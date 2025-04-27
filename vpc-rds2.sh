#!/usr/bin/bash

# Customize these variables
VPC_CIDR="10.0.0.0/16"
PUB_SUBNET_CIDR="10.0.1.0/24"
PRIV_SUBNET_CIDR="10.0.2.0/24"
REGION="us-east-1"
AVAIL_ZONE="us-east-1a"
AVAIL_ZONE2="us-east-1b"
KEY_PAIR_NAME="MyKeyToAws"    # Replace with your EC2 key pair name
AMI_ID="ami-0fc5d935ebf8bc3bc"   # Replace with a valid AMI ID (e.g., Amazon Linux, Ubuntu)
INSTANCE_TYPE="t2.micro"          # You can change the instance type
TAG_NAME="MyWebServer"            # Name tag for the Private EC2 instance
TAG_NAME="BastionHost"            # Name tag for the Public EC2 instance
DB_INSTANCE_IDENTIFIER="mydb"     # RDS instance identifier
DB_NAME="mydatabase"              # Database name
DB_USER="admin"                   # Database user
DB_PASSWORD="yourpassword123"     # Database password (change this securely)
DB_INSTANCE_TYPE="db.t2.micro"    # RDS instance type
DB_ENGINE="mysql"                 # RDS engine (can also be 'postgres', 'mariadb', etc.)
DB_PORT=3306                      # Default MySQL port

# Step 1: Create VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --query "Vpc.VpcId" --output table)
echo "Created VPC: $VPC_ID" > myLogs

# Tag the VPC
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=CustomVPC

# Step 2: Create Subnets
PUB_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PUB_SUBNET_CIDR --availability-zone $AVAIL_ZONE --query "Subnet.SubnetId" --output table)
echo "Created Public Subnet: $PUB_SUBNET_ID" >> myLogs

PRIV_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PRIV_SUBNET_CIDR --availability-zone $AVAIL_ZONE --query "Subnet.SubnetId" --output table)
echo "Created Private Subnet: $PRIV_SUBNET_ID" >> myLogs

# Step 3: Create and Attach Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway --query "InternetGateway.InternetGatewayId" --output table)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID
echo "Created and attached Internet Gateway: $IGW_ID" >> myLogs

# Step 4: Create and Associate Route Table for Public Subnet
PUB_RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query "RouteTable.RouteTableId" --output table)
aws ec2 create-route --route-table-id $PUB_RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --subnet-id $PUB_SUBNET_ID --route-table-id $PUB_RT_ID
echo "Configured Route Table for Public Subnet: $PUB_RT_ID" >> myLogs

# Step 5: Enable Auto-assign Public IP on Public Subnet
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET_ID --map-public-ip-on-launch

# Step 6: Create Elastic IP for NAT Gateway
EIP_ALLOC_ID=$(aws ec2 allocate-address --domain vpc --query "AllocationId" --output table)
echo "Allocated Elastic IP: $EIP_ALLOC_ID" >> myLogs

# Step 7: Create NAT Gateway in Public Subnet
NAT_GW_ID=$(aws ec2 create-nat-gateway --subnet-id $PUB_SUBNET_ID --allocation-id $EIP_ALLOC_ID --query "NatGateway.NatGatewayId" --output table)
echo "Creating NAT Gateway: $NAT_GW_ID" >> myLogs
echo "Waiting for NAT Gateway to become available..." >> myLogs
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW_ID
echo "NAT Gateway is available." >> myLogs

# Step 8: Create Route Table for Private Subnet and Associate
PRIV_RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query "RouteTable.RouteTableId" --output table)
aws ec2 create-route --route-table-id $PRIV_RT_ID --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_GW_ID
aws ec2 associate-route-table --subnet-id $PRIV_SUBNET_ID --route-table-id $PRIV_RT_ID
echo "Configured Route Table for Private Subnet: $PRIV_RT_ID" >> myLogs

# Step 9: Create Security Group for EC2 and RDS
EC2_Private_SG_ID=$(aws ec2 create-security-group --group-name "MyWebServerSG" --description "Security group for web server" --vpc-id $VPC_ID --query "GroupId" --output table)
echo "Created EC2 Security Group: $EC2_Private_SG_ID" >> myLogs

# Add inbound rules for SSH (port 22) and HTTP (port 80) on EC2
aws ec2 authorize-security-group-ingress --group-id $EC2_Private_SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $EC2_Private_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
echo "Configured inbound rules for SSH (22) and HTTP (80) on EC2 Security Group." >> myLogs

