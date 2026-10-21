# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub: **Security → Report a vulnerability** on this repository. Do not open a public issue.

Useful in a report: the affected file, what an attacker could do and from which position (internet, local network of a client, AWS account holder), and steps to reproduce. You will get an answer within a week.

## Scope

- The Terraform configuration: anything that exposes the instance beyond the WireGuard port, writes secret material to Terraform state, or lets an input reach the bootstrap script unvalidated.
- The bootstrap script `scripts/user_data.sh`: SSH, firewall, kernel and WireGuard configuration, and the handling of generated keys on the instance.
- The example IAM policy in the README: a way for the deploy identity to gain privileges beyond what the stack needs, such as a privilege-escalation chain.
- The guided scripts `deploy.command` and `cleanup-vault.command`: credential handling and anything they write or print.
- The CI workflow in `.github/workflows/`: anything that would let a pull request or a downloaded tool run unexpected code or get past a check that should fail.

Out of scope:

- Vulnerabilities in WireGuard, OpenSSH, Ubuntu, Terraform, its providers or AWS itself. Report those upstream.
- The trade-offs documented in the README under "What this does not protect against" and "Limitations", such as `ec2:*` within the allowed regions, local state, or the full-tunnel egress rule. A concrete way to narrow one of them is still welcome as an issue or pull request.
