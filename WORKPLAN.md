# WORKPLAN — BIZ4A Content Generator

> **Document de reprise.** Écrit pour être lu sans le contexte de la conversation d'origine.
> Toute valeur y est volontairement omise : les secrets vivent dans `~/.config/nestor/secrets.env` (hors dépôt).
> Dernière mise à jour : 2026-10-03 — P0/P1/P2 écrits et testés hors ligne ; **déploiement n8n bloqué par une panne DNS** (§0).

---

## 0. Incident en cours — à lire avant tout

**La zone DNS `whales-consultancy.biz` est en SERVFAIL depuis le 2026-10-02 au soir.**

Constaté par deux résolveurs indépendants (Cloudflare `1.1.1.1` et Google `8.8.8.8`,
via DoH), qui renvoient `Status 2` sur `NS` et `SOA` de la zone elle-même — la
délégation est cassée, pas l'instance. La zone sœur `biz-4-africa.com` répond
normalement. Conséquence :

| Cible | État |
|---|---|
| `n8n.whales-consultancy.biz` (API, UI) | injoignable — aucun `PUT` possible |
| `aegis.whales-consultancy.biz:8022` (SSH) | injoignable — aucun `docker exec` |
| Traefik / Let's Encrypt sur ce domaine | injoignable |
| `nestor-ai.biz-4-africa.com/hermes` (Ollama) | **joignable** — le modèle est testable |

Le P0 a donc pu être **vérifié contre le vrai modèle** pendant toute la panne,
mais les workflows modifiés ne sont **pas déployés** : Only `ieDcsbIeNFBCtppv`
porte la version P0 en base (déployée avant la panne), les ajouts P2 et les
scripts P1 sont **localisés et testés, pas poussés**.

### Reprise, dans cet ordre

```bash
# 1. Le DNS est revenu, ou une IP est connue -> forcer la resolution :
export N8N_IP=<ip>            # garde le SNI/TLS correct, sans /etc/hosts
./scripts/deploy-workflows.sh --check   # compare local / distant, n'ecrit rien
./scripts/deploy-workflows.sh           # sauvegarde + PUT + relecture + webhook

# 2. Renseigner le token Telegram dans le coffre, puis :
./scripts/set-telegram-webhook.sh       # verifie au passage le webhook

# 3. P4, qui exige SSH :
./scripts/aegis-maintenance.sh archive-dup --apply
./scripts/aegis-maintenance.sh clean-backups --apply
```

---

## 1. État en une page

Générateur de contenu LinkedIn pour BIZ4A : génération quotidienne par IA locale, validation humaine par Telegram.

**Ce qui fonctionne, vérifié bout en bout :**

| Phase | Contenu | Preuve |
|---|---|---|
| A | Secrets purgés du dépôt public | `git log -p --all` → 0 correspondance ; hook + `scripts/check-secrets.sh` |
| B | Latence divisée par 15 | `nous-hermes2` 450 s → `llama3.2:3b` **23 s** |
| C | Approbation Telegram réelle | exécution **#48** : `decision=approuver`, `user=TheHatCoder`, message édité `ok:true` |
| D | **P0 qualité LLM** | prompt verrouillé + filtre ; **10 générations, 0 occurrence** (§2) |
| E | **Aller-retour générateur → approbateur** | `scripts/test-telegram-roundtrip.js`, 4 cas |

Boucle complète prouvée par deux exécutions consécutives :

```
#47  Générateur   → llama3.2:3b, 23 s, message_id 9 envoyé avec 3 boutons
#48  Approbateur  → clic reçu, décision lue, branche « Approuvé », message 9 → ok:true
```

**Ce qui bloquait :** la qualité de sortie de `llama3.2:3b` → **treat P0**.
Ce qui bloque **maintenant** : la panne DNS (§0). La boucle est fonctionnelle et
ne laisse plus passer d'affirmation inventée ; ce qu'elle approuve reste toutefois
le fait d'un modèle 3b, et le filtre ne contrôle pas la véracité factuelle.

---

## 2. Backlog

### P0 — Qualité de sortie du LLM — **CLOS** (2026-10-02)

`llama3.2:3b` s'attribue la marque et invente des chiffres. Extraits réels issus des exécutions #37 à #47 :

