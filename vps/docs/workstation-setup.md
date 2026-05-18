# Workstation Setup

How to connect a personal workstation (macOS or Windows) to the K3s VPS so you
can use `kubectl`, `k9s`, `helm` and `stern` without SSHing in for every command.

End state:
- Passwordless SSH to `coterie-vps`
- Local `~/.kube/config` pointing at the VPS (`https://137.74.114.206:6443`)
- `kubectl get nodes` works from your terminal
- `k9s` opens a TUI dashboard on the live cluster

## Prerequisites

| Tool | macOS | Windows |
|------|-------|---------|
| `ssh` / `ssh-keygen` | built-in | built-in (OpenSSH on Win10+) |
| `kubectl` | `brew install kubectl` | bundled with Docker Desktop, or `winget install Kubernetes.kubectl` |
| `k9s` | `brew install k9s` | `winget install Derailed.k9s` |
| `helm` (optional) | `brew install helm` | `winget install Helm.Helm` |
| `stern` (optional, multi-pod log tail) | `brew install stern` | `winget install stern.stern` |

## Step 1 — SSH key + passwordless access

### 1.a Generate a key (if you don't already have one)

```bash
# macOS / Linux
ssh-keygen -t ed25519 -C "$USER-coterie-vps-$(date +%Y%m%d)" -f ~/.ssh/coterie_vps_ed25519 -N ""
```

```powershell
# Windows / PowerShell
ssh-keygen -t ed25519 -C "$env:USERNAME-coterie-vps-$(Get-Date -Format yyyyMMdd)" -f "$env:USERPROFILE\.ssh\coterie_vps_ed25519" -N '""'
```

### 1.b Install the public key on the VPS (one-time, password required)

```bash
# macOS / Linux
cat ~/.ssh/coterie_vps_ed25519.pub | ssh ubuntu@137.74.114.206 \
    'mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
     grep -qxF "$(cat)" ~/.ssh/authorized_keys 2>/dev/null || \
     tee -a ~/.ssh/authorized_keys >/dev/null && \
     chmod 600 ~/.ssh/authorized_keys && echo KEY_INSTALLED'
```

```powershell
# Windows / PowerShell
$pubkey = (Get-Content "$env:USERPROFILE\.ssh\coterie_vps_ed25519.pub" -Raw).Trim()
ssh -o StrictHostKeyChecking=accept-new ubuntu@137.74.114.206 `
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qxF '$pubkey' ~/.ssh/authorized_keys 2>/dev/null || echo '$pubkey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo KEY_INSTALLED"
```

### 1.c Add a host alias in `~/.ssh/config`

This lets you type `ssh coterie-vps` instead of the long form.

```text
# ~/.ssh/config  (macOS, Linux)
# %USERPROFILE%\.ssh\config  (Windows)

Host coterie-vps
    HostName 137.74.114.206
    User ubuntu
    IdentityFile ~/.ssh/coterie_vps_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 5
```

> Windows note: replace `~/.ssh/coterie_vps_ed25519` with the full path
> `C:\Users\<you>\.ssh\coterie_vps_ed25519` if the tilde does not expand.

Test: `ssh coterie-vps "hostname && whoami"` should print `vps-278732ad ubuntu`
without prompting for a password.

## Step 2 — Local kubeconfig pointing at the VPS

The k3s kubeconfig at `/etc/rancher/k3s/k3s.yaml` references `127.0.0.1:6443`.
We need to rewrite that to the public IP and save it locally.

### macOS / Linux

```bash
mkdir -p ~/.kube
# Backup any existing config
[ -f ~/.kube/config ] && cp ~/.kube/config ~/.kube/config.backup-$(date +%Y%m%d%H%M%S)

# Fetch, rewrite, save
ssh coterie-vps "sudo cat /etc/rancher/k3s/k3s.yaml" \
    | sed 's#127\.0\.0\.1#137.74.114.206#' \
    > ~/.kube/config

chmod 600 ~/.kube/config

# Test
kubectl get nodes
```

### Windows / PowerShell

```powershell
$kubeDir = "$env:USERPROFILE\.kube"
if (-not (Test-Path $kubeDir)) { New-Item -ItemType Directory -Path $kubeDir | Out-Null }
$kubeconfigPath = "$kubeDir\config"

if (Test-Path $kubeconfigPath) {
    Copy-Item $kubeconfigPath "$kubeconfigPath.backup-$(Get-Date -Format yyyyMMddHHmmss)"
}

