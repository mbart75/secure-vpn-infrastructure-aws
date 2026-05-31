output "server_public_ip" {
  description = "IP publique fixe du serveur WireGuard"
  value       = aws_eip.wireguard.public_ip
}

output "ssh_connection" {
  description = "Commande SSH pour se connecter"
  value       = "ssh -i ~/.ssh/id_ed25519 -p ${var.ssh_port} ubuntu@${aws_eip.wireguard.public_ip}"
}

output "get_configs" {
  description = "Récupérer TOUS les fichiers .conf clients en une commande"
  value       = "scp -i ~/.ssh/id_ed25519 -P ${var.ssh_port} ubuntu@${aws_eip.wireguard.public_ip}:'~/wireguard-clients/*.conf' ./"
}

output "check_setup_log" {
  description = "Vérifier les logs d'installation depuis le serveur"
  value       = "ssh -i ~/.ssh/id_ed25519 -p ${var.ssh_port} ubuntu@${aws_eip.wireguard.public_ip} 'sudo tail -50 /var/log/wireguard-setup.log'"
}

output "check_versions" {
  description = "Vérifier les versions installées (audit)"
  value       = "ssh -i ~/.ssh/id_ed25519 -p ${var.ssh_port} ubuntu@${aws_eip.wireguard.public_ip} 'sudo bash /opt/wireguard/check-versions.sh'"
}

output "ami_used" {
  description = "AMI Ubuntu utilisée (pour traçabilité)"
  value       = data.aws_ami.ubuntu.id
}

output "setup_instructions" {
  value = <<-EOT
    ========================================
    ✅ Déploiement terminé !
    
    1. Attends 2-3 min (installation en cours)
    2. Récupère tes configs :
       scp -i ~/.ssh/id_ed25519 -P ${var.ssh_port} ubuntu@${aws_eip.wireguard.public_ip}:'~/wireguard-clients/*.conf' ./
    3. Importe le .conf dans l'app WireGuard
    4. Connecte-toi !
    
    💰 Pour économiser : terraform destroy -auto-approve
       (L'Elastic IP est libérée, aucun frais résiduel)
    ========================================
  EOT
}
