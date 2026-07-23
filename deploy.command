#!/bin/bash
# ==============================================================================
# WireGuard VPN on AWS — guided deployment (macOS)
#
# Double-click from Finder, or run: bash deploy.command
#
# This script only prepares the local toolchain and runs Terraform. It never
# publishes code, never edits your shell profile, and never writes AWS
# credentials to disk: they live in the macOS Keychain, managed by aws-vault.
#
# On Linux or Windows, follow the manual Terraform workflow in the README.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# The login keychain syncs through iCloud Keychain, so the profile follows you
# across Macs. Exported for this process only.
export AWS_VAULT_KEYCHAIN_NAME="login"
AWS_PROFILE_NAME="wireguard"
MIN_TERRAFORM_VERSION="1.5.0"

info()    { echo -e "${GREEN}  $*${NC}"; }
warn()    { echo -e "${YELLOW}  $*${NC}"; }
fail()    { echo -e "${RED}  $*${NC}" >&2; exit 1; }
heading() { echo -e "\n${BLUE}==> $*${NC}"; }

echo ""
echo "=============================================="
echo "  WireGuard VPN on AWS — deployment"
echo "=============================================="

# ──────────────────────────────────────────────────────────────────────────────
# 1. Toolchain
# ──────────────────────────────────────────────────────────────────────────────
heading "[1/6] Checking the toolchain"

[ -x "/opt/homebrew/bin/brew" ] && eval "$(/opt/homebrew/bin/brew shellenv)"
[ -x "/usr/local/bin/brew" ] && eval "$(/usr/local/bin/brew shellenv)"

if ! command -v brew &> /dev/null; then
    # Deliberately not piping a remote installer into bash from a security
    # oriented project. Install Homebrew yourself, then re-run this script.
    fail "Homebrew is required. Install it from https://brew.sh, then run this script again."
fi

# Refresh formula definitions so anything installed below is the current release.
echo "  Updating Homebrew package definitions..."
brew update > /dev/null 2>&1 || warn "brew update failed, continuing with the local formula cache."

# Installs when missing, upgrades when a newer release exists.
# No arrays here: macOS runs .command files with bash 3.2, where expanding an
# empty array under `set -u` aborts with "unbound variable". brew resolves
# casks and formulae from the name alone, so no extra flag is needed either.
ensure_tool() {
    local command_name="$1" formula="$2"

    if ! command -v "$command_name" &> /dev/null; then
        echo "  Installing $command_name..."
        brew install "$formula" > /dev/null || fail "Could not install $command_name."
    elif brew outdated "$formula" 2> /dev/null | grep -q .; then
        echo "  Upgrading $command_name to the latest release..."
        brew upgrade "$formula" > /dev/null 2>&1 || warn "Could not upgrade $command_name, continuing with the installed version."
    fi
}

brew tap hashicorp/tap > /dev/null 2>&1 || true
ensure_tool terraform hashicorp/tap/terraform
ensure_tool aws awscli
ensure_tool aws-vault aws-vault

command -v terraform &> /dev/null || fail "terraform is not available on PATH."
command -v aws &> /dev/null       || fail "aws CLI is not available on PATH."
command -v aws-vault &> /dev/null || fail "aws-vault is not available on PATH."

TERRAFORM_VERSION="$(terraform version -json 2> /dev/null | sed -n 's/.*"terraform_version": *"\([^"]*\)".*/\1/p' | head -1)"
TERRAFORM_VERSION="${TERRAFORM_VERSION:-unknown}"

# Numeric comparison so 1.10 is correctly treated as newer than 1.5.
version_at_least() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}
if [ "$TERRAFORM_VERSION" != "unknown" ] && ! version_at_least "$TERRAFORM_VERSION" "$MIN_TERRAFORM_VERSION"; then
    fail "Terraform $MIN_TERRAFORM_VERSION or newer is required, found $TERRAFORM_VERSION."
fi

info "terraform $TERRAFORM_VERSION"
info "$(aws --version 2>&1 | head -1)"
info "aws-vault $(aws-vault --version 2>&1 | head -1)"

# ──────────────────────────────────────────────────────────────────────────────
# 2. AWS credentials
# ──────────────────────────────────────────────────────────────────────────────
heading "[2/6] AWS credentials (stored in the macOS Keychain)"

if aws-vault exec --no-session "$AWS_PROFILE_NAME" -- aws sts get-caller-identity &> /dev/null; then
    info "Profile '$AWS_PROFILE_NAME' is working."
else
    warn "Profile '$AWS_PROFILE_NAME' is missing or invalid."
    echo ""
    echo "  Your access keys go straight into the macOS Keychain."
    echo "  They are never written to ~/.aws/credentials."
    echo ""
    aws-vault remove "$AWS_PROFILE_NAME" --force &> /dev/null || true
    aws-vault add "$AWS_PROFILE_NAME"

    if ! aws-vault exec --no-session "$AWS_PROFILE_NAME" -- aws sts get-caller-identity &> /dev/null; then
        aws-vault remove "$AWS_PROFILE_NAME" --force &> /dev/null || true
        fail "Those credentials were rejected by AWS. Check the access key and secret, then retry."
    fi
    info "Credentials stored."
fi

AWS_ACCOUNT_ID="$(aws-vault exec --no-session "$AWS_PROFILE_NAME" -- aws sts get-caller-identity --query Account --output text)"
info "AWS account: $AWS_ACCOUNT_ID"

# ──────────────────────────────────────────────────────────────────────────────
# 3. SSH key
# ──────────────────────────────────────────────────────────────────────────────
heading "[3/6] SSH key"

SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
if [ ! -f "$SSH_KEY_PATH.pub" ]; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -C "wireguard-aws" -f "$SSH_KEY_PATH" -N ""
    info "Generated a new Ed25519 key."
fi
info "Using $SSH_KEY_PATH.pub"

# ──────────────────────────────────────────────────────────────────────────────
# 4. Region
# ──────────────────────────────────────────────────────────────────────────────
heading "[4/6] Region"

echo ""
echo "    1) eu-west-3       Paris"
echo "    2) eu-central-1    Frankfurt"
echo "    3) eu-south-2      Madrid"
echo "    4) us-east-1       N. Virginia"
echo "    5) us-west-2       Oregon"
echo "    6) ap-southeast-1  Singapore"
echo "    7) something else"
echo ""
read -rp "  Choice [1-7, default 1]: " REGION_CHOICE

case "${REGION_CHOICE:-1}" in
    1|"") AWS_REGION="eu-west-3" ;;
    2)    AWS_REGION="eu-central-1" ;;
    3)    AWS_REGION="eu-south-2" ;;
    4)    AWS_REGION="us-east-1" ;;
    5)    AWS_REGION="us-west-2" ;;
    6)    AWS_REGION="ap-southeast-1" ;;
    7)    read -rp "  Region: " AWS_REGION ;;
    *)    AWS_REGION="eu-west-3" ;;
