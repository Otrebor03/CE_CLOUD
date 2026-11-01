
#!/bin/bash

# Autor: Roberto Ripoll Cones
# Eliminar VPC y recursos asociados con etiqueta tipo=prueba

set -e


# CONFIGURACIÓN


REGION="us-east-1"
OWNER="Roberto Ripoll Cones"
TIPO="prueba"

# Nombre utilizado en el script Bash de creación
IGW_NAME="IGW-RRC-Bash"

export AWS_DEFAULT_REGION="$REGION"



# CONTROL DE ERRORES


trap 'echo ""; echo "ERROR: Ha fallado un comando en la línea $LINENO."; echo "La eliminación se ha detenido. Comprueba el recurso que ha producido el error."' ERR



# 1. BUSCAR VPCS CON LA ETIQUETA TIPO=PRUEBA


obtener_vpcs_prueba() {

    aws ec2 describe-vpcs \
        --filters "Name=tag:tipo,Values=$TIPO" \
        --query 'Vpcs[].VpcId' \
        --output text
}


obtener_nombre_recurso() {

    local vpc_id="$1"

    local nombre

    nombre=$(aws ec2 describe-vpcs \
        --vpc-ids "$vpc_id" \
        --query "Vpcs[0].Tags[?Key=='Name'].Value | [0]" \
        --output text)

    if [[ "$nombre" == "None" || -z "$nombre" ]]; then
        nombre="Sin nombre"
    fi

    echo "$nombre"
}



# 2. TERMINAR INSTANCIAS EC2


terminar_instancias() {

    local vpc_id="$1"

    echo ""
    echo "Buscando instancias EC2 de la VPC $vpc_id..."

    local instancias_esperar
    local instancias_terminar

    # Obtener instancias que todavía no estén terminadas

    instancias_esperar=$(aws ec2 describe-instances \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query "Reservations[].Instances[?State.Name!='terminated'].InstanceId[]" \
        --output text)

    # Obtener instancias que todavía necesitan recibir terminate

    instancias_terminar=$(aws ec2 describe-instances \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query "Reservations[].Instances[?State.Name!='terminated' && State.Name!='shutting-down'].InstanceId[]" \
        --output text)

    if [[ -n "$instancias_terminar" && "$instancias_terminar" != "None" ]]; then

        aws ec2 terminate-instances \
            --instance-ids $instancias_terminar

        echo "Instancias terminadas: $instancias_terminar"

    fi

    if [[ -n "$instancias_esperar" && "$instancias_esperar" != "None" ]]; then

        aws ec2 wait instance-terminated \
            --instance-ids $instancias_esperar

        echo "Todas las instancias han terminado correctamente."

    else

        echo "No hay instancias EC2 que terminar."

    fi

}



# 3. ELIMINAR GRUPOS DE SEGURIDAD


eliminar_grupos_seguridad() {

    local vpc_id="$1"

    echo ""
    echo "Buscando grupos de seguridad..."

    local grupos

    grupos=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" \
        --output text)

    if [[ -z "$grupos" || "$grupos" == "None" ]]; then

        echo "No hay grupos de seguridad personalizados."

        return

    fi

    for grupo_id in $grupos; do

        aws ec2 delete-security-group \
            --group-id "$grupo_id"

        echo "Grupo de seguridad $grupo_id eliminado."

    done

}



# 4. ELIMINAR SUBREDES


eliminar_subredes() {

    local vpc_id="$1"

    echo ""
    echo "Buscando subredes..."

    local subredes

    subredes=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'Subnets[].SubnetId' \
        --output text)

    if [[ -z "$subredes" || "$subredes" == "None" ]]; then

        echo "No hay subredes que eliminar."

        return

    fi

    for subred_id in $subredes; do

        aws ec2 delete-subnet \
            --subnet-id "$subred_id"

        echo "Subred $subred_id eliminada."

    done

}



# 5. ELIMINAR TABLAS DE ENRUTAMIENTO


# 5. ELIMINAR TABLAS DE ENRUTAMIENTO

