#!/usr/bin/env bash
# Maintenance de l'hote Aegis (n8n en conteneur). Necessite un acces SSH.
#
# Deux chores P4 du WORKPLAN, qui ne peuvent pas passer par l'API publique :
#   archive-dup   archiver le doublon inactif BIZ4A_Content_Generator
#   clean-backups supprimer les fichiers .bak laisses sur /srv
#   status        etat de la sante du conteneur n8n
#
# REGLE ABSOLUE : aucun DELETE sur un workflow. Une sonde DELETE a deja detruit
# un workflow par erreur (WORKPLAN.md §9). L'archivage passe par la CLI n8n.
#
# Usage :
#   ./scripts/aegis-maintenance.sh status
#   ./scripts/aegis-maintenance.sh archive-dup        # simulation
#   ./scripts/aegis-maintenance.sh archive-dup --apply
#   ./scripts/aegis-maintenance.sh clean-backups --apply
set -euo pipefail

VAULT="${NESTOR_VAULT:-$HOME/.config/nestor/secrets.env}"
N8N_URL="${N8N_URL:-https://n8n.whales-consultancy.biz}"
AEGIS_HOST="${AEGIS_HOST:-aegis.whales-consultancy.biz}"
AEGIS_PORT="${AEGIS_PORT:-8022}"
AEGIS_USER="${AEGIS_USER:-TheHatCoder}"
N8N_CONTAINER="${N8N_CONTAINER:-nestor-n8n}"
PLATFORM_DIR="${PLATFORM_DIR:-/srv/nestor-agent-platform}"
DUP_WORKFLOW_ID="${DUP_WORKFLOW_ID:-xpY6KBBcjZHweECC}"

APPLY=0
[[ "${2:-}" == "--apply" ]] && APPLY=1

die()  { printf '\033[31mERREUR\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[33mATTENTION\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }

command -v jq >/dev/null || die "jq est requis"
[[ -r "$VAULT" ]] || die "coffre introuvable : $VAULT"
set -a; . "$VAULT"; set +a
[[ -n "${N8N_API_KEY:-}" ]] || die "N8N_API_KEY absent du coffre"

if [[ -n "${N8N_IP:-}" ]]; then
  CURL_RESOLVE=(--resolve "$(printf '%s' "$N8N_URL" | sed -E 's#^[a-z]+://([^:/]+).*#\1#'):443:$N8N_IP")
else
  CURL_RESOLVE=()
fi

# Execute sur l'hote, ou simule en affichant la commande.
remote() {
  if [[ $APPLY -eq 1 ]]; then
    ssh -p "$AEGIS_PORT" -o BatchMode=yes -o ConnectTimeout=15 "$AEGIS_USER@$AEGIS_HOST" "$1"
  else
    printf '  [simulation] %s\n' "$1"
  fi
}

case "${1:-}" in

status)
  echo "== conteneur $N8N_CONTAINER =="
  remote "docker ps --filter name=$N8N_CONTAINER --format '{{.Names}}\t{{.Status}}'"
  echo "== executions recentes =="
  remote "docker exec $N8N_CONTAINER node -e '
    const {DatabaseSync}=require(\"node:sqlite\");
    const db=new DatabaseSync(\"/home/node/.n8n/database.sqlite\",{readOnly:true});
    for(const r of db.prepare(\"SELECT id,status,mode,startedAt FROM execution_entity ORDER BY id DESC LIMIT 8\").all())
      console.log(r.id,r.status,r.mode,r.startedAt);
  ' 2>&1 | grep -viE 'error tracking|custom api'"
  ;;

archive-dup)
  echo "== archivage du doublon $DUP_WORKFLOW_ID =="
  # Sauvegarde JSON d'abord, via l'API : si l'archivage rate, l'objet reste
  # recuperable et le script s'interrompt.
  mkdir -p "${NESTOR_BACKUPS:-$HOME/.config/nestor/backups}"
  out="${NESTOR_BACKUPS:-$HOME/.config/nestor/backups}/workflow-$DUP_WORKFLOW_ID-$(date -u +%Y%m%dT%H%M%SZ).json"
  curl ${CURL_RESOLVE[@]+"${CURL_RESOLVE[@]}"} -sS -m 30 -H "X-N8N-API-KEY: $N8N_API_KEY" \
    "$N8N_URL/api/v1/workflows/$DUP_WORKFLOW_ID" > "$out" 2>/dev/null \
    || die "doublon $DUP_WORKFLOW_ID injoignable : rien n'est fait."
  if [[ "$(jq -r '.id // empty' "$out" 2>/dev/null)" != "$DUP_WORKFLOW_ID" ]]; then
    die "sauvegarde de $DUP_WORKFLOW_ID vide/invalide : rien n'est fait."
  fi
  ok "sauvegarde : $out"
  jq -r '"  contenu : \(.name), \(.nodes|length) noeuds, active=\(.active), archived=\(.isArchived)"' "$out"

  warn "l'API publique ne sait pas archiver (isArchived est en lecture seule,"
  warn "comme active, cf. WORKPLAN.md §7). Passage par la CLI dans le conteneur."
  remote "docker exec $N8N_CONTAINER n8n update:workflow --id=$DUP_WORKFLOW_ID --archived=true"
  remote "docker restart $N8N_CONTAINER"
  if [[ $APPLY -eq 1 ]]; then
    echo "verification de l'etat archive..."
    remote "docker exec $N8N_CONTAINER node -e '
      const {DatabaseSync}=require(\"node:sqlite\");
      const db=new DatabaseSync(\"/home/node/.n8n/database.sqlite\",{readOnly:true});
      const r=db.prepare(\"SELECT id,name,active,archived FROM workflow_entity WHERE id=?\").get(\"$DUP_WORKFLOW_ID\");
      console.log(JSON.stringify(r));
    ' 2>&1 | grep -viE 'error tracking|custom api'"
  fi
  ;;

clean-backups)
  echo "== fichiers .bak sur $PLATFORM_DIR =="
  warn "suppression definitive : verifier la liste avant --apply."
  remote "cd $PLATFORM_DIR && ls -la .env.bak.* docker-compose*.yml.bak* docker-compose.override.yml.bak.* 2>/dev/null || echo '  (aucun fichier .bak trouve)'"
  echo
  echo " Ces fichiers contiennent potentiellement des secrets. Les supprimer est le bon geste ;"
  echo "  ils ne doivent surtout pas etre archives dans le depot (meme prive)."
  remote "cd $PLATFORM_DIR && rm -f .env.bak.* docker-compose.yml.bak-trustproxy-* docker-compose.override.yml.bak.*"
  if [[ $APPLY -eq 1 ]]; then
    remote "cd $PLATFORM_DIR && ls -la .env.bak.* docker-compose*.yml.bak* 2>/dev/null || echo '  plus aucun .bak : OK'"
  fi
  ;;

*)
  cat >&2 <<'EOF'
Usage : aegis-maintenance.sh {status|archive-dup|clean-backups} [--apply]

Sans --apply, rien n'est modifie : la commande exacte est affichee.
Variables : AEGIS_HOST AEGIS_PORT AEGIS_USER N8N_CONTAINER PLATFORM_DIR
EOF
  exit 2
  ;;
esac
