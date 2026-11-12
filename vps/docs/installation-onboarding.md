# Installer le cluster et onboarder une application

Huit étapes pour un VPS neuf et une application en production. Les étapes 1 à 5 installent la plateforme une seule
fois ; pour ajouter une application à un cluster existant, reprendre à l'étape 6. Sauf indication contraire, les
commandes se lancent sur le VPS, à la racine de `k3s-stack` après son clonage. Remplacer `my-app` et `my-org`
par le nom du dépôt et de son organisation.

Ne pas désinstaller un cluster existant pour ajouter une application : `uninstall.sh --all` supprime notamment les
bases et leurs sauvegardes locales. Ne jamais transmettre ou publier de secrets en clair.

## 1. Préparer la configuration et le DNS

Faire pointer les domaines publics vers le VPS. Sur un serveur neuf, cloner le dépôt puis
créer le fichier de configuration uniquement s'il n'existe pas :

```bash
git clone https://github.com/DevDeNiro/k3s-stack.git && cd k3s-stack
[ -f vps/config.env ] || cp vps/config.env.example vps/config.env
nano vps/config.env
./vps/scripts/apply-config.sh --check
```

Renseigner `SCM_ORGANIZATIONS`, `REGISTRY_HOST`, `LETSENCRYPT_EMAIL`, `GATEWAY_HOSTNAMES`
(`auth.example.com=security app.example.com=my-app-prod`) et `AUTH_HOSTNAMES`. Pour plusieurs organisations,
laisser `REGISTRY_BASE` vide. Configurer aussi `OFFSITE_BACKUP_REPOSITORY` et `OFFSITE_BACKUP_REGION` pour les
sauvegardes hors site.

## 2. Installer la plateforme

```bash
sudo ./vps/install.sh
```

Le script installe K3s, PostgreSQL, Keycloak, Argo CD, Sealed Secrets, la passerelle et les sauvegardes.

## 3. Autoriser l'accès aux images et aux dépôts

```bash
sudo ./vps/scripts/export-secrets.sh set-registry-credentials
sudo ./vps/scripts/export-secrets.sh set-scm-credentials github
```

Pour GHCR privé, utiliser un jeton GitHub **classique** limité à `read:packages` ; pour les dépôts privés, utiliser
un jeton distinct ayant accès aux organisations. Les saisies sont masquées. Si `KEYCLOAK_EXTENSION_IMAGES` contient
une image privée, relancer ensuite Keycloak avec `sudo ./vps/scripts/apply-keycloak.sh`.

## 4. Installer les certificats et les routes

```bash
sudo ./vps/scripts/setup-gateway-api.sh --staging
```

Après validation de l'émission des certificats de test, passer en production :

```bash
sudo ./vps/scripts/setup-gateway-api.sh
```

Relancer ce dernier script après chaque ajout de domaine dans `GATEWAY_HOSTNAMES`.

## 5. Protéger les sauvegardes

```bash
sudo ./vps/scripts/export-secrets.sh backup-sealing-key
```

Copier le fichier chiffré indiqué hors du VPS et conserver sa phrase de passe séparément. Si le dépôt hors site est
configuré, saisir ses identifiants sans écho et installer la copie chiffrée :

```bash
sudo ./vps/scripts/setup-secrets.sh set-offsite-backup
sudo ./vps/scripts/apply-backups.sh
```

