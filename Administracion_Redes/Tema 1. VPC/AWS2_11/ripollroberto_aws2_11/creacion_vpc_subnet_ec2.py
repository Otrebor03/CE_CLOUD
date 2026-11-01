
# Autor: Roberto Ripoll Cones

import boto3

def obtener_vpc_id(vpc):
    return vpc['Vpc']['VpcId']

def crear_vpc(ec2):
    return ec2.create_vpc(
        CidrBlock='172.16.0.0/16',
        TagSpecifications=[
            {
                'ResourceType': 'vpc',
                'Tags': [
                    {'Key': 'Name', 'Value': 'VPC-RRC-Python'},
                    {'Key': 'Owner', 'Value': 'Roberto Ripoll Cones'},
                    {'Key': 'tipo', 'Value': 'prueba'}
                    ]
            }
        ],
        InstanceTenancy='default')
                          
def crear_cliente_ec2():
    return boto3.client('ec2', region_name='us-east-1')

def crear_subred(ec2, vpc_id, cidrBlock, name):
    subred = ec2.create_subnet(
        VpcId=vpc_id,
        CidrBlock=cidrBlock,
        TagSpecifications=[
            {
                'ResourceType': 'subnet',
                'Tags': [
                    {'Key': 'Name', 'Value': name},
                    {'Key': 'Owner', 'Value': 'Roberto Ripoll Cones'},
                    {'Key': 'tipo', 'Value': 'prueba'}
                ]
            }
        ])
    return subred

def obtener_subred_id(subred):
    return subred['Subnet']['SubnetId']

def crear_grupo_seguridad(ec2, vpc_id):
    grupo = ec2.create_security_group(
        GroupName='SG-RRC-Python',
        Description='Grupo de seguridad para la instancia EC2',
        VpcId=vpc_id,
        TagSpecifications=[
            {
                'ResourceType': 'security-group',
                'Tags': [
                    {'Key': 'Name', 'Value': 'SG-RRC-Python'},
                    {'Key': 'Owner', 'Value': 'Roberto Ripoll Cones'},
                    {'Key': 'tipo', 'Value': 'prueba'}
                ]
            }
        ]
    )

    habilitar_reglas_grupo_seguridad(ec2, obtener_grupo_seguridad_id(grupo))

    return grupo

def habilitar_ip_publica_subred(ec2, subred_id):
    ec2.modify_subnet_attribute(
        SubnetId=subred_id,
        MapPublicIpOnLaunch={'Value': True}
    )


def obtener_grupo_seguridad_id(grupo):
    return grupo['GroupId']

def habilitar_reglas_grupo_seguridad(ec2, grupo_id):
    ec2.authorize_security_group_ingress(
        GroupId=grupo_id,
        IpPermissions=[
            {
                'IpProtocol': 'tcp',
                'FromPort': 22,
                'ToPort': 22,
                'IpRanges': [{'CidrIp': '0.0.0.0/0'}]
            },
            {
                'IpProtocol': 'icmp',
                'FromPort': -1,
                'ToPort': -1,
                'IpRanges': [{'CidrIp': '0.0.0.0/0'}]
            }
        ]
    )

def obtener_propiedades_grupo_seguridad(ec2, grupo_id):
    return ec2.describe_security_groups(GroupIds=[grupo_id])['SecurityGroups'][0]

def crear_tablas_enrutamiento(ec2, vpc_id, name):
    tabla = ec2.create_route_table(
        VpcId=vpc_id,
        TagSpecifications=[
            {
                'ResourceType': 'route-table',
                'Tags': [
                    {'Key': 'Name', 'Value': name},
                    {'Key': 'Owner', 'Value': 'Roberto Ripoll Cones'},
                    {'Key': 'tipo', 'Value': 'prueba'}
                ]
            }
        ]
    )

    return tabla

def obtener_tabla_enrutamiento_id(tabla):
    return tabla['RouteTable']['RouteTableId']

def asociar_subred_a_tabla_enrutamiento(ec2, subred_id, tabla_id):
    respuesta = ec2.associate_route_table(
        RouteTableId=tabla_id,
        SubnetId=subred_id
    )

    asociacion_id = respuesta['AssociationId']

    print(f"Subred {subred_id} asociada a la tabla {tabla_id}")

    return asociacion_id


