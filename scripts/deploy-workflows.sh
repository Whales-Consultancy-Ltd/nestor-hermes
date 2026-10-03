#!/usr/bin/env bash
# Deploie les workflows n8n depuis le depot, puis reinscrit le webhook Telegram.
#
# La source de verite est le depot : ne jamais editer a la main dans l'UI n8n
# (WORKPLAN.md §5). Ce script fait la sequence complete, sans piege :
#   1. sauvegarde la version DISTANTE avant toute ecriture
#   2. PUT chaque workflow local
#   3. relit la reponse et la compare au fichier sur disque
#   4. reinscrit le webhook Telegram de l'approbateur
#
# Usage :
#   ./scripts/deploy-workflows.sh           # deploie tout
#   ./scripts/deploy-workflows.sh --check   # compare local / distant, n'ecrit rien
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT="${NESTOR_VAULT:-$HOME/.config/nestor/secrets.env}"
N8N_URL="${N8N_URL:-https://n8n.whales-consultancy.biz}"
BACKUP_DIR="${NESTOR_BACKUPS:-$HOME/.config/nestor/backups}"

# fichier local : id n8n
WORKFLOWS=(
  "workflow-telegram-approval.json:ieDcsbIeNFBCtppv"
  "workflow-biz4a-approver.json:8D4pwY4Os56HC1UQ"
)

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

