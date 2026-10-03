# Mission: HERMES-TERM-01 — Terminal interactif Hermes

## Objective
Donner au porteur de projet un terminal local pour interagir avec le modèle
déployé (`nestor-hermes`, Ollama) sans passer par n8n ni par l'UI n8n, qui
n'expose aucun déclenchement d'exécution (WORKPLAN §7, §8.6).

## Status
DONE (script écrit, testé bout en bout contre l'instance vivante)

## Owner
Agent de session (opencode), repo `mission-hermes`

## GitHub Issue
— (mission locale, pas d'issue : le dépôt `Whales-Consultancy-Ltd/nestor-hermes`
n'ouvre pas de ticket pour ce lot)

## Livrable
`scripts/hermes-chat.js` — REPL Node vers `https://nestor-ai.biz-4-africa.com/hermes`.

- flux SSE décodé ligne à ligne, `keep_alive: 30m` renvoyé à chaque appel
- métriques par tour : durée, tokens prompt→eval, tok/s, `done_reason`,
  détection de troncature `⚠ tronque`
- commandes : `/stat` `/modele` `/systeme` `/temperature` `/limite` `/reset`
  `/historique` `/sortir`
- mode one-shot `-p` : stdout = réponse brute, métriques sur stderr
- `HERMES_URL` surcharge l'endpoint ; aucun secret dans le fichier

## Preuves (2026-10-03)

| Vérification | Résultat |
|---|---|
| `/api/tags` | 2 modèles réellement présents : `llama3.2:3b` (2,0 Go, 3.2B), `nous-hermes2` (6,1 Go, 11B) |
| `/api/ps` | `llama3.2:3b` chargé |
| Génération streamée | 4,6 s · 27→12 tok · 5,3 tok/s |
| One-shot `-p` | stdout = réponse seule, métriques sur stderr |
| Multi-tour + `/modele` | changement de modèle pris en compte |
| `scripts/check-secrets.sh` | `RESULTAT : OK` (arbre + `--all`) |

## Contraintes héritées (WORKPLAN §4)

- `OLLAMA_NUM_PARALLEL=1` → requêtes sérialisées, pas de préchargement.
- `OLLAMA_KEEP_ALIVE=30m` → 61 s de chargement disque après 30 min d'inactivité ;
  le REPL le maintient chaud entre deux questions.
- `nous-hermes2` : ~176 s et JSON vide avec `format:json` — éviter en production.

## Reste à faire
- P0 reste clos mais le filtre ne contrôle pas la véracité factuelle (§2).
- Le REPL n'exerce que le modèle : il ne passe par le filtre P0 du workflow ni
  par la boucle de régénération. Pour un test conforme, passer par n8n (UI,
  *Manual Trigger*) ou par `scripts/verify-p0-quality.js`.