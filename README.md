# Nestor Hermes — Documentation Complète

## 📦 déploiement Docker (Phase 0-2)

### Conteneur `nestor-hermes`
- **Emplacement** : `/srv/nestor-hermes` sur le serveur distant `aegis.whales-consultancy.biz` (port SSH 8022)
- **Image** : `ollama/ollama:latest`
- **Modèle** : `nous-hermes2` (6.1 GB, CPU-only optimisé)
- **Port exposé** : `127.0.0.1:11434 → 11434/tcp`
- **Réseau** : `nestor_net` (bridge externe `nestor-agent-platform_nestor_net`) + `aegis_proxy` (Traefik external)
- **Volume de persistance** : `hermes_data:/root/.ollama`

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
- **Statut** : Inactif (mode brouillon) — prêt à activation
- **Emplacement** : Instance n8n `https://n8n.whales-consultancy.biz`
- **Déclencheur** : Cron toutes les 24h
- **Nœuds** :
  1. **Cron Trigger** — Planification quotidienne
  2. **Theme Picker** — Rotation thématique (`Actualité OHADA`, `Conseil Gestion PME`, `SuccesStory BIZ4A`, `Innovation Odoo`)
  3. **Hermes LLM Request** — `POST https://nestor-ai.biz-4-africa.com/hermes/api/generate` avec modèle `nous-hermes2`
  4. **Email Approval** — Envoi à `vincent@biz-4-africa.com` pour validation humaine
  5. **Code Approval Check** — Vérifie que la réponse email contient "Approuver" / "Approve"

**Flux** : Cron → Theme Picker → Hermes → Email → Validation → ( prochainement : nœuds réseaux sociaux )

### Autres workflows n8n (inventaires)
| Nom | ID | Statut | Note |
|-----|-----|--------|------|
| `BIZ4A - Odoo SSOT to Audience Sheets (Native)` | `u6wWZDU5DrZKZmMH` | ✅ **Actif** | Pipeline principal Odoo → Google Sheets (Audiences + M365 CyberSuite), 2 trigger counts |
| `BIZ4A - Daily Audience Sync (Odoo → Google Sheets)` | `9aPeBMNhBNbb69nS` | ❌ Inactif | Redondant avec le workflow actif — à archiver |
| `BIZ4A - Sync Odoo SSOT to Dedicated Google Ads Audience Sheet` | `uov2tdwYdhALo1iT` | ❌ Inactif | Utilise script Python externe — obsolète |
| `BIZ4A_Content_Generator` | `ieDcsbIeNFBCtppv` | ❌ Inactif (brouillon) | Nouveau workflow contenu — prêt à enrichir de nœuds sociaux |

### Actions de cleanup effectuées
- ✅ Workflows redondants identifiés et marqués inactifs
- ✅ Pipeline principal préservé et actif
- ✅ Workflow contenu importé avec étape d'approbation email

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
- **Garde-fou** : hook `pre-commit` `.git/hooks/pre-commit` refuse tout fichier stagé contenant `eyJhbGci`, `sk-`, `oc_sk_`, `gho_`, `ghp_`, `xox*`
- **Vérification** : `git log -p --all | grep -c 'eyJhbGci'` doit rester `0`

---

## 📋 Workplan Officiel (Résumé)

| Phase | Titre | Statut | Prochaine étape |
|-------|-------|--------|-----------------|
| 0 | Vérification infrastructure | ✅ Terminé | — |
| 1 | Workflow n8n draft | ✅ Terminé | Import sous compte utilisateur |
| 2 | Test chaîne Hermes | ✅ Terminé | Réponse JSON validée |
| 3 | Système approbation | ✅ Terminé | Intégré dans workflow (email) |
| 4 | Connexion réseaux sociaux | 🟡 En cours | Ajouter nœuds LinkedIn/X/IG via UI n8n |
| 5 | Activation scheduler | ⏳ En attente | Validation utilisateur sur workflow complet |
| 6 | Boucle analytics | ⏳ Planifié | Après 2 semaines de données |

---

## ⚙️ Étapes suivantes (Phase 4-5)

1. **Dans n8n UI** : enrichir `BIZ4A_Content_Generator` avec les nœuds de publication sociale (LinkedIn, X/Twitter, Facebook, Instagram) en utilisant les credentials OAuth2 déjà configurés.
2. **Tester** le cycle complet : Cron → Hermes → Email approval → Réponse "Approuver" → Publication réseaux.
3. **Valider** l'activation en production du scheduler (Phase 5) suite au premier déclenchement et validation des 2 premiers jours.
4. **Planifier** la boucle analytics (Phase 6) après collecte de minimum 10 posts publiés.

---
*Documentation générée le $(date +%Y-%m-%d). Pour toute modification du déploiement, respecter le mode séquentiel : validation étapes précédentes avant toute action suivante.*