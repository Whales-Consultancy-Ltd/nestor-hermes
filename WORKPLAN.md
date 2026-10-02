# WORKPLAN — BIZ4A Content Generator

> **Document de reprise.** Écrit pour être lu sans le contexte de la conversation d'origine.
> Toute valeur y est volontairement omise : les secrets vivent dans `~/.config/nestor/secrets.env` (hors dépôt).
> Dernière mise à jour : 2026-10-01 — état vérifié par lectures directes de n8n, Ollama et Aegis.

---

## 1. État en une page

Générateur de contenu LinkedIn pour BIZ4A : génération quotidienne par IA locale, validation humaine par Telegram.

**Ce qui fonctionne, vérifié bout en bout :**

| Phase | Contenu | Preuve |
|---|---|---|
| A | Secrets purgés du dépôt public | `git log -p --all` → 0 correspondance ; hook + `scripts/check-secrets.sh` |
| B | Latence divisée par 15 | `nous-hermes2` 450 s → `llama3.2:3b` **23 s** |
| C | Approbation Telegram réelle | exécution **#48** : `decision=approuver`, `user=TheHatCoder`, message édité `ok:true` |

Boucle complète prouvée par deux exécutions consécutives :

```
#47  Générateur   → llama3.2:3b, 23 s, message_id 9 envoyé avec 3 boutons
#48  Approbateur  → clic reçu, décision lue, branche « Approuvé », message 9 → ok:true
```

**Ce qui bloque :** la qualité de sortie de `llama3.2:3b` (voir §2, P0). La boucle est fonctionnelle, mais ce qu'elle approuve n'est pas publiable en l'état.

---

## 2. Backlog

### P0 — Qualité de sortie du LLM  ← **risque le plus élevé du projet**

`llama3.2:3b` s'attribue la marque et invente des chiffres. Extraits réels issus des exécutions #37 à #47 :

- « j'ai réduit les coûts de personnel de **20 %** et j'ai augmenté la productivité de **25 %** en seulement 6 mois »
- « **Je** vais vous partager **mon** expérience de réussite avec BIZ4A »
- « **En tant que dirigeant de PME, j'ai réalisé** que la clé du succès réside dans… »

Conséquence directe : **approuver revient aujourd'hui à approuver des affirmations invérifiables et signées par BIZ4A.** Le flux est techniquement correct et éditorialement dangereux.

Correctif proposé — les deux ensemble, le prompt seul ne suffit pas sur un modèle 3b :

1. **Verrouillage du prompt** : interdiction explicite de la première personne (`je / mon / ma / mes / notre`) et de tout chiffre absent des données d'entrée.
2. **Filtre post-traitement** : rejeter ou marquer `complete=false` si le texte contient un pronom possessif ou un pourcentage non fourni en entrée.

Vérification : 10 générations consécutives, 0 occurrence. Publication automatique fermée tant que P0 n'est pas clos.

### P1 — Réinscription du webhook Telegram automatisée

Le `setWebhook` est écrit **à la main** (§7). Toute recréation de l'approbateur casse l'approbation silencieusement. À automatiser en script, appelé par un `deploy-workflows.sh`.

### P2 — Observabilité

- Alerte quand `complete=false` (contenu incomplet) : aujourd'hui le contenu est tout de même envoyé avec un champ vide.
- Compteur de publications approuvées : `Enregistrer Publication` écrit dans `$getWorkflowStaticData('global').approuves`, non exposé.
- Le cron ne se déclenche pas après un `PUT` : voir §8, piège n8n.

### P3 — Publication sociale (non commencée)

Le format est déjà prêt : `Enregistrer Publication` dépose `{theme, post:{hook,body,call_to_action}, publie:false, approuve_par, approuve_le}`. Il reste à insérer les nœuds LinkedIn / X / Facebook / Instagram, branchés **après** P0, avec idempotence anti-double-post.

### P4 — Nettoyage

- Archiver `BIZ4A_Content_Generator` `xpY6KBBcjZHweECC` (doublon inactif, 3 nœuds).
- Supprimer les backups laissés sur Aegis : `/srv/nestor-agent-platform/.env.bak.20261001T215259Z`, `docker-compose.yml.bak-trustproxy-*`, `docker-compose.override.yml.bak.20261001T215831Z`.
- `workflow-skeleton.json` est obsolète (précède la migration Telegram), à supprimer ou archiver.

### P5 — Rotation des clés *(différé, échéance ferme)*

Différé à la demande du porteur de projet, mais **la clé n8n en service expire le 2026-10-31**. Passé cette date, aucune modification de workflow n'est possible (l'API publique est le seul moyen d'écrire).

