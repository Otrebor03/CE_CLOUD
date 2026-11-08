#!/bin/bash
# Lanza una instancia EC2 con Webmin desde la plantilla predeterminada.
# Uso: ./lanza_webmin.sh NOMBRE_INSTANCIA
set -e
# 1. Comprobar que se recibe el nombre
if [ "$#" -ne 1 ]; then
    echo "Uso: $0 NOMBRE_INSTANCIA"
    exit 1
fi
NOMBRE="$1"
REGION="us-east-1"
PLANTILLA="LaunchTemplateName=webmin-rrc-template,Version=\$Default"
# 2. Definir las etiquetas de la instancia
ETIQUETAS="ResourceType=instance,Tags=[{Key=Name,Value=$NOMBRE},{Key=Aplicacion,Value=Webmin},{Key=Propietario,Value=Roberto Ripoll},{Key=Proyecto,Value=UD01}]"
echo "Lanzando instancia $NOMBRE..."
# 3. Crear la instancia
ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --launch-template "$PLANTILLA" \
    --tag-specifications "$ETIQUETAS" \
    --query "Instances[0].InstanceId" \
    --output text)
echo "Instancia creada: $ID"
# 4. Esperar a que esté en ejecución
echo "Esperando a que la instancia esté en ejecución..."
aws ec2 wait instance-running \
    --region "$REGION" \
    --instance-ids "$ID"
echo "Instancia en ejecución."
# 5. Obtener la IP pública
IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$ID" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)
if [ "$IP" = "None" ] || [ -z "$IP" ]; then
    echo "ERROR: La instancia no tiene IP pública."
    exit 1
fi
echo "IP pública: $IP"
# 6. Esperar a que Webmin responda
echo "Esperando a que Webmin esté disponible..."
INTENTOS=0
MAX_INTENTOS=60
while [ "$INTENTOS" -lt "$MAX_INTENTOS" ]; do
    if curl -k -sS --connect-timeout 5 --max-time 10 \
        "https://$IP:10000" -o /dev/null; then
        break
    fi
    INTENTOS=$((INTENTOS + 1))
    echo "Webmin todavía no está disponible ($INTENTOS/$MAX_INTENTOS)..."
    sleep 10
done
# 7. Mostrar la URL
if [ "$INTENTOS" -eq "$MAX_INTENTOS" ]; then
    echo "ERROR: Webmin no ha respondido dentro del tiempo esperado."
    exit 1
fi
echo ""
echo "Webmin está disponible."
echo "Instancia: $NOMBRE"
echo "ID: $ID"
echo "URL: https://$IP:10000"