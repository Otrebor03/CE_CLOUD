
#!/bin/bash

# Autor: Roberto Ripoll Cones
# Crear infraestructura AWS: VPC, subredes, grupo de seguridad,
# tabla de enrutamiento, Internet Gateway e instancias EC2.

set -e


REGION="us-east-1"
OWNER="Roberto Ripoll Cones"
TIPO="prueba"

VPC_CIDR="172.16.0.0/16"

AMI_ID="ami-0866a3c8686eaeeba"
INSTANCE_TYPE="t2.micro"
KEY_NAME="vockey"

export AWS_DEFAULT_REGION="$REGION"

echo "Comprobando configuración de AWS..."

aws sts get-caller-identity > /dev/null

echo "Conexión con AWS correcta."

# 1. CREAR VPC Y SUBREDES
crear_vpc() {

    aws ec2 create-vpc \
        --cidr-block "$VPC_CIDR" \
        --instance-tenancy default \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=VPC-RRC-Bash},{Key=Owner,Value=$OWNER},{Key=tipo,Value=$TIPO}]" \
        --query 'Vpc.VpcId' \
        --output text
}


crear_subred() {

    local vpc_id="$1"
    local cidr="$2"
    local nombre="$3"

    aws ec2 create-subnet \
        --vpc-id "$vpc_id" \
        --cidr-block "$cidr" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$nombre},{Key=Owner,Value=$OWNER},{Key=tipo,Value=$TIPO}]" \
        --query 'Subnet.SubnetId' \
        --output text
}


habilitar_ip_publica_subred() {

    local subnet_id="$1"

    aws ec2 modify-subnet-attribute \
        --subnet-id "$subnet_id" \
        --map-public-ip-on-launch

}

# 2. GRUPO DE SEGURIDAD

crear_grupo_seguridad() {

    local vpc_id="$1"

    aws ec2 create-security-group \
        --group-name "SG-RRC-Bash" \
        --description "Grupo de seguridad para la instancia EC2" \
        --vpc-id "$vpc_id" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=SG-RRC-Bash},{Key=Owner,Value=$OWNER},{Key=tipo,Value=$TIPO}]" \
        --query 'GroupId' \
        --output text
}


habilitar_reglas_grupo_seguridad() {

    local grupo_id="$1"

    aws ec2 authorize-security-group-ingress \
        --group-id "$grupo_id" \
        --ip-permissions \
        'IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0}]' \
        'IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=0.0.0.0/0}]'

}



# 3. TABLA DE ENRUTAMIENTO


crear_tabla_enrutamiento() {

    local vpc_id="$1"
    local nombre="$2"

    aws ec2 create-route-table \
        --vpc-id "$vpc_id" \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$nombre},{Key=Owner,Value=$OWNER},{Key=tipo,Value=$TIPO}]" \
        --query 'RouteTable.RouteTableId' \
        --output text
}


asociar_subred_tabla() {

    local subnet_id="$1"
    local tabla_id="$2"

    local asociacion_id

    asociacion_id=$(aws ec2 associate-route-table \
        --subnet-id "$subnet_id" \
        --route-table-id "$tabla_id" \
        --query 'AssociationId' \
        --output text)

    echo "Subred $subnet_id asociada a la tabla $tabla_id" >&2

    echo "$asociacion_id"
}


desasociar_subred_tabla() {

    local asociacion_id="$1"

    aws ec2 disassociate-route-table \
        --association-id "$asociacion_id"

    echo "Asociación $asociacion_id eliminada"
}


comprobar_tabla_enrutamiento() {

    local tabla_id="$1"

    echo ""
    echo "--- RUTAS DE LA TABLA ---"

    aws ec2 describe-route-tables \
        --route-table-ids "$tabla_id" \
        --query 'RouteTables[0].Routes[*].[DestinationCidrBlock,GatewayId,State]' \
        --output table

    echo ""
    echo "--- ASOCIACIONES ---"

    aws ec2 describe-route-tables \
        --route-table-ids "$tabla_id" \
        --query 'RouteTables[0].Associations[*].[AssociationId,SubnetId,Main,AssociationState.State]' \
        --output table

}



# 4. INTERNET GATEWAY


crear_gateway_internet() {

    aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=IGW-RRC-Bash},{Key=Owner,Value=$OWNER},{Key=tipo,Value=$TIPO}]" \
        --query 'InternetGateway.InternetGatewayId' \
        --output text
}


asociar_gateway_internet() {

    local gateway_id="$1"
    local vpc_id="$2"

    aws ec2 attach-internet-gateway \
        --internet-gateway-id "$gateway_id" \
        --vpc-id "$vpc_id"

    echo "Gateway de Internet $gateway_id asociado a la VPC $vpc_id"
}


desasociar_gateway_internet() {

    local gateway_id="$1"
    local vpc_id="$2"

    aws ec2 detach-internet-gateway \
        --internet-gateway-id "$gateway_id" \
        --vpc-id "$vpc_id"

    echo "Gateway de Internet $gateway_id desasociado de la VPC $vpc_id"
}


