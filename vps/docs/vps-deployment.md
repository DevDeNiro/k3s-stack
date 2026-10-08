# Guide de Déploiement VPS (Production & Staging)

Ce guide est la référence canonique unique pour déployer et opérer l'infrastructure Kubernetes K3s sur VPS, ainsi que les applications associées (`coterie-webapp`).

---

## 📋 Architecture Résumée

| Composant | Technologie | Namespace | Rôle |
| :--- | :--- | :--- | :--- |
| **Runtime** | K3s `v1.29.0+k3s1` mono-nœud | - | Moteur Kubernetes allégé (~500MB) |
| **Routing / Ingress** | Gateway API v1.2.0 + NGINX Gateway Fabric 2.4.1 | `nginx-gateway` | Point d'entrée HTTP (80) & HTTPS (443) mutualisé |
| **TLS / Certificats** | Cert-Manager (Let's Encrypt HTTP-01) | `cert-manager` | Certificats automatiques par sous-domaine |
| **Base de Données** | PostgreSQL (Bitnami) | `storage` | Instance mutualisée avec bases & users logiques dédiés |
| **Cache & Sessions** | Redis | `database` | Rate-limiting & cache session |
| **IAM / Auth** | Keycloak | `security` | Multi-realms (`coterie-alpha`, `coterie-prod`) |
| **GitOps** | Argo CD + Image Updater | `argocd` | Déploiement continu automatisé depuis Git |
| **Secrets Chiffrés** | Sealed Secrets | `kube-system` | Déchiffrement in-cluster des secrets versionnés |
| **Observabilité** | Prometheus + Loki + Grafana | `monitoring` | Métriques, alertes et logs centralisés |

---

## 🚀 Étape 1 : Installation du Cluster sur le VPS

### 1.1 Cloner et préparer la configuration
Connectez-vous au VPS :
```bash
ssh ubuntu@<VPS_IP>
cd /home/ubuntu
git clone https://github.com/DevDeNiro/k3s-stack.git && cd k3s-stack

# Éditer config.env avec votre domaine et emails
cp vps/config.env.example vps/config.env
nano vps/config.env
```

Variables obligatoires dans `vps/config.env` :
- `DOMAIN="macoterie.fr"`
- `LETSENCRYPT_EMAIL="admin@macoterie.fr"`
- `SCM_PROVIDER="github"`
- `SCM_ORGANIZATION="coterie-app"`
- `REGISTRY_BASE="ghcr.io/coterie-app"`

### 1.2 Lancer le script d'installation
```bash
chmod +x vps/install.sh
sudo ./vps/install.sh
```

Ce script déploie les briques d'infrastructure, génère les mots de passe sécurisés dans `/root/.k3s-secrets/credentials.env`, installe Gateway API, PostgreSQL, Redis, Keycloak, Prometheus, Grafana, Loki et ArgoCD.

---

## 🔒 Étape 2 : Configuration TLS & Gateway API

### 2.1 Configurer Cert-Manager (Let's Encrypt)
```bash
sudo ./vps/scripts/setup-cert-manager.sh --email admin@macoterie.fr
```

### 2.2 Déployer l'Infrastructure Gateway
```bash
sudo ./vps/scripts/setup-gateway-api.sh --domain macoterie.fr
```

### 2.3 Résolution interne (Hairpin NAT CoreDNS)
Permet aux pods internes de contacter `auth.macoterie.fr` sans sortir sur Internet :
```bash
sudo ./vps/scripts/setup-coredns-hosts.sh --domain macoterie.fr
```

---

## 🔑 Étape 3 : Token SCM pour ArgoCD (GitOps)

Pour qu'ArgoCD puisse lire vos dépôts privés (GitHub / GitLab) :
```bash
sudo ./vps/scripts/export-secrets.sh set-scm-credentials github
```
Renseignez votre organisation et un Personal Access Token (PAT) avec droits `repo`.

---

## 📦 Étape 4 : Onboarding d'une Application

Le script d'onboarding crée les namespaces, bases de données logiques, users PostgreSQL et secrets de base :

```bash
sudo ./vps/scripts/onboard-app.sh coterie-webapp
```

Ce script génère automatiquement :
- Les namespaces `coterie-webapp-alpha` et `coterie-webapp-prod` avec ResourceQuotas.
- Les bases PostgreSQL `coterie-webapp-alpha` et `coterie-webapp-prod` dans l'instance partagée `storage`.
- Les certificats Let's Encrypt et listeners HTTPS sur le Gateway (`alpha.macoterie.fr` et `app.macoterie.fr`).
- Les identifiants sauvegardés dans `/root/.k3s-secrets/coterie-webapp.env`.

---

## 🔐 Étape 5 : Chiffrement Sealed Secrets (Poste Développeur)

Les mots de passe de production ne doivent jamais être commis en clair. On utilise la clé publique du cluster pour sceller les secrets :

1. **Récupérer la clé publique du cluster VPS :**
   ```bash
   sudo ./vps/scripts/export-secrets.sh export-cert /tmp/sealed-secrets-pub.pem
   # Sur votre laptop :
   scp ubuntu@<VPS_IP>:/tmp/sealed-secrets-pub.pem local/secrets/sealed-secrets-pub.pem
   ```

2. **Générer les SealedSecrets pour chaque environnement :**
   Dans le dépôt de l'application (`coterie-webapp`), utilisez le script dédié :
   ```bash
   # Alpha / Staging
   ./scripts/seal-secrets.sh all coterie-webapp-alpha --cert local/secrets/sealed-secrets-pub.pem
   # Copier les valeurs chiffrées dans helm/coterie-webapp/values-alpha.yaml

   # Production
   ./scripts/seal-secrets.sh all coterie-webapp-prod --cert local/secrets/sealed-secrets-pub.pem
   # Copier les valeurs chiffrées dans helm/coterie-webapp/values-prod.yaml
   ```

3. **Nommage explicite des secrets :**
   - `coterie-alpha-db` dans `values-alpha.yaml`
   - `coterie-prod-db` dans `values-prod.yaml`
   - `keycloak-client` dans les deux environnements

---

## 👥 Étape 6 : Stratégie IAM & Données (Zéro Onboarding en Alpha)

### Environnement Alpha / Staging (`alpha.macoterie.fr`)
- **Base de données** : Le profil `alpha` exécute automatiquement `DataSeeder.kt` au premier démarrage pour peupler la fausse résidence démo, le syndic, le manager et les résidents.
- **Keycloak** : Le realm `coterie-alpha` dispose des 4 comptes de test pré-validés (`emailVerified: true`, mot de passe: `admin123`) :
  - `admin@coterie.localhost` (Super Admin)
  - `syndic@coterie.localhost` (Org Admin / Cabinet Les Lilas)
  - `manager@coterie.localhost` (Gestionnaire)
  - `resident@coterie.localhost` (Résident)
  👉 **Connexion immédiate sans aucun onboarding manuel.**

### Environnement Production (`macoterie.fr` / `app.macoterie.fr`)
- `DataSeeder` est **désactivé** (`SPRING_PROFILES_ACTIVE=prod`).
- Le realm `coterie-prod` ne contient aucun faux compte. Seuls les vrais clients s'y inscrivent via le flux d'onboarding officiel.

---

## 🛠️ Commandes Utiles & Maintenance

### Diagnostic rapide du cluster
```bash
# Vérifier tous les pods
sudo kubectl get pods -A

# Voir l'état de synchronisation ArgoCD
sudo kubectl get applications -n argocd

# Statut des routes Gateway API
sudo kubectl get httproutes -A

# Statut des certificats Let's Encrypt
sudo kubectl get certificates -A
```

### Rotation des mots de passe
```bash
sudo ./vps/scripts/setup-secrets.sh rotate
```

### Désinstallation propre
```bash
# Suppression des releases et données applicatives (garde K3s)
sudo ./vps/uninstall.sh

# Suppression intégrale du cluster K3s
sudo ./vps/uninstall.sh --all
```

---

## 🔄 ArgoCD Auto-Discovery

L'installation configure automatiquement l'auto-découverte des applications via ApplicationSets :
1. ArgoCD scanne votre organisation GitHub/GitLab.
2. Les dépôts contenant un dossier `helm/` sont détectés automatiquement.
3. Deux Applications sont créées par dépôt détecté : `<repo>-alpha` (branche `develop`) et `<repo>-prod` (branche `main`).

### Prérequis pour un repo

Structure attendue :

```
<repo>/
  helm/
    <repo>/
      Chart.yaml
      values.yaml
      values-alpha.yaml
      values-prod.yaml
      templates/
```

### Vérification

```bash
# Voir les ApplicationSets
kubectl get applicationsets -n argocd

# Voir les Applications générées
kubectl get applications -n argocd

# Logs du controller
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller --tail=50
```

### Problèmes fréquents

**"generated 0 applications"** :

- Vérifier que le dossier `helm/` existe dans le repo
- Le token SCM doit avoir accès au repo (scope `repo` ou `Contents: read`)
- Le filtre utilise `pathsExist: ["helm"]` (les globs ne sont PAS supportés)

**"Secret scm-token not found"** :

```bash
sudo ./vps/scripts/export-secrets.sh set-scm-credentials github
```

**"Unable to resolve issuer" / "Connection refused" sur Keycloak** :
Le hairpin NAT empêche les pods d'atteindre `auth.<domain>` via l'IP externe.
Cela est résolu automatiquement par `configure_coredns_internal_hosts()` dans install.sh.

Si nécessaire, vérifier CoreDNS :

```bash
kubectl get configmap coredns -n kube-system -o yaml | grep NodeHosts -A5
```

---

## Troubleshooting

### K3s ne démarre pas

```bash
systemctl status k3s
journalctl -u k3s --no-pager | tail -50
```

### Certificat TLS non émis

```bash
kubectl get certificates -A
kubectl describe certificate <name> -n <namespace>
kubectl logs -n cert-manager deploy/cert-manager
```

### Gateway API issues

```bash
# État du Gateway et listeners
kubectl get gateways -n nginx-gateway
kubectl describe gateway infrastructure-gateway -n nginx-gateway

# HTTPRoutes
kubectl get httproutes -A

# Pods NGINX (data plane)
kubectl get pods -n nginx-gateway
kubectl logs -n nginx-gateway -l app.kubernetes.io/name=nginx-gateway-fabric
```

### Certificat bloqué en Pending

```bash
# Vérifier l'état
kubectl get certificates -n nginx-gateway
kubectl describe certificate <name> -n nginx-gateway

# Vérifier les challenges HTTP-01
kubectl get challenges -A
kubectl describe challenge <name> -n nginx-gateway

# Logs cert-manager
kubectl logs -n cert-manager deploy/cert-manager --tail=50
```

> **Cause fréquente** : DNS pas encore propagé ou port 80 bloqué.

---

## Documentation complémentaire

- [Architecture & Concepts](architecture.md) - Séparation alpha/prod, tagging, migrations
- [Database Admin](database-admin.md) - Administration PostgreSQL
- [Commands Cheatsheet](commands-cheatsheet.md) - Commandes kubectl/helm utiles
