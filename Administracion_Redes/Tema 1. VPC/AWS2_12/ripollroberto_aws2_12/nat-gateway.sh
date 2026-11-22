#!/usr/bin/env bash

set -Eeuo pipefail

on_error() {
    local exit_code="$1"
    local line="$2"
    local command="$3"
    echo >&2
    echo "ERROR: fallo en la linea ${line}: ${command}" >&2
    exit "$exit_code"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR



# CONFIGURACION
REGION="us-east-1"
AVAILABILITY_ZONE="us-east-1a"

PROJECT_NAME="rrc-sh"
OWNER_TAG="RRC"

VPC_CIDR="10.0.0.0/16"
PUBLIC_SUBNET_CIDR="10.0.1.0/24"
PRIVATE_SUBNET_CIDR="10.0.2.0/24"

INSTANCE_TYPE="t3.micro"
KEY_NAME="vockey"
IAM_INSTANCE_PROFILE="LabInstanceProfile"

# Se obtiene la AMI directamente desde EC2 (no depende de SSM Parameter Store).
AMI_NAME_FILTER="al2023-ami-202*-kernel-*-x86_64"

# Variables globales con los identificadores de los recursos.
ADMIN_CIDR=""
AMI_ID=""
VPC_ID=""
PUBLIC_SUBNET_ID=""
PRIVATE_SUBNET_ID=""
IGW_ID=""
PUBLIC_SG_ID=""
PRIVATE_SG_ID=""
PUBLIC_ROUTE_TABLE_ID=""
PRIVATE_ROUTE_TABLE_ID=""
NAT_GATEWAY_ID=""
NAT_ALLOCATION_ID=""
NAT_PUBLIC_IP=""
PUBLIC_INSTANCE_ID=""
PRIVATE_INSTANCE_ID=""

aws_ec2() {
    aws --region "$REGION" ec2 "$@"
}

is_empty_aws_value() {
    [[ -z "${1:-}" || "$1" == "None" || "$1" == "null" ]]
}

tag_resource() {
    local resource_id="$1"
    local resource_name="${2:-}"
    local -a tags

    tags=(
        "Key=Proyecto,Value=${PROJECT_NAME}"
        "Key=Propietario,Value=${OWNER_TAG}"
    )

    if [[ -n "$resource_name" ]]; then
        tags+=("Key=Name,Value=${resource_name}")
    fi

    aws_ec2 create-tags --resources "$resource_id" --tags "${tags[@]}" >/dev/null
}

check_requirements() {
    echo "Comprobando requisitos..."

    local command_name
    for command_name in aws curl; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            echo "ERROR: no se encuentra el comando requerido: ${command_name}" >&2
            exit 1
        fi
    done

    echo "AWS CLI: $(aws --version 2>&1)"
    echo "Identidad AWS:"
    aws --region "$REGION" sts get-caller-identity \
        --query '{Cuenta:Account,Arn:Arn}' --output table
}

get_admin_cidr() {
    echo
    echo "Obteniendo IP publica del administrador..."

    local public_ip
    public_ip="$(curl -4fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')"

    if [[ ! "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "ERROR: la respuesta de checkip.amazonaws.com no es una IPv4 valida: ${public_ip}" >&2
        exit 1
    fi

    ADMIN_CIDR="${public_ip}/32"
    echo "    IP publica detectada: ${public_ip}"
    echo "    CIDR del administrador: ${ADMIN_CIDR}"
}



# AMI AMAZON LINUX 2023
get_latest_ami() {
    echo
    echo "Buscando la AMI mas reciente de Amazon Linux 2023..."

    AMI_ID="$(aws_ec2 describe-images \
        --owners amazon \
        --filters \
            "Name=name,Values=${AMI_NAME_FILTER}" \
            "Name=state,Values=available" \
            "Name=architecture,Values=x86_64" \
            "Name=virtualization-type,Values=hvm" \
            "Name=root-device-type,Values=ebs" \
        --query 'Images | sort_by(@, &CreationDate)[-1].ImageId' \
        --output text)"

    if is_empty_aws_value "$AMI_ID"; then
        echo "ERROR: no se ha encontrado ninguna AMI de Amazon Linux 2023 en ${REGION}." >&2
        echo "Comprueba que la cuenta permite ec2:DescribeImages." >&2
        exit 1
    fi

    echo "    AMI seleccionada: ${AMI_ID}"
}



# VPC Y SUBNETS
create_or_reuse_vpc() {
    echo
    echo "[1/8] Creando o reutilizando VPC..."

    local existing_vpc
    existing_vpc="$(aws_ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=${PROJECT_NAME}-VPC" \
        --query 'Vpcs[0].VpcId' \
        --output text)"

    if is_empty_aws_value "$existing_vpc"; then
        VPC_ID="$(aws_ec2 create-vpc \
            --cidr-block "$VPC_CIDR" \
            --query 'Vpc.VpcId' \
            --output text)"
        tag_resource "$VPC_ID" "${PROJECT_NAME}-VPC"
        echo "    VPC creada: ${VPC_ID}"
    else
        VPC_ID="$existing_vpc"
        echo "    VPC existente reutilizada: ${VPC_ID}"
    fi

    aws_ec2 modify-vpc-attribute \
        --vpc-id "$VPC_ID" \
        --enable-dns-support '{"Value":true}'

    aws_ec2 modify-vpc-attribute \
        --vpc-id "$VPC_ID" \
        --enable-dns-hostnames '{"Value":true}'

    aws_ec2 wait vpc-available --vpc-ids "$VPC_ID"
}

create_or_reuse_subnet() {
    local cidr="$1"
    local subnet_name="$2"
    local public_flag="$3"
    local existing_subnet
    local subnet_id

    existing_subnet="$(aws_ec2 describe-subnets \
        --filters \
            "Name=vpc-id,Values=${VPC_ID}" \
            "Name=tag:Name,Values=${subnet_name}" \
        --query 'Subnets[0].SubnetId' \
        --output text)"

    if is_empty_aws_value "$existing_subnet"; then
        subnet_id="$(aws_ec2 create-subnet \
            --vpc-id "$VPC_ID" \
            --cidr-block "$cidr" \
            --availability-zone "$AVAILABILITY_ZONE" \
            --query 'Subnet.SubnetId' \
            --output text)"
        tag_resource "$subnet_id" "$subnet_name"
        echo "    Subnet creada: ${subnet_name} (${subnet_id})"
    else
        subnet_id="$existing_subnet"
        echo "    Subnet existente reutilizada: ${subnet_name} (${subnet_id})"
    fi

    if [[ "$public_flag" == "true" ]]; then
        aws_ec2 modify-subnet-attribute \
            --subnet-id "$subnet_id" \
            --map-public-ip-on-launch
    else
        aws_ec2 modify-subnet-attribute \
            --subnet-id "$subnet_id" \
            --no-map-public-ip-on-launch
    fi

    aws_ec2 wait subnet-available --subnet-ids "$subnet_id"

    if [[ "$public_flag" == "true" ]]; then
        PUBLIC_SUBNET_ID="$subnet_id"
    else
        PRIVATE_SUBNET_ID="$subnet_id"
    fi
}



# INTERNET GATEWAY Y NAT GATEWAY
create_or_reuse_internet_gateway() {
    echo
    echo "[3/8] Creando o reutilizando Internet Gateway..."

    local existing_igw
    existing_igw="$(aws_ec2 describe-internet-gateways \
        --filters \
            "Name=attachment.vpc-id,Values=${VPC_ID}" \
            "Name=tag:Proyecto,Values=${PROJECT_NAME}" \
        --query 'InternetGateways[0].InternetGatewayId' \
        --output text)"

    if is_empty_aws_value "$existing_igw"; then
        IGW_ID="$(aws_ec2 create-internet-gateway \
            --query 'InternetGateway.InternetGatewayId' \
            --output text)"
        tag_resource "$IGW_ID" "${PROJECT_NAME}-IGW"
        aws_ec2 attach-internet-gateway \
            --internet-gateway-id "$IGW_ID" \
            --vpc-id "$VPC_ID"
        echo "    Internet Gateway creado y asociado: ${IGW_ID}"
    else
        IGW_ID="$existing_igw"
        echo "    Internet Gateway existente reutilizado: ${IGW_ID}"
    fi
}

create_or_reuse_nat_gateway() {
    echo
    echo "[6/8] Creando o reutilizando NAT Gateway..."

    local existing_nat
    existing_nat="$(aws_ec2 describe-nat-gateways \
        --filter \
            "Name=vpc-id,Values=${VPC_ID}" \
            "Name=tag:Name,Values=${PROJECT_NAME}-NAT" \
        --query "NatGateways[?State=='available' || State=='pending'] | [0].NatGatewayId" \
        --output text)"

    if is_empty_aws_value "$existing_nat"; then
        NAT_ALLOCATION_ID="$(aws_ec2 allocate-address \
            --domain vpc \
            --query 'AllocationId' \
            --output text)"

        NAT_GATEWAY_ID="$(aws_ec2 create-nat-gateway \
            --subnet-id "$PUBLIC_SUBNET_ID" \
            --allocation-id "$NAT_ALLOCATION_ID" \
            --connectivity-type public \
            --query 'NatGateway.NatGatewayId' \
            --output text)"

        tag_resource "$NAT_GATEWAY_ID" "${PROJECT_NAME}-NAT"
        echo "    NAT Gateway creada: ${NAT_GATEWAY_ID}"
    else
        NAT_GATEWAY_ID="$existing_nat"
        echo "    NAT Gateway existente reutilizada: ${NAT_GATEWAY_ID}"
    fi

    echo "    Esperando a que la NAT Gateway este disponible..."
    aws_ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GATEWAY_ID"

    NAT_ALLOCATION_ID="$(aws_ec2 describe-nat-gateways \
        --nat-gateway-ids "$NAT_GATEWAY_ID" \
        --query 'NatGateways[0].NatGatewayAddresses[0].AllocationId' \
        --output text)"

    NAT_PUBLIC_IP="$(aws_ec2 describe-nat-gateways \
        --nat-gateway-ids "$NAT_GATEWAY_ID" \
        --query 'NatGateways[0].NatGatewayAddresses[0].PublicIp' \
        --output text)"

    echo "    NAT Gateway disponible: ${NAT_GATEWAY_ID}"
    echo "    Elastic IP: ${NAT_PUBLIC_IP}"
}



# SECURITY GROUPS
authorize_ingress_rule() {
    local group_id="$1"
    local permission_json="$2"
    local command_output

    if command_output="$(aws_ec2 authorize-security-group-ingress \
        --group-id "$group_id" \
        --ip-permissions "$permission_json" 2>&1)"; then
        :
    else
        if [[ "$command_output" == *"InvalidPermission.Duplicate"* ]]; then
            echo "    Regla de entrada ya existente en ${group_id}; se conserva."
        else
            echo "$command_output" >&2
            return 1
        fi
    fi
}

create_or_reuse_security_groups() {
    echo
    echo "[4/8] Creando o reutilizando Security Groups..."

    local existing_public_sg existing_private_sg

    existing_public_sg="$(aws_ec2 describe-security-groups \
        --filters \
            "Name=vpc-id,Values=${VPC_ID}" \
            "Name=group-name,Values=${PROJECT_NAME}-SG-Publico" \
        --query 'SecurityGroups[0].GroupId' \
        --output text)"

    if is_empty_aws_value "$existing_public_sg"; then
        PUBLIC_SG_ID="$(aws_ec2 create-security-group \
            --group-name "${PROJECT_NAME}-SG-Publico" \
            --description "SSH desde la IP del administrador e ICMP desde la VPC" \
            --vpc-id "$VPC_ID" \
            --query 'GroupId' \
            --output text)"
        tag_resource "$PUBLIC_SG_ID"
        echo "    Security Group publico creado: ${PUBLIC_SG_ID}"
    else
        PUBLIC_SG_ID="$existing_public_sg"
        echo "    Security Group publico reutilizado: ${PUBLIC_SG_ID}"
    fi

    existing_private_sg="$(aws_ec2 describe-security-groups \
        --filters \
            "Name=vpc-id,Values=${VPC_ID}" \
            "Name=group-name,Values=${PROJECT_NAME}-SG-Privado" \
        --query 'SecurityGroups[0].GroupId' \
        --output text)"

    if is_empty_aws_value "$existing_private_sg"; then
        PRIVATE_SG_ID="$(aws_ec2 create-security-group \
            --group-name "${PROJECT_NAME}-SG-Privado" \
            --description "SSH desde la EC2 publica e ICMP desde la VPC" \
            --vpc-id "$VPC_ID" \
            --query 'GroupId' \
            --output text)"
        tag_resource "$PRIVATE_SG_ID"
        echo "    Security Group privado creado: ${PRIVATE_SG_ID}"
    else
        PRIVATE_SG_ID="$existing_private_sg"
        echo "    Security Group privado reutilizado: ${PRIVATE_SG_ID}"
    fi

    # SSH a la EC2 publica desde la IP publica del administrador.
    authorize_ingress_rule "$PUBLIC_SG_ID" "[{
        \"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,
        \"IpRanges\":[{\"CidrIp\":\"${ADMIN_CIDR}\"}]
    }]"

    # ICMP dentro de la VPC para la EC2 publica.
    authorize_ingress_rule "$PUBLIC_SG_ID" "[{
        \"IpProtocol\":\"icmp\",\"FromPort\":-1,\"ToPort\":-1,
        \"IpRanges\":[{\"CidrIp\":\"${VPC_CIDR}\"}]
    }]"

    # SSH a la EC2 privada desde cualquier instancia con el SG publico.
    authorize_ingress_rule "$PRIVATE_SG_ID" "[{
        \"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,
        \"UserIdGroupPairs\":[{\"GroupId\":\"${PUBLIC_SG_ID}\"}]
    }]"

    # ICMP dentro de la VPC para la EC2 privada.
    authorize_ingress_rule "$PRIVATE_SG_ID" "[{
        \"IpProtocol\":\"icmp\",\"FromPort\":-1,\"ToPort\":-1,
        \"IpRanges\":[{\"CidrIp\":\"${VPC_CIDR}\"}]
    }]"

    echo "    Security Group publico: ${PUBLIC_SG_ID}"
    echo "    Security Group privado: ${PRIVATE_SG_ID}"
}



