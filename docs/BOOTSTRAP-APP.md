# Bootstrap your app

Your app is a Helm chart in `helm/apps/<name>/`. Push it to Git: ArgoCD deploys it.

## Quick start

Copy an example, rename it, set your image:

```bash
cp -r examples/app-template/backend helm/apps/my-app
$EDITOR helm/apps/my-app/Chart.yaml helm/apps/my-app/values.yaml   # name, image, port, host
```

Commit and push:

```bash
git add helm/apps/my-app
git commit -m "feat: add my-app"
git push
```

ArgoCD picks up the new folder and creates the `my-app` application.

## Check it in ArgoCD

- UI: `https://argocd.<your-domain>`, app `my-app` must be *Synced* and *Healthy*.
- CLI:

  ```bash
  kubectl -n argocd get applications
  kubectl -n my-app get pods
  ```

## Restrict it to some IPs (optional)

Your app is open to everyone by default.

To allow only `global.platformAccess.allowedIPs` (like ArgoCD, Grafana, Infisical):

1. Copy `helm/platform/monitoring/templates/platform-access.yaml` to `helm/apps/my-app/templates/`.
2. Add this filter to your route rule (`route.main.rules[]` in values.yaml):

   ```yaml
   filters:
     - type: ExtensionRef
       extensionRef: {group: traefik.io, kind: Middleware, name: platform-access}
   ```

## Examples

In [`examples/`](../examples/):

- `app-template/`: one folder per workload kind (backend, frontend, worker, job, cronjob, statefulset, daemonset).
- `postgres-api/`: an API with its own PostgreSQL database.
