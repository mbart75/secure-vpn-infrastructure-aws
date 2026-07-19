terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Used by data "http" "my_ip" to auto-detect the deployer's public IP.
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "Terraform"
    }
  }
}

# ─── Data sources ─────────────────────────────────────────────────────────────

# Canonical publishes the current Ubuntu 24.04 LTS AMI id per region as a public
# SSM parameter. More stable than matching AMI names with a glob, which breaks
# whenever Canonical adjusts its naming scheme.
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# Not every availability zone offers every instance type.
data "aws_ec2_instance_type_offerings" "supported" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

# Only queried when the caller did not pin allowed_ssh_cidr, so an explicit CIDR
# also makes plan/destroy work without outbound internet access.
data "http" "my_ip" {
  count = var.allowed_ssh_cidr == null ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  ami_id = coalesce(var.ami_id, nonsensitive(data.aws_ssm_parameter.ubuntu.value))

  # null when the instance type is offered in no zone of this region; the
  # subnet turns that into an actionable error rather than an index failure.
  availability_zone = try(sort(data.aws_ec2_instance_type_offerings.supported.locations)[0], null)

  detected_ssh_cidr = try("${chomp(one(data.http.my_ip[*].response_body))}/32", null)
  allowed_ssh_cidr  = var.allowed_ssh_cidr != null ? var.allowed_ssh_cidr : local.detected_ssh_cidr

  # Terraform owns VPN addressing so the bootstrap script never does IP math.
  server_vpn_address = "${cidrhost(var.vpn_network_cidr, 1)}/${split("/", var.vpn_network_cidr)[1]}"
  vpn_host_capacity  = pow(2, 32 - tonumber(split("/", var.vpn_network_cidr)[1])) - 3

  # Rendered as "name:address" pairs, consumed as a plain word list by the script.
  client_specs = join(" ", [
    for index, name in var.wireguard_clients :
    "${name}:${cidrhost(var.vpn_network_cidr, index + 2)}"
  ])
}

# ─── Network ──────────────────────────────────────────────────────────────────
# A dedicated VPC rather than the account default: the default VPC is routinely
# deleted in hardened or organization-managed accounts, and relying on it makes
# this stack fail with an opaque "VPCIdNotSpecified" error.

resource "aws_vpc" "wireguard" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "wireguard" {
  vpc_id = aws_vpc.wireguard.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "wireguard" {
  vpc_id                  = aws_vpc.wireguard.id
  cidr_block              = var.vpc_cidr
  availability_zone       = local.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-subnet"
  }

  lifecycle {
    precondition {
      condition     = local.availability_zone != null
      error_message = "Instance type ${var.instance_type} is not offered in any availability zone of ${var.aws_region}. Pick another instance_type or another region."
    }
  }
}

resource "aws_route_table" "wireguard" {
  vpc_id = aws_vpc.wireguard.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.wireguard.id
  }

  tags = {
    Name = "${var.project_name}-rt"
  }
}

resource "aws_route_table_association" "wireguard" {
  subnet_id      = aws_subnet.wireguard.id
  route_table_id = aws_route_table.wireguard.id
}

# ─── IAM ──────────────────────────────────────────────────────────────────────
# The instance profile grants SSM Session Manager only: no static credentials on
# the box, and a way back in when the SSH source IP no longer matches.

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "wireguard" {
  name_prefix        = "${var.project_name}-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.wireguard.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "wireguard" {
  name_prefix = "${var.project_name}-"
  role        = aws_iam_role.wireguard.name
}

# ─── Security group ───────────────────────────────────────────────────────────
# name_prefix rather than a fixed name: with create_before_destroy, a fixed name
# guarantees an InvalidGroup.Duplicate failure on any replacement.

