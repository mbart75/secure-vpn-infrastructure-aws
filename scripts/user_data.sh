#!/bin/bash
# ==============================================================================
# WireGuard - Installation sécurisée & future-proof
# Bonnes pratiques : OWASP, CIS Benchmark, hardening Linux
# ==============================================================================

set -euo pipefail
LOG="/var/log/wireguard-setup.log"
exec > >(tee -a "$LOG") 2>&1
# Restreindre immédiatement les permissions du log (données opérationnelles sensibles)
touch "$LOG"
chmod 600 "$LOG"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         WireGuard Setup - $(date '+%Y-%m-%d %H:%M:%S')          ║"
echo "╚══════════════════════════════════════════════════════════╝"

WG_PORT="${wg_port}"
SSH_PORT="${ssh_port}"
PROJECT="${project_name}"
CLIENTS_JSON='${wg_clients}'
WG_DIR="/etc/wireguard"
CLIENTS_DIR="/home/ubuntu/wireguard-clients"
OPT_DIR="/opt/wireguard"

# ──────────────────────────────────────────────────────────────────────────────
# 1. MISE À JOUR SYSTÈME COMPLÈTE (future-proof : toujours les derniers patchs)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "▶ [1/9] Mise à jour système..."

# Forcer le mode non-interactif pour éviter les dialogs debconf/whiptail
export DEBIAN_FRONTEND=noninteractive

# Pré-configurer debconf pour ne pas demander de redémarrage interactif
echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
echo '* libraries/restart-without-asking boolean true' | debconf-set-selections

apt-get update -y
apt-get upgrade -y \
  -o Dpkg::Options::='--force-confdef' \
  -o Dpkg::Options::='--force-confold'
apt-get dist-upgrade -y \
  -o Dpkg::Options::='--force-confdef' \
  -o Dpkg::Options::='--force-confold'

# Mises à jour automatiques de sécurité (OWASP A06 - Vulnerable Components)
apt-get install -y unattended-upgrades apt-listchanges
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "$${distro_id}:$${distro_codename}-security";
    "$${distro_id}ESMApps:$${distro_codename}-apps-security";
    "$${distro_id}ESM:$${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";  // Pas de reboot auto = pas de coupure VPN
Unattended-Upgrade::SyslogEnable "true";
EOF

echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "✅ Système à jour"

# ──────────────────────────────────────────────────────────────────────────────
# 2. INSTALLATION WIREGUARD (toujours la dernière version)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "▶ [2/9] Installation WireGuard..."

# WireGuard est dans le noyau Linux depuis 5.6 (Ubuntu 24.04 = kernel 6.x)
# → apt install wireguard installe toujours la version du noyau actuel
apt-get install -y wireguard wireguard-tools qrencode

WG_VERSION=$(dpkg -l wireguard-tools | awk '/wireguard-tools/{print $3}')
echo "✅ WireGuard installé — version : $WG_VERSION"
echo "   Kernel : $(uname -r)"

# ──────────────────────────────────────────────────────────────────────────────
# 3. HARDENING SSH
# OWASP A07 - Identification and Authentication Failures
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "▶ [3/9] Hardening SSH..."

# Backup de la config originale
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

cat > /etc/ssh/sshd_config << EOF
# ── WireGuard Server SSH Config (Hardened) ──
Port $SSH_PORT
AddressFamily inet
ListenAddress 0.0.0.0

# Protocole et crypto modernes uniquement
Protocol 2
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

# Algorithmes sécurisés (NIST/OpenSSH recommandations 2024)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com

# Authentification — clé uniquement, jamais de mot de passe
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
# UsePAM yes : Ubuntu 24.04 nécessite PAM pour la gestion des sessions systemd
# Les passwords sont désactivés ci-dessus — PAM ne sert qu'à la session, pas à l'auth
UsePAM yes

# Restrictions de session
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

# Désactiver les fonctionnalités inutiles et risquées
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
GatewayPorts no
PrintMotd yes

# Logging
SyslogFacility AUTH
LogLevel VERBOSE

# Restreindre à l'utilisateur ubuntu uniquement
AllowUsers ubuntu

# SFTP subsystem (nécessaire pour scp)
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

# Régénérer uniquement les clés hôtes modernes (supprimer les existantes d'abord)
rm -f /etc/ssh/ssh_host_dsa_key* /etc/ssh/ssh_host_ecdsa_key* \
      /etc/ssh/ssh_host_ed25519_key* /etc/ssh/ssh_host_rsa_key*
ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -q
ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N "" -q

systemctl restart ssh
echo "✅ SSH hardené — authentification par clé uniquement"

# ──────────────────────────────────────────────────────────────────────────────
# 4. HARDENING KERNEL (sysctl)
# OWASP A05 - Security Misconfiguration
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "▶ [4/9] Hardening kernel (sysctl)..."

