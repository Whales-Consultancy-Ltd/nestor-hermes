# Nestor Hermes — Documentation Complète

> ## 📌 Point d'entrée : [`WORKPLAN.md`](WORKPLAN.md)
> Ce document est le **document de reprise** du projet : état vérifié, backlog priorisé,
> procédures opératoires, pièges n8n 2.35.5 et journal d'erreurs.
> Le README ci-dessous décrit l'infrastructure ; **en cas de divergence, WORKPLAN.md fait foi.**

## 📦 déploiement Docker (Phase 0-2)

### Conteneur `nestor-hermes`
- **Emplacement** : `/srv/nestor-hermes` sur le serveur distant `aegis.whales-consultancy.biz` (port SSH 8022)
- **Image** : `ollama/ollama:latest`
- **Modèle principal** : `llama3.2:3b` (2.0 GB, CPU) — utilisé par le workflow, structured outputs activés
- **Modèle de secours** : `nous-hermes2` (6.1 GB) — conservé sur le serveur, non utilisé par le workflow
- **Port exposé** : `127.0.0.1:11434 → 11434/tcp`
- **Réseau** : `nestor_net` (bridge externe `nestor-agent-platform_nestor_net`) + `aegis_proxy` (Traefik external)
- **Volume de persistance** : `hermes_data:/root/.ollama`
- **Hôte** : Aegis, **2 vCPU / 12 Go RAM** — l'inférence CPU est le goulot du système

### Proxy & SSL (Traefik)
- **Domain** : `https://nestor-ai.biz-4-africa.com/hermes`
- **Résolveur Let's Encrypt** : `myresolver` (déjà configuré sur le serveur)
- **Middleware Traefik** : `hermes-strip` (supprime le préfixe `/hermes` avant routage)
- **Statut** : Conteneur créé et démarré (`docker compose up -d`), réponse de santé : `Ollama is running`

### Point d'entrée API
- **Racine** : `https://nestor-ai.biz-4-africa.com/hermes` → `Ollama is running`
- **Génération** : `POST /api/generate` ou `POST /v1/chat/completions` (format OpenAI compatible)
- **Test effectué** : JSON strict avec `hook`, `body`, `call_to_action` validé avec succès

---

## 🤖 Workflows n8n (Phases 1-4)

### Workflow principal : `BIZ4A_Content_Generator`
- **ID** : `ieDcsbIeNFBCtppv`
- **Statut** : ✅ **Actif** (cron 24 h)
- **Emplacement** : Instance n8n `https://n8n.whales-consultancy.biz`
- **Déclencheurs** : Cron toutes les 24 h + Manual Trigger (test)
- **Source de vérité** : `workflow-telegram-approval.json` (ce dépôt) — toute modif passe par un `PUT` API puis relecture
- **Sauvegarde avant refonte** : `~/.config/nestor/backups/workflow-ieDcsbIeNFBCtppv-20261001T132452Z.json`
- **Nœuds** :
  1. **Cron Trigger** — planification quotidienne
  2. **Theme Picker** — rotation thématique (`Actualité OHADA`, `Conseil Gestion PME`, `SuccesStory BIZ4A`, `Innovation Odoo`)
  3. **LLM Request (Ollama)** — `POST https://nestor-ai.biz-4-africa.com/hermes/api/generate`, modèle `llama3.2:3b`, `format` = schéma JSON strict, `num_predict: 400`, `temperature: 0.7`, `timeout: 180000`, `retryOnFail: true` (3 tentatives / 3 s), `onError: continueRegularOutput`
  4. **Parse Content** — normalise la réponse en `hook` / `body` / `call_to_action` (+ `complete`, `total_duration_ms`). Tolère schéma, JSON brut et objet imbriqué ; lève une erreur explicite si la réponse est inexploitable
  5. **Telegram Approval** — envoi du contenu + durée de génération (credential `o2cm9Tyzy89zPU7X`)