crear_ruta_gateway() {

    local tabla_id="$1"
    local gateway_id="$2"

    aws ec2 create-route \
        --route-table-id "$tabla_id" \
        --destination-cidr-block "0.0.0.0/0" \
        --gateway-id "$gateway_id"

    echo "Ruta creada hacia el Gateway de Internet $gateway_id"
}



# 5. INSTANCIAS EC2


crear_instancia() {

    local subnet_id="$1"
    local grupo_id="$2"
    local ip_privada="$3"

    aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --count 1 \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --subnet-id "$subnet_id" \
        --security-group-ids "$grupo_id" \
        --private-ip-address "$ip_privada" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=EC2-RRC-Bash},{Key=Owner,Value=$OWNER},{Key=tipo,Value=$TIPO}]" \
        --query 'Instances[0].InstanceId' \
        --output text
}


obtener_ip_instancia() {

    local instancia_id="$1"

    aws ec2 wait instance-running \
        --instance-ids "$instancia_id"

    aws ec2 describe-instances \
        --instance-ids "$instancia_id" \
        --query 'Reservations[0].Instances[0].[PrivateIpAddress,PublicIpAddress]' \
        --output text
}



# 6. PREPARAR INSTANCIAS PARA SEPARAR EL IGW


preparar_instancias_para_separar_igw() {

    local instancia1="$1"
    local instancia3="$2"

    local subnet1="$3"
    local subnet2="$4"
    local subnet3="$5"

    # Evitar que las instancias reciban nuevas IP públicas

    aws ec2 modify-subnet-attribute \
        --subnet-id "$subnet1" \
        --no-map-public-ip-on-launch

    aws ec2 modify-subnet-attribute \
        --subnet-id "$subnet2" \
        --no-map-public-ip-on-launch

    aws ec2 modify-subnet-attribute \
        --subnet-id "$subnet3" \
        --no-map-public-ip-on-launch

    # Detener las instancias

    aws ec2 stop-instances \
        --instance-ids "$instancia1" "$instancia3"

    # Esperar a que estén detenidas

    aws ec2 wait instance-stopped \
        --instance-ids "$instancia1" "$instancia3"

    echo "Instancias detenidas y subredes configuradas."
    echo "Las IP públicas automáticas se han liberado."

}



# EJECUCIÓN PRINCIPAL



# 1. CREAR VPC Y SUBREDES


VPC_ID=$(crear_vpc)

aws ec2 wait vpc-available \
    --vpc-ids "$VPC_ID"

echo ""
echo "VPC creada: $VPC_ID"


# Crear subred 1

SUBNET1_ID=$(crear_subred \
    "$VPC_ID" \
    "172.16.0.0/20" \
    "Subnet-RRC-Bash-1")

aws ec2 wait subnet-available \
    --subnet-ids "$SUBNET1_ID"

habilitar_ip_publica_subred "$SUBNET1_ID"

echo "Subred 1 creada: $SUBNET1_ID"


# Crear subredes 2 y 3

SUBNET2_ID=$(crear_subred \
    "$VPC_ID" \
    "172.16.16.0/20" \
    "Subnet-RRC-Bash-2")

SUBNET3_ID=$(crear_subred \
    "$VPC_ID" \
    "172.16.32.0/20" \
    "Subnet-RRC-Bash-3")

aws ec2 wait subnet-available \
    --subnet-ids "$SUBNET2_ID" "$SUBNET3_ID"

habilitar_ip_publica_subred "$SUBNET2_ID"
habilitar_ip_publica_subred "$SUBNET3_ID"

echo "Subred 2 creada: $SUBNET2_ID"
echo "Subred 3 creada: $SUBNET3_ID"



# 2. GRUPO DE SEGURIDAD


SG_ID=$(crear_grupo_seguridad "$VPC_ID")

habilitar_reglas_grupo_seguridad "$SG_ID"

echo ""
echo "Grupo de seguridad creado: $SG_ID"



# 3. TABLA DE ENRUTAMIENTO E IGW


ROUTE_TABLE_ID=$(crear_tabla_enrutamiento \
    "$VPC_ID" \
    "RouteTable-RRC-Bash")

echo "Tabla de enrutamiento creada: $ROUTE_TABLE_ID"


# Asociar inicialmente las subredes 1 y 2.
# La subred 3 queda sin asociar a esta tabla personalizada.

ASSOCIATION1=$(asociar_subred_tabla \
    "$SUBNET1_ID" \
    "$ROUTE_TABLE_ID")

ASSOCIATION2=$(asociar_subred_tabla \
    "$SUBNET2_ID" \
    "$ROUTE_TABLE_ID")


# Crear y asociar Internet Gateway

IGW_ID=$(crear_gateway_internet)

asociar_gateway_internet "$IGW_ID" "$VPC_ID"

crear_ruta_gateway "$ROUTE_TABLE_ID" "$IGW_ID"

comprobar_tabla_enrutamiento "$ROUTE_TABLE_ID"



# 4. CREAR LAS INSTANCIAS EC2


