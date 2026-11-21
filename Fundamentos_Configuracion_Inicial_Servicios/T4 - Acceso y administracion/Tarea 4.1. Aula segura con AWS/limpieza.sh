#!/usr/bin/env bash
set -Eeuo pipefail

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_PAGER=""
export MSYS_NO_PATHCONV=1
REGION="$AWS_DEFAULT_REGION"

ALARM_NAME="cpu-alta-ec2-web"
DASHBOARD_NAME="aula-segura"
LOG_GROUP_NAME="/aula-segura/httpd-access"
SNS_TOPIC_NAME="alarma-practica"

CONFIRM_MODE="prompt"
if [[ "${1:-}" == "--yes" ]]; then
    CONFIRM_MODE="yes"
fi

trap 'rc=$?; echo; echo "ERROR: la limpieza se ha detenido en la línea ${LINENO} (código $rc). Revisa el último comando y vuelve a ejecutar el script; los recursos ya eliminados se omitirán." >&2; exit "$rc"' ERR


# Funciones auxiliares


info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[AVISO]\033[0m %s\n' "$*"; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: no se encuentra el comando '$1'." >&2
        exit 1
    }
}

# Devuelve los IDs de instancias no terminadas con un Name tag concreto.
instance_ids_by_name() {
    local name="$1"
    aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=${name}" \
        --query "Reservations[].Instances[?State.Name!='terminated'].InstanceId[]" \
        --output text
}

# Devuelve los VPC IDs que tengan un Name tag concreto.
vpc_ids_by_name() {
    local name="$1"
    aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=${name}" \
        --query 'Vpcs[].VpcId' \
        --output text
}

# Elimina una tabla de rutas personalizada por VPC y Name tag.
delete_route_tables_by_name() {
    local vpc_id="$1" name="$2" ids id
    ids="$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=${name}" \
        --query 'RouteTables[].RouteTableId' --output text)"
    for id in $ids; do
        [[ "$id" == "None" ]] && continue
        aws ec2 delete-route-table --route-table-id "$id"
        ok "Tabla de rutas $name ($id) eliminada."
    done
}

# Elimina un Internet Gateway etiquetado y conectado a la VPC indicada.
delete_igw_by_name() {
    local vpc_id="$1" name="$2" ids id attached
    ids="$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=${name}" \
        --query 'InternetGateways[].InternetGatewayId' --output text)"
    for id in $ids; do
        [[ "$id" == "None" ]] && continue
        attached="$(aws ec2 describe-internet-gateways \
            --internet-gateway-ids "$id" \
            --query 'InternetGateways[0].Attachments[?VpcId!=null].VpcId' \
            --output text)"
        if [[ -n "$attached" && "$attached" != "None" ]]; then
            aws ec2 detach-internet-gateway --internet-gateway-id "$id" --vpc-id "$vpc_id"
        fi
        aws ec2 delete-internet-gateway --internet-gateway-id "$id"
        ok "Internet Gateway $name ($id) eliminado."
    done
}

# Elimina grupos de seguridad por nombre dentro de la VPC indicada.
delete_sg_by_name() {
    local vpc_id="$1" group_name="$2" ids id
    ids="$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=group-name,Values=${group_name}" \
        --query 'SecurityGroups[].GroupId' --output text)"
    for id in $ids; do
        [[ "$id" == "None" ]] && continue
        aws ec2 delete-security-group --group-id "$id"
        ok "Security Group $group_name ($id) eliminado."
    done
}


# 0. Comprobaciones y confirmación


require_command aws
require_command grep
require_command tr

info "Comprobando credenciales y región"
CALLER="$(aws sts get-caller-identity --query 'Account' --output text)"
echo "Cuenta AWS: $CALLER"
echo "Región:     $REGION"

VPC_PRACTICA_IDS="$(vpc_ids_by_name vpc-practica)"
VPC_RETO_IDS="$(vpc_ids_by_name vpc-reto)"

# El bucket se solicita expresamente: no se intenta adivinar.
BUCKET="${BUCKET:-}"
if [[ -z "$BUCKET" && "$CONFIRM_MODE" != "yes" ]]; then
    read -r -p "Nombre exacto del bucket de la práctica (Enter para omitir S3): " BUCKET
fi

# Mostrar los recursos objetivo antes de borrar.
echo
echo "Se intentará eliminar lo siguiente:"
echo "  Instancias: ec2-web, ec2-privada y ec2-reto"
echo "  CloudWatch: alarma $ALARM_NAME, dashboard $DASHBOARD_NAME y grupo $LOG_GROUP_NAME"
echo "  SNS: tema $SNS_TOPIC_NAME (si existe)"
echo "  VPC: vpc-practica ${VPC_PRACTICA_IDS:-'(no encontrada)'}"
echo "       vpc-reto      ${VPC_RETO_IDS:-'(no encontrada)'}"
if [[ -n "$BUCKET" ]]; then
    echo "  Bucket S3: $BUCKET"
