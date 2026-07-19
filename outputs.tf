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

output "next_steps" {
  description = "What to do once the apply completes."
  value       = <<-EOT

    Deployment complete. Server: ${aws_eip.wireguard.public_ip}

    1. Bootstrapping takes 2-5 minutes. Check when it is done:
         ${local.ssh_base} 'sudo test -f /var/lib/wireguard-setup.done && echo READY || echo IN_PROGRESS'

    2. Download your client configurations:
         scp -i ${local.ssh_private_key} -P ${var.ssh_port} ${local.ssh_target}:'~/wireguard-clients/*.conf' .

    3. Mobile devices can scan a QR code instead:
         ${local.ssh_base} 'cat ~/wireguard-clients/${local.first_client}-qrcode.txt'

    4. Import the .conf file into the official WireGuard app and connect.

    Clients generated: ${join(", ", var.wireguard_clients)}

    Destroy everything when you are done (an allocated IPv4 address is billed
    by the hour even while the instance is stopped):
         terraform destroy
  EOT
}
