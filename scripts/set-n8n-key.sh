#!/usr/bin/env bash
# set-n8n-key.sh — installe proprement une clé API n8n dans le coffre local.
#
# Usage :  ./scripts/set-n8n-key.sh '<clé>'
#          (ou ./scripts/set-n8n-key.sh  → invite à la coller sans écho)
#
# Ne committe jamais la clé. Ne l'affiche pas.

set -uo pipefail

COFFRE=/home/vincent/.config/nestor/secrets.env
umask 077

if [ $# -ge 1 ]; then
  KEY="$1"
else
  printf 'Collez la clé API n8n (elle ne sera pas affichée) : ' >&2
  IFS= read -r -s KEY
  printf '\n' >&2
fi

KEY=$(printf '%s' "$KEY" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
# retire des guillemets eventuels
KEY=${KEY#\"}; KEY=${KEY%\"}
KEY=${KEY#\'}; KEY=${KEY%\'}

if [ -z "$KEY" ]; then
  echo "Erreur : clé vide." >&2; exit 1
fi

# --- validation structurelle d'un JWT n8n ---
if ! printf '%s' "$KEY" | grep -qE '^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'; then
  echo "Erreur : ce n'est pas la forme d'un JWT (3 segments séparés par des points, début 'eyJ')." >&2
  echo "        n8n API → Settings → n8n API → copier la clé affichée." >&2
  exit 1
fi

# --- test d'authentification avant d'écrire ---
API=https://n8n.whales-consultancy.biz/api/v1/workflows/ieDcsbIeNFBCtppv
CODE=$(curl -s -o /tmp/n8nkey.check -w '%{http_code}' --max-time 25 -H "X-N8N-API-KEY: $KEY" "$API")
if [ "$CODE" != "200" ]; then
  echo "Erreur : n8n a répondu HTTP $CODE — la clé est invalide ou révoquée." >&2
  head -c 200 /tmp/n8nkey.check >&2; echo >&2
  exit 1
fi

# --- écriture ---
mkdir -p "$(dirname "$COFFRE")"; chmod 700 "$(dirname "$COFFRE")"
EXP=$(printf '%s' "$KEY" | cut -d. -f2 | tr '_-' '/+')
EXP=$(printf '%s===' "$EXP" | base64 -d 2>/dev/null \
      | grep -oE '"exp":[0-9]+' | head -1 | cut -d: -f2)
if [ -n "$EXP" ]; then
  EXP_HUMAN=$(date -u -d "@$EXP" '+%Y-%m-%d %H:%M:%SZ')
else
  EXP_HUMAN="inconnue"
fi

cat > "$COFFRE" <<EOF
# Coffre local - NE PAS VERSIONNER
# permissions 600, hors depot git
# cle : n8n public-api (JWT HS256). generee dans n8n UI > Settings > n8n API
# expire : $EXP_HUMAN  (duree 30 jours)
N8N_API_KEY='$KEY'
EOF
chmod 600 "$COFFRE"

echo "OK — cle valide, ecrite dans $COFFRE"
echo "    permissions : $(stat -c '%a' "$COFFRE")"
echo "    expire      : $EXP_HUMAN"