- Rotation n8n : 2026-10-31 au plus tard, via `scripts/set-n8n-key.sh`.
- Webhook Telegram : à réinscrire si le bot change.

### P6 — Compose Aegis cassé *(hors périmètre BIZ4A)*

`docker compose` échoue sur `/srv/nestor-agent-platform` :

- `docker-compose.override.yml` déclare `opencode-adapter` **sans image** (résidu du nettoyage Phase 0-2).
- `email-gateway` déclare `depends_on: orchestrator`, service supprimé du compose principal.

Conséquence : `docker compose up -d` est inutilisable sur ce projet, seul `docker restart` fonctionne. Pré-existant à ce travail, non traité.

---

## 3. Trajectoire C — périmètre engagé

Décision du porteur de projet : fiabiliser la chaîne existante avant d'ouvrir la publication sociale.

**Dans le périmètre maintenant :** P0 (qualité), P1 (webhook automatisé), P2 (observabilité).

**Différé :** P3 (publication), P5 (rotation), P6 (compose).

**Critère de sortie de la trajectoire :** P0 et P1 clos, alerte `complete=false` en place, réinscription du webhook reproductible en une commande.

**Point important :** le filtre de P0 est écrit et testé dans le cadre de la trajectoire, mais la publication automatique reste fermée jusqu'à P3 — donc après validation explicite du porteur de projet sur la qualité.

---

## 4. Infrastructure vérifiée

### Aegis — `aegis.whales-consultancy.biz:8022`, SSH `TheHatCoder`

- Debian 13, **2 vCPU / 12 Go RAM**, load 0,9
- Docker, Traefik v2.11 avec Let's Encrypt (`myresolver`)

### Ollama — conteneur `nestor-hermes`

| Élément | Valeur |
|---|---|
| Image | `ollama/ollama:latest` (v0.34.4) |
| Modèle actif | `llama3.2:3b` (2,0 Go disque / 2,6 Go RAM) |
| Modèle inactif | `nous-hermes2` (6,1 Go) — conservé, inutilisé |
| `OLLAMA_KEEP_ALIVE` | **`30m`** → le modèle est déchargé après 30 min d'inactivité |
| `OLLAMA_NUM_PARALLEL` | `1` → requêtes **sérialisées** |
| Endpoint | `https://nestor-ai.biz-4-africa.com/hermes` (Traefik, `hermes-strip`) |

Latences mesurées :

| Cas | Latence | Détail |
|---|---|---|
| `llama3.2:3b` à chaud | **23 s** | état nominal |
| `llama3.2:3b` à froid | 90 s | dont **61 s de chargement** depuis le disque |
| `nous-hermes2` | 176 s | et **renvoie un JSON vide** avec `format:json` |
| `nous-hermes2` en production (avant bascule) | ~450 s | exécution #33 |

> Note `keep_alive` : le cron étant à 24 h, chaque exécution paie 61 s de chargement. Passer à `-1` immobiliserait 2,6 Go en RAM pour un cron quotidien — **déséquilibré, non fait volontairement**.

### n8n — conteneur `nestor-n8n`

- Version **2.35.5**, sur `https://n8n.whales-consultancy.biz`
- `WEBHOOK_URL=https://n8n.whales-consultancy.biz/` — **correct**, n8n ajoute lui-même le préfixe `/webhook` via `getNodeWebhookUrl()` + `N8N_ENDPOINT_WEBHOOK`
- `N8N_TRUST_PROXY` non défini → le rate limiter émet `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR`. **Bruit de log, pas un blocage** (les webhooks passent en 200). À corriger plus tard si le rate limiter devient bruyant.

### Telegram

Bot utilisé : **`@the_hat_trader_bot`** — distinct de `@The_real_nestor_ai_bot` (plateforme Nestor). Aucun impact sur la plateforme. Chat cible `5387896782`.

---

## 5. Les deux workflows

### Sources de vérité

| Fichier | Workflow |
|---|---|
| `workflow-telegram-approval.json` | `BIZ4A_Content_Generator` — `ieDcsbIeNFBCtppv` |
| `workflow-biz4a-approver.json` | `BIZ4A_Content_Approver` — `8D4pwY4Os56HC1UQ` |

Toute modification passe par un `PUT` sur l'API, puis relecture. **Ne jamais éditer à la main dans l'UI n8n** : la source de vérité est le dépôt.

### Générateur — `ieDcsbIeNFBCtppv` (6 nœuds, actif)

```
Cron Trigger ─┐
              ├→ Theme Picker → LLM Request (Ollama) → Parse Content → Telegram Approval
Manual Trigger┘
```

