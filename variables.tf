variable "aws_region" {
  description = "Région AWS — choisir proche de toi pour la latence"
  type        = string
  default     = "eu-west-3" # Paris

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "La région doit être au format AWS valide (ex: eu-west-3)."
  }
}

variable "project_name" {
  description = "Préfixe pour toutes les ressources AWS créées"
  type        = string
  default     = "wireguard-perso"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,20}$", var.project_name))
    error_message = "Le nom doit faire 3-20 caractères, lettres minuscules, chiffres et tirets uniquement."
  }
}

variable "ssh_public_key_path" {
  description = "Chemin vers ta clé publique SSH"
  type        = string
  default     = "~/.ssh/id_ed25519.pub" # Ed25519 recommandé (plus sûr que RSA)
}

variable "ssh_port" {
  description = "Port SSH custom (évite les scans automatiques sur le port 22)"
  type        = number
  default     = 22 # Change si tu veux (ex: 2222) — pense à adapter le SG

  validation {
    condition     = var.ssh_port >= 1 && var.ssh_port <= 65535
    error_message = "Le port doit être entre 1 et 65535."
  }
}

variable "wireguard_port" {
  description = "Port UDP WireGuard"
  type        = number
  default     = 51820 # Standard WireGuard

  validation {
    condition     = var.wireguard_port >= 1024 && var.wireguard_port <= 65535
    error_message = "Le port WireGuard doit être entre 1024 et 65535."
  }
}

variable "wireguard_clients" {
  description = "Liste des clients VPN à créer automatiquement"
  type        = list(string)
  default     = [
    "1ProMax5",    # iPhone 1 Pro Max 5
    "1ProMax6",    # iPhone 1 Pro Max 6
    "MacBookAir",  # MacBook Air
    "Android",     # Téléphone Android
    "PCTablette"   # PC Tablette
  ]
  # Chaque entrée génère un .conf + QR code — un fichier par appareil
}
