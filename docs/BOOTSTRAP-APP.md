# Bootstrap your app

Copy an example from `examples/` to `helm/apps/<app>/`; ArgoCD deploys it in namespace `<app>`.

1. Copy and rename:
   ```sh
   APP=shop-api
   cp -r examples/postgres-api helm/apps/$APP
   grep -rl postgres-api helm/apps/$APP | xargs sed -i "s/postgres-api/$APP/g"
   ```
2. Edit `helm/apps/$APP/values.yaml`: image, port, probes.
3. In Infisical (`https://infisical.<domain>`), project `kubernetes`, env `prod`: add folder `<app>` and your secrets. Do it before pushing.
4. Add `<app>` to `global.gatewayHosts` in `cluster.yaml`.
5. Push and check:
   ```sh
   git add helm/apps/$APP cluster.yaml && git commit -m "feat: $APP" && git push
   kubectl -n argocd get application $APP
   curl -k https://$APP.<domain>/greetings
   ```

## Env vars

- `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`: database connection, from Secret `<app>-cnpg`.
- `DATABASE_URL` (optional): map to key `DB_CONNECTION_URI` of `<app>-cnpg`.
- Infisical folder `/<app>` secrets: injected as-is via Secret `<app>-secrets`.

Remove: `git rm -r helm/apps/$APP` and push.
