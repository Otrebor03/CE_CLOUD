import boto3
from botocore.exceptions import ClientError


# -----------------------------------------------------------------------------
# CONFIGURACION
# -----------------------------------------------------------------------------

REGION = "us-east-1"
AVAILABILITY_ZONE = "us-east-1a"

PROJECT_NAME = "VPC-RRC"

VPC_CIDR = "10.0.0.0/16"
PUBLIC_SUBNET_CIDR = "10.0.1.0/24"
PRIVATE_SUBNET_CIDR = "10.0.2.0/24"

ADMIN_CIDR = "95.120.161.28/32"

INSTANCE_TYPE = "t3.micro"
KEY_NAME = "vockey"
IAM_INSTANCE_PROFILE = "LabInstanceProfile"

AMI_SSM_PARAMETER = (
    "/aws/service/ami-amazon-linux-latest/"
    "al2023-ami-kernel-default-x86_64"
)

TAGS = [
    {"Key": "Proyecto", "Value": PROJECT_NAME},
    {"Key": "Propietario", "Value": "RRC"},
]


# -----------------------------------------------------------------------------
# VPC Y SUBNETS
# -----------------------------------------------------------------------------


def create_vpc(ec2):
    """Crea la VPC y habilita DNS."""
    print("\n[1/8] Creando VPC...")

    response = ec2.create_vpc(CidrBlock=VPC_CIDR)
    vpc_id = response["Vpc"]["VpcId"]

    ec2.create_tags(
        Resources=[vpc_id],
        Tags=TAGS + [{"Key": "Name", "Value": f"{PROJECT_NAME}-VPC"}],
    )

    ec2.modify_vpc_attribute(
        VpcId=vpc_id,
        EnableDnsSupport={"Value": True},
    )
    ec2.modify_vpc_attribute(
        VpcId=vpc_id,
        EnableDnsHostnames={"Value": True},
    )

    ec2.get_waiter("vpc_available").wait(VpcIds=[vpc_id])
    print(f"    VPC creada: {vpc_id}")
    return vpc_id


def create_subnet(ec2, vpc_id, cidr, name, public):
    """Crea una subnet. Si es publica, habilita la asignacion de IP publica."""
    response = ec2.create_subnet(
        VpcId=vpc_id,
        CidrBlock=cidr,
        AvailabilityZone=AVAILABILITY_ZONE,
    )
    subnet_id = response["Subnet"]["SubnetId"]

    ec2.create_tags(
        Resources=[subnet_id],
        Tags=TAGS + [{"Key": "Name", "Value": name}],
    )

    ec2.modify_subnet_attribute(
        SubnetId=subnet_id,
        MapPublicIpOnLaunch={"Value": public},
    )

    ec2.get_waiter("subnet_available").wait(SubnetIds=[subnet_id])
    print(f"    Subnet creada: {name} ({subnet_id})")
    return subnet_id


# -----------------------------------------------------------------------------
# INTERNET GATEWAY Y NAT GATEWAY
# -----------------------------------------------------------------------------


def create_internet_gateway(ec2, vpc_id):
    """Crea un Internet Gateway y lo asocia a la VPC."""
    print("\n[3/8] Creando Internet Gateway...")

    response = ec2.create_internet_gateway(
        TagSpecifications=[
            {"ResourceType": "internet-gateway", "Tags": TAGS}
        ]
    )
    igw_id = response["InternetGateway"]["InternetGatewayId"]

    ec2.attach_internet_gateway(
        InternetGatewayId=igw_id,
        VpcId=vpc_id,
    )

    print(f"    Internet Gateway asociado: {igw_id}")
    return igw_id


