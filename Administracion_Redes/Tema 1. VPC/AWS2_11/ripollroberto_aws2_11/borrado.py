# Autor: Roberto Ripoll Cones
# Eliminar VPC y recursos asociados con etiqueta tipo=prueba

import boto3
from botocore.exceptions import ClientError


def crear_cliente_ec2():
    return boto3.client('ec2', region_name='us-east-1')

# 1. BUSCAR VPCS CON LA ETIQUETA TIPO=PRUEBA

def obtener_vpcs_prueba(ec2):
    paginator = ec2.get_paginator('describe_vpcs')

    vpcs = []

    for pagina in paginator.paginate(
        Filters=[
            {
                'Name': 'tag:tipo',
                'Values': ['prueba']
            }
        ]
    ):
        vpcs.extend(pagina['Vpcs'])

    return vpcs


def obtener_nombre_recurso(recurso):
    for etiqueta in recurso.get('Tags', []):
        if etiqueta['Key'] == 'Name':
            return etiqueta['Value']

    return 'Sin nombre'

# 2. TERMINAR INSTANCIAS EC2

def terminar_instancias(ec2, vpc_id):
    respuesta = ec2.describe_instances(
        Filters=[
            {
                'Name': 'vpc-id',
                'Values': [vpc_id]
            }
        ]
    )

    instancias_terminar = []
    instancias_esperar = []

    for reserva in respuesta['Reservations']:
        for instancia in reserva['Instances']:

            instancia_id = instancia['InstanceId']
            estado = instancia['State']['Name']

            if estado != 'terminated':
                instancias_esperar.append(instancia_id)

                if estado != 'shutting-down':
                    instancias_terminar.append(instancia_id)

    if instancias_terminar:
        ec2.terminate_instances(
            InstanceIds=instancias_terminar
        )

        print(f"Instancias terminadas: {instancias_terminar}")

    if instancias_esperar:
        ec2.get_waiter('instance_terminated').wait(
            InstanceIds=instancias_esperar
        )

        print("Todas las instancias han terminado correctamente")

    else:
        print("No hay instancias EC2 que terminar")


# 3. ELIMINAR GRUPOS DE SEGURIDAD

def eliminar_grupos_seguridad(ec2, vpc_id):
    respuesta = ec2.describe_security_groups(
        Filters=[
            {
                'Name': 'vpc-id',
                'Values': [vpc_id]
            }
        ]
    )

    for grupo in respuesta['SecurityGroups']:

        # No eliminamos el grupo de seguridad predeterminado
        if grupo['GroupName'] == 'default':
            continue

        grupo_id = grupo['GroupId']

        ec2.delete_security_group(
            GroupId=grupo_id
        )

        print(f"Grupo de seguridad {grupo_id} eliminado")


# 4. ELIMINAR SUBREDES

def eliminar_subredes(ec2, vpc_id):
    respuesta = ec2.describe_subnets(
        Filters=[
            {
                'Name': 'vpc-id',
                'Values': [vpc_id]
            }
        ]
    )

    for subred in respuesta['Subnets']:

        subred_id = subred['SubnetId']

        ec2.delete_subnet(
            SubnetId=subred_id
        )

        print(f"Subred {subred_id} eliminada")


# 5. ELIMINAR TABLAS DE ENRUTAMIENTO

def eliminar_tablas_enrutamiento(ec2, vpc_id):
    respuesta = ec2.describe_route_tables(
        Filters=[
            {
                'Name': 'vpc-id',
                'Values': [vpc_id]
            }
        ]
    )

    for tabla in respuesta['RouteTables']:

        tabla_id = tabla['RouteTableId']

        # No eliminamos la tabla principal de la VPC
        es_principal = any(
            asociacion.get('Main', False)
            for asociacion in tabla['Associations']
        )

        if es_principal:
            continue

        # Eliminar asociaciones explícitas que todavía existan
        for asociacion in tabla['Associations']:

            asociacion_id = asociacion.get(
                'RouteTableAssociationId'
            )

            if not asociacion.get('Main', False) and asociacion_id:
                ec2.disassociate_route_table(
                    AssociationId=asociacion_id
                )

        ec2.delete_route_table(
            RouteTableId=tabla_id
        )

        print(f"Tabla de enrutamiento {tabla_id} eliminada")


# 6. ELIMINAR ACL PERSONALIZADAS

