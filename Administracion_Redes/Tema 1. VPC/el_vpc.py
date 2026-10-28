import boto3

def cliente_ec2():
    return boto3.client('ec2')

def obtener_vpcs(ec2):
    vpcs = ec2.describe_vpcs()
    return vpcs['Vpcs']

def obtener_subredes(ec2, vpc_id):
    subnets = ec2.describe_subnets(Filters=[{'Name': 'vpc-id', 'Values': [vpc_id]}])
    return subnets['Subnets']

def obtener_instancias(ec2, subnet_id):
    instances = ec2.describe_instances(Filters=[{'Name': 'subnet-id', 'Values': [subnet_id]}])
    return instances['Reservations']

def obtener_interfaces_red(ec2, subnet_id):
    interfaces = ec2.describe_network_interfaces(Filters=[{'Name': 'subnet-id', 'Values': [subnet_id]}])
    return interfaces['NetworkInterfaces']

def obtener_grupos_seguridad_vpc(ec2, vpc_id):
    security_groups = ec2.describe_security_groups(Filters=[{'Name': 'vpc-id', 'Values': [vpc_id]}])
    return security_groups['SecurityGroups']

def obterner_instancias_vpc(ec2, vpc_id):
    instances = ec2.describe_instances(Filters=[{'Name': 'vpc-id', 'Values': [vpc_id]}])
    return instances['Reservations']

def borrar_subred(ec2, subnet_id):
    ec2.delete_subnet(SubnetId=subnet_id)

def borrar_interfaz_red(ec2, interface_id):
    ec2.delete_network_interface(NetworkInterfaceId=interface_id)

def borrar_vpc(ec2, vpc_id):
    ec2.delete_vpc(VpcId=vpc_id)

def parar_instancia(ec2, instance_id):
    ec2.stop_instances(InstanceIds=[instance_id])

def borrar_instancia(ec2, instance_id):
    ec2.terminate_instances(InstanceIds=[instance_id])

def borrar_grupo_seguridad(ec2, security_group_id):
    ec2.delete_security_group(GroupId=security_group_id)

def borrar_gateway_internet(ec2, internet_gateway_id):
    ec2.delete_internet_gateway(InternetGatewayId=internet_gateway_id)



if __name__ == "__main__":
    ec2 = cliente_ec2()

    # Obtener todas las VPCs
    vpcs = obtener_vpcs(ec2)
    print("Se borraran las siguientes VPC")
    for vpc in vpcs:
        print(f"ID: {vpc['VpcId']}, CIDR: {vpc['CidrBlock']}")

    # Borrar VPCs y sus subredes
    for vpc in vpcs:
        vpc_id = vpc['VpcId']
        subnets = obtener_subredes(ec2, vpc_id)
        for subnet in subnets:
            interfaces = obtener_interfaces_red(ec2, subnet['SubnetId'])
            for interface in interfaces:

                parar_instancia(ec2, interface['Attachment']['InstanceId'])
                print(f"Se ha detenido la instancia con ID: {interface['Attachment']['InstanceId']} asociada a la interfaz de red: {interface['NetworkInterfaceId']}")

                borrar_instancia(ec2, interface['Attachment']['InstanceId'])
                print(f"Se ha borrado la instancia con ID: {interface['Attachment']['InstanceId']} asociada a la interfaz de red: {interface['NetworkInterfaceId']}")

                borrar_grupo_seguridad(ec2, interface['Groups'][0]['GroupId'])
                print(f"Se ha borrado el grupo de seguridad con ID: {interface['Groups'][0]['GroupId']} asociado a la interfaz de red: {interface['NetworkInterfaceId']}")

                # borrar_gateway_internet(ec2, interface['Attachment']['InstanceId'])
                # print(f"Se ha borrado el gateway de internet asociado a la instancia con ID: {interface['Attachment']['InstanceId']}")
                
                print(f"Se borrara la interfaz de red con ID: {interface['NetworkInterfaceId']} en la Subred: {subnet['SubnetId']}")
                borrar_interfaz_red(ec2, interface['NetworkInterfaceId'])

            borrar_grupo_seguridad(ec2, subnet['SubnetId'])
            print(f"Se borrara el grupo de seguridad asociado a la Subred: {subnet['SubnetId']}")

            print(f"Se borrara la subred con ID: {subnet['SubnetId']} y CIDR: {subnet['CidrBlock']}")
            borrar_subred(ec2, subnet['SubnetId'])

        for sg in obtener_grupos_seguridad_vpc(ec2, vpc_id):
            if sg['GroupName'] != 'default': 
                print(f"Se borrara el grupo de seguridad con ID: {sg['GroupId']} en la VPC: {vpc_id}")
                borrar_grupo_seguridad(ec2, sg['GroupId'])

        for instance in obterner_instancias_vpc(ec2, vpc_id):
            for inst in instance['Instances']:
                print(f"Se borrara la instancia con ID: {inst['InstanceId']} en la VPC: {vpc_id}")
                borrar_instancia(ec2, inst['InstanceId'])

        print(f"Se borrara la VPC con ID: {vpc_id} y CIDR: {vpc['CidrBlock']}")
        borrar_vpc(ec2, vpc_id)