Conserver le mot de passe restic et les clés applicatives hors du VPS : restic sauvegarde les dumps PostgreSQL,
pas ces clés ni la clé Sealed Secrets. Un [exercice de restauration](postgres-backup.md#exercice-de-restauration)
reste indispensable avant toute mise en service réelle.

## 6. Onboarder l'application

Pour un cluster existant, faire pointer le nouveau domaine vers le VPS, ajouter `domaine=my-app-prod` dans
`GATEWAY_HOSTNAMES`, puis relancer `sudo ./vps/scripts/setup-gateway-api.sh`. Si l'organisation est nouvelle,
l'ajouter à `SCM_ORGANIZATIONS`, vérifier que les deux jetons de l'étape 3 permettent d'accéder à ses dépôts et
images, puis relancer `sudo ./vps/scripts/apply-config.sh`. En cas de changement de jeton, suivre la procédure
de rotation de [`../README.md`](../README.md#scriptsexport-secretssh). Le dépôt doit contenir `helm/my-app/` et publier une image
`ghcr.io/my-org/my-app:main-<sha complet>` sur `main`.

```bash
sudo ./vps/scripts/onboard-app.sh my-app --environment prod --organization my-org
```

Le script crée le namespace, la base et son Secret `my-app-db`, l'accès à l'image et l'AppProject Argo CD. Il
conserve le mot de passe de base dans `/root/.k3s-secrets/my-app.env` : le sauvegarder de façon chiffrée hors du VPS,
sans le committer. Utiliser `--skip-database` si l'application n'a pas de base.

## 7. Configurer l'identité et les secrets de l'application

Si nécessaire, ouvrir la console Keycloak depuis le poste avec un tunnel, en remplaçant l'adresse du VPS :

```bash
VPS="ubuntu@vps.example.com"
ssh -t -o ExitOnForwardFailure=yes -L 127.0.0.1:18080:127.0.0.1:18080 "$VPS" \
  'sudo kubectl port-forward -n security svc/keycloak 18080:80 --address 127.0.0.1'
```

Laisser ce terminal ouvert et accéder à [Keycloak](http://localhost:18080/admin/). Configurer le realm et le client,
les URLs de retour, le SMTP et les fournisseurs d'identité selon la documentation de l'application. Exemple :
[Keycloak pour Mon Attaché & Moi](https://github.com/mon-attache-et-moi/mon-attache-et-moi-webapp/blob/main/docs/exploitation/keycloak.md).
Ne jamais recréer un realm existant contenant des comptes.

Sur le VPS, exporter le certificat **public** du cluster :

```bash
mkdir -p -m 700 ~/.k3s-secrets
sudo ./vps/scripts/export-secrets.sh export-cert "$HOME/.k3s-secrets/sealed-secrets-pub.pem"
```

Depuis un autre terminal sur le poste, copier ce certificat :

```bash
VPS="ubuntu@vps.example.com"
mkdir -p ~/.k3s-secrets
scp "$VPS:.k3s-secrets/sealed-secrets-pub.pem" ~/.k3s-secrets/my-app-prod-sealed-secrets-pub.pem
```

Sceller chaque secret applicatif selon le nom, le namespace et la portée prévus par le chart. Exemple pour un Secret
`namespace-wide`, avec saisie sans écho depuis le poste :

```bash
bash -c 'read -r -s -p "Valeur : " VALEUR || exit 1
printf "\n" >&2
printf "%s" "$VALEUR" | kubeseal --raw --scope namespace-wide --namespace my-app-prod \
  --cert "$HOME/.k3s-secrets/my-app-prod-sealed-secrets-pub.pem" --from-file=/dev/stdin'
```

Copier uniquement la valeur chiffrée dans le chart. Pour Mon Attaché & Moi, les sept clés et leur procédure sont
dans [sa documentation de déploiement](https://github.com/mon-attache-et-moi/mon-attache-et-moi-webapp/blob/main/docs/exploitation/deploiement.md#3-secrets-à-sceller).
Le secret PostgreSQL créé à l'étape 6 n'a pas à être recréé.

## 8. Publier, sauvegarder et synchroniser

Publier les valeurs scellées dans le dépôt de l'application et attendre que la CI publie l'image. Dans Argo CD,
comparer la révision Git à `image.tag` : le tag doit être `main-<sha complet>` pour la révision examinée, jamais
simplement `main`. Image Updater peut choisir un autre build disponible ; ne pas synchroniser avant concordance.

Sauvegarder les bases avant la synchronisation :

```bash
JOB="pre-deploy-$(date +%s)"
sudo kubectl create job --from=cronjob/postgres-backup-daily "$JOB" -n storage &&
sudo kubectl wait --for=condition=complete "job/$JOB" -n storage --timeout=15m
sudo kubectl logs -n storage "job/$JOB"
```

Vérifier dans les journaux que chaque base attendue, dont `keycloak`, a été sauvegardée :
un job peut être marqué réussi malgré l'échec du dump d'une base.

Si la copie hors site est configurée, lancer une copie fraîche puis attendre sa fin :

```bash
JOB="offsite-pre-deploy-$(date +%s)"
sudo kubectl create job --from=cronjob/postgres-backup-offsite "$JOB" -n storage &&
sudo kubectl wait --for=condition=complete "job/$JOB" -n storage --timeout=15m
```

La synchronisation de production est **manuelle**. Depuis le poste, ouvrir un tunnel pour Argo CD :

```bash
VPS="ubuntu@vps.example.com"
ssh -t -o ExitOnForwardFailure=yes -L 127.0.0.1:18081:127.0.0.1:18081 "$VPS" \
  'sudo kubectl port-forward -n argocd svc/argocd-server 18081:80 --address 127.0.0.1'
```

Dans [Argo CD](http://localhost:18081), sélectionner `my-app-prod`, contrôler le commit et le tag, puis cliquer
sur **Sync**. L'application devient publiquement accessible si elle démarre. Le parcours de connexion et les
sauvegardes restaurées restent à tester avant d'accueillir des utilisateurs réels.