- « j'ai réduit les coûts de personnel de **20 %** et j'ai augmenté la productivité de **25 %** en seulement 6 mois »
- « **Je** vais vous partager **mon** expérience de réussite avec BIZ4A »
- « **En tant que dirigeant de PME, j'ai réalisé** que la clé du succès réside dans… »

Conséquence directe : **approuver revient aujourd'hui à approuver des affirmations invérifiables et signées par BIZ4A.** Le flux est techniquement correct et éditorialement dangereux.

Correctif proposé — les deux ensemble, le prompt seul ne suffit pas sur un modèle 3b :

1. **Verrouillage du prompt** : interdiction explicite de la première personne (`je / mon / ma / mes / notre`) et de tout chiffre absent des données d'entrée.
2. **Filtre post-traitement** : rejeter ou marquer `complete=false` si le texte contient un pronom possessif ou un pourcentage non fourni en entrée.

**Réalisé.** Les deux correctifs sont en place, plus une boucle de régénération.

1. Prompt verrouillé (interdictions explicites, listées ligne à ligne).
2. Filtre dans `Parse Content` : `complete = champs présents ET quality_flags vide`.
   `quality_flags` porte les occurrences exactes (`chiffre non source (hook : 20)`),
   et le message Telegram affiche un bandeau `⚠️ NON CONFORME`.
3. **Boucle de régénération bornée à 3** : `Est conforme ?` → `Compteur Tentative`
   → `Tentative Epuisee ?` → retour `LLM Request`, avec `Alerte Echec` si épuisée.
   Le compteur retransmet `theme`, sans quoi les tentatives 2 et 3 généreraient à vide.

**Résultat mesuré : 9/10 conformes, 1 rejet, 0 occurrence.**

Trois bugs trouvés en route, qu'aucune relecture de code n'aurait montrés :

- **Le `4` de `BIZ4A` compté comme chiffre inventé.** `\d` matche le `4` de la
  marque : tout contenu citant BIZ4A était rejeté à tort (3/10 → 5/10 conformes
  une fois corrigé). Regex : `/(?<![\p{L}\d])\d+(?:[.,]\d+)?(?![\p{L}])/gu`.
- **`en tant que` trop large.** Bloquait « En tant que dirigeant, **vous**
  connaissez… », qui est de la 2ᵉ personne. Règle retirée ; l'exemple WORKPLAN
  reste bloqué, via `j'ai`.
- **Libellé de vérification inversé.** Le script de contrôle affichait le nombre
  de rejets sous une mention « passe le filtre ». Le critère porte sur ce qui
  **traverse** le filtre, pas sur ce qui est rejeté.

**Réserve honnête :** le filtre couvre les classes définies au §2, pas la
véracité factuelle. Une génération affirmait que l'OHADA provoque des
« interdictions automatiques de produits » — invéridique, sans chiffre ni
première personne, donc **validée par le filtre**. L'hallucination de faits par
un modèle 3b reste un problème ouvert, distinct de P0.

> Publication automatique toujours fermée : `Enregistrer Publication` écrit
> `publie: false`. Rien ne part sans les nœuds de la phase P3.

### P1 — Réinscription du webhook Telegram — **script écrit, non exécuté**

Le `setWebhook` était écrit **à la main** (§7). Toute recréation de l'approbateur
casse l'approbation silencieusement.

**`scripts/set-telegram-webhook.sh`** — lit le `webhookId` sur l'API publique au
lieu de la base SQLite du conteneur : pas de SSH, et surtout la valeur de
l'instance vivante est utilisée. `--check` vérifie sans écrire.

**`scripts/deploy-workflows.sh`** — sauvegarde → `PUT` → **relecture et comparaison
de l'API** → réinscription du webhook. `--check` compare sans écrire.

Deux garde-fous non triviaux :

- **Le `webhookId` du dépôt est préservé s'il diverge du distant.** Il est généré
  par n8n à l'activation, ce n'est pas du contenu écrit. Un `PUT` qui l'écraserait
  changerait l'URL du webhook et casserait l'approbation jusqu'à la réinscription.
- **La comparaison post-`PUT` se fait contre la charge envoyée**, pas contre le
  fichier du dépôt, sinon l'injection ci-dessus déclencherait un faux écart.

