resource "aws_vpc" "this" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = var.az_a
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name_prefix}-public-a" }
}
resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.42.2.0/24"
  availability_zone       = var.az_b
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name_prefix}-public-b" }
}
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.42.11.0/24"
  availability_zone = var.az_a
  tags              = { Name = "${var.name_prefix}-private-a" }
}
resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.42.12.0/24"
  availability_zone = var.az_b
  tags              = { Name = "${var.name_prefix}-private-b" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name_prefix}-public-rt" }
}
resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}