cat > /etc/sysctl.d/99-wireguard-hardening.conf << 'EOF'
# ── Réseau ──
# Activation du forwarding IP (indispensable pour WireGuard)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Protection SYN flood
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2

# Protection contre le spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Désactiver les redirections ICMP
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Désactiver les source routes
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Log des paquets suspects (martians)
net.ipv4.conf.all.log_martians = 1

# ── Mémoire & Processus ──
# Protection Stack Smashing
kernel.randomize_va_space = 2

# Restreindre l'accès aux logs kernel
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2

# Désactiver le SysRq (accès console non autorisé)
kernel.sysrq = 0

# Protection ptrace (empêche un process de lire la mémoire d'un autre)
kernel.yama.ptrace_scope = 1
EOF

sysctl --system
echo "✅ Kernel hardené"

# ──────────────────────────────────────────────────────────────────────────────
# 5. PARE-FEU UFW
# OWASP A05 - Security Misconfiguration
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "▶ [5/9] Configuration UFW..."

apt-get install -y ufw

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow $SSH_PORT/tcp comment "SSH"

# WireGuard
ufw allow $WG_PORT/udp comment "WireGuard VPN"

# Limiter les tentatives SSH (brute force protection)
ufw limit $SSH_PORT/tcp comment "SSH rate limit"

ufw --force enable
ufw status verbose
echo "✅ UFW configuré"

# ──────────────────────────────────────────────────────────────────────────────
# 6. FAIL2BAN (protection brute force SSH)
# OWASP A07 - Identification and Authentication Failures
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "▶ [6/9] Installation Fail2ban..."

apt-get install -y fail2ban

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 3600      ; Ban 1 heure
findtime = 600       ; Fenêtre de 10 minutes
maxretry = 3         ; 3 tentatives max
backend  = systemd

[sshd]
enabled  = true
port     = $SSH_PORT
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 86400     ; SSH : ban 24h
EOF

systemctl enable fail2ban
systemctl restart fail2ban
echo "✅ Fail2ban actif"

# ──────────────────────────────────────────────────────────────────────────────
# 7. CONFIGURATION WIREGUARD
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "▶ [7/9] Configuration WireGuard..."

mkdir -p "$WG_DIR" "$CLIENTS_DIR"
chmod 700 "$WG_DIR"
chmod 700 "$CLIENTS_DIR"

# Génération des clés serveur
SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
# NOTE : pas de preshared key serveur globale — une PSK par client est générée plus bas

echo "Clé publique serveur : $SERVER_PUBLIC_KEY"

# Obtenir l'IP publique de l'instance (avec IMDSv2 obligatoire)
TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
SERVER_PUBLIC_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/public-ipv4")

echo "IP publique détectée : $SERVER_PUBLIC_IP"

# Interface réseau principale
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
echo "Interface réseau : $MAIN_IFACE"