| Nœud | Rôle |
|---|---|
| `Cron Trigger` | toutes les **24 h** |
| `Theme Picker` | rotation sur 4 thèmes selon le jour de l'année |
| `LLM Request (Ollama)` | `POST /hermes/api/generate`, `llama3.2:3b`, **structured outputs** (schéma JSON strict), `num_predict: 900`, `temperature: 0.7`, `top_p: 0.9`, `timeout: 180000`, `retryOnFail` 3× / 3 s, `onError: continueRegularOutput` |
| `Parse Content` | normalise la réponse, **répare les JSON tronqués**, échappe le Markdown |
| `Telegram Approval` | message + inline keyboard *Approuver / Rejeter / Régénérer* |

### Approbateur — `8D4pwY4Os56HC1UQ` (7 nœuds, actif)

```
Telegram Trigger → Parse Decision → Ack Callback → Approuve ? ┬→ Enregistrer Publication → Edit Message Approuve
                                                             └→ Edit Message Refuse
```

| Nœud | Rôle |
|---|---|
| `Telegram Trigger` | `updates: ['callback_query']`, credential `telegramApi` |
| `Parse Decision` | whitelist des décisions, **idempotence par `(message_id, decision)`**, refus de mise à jour sans `callback_query` |
| `Ack Callback` | fusionne les données du parseur (voir §8, piège majeur) |
| `Approuve ?` | route sur `decision === 'approuver'` |
| `Enregistrer Publication` | dépose le post approuvé dans la static data, `publie: false` |
| `Edit Message Approuve` / `Edit Message Refuse` | met le message Telegram à jour |

### Choix d'architecture : aucun stockage externe

Le contenu n'est pas stocké entre les deux workflows : il est **relu dans `callback_query.message.text`**, que Telegram renvoie avec le clic. Le texte contient des marqueurs fixes (`📌 Thème`, `🪝 Hook`, `📄 Body`, `📗 CTA`) parsés par expressions régulières.

Conséquence : rien à sécuriser, pas de Data Table ni de Redis. **Modifier les marqueurs du générateur oblige à modifier le parseur de l'approbateur.**

---

## 6. Accès et secrets

> **Règle absolue : aucune valeur de secret dans ce dépôt.** Il est public : `Whales-Consultancy-Ltd/nestor-hermes`.

### Coffre local

`~/.config/nestor/secrets.env` — mode `600`, répertoire `700`, **hors dépôt**.

```bash
set -a; . ~/.config/nestor/secrets.env; set +a   # charger
```

Contient `N8N_API_KEY` (JWT n8n, durée de vie 30 jours). Sauvegardes de workflows : `~/.config/nestor/backups/`.

### Charger une nouvelle clé n8n

```bash
./scripts/set-n8n-key.sh '<clé>'
```

Le script valide la **forme** du JWT, **teste l'authentification avant d'écrire**, puis inscrit le secret avec les bons guillemets et la date d'expiration. Il refuse une clé Shell contenant `$`, `&`, `#`, `*`.

### Bot Telegram

Le token n'est **pas** dans le dépôt. Besoin du token pour `getMe` / `getWebhookInfo` / `setWebhook` → le récupérer depuis la source (n8n → *Settings → n8n API*, ou le gestionnaire de secrets de la plateforme).

### Garde-fou

```bash
./scripts/check-secrets.sh     # 3 contrôles : arbre, historique --all, préfixes informatifs
```

Appelé automatiquement par `.git/hooks/pre-commit` (non versionné : `.git/hooks/`).

Motifs **sur une seule ligne** — un motif multi-lignes fait splitter l'expression par `grep` et produit une alternative vide qui matche tout le fichier. Le motif JWT exige les **3 segments** ; le motif PEM est ancré en début de ligne. Un préfixe seul n'est pas un secret (en-tête JWT standard, présent dans des millions de jetons publics).

Le script fait `git add -A` puis restaure l'index, car `git grep` n'indexe que les fichiers **suivis**.

### SSH

```bash
ssh -p 8022 TheHatCoder@aegis.whales-consultancy.biz
ssh the@office.biz-4-africa.com     # machine office : 3 cœurs, load 8,7, pas de GPU
```

---

## 7. Procédures opératoires

### Pousser un workflow