**Reste à faire :** renseigner `TELEGRAM_BOT_TOKEN` dans le coffre (l'API n8n
n'expose pas les credentials, le token ne peut pas être récupéré par l'API), puis
exécuter. Voir §0.

### P2 — Observabilité — **partiellement fait, non déployé**

- ✅ **Alerte `complete=false`** — un champ manquant est maintenant signalé comme
  les autres alertes (`champ manquant (body)`) et remonte dans le bandeau. Avant,
  le contenu incomplet partait avec un simple champ vide, sans aucun signal.
- ✅ **Compteur de publications approuvées** — il était écrit mais jamais exposé.
  `total_approuves` est maintenant retourné et affiché dans le message Telegram
  (`_Publication n° 7_`). Fenêtre glissante de 200 : c'est un compteur borné,
  pas un historique. La clé est le `message_id`, donc un double clic n'incrémente pas.
- ✅ **La décision du filtre est tracée à l'approbation** — `qualite`
  (`ok` / `non_conforme`) est lu dans le message et stocké avec la publication. On
  peut enfin savoir ce qui a été validé en connaissance de cause.
- ⬜ **Le cron ne se déclenche pas après un `PUT`** : documenté (§8.6), rappelé en
  fin de `deploy-workflows.sh`, mais pas contourné. Le contournement dépend d'un
  `docker restart`, donc d'un accès SSH — indisponible pendant la panne.

### P3 — Publication sociale (non commencée)

Le format est déjà prêt : `Enregistrer Publication` dépose `{theme, post:{hook,body,call_to_action}, publie:false, approuve_par, approuve_le}`. Il reste à insérer les nœuds LinkedIn / X / Facebook / Instagram, branchés **après** P0, avec idempotence anti-double-post.

### P4 — Nettoyage

- ⬜ Archiver `BIZ4A_Content_Generator` `xpY6KBBcjZHweECC` (doublon inactif, 3 nœuds).
  L'API publique ne sait pas archiver (`isArchived` est en lecture seule, comme
  `active`) ; il faut la CLI dans le conteneur. `scripts/aegis-maintenance.sh
  archive-dup` sauvegarde d'abord le JSON via l'API, puis archive — **jamais de
  `DELETE`**. Non exécuté : SSH indisponible.
- ⬜ Supprimer les backups laissés sur Aegis : `/srv/nestor-agent-platform/.env.bak.20261001T215259Z`,
  `docker-compose.yml.bak-trustproxy-*`, `docker-compose.override.yml.bak.20261001T215831Z`.
  `scripts/aegis-maintenance.sh clean-backups` liste puis supprime, **simulation par
  défaut**. Contiennent potentiellement des secrets : à supprimer, surtout pas à
  archiver dans le dépôt. Non exécuté : SSH indisponible.
- ✅ `workflow-skeleton.json` **supprimé** (nœuds `Hermes LLM Request` et
  `Email Approval`, antérieurs à Telegram ; rien ne le référençait ; récupérable
  en git via `59007f9`).

### P5 — Rotation des clés *(différé, échéance ferme)*

Différé à la demande du porteur de projet, mais **la clé n8n en service expire le 2026-10-31**. Passé cette date, aucune modification de workflow n'est possible (l'API publique est le seul moyen d'écrire).

- Rotation n8n : 2026-10-31 au plus tard, via `scripts/set-n8n-key.sh`.
- Webhook Telegram : à réinscrire si le bot change.

### P6 — Compose Aegis — **CORRIGÉ le 2026-10-03** *(hors périmètre BIZ4A)*

**Le diagnostic initial était partiellement faux.** Ce qui a été vérifié sur
l'hôte le 2026-03 :

| Défaut annoncé | Réalité |
|---|---|
| `opencode-adapter` « sans image » | Vrai, mais la cause est autre : le service **n'existe pas non plus** dans le compose de base. L'override ne portait que `volumes`/`entrypoint`/`command` ; le `build:` avait disparu avec la définition. Le contexte `services/opencode-adapter/` existe bel et bien sur disque. |
| `email-gateway` dépend d'`orchestrator` « supprimé » | Vrai. `orchestrator` n'est déclaré **nulle part** : `docker-compose.embedding-cpu.yml` n'en ajoute que des variables d'environnement à un service inexistant, ce qui ne peut pas le créer. |

