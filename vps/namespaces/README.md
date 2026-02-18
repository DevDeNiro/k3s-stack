# Application Namespaces

This directory contains **infrastructure namespaces only**.

Application-specific namespaces (e.g., `myapp-prod`, `myapp-alpha`) should be:

1. Defined in the application's own Helm chart
2. Created using the `create-app-namespaces.sh` script

## Creating Application Namespaces

```bash
# Create namespaces for your application
./scripts/create-app-namespaces.sh myapp

# This creates:
# - myapp-prod (with resource quotas)
# - myapp-alpha (with resource quotas)
```

## Manual Creation

Or use kubectl directly:

```bash
kubectl create namespace myapp-prod
kubectl create namespace myapp-alpha
```
