#!/usr/bin/env bash
# cambia_tipo_ec2.sh - Cambia el tipo de una instancia EC2
# Autor: Roberto Ripoll (rr)
# Fecha: 25/10/2026
# Uso: cambia_tipo_ec2.sh [-y] ID_INSTANCIA TIPO_NUEVO

set -uo pipefail
export AWS_PAGER=""   # sin paginador: el script no se detiene

# Solo se modifican las instancias con esta etiqueta Propietario
PROPIETARIO="rr"

I="Reservations[0].Instances[0]"

error() {
    echo "ERROR: $1" >&2
    exit "$2"
}

uso() {
    echo "Uso: $(basename "$0") [-y] ID_INSTANCIA TIPO_NUEVO" >&2
    exit 1
}

# 1. Opciones y parámetros (código 1, Uso incorrecto: número de parámetros u opción desconocida.)
CONFIRMAR="si"
while getopts ":y" OPC; do
    case "$OPC" in
        y) CONFIRMAR="no" ;;
        *) uso ;;
    esac
done
shift $((OPTIND - 1))

[ "$#" -eq 2 ] || uso

ID="$1"
TIPO_NUEVO="$2"

# 2. Una sola llamada: estado, tipo, propietario y nombre
DATOS=$(aws ec2 describe-instances --instance-ids "$ID" --output text \
    --query "$I.[State.Name,InstanceType,Tags[?Key=='Propietario'].Value|[0],Tags[?Key=='Name'].Value|[0]]" \
    2>/dev/null) \
    || error "La instancia $ID no existe o no es accesible" 2

IFS=$'\t' read -r ESTADO TIPO_ACTUAL PROPIETARIO_ACTUAL NOMBRE <<< "$DATOS"

# 3. Comprobaciones previas (propietario, estado, tipo y tamaño)
[ "$PROPIETARIO_ACTUAL" = "$PROPIETARIO" ] \
    || error "La instancia $ID no tiene la etiqueta Propietario=$PROPIETARIO" 3

case "$ESTADO" in
    terminated|shutting-down)
        error "La instancia $ID está en estado $ESTADO" 4 ;;
    running|stopped) ;;
    *)
        error "La instancia $ID está en estado transitorio ($ESTADO): inténtalo más tarde" 7 ;;
esac

if [ "$TIPO_NUEVO" = "$TIPO_ACTUAL" ]; then
    echo "La instancia $ID ya es de tipo $TIPO_ACTUAL: no hay nada que hacer."
    exit 0
fi

aws ec2 describe-instance-types --instance-types "$TIPO_NUEVO" \
    >/dev/null 2>&1 \
    || error "El tipo $TIPO_NUEVO no existe" 5

TAMANO="${TIPO_NUEVO#*.}"
case "$TAMANO" in
    nano|micro|small|medium|large) ;;
    *) error "El tamaño '$TAMANO' no está permitido en el Learner Lab (solo nano, micro, small, medium, large)" 5 ;;
esac

# Confirmación
echo "Resumen:"
echo "  ID:           $ID"
echo "  Nombre:       $NOMBRE"
echo "  Estado:       $ESTADO"
echo "  Tipo actual:  $TIPO_ACTUAL"
echo "  Tipo nuevo:   $TIPO_NUEVO"

if [ "$CONFIRMAR" = "si" ]; then
    if [ "$ESTADO" = "running" ]; then
        echo "AVISO: la instancia se DETENDRÁ para cambiar el tipo y se volverá a arrancar."
    fi
    RESPUESTA=""
    read -r -p "¿Continuar? (s/n): " RESPUESTA
    if [ "$RESPUESTA" != "s" ]; then
        echo "Cancelado por el usuario. No se ha cambiado nada."
        exit 6
    fi
fi

SECONDS=0

# 4. Cambio (cualquier fallo de AWS -> código 7)
if [ "$ESTADO" = "running" ]; then
    echo "Deteniendo la instancia..."
    aws ec2 stop-instances --instance-ids "$ID" >/dev/null \
        || error "No se pudo detener la instancia" 7
    aws ec2 wait instance-stopped --instance-ids "$ID" \
        || error "La instancia no llegó al estado stopped" 7
fi

echo "Cambiando el tipo a $TIPO_NUEVO..."
aws ec2 modify-instance-attribute --instance-id "$ID" \
    --instance-type "{\"Value\": \"$TIPO_NUEVO\"}" \
    || error "No se pudo cambiar el tipo de instancia" 7

if [ "$ESTADO" = "running" ]; then
    echo "Arrancando la instancia..."
    if ! { aws ec2 start-instances --instance-ids "$ID" >/dev/null \
           && aws ec2 wait instance-running --instance-ids "$ID"; }; then
        # Segunda red de seguridad: restaurar el tipo original
        echo "Fallo al arrancar con $TIPO_NUEVO: restaurando $TIPO_ACTUAL..." >&2
        ESTADO_FALLO=$(aws ec2 describe-instances --instance-ids "$ID" \
            --output text --query "$I.State.Name" 2>/dev/null)
        [ "$ESTADO_FALLO" != "terminated" ] \
            || error "La instancia ha sido terminada y no se puede restaurar" 7
        aws ec2 wait instance-stopped --instance-ids "$ID" \
            || error "No se pudo restaurar: la instancia no llegó a stopped" 7
        aws ec2 modify-instance-attribute --instance-id "$ID" \
            --instance-type "{\"Value\": \"$TIPO_ACTUAL\"}" \
            || error "No se pudo restaurar el tipo $TIPO_ACTUAL" 7
        aws ec2 start-instances --instance-ids "$ID" >/dev/null \
            && aws ec2 wait instance-running --instance-ids "$ID" \
            || error "Tipo $TIPO_ACTUAL restaurado, pero no se pudo volver a arrancar" 7
        error "No se pudo arrancar con $TIPO_NUEVO; instancia restaurada a $TIPO_ACTUAL" 7
    fi
fi

# 5. Verificación real
FINAL=$(aws ec2 describe-instances --instance-ids "$ID" --output text \
    --query "$I.[State.Name,InstanceType]" 2>/dev/null) \
    || error "No se pudo verificar el resultado final" 7

read -r ESTADO_FINAL TIPO_FINAL <<< "$FINAL"

echo "Estado final: $ESTADO_FINAL"
echo "Tipo final:   $TIPO_FINAL"

[ "$TIPO_FINAL" = "$TIPO_NUEVO" ] \
    || error "El tipo final ($TIPO_FINAL) no coincide con el solicitado ($TIPO_NUEVO)" 7
[ "$ESTADO_FINAL" = "$ESTADO" ] \
    || error "El estado final ($ESTADO_FINAL) no coincide con el inicial ($ESTADO)" 7

echo "Cambio completado y verificado. Tiempo total: ${SECONDS}s"
exit 0