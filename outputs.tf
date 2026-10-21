locals {
  # Commands are rendered with the key and port that were actually configured,
  # so they keep working when ssh_port or ssh_public_key_path are overridden.
  ssh_private_key = trimsuffix(var.ssh_public_key_path, ".pub")
  ssh_target      = "ubuntu@${aws_eip.wireguard.public_ip}"
  ssh_base        = "ssh -i ${local.ssh_private_key} -p ${var.ssh_port} ${local.ssh_target}"
  first_client    = var.wireguard_clients[0]
}

output "server_public_ip" {
  description = "Public IP of the VPN server. Client configs already point at it."
  value       = aws_eip.wireguard.public_ip
}

output "vpn_clients" {
  description = "Client configurations generated on the server."
  value       = var.wireguard_clients
}

output "ami_id" {
  description = "AMI the server was built from, for traceability."
  value       = aws_instance.wireguard.ami
}

output "ssh_command" {
  description = "Open a shell on the server."
  value       = local.ssh_base
}

output "fetch_client_configs" {
  description = "Download every client .conf into the current directory."
  value       = "scp -i ${local.ssh_private_key} -P ${var.ssh_port} ${local.ssh_target}:'~/wireguard-clients/*.conf' ."
}

output "show_qr_code" {
  description = "Print the QR code for the first client, ready to scan from the WireGuard mobile app."
  value       = "${local.ssh_base} 'cat ~/wireguard-clients/${local.first_client}-qrcode.txt'"
}

output "check_setup_status" {
  description = "Check whether the server finished bootstrapping."
  value       = "${local.ssh_base} 'sudo cat /var/log/wireguard-setup.log | tail -20'"
}

output "security_audit" {
  description = "Run the on-server audit: versions, pending security updates, firewall and peer status."
  value       = "${local.ssh_base} 'sudo /opt/wireguard/audit.sh'"
}

# ─── Post-deployment recap ────────────────────────────────────────────────────
# Single source: this text feeds both the next_steps output and the local file
# vpn-commands-<region>.txt. deploy.command prints it as is instead of writing
# its own commands: two hand-written blocks had drifted into two different
# destroy commands, one of them without aws-vault or the workspace.
#
# Nothing secret goes in here: an IP, a port, the PATH of the SSH key and
# commands. WireGuard keys stay on the server, then in the .conf files.

locals {
  commands_file = "${path.module}/vpn-commands-${var.aws_region}.txt"

  # Credentials are only needed by the destroy itself, not by workspace select.
  credentials_prefix = var.aws_vault_profile == null ? "" : "aws-vault exec --no-session ${var.aws_vault_profile} -- "
  destroy_command    = "cd '${abspath(path.module)}' && terraform workspace select ${terraform.workspace} && ${local.credentials_prefix}terraform destroy -var='aws_region=${var.aws_region}'"

  next_steps = <<-EOT

    WireGuard VPN: ${var.aws_region}, server ${aws_eip.wireguard.public_ip}
    Client endpoint: ${aws_eip.wireguard.public_ip}:${var.wireguard_port} (UDP)

    1. Bootstrapping takes 2-5 minutes after the apply. Check when it is done:
         ${local.ssh_base} 'sudo test -f /var/lib/wireguard-setup.done && echo READY || echo IN_PROGRESS'

    2. Download your client configurations:
         scp -i ${local.ssh_private_key} -P ${var.ssh_port} ${local.ssh_target}:'~/wireguard-clients/*.conf' .
       Delete them once imported: each .conf holds a device's private key.

    3. Mobile devices can scan a QR code instead:
         ${local.ssh_base} 'cat ~/wireguard-clients/${local.first_client}-qrcode.txt'

    4. Import the .conf file into the official WireGuard app and connect.

    Clients generated: ${join(", ", var.wireguard_clients)}

    Destroy everything when you are done (an allocated IPv4 address is billed
    by the hour even while the instance is stopped):
         ${local.destroy_command}

    These commands are also in ${abspath(local.commands_file)},
    which the destroy removes. While the state exists:
         terraform output -raw next_steps
  EOT
}

output "next_steps" {
  description = "What to do once the apply completes. Print it with: terraform output -raw next_steps"
  value       = local.next_steps
  # Not a secret: marked sensitive only so the apply does not print it on top of
  # deploy.command, which prints it once. -raw still shows it in clear.
  sensitive = true
}

output "commands_file" {
  description = "Local file holding this deployment's commands, removed on destroy."
  value       = abspath(local.commands_file)
}

# Created on apply, removed on destroy: the commands outlive the terminal
# window, not the infrastructure they describe. Git-ignored, mode 0600.
resource "local_file" "commands" {
  filename        = local.commands_file
  content         = local.next_steps
  file_permission = "0600"
}
