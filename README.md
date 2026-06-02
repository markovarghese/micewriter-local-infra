# micewriter-local-infra
> Part of the [mIceWriter Ingestion Ecosystem](../micewriter-hub/README.md)

Local data lake simulator and the home of the v2 engine pipeline Helm chart. Deploys **MinIO** (S3-compatible object store) and **Apache Nessie** (Iceberg REST Catalog) onto a k3s cluster; hosts [`charts/table-pipeline/`](charts/table-pipeline/README.md) which provisions one v2 `micewriter-engine` `Deployment` + `Service` + `HPA` per Iceberg table.

## Prerequisites

| Tool | Purpose |
|------|---------|
| Docker Desktop | Runs `helm` via containers — no native install needed |

Before running `powershell -ExecutionPolicy Bypass -File .\run.ps1 up` for the first time, add the local registry to Docker Desktop's
insecure registries list (**Settings → Docker Engine**) and restart Docker Desktop:

```json
{
  "insecure-registries": ["k8s-node-1.local:5000"]
}
```

Also run the one-time Ansible playbook in `k3sonhyperv` to configure k3s nodes to trust
the registry:

```powershell
# From D:\githubrepos\k3sonhyperv
powershell -ExecutionPolicy Bypass -File .\run-ansible.ps1 -Playbook install-local-registry.yml
```

## Quick Start

```powershell
# Deploy cert-manager, the in-cluster registry, MinIO, and Nessie
powershell -ExecutionPolicy Bypass -File .\run.ps1 up

# Verify all pods are running
powershell -ExecutionPolicy Bypass -File .\run.ps1 status
```

## Endpoints

| Service | URL | Notes |
|---------|-----|-------|
| Local Registry | http://k8s-node-1.local:5000 | Push images here for k3s to pull |
| MinIO Console | http://k8s-node-1.local:9001 | user: `micewriter` / `micewriter123` |
| MinIO S3 API | http://k8s-node-1.local:9000 | Use as `MINIO_URL` in the engine |
| Nessie API (v1) | http://k8s-node-1.local:19120/api/v1 | Nessie native API v1 |
| Nessie API (v2) | http://k8s-node-1.local:19120/api/v2 | Use as `iceberg.nessie-catalog.uri` in Trino |

The `iceberg` bucket is created automatically during the deployment process.

## Commands

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 up      # Install cert-manager + registry + MinIO + Nessie (idempotent)
powershell -ExecutionPolicy Bypass -File .\run.ps1 down    # Uninstall MinIO and Nessie Helm releases
powershell -ExecutionPolicy Bypass -File .\run.ps1 status  # Show pod status in micewriter-infra namespace
powershell -ExecutionPolicy Bypass -File .\run.ps1 test    # Run Iceberg CRUD integration tests via Trino
powershell -ExecutionPolicy Bypass -File .\run.ps1 clean   # Uninstall everything and purge the namespace (deletes PVCs)
```

`helm` is invoked inside a Docker container — no native tooling required on
the host beyond Docker Desktop. The kubeconfig is read from
`C:\Users\marko\source\repos\k3sonhyperv\kubeconfig` (update the path in `run.ps1` if different).

## What `up` installs

| Component | Why |
|-----------|-----|
| **cert-manager** | TLS certificates for cluster components that need them |
| **Local registry** (`registry:2`) | Image distribution: `docker push k8s-node-1.local:5000/<image>` |
| **MinIO** | S3-compatible object store for Parquet files |
| **Apache Nessie** | Iceberg REST Catalog for atomic table commits |

`up` does **not** install any engine pipelines — those are per-Iceberg-table releases of `charts/table-pipeline/` and are installed separately. See the chart [README](charts/table-pipeline/README.md) for the install command.

## Deploy a v2 engine pipeline

For each Iceberg table the sandbox or adopter app writes to:

```powershell
docker run --rm -i `
  -v "$HOME\.kube\config:/kubeconfig:ro" -e KUBECONFIG=/kubeconfig `
  -v "${PWD}:/workspace:ro" -w /workspace `
  alpine/helm:latest `
  upgrade --install engine-telemetry-events ./charts/table-pipeline `
    --namespace micewriter-infra `
    --set table=telemetry_events `
    --wait
```

Resulting Service: `engine-telemetry-events.micewriter-infra.svc:9090`. The SDK's default resolver template (`engine-{table}.micewriter.svc:9090`) reaches this with no per-table override.

## File Structure

```
micewriter-local-infra/
  run.ps1             # PowerShell entry point (up / down / status / clean)
  Makefile            # Alternative for Linux/Mac users
  registry/
    registry.yaml     # registry:2 Deployment + LoadBalancer Service
  minio/
    values.yaml       # Bitnami MinIO chart overrides
  nessie/
    values.yaml       # Project Nessie chart overrides
  charts/
    table-pipeline/   # v2 engine pipeline Helm chart (one release per Iceberg table)
```

## Notes

- Nessie uses an **in-memory** version store — all catalog state is lost on pod restart. This is intentional for local development. For persistence, set `versionStoreType: JDBC` in `nessie/values.yaml` and add a Postgres chart.
- MinIO persistence uses the k3s `local-path` storage class, so Parquet files survive pod restarts.
- The registry uses `emptyDir` storage — images must be re-pushed after a registry pod restart. This is intentional; images are rebuilt on each dev cycle anyway.
- Ingress is intentionally bypassed. `ServiceLB` (Klipper LoadBalancer) binds the ports directly to the node IPs, allowing native mDNS routing.
