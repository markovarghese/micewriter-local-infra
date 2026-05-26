# micewriter-local-infra
> Part of the [mIceWriter Ingestion Ecosystem](../micewriter-hub/README.md)

Local data lake simulator: deploys **MinIO** (S3-compatible object store) and **Apache Nessie** (Iceberg REST Catalog) onto a k3s cluster via Helm.

## Prerequisites

| Tool | Purpose |
|------|---------|
| Docker | Required to run helm and kubectl containers |
| GNU Make | Running the Makefile targets |

*(Note: `helm` and `kubectl` run via Docker containers transparently, using your local `~/.kube/config`)*

## Quick Start

```bash
# 1. Add Helm repos and deploy both services
make up

# 2. Verify
make status
```

## Endpoints

| Service | URL | Notes |
|---------|-----|-------|
| MinIO Console | http://k8s-node-1.local:9001 | user: `micewriter` / `micewriter123` |
| MinIO S3 API | http://k8s-node-1.local:9000 | Use as `MINIO_URL` in the engine |
| Nessie REST | http://k8s-node-1.local:19120/api/v1 | Nessie native API |
| Iceberg REST | http://k8s-node-1.local:19120/iceberg/v1 | Use as `NESSIE_URI` in the engine |

The `iceberg` bucket is created automatically by MinIO's provisioning job on first deploy.

## Make Targets

```
make up      # Deploy MinIO + Nessie (idempotent — safe to re-run)
make down    # Uninstall both Helm releases
make status  # Show pod status in micewriter-infra namespace
make clean   # Purge the namespace to delete PVCs and reset state completely
```

## File Structure

```
micewriter-local-infra/
  Makefile            # Orchestrates helm install/uninstall
  minio/
    values.yaml       # Bitnami MinIO chart overrides
  nessie/
    values.yaml       # Project Nessie chart overrides
```

## Notes

- Nessie uses an **in-memory** version store — all catalog state is lost on pod restart. This is intentional for local development. For persistence, set `versionStoreType: JDBC` in `nessie/values.yaml` and add a Postgres chart.
- MinIO persistence uses the k3s `local-path` storage class, so Parquet files survive pod restarts.
- Ingress is intentionally bypassed. `ServiceLB` (Klipper LoadBalancer) binds the ports directly to the node IPs, allowing native mDNS routing.