# TABLAS DE ENRUTAMIENTO
create_or_reuse_route_table() {
    local subnet_id="$1"
    local route_table_name="$2"
    local route_table_id
    local association_id

    route_table_id="$(aws_ec2 describe-route-tables \
        --filters \
            "Name=vpc-id,Values=${VPC_ID}" \
            "Name=tag:Name,Values=${route_table_name}" \
        --query 'RouteTables[0].RouteTableId' \
        --output text)"

    if is_empty_aws_value "$route_table_id"; then
        route_table_id="$(aws_ec2 create-route-table \
            --vpc-id "$VPC_ID" \
            --query 'RouteTable.RouteTableId' \
            --output text)"
        tag_resource "$route_table_id" "$route_table_name"
        echo "    Tabla de rutas creada: ${route_table_name} (${route_table_id})" >&2
    else
        echo "    Tabla de rutas existente reutilizada: ${route_table_name} (${route_table_id})" >&2
    fi

    association_id="$(aws_ec2 describe-route-tables \
        --route-table-ids "$route_table_id" \
        --query "RouteTables[0].Associations[?SubnetId=='${subnet_id}'].RouteTableAssociationId | [0]" \
        --output text)"

    if is_empty_aws_value "$association_id"; then
        aws_ec2 associate-route-table \
            --route-table-id "$route_table_id" \
            --subnet-id "$subnet_id" >/dev/null
    fi

    printf '%s' "$route_table_id"
}