```bash
set -a; . ~/.config/nestor/secrets.env; set +a
cp ~/.config/nestor/backups/  # déjà fait avant chaque push
python3 -c "
import json
d=json.load(open('workflow-biz4a-approver.json'))
json.dump({k:d[k] for k in ('name','nodes','connections','settings')}, open('/tmp/p.json','w'), ensure_ascii=False)"
curl -X PUT -H "X-N8N-API-KEY: $N8N_API_KEY" -H 'Content-Type: application/json' \
  --data @/tmp/p.json \
  https://n8n.whales-consultancy.biz/api/v1/workflows/<ID>
```

Toujours **sauvegarder avant**, et **relire la réponse** pour confirmer l'état réel.

### Activer / désactiver — l'API ne le permet pas

```
PATCH /workflows/{id}          → 405  (méthode non autorisée)
POST  /workflows/{id}/activate → 404  (endpoint inexistant)
PUT   avec "active": true      → 400  request/body/active is read-only
```

Contournement par la CLI, dans le conteneur :

```bash
docker exec nestor-n8n n8n update:workflow --id=<ID> --active=true
docker restart nestor-n8n            # ~9 s, obligatoire
```

⚠️ **Cette méthode écrit en base sans déclencher le cycle de vie des webhooks.** C'est pourquoi l'inscription Telegram doit être refaite à la main (§ P1). Avant tout `restart`, vérifier qu'aucune exécution n'est en cours.

### Réinscrire le webhook Telegram

Le `secret_token` est **déterministe** (§ code source n8n) :

```
secret_token = <workflowId>_<nodeId>       (puis sanitize [A-Za-z0-9_-])
```

Soit, pour l'approbateur : `8D4pwY4Os56HC1UQ_telegram-trigger-1`.

```bash
curl -X POST "https://api.telegram.org/bot<TOKEN>/setWebhook" \
  -H 'Content-Type: application/json' \
  -d '{
    "url":"https://n8n.whales-consultancy.biz/webhook/<webhookId>/webhook",
    "secret_token":"<workflowId>_<nodeId>",
    "allowed_updates":["message","edited_message","callback_query"],
    "drop_pending_updates":false
  }'
curl "https://api.telegram.org/bot<TOKEN>/getWebhookInfo"
```

`webhookId` et chemin : table `webhook_entity` de `/home/node/.n8n/database.sqlite` (colonne `webhookPath`).

### Déclencher un workflow

L'API publique **n'expose aucune exécution** (`POST /run|execute|trigger` → 405/404). Le nœud Manual Trigger ne se déclenche que depuis l'UI, ou via le cron. Un cron mis à 1 minute par `PUT` **ne se déclenche pas** (voir §8).

### Diagnostiquer

L'API ne montre ni les erreurs de nœud ni les données intermédiaires. Pour comprendre une exécution :

```bash
curl -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "https://n8n.whales-consultancy.biz/api/v1/executions/<ID>?includeData=true"
```

Puis lire `data.resultData.runData[<nœud>][0].data.main[0][0].json`. **C'est la seule source de vérité** : les logs n8n ne montrent ni les erreurs de nœud ni les données.

Ou en base :

```bash
docker exec nestor-n8n node -e '
const {DatabaseSync}=require("node:sqlite");
const db=new DatabaseSync("/home/node/.n8n/database.sqlite",{readOnly:true});
for(const r of db.prepare("SELECT id,status,mode,startedAt FROM execution_entity ORDER BY id DESC LIMIT 8").all())
  console.log(r.id,r.status,r.mode,r.startedAt);
' 2>&1 | grep -viE 'error tracking|custom api'
```

---

## 8. Pièges n8n 2.35.5

Chacun a coûté plusieurs cycles de debug. **Tous produisent des logs silencieux ou trompeurs.**

### 8.1 Un nœud Telegram natif **écrase** la charge utile

La sortie ne contient que `{ok, result}`. Tout le reste disparaît.

Impact réel : `decision` disparaissait avant l'IF, qui comparait `undefined` et **prenait la branche « refusé »** alors que l'utilisateur avait approuvé. Les logs indiquaient `Edit Message Refuse ok` — piège total.

**Règle :** ne jamais placer un nœud Telegram natif sur un chemin dont les données servent à router. Intercaler un nœud Code qui fusionne.

### 8.2 `replyMarkup` est une structure, pas une expression

Écrire `={{ { "inlineKeyboard": ... } }}` est silencieusement ignoré → `reply_markup: null` → aucun bouton.

```json
"replyMarkup": "inlineKeyboard",
"inlineKeyboard": { "rows": [ { "row": { "buttons": [
  { "text": "✅ Approuver", "additionalFields": { "callback_data": "approuver" } }
]}}]}
```

`callback_data` se place dans `additionalFields` **du bouton**, pas du nœud.

### 8.3 Signature de `answerCallbackQuery`

