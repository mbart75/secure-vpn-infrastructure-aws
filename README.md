# 🔒 Secure WireGuard VPN Infrastructure on AWS

> **Production-grade, ephemeral VPN infrastructure** — deployed in under 5 minutes via Terraform. Built with security-first principles, OWASP Top 10 compliance, and zero persistent credentials.

[![Terraform](https://img.shields.io/badge/Terraform-1.5+-purple)](https://terraform.io)
[![AWS](https://img.shields.io/badge/AWS-eu--west--3-orange)](https://aws.amazon.com)
[![WireGuard](https://img.shields.io/badge/WireGuard-kernel--native-green)](https://wireguard.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

---

## 🎯 Project Overview

This project provisions a **fully hardened WireGuard VPN server** on AWS EC2 (free tier) using Terraform. The infrastructure is designed to be **ephemeral** — deployed before travel on a trusted network, destroyed immediately after, leaving zero residual cost and zero persistent attack surface.

### Key Design Principles

- **Ephemeral by design** — destroy when not in use, redeploy in 5 minutes when needed
- **Zero credentials on disk** — AWS keys stored exclusively in macOS Keychain (iCloud-synced) via `aws-vault`
- **Least privilege IAM** — dedicated user scoped to specific regions and resource prefixes only
- **Fully automated** — single double-click deployment, no manual steps

---

## 🏗️ Architecture

```
AWS (region of choice)
├── EC2 t3.micro (Ubuntu 24.04 LTS — free tier eligible)
│   ├── WireGuard (kernel-native, Linux 6.x)
│   ├── UFW firewall (strict rules + SSH rate limiting)
│   ├── Fail2ban (24h SSH ban after 3 failed attempts)
│   └── Unattended-upgrades (automatic security patches)
├── Security Group
│   ├── SSH — restricted to deployer IP only (auto-detected)
│   └── UDP 51820 — WireGuard (open to all)
├── Elastic IP (fixed IP for VPN duration)
├── Key Pair (Ed25519)
└── IAM Role (SSM access, least privilege)
```

---

## 🔐 Security Implementation

### OWASP Top 10 Compliance

| OWASP Category | Control Implemented |
|---|---|
| **A01 — Broken Access Control** | SSH restricted to deployer IP only via Security Group; UFW rate limiting |
| **A02 — Cryptographic Failures** | WireGuard: Curve25519 + ChaCha20-Poly1305 + BLAKE2s; SSH: Ed25519 only; EBS encrypted at rest |
| **A05 — Security Misconfiguration** | Kernel hardening via sysctl (SYN flood, ICMP redirect, martian logging); UFW default deny |
| **A06 — Vulnerable Components** | Unattended-upgrades for automatic security patches; version audit script |
| **A07 — Auth Failures** | Password authentication disabled; Ed25519 keys only; Fail2ban; MaxAuthTries=3 |
| **A08 — Software Supply Chain** | `terraform.lock.hcl` committed (SHA256 provider hashes pinned) |
| **A10 — SSRF** | IMDSv2 enforced (hop limit=1, tokens required) — blocks SSRF attacks against metadata API |

### Credential Security

```
aws-vault → macOS Keychain (login) → iCloud Keychain sync
```

- AWS Access Keys **never stored in plaintext** (`~/.aws/credentials` unused)
- `aws-vault` generates short-lived STS tokens for each Terraform operation
- IAM user scoped to `wireguard-*` resources in 6 allowed regions only
- `--no-session` mode used for programmatic access (IAM user without MFA)

### Network Security

```
Client Device → WireGuard (UDP/51820, ChaCha20-Poly1305) → EC2 → Internet
```

- **Full tunnel mode** — all traffic routed through VPN (`AllowedIPs = 0.0.0.0/0, ::/0`)
- **DNS leak prevention** — Cloudflare DNS (1.1.1.1) over the tunnel
- **Per-client PresharedKey** — additional symmetric encryption layer per device (post-quantum hardening)
- SSH hardened: weak algorithms disabled, PAM session only (no password auth)

---

## 🚀 Deployment

### Prerequisites

- macOS with [Homebrew](https://brew.sh)
- AWS account (free tier sufficient)
- IAM user in `wireguard-deployers` group (see [IAM Setup](#iam-setup))

### One-Click Deploy

```bash
# Double-click deploy.command in Finder
# OR from terminal:
bash deploy.command
```

The script handles automatically:
1. Homebrew + tool installation (Terraform, AWS CLI, aws-vault, gh)
2. AWS credential setup via aws-vault → macOS Keychain
3. SSH key generation (Ed25519)
4. Interactive region selection
5. GitHub repository creation and push
6. `terraform plan` (saved to `.bin` file) → confirmation → `terraform apply`
7. Post-deploy instructions with exact commands

### Supported Regions

| # | Region | Location |
|---|---|---|
| 1 | `eu-west-3` | Paris 🇫🇷 |
| 2 | `eu-south-2` | Madrid 🇪🇸 |
| 3 | `eu-central-1` | Frankfurt 🇩🇪 |
| 4 | `us-east-1` | Virginia 🇺🇸 |
| 5 | `us-west-2` | Oregon 🇺🇸 |
| 6 | `ap-southeast-1` | Singapore 🇸🇬 |

### Post-Deploy

```bash
# 1. Wait 2-3 min for cloud-init to complete, then verify:
ssh -i ~/.ssh/id_ed25519 ubuntu@$SERVER_IP \
  'sudo tail -5 /var/log/wireguard-setup.log'

# 2. Retrieve client configs
scp -i ~/.ssh/id_ed25519 \
  ubuntu@$SERVER_IP:'~/wireguard-clients/*.conf' ~/Desktop/

# 3. QR code for mobile import
ssh -i ~/.ssh/id_ed25519 ubuntu@$SERVER_IP \
  'cat ~/wireguard-clients/telephone-qrcode.txt'
```

### Destroy (zero residual cost)

```bash
cd /path/to/project
AWS_VAULT_KEYCHAIN_NAME=login \
  aws-vault exec --no-session wireguard -- \
  terraform destroy -auto-approve -var="aws_region=eu-west-3"
```

---

## ⚙️ Configuration

### Variables

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `eu-west-3` | AWS region (set interactively at deploy time) |
| `project_name` | `wireguard-perso` | AWS resource name prefix |
| `wireguard_port` | `51820` | WireGuard UDP port |
| `ssh_port` | `22` | SSH port |
| `wireguard_clients` | *(5 devices)* | VPN client list — one `.conf` generated per device |
| `ssh_public_key_path` | `~/.ssh/id_ed25519.pub` | SSH public key path |

### Client Devices

Each client gets a unique config with its own key pair, PresharedKey, and VPN IP (`10.8.0.x/24`). Import the `.conf` into the official WireGuard app on any platform.

---

## 🔧 IAM Setup

### IAM Group Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2FullInAllowedRegions",
      "Effect": "Allow",
      "Action": "ec2:*",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": [
            "eu-west-3", "eu-south-2", "eu-central-1",
            "us-east-1", "us-west-2", "ap-southeast-1"
          ]
        }
      }
    },
    {
      "Sid": "IAMForWireguardRoles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:PassRole",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy",
        "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile", "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile", "iam:ListInstanceProfilesForRole",
        "iam:TagRole", "iam:UntagRole", "iam:TagInstanceProfile",
        "iam:UntagInstanceProfile", "iam:UpdateRole",
        "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"
      ],
      "Resource": [
        "arn:aws:iam::*:role/wireguard-*",
        "arn:aws:iam::*:instance-profile/wireguard-*"
      ]
    },
    {
      "Sid": "STSAccess",
      "Effect": "Allow",
      "Action": ["sts:GetCallerIdentity", "sts:GetSessionToken"],
      "Resource": "*"
    }
  ]
}
```

---

## 🛡️ Server Hardening Details

### SSH Configuration

- Protocol 2, Ed25519 host keys only (DSA/ECDSA removed)
- Allowed ciphers: `chacha20-poly1305`, `aes256-gcm`, `aes128-gcm`
- Allowed MACs: HMAC-SHA2-256/512 ETM, UMAC-128 ETM
- `PasswordAuthentication no`, `PermitRootLogin no`
- `MaxAuthTries 3`, `LoginGraceTime 30s`
- SFTP subsystem enabled (scp support)

### Kernel Hardening (sysctl)

- IP forwarding enabled (required for VPN)
- SYN flood protection (`tcp_syncookies`)
- Reverse path filtering (anti-spoofing)
- ICMP redirect disabled
- Kernel pointer restriction (`kptr_restrict=2`)
- ptrace scope restriction (`yama.ptrace_scope=1`)
- SysRq disabled

### Fail2ban

- SSH: ban 24h after 3 failed attempts within 10 minutes
- Backend: systemd journal

---

## 💸 Cost

| Resource | Free Tier | After Free Tier |
|---|---|---|
| EC2 t3.micro | **750h/month FREE** | ~$8/month |
| Elastic IP (attached) | **Free** | Free |
| Outbound data | **1 GB/month free** | $0.09/GB |

**→ `terraform destroy` when not in use = $0**

> The Elastic IP is released on destroy — the IP changes on every new deployment.
> Re-import the `.conf` files after each redeploy.

---

## 📁 Project Structure

```
.
├── main.tf                    # EC2, SG, IAM, Key Pair, EIP resources
├── variables.tf               # Input variables with validation
├── outputs.tf                 # Post-deploy connection info
├── .terraform.lock.hcl        # Provider SHA256 hashes (supply chain security)
├── .gitignore                 # Excludes tfstate, keys, configs, credentials
├── deploy.command             # One-click deploy script (macOS)
├── cleanup-vault.command      # aws-vault/config cleanup utility
├── terraform.tfvars.example   # Configuration template
└── scripts/
    └── user_data.sh           # EC2 cloud-init: WireGuard + hardening
```

---

## 🔍 Useful Commands

```bash
# Check WireGuard status (connected peers, data transfer)
ssh -i ~/.ssh/id_ed25519 ubuntu@$SERVER_IP 'sudo wg show'

# Full security audit (versions, updates, firewall status)
ssh -i ~/.ssh/id_ed25519 ubuntu@$SERVER_IP \
  'sudo bash /opt/wireguard/check-versions.sh'

# View setup logs
ssh -i ~/.ssh/id_ed25519 ubuntu@$SERVER_IP \
  'sudo tail -50 /var/log/wireguard-setup.log'

# Fail2ban banned IPs
ssh -i ~/.ssh/id_ed25519 ubuntu@$SERVER_IP \
  'sudo fail2ban-client status sshd'
```

---

## 📋 Requirements

- macOS (deploy script uses Finder double-click + macOS Keychain)
- AWS account
- GitHub account (optional — for IaC versioning)

---

## 📄 License

MIT — see [LICENSE](LICENSE) for details.
