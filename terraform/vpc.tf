# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

resource "aws_subnet" "workload" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.workload_subnet_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "${local.name}-workload" }
}

resource "aws_subnet" "direct_workload" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.direct_workload_subnet_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "${local.name}-direct-workload" }
}

resource "aws_subnet" "proxy" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.proxy_subnet_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "${local.name}-proxy" }
}

# Firewall subnet: ANF endpoint lives here.
# RT routes to NAT GW so that ANF-forwarded traffic (with private source IPs)
# can reach the internet via NAT — not directly via IGW.
resource "aws_subnet" "firewall" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.firewall_subnet_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "${local.name}-firewall" }
}

# Public subnet: NAT GW only.
# RT routes to IGW so NAT GW can reach the internet.
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "${local.name}-public" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${local.name}-nat" }
  depends_on    = [aws_internet_gateway.main]
}
