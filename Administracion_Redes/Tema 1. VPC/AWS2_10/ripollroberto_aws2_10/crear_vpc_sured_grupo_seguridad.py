import boto3


REGION = "us-east-1"

VPC_CIDR = "172.16.0.0/16"
SUBNET_CIDR = "172.16.0.0/20"

INSTANCE_TYPE = "t2.micro"
KEY_NAME = "vockey"
IAM_PROFILE = "LabInstanceProfile"

INSTANCE_NAME = "ripoll_roberto"


# Cliente AWS
ec2 = boto3.client("ec2", region_name=REGION)


def create_vpc():

    response = ec2.create_vpc(CidrBlock=VPC_CIDR)

    vpc_id = response["Vpc"]["VpcId"]

    ec2.get_waiter("vpc_available").wait(VpcIds=[vpc_id])

    ec2.create_tags(
        Resources=[vpc_id],
        Tags=[{"Key": "Name", "Value": "VPC_Practica"}]
    )

    print("VPC creada:", vpc_id)

    return vpc_id


def create_subnet(vpc_id):

    response = ec2.create_subnet(
        VpcId=vpc_id,
        CidrBlock=SUBNET_CIDR
    )

    subnet_id = response["Subnet"]["SubnetId"]

    # Asignar IP pública automáticamente
    ec2.modify_subnet_attribute(
        SubnetId=subnet_id,
        MapPublicIpOnLaunch={"Value": True}
    )

    ec2.create_tags(
        Resources=[subnet_id],
        Tags=[{"Key": "Name", "Value": "Subred_Practica"}]
    )

    print("Subred creada:", subnet_id)

    return subnet_id


def create_security_group(vpc_id):

    response = ec2.create_security_group(
        GroupName="SG_Practica",
        Description="Grupo de seguridad para la EC2",
        VpcId=vpc_id
    )

    sg_id = response["GroupId"]

    # Permitir SSH, HTTP y HTTPS
    ec2.authorize_security_group_ingress(
        GroupId=sg_id,
        IpPermissions=[
            {
                "IpProtocol": "tcp",
                "FromPort": 22,
                "ToPort": 22,
                "IpRanges": [{"CidrIp": "0.0.0.0/0"}]
            },
            {
                "IpProtocol": "tcp",
                "FromPort": 80,
                "ToPort": 80,
                "IpRanges": [{"CidrIp": "0.0.0.0/0"}]
            },
            {
                "IpProtocol": "tcp",
                "FromPort": 443,
                "ToPort": 443,
                "IpRanges": [{"CidrIp": "0.0.0.0/0"}]
            },
            {
                "IpProtocol": "icmp",
                "FromPort": 8,
                "ToPort": -1,
                "IpRanges": [{"CidrIp": "0.0.0.0/0"}]
            }
        ]
    )

    print("Grupo de seguridad creado:", sg_id)

    return sg_id


def get_ubuntu_ami():

    response = ec2.describe_images(
        Owners=["099720109477"],
        Filters=[
            {
                "Name": "name",
                "Values": [
                    "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
                ]
            },
            {
                "Name": "state",
                "Values": ["available"]
            }
        ]
    )

    images = response["Images"]

    if not images:
        raise Exception("No se ha encontrado una AMI de Ubuntu 22.04")

    latest_image = sorted(
        images,
        key=lambda image: image["CreationDate"]
    )[-1]

    return latest_image["ImageId"]


def create_instance(subnet_id, sg_id):

    ami_id = get_ubuntu_ami()

    response = ec2.run_instances(
        ImageId=ami_id,
        InstanceType=INSTANCE_TYPE,
        KeyName=KEY_NAME,
        MinCount=1,
        MaxCount=1,

        SubnetId=subnet_id,
        SecurityGroupIds=[sg_id],

        IamInstanceProfile={
            "Name": IAM_PROFILE
        },

        BlockDeviceMappings=[
            {
                "DeviceName": "/dev/sda1",
                "Ebs": {
                    "VolumeSize": 10,
                    "VolumeType": "gp2",
                    "DeleteOnTermination": True
                }
            }
        ],

        TagSpecifications=[
            {
                "ResourceType": "instance",
                "Tags": [
                    {"Key": "Name", "Value": INSTANCE_NAME}
                ]
            }
        ]
    )

    instance_id = response["Instances"][0]["InstanceId"]

    print("Instancia EC2 creada:", instance_id)

    ec2.get_waiter("instance_running").wait(
        InstanceIds=[instance_id]
    )

    instance = ec2.describe_instances(
        InstanceIds=[instance_id]
    )["Reservations"][0]["Instances"][0]

    print("IP pública:", instance.get("PublicIpAddress"))
    print("IP privada:", instance.get("PrivateIpAddress"))


def main():

    print("Creando infraestructura AWS...\n")

    vpc_id = create_vpc()

    subnet_id = create_subnet(vpc_id)

    sg_id = create_security_group(vpc_id)

    create_instance(subnet_id, sg_id)

    print("\nInfraestructura creada correctamente.")


if __name__ == "__main__":
    main()