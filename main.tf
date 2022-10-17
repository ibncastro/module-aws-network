# start with a declaration that it is using aws provider
# terraform will use this to download and install libraries it will need to aid communication with aws api and create resources on our behalf.
#  in an attempt to connect aws api, it will use these credentials
# we also specify the region so it knows which region we are working with. 
provider "aws" {
  region = var.aws_region
}


# defining two local variables 
# they establish a naming standard to help us differentiate environment resources in aws console. mostly important if we plan to create multiple environments in the same aws account space to avoid naming collision. 
locals {
  vpc_name     = "${var.env_name} ${var.vpc_name}"
  cluster_name = "${var.cluster_name}-${var.env_name}"
}

# AWS vpc definition resource 
# creating a new aws vpc
# CIDR: classes inter-domain routing: standard way of describing ip address range for the network. Its a shorthand string that defines ip addresses allowed inside a network or subnet. 
# we have also used tags becuase they give us a way of easily identifying groups of resources when we need to administer them. 
# Tags are also useful for automated tasks and identifying resources that shd be managed in specific ways. 
#  in some cases, we hv used variables. we will define their values later. when we use this as part of our sandbox. 
# by using variables, it makes our modules reuseable. by changing the variables, we can change the type of environment we create.
resource "aws_vpc" "main" {
  cidr_block           = var.main_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    # Name tag to make it easy to identify
    "Name" = local.vpc_name,
    # a kubernetes tag that identify this cluster as a target for out kubernetes cluster
    "Kubernetes.io/cluster/${local.cluster_name}" = "shared",
  }
}

# Subnet definition
# moving on to configuring subnets
# we will be using EKS so we need to configure this properly
# we will use two different availability zones.
# an availability zone represent a physical data center. this will ensure our services still work even when one availability zone or data center goes down. 
# in addition, aws also recommend a vpc configuration for both public and private subnets
# public subnet can be accessed over internet
# private subnet can be accessed or allow traffic only from inside the vpc.
# EKS will deploy load balancers in public subnet to manage inbound trafic which will be routed to our containerized microservices deployed in privae subnets.
# so we will have a public and private subnets in one availability zone or data center. so 4 subnets in total. because we will need two data centers. 
# next, we need to split up the ip addresses for the subnets to use. the cidr ip range we specified. 
# data element is a way of querying the provider for information.
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public-subnet-a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_a_cidr
  availability_zone = data.aws_availability_zones.available.names[0]
  # terafform type: data : can help us choose the zone names dynamically.

  tags = {
    # the name tag below will make it easier to find our network resource through the admin and ops console.
    "Name" = "${local.vpc_name}-public-subnet-a"
    #   we need EKS tags so the AWS kubernets service will know which subnets we are using and what they are for.
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    # we will tag our public subnet with an elb role so that EKS knows it can use these subnets to create and deploy an elastic load balancer.
    #   we will also tag our private subnets with internal-elb role to indicate that our workload will be deployed into them and can be load balanced. 
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "public-subnet-b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_b_cidr
  availability_zone = data.aws_availability_zones.available.names[1]
  # we are using this to grab the availablity zone ids in the region we have specified
  # nice way to avoid hardcoding values into the module.
  # data element is a way of querying the provider for information.

  tags = {
    "Name"                                        = "${local.vpc_name}-public-subnet-b"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }
}


resource "aws_subnet" "private-subnet-a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_a_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    "Name"                                        = "${local.vpc_name}-private-subnet-a"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

resource "aws_subnet" "private-subnet-b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_b_cidr
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    "Name"                                        = "${local.vpc_name}-private-subnet-b"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

# Internet gateway and routing tables for public subnets

# we need to create a routing table that will specify what traffic is allowed into our subnets. 
# we will create the gateway and associate it with our subnets. 

# this will make the subnets accessible to the internet
# gateway is an aws network component that will connect our private cloud to public internet
# we will create it and tie it to our vpc using the vpc_id 
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.vpc_name}-igw"
  }
}

# we need to define routing rules that let aws know how to route traffic from the gateway into the subnets.
# this particular routing table will allow all traffic from the internet through the gateway
resource "aws_route_table" "public-route" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    "Name" = "${local.vpc_name}-public-route"
  }
}


# then we need to associate our routing table and subnet together.
resource "aws_route_table_association" "public-a-association" {
  subnet_id      = aws_subnet.public-subnet-a.id
  route_table_id = aws_route_table.public-route.id
}

resource "aws_route_table_association" "public-b-association" {
  subnet_id      = aws_subnet.public-subnet-b.id
  route_table_id = aws_route_table.public-route.id
}

# configuring routing for our private subnets will be a bit challenging
# we need to define a route from our private subnet to the internet to allow our kubernetes pods to talk to the EKS service 
# for this to work, we need a way for our nodes in our private subnets to talk to the internet gateway we hv deployed in the public subnets. 
# in aws, we need to create a network address translation (NAT) gateway resource.
# the NAT will need a special kind of ip address called elastic ip address (EIP)
# we need to create two EIP addresses. one for each NAT we are creating
resource "aws_eip" "nat-a" {
  vpc = true
  tags = {
    "Name" = "${local.vpc_name}-NAT-a"
  }
}

resource "aws_eip" "nat-b" {
  vpc = true
  tags = {
    "Name" = "${local.vpc_name}-NAT-b"
  }
}


# NAT gateway for private subnets
# this depends on the general internet gateway defined above
resource "aws_nat_gateway" "nat-gw-a" {
  allocation_id = aws_eip.nat-a.id
  subnet_id     = aws_subnet.public-subnet-a.id
  depends_on = [
    aws_internet_gateway.igw
  ]

  tags = {
    "Name" = "${local.vpc_name}-NAT-gw-a"
  }
}

resource "aws_nat_gateway" "nat-gw-b" {
  allocation_id = aws_eip.nat-b.id
  subnet_id     = aws_subnet.public-subnet-b.id
  depends_on = [
    aws_internet_gateway.igw
  ]

  tags = {
    "Name" = "${local.vpc_name}-NAT-gw-b"
  }
}


# routes for the private subnet 
resource "aws_route_table" "private-route-a" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat-gw-a.id
  }

  tags = {
    "Name" = "${local.vpc_name}-private-route-a"
  }
}

resource "aws_route_table" "private-route-b" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat-gw-b.id
  }

  tags = {
    "Name" = "${local.vpc_name}-private-route-b"
  }
}


resource "aws_route_table_association" "private-a-association" {
  subnet_id      = aws_subnet.private-subnet-a.id
  route_table_id = aws_route_table.private-route-a.id
}


resource "aws_route_table_association" "private-b-association" {
  subnet_id      = aws_subnet.private-subnet-b.id
  route_table_id = aws_route_table.private-route-b.id
}
