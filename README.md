# kinops Community

A free, open source GitOps platform for Kubernetes, installed in one command.
Everything lives in your Git repo and ArgoCD applies it.

**Included:** ArgoCD, Traefik (Gateway API), cert-manager, External Secrets + Infisical,
CloudNativePG (Postgres backups to SeaweedFS S3), Reloader, metrics-server, OpenEBS and monitoring
(Prometheus, Grafana, VictoriaMetrics, VictoriaLogs). Optional: Cilium, external-dns.

This is the platform base of every pack, monitoring included. In Community, Grafana uses a local admin (no SSO).

## Packs

| Pack | What you get | Status |
|---|---|---|
| **Community** (this repo) | Platform base: GitOps platform above + monitoring (Grafana with a local admin, no SSO) | Free, open source |
| **AI Platform** | Platform base + Authentik SSO (Grafana and apps log in with it) + self-hosted AI (Ollama, LiteLLM, Onyx, Langfuse, Coder, OpenClaw) + MCP servers behind LiteLLM (ArgoCD, VictoriaMetrics, VictoriaLogs, Coder) | Available |
| **Enterprise** | AI Platform + Velero backups, Argo Rollouts, Image Updater, Radar, Renovate. Planned: HA, multi-DC, disaster recovery | Available (HA, multi-DC, DR planned) |

Enterprise, shipped today: Velero backups (in-cluster SeaweedFS S3; add an off-cluster S3 location for disaster recovery), Argo Rollouts, Image Updater, Radar, Renovate. Planned, not available yet: HA, multi-DC, full disaster recovery.

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
| Turn a component on or off | Comment or uncomment it in `argocd/applications/platform/appset.yaml` |
| See the deploy order | Stages and dependencies: [argocd/applications/platform/README.md](argocd/applications/platform/README.md) |
| Deploy my app | Copy an example from `examples/` to `helm/apps/<my-app>/`: [docs/BOOTSTRAP-APP.md](docs/BOOTSTRAP-APP.md) |
| Understand the repo layout | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Tune a component | Edit `helm/platform/<component>/values.yaml` |
| Add a Grafana dashboard | ConfigMap with label `grafana_dashboard: "1"` + annotation `grafana_folder: <folder>`, or a grafana.com id in `helm/platform/monitoring/values.yaml` |
| Back up a Postgres | Infisical's is backed up to the in-cluster S3 (SeaweedFS), 7 days, point-in-time. For your own `cnpg-cluster`: copy `plugins`, `objectStore` and `scheduledBackup` from `helm/platform/infisical/values.yaml` |

Full docs: https://shop.kien.cc/docs

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/kinopshq/core/main/scripts/install.sh | bash -s uninstall
```

Removes the ArgoCD apps, then ArgoCD. Namespaces and volumes are kept; delete them with `kubectl delete ns ...` if you want.

## License

Apache-2.0. Open source components keep their own licenses.
