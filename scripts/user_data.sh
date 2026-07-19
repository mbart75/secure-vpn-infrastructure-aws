#!/bin/bash
# ==============================================================================
# WireGuard VPN server bootstrap — Ubuntu 24.04 LTS
#
# Rendered by Terraform via templatefile(); see the user_data block in main.tf.
# Because of that, a literal dollar-brace sequence must be written doubled ($$)
# so it survives templating and reaches the shell intact.
#
# Runs once, at first boot, as root, under cloud-init.
# ==============================================================================
set -euo pipefail

LOG="/var/log/wireguard-setup.log"
DONE_MARKER="/var/lib/wireguard-setup.done"

install -m 600 /dev/null "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "[FAILED] bootstrap aborted on line $LINENO"' ERR

# ── Values injected by Terraform ──────────────────────────────────────────────
PROJECT="${project_name}"
SSH_PORT="${ssh_port}"
WG_PORT="${wg_port}"
SERVER_PUBLIC_IP="${server_public_ip}"
SERVER_VPN_ADDRESS="${server_vpn_address}"
CLIENT_DNS="${client_dns}"
# Space separated "name:address" pairs. Names are validated in variables.tf.
CLIENT_SPECS="${client_specs}"

WG_DIR="/etc/wireguard"
CLIENTS_DIR="/home/ubuntu/wireguard-clients"
OPT_DIR="/opt/wireguard"

echo "=============================================="
echo " WireGuard bootstrap — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo " Project: $PROJECT"
echo "=============================================="

# ──────────────────────────────────────────────────────────────────────────────
# 1. System packages
# ──────────────────────────────────────────────────────────────────────────────
echo "[1/8] Updating the system and installing packages..."

export DEBIAN_FRONTEND=noninteractive
echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
echo '* libraries/restart-without-asking boolean true' | debconf-set-selections

apt-get update -y

# dist-upgrade is a superset of upgrade, so running both only duplicates work.
apt-get dist-upgrade -y \
  -o Dpkg::Options::='--force-confdef' \
  -o Dpkg::Options::='--force-confold'

# One transaction rather than five: fewer dependency resolutions, faster boot.
apt-get install -y \
  wireguard \
  wireguard-tools \
  qrencode \
  ufw \
  fail2ban \
  python3-systemd \
  unattended-upgrades \
  apt-listchanges

echo "  WireGuard: $(dpkg-query -W -f='$${Version}' wireguard-tools)"
echo "  Kernel:    $(uname -r)"

# Unattended security updates. Reboots are disabled on purpose: an automatic
# reboot would drop every VPN session without warning.
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "$${distro_id}:$${distro_codename}-security";
    "$${distro_id}ESMApps:$${distro_codename}-apps-security";
    "$${distro_id}ESM:$${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::SyslogEnable "true";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

echo "  System up to date."

# ──────────────────────────────────────────────────────────────────────────────
# 2. SSH hardening
# ──────────────────────────────────────────────────────────────────────────────
echo "[2/8] Hardening SSH..."

# A drop-in rather than a rewrite of /etc/ssh/sshd_config: the packaged file
# keeps receiving upstream security fixes, and openssh-server upgrades will not
# raise a conffile conflict. Directives are first-match-wins, and the 00- prefix
# makes this file win over cloud-init's own drop-in.
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-hardening.conf << EOF
Port $SSH_PORT
AddressFamily inet

# Offer only the Ed25519 host key.
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com

# Modern key exchange, ciphers and MACs only.
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com

# Public key authentication only.
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
KbdInteractiveAuthentication no
AuthorizedKeysFile .ssh/authorized_keys
AllowUsers ubuntu

# Session limits.
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

# Disable features this host has no use for.
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
GatewayPorts no

LogLevel VERBOSE
EOF

# Remove the legacy host key types rather than merely refusing to offer them.
rm -f /etc/ssh/ssh_host_dsa_key* /etc/ssh/ssh_host_ecdsa_key*

# A malformed drop-in would make sshd refuse to start, and SSH is how client
# configs get retrieved. Validate first, roll back if the config is rejected.
if sshd -t; then
  echo "  sshd configuration valid."
else
  echo "  sshd rejected the hardening drop-in — rolling it back."
  rm -f /etc/ssh/sshd_config.d/00-hardening.conf
fi

