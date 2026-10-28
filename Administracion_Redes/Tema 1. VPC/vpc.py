import boto3

def crear_vpc():
    # Crear cliente de EC2
    ec2 = boto3.client('ec2')

    # Crear la VPC
    vpc = ec2.create_vpc(CidrBlock='193.168.5.0/16')
    vpc_id = vpc['Vpc']['VpcId']
    print(f"✅ VPC creada con ID: {vpc_id}")

    subred_id = crear_subred(ec2, vpc_id)

    # Habilitar DNS support
    ec2.modify_vpc_attribute(
        VpcId=vpc_id,
        EnableDnsSupport={'Value': True}
    )

    # Habilitar DNS hostnames
    ec2.modify_vpc_attribute(
        VpcId=vpc_id,
        EnableDnsHostnames={'Value': True}
    )

    # Etiquetar la VPC (opcional)
    ec2.create_tags(
        Resources=[vpc_id],
        Tags=[{'Key': 'Name', 'Value': 'MiVPC-Boto3'}]
    )

    print("🌐 DNS habilitado y etiqueta 'MiVPC-Boto3' asignada.")

    instancia_id = crear_instancia(ec2, subred_id)

    print(f"Instancia EC2 creada con ID: {instancia_id} en la Subred: {subred_id}")
    
    return vpc_id

def crear_subred(ec2, vpc_id):
    subred = ec2.create_subnet(
        VpcId=vpc_id,
        CidrBlock='193.168.5.0/24', 
        AvailabilityZone='us-east-1a',
        TagSpecifications=[
            {
                'ResourceType': 'subnet',
                'Tags': [{'Key': 'Name', 'Value': 'MiSubred-Boto3'}]
            }
        ]
    )

    subred_id = subred['Subnet']['SubnetId']
    print(f"Subred creada con ID: {subred_id} en la VPC: {vpc_id}")
    return subred_id

def crear_instancia(ec2, subred_id):

    

    instancia = ec2.run_instances(
        ImageId='ami-0866a3c8686eaeeba',
        MinCount=1,
        MaxCount=1,
        InstanceType='t2.micro',
        KeyName='vockey',          
        SubnetId=subred_id              
    )

    instancia_id = instancia['Instances'][0]['InstanceId']
    print(f"Instancia EC2 creada con ID: {instancia_id} en la Subred: {subred_id}")
    return instancia_id


if __name__ == "__main__":
    vpc_id = crear_vpc()
    print(f"🚀 Proceso completado. ID de la VPC: {vpc_id}")