$config = (ssh coterie-vps "sudo cat /etc/rancher/k3s/k3s.yaml") -replace '127\.0\.0\.1', '137.74.114.206'
[System.IO.File]::WriteAllText(
    $kubeconfigPath,
    (($config -join "`n") + "`n"),
    (New-Object System.Text.UTF8Encoding $false)
)

# Lock down ACL to current user only
icacls $kubeconfigPath /inheritance:r /grant:r "${env:USERNAME}:(R,W)" | Out-Null

# Test
kubectl get nodes
```

Expected output:

```text
NAME           STATUS   ROLES                  AGE   VERSION
vps-278732ad   Ready    control-plane,master   88d   v1.29.0+k3s1
```

## Step 3 — Launch k9s

```bash
k9s
```

k9s opens in the `default` namespace which is empty. Useful commands inside:

| Key / command | Effect |
|---------------|--------|
| `0` | Show pods of **all namespaces** (best landing view) |
| `:ns` | Interactive namespace picker |
| `:ns coterie-webapp-alpha` | Jump to alpha namespace |
| `:pods`, `:deploy`, `:svc`, `:rs`, `:httproute` | Switch resource type |
| `:applications` | View ArgoCD Applications |
| `:events` | All events sorted by time |
| `/<text>` | Filter visible list by substring |
| `l` | Logs of selected pod (`f` toggles follow) |
| `d` | Describe |
| `s` | Shell into the container |
| `Ctrl-D` | Delete the resource |
| `Shift-R` | Sort by restart count |
| `Shift-M` | Sort by memory |
| `?` | Contextual help |
| `:q` / `Ctrl-C` | Quit |

## Step 4 (optional) — Bash / PowerShell aliases

Add these to your `~/.zshrc` / `~/.bashrc` / `$PROFILE` for fast checks.

### macOS / Linux

```bash
alias k=kubectl
alias kgpa='kubectl get pods -A'
alias kga='kubectl get applications -n argocd'
alias klf='kubectl logs -f'
alias kctx='kubectl config use-context'
alias kn='kubectl config set-context --current --namespace'
```

### Windows / PowerShell

```powershell
function Show-CoterieStatus {
    Write-Host "=== Cluster ===" -ForegroundColor Cyan
    kubectl get pods -A | Select-String -NotMatch 'Running|Completed'
    Write-Host "`n=== ArgoCD apps ===" -ForegroundColor Cyan
    kubectl get applications -n argocd
    Write-Host "`n=== Top nodes ===" -ForegroundColor Cyan
    kubectl top nodes
}
Set-Alias k kubectl
Set-Alias kgpa "kubectl get pods -A"   # static alias variant
```

## Step 5 (optional) — Multi-cluster

If you later add a second cluster (e.g. local k3d):

```bash
# macOS / Linux
export KUBECONFIG=~/.kube/config:~/.kube/k3d-local.config
kubectl config get-contexts
kubectl config use-context <name>
```

```powershell
# Windows
$env:KUBECONFIG = "$env:USERPROFILE\.kube\config;$env:USERPROFILE\.kube\k3d-local.config"
kubectl config get-contexts
kubectl config use-context <name>
```

Inside k9s, you can switch with `:ctx`.

## Troubleshooting

### `Unable to connect to the server: dial tcp 137.74.114.206:6443: i/o timeout`

The VPS firewall blocks 6443. SSH in and open it:

```bash
ssh coterie-vps "sudo ufw allow 6443/tcp && sudo ufw reload"
```

### `error: You must be logged in to the server (Unauthorized)`

The kubeconfig client certificate has expired (rare — k3s renews on its own,
but if the VPS clock was very wrong it can happen). Re-run Step 2.

### `kubeconfig: ... permission denied` on macOS/Linux

```bash
chmod 600 ~/.kube/config
```

### k9s shows `No resources found for v1/pods in "default" namespace`

Normal — your apps live in other namespaces. Press `0` to view all, or
`:ns coterie-webapp-alpha` to jump to a specific one.

### Want to disable password auth on the VPS now that keys work

```bash
ssh coterie-vps -t \
    "sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
     sudo systemctl reload sshd && echo DONE"
```

## Security checklist

- [ ] SSH key has a passphrase (re-generate without `-N ""` if you skipped it)
- [ ] Add the key to `ssh-agent` to avoid retyping the passphrase (`ssh-add`)
- [ ] `~/.kube/config` is mode 600 / Windows ACL restricted to your user
- [ ] Original VPS password rotated (you used it during the one-time `ssh-copy-id`)
- [ ] Password authentication disabled on the VPS (Step 5 troubleshooting above)
- [ ] Backup of `~/.kube/config` not committed to a public repo