# Ubuntu 24.04 starts sshd through socket activation. The listening port comes
# from ssh.socket, which is generated from sshd_config at daemon-reload time, so
# "systemctl restart ssh" alone would leave the listener on port 22 and lock the
# operator out whenever ssh_port is customised.
if systemctl list-unit-files ssh.socket &> /dev/null && systemctl is-enabled ssh.socket &> /dev/null; then
  mkdir -p /etc/systemd/system/ssh.socket.d
  cat > /etc/systemd/system/ssh.socket.d/override.conf << EOF
[Socket]
ListenStream=
ListenStream=$SSH_PORT
EOF
  systemctl daemon-reload
  systemctl restart ssh.socket
  echo "  ssh.socket now listening on port $SSH_PORT."
else
  systemctl daemon-reload
  systemctl restart ssh
  echo "  sshd restarted on port $SSH_PORT."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 3. Kernel hardening
# ──────────────────────────────────────────────────────────────────────────────
echo "[3/8] Applying kernel hardening..."

cat > /etc/sysctl.d/99-wireguard-hardening.conf << 'EOF'
# Routing — required for the VPN to forward client traffic.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# SYN flood mitigation.
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2

# Reverse path filtering, anti spoofing.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore and never send ICMP redirects.
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Reject source routed packets.
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Log impossible addresses.
net.ipv4.conf.all.log_martians = 1

# Memory and process protections.
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.sysrq = 0
kernel.yama.ptrace_scope = 1
EOF

sysctl --system > /dev/null
echo "  sysctl policy applied."

# ──────────────────────────────────────────────────────────────────────────────
# 4. Firewall
# ──────────────────────────────────────────────────────────────────────────────
echo "[4/8] Configuring UFW..."

# UFW defaults the FORWARD policy to DROP, which silently breaks VPN routing:
# clients complete the handshake but no traffic reaches the internet.
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

ufw --force reset > /dev/null
ufw default deny incoming
ufw default allow outgoing

# "limit" both allows and rate limits, so a separate allow rule is redundant.
ufw limit "$SSH_PORT/tcp" comment "SSH (rate limited)"
ufw allow "$WG_PORT/udp" comment "WireGuard"

ufw --force enable
ufw status verbose

# ──────────────────────────────────────────────────────────────────────────────
# 5. Fail2ban
# ──────────────────────────────────────────────────────────────────────────────
echo "[5/8] Configuring fail2ban..."

# No inline comments: fail2ban parses everything after "=" as the value, so a
# trailing "; comment" would make bantime unparseable.
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
backend  = systemd

[sshd]
enabled  = true
port     = $SSH_PORT
maxretry = 3
bantime  = 86400
EOF

systemctl enable fail2ban > /dev/null
systemctl restart fail2ban
echo "  fail2ban active."

# ──────────────────────────────────────────────────────────────────────────────
# 6. WireGuard
# ──────────────────────────────────────────────────────────────────────────────
echo "[6/8] Configuring WireGuard..."

install -d -m 700 "$WG_DIR"
install -d -m 700 -o ubuntu -g ubuntu "$CLIENTS_DIR"

SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)

# Private keys are generated here and never leave the instance, so they are
# absent from the Terraform state and from any CI log.
echo "  Server public key: $SERVER_PUBLIC_KEY"
echo "  Server endpoint:   $SERVER_PUBLIC_IP:$WG_PORT"

MAIN_IFACE=$(ip route show default | awk '{print $5}' | head -1)
echo "  Uplink interface:  $MAIN_IFACE"

# No DNS directive here: DNS= is a wg-quick client-side setting and has no
# meaning in a server configuration.
umask 077
cat > "$WG_DIR/wg0.conf" << EOF
[Interface]
# $PROJECT — generated $(date -u '+%Y-%m-%d %H:%M:%S UTC')
PrivateKey = $SERVER_PRIVATE_KEY
Address    = $SERVER_VPN_ADDRESS
ListenPort = $WG_PORT

PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $MAIN_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $MAIN_IFACE -j MASQUERADE
EOF

