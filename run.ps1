<#
.SYNOPSIS
  Manage the micewriter local data lake on k3s.
.EXAMPLE
  .\run.ps1 up          # Deploy core infra (cert-manager, registry, MinIO, Nessie)
  .\run.ps1 down        # Uninstall MinIO + Nessie (keeps namespace/PVCs)
  .\run.ps1 clean       # Full teardown including namespace and PVCs
  .\run.ps1 status      # Show pod status
  .\run.ps1 console     # Port-forward MinIO console to localhost:9001
  .\run.ps1 query-up    # Deploy Trino + Querybook (run after up)
  .\run.ps1 query-down  # Tear down Trino + Querybook
  .\run.ps1 test        # Run Iceberg CRUD integration tests via Trino
#>
param([Parameter(Mandatory)][string]$Target)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:KUBECONFIG) {
    $kubeconfig = $env:KUBECONFIG
} else {
    $kubeconfig = "$HOME\.kube\config"
}
if (-not (Test-Path $kubeconfig)) {
    Write-Error "kubeconfig not found at $kubeconfig"
    exit 1
}

$namespace     = "micewriter-infra"
$certVersion   = "v1.15.1"
$minioRelease  = "micewriter-minio"
$nessieRelease = "micewriter-nessie"
$trinoRelease  = "trino"
$minioChart    = "oci://registry-1.docker.io/bitnamicharts/minio"
$minioVersion  = "17.0.21"
$nessieChart   = "nessie"
$nessieRepo    = "https://charts.projectnessie.org"
$nessieVersion = "0.69.0"
$trinoRepo     = "https://trinodb.github.io/charts"

function Invoke-Kubectl {
    kubectl --kubeconfig $kubeconfig @args
}

function Invoke-Helm {
    docker run --rm -i `
        -v "${kubeconfig}:/kubeconfig:ro" `
        -e KUBECONFIG=/kubeconfig `
        -v "${PSScriptRoot}:/workspace:ro" `
        -w /workspace `
        alpine/helm:latest @args
}

switch ($Target) {
    "up" {
        Write-Host "Installing cert-manager $certVersion..."
        Invoke-Kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/$certVersion/cert-manager.yaml"
        Invoke-Kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=120s

        Write-Host "Deploying in-cluster registry..."
        Invoke-Kubectl create namespace $namespace --dry-run=client -o yaml > temp-ns.yaml
        Invoke-Kubectl apply -f temp-ns.yaml
        Remove-Item temp-ns.yaml -ErrorAction SilentlyContinue
        Invoke-Kubectl apply -f registry/registry.yaml
        Invoke-Kubectl rollout status deployment/registry -n $namespace --timeout=120s

        Write-Host "Deploying MinIO..."
        Invoke-Helm upgrade --install $minioRelease $minioChart `
            --namespace $namespace --create-namespace `
            --version $minioVersion `
            --values minio/values.yaml `
            --wait

        Write-Host "Provisioning MinIO iceberg bucket..."
        Invoke-Kubectl exec -n $namespace deployment/micewriter-minio "--" sh -c "mc alias set local http://localhost:9000 micewriter micewriter123 && mc mb local/iceberg --ignore-existing"

        Write-Host "Deploying Nessie..."
        Invoke-Helm upgrade --install $nessieRelease $nessieChart `
            --repo $nessieRepo `
            --namespace $namespace --create-namespace `
            --version $nessieVersion `
            --values nessie/values.yaml `
            --wait

        Write-Host ""
        Write-Host "Local data lake is up."
        Write-Host "  Registry      : http://k8s-node-1.local:5000"
        Write-Host "  MinIO console : http://k8s-node-1.local:9001  (user: micewriter / micewriter123)"
        Write-Host "  MinIO S3 API  : http://k8s-node-1.local:9000"
        Write-Host "  Nessie API v1 : http://k8s-node-1.local:19120/api/v1"
        Write-Host "  Nessie API v2 : http://k8s-node-1.local:19120/api/v2"
    }

    "down" {
        Invoke-Helm uninstall $nessieRelease --namespace $namespace --ignore-not-found
        Invoke-Helm uninstall $minioRelease  --namespace $namespace --ignore-not-found
    }

    "clean" {
        & "$PSScriptRoot\run.ps1" down
        Invoke-Kubectl delete -f registry/registry.yaml --ignore-not-found
        Invoke-Kubectl delete namespace $namespace --ignore-not-found
    }

    "status" {
        Invoke-Kubectl get pods -n $namespace -o wide
    }

    "console" {
        Write-Host "Forwarding MinIO Console to http://localhost:9001 (Press Ctrl+C to stop)" -ForegroundColor Green
        try {
            while ($true) {
                kubectl --kubeconfig $kubeconfig port-forward svc/micewriter-minio 9001:9001 --address 0.0.0.0 -n micewriter-infra
                Start-Sleep -Milliseconds 500
            }
        } catch {
            Write-Host "Stopped MinIO console."
        }
    }

    "query-up" {
        Write-Host "Deploying Trino..."
        Invoke-Helm upgrade --install $trinoRelease trino `
            --repo $trinoRepo `
            --namespace $namespace `
            --values trino/values.yaml `
            --wait

        Write-Host "Deploying Querybook (MySQL, Redis, web, worker)..."
        Invoke-Kubectl apply -f querybook/querybook.yaml

        Write-Host ""
        Write-Host "Query stack is up."
        Write-Host "  Trino         : http://k8s-node-1.local:8080"
        Write-Host "  Querybook     : http://k8s-node-1.local:10001"
        Write-Host ""
        Write-Host "Register Trino in Querybook admin UI (/admin/query_engine/):"
        Write-Host "  Language: trino  |  Host: trino.$namespace.svc.cluster.local  |  Port: 8080  |  Catalog: iceberg"
    }

    "query-down" {
        Invoke-Helm uninstall $trinoRelease --namespace $namespace --ignore-not-found
        Invoke-Kubectl delete -f querybook/querybook.yaml --ignore-not-found
    }

    "test" {
        & "$PSScriptRoot\test.ps1"
    }

    default { Write-Error "Unknown target '$Target'. Use: up | down | clean | status | console | query-up | query-down | test" }
}
