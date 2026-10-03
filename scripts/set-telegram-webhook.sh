#!/usr/bin/env bash
# Reinscrit le webhook Telegram de l'approbateur, en une commande.
#
# Pourquoi ce script existe : le secret du webhook Telegram est DETERMINISTE
# (n8n : getSecretToken() = <workflowId>_<nodeId>). Toute recreation de
# l'approbateur, ou un simple redemarrage de n8n, casse l'approbation
# silencieusement -- le webhook repond alors 403.
#
# Deux API distinctes, deux chemins distincts :
#   - n8n     : API publique. Le webhookId est lu sur l'instance VIVANTE, pas
#               dans la base du conteneur : le fichier local peut porter un
#               webhookId ecrit a la main et faux, s'en servir casserait le
#               routage.
#   - Telegram: api.telegram.org. Injoignable depuis ce poste (pas de sortie
#               vers Telegram), alors que l'hote n8n y accede. Le script
#               detecte le chemin qui marche et passe par SSH si besoin.
#
# Usage :
#   ./scripts/set-telegram-webhook.sh          # reinscrit puis verifie
#   ./scripts/set-telegram-webhook.sh --check  # verifie sans modifier
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT="${NESTOR_VAULT:-$HOME/.config/nestor/secrets.env}"
N8N_URL="${N8N_URL:-https://n8n.whales-consultancy.biz}"
APPROVER_ID="${APPROVER_ID:-8D4pwY4Os56HC1UQ}"
AEGIS_HOST="${AEGIS_HOST:-aegis.whales-consultancy.biz}"
AEGIS_PORT="${AEGIS_PORT:-8022}"
AEGIS_USER="${AEGIS_USER:-TheHatCoder}"
TG_URL="https://api.telegram.org"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