Le compose **déployé** (348 lignes) n'est par ailleurs pas le même que celui du
dépôt local : le local déclare encore `orchestrator` et `opencode-adapter`. Deux
révisions divergent — source de la confusion.

**Correctif appliqué** (commenté, pas supprimé, pour rester réversible) :

- `depends_on: orchestrator` neutralisé dans `docker-compose.yml`.
- `build: ./services/opencode-adapter` + `container_name` restitués dans l'override.

`docker compose config -q` **passe désormais**. Sauvegardes `*.bak-p6-20261003T134212Z`.
Aucun conteneur n'a été (re)démarré : les 22 services tournaient avant et après.

> La plateforme est **en production** sur cet hôte : `nestor-n8n`,
> `nestor-email-gateway`, `nestor-postgres`, `nestor-redis`, `nestor-nats`,
> `nestor-temporal`, les agents, Traefik. Ne jamais `docker compose up -d` sur
> ce projet sans avoir vérifié ce qui serait recréé.

### Point de sécurité relevé pendant P6

`JWT_SECRET` n'est défini dans **aucun** `.env` : il se résout à une chaîne vide
et est passé à `nats-secure-channel` (JetStream + auth JWT + ACL + certificats
TLS). Un secret vide signifie des jetons signés avec une clé connue.

Le service est **dormant** (`nester-nats-secure-channel` absent des conteneurs),
donc non exposé aujourd'hui. **À définir avant de le démarrer.**

```bash
./scripts/aegis-maintenance.sh status --apply    # vérifier l'état des conteneurs
```

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

### Concurrence : `OLLAMA_NUM_PARALLEL` — mesuré, pas supposé

La variable **n'était pas définie** : le WORKPLAN concluait « `NUM_PARALLEL=1` →
requêtes sérialisées », ce qui est juste le défaut d'Ollama sur CPU, pas un
réglage délibéré. Le modèle n'occupe que 2,6 Go pour **6,1 Go disponibles**.

Mise à `2` le 2026-10-03 (`/srv/nestor-hermes/docker-compose.yml`, projet
**distinct** de `nestor-agent-platform` — donc indépendant de P6). Mesures à
modèle chaud, 80 tokens :

| | débit agrégé |
|---|---|
| séquentiel (4 req, 44 s) | **5.02 tok/s** |
| parallèle ×2 (17 s / 25 s / 48 s) | **5.83 / 5.70 / 2.88 tok/s** |

**Gain réel ≈ +15 %, pas le ×1,3 à ×1,6 attendu.** 2 vCPU sont un plafond dur, et
la première paire est parfois *plus lente* (48 s) : le modèle résident doit
être reconfiguré pour 2 emplacements. Gardé parce que c'est gratuit, mais ce
n'est pas le levier. Le vrai levier pour les tests serait de lancer les requêtes
du harnais en parallèle.

> Le premier couple de mesures a été **invalidé** : le conteneur venait d'être
> recréé, chaque requête payait le rechargement de 61 s depuis le disque
> (`total_duration` indiquait 0,65 tok/s). Toute mesure après un redémarrage
> doit être reprise à chaud.

> Note `keep_alive` : le cron étant à 24 h, chaque exécution paie 61 s de chargement. Passer à `-1` immobiliserait 2,6 Go en RAM pour un cron quotidien — **déséquilibré, non fait volontairement**.

### n8n — conteneur `nestor-n8n`

- Version **2.35.5**, sur `https://n8n.whales-consultancy.biz`
- `WEBHOOK_URL=https://n8n.whales-consultancy.biz/` — **correct**, n8n ajoute lui-même le préfixe `/webhook` via `getNodeWebhookUrl()` + `N8N_ENDPOINT_WEBHOOK`
- `N8N_TRUST_PROXY` non défini → le rate limiter émet `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR`. **Bruit de log, pas un blocage** (les webhooks passent en 200). À corriger plus tard si le rate limiter devient bruyant.

### Telegram

Bot utilisé : **`@the_hat_trader_bot`** — distinct de `@The_real_nestor_ai_bot` (plateforme Nestor). Aucun impact sur la plateforme. Chat cible `5387896782`.

---

## 4 bis. Chat Telegram vers Hermes

