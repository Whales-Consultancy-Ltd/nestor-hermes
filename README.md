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
- ⚠️ Qualité : `llama3.2:3b` reste générique et ne suit pas les consignes négatives du prompt. En cas d'insatisfaction → bascule vers un provider cloud (Phase B').

### Autres workflows n8n (inventaires)
| Nom | ID | Statut | Note |
|-----|-----|--------|------|
| `BIZ4A - Odoo SSOT to Audience Sheets (Native)` | `u6wWZDU5DrZKZmMH` | ✅ **Actif** | Pipeline principal Odoo → Google Sheets (Audiences + M365 CyberSuite), 2 trigger counts |
| `BIZ4A - Daily Audience Sync (Odoo → Google Sheets)` | `9aPeBMNhBNbb69nS` | ❌ Inactif | Redondant avec le workflow actif — à archiver |
| `BIZ4A - Sync Odoo SSOT to Dedicated Google Ads Audience Sheet` | `uov2tdwYdhALo1iT` | ❌ Inactif | Utilise script Python externe — obsolète |
| `BIZ4A_Content_Generator` | `ieDcsbIeNFBCtppv` | ✅ **Actif** | Génération quotidienne `llama3.2:3b` → Telegram ; à enrichir de nœuds sociaux |

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

### Credentials & Clés
> ⚠️ **Aucune clé en clair dans ce dépôt.** Le dépôt est public.

| Secret | Stockage | Comment l'obtenir |
|--------|----------|-------------------|
| n8n API Key (JWT) | `~/.config/nestor/secrets.env` — chmod `600`, hors dépôt | `set -a; . ~/.config/nestor/secrets.env; set +a` |
| n8n API Key (rotation) | — | n8n UI → *Settings → n8n API*. Non automatisable : `/api/v1/api-keys` → 404, `/rest/api-keys` → 401 |
| Token Telegram / credential n8n | n8n vault interne | ID credential `o2cm9Tyzy89zPU7X` |
| Hermes / Ollama | — | Aucun credential : endpoint HTTPS public via Traefik |

- **Utilisateur n8n** : `Vincent Luba`
- **Durée de vie du JWT n8n** : 30 jours (`exp = iat + 2 559 122 s`) → rotation périodique obligatoire
- **Garde-fou** : `scripts/check-secrets.sh` — source **unique** des motifs de détection. Appelé automatiquement par le hook `pre-commit`.
- **Contrôle** : `./scripts/check-secrets.sh` → doit afficher `RESULTAT : OK`
  - Le contrôle **strict** exige un suffixe de ≥ 20 caractères : citer un motif dans la documentation ne déclenche jamais l'alerte.
  - Un préfixe d'en-tête JWT seul n'est **pas** un secret (en-tête standard, présent dans des millions de jetons publics). Seul le motif à haute entropie est une preuve.
- **Vérification de l'historique** : intégrée au script (étape 2/3) — parcourt `git log -p --all`, pas seulement l'arbre de travail.

---

## 📋 Workplan Officiel (Résumé)

| Phase | Titre | Statut | Prochaine étape |
|-------|-------|--------|-----------------|
| 0 | Vérification infrastructure | ✅ Terminé | — |
| 1 | Workflow n8n | ✅ Terminé | Workflow live `ieDcsbIeNFBCtppv` |
| 2 | Chaîne LLM | ✅ Terminé | `llama3.2:3b` + structured outputs, 22-59 s |
| 3 | Sécurité dépôt | ✅ Terminé | Rotation du JWT n8n **à faire par l'utilisateur** (échéance 2026-10-29) |
| 4 | Approbation Telegram | 🟡 Partiel | Aujourd'hui : notification seule. Manque les **boutons** et la **boucle de décision** |
| 5 | Publication réseaux sociaux | ⏳ Non démarré | Nœuds LinkedIn / X / FB / IG, après Phase 4 |
| 6 | Scheduler en production | ✅ Actif | Cron 24 h — surveiller 2 exécutions avant de consideredorsécurisé |
| 7 | Boucle analytics | ⏳ Planifié | Après 10 posts publiés |

## ⚙️ Étapes suivantes

### Immédiat (bloquant)
1. **Rotation du JWT n8n** — n8n UI → *Settings → n8n API* → créer une clé, révoquer celle dont le `jti` est `814c620c-4268-4754-a467-ab2973e18bdf`. Expiration **2026-10-29T04:00Z**. Puis mettre à jour `~/.config/nestor/secrets.env`.
2. **Déclencher un test manuel** : n8n UI → `BIZ4A_Content_Generator` → *Execute Workflow*. L'API publique n'expose aucun déclenchement (`POST /api/v1/workflows/{id}/run|execute|trigger` → **405**).

### Phase 4 — Approbation réelle
3. Remplacer l'envoi Telegram par un **inline keyboard** (Approuver / Rejeter / Régénérer) + nœud d'attente de réponse.
4. Parser la décision et router vers la publication **ou** un retour `Theme Picker`.
5. Rendre la publication **idempotente** (anti double-post) et journaliser chaque approbation.

### Phase 5 — Publication sociale
6. Nœuds LinkedIn / X / Facebook / Instagram avec les credentials OAuth2 existants dans n8n.
7. Ne publier qu'après approbation explicite.

### Optionnel — B' (qualité)
8. Si la qualité de `llama3.2:3b` est jugée insuffisante : brancher un **provider cloud** en primaire avec `llama3.2:3b` en repli. Nécessite une clé valide. OpenCode Zen/Go est **exclu** (voir section Latence).

---
*Dernière mise à jour : 2026-10-01. Toute modification du déploiement suit un mode séquentiel : validation des étapes précédentes avant toute action suivante.*