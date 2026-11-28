# kinops Community

A free, open source GitOps platform for Kubernetes, installed in one command.
Everything lives in your Git repo and ArgoCD applies it.

**Included:** ArgoCD, Traefik (Gateway API), cert-manager, External Secrets + Infisical,
CloudNativePG, SeaweedFS (S3 in your cluster), Reloader, metrics-server, OpenEBS and monitoring
(Prometheus, Grafana, VictoriaMetrics, VictoriaLogs). Optional: Cilium, external-dns.

Postgres databases (point-in-time restore) and the metrics history (daily vmbackup) are backed up to SeaweedFS.

This is the platform base of every pack, monitoring and S3 included. In Community, Grafana uses a local admin (no SSO).

## Packs

| Pack | What you get | Status |
|---|---|---|
| **Community** (this repo) | Platform base: GitOps, secrets, Postgres and metrics backed up to S3, S3 in your cluster, monitoring (local Grafana admin, no SSO) | Free, open source |
| **AI Platform** | Community + single sign-on (Authentik) + your own AI: chat over your docs (Onyx), local LLMs (Ollama), LLM gateway (LiteLLM), tracing (Langfuse), agent (OpenClaw), dev environments (Coder), MCP tools for your agents (ArgoCD, metrics, logs, Coder) | Coming soon |
| **Enterprise** | AI Platform + resilience: HA Postgres, distributed storage, volume backups outside the cluster, disaster recovery, multi-DC. Plus AI Ops, progressive delivery, image updates, read-only cluster view | Coming soon |

## Try it

```bash
curl -fsSL https://raw.githubusercontent.com/kinopshq/core/main/scripts/try.sh | bash
```

## Install

1. [Fork this repo](https://github.com/kinopshq/core/fork).
2. Run the installer (one script). First run asks for your fork, domain and email, commits and pushes:

```bash
curl -fsSL https://raw.githubusercontent.com/kinopshq/core/main/scripts/install.sh | bash
```

Or from your clone: `./install.sh` (`./install.sh configure` to change the answers).

Requirements: a Kubernetes cluster (2 vCPU, 8 GB RAM), `kubectl`, `helm`, `git`.

### Private repo

If your fork is private (GitLab, Gitea, private GitHub...), the installer needs a token to clone and push it.

1. Create a token with read and write access to the repo:

   | Host | Token | Permissions |
   |---|---|---|
   | GitLab | Personal or project access token | `read_repository`, `write_repository` |
   | GitHub | Fine-grained personal access token | Contents: Read and write (on your fork) |

2. Export it, then run the installer:

   ```bash
   export GIT_USERNAME=<your-user>
   export GIT_TOKEN=<your-token>
   curl -fsSL https://raw.githubusercontent.com/kinopshq/core/main/scripts/install.sh | bash
   ```

> [!NOTE]
> Use `export`. With `GIT_TOKEN=... curl ... | bash`, only `curl` gets the token, not the installer.

> [!TIP]
> `repository not found` on a repo that exists usually means a missing or invalid token: private repos are hidden without one.

## Use it

| I want to | Do this, then `git push` |
|---|---|
| Change my settings | Edit `cluster.yaml` |
| Open ArgoCD, Grafana, Infisical from another IP | Add it to `global.platformAccess.allowedIPs` in `cluster.yaml` (others get 403): [Platform access](#platform-access) |
| Turn a component on or off | Comment or uncomment it in `argocd/applications/platform/appset.yaml` |
| See the deploy order | Stages and dependencies: [argocd/applications/platform/README.md](argocd/applications/platform/README.md) |
| Deploy my app | Copy an example from `examples/` to `helm/apps/<my-app>/`: [docs/BOOTSTRAP-APP.md](docs/BOOTSTRAP-APP.md) |
| Understand the repo layout | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Tune a component | Edit `helm/platform/<component>/values.yaml` |
| Add a Grafana dashboard | ConfigMap with label `grafana_dashboard: "1"` + annotation `grafana_folder: <folder>`, or a grafana.com id in `helm/platform/monitoring/values.yaml` |
| Back up a Postgres | Infisical's is backed up to the in-cluster S3 (SeaweedFS), 7 days, point-in-time. For your own `cnpg-cluster`: copy `plugins`, `objectStore` and `scheduledBackup` from `helm/platform/infisical/values.yaml` |

Full docs: https://kinops.dev/docs

## Platform access

ArgoCD, Grafana and Infisical only answer the IPs in `cluster.yaml`. Everyone else gets 403.

The installer puts your public IP there. Your own apps in `helm/apps/` are not affected.

```yaml
global:
  platformAccess:
    allowedIPs:
      - 203.0.113.7/32     # you
      - 198.51.100.0/24    # your office
```

Edit, `git push`, done. `./install.sh doctor` shows the current list.

Behind a proxy or tunnel (Cloudflare tunnel, external load balancer): add the proxy IPs to
`traefik.ports.websecure.forwardedHeaders.trustedIPs` in `cluster.yaml`. Traefik then reads the client IP from `X-Forwarded-For`.

kind / minikube: the browser comes from the Docker network of the node: add it (e.g. `172.18.0.0/24`).

Open to everyone (not recommended): `allowedIPs: [0.0.0.0/0]`.

Locked out? `kubectl -n argocd port-forward svc/argocd-server 8080:443` still works (https://localhost:8080).

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/kinopshq/core/main/scripts/install.sh | bash -s uninstall
```

Removes everything the platform created: ArgoCD, the components, their namespaces and volumes (data lost), then `~/kinops` (your clone).

It lists what goes away and asks first (`KSTACK_YES=1`: no question). Changes not pushed to your fork: asked again.

Kept: CRDs.

## License

Apache-2.0. Open source components keep their own licenses.