INSTANCE1_ID=$(crear_instancia \
    "$SUBNET1_ID" \
    "$SG_ID" \
    "172.16.0.100")

INSTANCE3_ID=$(crear_instancia \
    "$SUBNET3_ID" \
    "$SG_ID" \
    "172.16.32.100")


# Esperar y obtener las direcciones IP

read -r IP_PRIVADA1 IP_PUBLICA1 <<< "$(obtener_ip_instancia "$INSTANCE1_ID")"

read -r IP_PRIVADA3 IP_PUBLICA3 <<< "$(obtener_ip_instancia "$INSTANCE3_ID")"


echo ""
echo "--- INSTANCIA 1 ---"
echo "ID: $INSTANCE1_ID"
echo "IP privada: $IP_PRIVADA1"
echo "IP pública: $IP_PUBLICA1"

echo ""
echo "--- INSTANCIA 3 ---"
echo "ID: $INSTANCE3_ID"
echo "IP privada: $IP_PRIVADA3"
echo "IP pública: $IP_PUBLICA3"



# PRUEBA 1. ASOCIAR SUBRED 3 Y CONECTARSE POR SSH


read -r -p "
PRUEBA 1: Pulsa ENTER cuando estés preparado para asociar
la subred 3 a la tabla personalizada..."

ASSOCIATION3=$(asociar_subred_tabla \
    "$SUBNET3_ID" \
    "$ROUTE_TABLE_ID")

comprobar_tabla_enrutamiento "$ROUTE_TABLE_ID"


read -r -p "
Conéctate por SSH a la instancia 3 desde OTRA terminal.
Cuando tengas la sesión SSH abierta, vuelve aquí y pulsa ENTER..."



# PRUEBA 2. DESASOCIAR LA SUBRED EN CALIENTE


desasociar_subred_tabla "$ASSOCIATION3"

comprobar_tabla_enrutamiento "$ROUTE_TABLE_ID"


read -r -p "
Comprueba qué ocurre con la sesión SSH abierta.
Cuando termines, pulsa ENTER para continuar..."



# PRUEBA 3. SUBRED SIN ASOCIACIÓN A LA TABLA


echo ""
echo "PRUEBA 3: La subred 3 no está asociada a la tabla personalizada."

echo "Comprueba que no puedes abrir una NUEVA conexión SSH desde Internet."

read -r -p "Cuando hayas realizado la prueba, pulsa ENTER para continuar..."



# PRUEBA 4. VOLVER A ASOCIAR Y SEPARAR EL IGW


ASSOCIATION3=$(asociar_subred_tabla \
    "$SUBNET3_ID" \
    "$ROUTE_TABLE_ID")

comprobar_tabla_enrutamiento "$ROUTE_TABLE_ID"


read -r -p "
PRUEBA 4: Abre una nueva sesión SSH a la instancia 3 y déjala abierta.
Después vuelve aquí y pulsa ENTER para separar el Internet Gateway..."



# DETENER INSTANCIAS Y LIBERAR IP PÚBLICAS


preparar_instancias_para_separar_igw \
    "$INSTANCE1_ID" \
    "$INSTANCE3_ID" \
    "$SUBNET1_ID" \
    "$SUBNET2_ID" \
    "$SUBNET3_ID"



# SEPARAR INTERNET GATEWAY


desasociar_gateway_internet "$IGW_ID" "$VPC_ID"

comprobar_tabla_enrutamiento "$ROUTE_TABLE_ID"

echo ""
echo "PRUEBA 4: El IGW está separado."
echo "Las instancias están detenidas y no tienen IP pública automática al arrancar."


read -r -p "Pulsa ENTER para volver a asociar el IGW..."



# VOLVER A ASOCIAR INTERNET GATEWAY


asociar_gateway_internet "$IGW_ID" "$VPC_ID"



# RESTAURAR ASIGNACIÓN AUTOMÁTICA DE IP PÚBLICA


habilitar_ip_publica_subred "$SUBNET1_ID"
habilitar_ip_publica_subred "$SUBNET2_ID"
habilitar_ip_publica_subred "$SUBNET3_ID"



# ARRANCAR LAS INSTANCIAS


aws ec2 start-instances \
    --instance-ids "$INSTANCE1_ID" "$INSTANCE3_ID"

aws ec2 wait instance-running \
    --instance-ids "$INSTANCE1_ID" "$INSTANCE3_ID"



# CONSULTAR NUEVAS IP PÚBLICAS


read -r IP_PRIVADA1 IP_PUBLICA1 <<< "$(obtener_ip_instancia "$INSTANCE1_ID")"

read -r IP_PRIVADA3 IP_PUBLICA3 <<< "$(obtener_ip_instancia "$INSTANCE3_ID")"


echo ""
echo "Nueva IP pública EC2 1: $IP_PUBLICA1"
echo "Nueva IP pública EC2 3: $IP_PUBLICA3"



# COMPROBAR TABLA DE ENRUTAMIENTO


comprobar_tabla_enrutamiento "$ROUTE_TABLE_ID"


echo ""

echo "FINALIZADAS"