```js
resource: "callback"     // et non "message"
operation: "answerQuery" // et non "answerCallbackQuery"
queryId: <callback_query.id>
```

`chatId` / `callbackQueryId` **n'existent pas** sur cette opération. Source : `dist/nodes/Telegram/Telegram.node.js`.

### 8.4 Le secret du webhook Telegram est déterministe

`getSecretToken()` = `<workflowId>_<nodeId>`. Sans ce header, le webhook répond `403 Provided secret is not valid` — c'est le comportement attendu, pas une panne.

### 8.5 Activation par CLI ≠ cycle de vie complet

`n8n update:workflow --active=true` écrit en base sans appeler `create()` → `setWebhook` n'est pas rejoué.

### 8.6 Un cron modifié par `PUT` ne se déclenche pas

Passer le cron à 1 minute puis `restart` produit `Activated workflow` dans les logs, mais **aucune exécution**. L'UI déclenche seule. Ne pas perdre de temps là-dessus.

### 8.7 Le code du `Theme Picker` est figé dans le nœud

Le jour de l'année n'est recalculé qu'à l'exécution ; le sélecteur de thème visible dans l'UI n'existe pas comme paramètre. Modifier la liste des thèmes = éditer le `jsCode`.

---

## 9. Journal d'erreurs

| Symptôme trompeur | Cause réelle | Diagnostic |
|---|---|---|
| « Error au niveau n8n » sans message | `Parse Content` : `done_reason=length`, JSON tronqué | lire `data.total_duration` / `done_reason` / `eval_count` de la sortie du nœud LLM |
| Le message Telegram arrive **sans boutons** | `reply_markup: null` | lire `result.reply_markup` de la sortie `Telegram Approval` |
| Le clic approuve le **refus** | nœud Telegram destructeur (§8.1) | lire la sortie de `Ack Callback` : `decision` vaut `undefined` |
| `403 Provided secret is not valid` | comportement **normal** (§8.4) | vérifier l'URL dans `getWebhookInfo` |
| `Node does not have any credentials set` | credential manquante sur le `Telegram Trigger` | vérifier `credentials` sur **chaque** nœud Telegram |
| Le cron ne part jamais | §8.6 | passer par l'UI |
| `POST /workflows/{id}/run` → 405 | l'API publique n'expose pas l'exécution | UI uniquement |
| Un fichier semble modifié alors que non | décalage d'offset entre deux lectures | relire **sur disque**, pas en mémoire |

### Erreurs de ma part, à ne pas reproduire

1. **Probe destructif** : `curl -X DELETE` envoyé pour sonder les méthodes HTTP acceptées → a **supprimé** un workflow. Un workflow perdu n'est pas anodin ; ici il existait dans git et n'était pas activé. **Ne jamais sonder avec `DELETE`.**
2. **Modification en mémoire sans écriture disque** : changement appliqué, `json.dump` oublié → la base et le fichier local divergeaient, et la vérification affichait le code *vrai* alors que le push envoyait l'ancien. **Toujours relire le fichier sur disque après écriture.**
3. **Ancre d'édition trop stricte** : un script d'édition a échoué silencieusement sur un offset calculé à la lecture précédente.
4. **Confusion avertissement / cause** : `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR` traité comme bloquant alors que le webhook passait en 200. Modification de config inutile sur un compose déjà cassé — 3 fichiers touchés puis restaurés.

---

## 10. Historique git

Cinq commits locaux, **non poussés** (`git rev-list --count origin/main..HEAD` → 5).

```
806d4e0 feat(BIZ4A): boucle d'approbation Telegram operationnelle
f61e88d feat(BIZ4A): approbation Telegram reelle (boutons + decision + idempotence)
538aca4 chore(securite): centralise les motifs dans scripts/check-secrets.sh
59007f9 feat(BIZ4A): bascule le workflow sur llama3.2:3b (450s -> 35s)
4aad4b2 docs: purge le JWT n8n du README, coffre local + garde-fou pre-commit
```

Rappel : `git push` n'a jamais été demandé sur ce dépôt. **Ne pas pousser sans instruction explicite.**

---

## 11. Pour reprendre

1. Lire §1 (état), §2 (backlog), §3 (périmètre engagé)
2. Choisir une tâche du backlog
3. Consulter §7 (procédures) et §8 (pièges) **avant** toute modification
4. Si une erreur survient : §9, puis `/api/v1/executions/<ID>?includeData=true` — les logs ne mentent pas assez, les nœuds si
5. Après chaque modification : relire **le fichier sur disque**, pousser, puis relire **la réponse n8n**