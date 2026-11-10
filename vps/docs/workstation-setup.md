# Workstation Setup

How to use `kubectl`, `k9s` and `helm` from a workstation (macOS, Linux, Windows) against
the VPS. The Kubernetes API (6443) is closed by the VPS firewall: the workstation reaches
it through an SSH tunnel.

End state:
- passwordless SSH to the VPS (`ssh k3s-vps`)
- `~/.kube/config-k3s-vps` pointing at `https://127.0.0.1:16443`, the local end of the tunnel
- `kubectl get nodes` and `k9s` work from the terminal

## Prerequisites

| Tool | macOS | Windows |
|------|-------|---------|
| `ssh` / `ssh-keygen` | built-in | built-in (OpenSSH) |
| `kubectl` | `brew install kubectl` | `winget install Kubernetes.kubectl` |
| `k9s` | `brew install k9s` | `winget install Derailed.k9s` |
| `helm` (optional) | `brew install helm` | `winget install Helm.Helm` |
| `kubeseal` (to seal secrets) | `brew install kubeseal` | release binary |

## Step 1: SSH key and passwordless access

```bash
# Key with a passphrase (stored in the agent / keychain)
ssh-keygen -t ed25519 -C "$USER-k3s-vps-$(date +%Y%m%d)" -f ~/.ssh/k3s_vps_ed25519
ssh-copy-id -i ~/.ssh/k3s_vps_ed25519.pub <user>@<vps-ip>
```

On Windows, append the content of the `.pub` file to `~/.ssh/authorized_keys` on the VPS.

## Step 2: SSH host alias with the tunnel

```text
# ~/.ssh/config
Host k3s-vps
    HostName <vps-ip>
    User <user>
    IdentityFile ~/.ssh/k3s_vps_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 60
    # Kubernetes API of the VPS on localhost:16443
    LocalForward 16443 127.0.0.1:6443
```

`ssh k3s-vps` now opens the tunnel with the session; `ssh -fN k3s-vps` opens it in the
background without a shell.

## Step 3: kubeconfig

```bash
./vps/scripts/setup-remote.sh <vps-ip> --user <user>
```

The script copies the VPS kubeconfig into `~/.kube/config-k3s-vps` (mode 0600), with the
context, cluster and user renamed `k3s-vps` and the server set to
`https://127.0.0.1:16443`, then checks the access through a temporary tunnel. Options:
`--port` (SSH port), `--local-port` (default 16443), `--context` (default `k3s-vps`),
`--direct` (no tunnel, only with `harden-host.sh --allow-api-from <your-ip>/32`).

```bash
ssh -fN k3s-vps                        # tunnel in the background
export KUBECONFIG=~/.kube/config-k3s-vps
kubectl get nodes
```

To keep several clusters (for example the local k3d one):

```bash
export KUBECONFIG=~/.kube/config:~/.kube/config-k3s-vps
kubectl config use-context k3s-vps
```

## Step 4: k9s

```bash
k9s --context k3s-vps
```

| Key / command | Effect |
|---------------|--------|
| `0` | pods of all namespaces |
| `:ns` | namespace picker |
| `:pods`, `:deploy`, `:svc`, `:httproute` | resource type |
| `:applications` | Argo CD Applications |
| `:events` | events sorted by time |
| `/<text>` | filter the list |
| `l` / `d` / `s` | logs / describe / shell |
| `Shift-R`, `Shift-M` | sort by restarts, by memory |
| `:ctx` | switch context |

## Step 5: web consoles through port-forward

```bash
kubectl port-forward -n argocd svc/argocd-server 8080:80          # http://localhost:8080
kubectl port-forward -n monitoring svc/grafana 3000:80            # http://localhost:3000
kubectl port-forward -n monitoring svc/prometheus-server 9090:80  # http://localhost:9090
kubectl port-forward -n security svc/keycloak 8081:80             # http://localhost:8081/admin
```

Passwords: `ssh k3s-vps sudo <clone>/vps/scripts/export-secrets.sh show <service>`.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `connection refused` on `127.0.0.1:16443` | the tunnel is not open: `ssh -fN k3s-vps` |
| `bind: Address already in use` | a tunnel is already open (`lsof -i :16443`), or choose `--local-port` |
| `Unauthorized` | kubeconfig of a previous installation: run `setup-remote.sh` again |
| `x509: certificate is valid for ...` | use the generated kubeconfig: it targets `127.0.0.1`, covered by the K3s certificate |
| `permission denied` on the kubeconfig | `chmod 600 ~/.kube/config-k3s-vps` |

## Security checklist

- The SSH key has a passphrase and is loaded in the agent (`ssh-add`).
- Password logins are disabled on the VPS: `sudo ./vps/scripts/harden-host.sh --apply --harden-ssh`
  (after a successful key login in a second session).
- `~/.kube/config-k3s-vps` is mode 0600 and never committed: it grants cluster-admin.
- Port 6443 stays closed on the VPS; open it to a fixed IP only if a tunnel is not
  possible (`--allow-api-from`).
