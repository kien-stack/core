# kien/stack Essential

A free, open source GitOps platform for Kubernetes, installed in one command.
Everything lives in your Git repo and ArgoCD applies it.

**Included:** ArgoCD, Traefik (Gateway API), cert-manager, External Secrets + Infisical,
CloudNativePG, Reloader, metrics-server, OpenEBS and monitoring (Prometheus, Grafana, VictoriaMetrics,
VictoriaLogs). Optional: Cilium, external-dns.

This is the platform base of every pack, monitoring included. In Essential, Grafana uses a local admin (no SSO).

## Packs

| Pack | What you get | Status |
|---|---|---|
| **Essential** (this repo) | Platform base: GitOps platform above + monitoring (Grafana with a local admin, no SSO) | Free, open source |
| **AI Platform** | Platform base (monitoring included, no SSO) + self-hosted AI (Ollama, LiteLLM, Onyx, Langfuse, Coder, OpenClaw) | Available |
| **Pro** | AI Platform + Authentik SSO (Grafana and apps log in with it), Velero backups, Argo Rollouts, Image Updater, Radar, Renovate. Planned: HA, multi-DC, disaster recovery | Available (HA, multi-DC, DR planned) |

Pro is the former All-In-One pack (`kien-stack/full`) plus the enterprise features. Shipped today: Authentik SSO, Velero backups (in-cluster SeaweedFS S3; add an off-cluster S3 location for disaster recovery), Argo Rollouts, Image Updater, Radar, Renovate. Planned, not available yet: HA, multi-DC, full disaster recovery.

## Try it

```bash
curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/try.sh | bash
```

## Install

1. [Fork this repo](https://github.com/kien-stack/essential/fork).
2. Run the installer (one script). First run asks for your fork, domain and email, commits and pushes:

```bash
curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh | bash
```

Or from your clone: `./install.sh` (`./install.sh configure` to change the answers).

Requirements: a Kubernetes cluster (2 vCPU, 8 GB RAM), `kubectl`, `helm`, `git`.

## Use it

| I want to | Do this, then `git push` |
|---|---|
| Change my settings | Edit `cluster.yaml` |
| Turn a component on or off | Comment or uncomment it in `argocd/applications/platform/appset.yaml` |
| Deploy my app | Copy an example from `examples/app-template/` to `helm/apps/<my-app>/` |
| Tune a component | Edit `helm/platform/<component>/values.yaml` |

Full docs: https://shop.kien.cc/docs

## License

Apache-2.0. Open source components keep their own licenses.
