# Progressive sync

`appset.yaml` deploys the components in stages (`stage:` field of each entry).

A stage starts when every app of the previous stage is Healthy.

Components that depend on each other both ways go in the same stage: they converge on retries.

```mermaid
flowchart LR
  subgraph S1["Stage 1: network and certificates"]
    argocd
    traefik
    certmanager[cert-manager]
    cilium["cilium (off)"]
    externaldns["external-dns (off)"]
  end

  subgraph S2["Stage 2: operators and storage"]
    openebs
    cnpg[cloudnative-pg]
    reloader
    metricsserver[metrics-server]
  end

  subgraph S3["Stage 3: secrets, S3, monitoring"]
    eso[external-secrets]
    infisical
    seaweedfs
    monitoring
  end

  S1 ==> S2 ==> S3

  cnpg -->|Barman plugin certificates| certmanager

  eso -->|ClusterSecretStores need its identity| infisical
  infisical -->|generated secrets| eso
  infisical -->|backup S3 keys| seaweedfs
  infisical -->|PodMonitor CRD| monitoring
  infisical -->|Postgres| cnpg
  infisical -->|HTTPRoute| traefik
  seaweedfs -->|generated S3 keys| eso
  monitoring -->|generated secrets| eso
  seaweedfs -->|PVC| openebs
  infisical -->|PVC| openebs
```

Arrow = "needs".

Change a stage: edit `stage:` in `appset.yaml`. A component without a known stage goes in the last stage.