eliminar_tablas_enrutamiento() {

    local vpc_id="$1"

    echo ""
    echo "Buscando tablas de enrutamiento..."

    local tablas

    tablas=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'RouteTables[].RouteTableId' \
        --output text)

    if [[ -z "$tablas" || "$tablas" == "None" ]]; then

        echo "No hay tablas de enrutamiento."

        return

    fi

    for tabla_id in $tablas; do

        local principal

        principal=$(aws ec2 describe-route-tables \
            --route-table-ids "$tabla_id" \
            --query 'RouteTables[0].Associations[?Main==`true`].Main | [0]' \
            --output text)

        if [[ "$principal" == "True" ]]; then

            echo "Tabla principal $tabla_id: se conserva."

            continue

        fi

        echo "Eliminando tabla personalizada $tabla_id..."

        local asociaciones

        asociaciones=$(aws ec2 describe-route-tables \
            --route-table-ids "$tabla_id" \
            --query 'RouteTables[0].Associations[?SubnetId!=null].RouteTableAssociationId' \
            --output text)

        if [[ -n "$asociaciones" && "$asociaciones" != "None" ]]; then

            for asociacion_id in $asociaciones; do

                aws ec2 disassociate-route-table \
                    --association-id "$asociacion_id"

                echo "Asociación $asociacion_id eliminada."

            done

        fi

        aws ec2 delete-route-table \
            --route-table-id "$tabla_id"

        echo "Tabla $tabla_id eliminada."

    done

}



# 6. ELIMINAR ACL PERSONALIZADAS


eliminar_acl_personalizadas() {

    local vpc_id="$1"

    echo ""
    echo "Buscando ACL personalizadas..."

    local acls

    acls=$(aws ec2 describe-network-acls \
        --filters \
        "Name=vpc-id,Values=$vpc_id" \
        "Name=default,Values=false" \
        --query 'NetworkAcls[].NetworkAclId' \
        --output text)

    if [[ -z "$acls" || "$acls" == "None" ]]; then

        echo "No hay ACL personalizadas que eliminar."

        return

    fi

    for acl_id in $acls; do

        aws ec2 delete-network-acl \
            --network-acl-id "$acl_id"

        echo "ACL $acl_id eliminada."

    done

}



# 7. DESASOCIAR Y ELIMINAR INTERNET GATEWAY


eliminar_gateway_internet() {

    local vpc_id="$1"

    echo ""
    echo "Buscando Internet Gateway asociados..."

    local gateways

    gateways=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$vpc_id" \
        --query 'InternetGateways[].InternetGatewayId' \
        --output text)

    if [[ -z "$gateways" || "$gateways" == "None" ]]; then

        echo "No hay Internet Gateway asociados."

        return

    fi

    for gateway_id in $gateways; do

        # Desasociar Internet Gateway

        aws ec2 detach-internet-gateway \
            --internet-gateway-id "$gateway_id" \
            --vpc-id "$vpc_id"

        echo "Gateway $gateway_id desasociado de la VPC."

        # Eliminar Internet Gateway

        aws ec2 delete-internet-gateway \
            --internet-gateway-id "$gateway_id"

        echo "Gateway $gateway_id eliminado."

    done

}

# 8. ELIMINAR INTERFACES DE RED RESTANTES

