resource "aws_vpc" "main" {
  cidr_block = var.cidr

  tags = {
    Name = "dev-vpc"
  }
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id     = aws_vpc.main.id
  cidr_block = cidrsubnet(var.cidr, 8, count.index)

  tags = {
    Name = "public-subnet-${count.index}"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}