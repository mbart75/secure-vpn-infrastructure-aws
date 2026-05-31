#!/bin/bash
# ============================================================
# WireGuard AWS — Script de déploiement complet
# Double-clic pour lancer depuis Finder
# Credentials AWS : aws-vault (Trousseau macOS login → iCloud)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Trousseau login = sync iCloud Keychain automatique
export AWS_VAULT_KEYCHAIN_NAME="login"
AWS_PROFILE="wireguard"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║     WireGuard AWS — Déploiement automatisé               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Persister AWS_VAULT_KEYCHAIN_NAME=login dans ~/.zprofile si pas déjà là
if ! grep -q "AWS_VAULT_KEYCHAIN_NAME" "${HOME}/.zprofile" 2>/dev/null; then
    echo 'export AWS_VAULT_KEYCHAIN_NAME=login' >> "${HOME}/.zprofile"
    echo -e "${GREEN}  ✓ AWS_VAULT_KEYCHAIN_NAME=login ajouté à ~/.zprofile${NC}"
fi

# ──────────────────────────────────────────────────────────────
# 1. Homebrew
# ──────────────────────────────────────────────────────────────
echo -e "${BLUE}▶ [1/7] Homebrew...${NC}"
if ! command -v brew &>/dev/null; then
    echo "  Installation de Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "${HOME}/.zprofile"
    fi
fi
# S'assurer que brew est dans le PATH (Apple Silicon)
[ -f "/opt/homebrew/bin/brew" ] && eval "$(/opt/homebrew/bin/brew shellenv)"
echo -e "${GREEN}  ✓ Homebrew : $(brew --version | head -1)${NC}"
echo ""

# ──────────────────────────────────────────────────────────────
# 2. Outils
# ──────────────────────────────────────────────────────────────
echo -e "${BLUE}▶ [2/7] Outils...${NC}"
TOOLS=()
command -v terraform  &>/dev/null || TOOLS+=("hashicorp/tap/terraform")
command -v aws        &>/dev/null || TOOLS+=("awscli")
command -v aws-vault  &>/dev/null || TOOLS+=("aws-vault")
command -v gh         &>/dev/null || TOOLS+=("gh")
if [ ${#TOOLS[@]} -gt 0 ]; then
    brew install "${TOOLS[@]}"
fi
echo -e "${GREEN}  ✓ terraform : $(terraform version -json | python3 -c 'import sys,json;print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || terraform version | head -1)${NC}"
echo -e "${GREEN}  ✓ aws CLI   : $(aws --version 2>&1 | head -1)${NC}"
echo -e "${GREEN}  ✓ aws-vault : $(aws-vault --version 2>&1 | head -1)${NC}"
echo -e "${GREEN}  ✓ gh CLI    : $(gh --version | head -1)${NC}"
echo ""

# ──────────────────────────────────────────────────────────────
# 3. Credentials AWS (aws-vault → Trousseau login → iCloud)
# ──────────────────────────────────────────────────────────────
echo -e "${BLUE}▶ [3/7] Credentials AWS (aws-vault)...${NC}"
echo ""

# Test si le profil existe et fonctionne
if aws-vault exec --no-session "$AWS_PROFILE" -- aws sts get-caller-identity &>/dev/null 2>&1; then
    echo -e "${GREEN}  ✓ Profil '${AWS_PROFILE}' opérationnel (Trousseau iCloud)${NC}"
else
    echo -e "${YELLOW}  Profil '${AWS_PROFILE}' absent ou invalide — configuration...${NC}"
    echo ""
    echo "  Les credentials seront stockés dans le Trousseau macOS (login)"
    echo "  et synchronisés automatiquement sur iCloud Keychain."
    echo ""

    # Nettoyer un éventuel profil cassé
    aws-vault remove "$AWS_PROFILE" --force 2>/dev/null || true

    echo "  Lance aws-vault add (saisis Access Key ID puis Secret Access Key) :"
    echo ""
    AWS_VAULT_KEYCHAIN_NAME="login" aws-vault add "$AWS_PROFILE"

    echo ""
    echo -e "${CYAN}  Vérification des credentials...${NC}"
    if ! aws-vault exec --no-session "$AWS_PROFILE" -- aws sts get-caller-identity &>/dev/null 2>&1; then
        echo -e "${RED}  ✗ Credentials invalides — vérifie Access Key ID et Secret Key${NC}"
        aws-vault remove "$AWS_PROFILE" --force 2>/dev/null || true
        exit 1
    fi

    echo -e "${GREEN}  ✓ Credentials enregistrés dans le Trousseau macOS (login/iCloud)${NC}"
fi

AWS_ACCOUNT=$(aws-vault exec --no-session "$AWS_PROFILE" -- aws sts get-caller-identity --query Account --output text)
echo -e "${GREEN}  ✓ Compte AWS : ${AWS_ACCOUNT}${NC}"
echo ""

# ──────────────────────────────────────────────────────────────
# 4. Clé SSH
# ──────────────────────────────────────────────────────────────
echo -e "${BLUE}▶ [4/7] Clé SSH...${NC}"
if [ ! -f "${HOME}/.ssh/id_ed25519.pub" ]; then
    mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
    ssh-keygen -t ed25519 -C "wireguard-aws" -f "${HOME}/.ssh/id_ed25519" -N ""
fi
echo -e "${GREEN}  ✓ Clé SSH : ${HOME}/.ssh/id_ed25519.pub${NC}"
echo ""

# ──────────────────────────────────────────────────────────────
# 5. Région AWS
# ──────────────────────────────────────────────────────────────
echo -e "${BLUE}▶ [5/7] Région AWS...${NC}"
echo ""
echo -e "${CYAN}  Quelle région ?${NC}"
echo "    1) eu-west-3      — Paris 🇫🇷"
echo "    2) eu-south-2     — Madrid 🇪🇸"
echo "    3) eu-central-1   — Francfort 🇩🇪"
echo "    4) us-east-1      — Virginie 🇺🇸"
echo "    5) us-west-2      — Oregon 🇺🇸"
echo "    6) ap-southeast-1 — Singapour 🇸🇬"
echo "    7) Autre"
echo ""
read -rp "  Choix [1-7, défaut=1] : " REGION_CHOICE

case "${REGION_CHOICE:-1}" in
    1) AWS_REGION="eu-west-3" ;;
    2) AWS_REGION="eu-south-2" ;;
    3) AWS_REGION="eu-central-1" ;;
    4) AWS_REGION="us-east-1" ;;
    5) AWS_REGION="us-west-2" ;;
    6) AWS_REGION="ap-southeast-1" ;;
    7) read -rp "  Région : " AWS_REGION ;;
    *) AWS_REGION="eu-west-3" ;;
