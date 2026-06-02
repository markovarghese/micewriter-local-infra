# table-pipeline

One Helm release == one v2 mIceWriter engine pipeline serving a single Iceberg
table. Provisions a `Deployment` + `Service` + `HorizontalPodAutoscaler` named
`engine-{table}` so the SDK's default resolver (`engine-{table}.{ns}.svc:9090`)
resolves to it with no per-table override.

## Install

```powershell
docker run --rm -i `
  -v "$HOME\.kube\config:/kubeconfig:ro" `
  -e KUBECONFIG=/kubeconfig `
  -v "${PWD}:/workspace:ro" -w /workspace `
  alpine/helm:latest `
  upgrade --install engine-telemetry-events ./charts/table-pipeline `
    --namespace micewriter-infra `
    --set table=telemetry_events `
    --wait
```

For a second table:

```powershell
... upgrade --install engine-audit-events ./charts/table-pipeline `
    --namespace micewriter-infra `
    --set table=audit_events `
    --set resources.requests.memory=128Mi `
    --set resources.limits.memory=512Mi `
    --wait
```

## Required values

| Key | Description |
|---|---|
| `table` | Iceberg table this pipeline serves. Becomes `MICEWRITER_TABLE`; basis of the K8s Service name (`engine-{table}`, with `_` → `-` and lowercased). |

## Common overrides

| Key | Default | Why you'd change it |
|---|---|---|
| `image.tag` | `latest` | Pin a specific build |
| `resources.requests/limits` | 100m / 256Mi → 1000m / 1Gi | Right-size for the table's payload shape |
| `replicas.min` / `replicas.max` | 1 / 3 | Per-table HPA range |
| `hpa.enabled` | `true` | Set false to pin replicas to `min` |
| `flush.sizeBytes` | 32 MiB | Smaller windows for hot tables; larger for cold tables targeting big Parquet files |
| `catalog.type` | `nessie` | Switch to `glue` for production EKS |
| `enableManualFlush` | `true` | **Set false in production** — protects the catalog from API abuse |
| `rocksdb.storage.type` | `emptyDir` | Set `pvc` if you want the buffer to survive a pod restart (engine still does emergency-flush on SIGTERM) |

## Full value reference

See [`values.yaml`](values.yaml) — every key is commented inline.

## Lifecycle

| Operation | Command |
|---|---|
| Add a table | `helm upgrade --install engine-<table> ./charts/table-pipeline --set table=<table> ...` |
| Update sizing for an existing table | Same command with new `--set` values (Helm upgrade is idempotent) |
| Remove a table | `helm uninstall engine-<table> -n micewriter-infra` |

## What it expects from the surrounding cluster

- A `Secret` named (by default) `nessie-s3-creds` in the same namespace with `aws_access_key_id` and `aws_secret_access_key` data keys. The local-infra `run.ps1 up` creates it.
- The engine image present at `{{ image.repository }}:{{ image.tag }}` — `local-infra/registry` hosts it for the local k3s eval.
- A reachable Iceberg catalog (Nessie REST or AWS Glue) at the configured endpoint.
- A reachable S3 / MinIO endpoint at the configured URL.

## How v1 differs (for the curious)

In v1, the engine was a per-pod sidecar injected by the `micewriter-k8s-injector` admission webhook. There was no Helm chart for it — the injector embedded the engine container into every annotated application pod. v2 retires the injector entirely; this chart replaces that whole flow. See [v1-to-v2-migration.md](../../../micewriter-hub/docs/v1-to-v2-migration.md) for the rationale.
