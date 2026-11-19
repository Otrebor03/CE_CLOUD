#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# RETO UP4 - SEGUNDA VPC MEDIANTE AWS CLI
# Región: us-east-1
# Recursos: VPC + subred pública + IGW + rutas + SG + EC2
# Compatible con Bash (Git Bash en Windows y AWS CloudShell).
# ==========================================================

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_PAGER=""

REGION="$AWS_DEFAULT_REGION"
KEY_NAME="vockey"
INSTANCE_TYPE="t3.micro"
VPC_CIDR="10.30.0.0/16"
SUBNET_CIDR="10.30.1.0/24"

# Evita que un error deje recursos sin identificar.
VPC_ID=""
SUBNET_ID=""
IGW_ID=""
RT_ID=""
SG_ID=""
INSTANCE_ID=""

fail() {
    echo "ERROR: $*" >&2
    echo "Los recursos creados antes del error no se han eliminado automáticamente." >&2
    if [[ -n "$VPC_ID" ]]; then
        echo "VPC creada: $VPC_ID" >&2
    fi
    if [[ -n "$SUBNET_ID" ]]; then
        echo "Subred creada: $SUBNET_ID" >&2
    fi
    if [[ -n "$IGW_ID" ]]; then
        echo "Internet Gateway creado: $IGW_ID" >&2
    fi
    if [[ -n "$RT_ID" ]]; then
        echo "Tabla de rutas creada: $RT_ID" >&2
    fi
    if [[ -n "$SG_ID" ]]; then
        echo "Security Group creado: $SG_ID" >&2
    fi
    if [[ -n "$INSTANCE_ID" ]]; then
        echo "Instancia creada: $INSTANCE_ID" >&2
    fi
    exit 1
}

trap 'rc=$?; if [[ $rc -ne 0 ]]; then echo "El script ha terminado con error (código $rc)." >&2; fi' EXIT

printf '%s\n' "==================================================" \
    " DESPLIEGUE DE LA INFRAESTRUCTURA vpc-reto" \
    " Región: $REGION" \
    "=================================================="

# ----------------------------------------------------------
# 1. Comprobaciones iniciales
# ----------------------------------------------------------

echo "[1/8] Comprobando herramientas y credenciales AWS..."

command -v aws >/dev/null 2>&1 || fail "AWS CLI no está instalado o no está en PATH."
command -v curl >/dev/null 2>&1 || fail "curl no está instalado o no está en PATH."
command -v base64 >/dev/null 2>&1 || fail "base64 no está disponible en este entorno Bash."
command -v base64 >/dev/null 2>&1 || fail "base64 no está disponible en este entorno Bash."

aws sts get-caller-identity >/dev/null || fail "Credenciales AWS no válidas o caducadas."

# Si no se proporciona MY_IP_CIDR, se detecta la IP desde el equipo
# que ejecuta el script. En CloudShell será la IP de CloudShell.
if [[ -z "${MY_IP_CIDR:-}" ]]; then
    MY_IP="$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')" \
        || fail "No se ha podido detectar la IP pública. Define MY_IP_CIDR manualmente."
    MY_IP_CIDR="${MY_IP}/32"
fi