# Génération dynamique des clients depuis la liste JSON Terraform
# On parse le JSON avec Python (toujours dispo sur Ubuntu)
readarray -t CLIENTS < <(echo "$CLIENTS_JSON" | python3 -c "
import json, sys
clients = json.load(sys.stdin)
for c in clients:
    print(c)
")

echo "Clients à créer : $${CLIENTS[*]}"

# Construction de la config serveur
cat > "$WG_DIR/wg0.conf" << EOF
[Interface]
# Serveur WireGuard — généré le $(date '+%Y-%m-%d %H:%M:%S')
PrivateKey = $SERVER_PRIVATE_KEY
Address    = 10.8.0.1/24
ListenPort = $WG_PORT
DNS        = 1.1.1.1, 1.0.0.1   # Cloudflare — change si tu veux

# Règles NAT pour faire transiter le trafic clients vers internet
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $MAIN_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $MAIN_IFACE -j MASQUERADE

EOF

chmod 600 "$WG_DIR/wg0.conf"

# Génération d'un fichier .conf par client
CLIENT_IP_BASE=2  # 10.8.0.2, 10.8.0.3, ...

for CLIENT_NAME in "$${CLIENTS[@]}"; do
  echo "  → Création client : $CLIENT_NAME"

  CLIENT_PRIVATE_KEY=$(wg genkey)
  CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
  CLIENT_PRESHARED_KEY=$(wg genpsk)   # Couche de sécurité supplémentaire
  CLIENT_IP="10.8.0.$CLIENT_IP_BASE"

  # Ajouter le peer dans la config serveur
  cat >> "$WG_DIR/wg0.conf" << EOF
# ── Client : $CLIENT_NAME ──
[Peer]
PublicKey    = $CLIENT_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY  # Protection forward secrecy supplémentaire
AllowedIPs   = $CLIENT_IP/32

EOF

  # Créer le fichier .conf client
  cat > "$CLIENTS_DIR/$CLIENT_NAME.conf" << EOF
[Interface]
# WireGuard Client — $CLIENT_NAME
# Généré le $(date '+%Y-%m-%d %H:%M:%S')
PrivateKey = $CLIENT_PRIVATE_KEY
Address    = $CLIENT_IP/24
DNS        = 1.1.1.1, 1.0.0.1

[Peer]
# Serveur AWS — $PROJECT
PublicKey    = $SERVER_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY
Endpoint     = $SERVER_PUBLIC_IP:$WG_PORT
AllowedIPs   = 0.0.0.0/0, ::/0   # Tout le trafic passe par le VPN (full tunnel)
PersistentKeepalive = 25            # Maintient la connexion sur mobile (NAT)
EOF

  chmod 600 "$CLIENTS_DIR/$CLIENT_NAME.conf"
  chown ubuntu:ubuntu "$CLIENTS_DIR/$CLIENT_NAME.conf"

  # Générer aussi un QR code pour import rapide sur mobile
  qrencode -t ansiutf8 < "$CLIENTS_DIR/$CLIENT_NAME.conf" \
    > "$CLIENTS_DIR/$CLIENT_NAME-qrcode.txt" 2>/dev/null || true

  echo "     ✅ $CLIENT_NAME → IP: $CLIENT_IP | Fichier: $CLIENT_NAME.conf"
  CLIENT_IP_BASE=$((CLIENT_IP_BASE + 1))
done

chown -R ubuntu:ubuntu "$CLIENTS_DIR"

# Démarrer WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo "✅ WireGuard démarré"
wg show wg0

# ──────────────────────────────────────────────────────────────────────────────
# 8. SCRIPT DE VÉRIFICATION DES VERSIONS (future-proof)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "▶ [8/9] Création du script de vérification des versions..."

mkdir -p "$OPT_DIR"

cat > "$OPT_DIR/check-versions.sh" << 'VERSIONSCRIPT'
#!/bin/bash
# Vérifie les versions installées et les mises à jour disponibles
echo "════════════════════════════════════════"
echo " Audit des versions — $(date '+%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════"
echo ""
echo "🔵 Système"
echo "   OS      : $(lsb_release -d | cut -f2)"
echo "   Kernel  : $(uname -r)"
echo ""
echo "🟢 WireGuard"
WG_INSTALLED=$(dpkg -l wireguard-tools 2>/dev/null | awk '/wireguard-tools/{print $3}')
WG_AVAILABLE=$(apt-cache policy wireguard-tools 2>/dev/null | grep Candidate | awk '{print $2}')
echo "   Installé   : $WG_INSTALLED"
echo "   Disponible : $WG_AVAILABLE"
[ "$WG_INSTALLED" != "$WG_AVAILABLE" ] && echo "   ⚠️  MISE À JOUR DISPONIBLE" || echo "   ✅ À jour"
echo ""
echo "🟡 SSH"
echo "   $(ssh -V 2>&1)"
echo ""
echo "🔴 Fail2ban"
fail2ban-client status sshd 2>/dev/null || echo "   Service actif"
echo ""
echo "🔥 UFW"
ufw status numbered
echo ""
echo "📦 Paquets avec mises à jour de sécurité disponibles :"
apt list --upgradable 2>/dev/null | grep -i security || echo "   ✅ Aucun"
echo ""
echo "🔒 WireGuard Status"
wg show
VERSIONSCRIPT

chmod +x "$OPT_DIR/check-versions.sh"
echo "✅ Script de vérification créé dans $OPT_DIR/check-versions.sh"

# ──────────────────────────────────────────────────────────────────────────────
# 9. MOTD PERSONNALISÉ + RÉSUMÉ FINAL
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "▶ [9/9] Finalisation..."

# Message de connexion SSH personnalisé
cat > /etc/motd << EOF

╔══════════════════════════════════════════════════════╗
║              🔒 WireGuard VPN Server                 ║
║              Projet : $PROJECT
╠══════════════════════════════════════════════════════╣
║  wg show                  → Status WireGuard         ║
║  sudo systemctl status wg-quick@wg0                  ║
║  sudo /opt/wireguard/check-versions.sh               ║
╚══════════════════════════════════════════════════════╝

EOF

# Résumé final dans les logs
echo ""
echo "════════════════════════════════════════════════════════════"
echo " ✅ INSTALLATION TERMINÉE — $(date '+%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════════════════════════"
echo " Serveur IP     : $SERVER_PUBLIC_IP"
echo " Port WireGuard : $WG_PORT/UDP"
echo " Port SSH       : $SSH_PORT/TCP"
echo " Clients créés  : $${CLIENTS[*]}"
echo " Configs dispo  : $CLIENTS_DIR/"
echo "════════════════════════════════════════════════════════════"
echo ""
echo " Récupérer les configs depuis ton PC :"
echo " scp ubuntu@$SERVER_PUBLIC_IP:'$CLIENTS_DIR/*.conf' ./"
echo ""
