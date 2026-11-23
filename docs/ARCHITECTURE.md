# Architecture

One Git repo describes the whole cluster. You edit files and push, ArgoCD deploys them.

## Layout

```text
argocd/            declares the platform ApplicationSets (everything ArgoCD deploys for the platform)
helm/platform/     platform bricks: one chart + values per component
helm/apps/         your apps, one folder per app
examples/          app charts to copy into helm/apps/
scripts/           one-line install / try scripts
hack/              repo checks (validate, network policies)
docs/              guides
cluster.yaml       your cluster settings (domain, options)
install.sh         bootstrap: doctor, install
```

## How it flows

- `install.sh` installs ArgoCD and applies `argocd/app-of-apps.yaml`.
- The app-of-apps creates the ApplicationSets in `argocd/applications/`.
- The ApplicationSets deploy every chart in `helm/platform/` and `helm/apps/`.
- You push to Git, ArgoCD syncs.

## argocd/

```text
argocd/
  app-of-apps.yaml               root app: the repo/branch ArgoCD follows
  applications/
    platform/appset.yaml         one Application per platform brick
    platform/app-project.yaml    ArgoCD project of the bricks
    apps/appset.yaml             one Application per folder in helm/apps/
    apps/app-project.yaml        ArgoCD project of your apps
```

Enabled bricks: argocd, traefik, cert-manager, external-secrets, openebs, cloudnative-pg, infisical, reloader, metrics-server.

Off by default: cilium, external-dns.

The brick list lives in `argocd/applications/platform/appset.yaml`:

```yaml
generators:
  - list:
      elements:
        - app: traefik            # folder helm/platform/traefik
          namespace: traefik      # namespace it is deployed in
        # - app: external-dns     # commented = disabled
        #   namespace: external-dns
```

- **Disable a brick:** comment out its entry, push. ArgoCD removes it.
- **Enable a brick:** uncomment its entry, push.
- **Add a brick:** create `helm/platform/<app>/` (see below), add `- app: <app>` + `namespace:` to the list, push.

## helm/platform/

Each brick wraps an upstream chart:

```text
helm/platform/traefik/
  Chart.yaml     upstream chart + version
  values.yaml    our settings for it
```

```yaml
# Chart.yaml
dependencies:
  - name: traefik
    repository: https://traefik.github.io/charts
    version: 0.2.0
```

- **Change settings:** edit `values.yaml` (keys go under the dependency name, e.g. `traefik:`), push.
- **Bump the upstream chart:** change `version` in `Chart.yaml`, push.
- **Cluster-wide settings** (domain, options): `cluster.yaml`, passed to every brick.

## helm/apps/

Your apps. One folder = one Helm chart = one ArgoCD app, picked up automatically.

```bash
cp -r examples/postgres-api helm/apps/my-app
git add helm/apps/my-app && git commit -m "feat: add my-app" && git push
```

Full guide: [BOOTSTRAP-APP.md](BOOTSTRAP-APP.md).