ensure_default_route() {
    local route_table_id="$1"
    local target_field="$2"
    local target_option="$3"
    local target_id="$4"
    local current_target

    current_target="$(aws_ec2 describe-route-tables \
        --route-table-ids "$route_table_id" \
        --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].${target_field} | [0]" \
        --output text)"

    if is_empty_aws_value "$current_target"; then
        aws_ec2 create-route \
            --route-table-id "$route_table_id" \
            --destination-cidr-block "0.0.0.0/0" \
            "$target_option" "$target_id" >/dev/null
    elif [[ "$current_target" != "$target_id" ]]; then
        aws_ec2 replace-route \
            --route-table-id "$route_table_id" \
            --destination-cidr-block "0.0.0.0/0" \
            "$target_option" "$target_id" >/dev/null
    fi
}

configure_public_route() {
    echo
    echo "[5/8] Configurando tabla de rutas publica..."

    PUBLIC_ROUTE_TABLE_ID="$(create_or_reuse_route_table \
        "$PUBLIC_SUBNET_ID" \
        "${PROJECT_NAME}-RT-Publica")"

    ensure_default_route \
        "$PUBLIC_ROUTE_TABLE_ID" \
        "GatewayId" \
        "--gateway-id" \
        "$IGW_ID"

    echo "    Ruta publica: 0.0.0.0/0 -> ${IGW_ID}"
}

