#!/usr/bin/env bash
# check-secrets.sh — garde-fou unique du dépôt Nestor Hermes
#
# Le dépôt Whales-Consultancy-Ltd/nestor-hermes est PUBLIC.
# Toute clé qui y entre est compromise et doit être tournée depuis sa source.
#
# Usage :  ./scripts/check-secrets.sh
# Exit    : 0 = rien de faut   1 = secret probable détecté
#
# Note sur les motifs : le préfixe d'en-tête JWT est un en-tête standard,
# présent dans des millions de jetons publics — ce n'est PAS un secret.
# Seul un motif exigeant une haute entropie constitue une preuve.
# C'est pourquoi le contrôle bloquant est STRICT (suffixe >= 20 caractères),
# et que les citations de la documentation ne déclenchent jamais l'alerte.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

# Suffixe long exigé -> citer les motifs dans la doc reste sans effet.
# Motif sur UNE SEULE LIGNE : un motif multi-lignes fait splitter
# l'expression et produit une alternative vide qui matche tout le fichier.
STRICT='eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|(sk|oc_sk|gho|ghp|github_pat|glpat|xoxb|xoxp|xoxa|xoxr)[-_][A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|^-----BEGIN [A-Z ]*PRIVATE KEY-----$'

# Préfixe nu : informatif uniquement.
LOOSE='eyJhbGciOi|(sk|oc_sk|gho|ghp|xox)[-_][A-Za-z0-9_-]{8,}'

FAIL=0

echo "==> 1/3  Arbre de travail (motifs stricts)"
# git grep n'indexe que les fichiers SUIVIS : on ajoute -c (sans commit) puis
# on restaure l'index, sinon un secret dans un fichier non suivi passerait.
STAGED_BEFORE=$(git diff --cached --name-only 2>/dev/null)
git add -A . 2>/dev/null
TREE=$(git grep -InE -e "$STRICT" -- . ':!scripts/check-secrets.sh' 2>/dev/null)
# restauration de l'index
if [ -z "$STAGED_BEFORE" ]; then
  git reset -q
else
  git reset -q
  [ -n "$STAGED_BEFORE" ] && printf '%s\n' "$STAGED_BEFORE" | while read -r f; do git add "$f" 2>/dev/null; done
fi
if [ -n "$TREE" ]; then
  echo "    ECHEC - secret probable dans l'arbre de travail :"
  echo "$TREE" | sed -E 's/(.{0,14}).*/      \1... (tronque)/' | sed 's/^/  /'
  FAIL=1
else
  echo "    OK"
fi

echo "==> 2/3  Historique git --all (motifs stricts)"
HIST=$(git log -p --all --no-color 2>/dev/null | grep -cE -e "$STRICT")
if [ "$HIST" -ne 0 ]; then
  echo "    ECHEC - $HIST correspondance(s) dans l'historique."
  echo "    Une clé est dans l'historique : elle doit être TOURNEE (rotation),"
  echo "    puis l'historique réécrit (git filter-repo --replace-text)."
  FAIL=1
else
  echo "    OK - 0 correspondance"
fi

echo "==> 3/3  Préfixes nus (informatif, non bloquant)"
LOOSE_N=$(git grep -InE -e "$LOOSE" -- . ':!scripts/check-secrets.sh' 2>/dev/null | wc -l)
echo "    $LOOSE_N mention(s) - documentation, pas des cles."

echo
if [ "$FAIL" -ne 0 ]; then
  echo "RESULTAT : ECHEC"
  exit 1
fi
echo "RESULTAT : OK - aucun secret probable dans l'arbre ni dans l'historique."
exit 0