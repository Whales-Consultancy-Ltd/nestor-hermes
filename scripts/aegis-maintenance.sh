#!/usr/bin/env bash
# Maintenance de l'hote Aegis (n8n en conteneur). Necessite un acces SSH.
#
# Deux chores P4 du WORKPLAN, qui ne peuvent pas passer par l'API publique :
#   archive-dup   archiver le doublon inactif BIZ4A_Content_Generator
#   list-baks    inventorier les .bak (lecture seule)
#   clean-backups supprimer les COPIES DE COFFRE (.env.bak*), pas les rollbacks
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

list-baks)
  echo "== inventaire des .bak sur $PLATFORM_DIR =="
  echo "   (lecture seule, aucune suppression)"
  remote "cd $PLATFORM_DIR && ls -la *.bak* 2>/dev/null || echo '  (aucun)'"
  echo
  echo " Classification :"
  echo "  - .env.bak*        COPIE D UN COFFRE. contient des secrets en clair."
  echo "                      A supprimer : le .env vivant fait foi."
  echo "  - docker-compose*.bak*  points de rollback du deploiement."
  echo "                      A CONSERVER : certains sont les predecesseurs"
  echo "                      directs de la config qui tourne en production."
  echo
  warn "suppression definitive : les motifs sont explicites et separes."
  warn "les .bak de compose ne sont PAS dans le motif de suppression."
  ;;

clean-backups)
  # Motif VOLONTAIREMENT etroit : uniquement les copies de coffre.
  # Les .bak de compose sont des points de rollback sur un hote en
  # production ; les supprimer serait irremversible et sans gain de securite
  # (ils ne contiennent pas de secret en clair, seulement des references).
  echo "== purge des COPIES DE COFFRE sur $PLATFORM_DIR =="
  remote "cd $PLATFORM_DIR && ls -la .env.bak* 2>/dev/null || echo '  (aucune copie de coffre)'"
  echo
  warn "ces fichiers contiennent des secrets en clair (26 motifs detectes le"
  warn "2026-10-03). Ils ne doivent SURTOUT pas etre archives dans un depot."
  remote "cd $PLATFORM_DIR && rm -f .env.bak*"
  remote "cd $PLATFORM_DIR && ls -la .env.bak* 2>/dev/null || echo '  plus aucune copie de coffre : OK'"
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
