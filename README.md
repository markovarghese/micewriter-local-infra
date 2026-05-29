# micewriter-local-infra
> Part of the [mIceWriter Ingestion Ecosystem](../micewriter-hub/README.md)

Local data lake simulator: deploys **MinIO** (S3-compatible object store) and **Apache Nessie** (Iceberg REST Catalog) onto a k3s cluster via Helm.

## Prerequisites

| Tool | Purpose |
|------|---------|
| Docker Desktop | Runs `helm` via containers — no native install needed |

Before running `.\run.ps1 up` for the first time, add the local registry to Docker Desktop's
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
.\run-ansible.ps1 -Playbook install-local-registry.yml
```

## Quick Start

> **Note**: If PowerShell blocks the script with an execution policy error, prefix your commands with `powershell -ExecutionPolicy Bypass -File` (e.g. `powershell -ExecutionPolicy Bypass -File .\run.ps1 up`).

```powershell
# Deploy cert-manager, the in-cluster registry, MinIO, and Nessie
.\run.ps1 up

# Verify all pods are running
.\run.ps1 status
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
.\run.ps1 up      # Install cert-manager + registry + MinIO + Nessie (idempotent)
.\run.ps1 down    # Uninstall MinIO and Nessie Helm releases
.\run.ps1 status  # Show pod status in micewriter-infra namespace
.\run.ps1 test    # Run Iceberg CRUD integration tests via Trino
.\run.ps1 clean   # Uninstall everything and purge the namespace (deletes PVCs)
```

`helm` is invoked inside a Docker container — no native tooling required on
the host beyond Docker Desktop. The kubeconfig is read from
`C:\Users\marko\source\repos\k3sonhyperv\kubeconfig` (update the path in `run.ps1` if different).

## What `up` installs

| Component | Why |
|-----------|-----|
| **cert-manager** | Required by `micewriter-k8s-injector` for TLS webhook certificates |
| **Local registry** (`registry:2`) | Image distribution: `docker push k8s-node-1.local:5000/<image>` |
| **MinIO** | S3-compatible object store for Parquet files |
| **Apache Nessie** | Iceberg REST Catalog for atomic table commits |

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
```

## Notes

- Nessie uses an **in-memory** version store — all catalog state is lost on pod restart. This is intentional for local development. For persistence, set `versionStoreType: JDBC` in `nessie/values.yaml` and add a Postgres chart.
- MinIO persistence uses the k3s `local-path` storage class, so Parquet files survive pod restarts.
- The registry uses `emptyDir` storage — images must be re-pushed after a registry pod restart. This is intentional; images are rebuilt on each dev cycle anyway.
- Ingress is intentionally bypassed. `ServiceLB` (Klipper LoadBalancer) binds the ports directly to the node IPs, allowing native mDNS routing.