EC2_Public_SG_ID=$(aws ec2 create-security-group --group-name "BastionHost" --description "Security group for web server" --vpc-id $VPC_ID --query "GroupId" --output table)
echo "Created EC2 Security Group: $EC2_Public_SG_ID" >> myLogs

# Add inbound rules for SSH (port 22) and HTTP (port 80) on EC2
aws ec2 authorize-security-group-ingress --group-id $EC2_Public_SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $EC2_Public_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
echo "Configured inbound rules for SSH (22) and HTTP (80) on EC2 Security Group." >> myLogs

# Create RDS Security Group to allow EC2 access
RDS_SG_ID=$(aws ec2 create-security-group --group-name "MyRDS-SG" --description "Security group for RDS" --vpc-id $VPC_ID --query "GroupId" --output table)
echo "Created RDS Security Group: $RDS_SG_ID" >> myLogs

# Allow inbound MySQL (port 3306) access from EC2 security group
aws ec2 authorize-security-group-ingress --group-id $RDS_SG_ID --protocol tcp --port $DB_PORT --source-group $EC2_Private_SG_ID
echo "Configured inbound rule for MySQL (3306) on RDS Security Group from EC2." >> myLogs

# Step 10: Create User Data to Install Apache and Database Client (MySQL)
USER_DATA=$(cat <<EOF
#!/bin/bash
# Update system and install Apache HTTP Server and MySQL client
yum update -y
yum install -y httpd mysql
# Start Apache
systemctl start httpd
# Enable Apache to start on boot
systemctl enable httpd
# Create a simple HTML page
echo "<html><body><h1>Welcome to My Web Server!</h1></body></html>" > /var/www/html/index.html
# Test MySQL Client connection to RDS
mysql -h $DB_INSTANCE_IDENTIFIER.$REGION.rds.amazonaws.com -u $DB_USER -p$DB_PASSWORD -e "SHOW DATABASES;"
EOF
)

# Step 11: Launch EC2 Instance in Public Subnet with User Data
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --count 1 \
  --instance-type $INSTANCE_TYPE \
  --key-name $KEY_PAIR_NAME \
  --subnet-id $PUB_SUBNET_ID \
  --associate-public-ip-address \
  --security-group-ids $EC2_Public_SG_ID \
  --user-data "$USER_DATA" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$BastionHost}]" \
  --query "Instances[0].InstanceId" \
  --output table)
echo "Launched EC2 Instance: $INSTANCE_ID" >> myLogs

# Launch EC2 Private Instance in the Private Subnet with user Data
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --count 1 \
  --instance-type $INSTANCE_TYPE \
  --key-name $KEY_PAIR_NAME \
  --subnet-id $PRIV_SUBNET_ID \
  --associate-public-ip-address \
  --security-group-ids $EC2_Private_SG_ID \
  --user-data "$USER_DATA" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$MyWebServer}]" \
  --query "Instances[0].InstanceId" \
  --output table)
echo "Launched EC2 Instance: $INSTANCE_ID" >> myLogs

# Step 12: Launch RDS Instance in Private Subnet
RDS_INSTANCE_ID=$(aws rds create-db-instance \
  --db-instance-identifier $DB_INSTANCE_IDENTIFIER \
  --allocated-storage 20 \
  --db-instance-class $DB_INSTANCE_TYPE \
  --engine $DB_ENGINE \
  --master-username $DB_USER \
  --master-user-password $DB_PASSWORD \
  --db-name $DB_NAME \
  --vpc-security-group-ids $RDS_SG_ID \
  --availability-zones $AVAIL_ZONE $AVAIL_ZONE2 \
  --db-subnet-group-name $(aws rds create-db-subnet-group --db-subnet-group-name "MyDBSubnetGroup" --subnet-ids $PRIV_SUBNET_ID --query "DBSubnetGroup.DBSubnetGroupName" --output table) \
  --publicly-accessible false \
  --query "DBInstance.DBInstanceIdentifier" \
  --output table)
echo "Launched RDS Instance: $RDS_INSTANCE_ID" >> myLogs

# Output instance details
echo "EC2 Instance launched in Public Subnet as the BASTIONHOST: $INSTANCE_ID" >> myLogs
echo "EC2 Instance launched in Private Subnet as the SERVER: $INSTANCE_ID" >> myLogs
echo "RDS Instance launched in Private Subnet: $RDS_INSTANCE_ID" >> myLogs
echo "✅ Custom VPC setup complete with EC2 instance, Apache >> myLogs