def desasociar_subred_de_tabla_enrutamiento(ec2, asociacion_id):
    ec2.disassociate_route_table(
        AssociationId=asociacion_id
    )

    print(f"Asociación {asociacion_id} eliminada")



def crear_gateway_internet(ec2, vpc_id):
    gateway = ec2.create_internet_gateway(
        TagSpecifications=[
            {
                'ResourceType': 'internet-gateway',
                'Tags': [
                    {'Key': 'Name', 'Value': 'IGW-RRC-Python'},
                    {'Key': 'Owner', 'Value': 'Roberto Ripoll Cones'},
                    {'Key': 'tipo', 'Value': 'prueba'}
                ]
            }
        ]
    )

    asociar_gateway_internet_a_vpc(ec2, obtener_gateway_internet_id(gateway), vpc_id)

    return gateway

def obtener_gateway_internet_id(gateway):
    return gateway['InternetGateway']['InternetGatewayId']

def asociar_gateway_internet_a_vpc(ec2, gateway_id, vpc_id):
    ec2.attach_internet_gateway(
        InternetGatewayId=gateway_id,
        VpcId=vpc_id
    )
    print(f"Gateway de Internet {gateway_id} asociado a la VPC {vpc_id}")

def crear_ruta_hacia_gateway_internet(ec2, tabla_id, gateway_id):
    ec2.create_route(
        RouteTableId=tabla_id,
        DestinationCidrBlock='0.0.0.0/0',
        GatewayId=gateway_id
    )
    print(f"Ruta creada hacia el Gateway de Internet {gateway_id}")

def crear_instancia(ec2, subred_id, grupo_id, ip_privada):
    instancia = ec2.run_instances(
        ImageId='ami-0866a3c8686eaeeba',
        MinCount=1,
        MaxCount=1,
        InstanceType='t2.micro',
        KeyName='vockey',
        SubnetId=subred_id,
        SecurityGroupIds=[grupo_id],
        PrivateIpAddress=ip_privada,
        TagSpecifications=[
            {
                'ResourceType': 'instance',
                'Tags': [
                    {'Key': 'Name', 'Value': 'EC2-RRC-Python'},
                    {'Key': 'Owner', 'Value': 'Roberto Ripoll Cones'},
                    {'Key': 'tipo', 'Value': 'prueba'}
                ]
            }
        ]
    )

    return instancia['Instances'][0]['InstanceId']

def obtener_ip_instancia(ec2, instancia_id):
    ec2.get_waiter('instance_running').wait(
        InstanceIds=[instancia_id]
    )

    respuesta = ec2.describe_instances(
        InstanceIds=[instancia_id]
    )

    instancia = respuesta['Reservations'][0]['Instances'][0]

    ip_privada = instancia['PrivateIpAddress']
    ip_publica = instancia.get('PublicIpAddress')

    return ip_privada, ip_publica

def desasociar_gateway_internet_de_vpc(ec2, gateway_id, vpc_id):
    ec2.detach_internet_gateway(
        InternetGatewayId=gateway_id,
        VpcId=vpc_id
    )

    print(f"Gateway de Internet {gateway_id} desasociado de la VPC {vpc_id}")

def comprobar_tabla_enrutamiento(ec2, tabla_id):
    respuesta = ec2.describe_route_tables(
        RouteTableIds=[tabla_id]
    )

    tabla = respuesta['RouteTables'][0]

    print("\n--- RUTAS DE LA TABLA ---")

    for ruta in tabla['Routes']:
        destino = ruta.get('DestinationCidrBlock', 'N/A')
        gateway = ruta.get('GatewayId', 'Local')
        estado = ruta.get('State', 'N/A')

        print(f"Destino: {destino} | Gateway: {gateway} | Estado: {estado}")

    print("\n--- ASOCIACIONES ---")

    for asociacion in tabla['Associations']:
        print(asociacion)