else
    echo "  Bucket S3: se omitirá"
fi

if [[ "$CONFIRM_MODE" != "yes" ]]; then
    echo
    read -r -p "Esta operación es destructiva. Escribe ELIMINAR para continuar: " ANSWER
    if [[ "$ANSWER" != "ELIMINAR" ]]; then
        echo "Cancelado. No se ha eliminado ningún recurso."
        exit 0
    fi
fi


# 1. Desactivar monitorización detallada y terminar instancias


info "1/9 - Localizando y terminando las instancias EC2"
INSTANCE_IDS=()
ID_WEB=""
for NAME in ec2-web ec2-privada ec2-reto; do
    IDS="$(instance_ids_by_name "$NAME")"
    for ID in $IDS; do
        [[ -z "$ID" || "$ID" == "None" ]] && continue
        INSTANCE_IDS+=("$ID")
        if [[ "$NAME" == "ec2-web" ]]; then
            ID_WEB="$ID"
        fi
        echo "Encontrada $NAME: $ID"
    done
done

if [[ -n "$ID_WEB" ]]; then
    STATE_WEB="$(aws ec2 describe-instances --instance-ids "$ID_WEB" \
        --query 'Reservations[0].Instances[0].State.Name' --output text)"
    if [[ "$STATE_WEB" == "running" ]]; then
        if aws ec2 unmonitor-instances --instance-ids "$ID_WEB" >/dev/null; then
            ok "Monitorización detallada desactivada en $ID_WEB."
        else
            warn "No se pudo desactivar la monitorización detallada; la instancia se terminará igualmente."
        fi
    else
        warn "ec2-web está en estado '$STATE_WEB'; se omitió unmonitor-instances."
    fi
fi