# Validación de formato IPv4/32 y de cada octeto.
if [[ ! "$MY_IP_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]]; then
    fail "MY_IP_CIDR debe tener formato IPv4/32, por ejemplo 95.120.155.225/32."
fi
IFS='./' read -r OCT1 OCT2 OCT3 OCT4 MASK <<< "$MY_IP_CIDR"
for OCTET in "$OCT1" "$OCT2" "$OCT3" "$OCT4"; do
    (( 10#$OCTET <= 255 )) || fail "Dirección IP no válida en MY_IP_CIDR: $MY_IP_CIDR"
done

printf 'IP autorizada para SSH: %s\n' "$MY_IP_CIDR"

aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1 \
    || fail "No existe el par de claves '$KEY_NAME' en la región $REGION."

# El reto debe ejecutarse en una VPC limpia. No se reutilizan recursos
# parciales de una ejecución anterior para evitar asociaciones incorrectas.
EXISTING_VPC="$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=vpc-reto" \
    --query 'Vpcs[0].VpcId' --output text)"

if [[ "$EXISTING_VPC" != "None" && -n "$EXISTING_VPC" ]]; then
    fail "Ya existe vpc-reto ($EXISTING_VPC). Limpia la ejecución anterior o usa una VPC limpia antes de volver a ejecutar el script."
fi

# ----------------------------------------------------------
# 2. Obtener AMI de Amazon Linux 2023
# ----------------------------------------------------------

echo "[2/8] Buscando AMI de Amazon Linux 2023..."

AMI_ID="$(aws ssm get-parameter \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameter.Value' \
    --output text 2>/dev/null || true)"

# Alternativa si el Learner Lab no permite consultar SSM.
if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    AMI_ID="$(aws ec2 describe-images \
        --owners amazon \
        --filters \
        "Name=name,Values=al2023-ami-2023.*-x86_64" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
        --query 'Images | sort_by(@, &CreationDate)[-1].ImageId' \
        --output text)"
fi

[[ -n "$AMI_ID" && "$AMI_ID" != "None" ]] || fail "No se ha podido obtener una AMI de Amazon Linux 2023."
printf 'AMI seleccionada: %s\n' "$AMI_ID"

# ----------------------------------------------------------
# 3. Crear VPC y activar DNS
# ----------------------------------------------------------

echo "[3/8] Creando VPC..."

VPC_ID="$(aws ec2 create-vpc \
    --cidr-block "$VPC_CIDR" \
    --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=vpc-reto}]' \
    --query 'Vpc.VpcId' \
    --output text)"

aws ec2 wait vpc-available --vpc-ids "$VPC_ID"

aws ec2 modify-vpc-attribute \
    --vpc-id "$VPC_ID" \
    --enable-dns-support '{"Value":true}'

aws ec2 modify-vpc-attribute \
    --vpc-id "$VPC_ID" \
    --enable-dns-hostnames '{"Value":true}'

printf 'VPC creada: %s\n' "$VPC_ID"

# ----------------------------------------------------------
# 4. Crear subred pública
# ----------------------------------------------------------

echo "[4/8] Creando subred pública..."

SUBNET_ID="$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block "$SUBNET_CIDR" \
    --availability-zone "${REGION}a" \
    --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=sn-reto}]' \
    --query 'Subnet.SubnetId' \
    --output text)"

aws ec2 wait subnet-available --subnet-ids "$SUBNET_ID"

aws ec2 modify-subnet-attribute \
    --subnet-id "$SUBNET_ID" \
    --map-public-ip-on-launch

printf 'Subred creada: %s\n' "$SUBNET_ID"

# ----------------------------------------------------------
# 5. Crear Internet Gateway y tabla de rutas
# ----------------------------------------------------------

echo "[5/8] Configurando Internet Gateway y tabla de rutas..."

IGW_ID="$(aws ec2 create-internet-gateway \
    --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=igw-reto}]' \
    --query 'InternetGateway.InternetGatewayId' \
    --output text)"

aws ec2 attach-internet-gateway \
    --internet-gateway-id "$IGW_ID" \
    --vpc-id "$VPC_ID"

RT_ID="$(aws ec2 create-route-table \
    --vpc-id "$VPC_ID" \
    --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=rt-reto}]' \
    --query 'RouteTable.RouteTableId' \
    --output text)"

# Reintentar brevemente por si AWS aún está propagando el attachment del IGW.
ROUTE_CREATED=0
for ATTEMPT in 1 2 3 4 5; do
    if aws ec2 create-route \
        --route-table-id "$RT_ID" \
        --destination-cidr-block 0.0.0.0/0 \
        --gateway-id "$IGW_ID" >/dev/null 2>&1; then
        ROUTE_CREATED=1
        break
    fi
    sleep 3
done

[[ "$ROUTE_CREATED" -eq 1 ]] || fail "No se ha podido crear la ruta 0.0.0.0/0 hacia el Internet Gateway."

aws ec2 associate-route-table \
    --route-table-id "$RT_ID" \
    --subnet-id "$SUBNET_ID" >/dev/null

printf 'Internet Gateway: %s\nTabla de rutas: %s\n' "$IGW_ID" "$RT_ID"

# ----------------------------------------------------------
# 6. Crear Security Group
# ----------------------------------------------------------

echo "[6/8] Creando Security Group..."

SG_ID="$(aws ec2 create-security-group \
    --group-name sgr-reto \
    --description "Security Group del servidor web del reto" \
    --vpc-id "$VPC_ID" \
    --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=sgr-reto}]' \
    --query 'GroupId' \
    --output text)"

# HTTP desde cualquier origen.
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0 >/dev/null

# SSH exclusivamente desde la IP pública indicada.
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr "$MY_IP_CIDR" >/dev/null

printf 'Security Group: %s\n' "$SG_ID"

# ----------------------------------------------------------
# 7. Preparar User Data
# ----------------------------------------------------------

echo "[7/8] Preparando User Data..."

# IMPORTANTE: se guarda en una variable y después se codifica en Base64.
# Así no se utiliza ningún fichero temporal ni rutas /tmp incompatibles
# con AWS CLI para Windows cuando se ejecuta desde Git Bash.
USER_DATA="$(cat <<'USERDATA'
#!/bin/bash
exec > /var/log/user-data-reto.log 2>&1
set -euxo pipefail

dnf install -y httpd

HOSTNAME_LOCAL="$(hostname)"

cat > /var/www/html/index.html <<HTML
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>Reto AWS - UP4</title>
</head>
<body style="font-family:Arial,sans-serif;margin:40px">
    <h1>Servidor web desplegado con AWS CLI</h1>
    <h2>Reto UP4 - Segunda VPC</h2>
    <p>Nombre de host: <strong>${HOSTNAME_LOCAL}</strong></p>
    <p>Instancia: ec2-reto</p>
    <p>Servidor Apache funcionando correctamente.</p>
</body>
</html>
HTML

systemctl enable --now httpd
USERDATA
)"

# AWS CLI recibe UserData como un parámetro blob en Base64. Al codificarlo
# aquí evitamos rutas temporales /tmp que AWS CLI para Windows no puede abrir.
USER_DATA_B64="$(printf '%s' "$USER_DATA" | base64 | tr -d '\r\n')"

# ----------------------------------------------------------
# 8. Lanzar instancia EC2 y verificar la web
# ----------------------------------------------------------

echo "[8/8] Lanzando instancia EC2..."

INSTANCE_ID="$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --count 1 \
    --key-name "$KEY_NAME" \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --metadata-options HttpTokens=required \
    --user-data "$USER_DATA_B64" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ec2-reto}]' \
    --query 'Instances[0].InstanceId' \
    --output text)"

printf 'Instancia creada: %s\n' "$INSTANCE_ID"

echo "Esperando a que la instancia esté operativa..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"

PUBLIC_IP="$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)"

[[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "None" ]] || fail "La instancia no tiene una IP pública. Revisa la subred y la asignación automática de IP."

# Guardar los identificadores para facilitar la consulta y la limpieza posterior.
ENV_FILE="reto-recursos.env"
cat > "$ENV_FILE" <<EOF_ENV
REGION=$REGION
VPC_ID=$VPC_ID
SUBNET_ID=$SUBNET_ID
IGW_ID=$IGW_ID
RT_ID=$RT_ID
SG_ID=$SG_ID
INSTANCE_ID=$INSTANCE_ID
PUBLIC_IP=$PUBLIC_IP
AMI_ID=$AMI_ID
MY_IP_CIDR=$MY_IP_CIDR
EOF_ENV

printf '\n%s\n' "==================================================" \
    " INFRAESTRUCTURA CREADA" \
    "==================================================" \
    "VPC:             $VPC_ID" \
    "Subred:          $SUBNET_ID" \
    "Internet GW:     $IGW_ID" \
    "Tabla de rutas:  $RT_ID" \
    "Security Group:  $SG_ID" \
    "Instancia EC2:   $INSTANCE_ID" \
    "AMI:             $AMI_ID" \
    "IP pública:      $PUBLIC_IP" \
    "URL WEB:         http://$PUBLIC_IP" \
    "Recursos:        $ENV_FILE" \
    "=================================================="

# El User Data puede seguir ejecutándose después del status check.
echo "Esperando a que Apache termine de instalarse y responda..."
WEB_OK=0
for ((ATTEMPT=1; ATTEMPT<=30; ATTEMPT++)); do
    if curl -fsS --max-time 5 "http://$PUBLIC_IP/" >/dev/null 2>&1; then
        WEB_OK=1
        break
    fi
    sleep 10
done

if [[ "$WEB_OK" -eq 1 ]]; then
    echo "OK: Apache responde correctamente. Contenido devuelto:"
    curl -fsS "http://$PUBLIC_IP/"
else
    echo "AVISO: La instancia se ha creado, pero Apache todavía no responde desde este equipo."
    echo "Comprueba desde EC2 que el User Data ha terminado:"
    echo "  sudo cat /var/log/user-data-reto.log"
    echo "Comprueba también que el Security Group permite TCP 80 y que la ruta 0.0.0.0/0 apunta al IGW."
fi

echo
echo "Despliegue finalizado. Los identificadores se han guardado en $ENV_FILE."