**Écrit le 2026-10-03, déployé et prouvé.** Écris un message à `@the_hat_trader_bot`,
Hermes répond.

### Contrainte structurante : un seul webhook par jeton

Telegram n'accepte **qu'une URL de webhook par jeton de bot**. Les deux workflows
historiques partagent la même credential (`o2cm9Tyzy89zPU7X`). Un second
`Telegram Trigger` autonome aurait donc **écrasé** le webhook de l'approbateur, et
l'approbation serait morte en `403 Provided secret is not valid` — sans la moindre
erreur visible dans les logs.

Le chat a donc été intégré **dans** `BIZ4A_Content_Approver`, qui porte désormais
les deux fonctions, avec un seul point d'entrée :

```
Telegram Trigger (message, callback_query)
   └→ Route Evenement ─┬(callback_query)→ Parse Decision → … approbation (inchangée)
                      └(message)       → Guard Chat → Message pertinent ?
                                          → Hermes Chat (Ollama) → Reponse Hermes
                                          → Telegram Reponse
```

### Garde-fous

| Garde | Rôle |
|---|---|
| `Guard Chat` | chat `5387896782` uniquement ; ignore les bots, les médias, les commandes |
| `Message pertinent ?` | **avant** toute requête HTTP : un message écarté ne consomme pas de génération |
| Fiche BIZ4A | le modèle ne répond qu'avec ces faits, et dit « je n'ai pas cette information » sinon |
| `Reponse Hermes` | borne à 4000 caractères (limite Telegram) |
| `parse_mode` absent | un `_` ou `*` du modèle ferait échouer l'API en 400 |

### Preuve

Exécutions **#52 à #54** : `success`, `Telegram Reponse ok=true`, `message_id` 11, 12, 13.

### Deux pièges rencontrés

1. **`chat_id is empty`.** `Conserver Chat` avait été placé **avant** le nœud HTTP
   pour transporter le `chat_id` ; or le nœud HTTP remplace intégralement la charge
   utile. Le message partait donc vide. Correctif : relire `chat_id` chez
   `Guard Chat` via `$('Guard Chat')`. C'est le même piège que §8.1, version HTTP.
   Le test l'a d'abord **manqué** parce qu'il injectait `__chat_id` à la main au
   lieu de jouer la chaîne réelle : le test a été durci pour jouer le vrai chemin.
2. **`llama3.2:3b` hallucine sur BIZ4A.** Il a affirmé que BIZ4A était « une
   plateforme créée par l'État ». Une fiche de faits a été ajoutée au prompt
   système. Résultat après correctif : le modèle **refuse** plutôt que d'inventer,
   ce qui est le bon compromis — mais il répond parfois « je ne connais pas
   BIZ4A » alors que la fiche la décrit. **Verdict : ce bot est un intervieweur
   approximatif, pas une source de vérité.**

---

## 4 ter. Règle de nommage — « Nestor v1.0.0 » vs « Ollama BIZ4A » (2026-10-03, décision Vincent)

**« Hermes » est un terme proscrit** dans le vocabulaire de la plateforme. Trois
entités coexistent et se confondaient jusqu'à produire une fausse installation
(leçon gravée en SSOT : `nestor-rules.md` P68 + P69).

| Entité | Désignation officielle | Nature | Où |
|---|---|---|---|
| L'agent (produit Nous Research, MIT) | **Nestor v1.0.0** | Agent : outils, mémoire, skills, cron, gateway 25+ plateformes | `~/.hermes/`, CLI `hermes`, repo upstream `NousResearch/hermes-agent` |
| Le serveur de modèles | **Ollama BIZ4A** | Serveur d'inférence — **pas un agent** | conteneur `nestor-hermes`, `https://nestor-ai.biz-4-africa.com/hermes` |
| Le modèle `nous-hermes2` | **modèle nous-hermes2** | Poids LLM | disque du conteneur |

Écrire « Hermes » ou « Nestor » sans qualificatif est **interdit**.

Le chemin technique `~/.hermes/` **reste** `~/.hermes/` : c'est un artefact amont,
non renommable sans casser `hermes update`. Le renommage est fonctionnel et
documentaire, pas physique. `HERMES_HOME` reste la variable d'env du produit.