if (( ${#INSTANCE_IDS[@]} > 0 )); then
    # Separar instancias que ya están en proceso de apagado.
    TERMINATE_IDS=()
    WAIT_IDS=()
    for ID in "${INSTANCE_IDS[@]}"; do
        STATE="$(aws ec2 describe-instances --instance-ids "$ID" \
            --query 'Reservations[0].Instances[0].State.Name' --output text)"
        case "$STATE" in
            shutting-down) WAIT_IDS+=("$ID");;
            terminated) ;;
            *) TERMINATE_IDS+=("$ID"); WAIT_IDS+=("$ID");;
        esac
    done
    if (( ${#TERMINATE_IDS[@]} > 0 )); then
        aws ec2 terminate-instances --instance-ids "${TERMINATE_IDS[@]}" >/dev/null
    fi
    if (( ${#WAIT_IDS[@]} > 0 )); then
        echo "Esperando a que las instancias terminen..."
        aws ec2 wait instance-terminated --instance-ids "${WAIT_IDS[@]}"
    fi
    ok "Instancias EC2 terminadas."
else
    ok "No se encontraron instancias pendientes de terminación."
fi


# 2. Eliminar recursos de CloudWatch y SNS


info "2/9 - Eliminando recursos de CloudWatch y SNS"
aws cloudwatch delete-alarms --alarm-names "$ALARM_NAME"
ok "Alarma $ALARM_NAME eliminada (si existía)."
aws cloudwatch delete-dashboards --dashboard-names "$DASHBOARD_NAME"
ok "Dashboard $DASHBOARD_NAME eliminado (si existía)."

TOPIC_ARN="${TOPIC:-}"
if [[ -n "$TOPIC_ARN" && "$TOPIC_ARN" != arn:aws:sns:* ]]; then
    TOPIC_ARN=""
fi
if [[ -z "$TOPIC_ARN" ]]; then
    TOPIC_ARN="$(aws sns list-topics --query 'Topics[].TopicArn' --output text \
        | tr '\t' '\n' | grep -E ":${SNS_TOPIC_NAME}$" | head -n 1 || true)"
fi
if [[ -n "$TOPIC_ARN" && "$TOPIC_ARN" != "None" ]]; then
    aws sns delete-topic --topic-arn "$TOPIC_ARN"
    ok "Tema SNS eliminado: $TOPIC_ARN"
else
    ok "No se encontró el tema SNS $SNS_TOPIC_NAME; se omite."
fi

LOG_GROUP_EXISTS="$(aws logs describe-log-groups \
    --log-group-name-prefix "$LOG_GROUP_NAME" \
    --query "logGroups[?logGroupName=='${LOG_GROUP_NAME}'].logGroupName" \
    --output text)"
if [[ -n "$LOG_GROUP_EXISTS" && "$LOG_GROUP_EXISTS" != "None" ]]; then
    aws logs delete-log-group --log-group-name "$LOG_GROUP_NAME"
    ok "Grupo de logs eliminado: $LOG_GROUP_NAME"
else
    ok "No se encontró el grupo de logs; se omite."
fi


# 3. Eliminar VPC Endpoint S3 de vpc-practica


info "3/9 - Eliminando VPC Endpoint de S3"
for VPC_ID in $VPC_PRACTICA_IDS; do
    ENDPOINT_IDS="$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=vpce-s3" \
        --query 'VpcEndpoints[].VpcEndpointId' --output text)"
    for ENDPOINT_ID in $ENDPOINT_IDS; do
        [[ -z "$ENDPOINT_ID" || "$ENDPOINT_ID" == "None" ]] && continue
        aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$ENDPOINT_ID" >/dev/null
        echo "Eliminando endpoint $ENDPOINT_ID..."
        for _ in {1..30}; do
            REMAINING="$(aws ec2 describe-vpc-endpoints \
                --vpc-endpoint-ids "$ENDPOINT_ID" \
                --query 'VpcEndpoints[?State!=`deleted`].VpcEndpointId' \
                --output text 2>/dev/null || true)"
            [[ -z "$REMAINING" || "$REMAINING" == "None" ]] && break
            sleep 2
        done
        ok "Endpoint $ENDPOINT_ID eliminado."
    done
done


# 4. Vaciar y borrar el bucket S3 (si se indicó)


info "4/9 - Eliminando bucket S3"
if [[ -n "$BUCKET" ]]; then
    if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
        aws s3 rb "s3://${BUCKET}" --force
        ok "Bucket s3://${BUCKET} vaciado y eliminado."
    else
        warn "No se encuentra el bucket $BUCKET o no hay permisos para consultarlo; se omite."
    fi
else
    warn "No se indicó bucket; se omite la limpieza de S3."
fi


# 5-9. Eliminar recursos de cada VPC en orden de dependencias


cleanup_vpc() {
    local vpc_id="$1" vpc_name="$2"
    local SUBNET_IDS SUBNET_ID NACL_IDS NACL_ID

    info "Limpiando $vpc_name ($vpc_id)"

    # 5. Subredes: al eliminarlas se liberan asociaciones de NACL y RT.
    SUBNET_IDS="$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'Subnets[].SubnetId' --output text)"
    for SUBNET_ID in $SUBNET_IDS; do
        [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]] && continue
        aws ec2 delete-subnet --subnet-id "$SUBNET_ID"
        ok "Subred eliminada: $SUBNET_ID"
    done

    # 6a. NACL personalizada de la subred privada.
    NACL_IDS="$(aws ec2 describe-network-acls \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=nacl-privada" \
        --query 'NetworkAcls[].NetworkAclId' --output text)"
    for NACL_ID in $NACL_IDS; do
        [[ -z "$NACL_ID" || "$NACL_ID" == "None" ]] && continue
        aws ec2 delete-network-acl --network-acl-id "$NACL_ID"
        ok "NACL nacl-privada eliminada: $NACL_ID"
    done

    # 6b. Tablas de rutas personalizadas.
    if [[ "$vpc_name" == "vpc-practica" ]]; then
        delete_route_tables_by_name "$vpc_id" rt-publica
        delete_route_tables_by_name "$vpc_id" rt-privada
    else
        delete_route_tables_by_name "$vpc_id" rt-reto
    fi

    # 7. Internet Gateway.
    if [[ "$vpc_name" == "vpc-practica" ]]; then
        delete_igw_by_name "$vpc_id" igw-practica
    else
        delete_igw_by_name "$vpc_id" igw-reto
    fi

    # 8. Security Groups. El privado referencia al web: borrar primero el privado.
    if [[ "$vpc_name" == "vpc-practica" ]]; then
        delete_sg_by_name "$vpc_id" sgr-privada
        delete_sg_by_name "$vpc_id" sgr-web
    else
        delete_sg_by_name "$vpc_id" sgr-reto
    fi

    # 9. VPC, una vez eliminadas todas sus dependencias.
    aws ec2 delete-vpc --vpc-id "$vpc_id"
    ok "$vpc_name ($vpc_id) eliminada."
}

info "5-9 - Eliminando recursos de las VPC"
for VPC_ID in $VPC_PRACTICA_IDS; do
    [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]] && continue
    cleanup_vpc "$VPC_ID" vpc-practica
done
for VPC_ID in $VPC_RETO_IDS; do
    [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]] && continue
    cleanup_vpc "$VPC_ID" vpc-reto
done

if [[ -z "$VPC_PRACTICA_IDS" || "$VPC_PRACTICA_IDS" == "None" ]]; then
    ok "No se encontró vpc-practica."
fi
if [[ -z "$VPC_RETO_IDS" || "$VPC_RETO_IDS" == "None" ]]; then
    ok "No se encontró vpc-reto."
fi

info "Limpieza finalizada"
echo "Se han procesado los recursos de la región $REGION en la cuenta $CALLER."
echo "Revisa la consola de EC2/VPC/S3 para confirmar que no quedan recursos de la práctica."
