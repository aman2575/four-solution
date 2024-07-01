# Define provider (AWS)
provider "aws" {
  region = "us-east-1" # Specify your desired AWS region
}

# Variables
variable "vpc_cidr_block" {
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  default = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  default = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "aws_availability_zones" {
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

# Create VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "ionginx-vpc"
  }
}

# Create Internet Gateway
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "ionginx-igw"
  }
}

# Create Public Subnets
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.aws_availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "ionginx-public-subnet-${count.index}"
  }
}

# Create Private Subnets
resource "aws_subnet" "private" {
  count                   = length(var.private_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = var.aws_availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "ionginx-private-subnet-${count.index}"
  }
}

# Create Route Table for Public Subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "ionginx-public-route-table"
  }
}

# Associate Public Subnets with Public Route Table
resource "aws_route_table_association" "public_association" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Create NAT Gateway
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "ionginx-nat-gateway"
  }
}

# Create EIP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"
  count  = 1
  tags = {
    Name = "ionginx-nat-eip"
  }
}

# Create Route Table for Private Subnets
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "ionginx-private-route-table"
  }
}

# Associate Private Subnets with Private Route Table
resource "aws_route_table_association" "private_association" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Auto Scaling Group and Launch Configuration

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"] # Canonical
}

resource "aws_launch_template" "nginx_template" {
  name                   = "nginx-template"
  instance_type          = "t4g.micro"
  image_id               = data.aws_ami.ubuntu.id
  key_name               = "neo"
  vpc_security_group_ids = [aws_security_group.nginx_sg.id]

  lifecycle {
    create_before_destroy = true
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y nginx
              service nginx start
              EOF
  )
}


# resource "aws_launch_configuration" "nginx_lc" {
#   name_prefix                 = "nginx-lc-"
#   image_id                    = data.aws_ami.ubuntu.id # Specify your Ubuntu AMI ID
#   instance_type               = "t2.micro"             # Specify your instance type
#   security_groups             = [aws_security_group.nginx.id]
#   key_name                    = "neo" # Specify your SSH key name if needed
#   associate_public_ip_address = false # Do not assign public IP

#   lifecycle {
#     create_before_destroy = true
#   }

#   user_data = <<-EOF
#               #!/bin/bash
#               apt-get update
#               apt-get install -y nginx
#               service nginx start
#               EOF
# }

resource "aws_autoscaling_group" "nginx_asg" {
  name                = "nginx-asg"
  desired_capacity    = 2
  max_size            = 4
  min_size            = 2
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [aws_lb_target_group.nginx.arn]

  launch_template {
    id      = aws_launch_template.nginx_template.id
    version = "$Latest"
  }
  lifecycle {
    create_before_destroy = true
  }
}

# Security Group for NGINX instances (allow HTTP inbound)
resource "aws_security_group" "nginx_sg" {
  name        = "nginx-sg"
  description = "Security group for NGINX servers"

  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_lb_target_group" "nginx" {
  name        = "nginx-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"
}

# Define Route 53 Zone
resource "aws_route53_zone" "primary" {
  name = "exam.com" # Replace with your domain name
}

# Route 53 Record Set
resource "aws_route53_record" "nginx_record" {
  zone_id = aws_route53_zone.primary.zone_id # Specify your Route 53 hosted zone ID
  name    = "nginx.exam.com"
  type    = "A"
  ttl     = 300

  records = [aws_eip.nat[0].public_ip] # EIP of the NAT Gateway

  allow_overwrite = true
}