def create_nat_gateway(ec2, public_subnet_id):
    """Reserva una Elastic IP y crea una NAT Gateway en la subnet publica."""
    print("\n[6/8] Creando NAT Gateway (puede tardar unos minutos)...")

    address = ec2.allocate_address(Domain="vpc")
    allocation_id = address["AllocationId"]
    nat_eip = address["PublicIp"]

    response = ec2.create_nat_gateway(
        SubnetId=public_subnet_id,
        AllocationId=allocation_id,
        ConnectivityType="public",
        TagSpecifications=[
            {
                "ResourceType": "natgateway",
                "Tags": TAGS + [{"Key": "Name", "Value": f"{PROJECT_NAME}-NAT"}],
            }
        ],
    )
    nat_id = response["NatGateway"]["NatGatewayId"]

    print(f"    NAT Gateway creada: {nat_id}")
    print("    Esperando a que la NAT Gateway este disponible...")

    ec2.get_waiter("nat_gateway_available").wait(
        NatGatewayIds=[nat_id],
        WaiterConfig={"Delay": 15, "MaxAttempts": 40},
    )

    print(f"    NAT Gateway disponible. Elastic IP: {nat_eip}")
    return nat_id, allocation_id, nat_eip


# -----------------------------------------------------------------------------
# SECURITY GROUPS
# -----------------------------------------------------------------------------


def create_security_groups(ec2, vpc_id):
    """Crea los grupos de seguridad para las EC2 publica y privada."""
    print("\n[4/8] Creando Security Groups...")

    public_sg = ec2.create_security_group(
        GroupName=f"{PROJECT_NAME}-SG-Publico",
        Description="SSH desde la IP del administrador e ICMP desde la VPC",
        VpcId=vpc_id,
    )["GroupId"]

    private_sg = ec2.create_security_group(
        GroupName=f"{PROJECT_NAME}-SG-Privado",
        Description="SSH desde la EC2 publica e ICMP desde la VPC",
        VpcId=vpc_id,
    )["GroupId"]

    ec2.create_tags(
        Resources=[public_sg, private_sg],
        Tags=TAGS,
    )

    # EC2 publica: SSH desde la IP del administrador y ping desde la VPC.
    ec2.authorize_security_group_ingress(
        GroupId=public_sg,
        IpPermissions=[
            {
                "IpProtocol": "tcp",
                "FromPort": 22,
                "ToPort": 22,
                "IpRanges": [{"CidrIp": ADMIN_CIDR}],
            },
            {
                "IpProtocol": "icmp",
                "FromPort": -1,
                "ToPort": -1,
                "IpRanges": [{"CidrIp": VPC_CIDR}],
            },
        ],
    )

    # EC2 privada: SSH desde una instancia que tenga asociado el SG publico.
    ec2.authorize_security_group_ingress(
        GroupId=private_sg,
        IpPermissions=[
            {
                "IpProtocol": "tcp",
                "FromPort": 22,
                "ToPort": 22,
                "UserIdGroupPairs": [{"GroupId": public_sg}],
            },
            {
                "IpProtocol": "icmp",
                "FromPort": -1,
                "ToPort": -1,
                "IpRanges": [{"CidrIp": VPC_CIDR}],
            },
        ],
    )

    # Ambos grupos conservan la salida predeterminada de AWS (todo el trafico).
    print(f"    Security Group publico: {public_sg}")
    print(f"    Security Group privado: {private_sg}")
    return public_sg, private_sg


# -----------------------------------------------------------------------------
# TABLAS DE ENRUTAMIENTO
# -----------------------------------------------------------------------------


def create_route_table(ec2, vpc_id, subnet_id, name):
    """Crea una tabla de rutas y la asocia a una subnet."""
    response = ec2.create_route_table(VpcId=vpc_id)
    route_table_id = response["RouteTable"]["RouteTableId"]

    ec2.create_tags(
        Resources=[route_table_id],
        Tags=TAGS + [{"Key": "Name", "Value": name}],
    )

    ec2.associate_route_table(
        RouteTableId=route_table_id,
        SubnetId=subnet_id,
    )
    return route_table_id


def configure_public_route(ec2, vpc_id, public_subnet_id, igw_id):
    """Envia el trafico externo de la subnet publica al Internet Gateway."""
    print("\n[5/8] Configurando tabla de rutas publica...")

    route_table_id = create_route_table(
        ec2,
        vpc_id,
        public_subnet_id,
        f"{PROJECT_NAME}-RT-Publica",
    )

    ec2.create_route(
        RouteTableId=route_table_id,
        DestinationCidrBlock="0.0.0.0/0",
        GatewayId=igw_id,
    )

    print(f"    Ruta publica: 0.0.0.0/0 -> {igw_id}")
    return route_table_id