eliminar_interfaces_red() {

    local vpc_id="$1"

    echo ""
    echo "Buscando interfaces de red restantes..."

    local interfaces

    interfaces=$(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' \
        --output text)

    if [[ -z "$interfaces" || "$interfaces" == "None" ]]; then

        echo "No hay interfaces de red pendientes."

        return

    fi

    for interfaz_id in $interfaces; do

        local administrada
        local estado
        local descripcion

        administrada=$(aws ec2 describe-network-interfaces \
            --network-interface-ids "$interfaz_id" \
            --query 'NetworkInterfaces[0].RequesterManaged' \
            --output text)

        estado=$(aws ec2 describe-network-interfaces \
            --network-interface-ids "$interfaz_id" \
            --query 'NetworkInterfaces[0].Status' \
            --output text)

        descripcion=$(aws ec2 describe-network-interfaces \
            --network-interface-ids "$interfaz_id" \
            --query 'NetworkInterfaces[0].Description' \
            --output text)

        echo "Interfaz: $interfaz_id"
        echo "Estado: $estado"
        echo "Administrada por AWS: $administrada"
        echo "Descripción: $descripcion"

        if [[ "$administrada" == "True" ]]; then

            echo "No se puede eliminar directamente: depende de otro servicio."

        elif [[ "$estado" == "available" ]]; then

            aws ec2 delete-network-interface \
                --network-interface-id "$interfaz_id"

            echo "Interfaz $interfaz_id eliminada."

        else

            echo "La interfaz no está disponible para su eliminación."

        fi

    done

}

# 8. ELIMINAR GATEWAYS QUE YA ESTABAN DESASOCIADOS


eliminar_gateways_desconectados() {

    echo ""
    echo "Buscando Internet Gateway desconectados..."

    local gateways

    gateways=$(aws ec2 describe-internet-gateways \
        --filters \
        "Name=tag:tipo,Values=$TIPO" \
        "Name=tag:Owner,Values=$OWNER" \
        "Name=tag:Name,Values=$IGW_NAME" \
        --query 'InternetGateways[?length(Attachments)==`0`].InternetGatewayId' \
        --output text)

    if [[ -z "$gateways" || "$gateways" == "None" ]]; then

        echo "No hay Internet Gateway desconectados."

        return

    fi

    for gateway_id in $gateways; do

        aws ec2 delete-internet-gateway \
            --internet-gateway-id "$gateway_id"

        echo "Gateway desconectado $gateway_id eliminado."

    done

}



# 9. ELIMINAR VPC


eliminar_vpc() {

    local vpc_id="$1"

    aws ec2 delete-vpc \
        --vpc-id "$vpc_id"

    echo "VPC $vpc_id eliminada correctamente."

}



# 10. ELIMINAR TODOS LOS RECURSOS DE UNA VPC


borrar_vpc_completa() {

    local vpc_id="$1"

    echo ""
    echo "ELIMINANDO VPC $vpc_id"

    terminar_instancias "$vpc_id"

    eliminar_grupos_seguridad "$vpc_id"

    eliminar_subredes "$vpc_id"

    eliminar_tablas_enrutamiento "$vpc_id"

    eliminar_acl_personalizadas "$vpc_id"

    eliminar_gateway_internet "$vpc_id"

    eliminar_interfaces_red "$vpc_id"

    eliminar_vpc "$vpc_id"

    echo ""
    echo "VPC $vpc_id ELIMINADA"
    echo ""

}



# EJECUCIÓN PRINCIPAL



# COMPROBAR CONEXIÓN CON AWS


echo ""
echo "Comprobando configuración de AWS..."

aws sts get-caller-identity > /dev/null

echo "Conexión con AWS correcta."



# BUSCAR VPCS DE PRUEBA


echo ""
echo "Buscando VPC con la etiqueta tipo=prueba..."
echo ""

VPCS=$(obtener_vpcs_prueba)

if [[ -z "$VPCS" || "$VPCS" == "None" ]]; then

    echo "No se han encontrado VPC con la etiqueta tipo=prueba."

    exit 0

fi



# MOSTRAR VPCS ENCONTRADAS


NUM_VPCS=0

for vpc_id in $VPCS; do

    NUM_VPCS=$((NUM_VPCS + 1))

    NOMBRE=$(obtener_nombre_recurso "$vpc_id")

    CIDR=$(aws ec2 describe-vpcs \
        --vpc-ids "$vpc_id" \
        --query 'Vpcs[0].CidrBlock' \
        --output text)

    echo "VPC $NUM_VPCS"
    echo "ID: $vpc_id"
    echo "Nombre: $NOMBRE"
    echo "CIDR: $CIDR"
    echo "----------------------------------------"

done


echo ""
echo "Se han encontrado $NUM_VPCS VPC."



# SOLICITAR CONFIRMACIÓN


read -r -p "
Escribe ELIMINAR para borrar todas estas VPC y sus recursos: " CONFIRMACION


if [[ "$CONFIRMACION" == "ELIMINAR" ]]; then

    # Eliminar todas las VPC encontradas

    for vpc_id in $VPCS; do

        borrar_vpc_completa "$vpc_id"

    done

    # Limpiar Internet Gateway desconectados

    eliminar_gateways_desconectados

    echo ""
    
    echo "TODAS LAS VPC SELECCIONADAS HAN SIDO ELIMINADAS"
    

else

    echo ""
    echo "Operación cancelada."
    echo "No se ha eliminado ninguna VPC."

fi
