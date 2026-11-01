
#!/bin/bash

set -e


REGION="us-east-1"

VPC_CIDR="172.16.0.0/16"
SUBNET_CIDR="172.16.0.0/20"

INSTANCE_TYPE="t2.micro"
KEY_NAME="vockey"
IAM_PROFILE="LabInstanceProfile"

INSTANCE_NAME="ripoll_roberto"

export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""


create_vpc() {

    VPC_ID=$(aws ec2 create-vpc \
        --cidr-block "$VPC_CIDR" \
        --query "Vpc.VpcId" \
        --output text)

    aws ec2 wait vpc-available --vpc-ids "$VPC_ID"

    aws ec2 create-tags \
        --resources "$VPC_ID" \
        --tags Key=Name,Value=VPC_Practica

    echo "VPC creada: $VPC_ID"
}



create_subnet() {

    SUBNET_ID=$(aws ec2 create-subnet \
        --vpc-id "$VPC_ID" \
        --cidr-block "$SUBNET_CIDR" \
        --query "Subnet.SubnetId" \
        --output text)

    aws ec2 wait subnet-available --subnet-ids "$SUBNET_ID"

    # Asignar IP publica automaticamente
    aws ec2 modify-subnet-attribute \
        --subnet-id "$SUBNET_ID" \
        --map-public-ip-on-launch

    aws ec2 create-tags \
        --resources "$SUBNET_ID" \
        --tags Key=Name,Value=Subred_Practica

    echo "Subred creada: $SUBNET_ID"
}

create_security_group() {

    SG_ID=$(aws ec2 create-security-group \
        --group-name SG_Practica \
        --description "Grupo de seguridad para la EC2" \
        --vpc-id "$VPC_ID" \
        --query "GroupId" \
        --output text)

    # Reglas SSH, HTTP, HTTPS y PING (ICMP)
    IP_PERMISSIONS='[
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
    ]'

    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --ip-permissions "$IP_PERMISSIONS"

    aws ec2 create-tags \
        --resources "$SG_ID" \
        --tags Key=Name,Value=SG_Practica

    echo "Grupo de seguridad creado: $SG_ID"
}


get_ubuntu_ami() {

    AMI_ID=$(aws ec2 describe-images \
        --owners 099720109477 \
        --filters \
            "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
            "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate)[-1].ImageId' \
        --output text)

    if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
        echo "Error: No se ha encontrado una AMI de Ubuntu 22.04"
        exit 1
    fi

    echo "AMI seleccionada: $AMI_ID"
}


create_instance() {

    get_ubuntu_ami

    BLOCK_DEVICE_MAPPINGS='[
        {
            "DeviceName": "/dev/sda1",
            "Ebs": {
                "VolumeSize": 10,
                "VolumeType": "gp2",
                "DeleteOnTermination": true
            }
        }
    ]'

    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --count 1 \
        --iam-instance-profile "Name=$IAM_PROFILE" \
        --subnet-id "$SUBNET_ID" \
        --security-group-ids "$SG_ID" \
        --block-device-mappings "$BLOCK_DEVICE_MAPPINGS" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
        --query "Instances[0].InstanceId" \
        --output text)

    echo "Instancia EC2 creada: $INSTANCE_ID"

    # Esperar a que la instancia este en ejecucion
    aws ec2 wait instance-running \
        --instance-ids "$INSTANCE_ID"

    # Esperar a las comprobaciones 2/2
    aws ec2 wait instance-status-ok \
        --instance-ids "$INSTANCE_ID"

    # Mostrar informacion de la instancia
    aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].[State.Name,PublicIpAddress,PrivateIpAddress]" \
        --output table
}


main() {

    echo "Comprobando credenciales AWS..."

    aws sts get-caller-identity > /dev/null

    echo "Creando infraestructura AWS..."
    echo ""

    create_vpc

    create_subnet

    create_security_group

    create_instance

    echo ""
    echo "Infraestructura creada correctamente."
}


main
