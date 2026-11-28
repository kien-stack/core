# kinops Community

A free, open source GitOps platform for Kubernetes, installed in one command.
Everything lives in your Git repo and ArgoCD applies it.

Docs: https://kinops.dev/docs

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

## Deploy your app

Two ways. Pick one.

### 1. In this repo

One folder in `helm/apps/` = one app. Nothing else to set up.

```bash
cp -r examples/app-template/backend helm/apps/my-app
$EDITOR helm/apps/my-app/values.yaml    # image, port, host
git add helm/apps/my-app && git commit -m "feat: add my-app" && git push
```

More: [docs/BOOTSTRAP-APP.md](docs/BOOTSTRAP-APP.md)

### 2. From your own repo

Your charts live in another repo (here `charts/<app>/`). Add an ApplicationSet that points to it.

`argocd/applications/apps/my-repo.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: my-repo
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - git:
        repoURL: https://github.com/me/my-apps.git
        revision: main
        directories:
          - path: "charts/*"
  template:
    metadata:
      name: "{{ .path.basename }}"
    spec:
      project: apps
      source:
        repoURL: https://github.com/me/my-apps.git
        targetRevision: main
        path: "{{ .path.path }}"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{ .path.basename }}"
      syncPolicy:
        automated: {prune: true, selfHeal: true}
        syncOptions: [CreateNamespace=true]
```

List it in `argocd/applications/apps/kustomization.yaml`:

```yaml
resources:
  - app-project.yaml
  - appset.yaml
  - my-repo.yaml
```

`git push`. Each folder in `charts/` becomes an app.

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
