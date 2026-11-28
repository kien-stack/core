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
| Open ArgoCD, Grafana, Infisical | Add your IP to `global.platformAccess.allowedIPs` in `cluster.yaml` (closed by default, others get 403). Behind Cloudflare, a tunnel or at home: [Platform access](#platform-access) |
| Turn a component on or off | Comment or uncomment it in `argocd/applications/platform/appset.yaml` |
| See the deploy order | Stages and dependencies: [argocd/applications/platform/README.md](argocd/applications/platform/README.md) |
| Deploy my app | [Deploy your app](#deploy-your-app) |
| Understand the repo layout | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Tune a component | Edit `helm/platform/<component>/values.yaml` |
| Add a Grafana dashboard | ConfigMap with label `grafana_dashboard: "1"` + annotation `grafana_folder: <folder>`, or a grafana.com id in `helm/platform/monitoring/values.yaml` |
| Back up a Postgres | Infisical's is backed up to the in-cluster S3 (SeaweedFS), 7 days, point-in-time. For your own `cnpg-cluster`: copy `plugins`, `objectStore` and `scheduledBackup` from `helm/platform/infisical/values.yaml` |

Full docs: https://kinops.dev/docs

## Deploy your app

Your app = a Helm chart. Two ways:

**In this repo:** put your chart in `helm/apps/<my-app>/`, then `git push`.

Examples: [`examples/`](examples/). Details: [docs/BOOTSTRAP-APP.md](docs/BOOTSTRAP-APP.md).

**In your own repo:**

1. Copy `argocd/applications/apps/appset.yaml` to `argocd/applications/apps/my-repo.yaml`.
2. In the copy: change `name`, both `repoURL` and `path` to your repo, remove the `cluster.yaml` line.
3. Add `my-repo.yaml` to `argocd/applications/apps/kustomization.yaml`, then `git push`.

## Platform access

ArgoCD, Grafana and Infisical are closed by default (403).

Open them to your IP in `cluster.yaml`, then `git push`:

```yaml
global:
  platformAccess:
    allowedIPs: [203.0.113.7/32]
```

Behind Cloudflare or a load balancer, also add the proxy IPs:

```yaml
traefik:
  ports:
    websecure:
      forwardedHeaders:
        trustedIPs: [173.245.48.0/20, ...]
```

- Cloudflare DNS: https://www.cloudflare.com/ips
- Cloudflare Tunnel: the pod CIDR (k3s: `10.42.0.0/16`)
- Load balancer: its IPs

Still 403? The refused IP is the first field:

```bash
kubectl -n traefik logs deploy/traefik | grep '" 403 '
```

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/kinopshq/core/main/scripts/install.sh | bash -s uninstall
```

Removes everything the platform created: ArgoCD, the components, their namespaces and volumes (data lost), then `~/kinops` (your clone).

It lists what goes away and asks first (`KSTACK_YES=1`: no question). Changes not pushed to your fork: asked again.

Kept: CRDs.

## License

Apache-2.0. Open source components keep their own licenses.