def configure_private_route(ec2, vpc_id, private_subnet_id, nat_id):
    """Envia el trafico externo de la subnet privada a la NAT Gateway."""
    print("\n[7/8] Configurando tabla de rutas privada...")

    route_table_id = create_route_table(
        ec2,
        vpc_id,
        private_subnet_id,
        f"{PROJECT_NAME}-RT-Privada",
    )

    ec2.create_route(
        RouteTableId=route_table_id,
        DestinationCidrBlock="0.0.0.0/0",
        NatGatewayId=nat_id,
    )

    print(f"    Ruta privada: 0.0.0.0/0 -> {nat_id}")
    return route_table_id


# -----------------------------------------------------------------------------
# EC2 Y PRUEBAS DE CONECTIVIDAD
# -----------------------------------------------------------------------------


def get_latest_ami(ssm):
    """Obtiene la AMI mas reciente de Amazon Linux 2023 para la region."""
    response = ssm.get_parameter(Name=AMI_SSM_PARAMETER)
    return response["Parameter"]["Value"]


def create_user_data(instance_name):
    """Script que se ejecuta al arrancar la EC2 y guarda pruebas de red."""
    return f"""#!/bin/bash
exec > >(tee -a /var/log/connectivity-check.log) 2>&1

 echo '============================================'
 echo 'PRUEBAS DE CONECTIVIDAD: {instance_name}'
 echo '============================================'
 date

 echo '\n[1] Interfaces de red'
 ip -brief address || ip addr

 echo '\n[2] Tabla de rutas'
 ip route

 echo '\n[3] Resolucion DNS'
 getent hosts amazon.com || true

 echo '\n[4] Ping a 1.1.1.1'
 ping -c 4 -W 3 1.1.1.1 || true

 echo '\n[5] Conexion HTTPS a AWS'
 curl -4 -I --connect-timeout 10 --max-time 20 https://aws.amazon.com || true

 echo '\n[6] Direccion IP publica de salida'
 curl -4 --silent --show-error --connect-timeout 10 --max-time 20 https://checkip.amazonaws.com || true

 echo '\nFIN DE LAS PRUEBAS'
"""


def create_instance(ec2, ami_id, subnet_id, security_group_id,
                    instance_name, public_ip):
    """Lanza una EC2 y espera a que pase los chequeos de estado de AWS."""
    print(f"    Creando {instance_name}...")

    network_interface = {
        "DeviceIndex": 0,
        "SubnetId": subnet_id,
        "Groups": [security_group_id],
        "AssociatePublicIpAddress": public_ip,
        "DeleteOnTermination": True,
    }

    params = {
        "ImageId": ami_id,
        "InstanceType": INSTANCE_TYPE,
        "KeyName": KEY_NAME,
        "MinCount": 1,
        "MaxCount": 1,
        "NetworkInterfaces": [network_interface],
        "UserData": create_user_data(instance_name),
        "TagSpecifications": [
            {
                "ResourceType": "instance",
                "Tags": TAGS + [{"Key": "Name", "Value": instance_name}],
            }
        ],
    }

    if IAM_INSTANCE_PROFILE:
        params["IamInstanceProfile"] = {"Name": IAM_INSTANCE_PROFILE}

    response = ec2.run_instances(**params)
    instance_id = response["Instances"][0]["InstanceId"]

    print(f"    Instancia lanzada: {instance_id}")
    ec2.get_waiter("instance_running").wait(InstanceIds=[instance_id])
    ec2.get_waiter("instance_status_ok").wait(
        InstanceIds=[instance_id],
        WaiterConfig={"Delay": 15, "MaxAttempts": 40},
    )

    print(f"    Instancia preparada: {instance_id}")
    return instance_id


