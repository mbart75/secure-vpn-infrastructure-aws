# AGENTS.md - secure-vpn-infrastructure-aws

Briefing for AI coding agents (and humans) working on this repository.
`CLAUDE.md` is a symlink to this file.

## What this is

An ephemeral WireGuard VPN server on AWS, defined in Terraform: a dedicated VPC,
one EC2 instance bootstrapped by `scripts/user_data.sh`, an Elastic IP, and a
security group that exposes only the WireGuard UDP port publicly. It is deployed
before a trip and destroyed after. Read `README.md` first: its "Design decisions"
and "Limitations" sections explain most choices that look odd.

## Layout

| Path | Role |
|---|---|
| `main.tf` | Network, IAM instance role, security group, key pair, EIP, instance |
| `variables.tf` | Every input, typed and validated |
| `outputs.tf` | Ready-to-run SSH, scp and audit commands |
| `scripts/user_data.sh` | Bootstrap, rendered by `templatefile()` and run once as root by cloud-init |
| `deploy.command`, `cleanup-vault.command` | Guided macOS scripts (aws-vault, workspaces) |
| `tests/` | Contract tests run by CI (Python `unittest`, some drive `terraform test`) |
| `.github/workflows/terraform.yml` | Static validation only, no AWS credentials |

## Commands

Everything below runs offline, without AWS credentials:

```bash
terraform fmt -check -recursive -diff
terraform init -backend=false -input=false
terraform validate
shellcheck --severity=warning deploy.command cleanup-vault.command
shellcheck --severity=error --exclude=SC1083,SC2154 scripts/user_data.sh
trivy config . --severity HIGH,CRITICAL --exit-code 1 --skip-dirs .terraform
python3 -m unittest discover -s tests -v
```

Run the whole sequence before proposing a change. CI runs the same steps on
every pull request, with Terraform pinned in the workflow.

## Hard rules

- **Never run `terraform plan`, `apply` or `destroy` against a real account,
  and never call AWS**, unless the maintainer explicitly asks for it in the
  current session. A deployment costs money and an interrupted destroy leaves
  billed resources behind.
- **Never read, print or copy `terraform.tfstate*`, `*.tfvars`, client `.conf`
  files, QR codes or SSH keys.** They describe a real deployment or hold key
  material, and they are gitignored for that reason.
- **No secret may reach Terraform.** WireGuard keys are generated on the
  instance on purpose: anything Terraform generates ends up in plaintext state.
- **Every input that reaches the bootstrap script must be validated in
  `variables.tf`**, with a test in `tests/test_terraform_inputs.py`. A value
  interpolated by `templatefile()` is re-read by Bash as root; `bash -n` and
  the IaC scanners do not catch an injected but syntactically valid line.
- **Public claims must match the code.** When a change alters behaviour, update
  the README in the same pull request. An unverifiable claim on a public
  security project is a bug.
- Do not silence a scanner finding globally. Accepted findings are annotated on
  the exact resource, with the reason, and a test keeps them scoped.
- Keep GitHub Actions pinned to full commit SHAs, with the version in a comment.
- English everywhere: code, comments, docs, commit messages (conventional
  commits).
- Before writing code for anything non-trivial, present the plan and wait for
  the maintainer's approval.

## Traps already hit

- **Templating**: in `scripts/user_data.sh`, a literal `${...}` must be written
  `$${...}`, otherwise `templatefile()` tries to resolve it. Render the template
  with dummy values, then run `bash -n` and ShellCheck on the result.
- **macOS runs `.command` files with bash 3.2**: no `declare -A`, and expanding
  an empty array under `set -u` aborts.
- **Ubuntu 24.04 starts sshd through `ssh.socket`**: the listening port and
  address come from the socket unit, not from `sshd_config` alone.
- **fail2ban 1.x reads an inline `; comment` as part of the value.** The same
  goes for `.gitignore`: a trailing `# comment` turns the pattern into a literal
  filename. Comments go on their own line.
- **Security group rule descriptions are ASCII only**, from a restricted
  character set: no apostrophes, no accents.
- **One Terraform workspace per region.** Reusing a state across regions
  orphans the previous region's resources, which keep billing.
