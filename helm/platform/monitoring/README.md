# monitoring

Prometheus + Grafana + VictoriaMetrics + VictoriaLogs.

## Backup

VictoriaMetrics is backed up every day at 02:00 to the in-cluster S3 (SeaweedFS): `s3://monitoring/victoria-metrics`.

CronJob `vmbackup` (`values.yaml`). Incremental: only new data is uploaded.

Run one now:

```bash
kubectl -n monitoring create job --from=cronjob/vmbackup vmbackup-manual
```

## Restore

Restores the last backup. Data written after it is lost.

1. Stop VictoriaMetrics:

```bash
kubectl -n monitoring scale statefulset monitoring-victoria-metrics-single-server --replicas=0
```

2. Run the restore Job:

```bash
kubectl -n monitoring apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: vmrestore
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      containers:
        - name: vmrestore
          image: victoriametrics/vmrestore:v1.156.0  # same tag as vmbackup in values.yaml
          args:
            - -src=s3://monitoring/victoria-metrics
            - -storageDataPath=/storage
            - -customS3Endpoint=http://seaweedfs-s3.seaweedfs.svc:8333
            - -credsFilePath=/creds/credentials
          volumeMounts:
            - {name: storage, mountPath: /storage}
            - {name: creds, mountPath: /creds, readOnly: true}
      volumes:
        - name: storage
          persistentVolumeClaim:
            claimName: server-volume-monitoring-victoria-metrics-single-server-0
        - name: creds
          secret:
            secretName: vmbackup-s3
EOF
kubectl -n monitoring wait --for=condition=complete job/vmrestore --timeout=30m
```

3. Start VictoriaMetrics, delete the Job:

```bash
kubectl -n monitoring scale statefulset monitoring-victoria-metrics-single-server --replicas=1
kubectl -n monitoring delete job vmrestore
```

ArgoCD shows `monitoring` OutOfSync while the StatefulSet is at 0: expected, it does not scale it back (RollingSync turns off auto-sync on the platform apps). Back in sync at step 3.

## Grafana dashboards

Your dashboard: ConfigMap with label `grafana_dashboard: "1"` + annotation `grafana_folder: <folder>`.

A grafana.com dashboard: `dashboardProviders` + `dashboards` in `values.yaml`.
