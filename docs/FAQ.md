# FAQ

## What do I need?

**1. A Kubernetes cluster** (>= 1.29) and a kubeconfig with *cluster-admin* rights.

- k3s, kind, minikube, EKS, GKE, AKS... all work.
- No cluster yet? Install [k3s](https://docs.k3s.io/quick-start):

  ```bash
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -
  ```

**2. Resources** (allocatable): 2 vCPU, 6 GB RAM (8 GB recommended), 40 GB disk.

**3. A load balancer** for the Traefik Service:

- cloud LB, k3s ServiceLB, `minikube tunnel`, or Cilium L2 (homelab, see below).
- Otherwise use a NodePort: `traefik.service.spec.type: NodePort` in `cluster.yaml` (see the comment there).

**4. Storage**: OpenEBS hostpath is installed by default (local volumes on the node disk).

- On a cloud cluster you can keep its StorageClass instead.
- Then exclude `helm/platform/openebs` in `argocd/applications/platform/appset.yaml`.

**5. On your machine**: `kubectl`, `helm` >= 3.14, `git`.

- `yq` v4 is downloaded if missing.
- `./install.sh doctor` checks everything.

**6. A Git repo** reachable from the cluster: your fork of this repo.

- Private repo: set `GIT_USERNAME` + `GIT_TOKEN` (read-only is enough).

**Not needed:** Vault, Bitnami charts, GPU, inbound Internet access (except for Let's Encrypt HTTP-01).

All images are public (docker.io, quay.io, ghcr.io, registry.k8s.io).

## No domain name?

Leave the domain empty in `scripts/install.sh`.
It then uses `<ip>.sslip.io` (free public DNS that resolves to the IP).

Certificates are **self-signed** (CA in `cert-manager/selfsigned-ca`), e.g. `https://argocd.192.168.1.240.sslip.io`.

Your browser shows a warning until you import the CA.

## A real domain and certificates

**DNS:** point `*.your-domain` to the Traefik load balancer IP.

Or let external-dns do it:

- enable `helm/platform/external-dns` in `argocd/applications/platform/appset.yaml`
- set `external-dns:` in `cluster.yaml`
- pass `EXTERNAL_DNS_API_TOKEN` to `install.sh`

**TLS** (in `cluster.yaml`), pick one:

- `global.tls.issuer: letsencrypt-http01` + `global.issuer: letsencrypt` (port 80 open from the Internet)
- `letsencrypt-dns01` (Cloudflare API token in `DNS01_API_TOKEN`)

## Where do I log in to ArgoCD?

`install.sh` prints the admin password. Before Traefik is ready you can always use:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443   # https://localhost:8080, user admin
```

## Cilium (optional)

Remove the `helm/platform/cilium` exclude in `argocd/applications/platform/appset.yaml` and uncomment
`cilium:` in `cluster.yaml` (`k8sServiceHost` = API server IP): `install.sh` installs Cilium first (eBPF CNI,
replaces kube-proxy, L2 load balancer IPs via `ciliumLB` in `cluster.yaml`, no MetalLB needed).
Only for a cluster created **without** a CNI nor kube-proxy, e.g. k3s:
`--flannel-backend=none --disable-network-policy --disable-kube-proxy --disable servicelb`.
`install.sh doctor` refuses Cilium if a CNI is already running.

## How do I remove everything?

```bash
curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/try.sh | bash -s uninstall
```

Namespaces and volumes are kept; delete them with `kubectl delete ns ...` if you want.
