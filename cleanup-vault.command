#!/bin/bash
# ============================================================
# Nettoyage complet aws-vault + ~/.aws/config
# Double-clic depuis Finder pour exécuter
# ============================================================
set -uo pipefail

[ -f "/opt/homebrew/bin/brew" ] && eval "$(/opt/homebrew/bin/brew shellenv)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║     Nettoyage aws-vault + config AWS                     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── État avant nettoyage ──
echo -e "${BLUE}▶ État actuel aws-vault :${NC}"
aws-vault list 2>/dev/null || echo "  (aucun profil)"
echo ""

echo -e "${BLUE}▶ État actuel ~/.aws/config :${NC}"
cat "${HOME}/.aws/config" 2>/dev/null || echo "  (fichier absent)"
echo ""

echo -e "${BLUE}▶ État actuel ~/.aws/credentials :${NC}"
cat "${HOME}/.aws/credentials" 2>/dev/null || echo "  (fichier absent)"
echo ""

# ── Nettoyage aws-vault (tous les profils wireguard*) ──
echo -e "${YELLOW}▶ Suppression des profils aws-vault wireguard* ...${NC}"
for PROFILE in wireguard wireguard2 wireguard3; do
    if aws-vault list 2>/dev/null | grep -q "^${PROFILE}"; then
        aws-vault remove "$PROFILE" --force 2>/dev/null && \
            echo -e "${GREEN}  ✓ Supprimé : ${PROFILE}${NC}" || \
            echo "  (échec suppression ${PROFILE})"
    else
        echo "  — Profil '${PROFILE}' absent"
    fi
done
echo ""

# ── Nettoyage ~/.aws/config (supprimer les sections wireguard*) ──
echo -e "${YELLOW}▶ Nettoyage ~/.aws/config ...${NC}"
if [ -f "${HOME}/.aws/config" ]; then
    python3 - <<'PYEOF'
import configparser, os, re

path = os.path.expanduser("~/.aws/config")
cfg = configparser.ConfigParser()
cfg.read(path)

removed = []
for section in list(cfg.sections()):
    # aws config utilise [profile wireguard] ou [wireguard]
    name = re.sub(r'^profile\s+', '', section)
    if re.match(r'^wireguard', name):
        cfg.remove_section(section)
        removed.append(section)

with open(path, "w") as f:
    cfg.write(f)

if removed:
    print(f"  ✓ Sections supprimées de ~/.aws/config : {', '.join(removed)}")
else:
    print("  — Aucune section wireguard trouvée dans ~/.aws/config")
PYEOF
else
    echo "  — ~/.aws/config absent, rien à nettoyer"
fi
echo ""

# ── Nettoyage ~/.aws/credentials ──
echo -e "${YELLOW}▶ Nettoyage ~/.aws/credentials ...${NC}"
if [ -f "${HOME}/.aws/credentials" ]; then
    python3 - <<'PYEOF'
import configparser, os, re

path = os.path.expanduser("~/.aws/credentials")
cfg = configparser.ConfigParser()
cfg.read(path)

removed = []
for section in list(cfg.sections()):
    if re.match(r'^wireguard', section):
        cfg.remove_section(section)
        removed.append(section)

with open(path, "w") as f:
    cfg.write(f)

if removed:
    print(f"  ✓ Sections supprimées de ~/.aws/credentials : {', '.join(removed)}")
else:
    print("  — Aucune section wireguard trouvée dans ~/.aws/credentials")
PYEOF
else
    echo "  — ~/.aws/credentials absent, rien à nettoyer"
fi
echo ""

# ── État après nettoyage ──
echo -e "${CYAN}▶ État final aws-vault :${NC}"
aws-vault list 2>/dev/null || echo "  (aucun profil)"
echo ""

echo -e "${CYAN}▶ État final ~/.aws/config :${NC}"
cat "${HOME}/.aws/config" 2>/dev/null | grep -E '^\[|wireguard' || echo "  (vide ou absent)"
echo ""

echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ Nettoyage terminé — relance deploy.command${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
echo ""