def show_instance_information(ec2, public_instance_id, private_instance_id):
    """Muestra las direcciones IP asignadas a las dos instancias."""
    response = ec2.describe_instances(
        InstanceIds=[public_instance_id, private_instance_id]
    )

    print("\n========== INFORMACION DE LAS EC2 ==========")

    for reservation in response["Reservations"]:
        for instance in reservation["Instances"]:
            name = next(
                (tag["Value"] for tag in instance.get("Tags", [])
                 if tag["Key"] == "Name"),
                instance["InstanceId"],
            )

            print(f"\nNombre: {name}")
            print(f"ID: {instance['InstanceId']}")
            print(f"Estado: {instance['State']['Name']}")
            print(f"IP privada: {instance.get('PrivateIpAddress', 'No disponible')}")
            print(f"IP publica: {instance.get('PublicIpAddress', 'No tiene')}")


def main():
    """Crea todos los recursos en el orden necesario."""
    if ADMIN_CIDR == "CAMBIA_ESTO/32":
        raise ValueError("Tienes que configurar ADMIN_CIDR con tu IP publica/32.")

    print("============================================")
    print(" DESPLIEGUE DE VPC CON SUBNET PUBLICA Y PRIVADA")
    print("============================================")

    # Clientes de AWS.
    session = boto3.Session(region_name=REGION)
    ec2 = session.client("ec2")
    ssm = session.client("ssm")

    # 1. Crear VPC.
    vpc_id = create_vpc(ec2)

    # 2. Crear subnet publica y subnet privada.
    print("\n[2/8] Creando subnets...")
    public_subnet_id = create_subnet(
        ec2, vpc_id, PUBLIC_SUBNET_CIDR,
        f"{PROJECT_NAME}-Subnet-Publica", True,
    )
    private_subnet_id = create_subnet(
        ec2, vpc_id, PRIVATE_SUBNET_CIDR,
        f"{PROJECT_NAME}-Subnet-Privada", False,
    )

    # 3. Crear y asociar Internet Gateway.
    igw_id = create_internet_gateway(ec2, vpc_id)

    # 4. Crear Security Groups.
    public_sg, private_sg = create_security_groups(ec2, vpc_id)

    # 5. Configurar la ruta publica hacia Internet.
    public_route_table_id = configure_public_route(
        ec2, vpc_id, public_subnet_id, igw_id
    )

    # 6. Crear NAT Gateway en la subnet publica.
    nat_id, allocation_id, nat_eip = create_nat_gateway(
        ec2, public_subnet_id
    )

    # 7. Configurar la ruta privada hacia la NAT Gateway.
    private_route_table_id = configure_private_route(
        ec2, vpc_id, private_subnet_id, nat_id
    )

    # 8. Obtener AMI y crear las dos EC2.
    print("\n[8/8] Creando instancias EC2...")
    ami_id = get_latest_ami(ssm)
    print(f"    AMI seleccionada: {ami_id}")

    public_instance_id = create_instance(
        ec2, ami_id, public_subnet_id, public_sg,
        f"{PROJECT_NAME}-EC2-Publica", True,
    )
    private_instance_id = create_instance(
        ec2, ami_id, private_subnet_id, private_sg,
        f"{PROJECT_NAME}-EC2-Privada", False,
    )

    # Mostrar el resultado del despliegue.
    show_instance_information(
        ec2, public_instance_id, private_instance_id
    )

    print("\n============= DESPLIEGUE COMPLETADO =============")
    print(f"VPC: {vpc_id}")
    print(f"Internet Gateway: {igw_id}")
    print(f"Tabla de rutas publica: {public_route_table_id}")
    print(f"NAT Gateway: {nat_id}")
    print(f"Elastic IP de la NAT: {nat_eip}")
    print(f"Allocation ID de la Elastic IP: {allocation_id}")
    print(f"Tabla de rutas privada: {private_route_table_id}")
    print("\nPara conectarte a la EC2 publica:")
    print(f"ssh -i .\\{KEY_NAME}.pem ec2-user@IP_PUBLICA")
    print("\nPara conectarte a la EC2 privada desde la publica:")
    print("ssh -i clave.pem ec2-user@IP_PRIVADA")
    print("\nLog de conectividad en cada EC2:")
    print("sudo cat /var/log/connectivity-check.log")
    print("=================================================")


if __name__ == "__main__":
    try:
        main()
    except (ClientError, ValueError) as error:
        print(f"\nERROR: {error}")
        raise SystemExit(1)