configure_private_route() {
    echo
    echo "[7/8] Configurando tabla de rutas privada..."

    PRIVATE_ROUTE_TABLE_ID="$(create_or_reuse_route_table \
        "$PRIVATE_SUBNET_ID" \
        "${PROJECT_NAME}-RT-Privada")"

    ensure_default_route \
        "$PRIVATE_ROUTE_TABLE_ID" \
        "NatGatewayId" \
        "--nat-gateway-id" \
        "$NAT_GATEWAY_ID"

    echo "    Ruta privada: 0.0.0.0/0 -> ${NAT_GATEWAY_ID}"
}



# USER DATA Y EC2
write_user_data() {
    local instance_name="$1"

    cat <<EOF_USER_DATA
#!/bin/bash
exec > >(tee -a /var/log/connectivity-check.log) 2>&1

echo '============================================'
echo 'PRUEBAS DE CONECTIVIDAD: ${instance_name}'
echo '============================================'
date

echo
echo '[1] Interfaces de red'
ip -brief address || ip addr

echo
echo '[2] Tabla de rutas'
ip route

echo
echo '[3] Resolucion DNS'
getent hosts amazon.com || true

echo
echo '[4] Ping a 1.1.1.1'
ping -c 4 -W 3 1.1.1.1 || true

echo
echo '[5] Conexion HTTPS a AWS'
curl -4 -I --connect-timeout 10 --max-time 20 https://aws.amazon.com || true

echo
echo '[6] Direccion IP publica de salida'
curl -4 --silent --show-error --connect-timeout 10 --max-time 20 https://checkip.amazonaws.com || true

echo
echo 'FIN DE LAS PRUEBAS'
EOF_USER_DATA
}