> §4 bis ci-dessus parle du chat Telegram n8n branché sur **Ollama BIZ4A** : c'est
> un intervieweur `llama3.2:3b` dans un workflow n8n, **pas** Nestor v1.0.0. Les
> deux sont des surfaces de conversation mais ce sont des systèmes distincts.

### Surfaces d'accès à Nestor v1.0.0

Toutes partagent le même `~/.hermes/state.db` : une session commencée dans la TUI
se reprend dans le navigateur et sur Telegram.

| Surface | Commande | Usage |
|---|---|---|
| TUI | `hermes --tui` | terminal (Node ≥ 20 requis) |
| Dashboard web | `hermes dashboard` → `http://127.0.0.1:9119` | Chrome ; l'onglet Chat héberge la vraie TUI en xterm.js |
| Gateway | `hermes gateway` | Telegram et 24 autres plateformes |
| API server | toolset `hermes-api-server` | compatible OpenAI |

Le dashboard est **borné à loopback, sans login**. Un bind hors loopback
(`--host 0.0.0.0`) **engage un gate d'auth obligatoire** et le serveur refuse de
démarrer sans provider configuré — c'est un refus volontaire, pas une panne.

### Contrainte de modèle

Nestor v1.0.0 **refuse de démarrer sous 64k de contexte**. `llama3.2:3b` sur
Ollama BIZ4A est à 2 vCPU : il ne peut pas servir d'agent outillé.

