# Tarea 1 - CREAR VPC, SUBRED, GRUPO DE SEGURIDAD Y LANZAR INSTANCIA EC2, GateWay tabla de enrutamiento y asociar la subred a la tabla de enrutamiento
# Tarea 2 - BORRAR VPC, SUBRED, GRUPO DE SEGURIDAD Y TERMINAR INSTANCIA EC2
# Autor: Roberto Ripoll Cones

import boto3

def obtener_vpc_id(vpc):
    return vpc['Vpc']['VpcId']

def crear_vpc(ec2):
    return ec2.create_vpc(
        CidrBlock='10.0.0.0/16',
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
                'IpProtocol': 'ICMP',
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

def crear_instancia(ec2, subred_id, grupo_id):
    instancia = ec2.run_instances(
        ImageId='ami-0866a3c8686eaeeba',
        MinCount=1,
        MaxCount=1,
        InstanceType='t2.micro',
        KeyName='vockey',          
        SubnetId=subred_id[0],
        SecurityGroupIds=[grupo_id],
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

if __name__ == "__main__":
    ec2 = crear_cliente_ec2()
    
    vpc = crear_vpc(ec2)
    vpc_id = obtener_vpc_id(vpc)
    print(f" + VPC creada con ID: {vpc_id}")

    subred = crear_subred(ec2, vpc_id, '10.0.1.0/24', 'Subnet-RRC-Python')
    subred_id = obtener_subred_id(subred)
    print(f" + Subnet creada con ID: {subred_id}")

    subred2 = crear_subred(ec2, vpc_id, '10.0.2.0/24', 'Subnet-RRC-Python-2')
    subred2_id = obtener_subred_id(subred2)
    print(f" + Subnet creada con ID: {subred2_id}")

    subred3 = crear_subred(ec2, vpc_id, '10.0.3.0/24', 'Subnet-RRC-Python-3')
    subred3_id = obtener_subred_id(subred3)
    print(f" + Subnet creada con ID: {subred3_id}")

    habilitar_ip_publica_subred(ec2, subred_id)
    habilitar_ip_publica_subred(ec2, subred2_id)

    grupo = crear_grupo_seguridad(ec2, vpc_id)
    grupo_id = obtener_grupo_seguridad_id(grupo)
    print(f" + Grupo de seguridad creado con ID: {grupo_id}")
    propiedades = obtener_propiedades_grupo_seguridad(ec2, grupo_id)
    print(f" + Propiedades del grupo de seguridad: {propiedades}")

    tabla = crear_tablas_enrutamiento(ec2, vpc_id, 'RouteTable-RRC-Python')
    tabla_id = obtener_tabla_enrutamiento_id(tabla)
    print(f" + Tabla de enrutamiento creada con ID: {tabla_id}")

    asociacion1 = asociar_subred_a_tabla_enrutamiento(ec2, subred_id, tabla_id)
    asociacion2 = asociar_subred_a_tabla_enrutamiento(ec2, subred2_id, tabla_id)

    gateway = crear_gateway_internet(ec2, vpc_id)
    gateway_id = obtener_gateway_internet_id(gateway)

    crear_ruta_hacia_gateway_internet(ec2, tabla_id, gateway_id)

    instancia = crear_instancia(ec2, subred_id, grupo_id)
    print("Se ha creado instancia EC2: "+instancia)



    






