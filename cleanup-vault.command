#!/bin/bash
# ==============================================================================
# Remove the local AWS credential setup created by deploy.command
#
# Deletes the aws-vault Keychain entry and any wireguard* section left in
# ~/.aws/config or ~/.aws/credentials.
#
# This touches local credentials only. It does not delete AWS infrastructure:
# run "terraform destroy" for that, before running this script.
# ==============================================================================
set -uo pipefail

[ -x "/opt/homebrew/bin/brew" ] && eval "$(/opt/homebrew/bin/brew shellenv)"
[ -x "/usr/local/bin/brew" ] && eval "$(/usr/local/bin/brew shellenv)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo "=============================================="
echo "  Cleaning up local AWS credentials"
echo "=============================================="
echo ""

echo -e "${BLUE}Current aws-vault profiles:${NC}"
aws-vault list 2> /dev/null || echo "  (aws-vault not installed or no profiles)"
echo ""

# Only profile names are printed, never the file contents: these files can hold
# access keys for unrelated AWS accounts.
echo -e "${BLUE}Profiles found in ~/.aws:${NC}"
for AWS_FILE in "$HOME/.aws/config" "$HOME/.aws/credentials"; do
    if [ -f "$AWS_FILE" ]; then
        echo "  $AWS_FILE:"
        grep -oE '^\[[^]]+\]' "$AWS_FILE" 2> /dev/null | sed 's/^/    /' || echo "    (no sections)"
    else
        echo "  $AWS_FILE: absent"
    fi
done
echo ""

echo -e "${YELLOW}Removing aws-vault profiles matching wireguard*...${NC}"
if command -v aws-vault &> /dev/null; then
    while read -r PROFILE; do
        [ -z "$PROFILE" ] && continue
        if aws-vault remove "$PROFILE" --force &> /dev/null; then
            echo -e "${GREEN}  removed: $PROFILE${NC}"
        else
            echo "  could not remove: $PROFILE"
        fi
    done < <(aws-vault list 2> /dev/null | awk 'NR > 1 {print $1}' | grep -E '^wireguard' | sort -u)
else
    echo "  aws-vault not installed, skipping."
fi
echo ""

echo -e "${YELLOW}Removing wireguard* sections from ~/.aws...${NC}"
python3 - <<'PYEOF'
import configparser
import os
import re

for path in (os.path.expanduser("~/.aws/config"), os.path.expanduser("~/.aws/credentials")):
    if not os.path.exists(path):
        print(f"  {path}: absent")
        continue

    parser = configparser.ConfigParser()
    try:
        parser.read(path)
    except configparser.Error as exc:
        print(f"  {path}: could not parse ({exc}), left untouched")
        continue

    # Sections appear as [wireguard] in credentials and [profile wireguard] in config.
    removed = [
        section for section in list(parser.sections())
        if re.match(r"^wireguard", re.sub(r"^profile\s+", "", section))
    ]
    for section in removed:
        parser.remove_section(section)

    if removed:
        with open(path, "w") as handle:
            parser.write(handle)
        print(f"  {path}: removed {', '.join(removed)}")
    else:
        print(f"  {path}: nothing to remove")
PYEOF
echo ""

echo -e "${BLUE}Remaining aws-vault profiles:${NC}"
aws-vault list 2> /dev/null || echo "  (none)"
echo ""
echo -e "${GREEN}=============================================="
echo -e "  Cleanup complete."
echo -e "==============================================${NC}"
echo ""