def preparar_instancias_para_separar_igw(
    ec2, instancias, subredes
):
    # Evitar que las instancias reciban nuevas IP públicas
    for subred_id in subredes:
        ec2.modify_subnet_attribute(
            SubnetId=subred_id,
            MapPublicIpOnLaunch={'Value': False}
        )

    # Detener las instancias para liberar sus IP públicas automáticas
    ec2.stop_instances(InstanceIds=instancias)

    ec2.get_waiter('instance_stopped').wait(
        InstanceIds=instancias
    )

    print("Instancias detenidas y subredes configuradas.")
    print("Las IP públicas automáticas se han liberado.")



if __name__ == "__main__":
    ec2 = crear_cliente_ec2()

    # 1. CREAR VPC Y SUBREDES

    vpc = crear_vpc(ec2)
    vpc_id = obtener_vpc_id(vpc)

    ec2.get_waiter('vpc_available').wait(
        VpcIds=[vpc_id]
    )

    print(f"\nVPC creada: {vpc_id}")

    # Creamos primero la subred 1
    subred = crear_subred(
        ec2, vpc_id, '172.16.0.0/20', 'Subnet-RRC-Python-1'
    )
    subred_id = obtener_subred_id(subred)

    ec2.get_waiter('subnet_available').wait(
        SubnetIds=[subred_id]
    )

    habilitar_ip_publica_subred(ec2, subred_id)

    print(f"Subred 1 creada: {subred_id}")

    # Creamos posteriormente las subredes 2 y 3
    subred2 = crear_subred(
        ec2, vpc_id, '172.16.16.0/20', 'Subnet-RRC-Python-2'
    )
    subred2_id = obtener_subred_id(subred2)

    subred3 = crear_subred(
        ec2, vpc_id, '172.16.32.0/20', 'Subnet-RRC-Python-3'
    )
    subred3_id = obtener_subred_id(subred3)

    ec2.get_waiter('subnet_available').wait(
        SubnetIds=[subred2_id, subred3_id]
    )

    habilitar_ip_publica_subred(ec2, subred2_id)
    habilitar_ip_publica_subred(ec2, subred3_id)

    print(f"Subred 2 creada: {subred2_id}")
    print(f"Subred 3 creada: {subred3_id}")

    # 2. GRUPO DE SEGURIDAD

    grupo = crear_grupo_seguridad(ec2, vpc_id)
    grupo_id = obtener_grupo_seguridad_id(grupo)

    print(f"\nGrupo de seguridad creado: {grupo_id}")

    # 3. TABLA DE ENRUTAMIENTO E IGW

    tabla = crear_tablas_enrutamiento(
        ec2, vpc_id, 'RouteTable-RRC-Python'
    )
    tabla_id = obtener_tabla_enrutamiento_id(tabla)

    print(f"Tabla de enrutamiento creada: {tabla_id}")

    # Asociamos inicialmente las subredes 1 y 2.
    # La subred 3 queda sin asociar a esta tabla personalizada.
    asociacion1 = asociar_subred_a_tabla_enrutamiento(
        ec2, subred_id, tabla_id
    )

    asociacion2 = asociar_subred_a_tabla_enrutamiento(
        ec2, subred2_id, tabla_id
    )

    # Creamos y asociamos el Internet Gateway
    gateway = crear_gateway_internet(ec2, vpc_id)
    gateway_id = obtener_gateway_internet_id(gateway)

    crear_ruta_hacia_gateway_internet(
        ec2, tabla_id, gateway_id
    )

    comprobar_tabla_enrutamiento(ec2, tabla_id)

    # 4. CREAR LAS INSTANCIAS EC2

    instancia1 = crear_instancia(
        ec2, subred_id, grupo_id, '172.16.0.100'
    )

    instancia3 = crear_instancia(
        ec2, subred3_id, grupo_id, '172.16.32.100'
    )

    ip_privada1, ip_publica1 = obtener_ip_instancia(
        ec2, instancia1
    )

    ip_privada3, ip_publica3 = obtener_ip_instancia(
        ec2, instancia3
    )

    print("\n--- INSTANCIA 1 ---")
    print(f"ID: {instancia1}")
    print(f"IP privada: {ip_privada1}")
    print(f"IP pública: {ip_publica1}")

    print("\n--- INSTANCIA 3 ---")
    print(f"ID: {instancia3}")
    print(f"IP privada: {ip_privada3}")
    print(f"IP pública: {ip_publica3}")

    # PRUEBA 1. ASOCIAR LA SUBRED 3 Y CONECTARSE POR SSH

    input(
        "\nPRUEBA 1: Pulsa ENTER cuando estés preparado "
        "para asociar la subred 3 a la tabla personalizada..."
    )

    asociacion3 = asociar_subred_a_tabla_enrutamiento(
        ec2, subred3_id, tabla_id
    )

    comprobar_tabla_enrutamiento(ec2, tabla_id)

    input(
        "\nConéctate por SSH a la instancia 3 desde OTRA "
        "terminal. Cuando tengas la sesión SSH abierta, "
        "vuelve aquí y pulsa ENTER para desasociar la subred."
    )

    # PRUEBA 2. DESASOCIAR LA SUBRED EN CALIENTE

    desasociar_subred_de_tabla_enrutamiento(
        ec2, asociacion3
    )

    comprobar_tabla_enrutamiento(ec2, tabla_id)

    input(
        "\nComprueba qué ocurre con la sesión SSH abierta. "
        "Cuando termines, pulsa ENTER para continuar."
    )

    # PRUEBA 3. SUBRED SIN ASOCIACIÓN A LA TABLA PERSONALIZADA

    print(
        "\nPRUEBA 3: La subred 3 no está asociada a la "
        "tabla personalizada."
    )
    print(
        "Comprueba que no puedes abrir una NUEVA conexión "
        "SSH desde Internet."
    )

    input(
        "Cuando hayas realizado la prueba, pulsa ENTER "
        "para continuar."
    )

    # PRUEBA 4. VOLVER A ASOCIAR Y SEPARAR EL IGW

    asociacion3 = asociar_subred_a_tabla_enrutamiento(
        ec2, subred3_id, tabla_id
    )

    comprobar_tabla_enrutamiento(ec2, tabla_id)

    input(
        "\nPRUEBA 4: Abre una nueva sesión SSH a la instancia 3 "
        "y déjala abierta. Después vuelve aquí y pulsa ENTER "
        "para separar el Internet Gateway."
    )

    
    # Detener las instancias y liberar las IP públicas
    # antes de separar el Internet Gateway.

    preparar_instancias_para_separar_igw(
        ec2,
        [instancia1, instancia3],
        [subred_id, subred2_id, subred3_id]
    )

    # Separar el Internet Gateway
    desasociar_gateway_internet_de_vpc(
        ec2, gateway_id, vpc_id
    )

    comprobar_tabla_enrutamiento(ec2, tabla_id)

    print(
        "\nPRUEBA 4: El IGW está separado. "
        "Las instancias están detenidas y no tienen "
        "IP pública automática al arrancar."
    )

    input(
        "Pulsa ENTER para volver a asociar el IGW..."
    )

    # Volver a asociar el IGW
    asociar_gateway_internet_a_vpc(
        ec2, gateway_id, vpc_id
    )

    # Restaurar la asignación automática de IP pública
    for subred_id_actual in [
        subred_id, subred2_id, subred3_id
    ]:
        ec2.modify_subnet_attribute(
            SubnetId=subred_id_actual,
            MapPublicIpOnLaunch={'Value': True}
        )

    # Arrancar las instancias
    ec2.start_instances(
        InstanceIds=[instancia1, instancia3]
    )

    ec2.get_waiter('instance_running').wait(
        InstanceIds=[instancia1, instancia3]
    )

    # Consultar las nuevas IP públicas
    ip_privada1, ip_publica1 = obtener_ip_instancia(
        ec2, instancia1
    )

    ip_privada3, ip_publica3 = obtener_ip_instancia(
        ec2, instancia3
    )

    print(f"\nNueva IP pública EC2 1: {ip_publica1}")
    print(f"Nueva IP pública EC2 3: {ip_publica3}")

    comprobar_tabla_enrutamiento(ec2, tabla_id)



    