find_existing_instance() {
    local instance_name="$1"
    local subnet_id="$2"

    aws_ec2 describe-instances \
        --filters \
            "Name=tag:Name,Values=${instance_name}" \
            "Name=tag:Proyecto,Values=${PROJECT_NAME}" \
            "Name=subnet-id,Values=${subnet_id}" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId | [0]' \
        --output text
}

create_or_reuse_instance() {
    local subnet_id="$1"
    local security_group_id="$2"
    local instance_name="$3"
    local public_ip="$4"
    local existing_instance
    local instance_state
    local network_interfaces
    local tag_specifications
    local user_data
    local -a run_args

    existing_instance="$(find_existing_instance "$instance_name" "$subnet_id")"

    if ! is_empty_aws_value "$existing_instance"; then
        INSTANCE_ID_RESULT="$existing_instance"
        instance_state="$(aws_ec2 describe-instances \
            --instance-ids "$INSTANCE_ID_RESULT" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text)"

        echo "    Instancia existente encontrada: ${INSTANCE_ID_RESULT} (${instance_state})"

        case "$instance_state" in
            stopped)
                aws_ec2 start-instances --instance-ids "$INSTANCE_ID_RESULT" >/dev/null
                ;;
            stopping)
                aws_ec2 wait instance-stopped --instance-ids "$INSTANCE_ID_RESULT"
                aws_ec2 start-instances --instance-ids "$INSTANCE_ID_RESULT" >/dev/null
                ;;
            pending|running)
                ;;
            *)
                echo "ERROR: estado no esperado para ${INSTANCE_ID_RESULT}: ${instance_state}" >&2
                return 1
                ;;
        esac
    else
        echo "    Creando ${instance_name}..."

        network_interfaces="$(cat <<EOF_NETWORK
