locals {
  tags = {
    Environment = var.env
    Project     = var.project
    ManagedBy   = "terraform"
  }
}

# ── VPC ──
resource "aws_vpc" "main" {
  cidr_block           = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = merge(local.tags, { Name = "${var.env}-vpc" })
}

# ── Internet Gateway ──
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${var.env}-igw" })
}

# ── Public Subnets ──
resource "aws_subnet" "public" {
  count                   = length(var.azs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.cidr, 8, count.index)
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name                     = "${var.env}-public-${count.index}"
    "kubernetes.io/role/elb" = "1"
    "kubernetes.io/cluster/${var.env}-eks" = "shared"
  })
}

# ── Private Subnets ──
resource "aws_subnet" "private" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.cidr, 8, count.index + 10)
  availability_zone = var.azs[count.index]

  tags = merge(local.tags, {
    Name                              = "${var.env}-private-${count.index}"
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/${var.env}-eks" = "shared"
  })
}

# ── NAT Gateways (one per AZ for HA) ──
resource "aws_eip" "nat" {
  count      = length(var.azs)
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags       = merge(local.tags, { Name = "${var.env}-nat-eip-${count.index}" })
}

resource "aws_nat_gateway" "nat" {
  count         = length(var.azs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(local.tags, { Name = "${var.env}-nat-${count.index}" })
}

# ── Public Route Table ──
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = merge(local.tags, { Name = "${var.env}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Private Route Tables (per AZ) ──
resource "aws_route_table" "private" {
  count  = length(var.azs)
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[count.index].id
  }
  tags = merge(local.tags, { Name = "${var.env}-private-rt-${count.index}" })
}

resource "aws_route_table_association" "private" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ── VPC Flow Logs ──
resource "aws_cloudwatch_log_group" "vpc_logs" {
  name              = "/aws/vpc/${var.env}/flow-logs"
  retention_in_days = 30
  tags              = local.tags
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.env}-vpc-flow-logs-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups"]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "vpc" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn
  tags                 = local.tags
}