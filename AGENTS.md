# Conventions de travail partagé — `nestor-hermes`

Ce dépôt est édité **par plusieurs agents en parallèle** (sessions opencode concurrentes,
agents Aegis). Les règles ci-dessous existent parce qu'un travail a déjà été perdu par
écrasement.

## 1. Avant toute écriture

```bash
git fetch origin && git status -sb
```

Ne jamais écrire à l'aveugle sur `origin/main`. Un `git pull --rebase` avant de commencer
évite 90 % des conflits.

## 2. Un seul auteur par section à la fois

`WORKPLAN.md` est le fichier partagé par excellence. Règle :

- **relire la section qu'on va modifier immédiatement avant** de l'éditer ;
- **ne pas reformater, réordonner ni « ranger » une section qui ne nous appartient pas** ;
- si une section est modifiée par quelqu'un d'autre pendant qu'on travaille, on relit le
  diff avant de committer, et on ne force pas.

## 3. Commits

- Un commit = une intention. Ne jamais mélanger « tidy » et « contenu ».
- Toujours `git fetch && git log --oneline -5` avant de commiter : on ne réécrit pas
  l'historique d'autrui.
- Ne pas `git rebase` / `git commit --amend` sur un commit déjà poussé par une autre session.
- Ne pas toucher aux `.bak` ni aux fichiers de coffre, même pour « nettoyer ».

## 4. Secrets

Aucun token, clé ou `.env` dans ce dépôt, **y compris dans WORKPLAN.md**.
`scripts/check-secrets.sh` doit passer avant chaque push.
Si un secret a été écrit par erreur : le révoquer d'abord, puis nettoyer l'historique.

## 5. Vocabulaire (depuis le 2026-10-03, voir WORKPLAN § 4 ter)

| À écrire | Ne pas écrire |
|---|---|
| **Nestor Agent v1.0.0** (l'agent) | « Hermes » |
| **Ollama BIZ4A** (le serveur de modèles) | « Hermes », « le modèle » |
| **modèle nous-hermes2** (les poids) | « Hermes » |

Le terme « Hermes » désigne historiquement **deux produits sans rapport** : le modèle
`nous-hermes2` servi par Ollama, et l'agent Hermes Agent de Nous Research. Chaque mention
doit être non ambiguë.

Corollaire : le chemin `~/.hermes/`, le binaire `hermes` et la variable `HERMES_HOME` sont des
**artifacts amont**, non renommables sans casser `hermes update`. On ne les touche pas.

## 6. Vérifier avant d'affirmer

Ne jamais écrire « c'est fait », « ça fonctionne » ou « le produit n'existe pas » sans
commande de preuve dans le même commit. Exemples de preuves attendues :

```bash
hermes -z "reponds PONG"      # inférence réelle, pas juste doctor
git show origin/main:fichier | grep -c '^<<<<<<<'   # état réel de la SSOT
ssh aegis ... <commande>       # l'hôte distant, pas une supposition
```

Un `which` vide ne prouve pas une absence : l'install de Nestor Agent v1.0.0 télécharge ~500 Mo
et crée son environnement **avant** de publier le binaire.