[
  {
    "DeviceIndex": 0,
    "SubnetId": "${subnet_id}",
    "Groups": ["${security_group_id}"],
    "AssociatePublicIpAddress": ${public_ip},
    "DeleteOnTermination": true
  }
]
EOF_NETWORK
)"

        tag_specifications="$(cat <<EOF_TAGS
[
  {
    "ResourceType": "instance",
    "Tags": [
      {"Key": "Proyecto", "Value": "${PROJECT_NAME}"},
      {"Key": "Propietario", "Value": "${OWNER_TAG}"},
      {"Key": "Name", "Value": "${instance_name}"}
    ]
  }
]
EOF_TAGS
)"

        user_data="$(write_user_data "$instance_name")"

        run_args=(
            run-instances
            --image-id "$AMI_ID"
            --instance-type "$INSTANCE_TYPE"
            --key-name "$KEY_NAME"
            --count 1
            --network-interfaces "$network_interfaces"
            --user-data "$user_data"
            --tag-specifications "$tag_specifications"
        )

        if [[ -n "$IAM_INSTANCE_PROFILE" ]]; then
            run_args+=(--iam-instance-profile "Name=${IAM_INSTANCE_PROFILE}")
        fi

        INSTANCE_ID_RESULT="$(aws_ec2 "${run_args[@]}" \
            --query 'Instances[0].InstanceId' \
            --output text)"

        echo "    Instancia lanzada: ${INSTANCE_ID_RESULT}"
    fi

    echo "    Esperando a que ${instance_name} este en estado running..."
    aws_ec2 wait instance-running --instance-ids "$INSTANCE_ID_RESULT"

    echo "    Esperando los chequeos de estado de AWS..."
    aws_ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID_RESULT"

    echo "    Instancia preparada: ${INSTANCE_ID_RESULT}"
}

show_instance_information() {
    local instance_name="$1"
    local instance_id="$2"
    local details
    local returned_id state private_ip public_ip

    details="$(aws_ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].[InstanceId,State.Name,PrivateIpAddress,PublicIpAddress]' \
        --output text)"

    IFS=$'\t' read -r returned_id state private_ip public_ip <<< "$details"

    [[ "$private_ip" == "None" || -z "$private_ip" ]] && private_ip="No disponible"
    [[ "$public_ip" == "None" || -z "$public_ip" ]] && public_ip="No tiene"

    echo
    echo "Nombre: ${instance_name}"
    echo "ID: ${returned_id}"
    echo "Estado: ${state}"
    echo "IP privada: ${private_ip}"
    echo "IP publica: ${public_ip}"
}



# MAIN


