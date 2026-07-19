variable "aws_region" {
  description = "AWS region to deploy into. Pick one close to you for lower latency."
  type        = string
  default     = "eu-west-3" # Paris

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.aws_region))
    error_message = "Must be a valid AWS region identifier, for example eu-west-3 or ap-southeast-1."
  }
}

variable "project_name" {
  description = "Prefix applied to the name of every AWS resource created by this stack."
  type        = string
  default     = "wireguard-vpn"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,20}$", var.project_name))
    error_message = "Must be 3-20 characters, lowercase letters, digits and hyphens only."
  }
}

variable "instance_type" {
  description = "EC2 instance type. t3.micro is free-tier eligible in most regions."
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = <<-EOT
    Optional AMI to pin. When null, the current Ubuntu 24.04 LTS AMI is resolved
    from Canonical's public SSM parameter. Pin this for reproducible rebuilds.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.ami_id == null || can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "Must be a valid AMI id such as ami-0123456789abcdef0, or null."
  }
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key installed on the server. Ed25519 recommended."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"

  validation {
    condition     = endswith(var.ssh_public_key_path, ".pub")
    error_message = "Must point to a PUBLIC key file ending in .pub, never a private key."
  }
}

variable "allowed_ssh_cidr" {
  description = <<-EOT
    CIDR range allowed to reach SSH. When null, the public IP of the machine
    running Terraform is auto-detected and pinned as a /32.

    Set this explicitly when running Terraform offline, from CI, or when you want
    the security group to stay stable as your own IP changes.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.allowed_ssh_cidr == null || can(cidrnetmask(var.allowed_ssh_cidr))
    error_message = "Must be a valid IPv4 CIDR such as 203.0.113.4/32, or null to auto-detect."
  }
}

variable "ssh_port" {
  description = "TCP port the SSH daemon listens on. Changing it also updates the socket unit."
  type        = number
  default     = 22

  validation {
    condition     = var.ssh_port >= 1 && var.ssh_port <= 65535
    error_message = "Must be between 1 and 65535."
  }
}

variable "wireguard_port" {
  description = <<-EOT
    UDP port WireGuard listens on.

    WireGuard's standard port is 51820. This project defaults to 443 instead,
    because networks that filter VPNs target the well-known port, and 443
    carries QUIC and HTTP/3 so it is almost never blocked. Set 51820 to use
    the standard port.
  EOT
  type        = number
  default     = 443

  # Privileged ports are allowed: wg-quick is started by systemd as root, and
  # UDP 443 is the usual fallback when a network filters the WireGuard port.
  validation {
    condition     = var.wireguard_port >= 1 && var.wireguard_port <= 65535
    error_message = "Must be between 1 and 65535."
  }
}

variable "wireguard_clients" {
  description = <<-EOT
    Devices to generate a VPN client configuration for. One .conf file and one
    QR code is produced per entry, each with its own key pair, preshared key and
    VPN address.

    Add or remove entries freely, for example:
      wireguard_clients = ["phone", "laptop", "tablet", "work-laptop"]
  EOT
  type        = list(string)
  default     = ["phone", "laptop"]

  validation {
    condition     = length(var.wireguard_clients) >= 1
    error_message = "At least one client is required."
  }

  validation {
    # Names become filenames and shell words on the server, so keep them boring.
    condition = alltrue([
      for name in var.wireguard_clients : can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$", name))
    ])
    error_message = "Client names must be 1-32 chars, letters, digits, underscore or hyphen, starting with a letter or digit."
  }

  validation {
    condition     = length(distinct(var.wireguard_clients)) == length(var.wireguard_clients)
    error_message = "Client names must be unique."
  }
}

variable "vpn_network_cidr" {
  description = "Private network used inside the tunnel. The server takes the first usable address."
  type        = string
  default     = "10.8.0.0/24"

  validation {
    condition     = can(cidrnetmask(var.vpn_network_cidr))
    error_message = "Must be a valid IPv4 CIDR such as 10.8.0.0/24."
  }
}

variable "vpc_cidr" {
  description = "CIDR of the dedicated VPC created for the VPN server."
  type        = string
  default     = "10.20.0.0/24"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "Must be a valid IPv4 CIDR such as 10.20.0.0/24."
  }
}

variable "client_dns_servers" {
  description = "DNS resolvers pushed to VPN clients. Defaults to Cloudflare."
  type        = list(string)
  default     = ["1.1.1.1", "1.0.0.1"]

  validation {
    condition     = length(var.client_dns_servers) > 0
    error_message = "At least one DNS server is required, otherwise clients leak DNS to their local network."
  }
}
