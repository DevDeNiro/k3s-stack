# K3s Stack Deployment Flow

For the installation and onboarding commands, see [installation-onboarding.md](installation-onboarding.md).
Script parameters are documented in [the VPS reference](../README.md).

## Repository and discovery

- Discovery currently targets GitHub organizations listed in `SCM_ORGANIZATIONS`.
- Each repository needs a unique lowercase name, `helm/<repository>/values.yaml` and
  `values-prod.yaml`; alpha also needs `values-alpha.yaml` on `develop`.
- The production generator checks for `helm/` on the default branch and follows `main`.
  The alpha generator checks `helm/` on `develop`.
- `onboard-app.sh` creates the namespaces and AppProject before Argo CD can deploy.
  The project permits only the application's repository and namespaces; cluster-scoped
  resources, `ResourceQuota`, `LimitRange`, `Endpoints` and `EndpointSlice` are refused.
- The templates poll every 180 seconds once applied. Losing the `develop` branch removes
  its alpha Application and resources. If a repository leaves production discovery, its
  Application is deleted but the deployed resources are preserved.

## Images and synchronization

| Environment | Branch | Image Updater filter | Sync |
|-------------|--------|----------------------|------|
| Alpha | `develop` | `develop-<40-character SHA>` | automatic, with self-heal and prune |
| Production | `main` | `main-<40-character SHA>` | manual |

Image Updater polls the registry, selects the newest matching build and writes `image.tag`
into the Application, not Git. It can select an image before the first workload starts.
Initially the Application uses the mutable `develop` or `main` tag; alpha can sync before
an immutable tag is selected. **Before syncing production, verify that the selected tag
matches the Git revision being deployed.** These behaviors require the current templates
to be applied; repository changes alone do not update a running cluster.

Each organization uses `REGISTRY_HOST/<organization>/<repository>` (lowercase), or
`REGISTRY_BASE/<repository>` for a single organization. A read-only image token is copied
into application namespaces as `ghcr-secret`; the repository token stays in `argocd`.

## Secrets and migrations

- Onboarding creates `<app>-db` directly and saves its password in
  `/root/.k3s-secrets/<app>.env`. Back it up securely; do not duplicate it as a
  SealedSecret. Application secrets are sealed with the destination cluster's public
  certificate and committed encrypted.
- Sealed Secrets default to **strict** scope: the name and namespace must match. For
  `namespace-wide` Secrets, use `--scope namespace-wide` with the target namespace.
- An optional PreSync migration needs its image pull secret and database secret before
  Sync. The common-library migration job uses the default ServiceAccount unless
  configured otherwise. Application-specific secrets created during Sync are unavailable
  to a first PreSync hook.
- For Keycloak, the expected issuer must match the token's `iss`, normally the public
  realm URL. CoreDNS routes configured public hostnames internally; use separate internal
  endpoints only if the application supports them.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No Application | Onboarding AppProject, GitHub token, organization, `helm/` and branch; inspect the ApplicationSet controller logs. |
| Project not found | Onboard the application; if the project exists, refresh the relevant ApplicationSet. |
| ImagePullBackOff | Image path and tag, then `ghcr-secret` in the application namespace. |
| `no key could decrypt secret` | Seal again with the target cluster certificate and correct scope. |
| Resource not permitted | Remove forbidden or cluster-scoped resources from the application chart. |
| Route not attached | Declare `hostname=namespace` in `GATEWAY_HOSTNAMES` and apply the gateway configuration. |
| Connection refused to PostgreSQL or Keycloak | Check the application's egress policy, namespace label, ports and DNS. |
| Rolling update exceeds quota | Size quota for both old and new pods, then apply onboarding settings to the intended environment. |

For logs and diagnostic commands, see [commands-cheatsheet.md](commands-cheatsheet.md).

## Example applications

[DevDeNiro/react-starter-kit](https://github.com/DevDeNiro/react-starter-kit) is a static
client with no database (`onboard-app.sh <app> --skip-database`). Server applications use
the same chart layout and may add their own database, Keycloak realm and cache.