# Each client gets its own key pair, its own preshared key and its own address.
# Addresses are allocated by Terraform, so there is no IP arithmetic here.
for SPEC in $CLIENT_SPECS; do
  CLIENT_NAME="$${SPEC%%:*}"
  CLIENT_IP="$${SPEC##*:}"

  CLIENT_PRIVATE_KEY=$(wg genkey)
  CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
  CLIENT_PRESHARED_KEY=$(wg genpsk)

  cat >> "$WG_DIR/wg0.conf" << EOF

# Client: $CLIENT_NAME
[Peer]
PublicKey    = $CLIENT_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY
AllowedIPs   = $CLIENT_IP/32
EOF

  cat > "$CLIENTS_DIR/$CLIENT_NAME.conf" << EOF
[Interface]
# $CLIENT_NAME — $PROJECT
PrivateKey = $CLIENT_PRIVATE_KEY
Address    = $CLIENT_IP/32
DNS        = $CLIENT_DNS

[Peer]
PublicKey    = $SERVER_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY
Endpoint     = $SERVER_PUBLIC_IP:$WG_PORT
# Full tunnel: every packet, including DNS, goes through the VPN.
AllowedIPs   = 0.0.0.0/0, ::/0
# Keeps the session alive through mobile carrier NAT.
PersistentKeepalive = 25
EOF

  qrencode -t ansiutf8 < "$CLIENTS_DIR/$CLIENT_NAME.conf" \
    > "$CLIENTS_DIR/$CLIENT_NAME-qrcode.txt" 2> /dev/null || true

  chmod 600 "$CLIENTS_DIR/$CLIENT_NAME.conf" "$CLIENTS_DIR/$CLIENT_NAME-qrcode.txt" 2> /dev/null || true
  echo "  Client $CLIENT_NAME -> $CLIENT_IP"
done
umask 022

chown -R ubuntu:ubuntu "$CLIENTS_DIR"
chmod 600 "$WG_DIR/wg0.conf"

systemctl enable wg-quick@wg0 > /dev/null
systemctl start wg-quick@wg0
wg show wg0

# ──────────────────────────────────────────────────────────────────────────────
# 7. Audit helper
# ──────────────────────────────────────────────────────────────────────────────
echo "[7/8] Installing the audit script..."

mkdir -p "$OPT_DIR"
cat > "$OPT_DIR/audit.sh" << 'AUDIT'
#!/bin/bash
# Reports installed versions, pending security updates and runtime status.
echo "=============================================="
echo " Security audit — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "=============================================="
echo
echo "System"
echo "  OS:     $(lsb_release -ds 2>/dev/null || echo unknown)"
echo "  Kernel: $(uname -r)"
echo
echo "WireGuard"
echo "  Installed: $(dpkg-query -W -f='$${Version}' wireguard-tools 2>/dev/null)"
echo "  Candidate: $(apt-cache policy wireguard-tools 2>/dev/null | awk '/Candidate:/{print $2}')"
echo
echo "OpenSSH"
echo "  $(ssh -V 2>&1)"
echo "  Listening on: $(ss -tlnp 2>/dev/null | awk '/sshd|ssh/{print $4}' | paste -sd' ' -)"
echo
echo "Pending security updates"
apt-get -s upgrade 2>/dev/null | awk '/^Inst.*-security/{print "  " $2 " " $3}' | sort -u
apt-get -s upgrade 2>/dev/null | grep -q '^Inst.*-security' || echo "  none"
echo
echo "Firewall"
ufw status verbose
echo
echo "fail2ban"
fail2ban-client status sshd 2>/dev/null || echo "  sshd jail unavailable"
echo
echo "WireGuard peers"
wg show
AUDIT

chmod 700 "$OPT_DIR/audit.sh"

# ──────────────────────────────────────────────────────────────────────────────
# 8. Finish
# ──────────────────────────────────────────────────────────────────────────────
echo "[8/8] Finalising..."

cat > /etc/motd << EOF

  WireGuard VPN server — $PROJECT

  wg show                              peer and transfer status
  sudo systemctl status wg-quick@wg0   service status
  sudo /opt/wireguard/audit.sh         security audit

EOF

date -u '+%Y-%m-%dT%H:%M:%SZ' > "$DONE_MARKER"

echo "=============================================="
echo " Bootstrap complete — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo " Endpoint:  $SERVER_PUBLIC_IP:$WG_PORT (UDP)"
echo " SSH port:  $SSH_PORT (TCP)"
echo " Configs:   $CLIENTS_DIR"
echo "=============================================="
