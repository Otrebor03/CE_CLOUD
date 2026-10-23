
#¿COMO FUNCIONA LO DE DEVOLVER LOS IDS Y LA QUERY?

# Creo la VPC y devuelvo su ID
VPC_ID=$(aws ec2 create-vpc \
        --cidr-block 172.16.0.0/16 \
        --amazon-provided-ipv6-cidr-block \
        --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=ripoll-roberto-vpc-code}]' \
        --query 'Vpc.{VpcId:VpcId}' \
        --output text
)

echo VPC_ID

# Habilitar el DNS en la VPC
aws ec2 modify-vpc-attribute \
    --vpc-id VPC_ID \
    --enable-dns-hostnames "{\"Value\":true}"

# Creacion de subred y devolver su ID
SR_ID=$(aws ec2 create-subnet \
        --vpc-id VPC_ID \
        --cidr-block 192.168.3.0/28 \
        --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=sr-ripoll-code}]' \
        --query Subnet.SubnetId --output text
)

echo SR_ID

# Habilito la asignacion de ipv4 publica en la subred
# comprobar como NO se habilita y tenemos que hacerlo a posteriori
aws ec2 modify-subnet-attribute --subnet-id SR_ID --map-public-ip-on-launch

#NO DEVUELVE ID - HACER QUE DEVULVA ID
# Creacion del grupo de seguridad 
SG_ID=$(aws ec2 create-security-group \
        --group-name sc-ripoll-code \
        --description "Grupo de seguridad creado por codigo" \
        --vpc-id VPC_ID \
        --query 'GroupId' --output text
)

echo SG_ID

# Añadir regla de entrada SSH
aws ec2 authorize-security-group-ingress \
  --security-group-ids SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0


#NECESITO CREAR LA IMAGEN AMI


# Lanzar Instancia
EC2_ID=$(aws ec2 run-instances \
    --image-id ami-0ecb62995f68bb549 \
    --instance-type t2.small \
    --key-name vockey \
    --security-group-ids SG_ID \
    --subnet-id SR_ID \
    --iam-instance-profile Name=LabInstanceProfile \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=instancia-ripoll-code}]' \
    --query 'Instances[0].InstanceId' --output text
)
echo EC2_ID