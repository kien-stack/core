# Tests

What was tested, how, and the results. One section per feature, newest first.

Add a section when you add or change a feature.

## Restore steps of the monitoring README (#92)

Date: 2026-11-25. Cluster: minikube, 1 node, existing install.

- Restore Job of `helm/platform/monitoring/README.md`: `kubectl apply --dry-run=server` OK.
- StatefulSet scaled to 0 for 3 min: ArgoCD left it at 0 (`monitoring` OutOfSync), scaled back to 1, Ready.

Not tested: the whole README in one go (steps tested separately, see below).

## VictoriaMetrics backup and restore (#91)

Date: 2026-11-25. Cluster: minikube, 1 node, new objects applied on an existing install.

Backup:

- ExternalSecret `vmbackup-s3` SecretSynced, SecretStore Valid.
- 1st run (`create job --from=cronjob/vmbackup`): 20.9 MB in 1 s.
- 2nd run, incremental: 1.8 MB uploaded.

Restore on the live disk:

1. Before: 87,607 series, `sum(count_over_time(up[1h]))` = 449, 2,236,480 samples over 30 min, oldest `up` 22:46:28.
2. Backup: 28.2 MB in 5 s.
3. VictoriaMetrics stopped, `rm -rf /storage/*` on its PVC: 4 KB left.
4. `vmrestore`: 3 s. VictoriaMetrics Ready 16 s after restart.
5. After: same 4 values. Lost: ~30 s (written between backup and stop).

Not tested: fresh install with ArgoCD (bucket creation), the 02:00 schedule, multi-node.

## Grafana dashboards in folders (#89)

Date: 2026-11-25. Cluster: minikube, 1 node, AI Platform values (same monitoring values).

- Grafana API `/api/search`: Kubernetes 24, Databases 1, Logs 1, General 0.
- Home dashboard unchanged: Kubernetes / Compute Resources / Cluster.

Not tested: fresh install of Community.

## Postgres backups to S3 (#86)

Date: 2026-11-25. Cluster: minikube, 1 node, fresh install, zero manual step.

- Install: 414 s, 12/12 apps Synced/Healthy.
- `seaweedfs-s3` (generator) and `infisical-backup-s3` (copy): SecretSynced, same keys.
- `ContinuousArchiving=True`.
- On-demand backup: completed in 4 min 38 s.
- Point-in-time restore: 700 rows, deleted (0 left), restored to a new Cluster: Ready in 56 s, 700 rows back.

Not tested: the scheduled backup firing on its own, 7-day retention pruning, upgrade of an existing install, off-cluster S3, multi-node.