resource "aws_security_group" "wireguard" {
  name_prefix = "${var.project_name}-sg-"
  description = "WireGuard VPN server access"
  vpc_id      = aws_vpc.wireguard.id

  tags = {
    Name = "${var.project_name}-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Standalone rule resources (provider v5 pattern): each rule plans, tags and
# diffs independently instead of the whole rule set churning as one attribute.
resource "aws_vpc_security_group_ingress_rule" "wireguard" {
  security_group_id = aws_security_group.wireguard.id
  description       = "WireGuard tunnel"
  ip_protocol       = "udp"
  from_port         = var.wireguard_port
  to_port           = var.wireguard_port
  cidr_ipv4         = "0.0.0.0/0" # The tunnel itself is authenticated and encrypted.

  tags = {
    Name = "${var.project_name}-wireguard"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.wireguard.id
  description       = "SSH from the operator only"
  ip_protocol       = "tcp"
  from_port         = var.ssh_port
  to_port           = var.ssh_port
  cidr_ipv4         = local.allowed_ssh_cidr

  tags = {
    Name = "${var.project_name}-ssh"
  }

  lifecycle {
    precondition {
      condition     = local.allowed_ssh_cidr != null
      error_message = <<-EOT
        Could not auto-detect your public IP address.
        Set it explicitly, for example:
          terraform apply -var='allowed_ssh_cidr=203.0.113.4/32'
      EOT
    }
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.wireguard.id
  description       = "Outbound traffic: package updates and client tunnel egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Name = "${var.project_name}-egress"
  }
}

# ─── SSH key pair ─────────────────────────────────────────────────────────────

resource "aws_key_pair" "wireguard" {
  key_name_prefix = "${var.project_name}-"
  public_key      = file(pathexpand(var.ssh_public_key_path))

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Elastic IP ───────────────────────────────────────────────────────────────
# Allocated before the instance so the address can be baked into the client
# configurations. Associated afterwards, which keeps the dependency acyclic.
#
# Note: the address is released on destroy, so every redeploy hands out a new
# IP and client configs must be re-imported. Keeping it allocated between trips
# would preserve the IP but AWS bills every allocated IPv4 address by the hour.

resource "aws_eip" "wireguard" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-eip"
  }
}

resource "aws_eip_association" "wireguard" {
  instance_id   = aws_instance.wireguard.id
  allocation_id = aws_eip.wireguard.id
}

# ─── EC2 instance ─────────────────────────────────────────────────────────────

resource "aws_instance" "wireguard" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.wireguard.id
  vpc_security_group_ids = [aws_security_group.wireguard.id]
  iam_instance_profile   = aws_iam_instance_profile.wireguard.name
  key_name               = aws_key_pair.wireguard.key_name

  # IMDSv2 only: session tokens required, and a hop limit of 1 keeps the
  # credentials endpoint unreachable from containers or a proxied request.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    delete_on_termination = true
  }

  # The public IP is injected by Terraform rather than read from the instance
  # metadata at boot: reading it on the instance races the Elastic IP
  # association and can bake a discarded address into every client config.
  user_data = base64gzip(templatefile("${path.module}/scripts/user_data.sh", {
    project_name       = var.project_name
    ssh_port           = var.ssh_port
    wg_port            = var.wireguard_port
    server_public_ip   = aws_eip.wireguard.public_ip
    server_vpn_address = local.server_vpn_address
    client_specs       = local.client_specs
    client_dns         = join(", ", var.client_dns_servers)
  }))

  tags = {
    Name = "${var.project_name}-server"
  }

  lifecycle {
    # Canonical publishes new AMIs continuously. Without this, an unrelated
    # apply would replace a running server mid-trip. Pin var.ami_id to control
    # the image deliberately. This is not destroy protection.
    ignore_changes = [ami]

    precondition {
      condition     = length(var.wireguard_clients) <= local.vpn_host_capacity
      error_message = "Too many clients for ${var.vpn_network_cidr}: it holds ${local.vpn_host_capacity} clients. Use a larger vpn_network_cidr."
    }
  }
}
