# Architecture

One Git repo describes the whole cluster. ArgoCD reads it and deploys it.

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

Add your own app: [BOOTSTRAP-APP.md](BOOTSTRAP-APP.md).
