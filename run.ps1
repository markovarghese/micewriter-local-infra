<#
.SYNOPSIS
  Manage the micewriter local data lake on k3s.
.EXAMPLE
  .\run.ps1 up          # Deploy core infra (cert-manager, registry, MinIO, Nessie)
  .\run.ps1 down        # Uninstall MinIO + Nessie (keeps namespace/PVCs)
  .\run.ps1 clean       # Full teardown including namespace and PVCs
  .\run.ps1 status      # Show pod status
  .\run.ps1 query-up    # Deploy Trino + Superset (run after up)
  .\run.ps1 query-down  # Tear down Trino + Superset
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
$certVersion   = "v1.20.2"
$minioRelease  = "micewriter-minio"
$nessieRelease = "micewriter-nessie"
$trinoRelease  = "trino"
$minioChart    = "oci://registry-1.docker.io/bitnamicharts/minio"
$minioVersion  = "17.0.21"
$nessieChart   = "nessie"
$nessieRepo    = "https://charts.projectnessie.org"
$nessieVersion = "0.107.6"
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
        $minioValues = Get-Content "$PSScriptRoot\minio\values.yaml"
        $rootUser = ($minioValues -match '^\s*rootUser:\s*(.*)')[0] -replace '^\s*rootUser:\s*(.*)', '$1'
        $rootPassword = ($minioValues -match '^\s*rootPassword:\s*(.*)')[0] -replace '^\s*rootPassword:\s*(.*)', '$1'

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

        Write-Host "Enabling MinIO native WebUI..."
        # The Bitnami chart hardcodes MINIO_BROWSER=off; this post-install env-set is the
        # only way to enable the legacy in-server UI. Side effect: kubectl-set claims field
        # ownership, which causes Server-Side Apply conflicts on later helm upgrades. If you
        # need to re-run `helm upgrade` directly (without going through run.ps1), first
        # `kubectl delete deployment micewriter-minio -n micewriter-infra` to release ownership.
        Invoke-Kubectl set env deployment/micewriter-minio MINIO_BROWSER=on -n micewriter-infra

        Write-Host "Provisioning MinIO iceberg bucket..."
        Invoke-Kubectl exec -n $namespace deployment/micewriter-minio "--" sh -c "mc alias set local http://localhost:9000 $rootUser $rootPassword && mc mb local/iceberg --ignore-existing"

        Write-Host "Creating nessie-s3-creds Secret..."
        Invoke-Kubectl create secret generic nessie-s3-creds `
            --from-literal=aws_access_key_id=$rootUser `
            --from-literal=aws_secret_access_key=$rootPassword `
            -n $namespace `
            --dry-run=client -o yaml > temp-secret.yaml
        Invoke-Kubectl apply -f temp-secret.yaml
        Remove-Item temp-secret.yaml -ErrorAction SilentlyContinue

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
        Write-Host "  MinIO console : http://k8s-node-1.local:9001  (user: $rootUser / $rootPassword)"
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


    "query-up" {
        Write-Host "Building Superset image with Trino driver..."
        docker build -t k8s-node-1.local:5000/superset:latest "$PSScriptRoot/superset"
        docker push k8s-node-1.local:5000/superset:latest

        Write-Host "Deploying Trino..."
        Invoke-Helm upgrade --install $trinoRelease trino `
            --repo $trinoRepo `
            --namespace $namespace `
            --version 1.42.2 `
            --values trino/values.yaml `
            --wait

        Write-Host "Deploying Superset (PostgreSQL, Redis, web, worker)..."
        Invoke-Kubectl apply -f superset/superset.yaml

        Write-Host ""
        Write-Host "Query stack is up."
        Write-Host "  Trino    : http://k8s-node-1.local:8080"
        Write-Host "  Superset : http://k8s-node-1.local:8088  (admin / admin)"
        Write-Host ""
        Write-Host "Add Trino in Superset (Settings > Database Connections > + Database > Trino):"
        Write-Host "  SQLAlchemy URI: trino://admin@trino.$namespace.svc.cluster.local:8080/iceberg"
    }

    "query-down" {
        Invoke-Helm uninstall $trinoRelease --namespace $namespace --ignore-not-found
        Invoke-Kubectl delete -f superset/superset.yaml --ignore-not-found
    }

    "test" {
        & "$PSScriptRoot\test.ps1"
    }

    default { Write-Error "Unknown target '$Target'. Use: up | down | clean | status | query-up | query-down | test" }
}