Source de vérité des fournisseurs : **`/srv/nestor-agent-platform/conf/llm-registry.yaml`**
(8 fournisseurs, non-secret, avec l'état de chaque clé). **Jamais** la liste des
modèles dans un fichier de clés. Au 2026-09-03 : `llmkiwi` gratuit et healthy,
`gemini` / `mistral` / `cloudflare` / `bazaarlink` opérationnels ;
`openrouter` en backoff 404, `deepseek` et `openai` dégradés (solde épuisé).

### Vérifier la présence avant de conclure

```bash
which hermes                 # binaire publié ?
ls -d ~/.hermes             # install en cours ou déjà faite ?
pgrep -af 'launch.py install'   # l'install tourne-t-elle encore ?
```

Un `which hermes` vide **ne prouve pas** l'absence de l'agent : l'install
télécharge ~500 Mo et crée le venv **avant** de publier le binaire. Conclure
« non installé » sur cette seule commande est une **fausse négative** — c'est
exactement l'erreur commise le 2026-10-03.

---

## 5. Les workflows

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

### Approbateur — `8D4pwY4Os56HC1UQ` (13 nœuds, actif)

> Il porte aussi le chat Hermes (§4 bis). Le chemin d'approbation est inchangé.

```
Telegram Trigger → Parse Decision → Ack Callback → Approuve ? ┬→ Enregistrer Publication → Edit Message Approuve
                                                             └→ Edit Message Refuse
```

| Nœud | Rôle |
|---|---|
| `Telegram Trigger` | `updates: ['message','callback_query']`, credential `telegramApi` |
| `Parse Decision` | whitelist des décisions, **idempotence par `(message_id, decision)`**, refus de mise à jour sans `callback_query` |
| `Ack Callback` | fusionne les données du parseur (voir §8, piège majeur) |
| `Route Evenement` | `callback_query` → approbation ; `message` → chat (§4 bis) |
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

## 6 bis. Scripts

Tous lancables depuis la racine du dépôt. Aucun ne contient de secret : ils lisent
le coffre. `check-secrets.sh` passe sur l'ensemble.

| Script | Rôle | Réseau |
|---|---|---|
| `scripts/check-secrets.sh` | garde-fou anti-secret (arbre, `--all`, préfixes) | non |
| `scripts/set-n8n-key.sh` | validate et installe une clé n8n (P5) | oui |
| `scripts/deploy-workflows.sh` | sauvegarde + `PUT` + relecture + webhook | oui |
| `scripts/set-telegram-webhook.sh` | réinscrit le webhook Telegram (`--check`) | oui |
| `scripts/aegis-maintenance.sh` | archivage du doublon, purge des `.bak` (SSH) | oui |
| `scripts/test-quality-filter.js` | 12 cas du filtre P0, lus depuis le workflow | non |
| `scripts/test-telegram-roundtrip.js` | message généré → relu par l'approbateur | non |
| `scripts/verify-p0-quality.js` | 10 générations réelles + filtre déployé | Ollama |

Les deux scripts réseau acceptent `N8N_IP=<ip>` : le SNI/TLS reste correct sans
toucher à `/etc/hosts` ni demander root. Indispensable pendant la panne DNS (§0).

```bash
node scripts/test-quality-filter.js      # garde-fou, < 1 s, hors ligne
node scripts/test-telegram-roundtrip.js
node scripts/verify-p0-quality.js 10     # ~6 min, 10 appels Ollama serialisés
```

#### Interaction avec le modèle — ne pas réimplémenter

Il existedici `scripts/hermes-chat.js`, un REPL Node écrit à la main sur
l'API `/api/chat` du conteneur `nestor-hermes`. **Il a été supprimé** : c'était
une réimplémentation d'un produit qui existe déjà.

L'outil pour discuter avec un modèle n'est pas un script de ce dépôt, c'est
**Nestor v1.0.0** (= le produit *Hermes Agent* de Nous Research) — § 4 bis.
Sa TUI et son dashboard web remplacent ce REPL, avec en plus les outils, la
mémoire persistante et les skills.

> **Le vocabulaire « Hermes » est ambigu et distingue deux choses sans rapport.**
> Cf. § 4 bis pour la règle de nommage.

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

### Réinscrire le webhook Telegram — **ne plus faire à la main**

```bash
./scripts/set-telegram-webhook.sh          # 1 commande : inscription + vérification
./scripts/set-telegram-webhook.sh --check  # état courant, sans écriture
```

La procédure manuelle ci-dessous est conservée pour comprendre le mécanisme
(l'API publique n'expose ni `setWebhook` ni la base). Elle est **périmée en usage
courant** : le script lit le `webhookId` sur l'API et dérive le `secret_token`.

### (référence) Réinscription manuelle

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

Six commits locaux, **non poussés** (`git rev-list --count origin/main..HEAD` → 6).
Le travail P0/P1/P2/P4 du 2026-10-02/03 est **en plus dans l'arbre de travail, non
commité**, et `workflow-skeleton.json` est supprimé (`git rm`, récupérable).

```
806d4e0 feat(BIZ4A): boucle d'approbation Telegram operationnelle
f61e88d feat(BIZ4A): approbation Telegram reelle (boutons + decision + idempotence)
538aca4 chore(securite): centralise les motifs dans scripts/check-secrets.sh
59007f9 feat(BIZ4A): bascule le workflow sur llama3.2:3b (450s -> 35s)
4aad4b2 docs: purge le JWT n8n du README, coffre local + garde-fou pre-commit
```

```
 b3e7d28 docs: WORKPLAN de reprise pour le projet BIZ4A   ( workflows + scripts P0/P1/P2/P4 )
```

Rappel : `git push` n'a jamais été demandé sur ce dépôt. **Ne pas pousser sans instruction explicite.**

---

## 11. Pour reprendre

0. **Si le DNS de `whales-consultancy.biz` est toujours cassé : lire §0.** Tout ce
   qui touche n8n ou Aegis est bloqué ; le générateur peut être vérifié, pas déployé.
1. Lire §0 (incident), §1 (état), §2 (backlog), §3 (périmètre engagé)
2. Lancer les garde-fous hors ligne avant toute modification :
   `node scripts/test-quality-filter.js && node scripts/test-telegram-roundtrip.js`
3. Consulter §6 bis (scripts), §7 (procédures) et §8 (pièges) **avant** toute modification
4. Modifier via `./scripts/deploy-workflows.sh`, qui sauvegarde, pousse **et relit
   l'API** — ne pas faire un `curl` à la main
5. Si une erreur survient : §9, puis `/api/v1/executions/<ID>?includeData=true` — les logs ne mentent pas assez, les nœuds si
6. Après chaque modification : relire **le fichier sur disque**, pousser, puis relire **la réponse n8n**
7. **La boucle de régénération (P0) n'a jamais été exécutée dans n8n** : l'API ne
   lance pas d'exécution (§8.6). Déclencher un *Manual Trigger* depuis l'UI du
   générateur pour la prouver — c'est le seul test qui reste.