**Flux** : Cron | Manual → Theme Picker → LLM Request (Ollama) → Parse Content → Telegram Approval → *(à venir : boutons d'approbation → publication sociale)*

### Latence mesurée (Aegis, 2 vCPU, via le proxy Traefik)
| Modèle | Latence | JSON `hook/body/call_to_action` |
|---|---|---|
| `nous-hermes2` (avant) | 176 s en local, **~450 s en production** (exec #33) | vide / cassé avec `format:json` |
| `llama3.2:3b` (actuel) | **22 – 59 s** (moyenne ~35 s) | ✅ valide — structured outputs garantis par le schéma |

- Gain : **×6 à ×15**.
- ⚠️ `num_predict` ≥ 320 obligatoire : à 180 la génération est **tronquée** et le JSON invalide (observé sur le thème OHADA).
- ⚠️ OpenCode Zen / Go n'est **pas** utilisable comme fournisseur n8n : le free tier renvoie `403 FreeTierError` (« can only be used from within OpenCode ») et les modèles payants `Model access is disabled`.
- ✅ **Qualité (P0, clos le 2026-10-02)** : `llama3.2:3b` s'attribuait la marque et inventait des chiffres. Corrigé par un prompt verrouillé **et** un filtre post-traitement (`complete=false` + bandeau `⚠️ NON CONFORME` dans le message), avec une **boucle de régénération bornée à 3**. Vérifié : **10 générations, 0 occurrence**. Le filtre ne contrôle pas la véracité factuelle — voir WORKPLAN §2.
- ⚠️ Reste ouvert : l'hallucination de faits par un modèle 3b, distincte de P0. Option Phase B' si la qualité reste insuffisante.

### Autres workflows n8n (inventaires)
| Nom | ID | Statut | Note |
|-----|-----|--------|------|
| `BIZ4A - Odoo SSOT to Audience Sheets (Native)` | `u6wWZDU5DrZKZmMH` | ✅ **Actif** | Pipeline principal Odoo → Google Sheets (Audiences + M365 CyberSuite), 2 trigger counts |
| `BIZ4A - Daily Audience Sync (Odoo → Google Sheets)` | `9aPeBMNhBNbb69nS` | ❌ Inactif | Redondant avec le workflow actif — à archiver |
| `BIZ4A - Sync Odoo SSOT to Dedicated Google Ads Audience Sheet` | `uov2tdwYdhALo1iT` | ❌ Inactif | Utilise script Python externe — obsolète |
| `BIZ4A_Content_Generator` | `ieDcsbIeNFBCtppv` | ✅ **Actif** | Génération quotidienne `llama3.2:3b` → Telegram ; filtre P0 + boucle de régénération (10 nœuds) |
| `BIZ4A_Content_Approver` | `8D4pwY4Os56HC1UQ` | ✅ **Actif** | Boutons Approuver / Rejeter / Régénérer, idempotent, publication `publie:false` |

> **Chat Telegram** : écris un message à `@the_hat_trader_bot`, Hermes répond. Un seul webhook par jeton ⇒ le chat est intégré à l'approbateur, qui porte les deux fonctions. Chat `5387896782` uniquement. Détail et preuve : WORKPLAN §4 bis.

### Actions de cleanup effectuées
- ✅ Workflows redondants identifiés et marqués inactifs
- ✅ Pipeline principal préservé et actif
- ✅ Workflow contenu migré de l'approbation email vers Telegram
- ✅ Modèle basculé de `nous-hermes2` (450 s) vers `llama3.2:3b` (35 s) avec structured outputs
- ⚠️ **À faire** : l'e-mail `vincent@biz-4-africa.com` et le nœud *Code Approval Check* décrits dans les versions anteriores de ce document **n'existent plus** dans le workflow live (approbation par Telegram uniquement, sans boucle de décision)

---

## 🔧 Configuration & Réseaux Serveur

### Serveur distant
- **Adresse** : `aegis.whales-consultancy.biz` (SSH port 8022)
- **OS** : Debian GNU/Linux 13 (trixie)
- **Docker** : Instancé via `/srv/nestor-agent-platform` et `/srv/nestor-hermes`
- **Traefik** : Proxy inverse avec `aegis_proxy` network externe, Let's Encrypt `myresolver`

### Réseaux Docker
- `nestor-agent-platform_nestor_net` — Réseau bridge créé par la plateforme Nestor
- `aegis_proxy` — Réseau external géré par Traefik (SSL, routing domaines)

### ⚠️ Incident en cours (2026-10-02 →)

La zone DNS `whales-consultancy.biz` est en **SERVFAIL** (délégation cassée,
constaté via Cloudflare `1.1.1.1` et Google `8.8.8.8`). `n8n.` et `aegis.` sont
injoignables ; `nestor-ai.biz-4-africa.com` (Ollama) répond toujours. Conséquence :
**aucun déploiement n8n, aucun accès SSH** tant que ce n'est pas corrigé.

Les scripts réseau acceptent `N8N_IP=<ip>` pour contourner le DNS en gardant le
SNI/TLS correct. Détail et ordre de reprise : **WORKPLAN.md §0**.

### Credentials & Clés
> ⚠️ **Aucune clé en clair dans ce dépôt.** Le dépôt est public.

| Secret | Stockage | Comment l'obtenir |
|--------|----------|-------------------|
| n8n API Key (JWT) | `~/.config/nestor/secrets.env` — chmod `600`, hors dépôt | `set -a; . ~/.config/nestor/secrets.env; set +a` |
| n8n API Key (rotation) | — | n8n UI → *Settings → n8n API*. Non automatisable : `/api/v1/api-keys` → 404, `/rest/api-keys` → 401 |
| Token Telegram (`@the_hat_trader_bot`) | `~/.config/nestor/secrets.env` — `TELEGRAM_BOT_TOKEN` | n8n vault interne, credential `o2cm9Tyzy89zPU7X`. **L'API publique n'expose pas les credentials** : le token ne peut pas être récupéré par API |
| Token Telegram (credential n8n) | n8n vault interne | ID credential `o2cm9Tyzy89zPU7X` |
| Hermes / Ollama | — | Aucun credential : endpoint HTTPS public via Traefik |

- **Utilisateur n8n** : `Vincent Luba`
- **Durée de vie du JWT n8n** : 30 jours → rotation périodique obligatoire. En service : `jti 3b002510-e74b-47fa-960a-57d44573d919`, **expire le 2026-10-31**. `deploy-workflows.sh` rappelle l'échéance à chaque exécution.
- **Garde-fou** : `scripts/check-secrets.sh` — source **unique** des motifs de détection. Appelé automatiquement par le hook `pre-commit`.
- **Contrôle** : `./scripts/check-secrets.sh` → doit afficher `RESULTAT : OK`
  - Le contrôle **strict** exige un suffixe de ≥ 20 caractères : citer un motif dans la documentation ne déclenche jamais l'alerte.
  - Un préfixe d'en-tête JWT seul n'est **pas** un secret (en-tête standard, présent dans des millions de jetons publics). Seul le motif à haute entropie est une preuve.
- **Vérification de l'historique** : intégrée au script (étape 2/3) — parcourt `git log -p --all`, pas seulement l'arbre de travail.

---

## 🧰 Scripts

| Script | Rôle | Réseau |
|---|---|---|
| `scripts/deploy-workflows.sh` | sauvegarde + `PUT` + relecture + réinscription du webhook | oui |
| `scripts/set-telegram-webhook.sh` | réinscrit le webhook Telegram (`--check` pour vérifier) | oui |
| `scripts/aegis-maintenance.sh` | archivage du doublon, purge des `.bak` (SSH, simulation par défaut) | oui |
| `scripts/set-n8n-key.sh` | valide et installe une clé n8n | oui |
| `scripts/check-secrets.sh` | garde-fou anti-secret | non |
| `scripts/test-quality-filter.js` | 12 cas du filtre P0, lus depuis le workflow | non |
| `scripts/test-telegram-roundtrip.js` | message généré → relu par l'approbateur | non |
| `scripts/verify-p0-quality.js` | 10 générations réelles + filtre déployé | Ollama |

Toujours passer par `deploy-workflows.sh` plutôt qu'un `curl` manuel : il
sauvegarde avant, relit l'API après, et préserve le `webhookId` distant.

## 📋 Workplan Officiel (Résumé)

| Phase | Titre | Statut | Prochaine étape |
|-------|-------|--------|-----------------|
| 0 | Vérification infrastructure | ✅ Terminé | — |
| 1 | Workflow n8n | ✅ Terminé | Workflow live `ieDcsbIeNFBCtppv` |
| 2 | Chaîne LLM | ✅ Terminé | `llama3.2:3b` + structured outputs, 22-59 s |
| 3 | Sécurité dépôt | ✅ Terminé | Rotation du JWT n8n **à faire par l'utilisateur** (échéance **2026-10-31**) |
| 4 | Approbation Telegram | ✅ Terminé | Boutons + décision + idempotence, prouvés par l'exécution **#48**. Compteur de publications et trace de la qualité ajoutés (P2, non déployé) |
| 5 | Publication réseaux sociaux | ⏳ Non démarré | Nœuds LinkedIn / X / FB / IG, après Phase 4 |
| 6 | Scheduler en production | ✅ Actif | Cron 24 h. ⚠️ Un cron modifié par `PUT` ne se redéclenche pas (WORKPLAN §8.6) |
| 7 | Boucle analytics | ⏳ Planifié | Après 10 posts publiés |

## ⚙️ Étapes suivantes

### Immédiat (bloquant)
1. **Rétablir le DNS de `whales-consultancy.biz`** (SERVFAIL). Tout déploiement n8n et tout accès SSH en dépendent.
2. **Rotation du JWT n8n** — n8n UI → *Settings → n8n API* → créer une clé, révoquer celle dont le `jti` est `3b002510-e74b-47fa-960a-57d44573d919`. Expiration **2026-10-31T04:00Z**. Puis `./scripts/set-n8n-key.sh '<clé>'`.
3. **Renseigner `TELEGRAM_BOT_TOKEN`** dans `~/.config/nestor/secrets.env`, puis `./scripts/set-telegram-webhook.sh`.
4. **Déployer** : `./scripts/deploy-workflows.sh` (P2 + boucle de régénération sont écrits et testés, pas en base).
5. **Déclencher un test manuel** : n8n UI → `BIZ4A_Content_Generator` → *Execute Workflow*. L'API publique n'expose aucun déclenchement (`POST /api/v1/workflows/{id}/run|execute|trigger` → **405**). C'est le **seul test qui reste** pour prouver la boucle de régénération.
6. **Purge P4** : `./scripts/aegis-maintenance.sh archive-dup --apply` puis `clean-backups --apply`.

### Phase 5 — Publication sociale
7. Nœuds LinkedIn / X / Facebook / Instagram avec les credentials OAuth2 existants dans n8n, branchés **après** `Enregistrer Publication`, avec idempotence anti-double-post.
8. Ne publier qu'après approbation explicite **et** validation de la qualité par le porteur de projet.

### Optionnel — B' (qualité)
9. Si la qualité de `llama3.2:3b` reste insuffisante : brancher un **provider cloud** en primaire avec `llama3.2:3b` en repli. Nécessite une clé valide. OpenCode Zen/Go est **exclu** (voir section Latence).

---
*Dernière mise à jour : 2026-10-03. Toute modification du déploiement suit un mode séquentiel : validation des étapes précédentes avant toute action suivante. Détail complet et procedures : **WORKPLAN.md**.*