die()  { printf '\033[31mERREUR\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[33mATTENTION\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }

command -v jq >/dev/null || die "jq est requis"
[[ -r "$VAULT" ]] || die "coffre introuvable ou illisible : $VAULT"
set -a; . "$VAULT"; set +a
[[ -n "${N8N_API_KEY:-}" ]]        || die "N8N_API_KEY absent du coffre"
[[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || die "TELEGRAM_BOT_TOKEN absent du coffre (bot @the_hat_trader_bot)"

# --- routage n8n : DNS casse ? on force l IP en gardant le SNI/TLS ---------
CURL_RESOLVE=()
if [[ -n "${N8N_IP:-}" ]]; then
  _host="$(printf '%s' "$N8N_URL" | sed -E 's#^[a-z]+://([^:/]+).*#\1#')"
  _port="$(printf '%s' "$N8N_URL" | sed -nE 's#^[a-z]+://[^:/]+:([0-9]+).*#\1#p')"
  [[ -n "$_port" ]] || _port=443
  CURL_RESOLVE=(--resolve "$_host:$_port:$N8N_IP")
  printf 'resolution forcee : %s:%s -> %s\n\n' "$_host" "$_port" "$N8N_IP"
fi
n8n() { curl ${CURL_RESOLVE[@]+"${CURL_RESOLVE[@]}"} -sS -m 30 "$@"; }

# --- routage Telegram : direct si possible, sinon via l'hote n8n ----------
# Le jeton transite par stdin : jamais en argument de ligne de commande, donc
# jamais visible dans un `ps` sur l'hote.
TG_VIA=""
if curl -sS -m 8 -o /dev/null "$TG_URL" 2>/dev/null; then
  TG_VIA="direct"
elif ssh -p "$AEGIS_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
      "$AEGIS_USER@$AEGIS_HOST" 'curl -sS -m 8 -o /dev/null https://api.telegram.org' 2>/dev/null; then
  TG_VIA="ssh"
  warn "api.telegram.org injoignable depuis ce poste : les appels passent par SSH ($AEGIS_USER@$AEGIS_HOST)."
else
  die "api.telegram.org injoignable, ni en direct ni via $AEGIS_HOST."
fi

# tg_get <method> [json-body]  -> JSON brut de l'API Telegram
tg_call() {
  local method="$1" body="${2:-}"
  if [[ "$TG_VIA" == "direct" ]]; then
    if [[ -n "$body" ]]; then
      curl -sS -m 30 -X POST "$TG_URL/bot$TELEGRAM_BOT_TOKEN/$method" \
        -H 'Content-Type: application/json' -d "$body"
    else
      curl -sS -m 30 "$TG_URL/bot$TELEGRAM_BOT_TOKEN/$method"
    fi
  else
    {
      printf '%s\n' "$TELEGRAM_BOT_TOKEN"
      printf '%s\n' "$body"
    } | ssh -p "$AEGIS_PORT" -o BatchMode=yes "$AEGIS_USER@$AEGIS_HOST" \
      'IFS= read -r TOK; IFS= read -r BODY
       if [ -n "$BODY" ]; then
         curl -sS -m 30 -X POST "https://api.telegram.org/bot$TOK/'"$method"'" \
           -H "Content-Type: application/json" -d "$BODY"
       else
         curl -sS -m 30 "https://api.telegram.org/bot$TOK/'"$method"'"
       fi'
  fi
}

# --- decouverte du noeud de declenchement ----------------------------------
# Une seule valeur de jq par appel : le nom du noeud peut contenir des espaces
# ("Telegram (telegram-trigger-1)"), un decoupage par champs le corrompt.
WF="$(n8n -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_URL/api/v1/workflows/$APPROVER_ID")" \
  || die "workflow $APPROVER_ID injoignable (DNS/HTTPS ?)"
[[ "$(printf '%s' "$WF" | jq -r '.id // empty')" == "$APPROVER_ID" ]] \
  || die "reponse inattendue de l'API n8n (verifier N8N_URL)"

NODE_ID="$(printf '%s' "$WF"    | jq -r '.nodes[] | select(.type | endswith("telegramTrigger")) | .id'       | head -1)"
WEBHOOK_ID="$(printf '%s' "$WF" | jq -r '.nodes[] | select(.type | endswith("telegramTrigger")) | .webhookId // empty' | head -1)"
NODE_NAME="$(printf '%s' "$WF"  | jq -r '.nodes[] | select(.type | endswith("telegramTrigger")) | .name'     | head -1)"

[[ -n "$NODE_ID" ]]    || die "aucun noeud telegramTrigger dans $APPROVER_ID"
[[ -n "$WEBHOOK_ID" ]] || die "webhookId vide sur '$NODE_NAME' : workflow jamais active, ou version deployee anterieure"

# n8n nettoie le token avec [^A-Za-z0-9_-] (cf. WORKPLAN.md §8.4).
SECRET_TOKEN="$(printf '%s_%s' "$APPROVER_ID" "$NODE_ID" | sed -E 's/[^A-Za-z0-9_-]//g')"
HOOK_URL="$N8N_URL/webhook/$WEBHOOK_ID/webhook"

echo "workflow   : $APPROVER_ID"
echo "noeud      : $NODE_NAME (id=$NODE_ID)"
echo "webhookId  : $WEBHOOK_ID"
echo "secret     : $SECRET_TOKEN"
echo "telegram   : via $TG_VIA"

# Etat courant, une seule interrogation de l'API (mise en cache).
TG_INFO=""
tg_info() {
  [[ -n "$TG_INFO" ]] || TG_INFO="$(tg_call getWebhookInfo)"
  printf '%s' "$TG_INFO"
}
tg_url() { tg_info | jq -r '.result.url // ""'; }

report() {
  tg_info | jq -r --arg h "$HOOK_URL" '
    "  url       : \(.result.url // "AUCUN - webhook non inscrit")
  a jour   : \(if .result.url == $h then "oui" else "NON" end)
  updates   : \(.result.allowed_updates // [] | join(", "))
  pending   : \(.result.pending_update_count // "?")"'
}

if [[ $CHECK_ONLY -eq 1 ]]; then
  echo; echo "verification seule (aucune ecriture) :"
  report
  if [[ "$(tg_url)" == "$HOOK_URL" ]]; then
    ok "Webhook deja inscrit sur la bonne URL."
  else
    warn "Webhook absent ou sur une autre URL. Lancez le script sans --check pour le reinscrire."
  fi
  exit 0
fi

# --- ecriture ---------------------------------------------------------------
PAYLOAD="$(jq -nc --arg url "$HOOK_URL" --arg secret "$SECRET_TOKEN" '{
  url: $url, secret_token: $secret,
  allowed_updates: ["message","edited_message","callback_query"],
  drop_pending_updates: false
}')"

echo; echo "inscription du webhook..."
RESULT="$(tg_call setWebhook "$PAYLOAD")" || die "appel setWebhook impossible"
printf '%s' "$RESULT" | jq -e '.ok == true' >/dev/null \
  || die "setWebhook refuse : $(printf '%s' "$RESULT" | jq -c '{description, error_code}')"
ok "  setWebhook ok"

echo
report
[[ "$(tg_url)" == "$HOOK_URL" ]] || die "URL reelle differente de l'attendue : $(tg_url)"

echo
ok "Webhook Telegram operationnel."
printf 'Test : dans l UI n8n, ouvrir BIZ4A_Content_Generator > Manual Trigger, puis appuyer un bouton.\n'
printf '\033[33mRappel\033[0m : la boucle de regeneration (P0) ne se prouve que par cette execution manuelle,\n'
printf 'l API publique n exposant aucun declenchement (WORKPLAN.md §8.6).\n'