main() {
    echo "============================================"
    echo " DESPLIEGUE DE VPC CON SUBNET PUBLICA Y PRIVADA"
    echo "============================================"
    echo "Region: ${REGION}"
    echo "Availability Zone: ${AVAILABILITY_ZONE}"
    echo "Proyecto: ${PROJECT_NAME}"

    check_requirements
    get_admin_cidr

    # Buscar la AMI antes de crear recursos para evitar dejar infraestructura
    # desplegada si no se puede resolver una imagen para las instancias.
    get_latest_ami

    # 1. VPC.
    create_or_reuse_vpc

    # 2. Subnets publica y privada.
    echo
    echo "[2/8] Creando o reutilizando subnets..."
    create_or_reuse_subnet \
        "$PUBLIC_SUBNET_CIDR" \
        "${PROJECT_NAME}-Subnet-Publica" \
        true

    create_or_reuse_subnet \
        "$PRIVATE_SUBNET_CIDR" \
        "${PROJECT_NAME}-Subnet-Privada" \
        false

    # 3. Internet Gateway.
    create_or_reuse_internet_gateway

    # 4. Security Groups.
    create_or_reuse_security_groups

    # 5. Ruta publica hacia Internet Gateway.
    configure_public_route

    # 6. NAT Gateway en la subnet publica.
    create_or_reuse_nat_gateway

    # 7. Ruta privada hacia NAT Gateway.
    configure_private_route

    # 8. Instancias EC2.
    echo
    echo "[8/8] Creando o reutilizando instancias EC2..."

    create_or_reuse_instance \
        "$PUBLIC_SUBNET_ID" \
        "$PUBLIC_SG_ID" \
        "${PROJECT_NAME}-EC2-Publica" \
        true
    PUBLIC_INSTANCE_ID="$INSTANCE_ID_RESULT"

    create_or_reuse_instance \
        "$PRIVATE_SUBNET_ID" \
        "$PRIVATE_SG_ID" \
        "${PROJECT_NAME}-EC2-Privada" \
        false
    PRIVATE_INSTANCE_ID="$INSTANCE_ID_RESULT"

    # Resumen final.
    echo
    echo "========== INFORMACION DE LAS EC2 =========="
    show_instance_information "${PROJECT_NAME}-EC2-Publica" "$PUBLIC_INSTANCE_ID"
    show_instance_information "${PROJECT_NAME}-EC2-Privada" "$PRIVATE_INSTANCE_ID"

    echo
    echo "============= DESPLIEGUE COMPLETADO ============="
    echo "VPC: ${VPC_ID}"
    echo "Subnet publica: ${PUBLIC_SUBNET_ID}"
    echo "Subnet privada: ${PRIVATE_SUBNET_ID}"
    echo "Internet Gateway: ${IGW_ID}"
    echo "Security Group publico: ${PUBLIC_SG_ID}"
    echo "Security Group privado: ${PRIVATE_SG_ID}"
    echo "Tabla de rutas publica: ${PUBLIC_ROUTE_TABLE_ID}"
    echo "NAT Gateway: ${NAT_GATEWAY_ID}"
    echo "Elastic IP de la NAT: ${NAT_PUBLIC_IP}"
    echo "Allocation ID de la Elastic IP: ${NAT_ALLOCATION_ID}"
    echo "Tabla de rutas privada: ${PRIVATE_ROUTE_TABLE_ID}"
    echo "AMI: ${AMI_ID}"
    echo "EC2 publica: ${PUBLIC_INSTANCE_ID}"
    echo "EC2 privada: ${PRIVATE_INSTANCE_ID}"
    echo
    echo "Para conectarte a la EC2 publica:"
    echo "ssh -i ./${KEY_NAME}.pem ec2-user@IP_PUBLICA"
    echo
    echo "Para conectarte a la EC2 privada desde tu equipo mediante ProxyJump:"
    echo "ssh -i ./${KEY_NAME}.pem -o IdentitiesOnly=yes -J ec2-user@IP_PUBLICA ec2-user@IP_PRIVADA"
    echo
    echo "Log de conectividad en cada EC2:"
    echo "sudo cat /var/log/connectivity-check.log"
    echo "================================================="
}

main "$@"