esac
echo -e "${GREEN}  ✓ Région : ${AWS_REGION}${NC}"
echo ""

# ──────────────────────────────────────────────────────────────
# 6. GitHub
# ──────────────────────────────────────────────────────────────
echo -e "${BLUE}▶ [6/7] GitHub...${NC}"
REPO_NAME="wireguard-aws-vpn"

[ ! -d ".git" ] && git init && git branch -M main

if command -v gh &>/dev/null; then
    if ! gh auth status &>/dev/null; then
        echo "  Authentification GitHub..."
        gh auth login
    fi
    GH_USER=$(gh api user --jq .login)
    if ! gh repo view "${GH_USER}/${REPO_NAME}" &>/dev/null 2>&1; then
        gh repo create "$REPO_NAME" --private \
            --description "WireGuard VPN sécurisé sur AWS — Terraform" --clone=false
        git remote add origin "https://github.com/${GH_USER}/${REPO_NAME}.git" 2>/dev/null || true
        echo -e "${GREEN}  ✓ Repo créé : https://github.com/${GH_USER}/${REPO_NAME}${NC}"
    else
        git remote get-url origin &>/dev/null || \
            git remote add origin "https://github.com/${GH_USER}/${REPO_NAME}.git"
        echo -e "${GREEN}  ✓ Repo existant${NC}"
    fi
    git add .
    git diff --cached --quiet 2>/dev/null && git rev-parse HEAD &>/dev/null || \
        git commit -m "feat: WireGuard AWS VPN — secure Terraform deployment" 2>/dev/null || true
    git push -u origin main 2>/dev/null || true
    echo -e "${GREEN}  ✓ Code poussé sur GitHub${NC}"
fi
echo ""

# ──────────────────────────────────────────────────────────────
# 7. Terraform (via aws-vault)
# ──────────────────────────────────────────────────────────────
echo -e "${BLUE}▶ [7/7] Déploiement Terraform (${AWS_REGION})...${NC}"
echo ""

aws-vault exec --no-session "$AWS_PROFILE" -- terraform init -upgrade

echo ""
echo -e "${CYAN}  Plan :${NC}"
aws-vault exec --no-session "$AWS_PROFILE" -- terraform plan \
  -var="aws_region=${AWS_REGION}" \
  -out="tfplan-${AWS_REGION}.bin"

echo ""
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Déployer en région ${AWS_REGION} ? (yes/no)              ${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════════════${NC}"
read -r CONFIRM
[ "$CONFIRM" != "yes" ] && echo "Annulé." && rm -f "tfplan-${AWS_REGION}.bin" && exit 0

aws-vault exec --no-session "$AWS_PROFILE" -- terraform apply "tfplan-${AWS_REGION}.bin"
rm -f "tfplan-${AWS_REGION}.bin"

SERVER_IP=$(aws-vault exec --no-session "$AWS_PROFILE" -- terraform output -raw server_public_ip 2>/dev/null || echo "<IP>")

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ DÉPLOIEMENT TERMINÉ — ${AWS_REGION}${NC}"
echo -e "${GREEN}║  🌐 IP publique : ${SERVER_IP}${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}  ⏳ Attends 2-3 min que WireGuard finisse l'installation${NC}"
echo -e "${YELLOW}     puis vérifie avec :${NC}"
echo ""
echo -e "${CYAN}  # 1. Vérifier que l'installation est terminée${NC}"
echo "  ssh -i ~/.ssh/id_ed25519 ubuntu@${SERVER_IP} 'sudo tail -5 /var/log/wireguard-setup.log'"
echo ""
echo -e "${CYAN}  # 2. Récupérer les configs WireGuard sur le Desktop${NC}"
echo "  scp -i ~/.ssh/id_ed25519 ubuntu@${SERVER_IP}:'~/wireguard-clients/*.conf' ~/Desktop/"
echo ""
echo -e "${CYAN}  # 3. QR code pour import rapide sur téléphone${NC}"
echo "  ssh -i ~/.ssh/id_ed25519 ubuntu@${SERVER_IP} 'cat ~/wireguard-clients/telephone-qrcode.txt'"
echo ""
echo -e "${RED}  🗑  Pour détruire (fin de voyage) :${NC}"
echo "  cd '${SCRIPT_DIR}' && AWS_VAULT_KEYCHAIN_NAME=login aws-vault exec --no-session ${AWS_PROFILE} -- terraform destroy -auto-approve -var=\"aws_region=${AWS_REGION}\""
echo ""
