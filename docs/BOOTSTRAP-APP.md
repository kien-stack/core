# Bootstrap your own app

A fresh install deploys **no sample app**: `helm/apps/` is empty. ArgoCD (ApplicationSet `apps`,
`argocd/applications/apps/appset.yaml`) creates one Application per folder `helm/apps/<name>/`, in the namespace `<name>`.
Ready-to-copy examples live in `examples/` (never deployed, the ApplicationSets do not watch it):

| Example | What it shows |
|---|---|
| [examples/postgres-api](../examples/postgres-api) | HTTP API (PostgREST) on its own PostgreSQL (CloudNativePG), DB credentials as env vars, app secrets from Infisical, HTTPRoute, NetworkPolicies |
| [examples/app-template/*](../examples/app-template) | One per workload kind (frontend, backend, worker, cronjob, job, statefulset, daemonset) |

Needs the bricks `cloudnative-pg`, `external-secrets`, `infisical`, `openebs` and `traefik` (all on by default).

## 1. Copy the example

```sh
APP=shop-api      # lowercase, = folder = namespace = Helm release = hostname
cp -r examples/postgres-api helm/apps/$APP
grep -rl postgres-api helm/apps/$APP | xargs sed -i "s/postgres-api/$APP/g"   # macOS: sed -i ''
```

Then edit `helm/apps/$APP/values.yaml`: your image, port, probes. Keep the env block: the database is reached through
the standard `PG*` variables (`PGHOST`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGPORT`), read from the Secret `<app>-cnpg`
that CloudNativePG + External Secrets create (`username`, `password`, `DB_HOST`, `DB_DATABASE`,
`DB_CONNECTION_URI` = `postgres://user:pass@<app>-cluster-rw:5432/app`). Need one URL instead (`DATABASE_URL`)?
`DATABASE_URL: {valueFrom: {secretKeyRef: {name: <app>-cnpg, key: DB_CONNECTION_URI}}}`. No database? Remove the
`cnpg-cluster` dependency (`Chart.yaml`) and block (`values.yaml`), the `migrate` init container and the `PG*` env.

## 2. Its secrets in Infisical

Every secret of the Infisical folder `/<app>` (project `kubernetes`, environment `infisicalSecrets.env`, `prod` by default)
lands in the Secret `<app>-secrets` and is injected as env vars (`envFrom`).

1. Open `https://infisical.<domain>` (admin: `kubectl -n infisical get secret infisical-admin -o jsonpath='{.data.email}' | base64 -d`,
   same with `password`).
2. Project `kubernetes` -> environment **prod** (and dev/staging if you use them) -> **Add folder** `<app>`.
3. Add your secrets in it, e.g. `GREETING=hello from Infisical` (the example writes it to the database on first start).

Create the folder **before** pushing: an ExternalSecret on a missing folder stays in error and the app is Degraded.
No app secret? Delete the `infisicalSecrets` block and `templates/externalsecret.yaml`.

## 3. Expose it (HTTPS)

Add `<app>` to `global.gatewayHosts` in `cluster.yaml` (one HTTPS listener + certificate `<app>.<domain>`); the route in
`values.yaml` already uses `sectionName: https-<app>`.

## 4. Commit, push

```sh
git add helm/apps/$APP cluster.yaml && git commit -m "feat: $APP" && git push
kubectl -n argocd get application $APP    # Synced / Healthy after 1-3 min (Postgres first, then the app)
curl -k https://$APP.<domain>/greetings    # the example: [{"id":1,"message":"...","created_at":"..."}]
```

## Network

`templates/networkpolicy.yaml` denies ingress by default and allows: the same namespace (app -> Postgres), `monitoring`,
Traefik -> the app port, the CloudNativePG operator -> Postgres. Another namespace must call the app? Add an entry to
`networkPolicy.allow` in `values.yaml`.

## Remove it

`git rm -r helm/apps/$APP`, push: ArgoCD deletes the Application and its resources (the database volume included).
Then delete the Infisical folder if you want.