def eliminar_acl_personalizadas(ec2, vpc_id):
    respuesta = ec2.describe_network_acls(
        Filters=[
            {
                'Name': 'vpc-id',
                'Values': [vpc_id]
            }
        ]
    )

    for acl in respuesta['NetworkAcls']:

        # No eliminamos la ACL predeterminada
        if acl['IsDefault']:
            continue

        acl_id = acl['NetworkAclId']

        ec2.delete_network_acl(
            NetworkAclId=acl_id
        )

        print(f"ACL {acl_id} eliminada")


# 7. DESASOCIAR Y ELIMINAR INTERNET GATEWAY

def eliminar_gateway_internet(ec2, vpc_id):
    respuesta = ec2.describe_internet_gateways(
        Filters=[
            {
                'Name': 'attachment.vpc-id',
                'Values': [vpc_id]
            }
        ]
    )

    for gateway in respuesta['InternetGateways']:

        gateway_id = gateway['InternetGatewayId']

        ec2.detach_internet_gateway(
            InternetGatewayId=gateway_id,
            VpcId=vpc_id
        )

        print(f"Gateway {gateway_id} desasociado de la VPC")

        ec2.delete_internet_gateway(
            InternetGatewayId=gateway_id
        )

        print(f"Gateway {gateway_id} eliminado")


# 8. ELIMINAR GATEWAYS QUE YA ESTABAN DESASOCIADOS

def eliminar_gateways_desconectados(ec2):
    respuesta = ec2.describe_internet_gateways(
        Filters=[
            {
                'Name': 'tag:tipo',
                'Values': ['prueba']
            },
            {
                'Name': 'tag:Owner',
                'Values': ['Roberto Ripoll Cones']
            },
            {
                'Name': 'tag:Name',
                'Values': ['IGW-RRC-Python']
            }
        ]
    )

    for gateway in respuesta['InternetGateways']:

        gateway_id = gateway['InternetGatewayId']

        # Solo eliminamos gateways que no estén asociados a ninguna VPC
        if not gateway['Attachments']:

            ec2.delete_internet_gateway(
                InternetGatewayId=gateway_id
            )

            print(f"Gateway desconectado {gateway_id} eliminado")


# 9. ELIMINAR VPC

def eliminar_vpc(ec2, vpc_id):
    ec2.delete_vpc(
        VpcId=vpc_id
    )

    print(f"VPC {vpc_id} eliminada correctamente")


# 10. ELIMINAR TODOS LOS RECURSOS DE UNA VPC

def borrar_vpc_completa(ec2, vpc_id):

    print(f"\n ELIMINANDO VPC {vpc_id} ")

    terminar_instancias(ec2, vpc_id)

    eliminar_grupos_seguridad(ec2, vpc_id)

    eliminar_subredes(ec2, vpc_id)

    eliminar_tablas_enrutamiento(ec2, vpc_id)

    eliminar_acl_personalizadas(ec2, vpc_id)

    eliminar_gateway_internet(ec2, vpc_id)

    eliminar_vpc(ec2, vpc_id)

    print(f" VPC {vpc_id} ELIMINADA \n")


if __name__ == "__main__":

    ec2 = crear_cliente_ec2()

    print("\nBuscando VPC con la etiqueta tipo=prueba...\n")

    vpcs = obtener_vpcs_prueba(ec2)

    if not vpcs:
        print("No se han encontrado VPC con la etiqueta tipo=prueba")

    else:

        print(f"Se han encontrado {len(vpcs)} VPC:\n")

        for vpc in vpcs:

            print(f"ID: {vpc['VpcId']}")
            print(f"Nombre: {obtener_nombre_recurso(vpc)}")
            print(f"CIDR: {vpc['CidrBlock']}")
            print("-" * 40)

        confirmacion = input(
            "\nEscribe ELIMINAR para borrar todas estas VPC y sus recursos: "
        )

        if confirmacion == 'ELIMINAR':

            try:
                for vpc in vpcs:

                    vpc_id = vpc['VpcId']

                    borrar_vpc_completa(ec2, vpc_id)

                # Limpiar IGW que se hubieran desasociado previamente
                eliminar_gateways_desconectados(ec2)

                print("\nTodas las VPC seleccionadas han sido eliminadas.")

            except ClientError as error:

                print("\nERROR AL ELIMINAR UN RECURSO")

                print(f"Código: {error.response['Error']['Code']}")
                print(f"Descripción: {error.response['Error']['Message']}")

                print(
                    "\nLa eliminación se ha detenido. "
                    "Comprueba el recurso que ha producido el error."
                )

        else:
            print("\nOperación cancelada. No se ha eliminado ninguna VPC.")