die()  { printf '\033[31mERREUR\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[33mATTENTION\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }

command -v jq >/dev/null || die "jq est requis"
[[ -r "$VAULT" ]] || die "coffre introuvable : $VAULT"
set -a; . "$VAULT"; set +a
[[ -n "${N8N_API_KEY:-}" ]] || die "N8N_API_KEY absent du coffre"

# Resolution de secours par IP : quand le DNS du domaine est casse (SERVFAIL),
# on garde le SNI/TLS correct en pointant curl sur une IP connue, sans toucher
# a /etc/hosts et sans privileges root.
#   N8N_IP=1.2.3.4 ./scripts/set-telegram-webhook.sh
CURL_RESOLVE=()
if [[ -n "${N8N_IP:-}" ]]; then
  _host="$(printf '%s' "$N8N_URL" | sed -E 's#^[a-z]+://([^:/]+).*#\1#')"
  _port="$(printf '%s' "$N8N_URL" | sed -nE 's#^[a-z]+://[^:/]+:([0-9]+).*#\1#p')"
  [[ -n "$_port" ]] || _port=443
  CURL_RESOLVE=(--resolve "$_host:$_port:$N8N_IP")
  printf 'resolution forcee : %s:%s -> %s\n\n' "$_host" "$_port" "$N8N_IP"
fi
c() { curl ${CURL_RESOLVE[@]+"${CURL_RESOLVE[@]}"} "$@"; }

api() { c -sS -m 60 -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_URL$1"; }
# webhookId est genere par n8n a l'activation : il n'est pas du contenu ecrit.
# Le garder hors de la comparaison evite un ecart sans consequence sur chaque
# noeud Telegram, y compris les noeuds d'envoi qui n'ont aucun webhook.
payload_of() {  # ne renvoie que ce que PUT accepte, webhookId normalise
  jq -c '{name, nodes, connections, settings}
         | .nodes |= map(del(.webhookId))' "$1"
}
tmp() { mktemp; }

# Compare le local et le distant sur le contenu reellement deploye.
compare() { # fichier libelle
  local f="$1" label="$2" remote="$3"
  local l r
  l="$(payload_of "$f")"
  r="$(printf '%s' "$remote" | jq -c '{name, nodes, connections, settings}
                                    | .nodes |= map(del(.webhookId))')"
  if [[ "$l" == "$r" ]]; then
    ok "  $label : identique au depot"
    return 0
  fi
  printf '  %s : DIVERGENT\n' "$label" >&2
  diff <(printf '%s' "$l" | jq -S .) <(printf '%s' "$r" | jq -S .) | head -40 >&2
  return 1
}

# P5 : la cle n8n est un JWT a duree de vie limitee. Hors de peremption, plus
# aucune modification de workflow n est possible (l API est le seul moyen
# d ecrire). L echeance est rappelee a chaque deploiement.
key_deadline() {
  local exp
  exp="$(printf '%s' "$N8N_API_KEY" | cut -d. -f2 | tr '_-' '/+' \
    | awk '{l=length($0)%4; if(l==2)$0=$0"=="; else if(l==3)$0=$0"="; print}' \
    | base64 -d 2>/dev/null | jq -r '.exp // empty')" || return 0
  [[ -n "$exp" ]] || return 0
  local days when
  days=$(( (exp - $(date -u +%s)) / 86400 ))
  when="$(date -u -d "@$exp" +%Y-%m-%d)"
  if   [[ $days -lt 0  ]]; then warn "CLE N8N EXPIREE depuis $when : les deploiements echoueront."
  elif [[ $days -le 14 ]]; then warn "CLE N8N : $days jours restants (expire le $when). Renouveler via scripts/set-n8n-key.sh."
  else printf '  cle n8n : %s jours restants\n' "$days"
  fi
}

# Verrou de coordination : n8n regenere le webhookId a CHAQUE PUT, donc deux
# deploiement simultanes cassent l'approbation Telegram sans laisser de trace.
# Si un autre noeud tient le verrou, on refuse d'ecrire.
COORD="${COORD_BIN:-$HOME/coord/bin/coord}"
# Un simple check ne protege rien : deux noeuds peuvent tous deux passer le
# check et ecrire. Il faut ACQUERIR le verrou -- le push de coord est atomique.
# Une liste, pas un scalaire : la boucle deploie deux workflows, et un scalaire
# ne conservait que le dernier -- le verrou du premier restait bloque jusqu'a son TTL.
COORD_HELD=()
guard_lock() {  # guard_lock <workflowId>
  [[ -x "$COORD" ]] || return 0          # coord absent : pas de verrou, pas de blocage
  "$COORD" check-lock "n8n:$1" || die "un autre noeud deploie en ce moment : $COORD locks"
  "$COORD" lock "n8n:$1" >/dev/null \
    || die "verrou n8n:$1 pris par un autre noeud entre-temps : $COORD locks"
  COORD_HELD+=("$1")
}
COORD_HELD=""
release_lock() {
  [[ -x "$COORD" ]] || return 0
  local id
  local id
  for id in "${COORD_HELD[@]+"${COORD_HELD[@]}"}"; do
    [[ -n "$id" ]] || continue
    "$COORD" unlock "n8n:$id" >/dev/null 2>&1 || warn "verrou n8n:$id non rendu (a expirer)"
  done
  COORD_HELD=()
}
trap release_lock EXIT

printf '\033[1m== Diagnostic ==\033[0m\n'
key_deadline
for entry in "${WORKFLOWS[@]}"; do
  f="${entry%%:*}"; id="${entry##*:}"
  [[ -f "$REPO/$f" ]] || die "fichier source absent : $f"
  remote="$(api "/api/v1/workflows/$id")" || die "$id injoignable sur $N8N_URL (DNS ou HTTPS ?)"
  if [[ "$(printf '%s' "$remote" | jq -r '.id // empty')" != "$id" ]]; then
    die "$id : reponse inattendue de l'API. N8N_URL=$N8N_URL est-il correct ?"
  fi
  printf '%s  %s (actif=%s, %s noeuds)\n' "$id" \
    "$(printf '%s' "$remote" | jq -r .name)" \
    "$(printf '%s' "$remote" | jq -r .active)" \
    "$(printf '%s' "$remote" | jq -r '.nodes | length')"
done

if [[ $CHECK_ONLY -eq 1 ]]; then
  printf '\n\033[1m== Comparaison (aucune ecriture) ==\033[0m\n'
  rc=0
  for entry in "${WORKFLOWS[@]}"; do
    f="${entry%%:*}"; id="${entry##*:}"
    compare "$REPO/$f" "$f" "$(api "/api/v1/workflows/$id")" || rc=1
  done
  printf '\n'
  exit $rc
fi

# --- 1. sauvegarde avant ecriture ------------------------------------------
mkdir -p "$BACKUP_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
printf '\n\033[1m== 1. Sauvegarde des versions distantes ==\033[0m\n'
for entry in "${WORKFLOWS[@]}"; do
  id="${entry##*:}"
  out="$BACKUP_DIR/workflow-$id-$TS.json"
  api "/api/v1/workflows/$id" > "$out"
  ok "  $out"
done

# --- 2 & 3. PUT puis relecture --------------------------------------------
printf '\n\033[1m== 2. Mise a jour des workflows ==\033[0m\n'
for entry in "${WORKFLOWS[@]}"; do
  f="${entry%%:*}"; id="${entry##*:}"
  src="$REPO/$f"
  guard_lock "$id"
  p="$(tmp)"

  # Le webhookId est genere par n8n a l'activation : ce n'est pas du contenu
  # authored. S'il differe entre le depot et l'instance vivante, conserver la
  # valeur DISTANTE -- sinon PUT change l'URL du webhook et l'approbation
  # Telegram cesse de fonctionner jusqu'a la reinscription.
  live_wh="$(api "/api/v1/workflows/$id" \
    | jq -r '.nodes[] | select(.type | endswith("telegramTrigger")) | .webhookId // empty')"
  local_wh="$(jq -r '.nodes[] | select(.type | endswith("telegramTrigger")) | .webhookId // empty' "$src")"
  p="$(tmp)"
  if [[ -n "$live_wh" && -n "$local_wh" && "$live_wh" != "$local_wh" ]]; then
    warn "  $f : webhookId du depot ($local_wh) != distant ($live_wh). On conserve le distant."
    warn "  Corriger $f pour supprimer cette divergence a la prochaine revision."
    jq --arg wh "$live_wh" '
      .nodes |= map(if (.type | endswith("telegramTrigger")) then .webhookId = $wh else . end)
    ' "$src" | payload_of /dev/stdin > "$p"
  else
    payload_of "$src" > "$p"
  fi

  resp="$(tmp)"
  code="$(c -sS -m 60 -X PUT -o "$resp" -w '%{http_code}' \
    -H "X-N8N-API-KEY: $N8N_API_KEY" -H 'Content-Type: application/json' \
    --data @"$p" "$N8N_URL/api/v1/workflows/$id")" || die "PUT $id impossible"

  [[ "$code" == "200" ]] || die "PUT $id -> HTTP $code : $(head -c 300 "$resp")"
  ok "  $f -> HTTP 200 (versionId $(jq -r '.versionId // "?"' "$resp"))"

  # On compare le distant a ce qu'on a ENVOYE, pas au fichier du depot : si le
  # webhookId distant a ete.injecte, le depot ne peut pas correspondre.
  # Relecture de l'API : c'est la seule preuve de l'etat reel (WORKPLAN.md §7).
  remote_after="$(api "/api/v1/workflows/$id")"
  compare "$p" "  verification reponse PUT" "$(cat "$resp")"
  compare "$p" "  verification relecture API" "$remote_after" \
    || die "$id : le distant ne correspond pas a ce qui a ete envoye. NE PAS ALLER PLUS LOIN, chercher la cause."
  rm -f "$p" "$resp"
done

# --- 4. webhook Telegram ----------------------------------------------------
printf '\n\033[1m== 3. Reinscription du webhook Telegram ==\033[0m\n'
"$REPO/scripts/set-telegram-webhook.sh" || die "reinscription du webhook echouee : l approbation est cassee"

printf '\n\033[1m== Rappel cron (WORKPLAN.md §8.6) ==\033[0m\n'
printf 'Un cron modifie par PUT ne se redeclenche pas au demarrage suivant.\n'
printf 'Si le declenchement automatique doit etre verifie : redemarrer le conteneur\n'
printf 'puis lancer une execution manuelle depuis l UI (l API ne peut pas l executer).\n\n'
ok "Deploiement termine."
