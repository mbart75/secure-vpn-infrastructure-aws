terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # REQUIRED : utilisé par data "http" "my_ip" pour détecter ton IP publique
    # Sans cette déclaration, terraform init échoue (bug critique)
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
      Project     = var.project_name
      ManagedBy   = "Terraform"
      Environment = "personal"
    }
  }
}

# ─── Data sources ────────────────────────────────────────────────────────────

# Dernière AMI Ubuntu 24.04 LTS (Noyau récent = WireGuard natif, meilleures
# patchs sécu, support long terme jusqu'en 2029)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical officiel uniquement

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# Détection automatique de ton IP publique pour restreindre SSH
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  my_ip_cidr = "${chomp(data.http.my_ip.response_body)}/32"
}

# ─── IAM Role (IMDSv2 + moindre privilège) ────────────────────────────────────
# OWASP A05 - Security Misconfiguration : pas de rôle admin sur l'instance

resource "aws_iam_role" "wireguard" {
  name = "${var.project_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# SSM pour accès console sans ouvrir SSH si nécessaire (backup sécurisé)
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.wireguard.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "wireguard" {
  name = "${var.project_name}-profile"
  role = aws_iam_role.wireguard.name
}

# ─── Security Group (principe du moindre privilège) ───────────────────────────
# OWASP A01 - Broken Access Control

resource "aws_security_group" "wireguard" {
  name        = "${var.project_name}-sg"
  description = "WireGuard VPN - acces strictement controle"

  # WireGuard UDP uniquement
  ingress {
    description = "WireGuard VPN"
    from_port   = var.wireguard_port
    to_port     = var.wireguard_port
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    # UDP ouvert au monde : normal pour un VPN, le tunnel lui-même est chiffré
  }

  # SSH restreint à ton IP UNIQUEMENT
  # OWASP A07 - Identification and Authentication Failures
  ingress {
    description = "SSH depuis mon IP uniquement"
    from_port   = var.ssh_port
    to_port     = var.ssh_port
    protocol    = "tcp"
    cidr_blocks = [local.my_ip_cidr]
  }

  # Tout le trafic sortant autorisé (nécessaire pour les mises à jour)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Clé SSH ──────────────────────────────────────────────────────────────────

resource "aws_key_pair" "wireguard" {
  key_name   = "${var.project_name}-key"
  public_key = file(var.ssh_public_key_path)
}

# ─── EC2 Free Tier + Hardening ────────────────────────────────────────────────

resource "aws_instance" "wireguard" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro" # Free tier (750h/mois) — t3.micro en eu-west-3+
  key_name               = aws_key_pair.wireguard.key_name
  vpc_security_group_ids = [aws_security_group.wireguard.id]
  iam_instance_profile   = aws_iam_instance_profile.wireguard.name

  # IMDSv2 obligatoire : empêche les attaques SSRF vers le metadata service
  # OWASP A10 - Server-Side Request Forgery
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 uniquement
    http_put_response_hop_limit = 1          # Bloque l'accès depuis les containers
    instance_metadata_tags      = "disabled"
  }

  # EBS chiffré par défaut
  # OWASP A02 - Cryptographic Failures
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true # Chiffrement du disque
    delete_on_termination = true
  }

  user_data = base64gzip(templatefile("${path.module}/scripts/user_data.sh", {
    wg_port       = var.wireguard_port
    wg_clients    = jsonencode(var.wireguard_clients)
    ssh_port      = var.ssh_port
    project_name  = var.project_name
  }))

  # Empêche la destruction accidentelle si on fait un apply
  lifecycle {
    ignore_changes = [ami] # Ne pas recréer si une nouvelle AMI sort
  }
}

# ─── Elastic IP (IP fixe) ─────────────────────────────────────────────────────
# Même après destroy/apply → même IP → pas besoin de reconfigurer les clients

resource "aws_eip" "wireguard" {
  instance = aws_instance.wireguard.id
  domain   = "vpc"
}
