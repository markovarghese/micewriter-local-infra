# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

**micewriter-local-infra** provisions a local data lake on a k3s cluster for the mIceWriter project. It deploys:
- **MinIO** — S3-compatible object store (Parquet files, persisted via PVC)
- **Apache Nessie** — Iceberg REST Catalog (in-memory, ephemeral by design)
- **cert-manager** — required for cluster components that need TLS certificates
- **Local Docker Registry** — in-cluster image registry for k3s to pull from

It also hosts [`charts/table-pipeline/`](charts/table-pipeline/) — the v2 engine pipeline Helm chart. One release per Iceberg table. Not installed by `up` (engine pipelines are deployed per-table, on demand). See the chart README for usage.

Neither `kubectl` nor `helm` need to be installed locally — the scripts run them inside Docker containers.

## Commands

### Deploy / Manage (Windows, PowerShell)

```powershell
.\run.ps1 up          # Deploy cert-manager, registry, MinIO, Nessie (idempotent)
.\run.ps1 down        # Uninstall MinIO + Nessie Helm releases (keeps namespace/PVCs)
.\run.ps1 status      # Show pod status in micewriter-infra namespace
.\run.ps1 clean       # Full teardown — uninstalls everything, purges namespace and PVCs
.\run.ps1 console     # Port-forward MinIO Console to localhost:9001
.\run.ps1 query-up    # Deploy Trino + Superset (run after up)
.\run.ps1 query-down  # Tear down Trino + Superset
```

If blocked by execution policy:
```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 up
```

### Deploy / Manage (Linux/Mac, Make)

```bash
make repo    # Add Nessie Helm repo
make up      # Full deployment
make down    # Uninstall releases
make status  # Check pod status
make clean   # Complete cleanup
```

## Architecture

### How `run.ps1` Works

Two wrapper functions — `Invoke-Kubectl` and `Invoke-Helm` — run `kubectl` and `helm` inside Docker containers, mounting `~/.kube/config` from the host. This is the key design decision that eliminates native tool dependencies.

Deployment order in `up`:
1. Install cert-manager from GitHub release URL
2. Create `micewriter-infra` namespace (idempotent via `--dry-run=client`)
3. Deploy in-cluster Docker registry (`registry:2` on `k8s-node-1`, `LoadBalancer` port 5000)
4. Helm upgrade/install MinIO (Bitnami chart)
5. Provision the `iceberg` bucket via `mc` CLI in a one-shot pod
6. Helm upgrade/install Nessie (Project Nessie chart)

### Network — ServiceLB, not Ingress

Services use k3s's built-in Klipper LoadBalancer to bind directly to node IPs. This enables mDNS routing to `k8s-node-1.local` without configuring an Ingress controller.

| Service | Endpoint |
|---|---|
| MinIO S3 API | `http://k8s-node-1.local:9000` |
| MinIO Console | `http://k8s-node-1.local:9001` (user: `micewriter` / `micewriter123`) |
| Nessie REST | `http://k8s-node-1.local:19120/api/v1` |
| Nessie Iceberg REST | `http://k8s-node-1.local:19120/iceberg/v1` |
| Local Registry | `http://k8s-node-1.local:5000` |
| Trino | `http://k8s-node-1.local:8080` (deployed by `query-up`) |
| Superset | `http://k8s-node-1.local:8088` (deployed by `query-up`, admin / admin) |

### Key Design Decisions

- **Nessie is in-memory** (`versionStoreType: IN_MEMORY` in `nessie/values.yaml`) — all catalog state is lost on pod restart. This is intentional for local dev.
- **Registry uses `emptyDir`** — images are ephemeral. Images must be pushed again after pod restarts.
- **MinIO PVC is persistent** — 20Gi via `local-path` provisioner; Parquet files survive restarts.
- **Superset PostgreSQL uses a PVC** (2Gi) — dashboards and query history persist across pod restarts. Redis uses `emptyDir` (ephemeral).

## Prerequisites

1. Docker Desktop running with insecure registry configured:
   ```json
   { "insecure-registries": ["k8s-node-1.local:5000"] }
   ```
2. k3s cluster running with kubeconfig at `~/.kube/config` (or `$env:KUBECONFIG`)
3. One-time Ansible setup from the `k3sonhyperv` repo to trust the local registry on k3s nodes:
   ```powershell
   .\run-ansible.ps1 -Playbook install-local-registry.yml
   ```