esac

[[ "$AWS_REGION" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || fail "'$AWS_REGION' is not a valid AWS region identifier."
info "Region: $AWS_REGION"

# ──────────────────────────────────────────────────────────────────────────────
# 5. VPN clients
# ──────────────────────────────────────────────────────────────────────────────
heading "[5/6] Devices to connect"

echo ""
echo "  One configuration file and one QR code is generated per device,"
echo "  each with its own keys. Names may contain letters, digits,"
echo "  hyphens and underscores."
echo ""
read -rp "  Devices, comma separated [default: phone,laptop]: " CLIENTS_INPUT
CLIENTS_INPUT="${CLIENTS_INPUT:-phone,laptop}"

# Build an HCL list literal for -var, validating each name on the way.
# Split with parameter expansion rather than an array: bash 3.2 aborts on an
# empty array under `set -u`, and unquoted word splitting would glob the names.
CLIENTS_HCL="["
CLIENT_COUNT=0
REMAINING="$CLIENTS_INPUT"
while [ -n "$REMAINING" ]; do
    RAW_NAME="${REMAINING%%,*}"
    if [ "$RAW_NAME" = "$REMAINING" ]; then
        REMAINING=""
    else
        REMAINING="${REMAINING#*,}"
    fi

    NAME="$(echo "$RAW_NAME" | tr -d '[:space:]')"
    [ -z "$NAME" ] && continue
    [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || fail "Invalid device name '$NAME'. Use letters, digits, hyphens or underscores (max 32 characters)."
    [ "$CLIENT_COUNT" -gt 0 ] && CLIENTS_HCL+=","
    CLIENTS_HCL+="\"$NAME\""
    CLIENT_COUNT=$((CLIENT_COUNT + 1))
done
CLIENTS_HCL+="]"
[ "$CLIENT_COUNT" -eq 0 ] && fail "At least one device is required."
info "$CLIENT_COUNT device(s): $CLIENTS_HCL"

# ──────────────────────────────────────────────────────────────────────────────
# 6. Terraform
# ──────────────────────────────────────────────────────────────────────────────
heading "[6/6] Deploying to $AWS_REGION"

run_terraform() {
    aws-vault exec --no-session "$AWS_PROFILE_NAME" -- terraform "$@"
}

# Plain init, not "init -upgrade": the committed .terraform.lock.hcl pins the
# provider versions and their checksums. Upgrade providers deliberately, in a
# separate change, with: terraform init -upgrade
run_terraform init -input=false

# One workspace per region. Without this, a single local state file is reused
# across regions and switching region silently orphans the previous region's
# instance and Elastic IP, which keep billing with no way to destroy them.
run_terraform workspace select -or-create "$AWS_REGION" > /dev/null
info "Terraform workspace: $AWS_REGION"

PLAN_FILE="tfplan-${AWS_REGION}.bin"
echo ""
run_terraform plan -input=false \
    -var="aws_region=$AWS_REGION" \
    -var="wireguard_clients=$CLIENTS_HCL" \
    -out="$PLAN_FILE"

echo ""
echo -e "${YELLOW}=============================================="
echo -e "  Deploy to $AWS_REGION? Type 'yes' to confirm."
echo -e "==============================================${NC}"
read -r CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    rm -f "$PLAN_FILE"
    echo "Cancelled. Nothing was created."
    exit 0
fi

# Applying the reviewed plan artifact, not re-planning at apply time.
run_terraform apply -input=false "$PLAN_FILE"
rm -f "$PLAN_FILE"

echo ""
run_terraform output -raw next_steps
echo ""
echo -e "${CYAN}  To destroy everything later:${NC}"
echo "    cd '$SCRIPT_DIR'"
echo "    aws-vault exec --no-session $AWS_PROFILE_NAME -- terraform workspace select $AWS_REGION"
echo "    aws-vault exec --no-session $AWS_PROFILE_NAME -- terraform destroy -var='aws_region=$AWS_REGION' -var='wireguard_clients=$CLIENTS_HCL'"
echo ""
