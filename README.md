# Secure WireGuard VPN on AWS

Ephemeral, hardened WireGuard VPN infrastructure defined entirely in Terraform. Deploy it before a trip, destroy it when you get back, and pay nothing while it does not exist.

[![Terraform](https://img.shields.io/badge/Terraform-1.5%2B-844FBA?logo=terraform&logoColor=white)](https://developer.hashicorp.com/terraform)
[![AWS](https://img.shields.io/badge/AWS-EC2%20%7C%20VPC%20%7C%20IAM-FF9900?logo=amazonwebservices&logoColor=white)](https://aws.amazon.com)
[![WireGuard](https://img.shields.io/badge/WireGuard-kernel%20native-88171A?logo=wireguard&logoColor=white)](https://www.wireguard.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

---

## 📖 Contents

- [Why this exists](#why-this-exists)
- [Architecture](#architecture)
- [Quick start](#quick-start)
- [Configuring your devices](#configuring-your-devices)
- [Configuration reference](#configuration-reference)
- [Security controls](#security-controls)
- [Cost](#cost)
- [IAM setup](#iam-setup)
- [Operating the server](#operating-the-server)
- [Design decisions](#design-decisions)
- [Limitations](#limitations)
- [Project structure](#project-structure)
- [License](#license)

---

<a id="why-this-exists"></a>
## 🎯 Why this exists

Public Wi-Fi on the road is untrusted by default, and commercial VPN providers ask you to trade one trusted third party for another. This project provisions a VPN server that **you** own, on infrastructure **you** control, from a configuration you can read end to end in about 300 lines.

It is built to be ephemeral. Deploying takes one command, destroying takes one command, and nothing is left running between trips.

**Design principles**

- **Ephemeral by default** — the whole stack is disposable; redeploying is faster than maintaining it
- **No credentials on disk** — AWS keys live in the macOS Keychain via `aws-vault`, never in `~/.aws/credentials`
- **No secrets in Terraform state** — every WireGuard private key is generated on the instance and never leaves it
- **Self-contained networking** — a dedicated VPC, not the account's default VPC
- **Least privilege** — a scoped IAM user for deploying, an instance role limited to Session Manager

---

<a id="architecture"></a>
## 🏗️ Architecture

```
Your device                          AWS region
┌──────────────┐                     ┌──────────────────────────────────────┐
│  WireGuard   │   UDP 443           │  VPC 10.20.0.0/24                    │
│  client      │ ──────────────────► │  └── Public subnet                   │
│              │   ChaCha20-Poly1305 │      └── EC2 t3.micro (Ubuntu 24.04) │
└──────────────┘                     │          ├── WireGuard (in kernel)   │
                                     │          ├── UFW + fail2ban          │
                                     │          └── unattended-upgrades     │
                                     │                                      │
                                     │  Elastic IP ── Internet Gateway ──►  │
                                     └──────────────────────────────────────┘

Security group
  UDP 443    from 0.0.0.0/0          the tunnel is authenticated and encrypted
  TCP 22     from your IP only       auto-detected at plan time
  egress     all                     package updates and client traffic

IAM
  Instance role   AmazonSSMManagedInstanceCore   console access without SSH
  Deploy user     scoped to one resource prefix and an allow-list of regions
```

All resources are created by Terraform, so `terraform destroy` removes all of them.

---

<a id="quick-start"></a>
## 🚀 Quick start

### Prerequisites

- An AWS account, and an IAM user set up as described in [IAM setup](#iam-setup)
- [Terraform](https://developer.hashicorp.com/terraform/downloads) 1.5 or newer
- An SSH key pair (`ssh-keygen -t ed25519` if you do not have one)
- The [WireGuard client](https://www.wireguard.com/install/) on each device you want to connect

### Option A — guided script (macOS)

```bash
bash deploy.command      # or double-click deploy.command in Finder
```

The script checks and updates your toolchain via Homebrew, stores your AWS keys in the macOS Keychain with `aws-vault`, asks which region and which devices you want, shows you the plan, and applies it after you confirm.

It never installs Homebrew for you, never edits your shell profile, and never runs a Git command: nothing from your working copy is committed or pushed anywhere.

### Option B — plain Terraform (any platform)

```bash
git clone https://github.com/mbart75/secure-vpn-infrastructure-aws.git
cd secure-vpn-infrastructure-aws

cp terraform.tfvars.example terraform.tfvars   # optional, all values have defaults
terraform init
terraform plan
terraform apply
```

Provide credentials the way you normally would: `AWS_PROFILE`, environment variables, SSO, or `aws-vault exec`.

### After the apply

Bootstrapping the server takes two to five minutes. Terraform prints every command you need, already filled in with your IP, port and key path:

```bash
terraform output next_steps
```

Check that the server has finished setting itself up:

```bash
eval "$(terraform output -raw ssh_command)" 'sudo test -f /var/lib/wireguard-setup.done && echo READY || echo IN_PROGRESS'
```

Then download your configuration files and import them into the WireGuard app:

```bash
$(terraform output -raw fetch_client_configs)
```

On a phone, scan the QR code instead:

```bash
$(terraform output -raw show_qr_code)
```

### Tearing it down

```bash
terraform destroy
```

This deletes everything, including the Elastic IP. Your next deployment gets a new address, so client configurations have to be re-imported. That is the intended trade-off: an allocated IPv4 address is billed by the hour even when nothing is using it.

---

<a id="configuring-your-devices"></a>
## 📱 Configuring your devices

Every entry in `wireguard_clients` produces one `.conf` file and one QR code on the server, each with its own key pair, preshared key and address inside the tunnel. There is no shared configuration between devices, so you can revoke one by removing it and reapplying.

**Choose at deploy time.** The guided script asks:

```
Devices, comma separated [default: phone,laptop]: phone,laptop,tablet
```

**Or set it in `terraform.tfvars`:**

```hcl
wireguard_clients = ["phone", "laptop", "tablet", "work-laptop"]
```

**Or pass it on the command line:**

```bash
terraform apply -var='wireguard_clients=["phone","laptop","tablet"]'
```

Names accept letters, digits, hyphens and underscores, up to 32 characters, and must be unique. Addresses are allocated by Terraform from `vpn_network_cidr`, so a `/24` supports 253 devices. Adding or removing a device rewrites the server configuration, which replaces the instance and issues fresh keys for everyone.

---

<a id="configuration-reference"></a>
## ⚙️ Configuration reference

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `eu-west-3` | Region to deploy into |
| `project_name` | `wireguard-vpn` | Prefix for every resource name |
| `wireguard_clients` | `["phone", "laptop"]` | Devices to generate configurations for |
| `allowed_ssh_cidr` | *auto-detected* | CIDR allowed to reach SSH; set explicitly to avoid auto-detection |
| `ssh_port` | `22` | SSH port; the server updates sshd and its socket unit to match |
| `wireguard_port` | `443` | WireGuard UDP port; 51820 is the standard, see below |
| `ssh_public_key_path` | `~/.ssh/id_ed25519.pub` | Public key installed on the server |
| `vpn_network_cidr` | `10.8.0.0/24` | Address range inside the tunnel |
| `vpc_cidr` | `10.20.0.0/24` | CIDR of the dedicated VPC |
| `client_dns_servers` | `["1.1.1.1", "1.0.0.1"]` | Resolvers pushed to clients |
| `instance_type` | `t3.micro` | EC2 instance type |
| `ami_id` | *latest Ubuntu 24.04* | Pin an AMI for reproducible rebuilds |

Every variable is validated: invalid regions, malformed CIDRs, a private key passed where a public key is expected, or more clients than the VPN network can hold all fail at plan time with an explicit message.

### A note on the default ports

**SSH stays on 22 on purpose.** Moving SSH to a high port is obscurity, not security: a port scan finds it in seconds. Here it would buy even less, because the security group already drops every packet from any address other than yours before it ever reaches the daemon. Access control is doing the work, not the port number. Moving it does cut noise in the auth log, and `ssh_port` is there if you want that, but be aware that restrictive networks are more likely to allow outbound 22 than an unusual port, which matters when the whole point is connecting from hotel and airport Wi-Fi.

**WireGuard defaults to UDP 443 here, not to its standard port.** To be clear about the deviation: WireGuard's registered port is **51820**, and that is what you will find in the upstream documentation and in most guides. This project deliberately ships 443 as the default instead.

The reason is the use case. This is a VPN for untrusted networks, and precisely those networks are the ones that filter VPN traffic by port. Being the well-known WireGuard port makes 51820 the easy target: hotel, corporate and campus Wi-Fi, some public hotspots, some mobile carriers, and national-level filtering all block it. Home ISPs rarely do, which is the trap — you deploy from home where 51820 works perfectly, and only discover the block on arrival, when fixing it means redeploying from that same restricted network and re-importing configurations on every device.

UDP 443 carries QUIC and HTTP/3, so it is almost never filtered and the traffic blends into ordinary web usage. Nothing else on this server listens on it, so the choice costs nothing.

**Going back to 51820** is one variable, either in `terraform.tfvars`:

```hcl
wireguard_port = 51820
```

or on the command line:

```bash
terraform apply -var='wireguard_port=51820'
```

Any port from 1 to 65535 is accepted. The security group, the server firewall and the generated client configurations all follow the value automatically.

Two caveats worth stating. On a network whose acceptable use policy forbids circumventing filtering, use the standard port and respect the policy. And this defeats port-based filtering only: WireGuard's handshake has a recognisable signature, so deep packet inspection can still identify and block the protocol on any port. Defeating that needs obfuscation the protocol does not provide on its own.

---

<a id="security-controls"></a>
## 🔐 Security controls

### Infrastructure

| Control | Implementation |
|---|---|
| Network isolation | Dedicated VPC, subnet, route table and internet gateway; the account's default VPC is never used |
| Ingress filtering | Security group allows only the WireGuard UDP port publicly; SSH is restricted to a single CIDR |
| Instance metadata | IMDSv2 required, PUT hop limit of 1, instance tags not exposed via metadata |
| Encryption at rest | EBS root volume encrypted |
| Credentials | No static AWS credentials on the instance; the instance role grants Session Manager only |
| Supply chain | `.terraform.lock.hcl` is committed, pinning provider versions and their checksums |
| Local credentials | `aws-vault` keeps AWS keys in the macOS Keychain instead of a plaintext file |

### Server

| Control | Implementation |
|---|---|
| SSH authentication | Public key only; passwords and root login disabled; access limited to the `ubuntu` user |
| SSH cryptography | Ed25519 host key only, DSA and ECDSA host keys deleted; modern KEX, ciphers and MACs only |
| SSH configuration | Applied as a `sshd_config.d` drop-in, validated with `sshd -t` and rolled back automatically if invalid |
| Brute force | `ufw limit` rate limiting, plus fail2ban banning for 24 hours after 3 failures in 10 minutes |
| Firewall | UFW default-deny inbound, only the SSH and WireGuard ports opened |
| Kernel | sysctl hardening: SYN cookies, reverse path filtering, no ICMP redirects or source routing, `kptr_restrict`, restricted ptrace, SysRq disabled |
| Patching | `unattended-upgrades` for security updates, with automatic reboots disabled so the tunnel is never dropped without warning |

### Tunnel

- **Modern cryptography** — WireGuard uses Curve25519, ChaCha20-Poly1305 and BLAKE2s, with no cipher negotiation to downgrade
- **Per-client preshared keys** — an extra symmetric layer on top of the handshake, which also hardens it against future quantum attacks on the key exchange
- **Full tunnel** — clients route all IPv4 and IPv6 traffic through the VPN
- **DNS** — resolvers are pushed to clients so lookups travel inside the tunnel rather than leaking to the local network
- **Key handling** — every private key is generated on the instance by `wg genkey` and never transits Terraform, so no key material ends up in state files or CI logs

### What this does not protect against

Being explicit matters more than a longer feature list:

- **The server sees your traffic.** A VPN moves the trust boundary to the exit node; it does not remove it. You are trusting yourself and AWS instead of a VPN vendor.
- **Traffic is attributable to you.** A dedicated IP address used only by your devices is a stronger identifier than a shared commercial VPN pool. This is a tool for securing untrusted networks, not for anonymity.
- **State is stored locally.** The default backend is a local state file with no locking or encryption at rest. That is appropriate for a single operator and unsuitable for a team; see [Design decisions](#design-decisions).
- **No IPv6 ingress.** The server is reachable over IPv4 only, so clients on IPv6-only networks cannot connect.

---

<a id="cost"></a>
## 💸 Cost

Prices are for `eu-west-3` and exclude tax. Check the [AWS pricing pages](https://aws.amazon.com/ec2/pricing/on-demand/) for your region.

| Resource | While running | Free tier |
|---|---|---|
| EC2 `t3.micro` | ~$0.0104/hour, ~$7.60/month | 750 hours/month for 12 months on legacy free tier accounts |
| Public IPv4 address | $0.005/hour, ~$3.65/month | Not free. Billed since 1 February 2024 whenever allocated, including while the instance is stopped |
| EBS gp3, 8 GB | ~$0.64/month | 30 GB/month for 12 months on legacy free tier accounts |
| Data transfer out | ~$0.09/GB | First 100 GB/month free account-wide |

**In practice:** roughly **$0.015/hour**, so about **$0.36/day** or **$2.50 for a week-long trip** on a paid account, and close to zero on an account still within the 12-month free tier apart from the IPv4 charge.

Accounts created since mid-2025 use the newer credit-based free plan rather than the 12-month free tier, so the "free tier" column may not apply. Verify against your own [billing console](https://console.aws.amazon.com/billing/) rather than trusting this table.

`terraform destroy` releases every billable resource, including the IPv4 address. Stopping the instance without destroying it still incurs the address and storage charges.

---

<a id="iam-setup"></a>
## 🔧 IAM setup

Create a dedicated IAM user for deployments rather than using your root account or an administrator. This policy limits it to the regions you actually deploy to and to resources carrying the project prefix.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2AndVPCInAllowedRegions",
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
      "Sid": "SessionManagerAccess",
      "Effect": "Allow",
      "Action": [
        "ssm:StartSession", "ssm:TerminateSession", "ssm:ResumeSession",
        "ssm:DescribeSessions", "ssm:DescribeInstanceInformation",
        "ssm:GetConnectionStatus"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ManageProjectRoles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole",
        "iam:DetachRolePolicy",
        "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile", "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile", "iam:ListInstanceProfilesForRole",
        "iam:TagRole", "iam:UntagRole", "iam:TagInstanceProfile",
        "iam:UntagInstanceProfile",
        "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"
      ],
      "Resource": [
        "arn:aws:iam::*:role/wireguard-*",
        "arn:aws:iam::*:instance-profile/wireguard-*"
      ]
    },
    {
      "Sid": "AttachOnlySsmCoreToProjectRoles",
      "Effect": "Allow",
      "Action": "iam:AttachRolePolicy",
      "Resource": "arn:aws:iam::*:role/wireguard-*",
      "Condition": {
        "ArnEquals": {
          "iam:PolicyARN": "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
        }
      }
    },
    {
      "Sid": "PassProjectRoleToEc2Only",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::*:role/wireguard-*",
      "Condition": {
        "StringEquals": { "iam:PassedToService": "ec2.amazonaws.com" }
      }
    },
    {
      "Sid": "CallerIdentity",
      "Effect": "Allow",
      "Action": ["sts:GetCallerIdentity", "sts:GetSessionToken"],
      "Resource": "*"
    }
  ]
}
```

**Why `iam:AttachRolePolicy` sits in its own statement.** Grouping it with the other IAM actions and scoping it with `"Resource": "arn:aws:iam::*:role/wireguard-*"` looks locked down, but it is not. For that action, `Resource` names the role being modified — the target. It says nothing about *which policy* gets attached to it. Without a condition on `iam:PolicyARN`, the answer is: any policy, including `AdministratorAccess`.

That turns the deploy key into a full privilege-escalation chain. Create a role named `wireguard-anything` (`CreateRole` allows it — the prefix is chosen by the caller, so it protects nothing), attach `AdministratorAccess` to it, wrap it in an instance profile, pass it to an EC2 instance (`PassRole` + `ec2:*`), then read the role's credentials from IMDS. Five steps, none of them exploiting a bug: every one is explicitly granted by the policy.

The `ArnEquals` condition on `iam:PolicyARN` restricts attachment to `AmazonSSMManagedInstanceCore`, the only policy this stack actually needs, which breaks step two. The `iam:PassedToService` condition on `PassRole` adds a second bound: project roles can only be handed to EC2, not to Lambda or any other service.

`ec2:*` is broader than ideal. EC2 resource-level permissions do not cover every action this stack needs, in particular several `Describe*` calls that ignore resource conditions, so the region condition carries most of the restriction. Narrowing this further is on the [roadmap](#limitations). A caller holding the key can still create EC2 resources in the six allowed regions — but can no longer grant itself administrator access to the account.

The `SessionManagerAccess` statement is what makes the SSM fallback usable: if your IP changes while travelling and SSH no longer matches the security group, you can still reach the instance with `aws ssm start-session --target <instance-id>`.

---

<a id="operating-the-server"></a>
## 🔍 Operating the server

Terraform renders every command with the port and key path you configured:

```bash
terraform output ssh_command            # open a shell
terraform output fetch_client_configs   # download all client .conf files
terraform output show_qr_code           # QR code for the first client
terraform output security_audit         # run the on-server audit
terraform output check_setup_status     # tail the bootstrap log
```

The audit script reports installed versions, pending security updates, listening ports, firewall state, fail2ban status and connected peers:

```bash
$(terraform output -raw security_audit)
```

Deploying to more than one region is supported through Terraform workspaces, one per region. The guided script handles this automatically; by hand:

```bash
terraform workspace select -or-create eu-west-3
terraform apply -var='aws_region=eu-west-3'
```

Using a single workspace across regions would leave the previous region's resources running with no way to destroy them.

---

<a id="design-decisions"></a>
## 🧭 Design decisions

Notes on the trade-offs, since the reasoning is more interesting than the resource list.

**A dedicated VPC instead of the default VPC.** Default VPCs are routinely deleted in hardened or organization-managed accounts, and depending on one makes the stack fail with an opaque `VPCIdNotSpecified` error. A VPC, subnet, gateway and route table cost nothing and make the configuration portable to any account.

**The Elastic IP is allocated before the instance.** The client configurations need the server's public address baked in. Reading it from instance metadata during boot races the address association and can embed an address that is discarded moments later, leaving clients that hand-shake against nothing. Allocating the address first, injecting it through `templatefile`, and associating it afterwards keeps the dependency graph acyclic and the result deterministic.

**Private keys are generated on the instance.** Terraform could generate them with the `tls` provider, but anything Terraform generates is written to state in plaintext. Generating them on the server keeps the state file free of secrets, at the cost of retrieving configurations over SSH.

**SSH hardening is a drop-in, not a rewrite.** Replacing `/etc/ssh/sshd_config` wholesale drops the `Include` directive that Ubuntu ships and makes every `openssh-server` upgrade a conffile conflict, which is a poor outcome on a box that patches itself. A file in `sshd_config.d` overrides what it needs and leaves the packaged configuration to keep receiving upstream fixes.

**The SSH port change updates the systemd socket.** Ubuntu 24.04 starts sshd through socket activation, so the listening port comes from `ssh.socket` rather than from `sshd_config` alone. Changing only `sshd_config` and restarting the service leaves the listener on port 22 while the security group allows a different port, which locks the operator out. The bootstrap writes a socket override and reloads systemd.

**Local state, deliberately.** A single operator deploying disposable infrastructure gains nothing from an S3 backend and a lock table that cost more to maintain than the VPN itself. For anything shared, this belongs in S3 with `use_lockfile = true` and per-region state keys, and the configuration should become a module consumed per environment.

**One instance, no autoscaling, no monitoring stack.** A personal VPN that is redeployed in minutes does not need high availability. Adding it would be architecture for its own sake.

---

<a id="limitations"></a>
## ⚠️ Limitations

Known gaps, in rough priority order:

- **IPv4 only.** No IPv6 ingress, so clients on IPv6-only networks cannot connect.
- **`ec2:*` in the deploy policy.** Restricted by region, not by resource. Narrowing it requires mapping each action this stack calls to its resource-level support.
- **Local state.** No locking, no encryption at rest, no history. Fine for one operator, wrong for a team.
- **Changing the client list replaces the instance.** Adding a device reissues keys for every device. Managing peers with `wg set` on a running server would avoid this.
- **Automated testing is static only.** CI runs `fmt`, `validate`, `shellcheck` and a Trivy configuration scan; there is no `terraform test` suite exercising a real deployment.
- **The guided script is macOS only.** The Terraform configuration itself is platform independent.

---

<a id="project-structure"></a>
## 📁 Project structure

```
.
├── main.tf                     VPC, subnet, gateway, security group, IAM, EC2, Elastic IP
├── variables.tf                Inputs, all typed, documented and validated
├── outputs.tf                  Connection details and ready-to-run commands
├── terraform.tfvars.example    Annotated configuration template
├── .terraform.lock.hcl         Provider versions and checksums (committed on purpose)
├── deploy.command              Guided deployment for macOS
├── cleanup-vault.command       Removes the local aws-vault and ~/.aws entries
├── scripts/
│   └── user_data.sh            Cloud-init bootstrap: WireGuard, firewall, hardening
└── .github/workflows/
    └── terraform.yml           fmt, validate, shellcheck, Trivy config scan
```

---

<a id="license"></a>
## 📄 License

[MIT](LICENSE) — use it, fork it, adapt it.
