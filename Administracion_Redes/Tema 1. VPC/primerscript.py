import boto3

# 1. Inicializar el recurso EC2
ec2 = boto3.resource('ec2', region_name='us-east-1')

print("1. Creando VPC...")
vpc = ec2.create_vpc(CidrBlock='10.0.0.0/16')
vpc.wait_until_available() # Esperamos a que AWS la cree por completo
vpc.create_tags(Tags=[{"Key": "Name", "Value": "MiVPCPython"}])

print("2. Creando Subred...")
# Al crearla desde el objeto 'vpc', ya sabe a qué VPC pertenece
subred = vpc.create_subnet(CidrBlock='10.0.1.0/24')
subred.create_tags(Tags=[{"Key": "Name", "Value": "MiSubredPython"}])

print("3. Lanzando Instancia EC2 dentro de la subred...")
instancias = ec2.create_instances(
    ImageId='ami-0866a3c8686eaeeba',  # Nota: Asegúrate de que esta AMI exista en us-east-1
    MinCount=1,
    MaxCount=1,
    InstanceType='t2.micro',
    KeyName='vockey',          
    SubnetId=subred.id              
)

nueva_instancia = instancias[0]
print(f"Instancia creada con ID: {nueva_instancia.id} dentro de la Subred: {subred.id}")