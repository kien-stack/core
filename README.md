# kien/stack Essential

A free, open source GitOps platform for Kubernetes, installed in one command.
Everything lives in your Git repo and ArgoCD applies it.

**Included:** ArgoCD, Traefik (Gateway API), cert-manager, External Secrets + Infisical,
CloudNativePG, Reloader, metrics-server, OpenEBS, monitoring (Prometheus, Grafana, VictoriaMetrics,
VictoriaLogs). Optional: Cilium, external-dns.

## Packs

| Pack | What you get | Status |
|---|---|---|
| **Essential** (this repo) | GitOps platform above, monitoring included, Grafana with a local admin | Free, open source |
| **Private AI** | Essential + self-hosted AI (Ollama, LiteLLM, Onyx, Langfuse, Coder, OpenClaw) | Available |
| **All-In-One** (full) | Private AI + Authentik SSO, Velero backups, Argo Rollouts, Image Updater, Radar, Renovate | Available |
| **Pro** | HA, multi-DC, disaster recovery, SSO | Planned, not available yet |

SSO (Authentik) ships today in All-In-One. Going forward SSO belongs to Pro; nothing is removed from All-In-One for now.

## Try it

```bash
curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/try.sh | bash
```

## Install

1. [Fork this repo](https://github.com/kien-stack/essential/fork).
2. Run the installer. It asks for your fork, domain and email:

```bash
curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh | bash
```

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
