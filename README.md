# Secure WireGuard VPN on AWS

Ephemeral, hardened WireGuard VPN infrastructure defined entirely in Terraform. Deploy it before a trip, destroy it when you get back, and pay nothing while it does not exist.

[![Terraform](https://img.shields.io/badge/Terraform-1.5%2B-844FBA?logo=terraform&logoColor=white)](https://developer.hashicorp.com/terraform)
[![AWS](https://img.shields.io/badge/AWS-EC2%20%7C%20VPC%20%7C%20IAM-FF9900?logo=amazonwebservices&logoColor=white)](https://aws.amazon.com)
[![WireGuard](https://img.shields.io/badge/WireGuard-kernel%20native-88171A?logo=wireguard&logoColor=white)](https://www.wireguard.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)
[![CI](https://github.com/mbart75/secure-vpn-infrastructure-aws/actions/workflows/terraform.yml/badge.svg?branch=main)](https://github.com/mbart75/secure-vpn-infrastructure-aws/actions/workflows/terraform.yml)

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

Public Wi-Fi on the road is untrusted by default, and commercial VPN providers ask you to trade one trusted third party for another. This project provisions a VPN server that **you** own, on infrastructure **you** control, from a configuration small enough to read end to end: about 600 lines of Terraform and one bootstrap script.

It is built to be ephemeral. Deploying takes one command, destroying takes one command, and nothing is left running between trips.

**Design principles**

- **Ephemeral by default** — the whole stack is disposable; redeploying is faster than maintaining it
- **No credentials on disk** — AWS keys live in the macOS Keychain via `aws-vault`, never in `~/.aws/credentials`
- **No secrets in Terraform state** — every WireGuard private key is generated on the instance, never by Terraform; a device's key leaves the server only inside the `.conf` file or QR code you fetch over SSH
- **Self-contained networking** — a dedicated VPC, not the account's default VPC
- **Bounded deployment identity** — project-scoped IAM and Session Manager access, region-scoped EC2 access, with the remaining EC2 breadth documented

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
  Instance role   Session Manager actions only   console access without SSH
  Deploy user     project-scoped IAM/SSM; EC2 scoped to an allow-list of regions
```

Every AWS resource of the stack is created by Terraform, so `terraform destroy` removes all of them. The deploy IAM user and its policy are the exception: you create them by hand once, as described in [IAM setup](#iam-setup), and they stay until you delete them.

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

When the apply completes, it prints the recap described below once, then the time the apply finished, in the local time of the machine that ran it:

```
  Deployment finished at 2026-10-21 18:42 CEST (local time)
  WireGuard is still installing on the server: allow 2 to 5 more minutes
```

The server is not polled: that time only tells you when it is worth checking.

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

Bootstrapping the server takes two to five minutes. Terraform renders every command you need, already filled in with your IP, port, key path, region and workspace, including the exact destroy command:

```bash
terraform output -raw next_steps
```

The output is marked sensitive only so that the apply does not print it on top of the guided script; it holds no secret, and `-raw` shows it in clear.

The same recap is written to **`vpn-commands-<region>.txt`** at the repository root (mode `0600`, git-ignored). Terraform creates it on apply and **removes it on destroy**, so the commands outlive the terminal window but not the infrastructure. It holds an IP, a port, the path of your SSH key and commands: no key material. With `aws_vault_profile` set, as `deploy.command` does, the destroy command goes through `aws-vault`; otherwise it is rendered without the prefix, for whatever credentials you use.

Check that the server has finished setting itself up:

```bash
eval "$(terraform output -raw ssh_command)" 'sudo test -f /var/lib/wireguard-setup.done && echo READY || echo IN_PROGRESS'
```

Then download your configuration files and import them into the WireGuard app:

```bash
eval "$(terraform output -raw fetch_client_configs)"
```

On a phone, scan the QR code instead:

```bash
eval "$(terraform output -raw show_qr_code)"
```

### Tearing it down

Run the destroy command from the recap or from `vpn-commands-<region>.txt`: it selects the right workspace and passes the region. With the plain Terraform workflow and the defaults, it boils down to:

```bash
terraform destroy
```

This deletes everything, including the Elastic IP. Your next deployment gets a new address, so client configurations have to be re-imported. That is the intended trade-off: an allocated IPv4 address is billed by the hour even when nothing is using it.

---

<a id="configuring-your-devices"></a>
## 📱 Configuring your devices

Every entry in `wireguard_clients` produces one `.conf` file and one QR code on the server, each with its own key pair, preshared key and address inside the tunnel. There is no shared configuration between devices, so removing one and reapplying revokes it: the apply replaces the server, and the removed device's keys go with the old instance.

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

Names accept letters, digits, hyphens and underscores, up to 32 characters, and must be unique. Addresses are allocated by Terraform from `vpn_network_cidr`, so a `/24` supports 253 devices.

**Adding or removing a device replaces the server.** The device list is rendered into the bootstrap script, which runs only at first boot. Applied in place, a new script would merely stop and start the instance, and WireGuard would keep its old peers, the removed one included. `user_data_replace_on_change` makes Terraform destroy the instance and create a new one instead. That is what turns a removal into a revocation, and it has consequences for every device:

- **The tunnel is down for a few minutes**, while the old instance is destroyed and the new one bootstraps (two to five minutes).
- **Every device needs its configuration again**, not only the one you added. The new server generates a new key pair for itself and for each device, so the old `.conf` files and QR codes stop working. Download and import them all again, as after the first deployment.
- **The public IP does not change.** The Elastic IP is a separate resource: it is kept and associated with the new instance.
- **SSH reports a changed host key.** The new instance has its own Ed25519 host key behind the same address. Remove the old entry before reconnecting: `ssh-keygen -R <ip>` with the default port, `ssh-keygen -R "[<ip>]:<ssh_port>"` otherwise.
- **The new instance boots the latest Ubuntu 24.04 AMI**, unless `ami_id` is pinned, and the old disk is deleted with everything on it, logs included.

Changing any other value rendered into the bootstrap script has the same effect: `ssh_port`, `wireguard_port`, `client_dns_servers`, `vpn_network_cidr` and `project_name`.

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
| `aws_vault_profile` | `null` | aws-vault profile used to render the destroy command; set by `deploy.command` |

Every variable is validated: malformed region names or CIDRs, a private key passed where a public key is expected, or more clients than the VPN network can hold all fail at plan time with an explicit message.

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
| Credentials | No static AWS credentials on the instance; the instance role allows the five Session Manager actions only, under a permissions boundary that excludes IAM and parameter reads |
| Supply chain | `.terraform.lock.hcl` is committed, pinning provider versions and their checksums |
| Local credentials | `aws-vault` keeps AWS keys in the macOS Keychain instead of a plaintext file |

### Server

| Control | Implementation |
|---|---|
| SSH authentication | Public key only; passwords and root login disabled; access limited to the `ubuntu` user |
| SSH cryptography | Only the Ed25519 host key is offered, DSA and ECDSA host keys deleted; modern ciphers and MACs; **hybrid post-quantum key exchange** when the installed OpenSSH offers one |
| SSH configuration | Applied as a `sshd_config.d` drop-in, validated with `sshd -t` and rolled back automatically if invalid |
| Brute force | `ufw limit` rate limiting, plus fail2ban banning for 24 hours after 3 failures in 10 minutes |
| Firewall | UFW default-deny inbound, only the SSH and WireGuard ports opened |
| Kernel | sysctl hardening: SYN cookies, reverse path filtering, no ICMP redirects or source routing, `kptr_restrict`, restricted ptrace, SysRq disabled |
| Patching | `unattended-upgrades` for security updates, with automatic reboots disabled so the tunnel is never dropped without warning |

### Tunnel

- **Modern cryptography** — WireGuard uses Curve25519, ChaCha20-Poly1305 and BLAKE2s, with no cipher negotiation to downgrade
- **Per-client preshared keys** — an extra symmetric layer on top of the handshake, which also hardens the tunnel against future quantum attacks on the key exchange
- **Post-quantum SSH key exchange** — the admin channel is covered too, see below
- **Full tunnel** — clients send all IPv4 and IPv6 traffic into the tunnel. IPv4 is forwarded to the internet; IPv6 is captured but not forwarded, since the server has no IPv6 egress, so it cannot leak around the VPN either
- **DNS** — resolvers are pushed to clients so lookups travel inside the tunnel rather than leaking to the local network
- **Key handling** — every private key is generated on the instance by `wg genkey` and never transits Terraform, so no key material ends up in state files or CI logs

### What this does not protect against

Being explicit matters more than a longer feature list:

- **The server sees your traffic.** A VPN moves the trust boundary to the exit node; it does not remove it. You are trusting yourself and AWS instead of a VPN vendor.
- **Traffic is attributable to you.** A dedicated IP address used only by your devices is a stronger identifier than a shared commercial VPN pool. This is a tool for securing untrusted networks, not for anonymity.
- **State is stored locally.** The default backend is a local state file. Terraform locks it against concurrent runs on the same machine, but it is not encrypted at rest and only the previous version is kept as a backup. That is appropriate for a single operator and unsuitable for a team; see [Design decisions](#design-decisions).
- **No IPv6 ingress.** The server is reachable over IPv4 only, so clients on IPv6-only networks cannot connect.

---

<a id="cost"></a>
## 💸 Cost

Prices are AWS on-demand list prices for `eu-west-3` (Paris), in US dollars, excluding tax, as published on 24 October 2026 on the [EC2](https://aws.amazon.com/ec2/pricing/on-demand/), [EBS](https://aws.amazon.com/ebs/pricing/) and [VPC](https://aws.amazon.com/vpc/pricing/) pricing pages. Check them for your region and date: `us-east-1`, for instance, is cheaper.

| Resource | While running | Free tier |
|---|---|---|
| EC2 `t3.micro` | $0.0118/hour, ~$8.61/month | 750 hours/month for 12 months on legacy free tier accounts |
| Public IPv4 address | $0.005/hour, ~$3.65/month | 750 hours/month for 12 months on legacy free tier accounts, while attached to a running instance. Billed since 1 February 2024 otherwise, including while the instance is stopped |
| EBS gp3, 8 GB | $0.0928/GB-month, ~$0.74/month | 30 GB/month for 12 months on legacy free tier accounts |
| Data transfer out | $0.09/GB | First 100 GB/month free account-wide |

**In practice:** roughly **$0.018/hour**, so about **$0.43/day** or **$3 for a week-long trip** on a paid account, before data transfer, and close to zero on an account still within the legacy 12-month free tier.

Accounts created since mid-2025 use the newer credit-based free plan rather than the 12-month free tier, so the "free tier" column may not apply. Verify against your own [billing console](https://console.aws.amazon.com/billing/) rather than trusting this table.

`terraform destroy` releases every billable resource, including the IPv4 address. Stopping the instance without destroying it still incurs the address and storage charges.

---

<a id="iam-setup"></a>
## 🔧 IAM setup

Create a dedicated IAM user for deployments rather than using your root account or an administrator. This policy limits IAM and Session Manager access to the VPN project and limits EC2 access to the regions you actually deploy to. The EC2 statement remains intentionally broad within those regions; that trade-off is documented below.

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
      "Sid": "SessionManagerDiscovery",
      "Effect": "Allow",
      "Action": [
        "ssm:DescribeSessions", "ssm:DescribeInstanceInformation",
        "ssm:GetConnectionStatus"
      ],
      "Resource": "*"
    },
    {
      "Sid": "StartSessionOnProjectInstances",
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringEquals": {
          "ssm:resourceTag/Project": "wireguard-vpn"
        }
      }
    },
    {
      "Sid": "StartDefaultSessionDocument",
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": "arn:aws:ssm:*:*:document/SSM-SessionManagerRunShell"
    },
    {
      "Sid": "ControlOwnSessions",
      "Effect": "Allow",
      "Action": ["ssm:TerminateSession", "ssm:ResumeSession"],
      "Resource": [
        "arn:aws:ssm:*:*:session/${aws:username}-*",
        "arn:aws:ssm:*:*:session/${aws:userid}-*"
      ]
    },
    {
      "Sid": "ManageProjectRoles",
      "Effect": "Allow",
      "Action": [
        "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole",
        "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:DetachRolePolicy",
        "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile", "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile", "iam:ListInstanceProfilesForRole",
        "iam:TagRole", "iam:UntagRole", "iam:TagInstanceProfile",
        "iam:UntagInstanceProfile",
        "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"
      ],
      "Resource": [
        "arn:aws:iam::*:role/wireguard-vpn-*",
        "arn:aws:iam::*:instance-profile/wireguard-vpn-*"
      ]
    },
    {
      "Sid": "GrantProjectRolesOnlyInsideTheBoundary",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:PutRolePolicy", "iam:PutRolePermissionsBoundary"
      ],
      "Resource": "arn:aws:iam::*:role/wireguard-vpn-*",
      "Condition": {
        "ArnEquals": {
          "iam:PermissionsBoundary": "arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy"
        }
      }
    },
    {
      "Sid": "PassProjectRoleToEc2Only",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::*:role/wireguard-vpn-*",
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

**Why role creation and `iam:PutRolePolicy` sit in their own statement.** Grouping them with the other IAM actions and scoping them with `"Resource": "arn:aws:iam::*:role/wireguard-vpn-*"` looks locked down, but it is not. For these actions, `Resource` names the role being created or modified — the target. It says nothing about *which permissions* the role ends up with. Without a condition, the answer is: any, including `"Action": "*"`.

That turns the deploy key into a full privilege-escalation chain. Create a role named `wireguard-vpn-anything` (`CreateRole` allows it — the prefix is chosen by the caller, so it protects nothing), give it an administrator policy, wrap it in an instance profile, pass it to an EC2 instance (`PassRole` + `ec2:*`), then read the role's credentials from IMDS. Five steps, none of them exploiting a bug: every one is explicitly granted by the policy.

The `iam:PermissionsBoundary` condition breaks step two. The deploy identity can create a project role, write its inline policy or set its boundary only when that boundary is `AmazonSSMManagedEC2InstanceDefaultPolicy`, an AWS managed policy nobody in your account can edit. A role's effective permissions are the intersection of its policies and its boundary, so whatever inline policy is written, the role can never exceed the boundary: SSM Agent operations, with no IAM access and no parameter reads. The stack itself writes a narrower inline policy, the five Session Manager actions; the boundary is the ceiling, not the grant. The policy grants neither `iam:AttachRolePolicy` nor `iam:DeleteRolePermissionsBoundary`, so a managed policy cannot be attached and the boundary cannot be removed. `iam:DetachRolePolicy`, and `iam:PutRolePermissionsBoundary` under the same condition, let an apply or a destroy migrate or clean up a role created by an earlier version of this stack, which attached `AmazonSSMManagedInstanceCore` and had no boundary. The `iam:PassedToService` condition on `PassRole` adds a second bound: project roles can only be handed to EC2, not to Lambda or any other service. This follows the delegation pattern of the [AWS documentation on permissions boundaries](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html#access_policies_boundaries-delegate).

**Why `PassRole` is scoped by name.** The boundary condition covers the roles the deploy identity creates or edits, not the roles it passes. `iam:PassRole` supports no `iam:PermissionsBoundary` condition key ([Service Authorization Reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_iam.html#list_iam-actions-as-permissions)), so the policy cannot require a passed role to carry the boundary. AWS also advises against gating `PassRole` on role tags, which give unreliable results ([Grant a user permissions to pass a role](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_passrole.html)), and a tag would protect nothing here: the policy grants `iam:TagRole` on project roles. What remains is the name and the service. Every IAM statement is scoped to `wireguard-vpn-*`, the prefix `main.tf` gives the role and the instance profile with the default `project_name`, so the key cannot pass, edit or delete any other `wireguard-*` role of the account. [`iam:PassedToService`](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html#ck_PassedToService) limits `PassRole` to EC2. The name cannot be pinned further: Terraform appends a unique suffix to the prefix, and it has to, because IAM names are global to the account and each regional deployment creates its own role. A `wireguard-vpn-*` role that this stack did not create can still be passed to an instance, see [Limitations](#limitations).

`ec2:*` is broader than least privilege. EC2 resource-level permissions do not cover every action this stack needs, in particular several `Describe*` calls that ignore resource conditions, so the region condition carries most of the restriction. Narrowing this further is on the [roadmap](#limitations). A caller holding the key can create, modify or delete EC2 and VPC resources in the six allowed regions, so prefer a dedicated account when that blast radius is unacceptable. The policy does prevent that caller from giving a project role more than its boundary allows.

The Session Manager statements keep the SSM fallback usable without granting a shell on every managed node in the account. `StartSession` is limited to instances tagged `Project=wireguard-vpn`, and a caller can resume or terminate only their own sessions. A session ID starts with the name of the IAM user who opened it, which `${aws:username}` matches, as the [AWS sample policies](https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-restrict-access-examples.html#restrict-access-example-user-sessions) prescribe for IAM users; `${aws:userid}` is the variable the same samples use for federated callers.

The role, the instance profile and the `Project` tag are all named after `project_name`. If you change it, replace `wireguard-vpn` everywhere in this deploy policy with the new value: the `Project` tag and the `wireguard-vpn-*` prefixes. Otherwise the apply fails on `iam:CreateRole` and Session Manager refuses the instance.

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

The audit script reports the OS, kernel, WireGuard and OpenSSH versions, the address SSH listens on, pending security updates, the firewall rules, the fail2ban SSH jail and each WireGuard peer with its latest handshake:

```bash
eval "$(terraform output -raw security_audit)"
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

**The SSH key exchange list is detected, not hardcoded.** A pinned `KexAlgorithms` list freezes cryptography at the date it was written and eventually becomes weaker than the upstream default — recent OpenSSH clients now warn that such a session is open to *store now, decrypt later*, where an adversary records traffic today and decrypts it once a quantum computer can break the classical exchange. Hybrid exchanges combine a classical and a lattice-based secret so both must fall. The list is therefore built from what `ssh -Q KexAlgorithms` reports on the instance at bootstrap: `mlkem768x25519-sha256` when present, `sntrup761x25519-sha512@openssh.com` otherwise. Hardcoding the former would break sshd on Ubuntu 24.04, which ships OpenSSH 9.6 while ML-KEM arrived in OpenSSH 9.9, and lock the operator out. On Ubuntu 24.04 the server therefore negotiates `sntrup761x25519`. Security updates keep OpenSSH at 9.6 and the list is not detected again after the first boot, so ML-KEM is only picked up by a new server built from an image that ships OpenSSH 9.9 or later, such as a newer Ubuntu release pinned through `ami_id`; a newer Ubuntu 24.04 AMI is not enough. The instance ignores AMI changes, so changing `ami_id` takes effect on the next replacement, not on a running server. This project is only tested on Ubuntu 24.04.

**SSH hardening is a drop-in, not a rewrite.** Replacing `/etc/ssh/sshd_config` wholesale drops the `Include` directive that Ubuntu ships and makes every `openssh-server` upgrade a conffile conflict, which is a poor outcome on a box that patches itself. A file in `sshd_config.d` overrides what it needs and leaves the packaged configuration to keep receiving upstream fixes.

**The SSH port change updates the systemd socket.** Ubuntu 24.04 starts sshd through socket activation, so the listening port comes from `ssh.socket` rather than from `sshd_config` alone. Changing only `sshd_config` and restarting the service leaves the listener on port 22 while the security group allows a different port, which locks the operator out. The bootstrap writes a socket override and reloads systemd.

**Local state, deliberately.** A single operator deploying disposable infrastructure gains nothing from an S3 backend and a lock table that cost more to maintain than the VPN itself. For anything shared, this belongs in S3 with `use_lockfile = true` and per-region state keys, and the configuration should become a module consumed per environment.

**One instance, no autoscaling, no monitoring stack.** A personal VPN that is redeployed in minutes does not need high availability. Adding it would be architecture for its own sake.

---

<a id="limitations"></a>
## ⚠️ Limitations

Known gaps, in rough priority order:

- **IPv4 only.** No IPv6 ingress, so clients on IPv6-only networks cannot connect.
- **`PassRole` trusts the role name.** The deploy key can pass to an EC2 instance any role whose name starts with `wireguard-vpn-`, including one that already exists in the account and that this stack did not create. Such a role may carry broad permissions and no boundary, and its credentials would then be readable from the instance metadata. AWS offers no `PassRole` condition on the passed role's boundary. Before granting the deploy policy, check that `aws iam list-roles --query "Roles[?starts_with(RoleName, 'wireguard-vpn-')].RoleName"` lists none that you did not deploy, or use a dedicated account. Neither Terraform nor `deploy.command` runs this check for you: it would need `iam:ListRoles`, which cannot be scoped by role name, on the very key whose theft is the threat, and a stolen key calls the API directly, without either of them. An honest deployment only ever passes the role it creates itself.
- **`ec2:*` in the deploy policy.** Restricted by region, not by resource. Narrowing it requires mapping each action this stack calls to its resource-level support.
- **Local state.** Locked on the local filesystem only, not encrypted at rest, one backup copy and no version history. Fine for one operator, wrong for a team.
- **Changing the client list replaces the instance.** Adding or removing a device reissues keys for every device, cuts the tunnel for a few minutes and means re-importing every configuration. Managing peers with `wg set` on a running server would avoid this.
- **No automated end-to-end test.** CI runs `fmt`, `validate`, `shellcheck`, a Trivy configuration scan and contract tests: actions pinned to commit SHAs and the Trivy archive checksum, the scope of the documented deploy policy, the instance role limited to Session Manager, validation of every input rendered into the bootstrap script, the setting that replaces the instance when its bootstrap script changes, the post-deployment commands file, and the git-ignore and scanner-ignore rules. The Terraform tests run `terraform test` in plan mode with mocked providers. Nothing in CI exercises a real deployment; that is validated by hand.
- **Unrestricted egress.** The security group allows all outbound traffic, because a full-tunnel VPN has to reach arbitrary destinations on behalf of its clients. A compromised server could reach them too.
- **The guided script is macOS only.** The Terraform configuration itself is platform independent.

---

<a id="project-structure"></a>
## 📁 Project structure

```
.
├── main.tf                     VPC, subnet, gateway, security group, IAM, EC2, Elastic IP
├── variables.tf                Inputs, all typed, documented and validated
├── outputs.tf                  Ready-to-run commands, the next_steps recap and vpn-commands-<region>.txt
├── terraform.tfvars.example    Annotated configuration template
├── .terraform.lock.hcl         Provider versions and checksums (committed on purpose)
├── AGENTS.md                   Briefing for coding agents (CLAUDE.md links to it)
├── SECURITY.md                 How to report a vulnerability
├── deploy.command              Guided deployment for macOS
├── cleanup-vault.command       Removes the local aws-vault and ~/.aws entries
├── scripts/
│   └── user_data.sh            Cloud-init bootstrap: WireGuard, firewall, hardening
├── tests/                      Contract tests run by CI
└── .github/
    ├── dependabot.yml          Keeps the SHA-pinned actions current
    └── workflows/
        └── terraform.yml       fmt, validate, shellcheck, Trivy config scan, tests
```

---

<a id="license"></a>
## 📄 License

[MIT](LICENSE) — use it, fork it, adapt it.
