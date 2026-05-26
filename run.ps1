<#
.SYNOPSIS
  Manage the micewriter local data lake on k3s.
.EXAMPLE
  .\run.ps1 up
  .\run.ps1 down
  .\run.ps1 clean
  .\run.ps1 status
#>
param([Parameter(Mandatory)][string]$Target)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Path to the kubeconfig produced by the k3sonhyperv Ansible playbook.
# Update this if your k3sonhyperv repo is in a different location.
$kubeconfig = "C:\Users\marko\source\repos\k3sonhyperv\kubeconfig"
if (-not (Test-Path $kubeconfig)) {
    Write-Error "kubeconfig not found at $kubeconfig - run install-k3s.yml first."
    exit 1
}

docker info > $null 2>&1
if ($LASTEXITCODE -ne 0) { Write-Error "Docker is not running."; exit 1 }

$namespace     = "micewriter-infra"
$certVersion   = "v1.15.1"
$minioRelease  = "micewriter-minio"
$nessieRelease = "micewriter-nessie"
$minioChart    = "oci://registry-1.docker.io/bitnamicharts/minio"
$minioVersion  = "17.0.21"
$nessieChart   = "nessie"
$nessieRepo    = "https://charts.projectnessie.org"
$nessieVersion = "0.69.0"

function Invoke-Kubectl {
    docker run --rm -i `
        -v "${kubeconfig}:/kubeconfig:ro" `
        -e KUBECONFIG=/kubeconfig `
        -v "${PSScriptRoot}:/workspace:ro" `
        -w /workspace `
        bitnami/kubectl:latest @args
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
        Invoke-Kubectl exec -n $namespace deployment/micewriter-minio -- sh -c "mc alias set local http://localhost:9000 micewriter micewriter123 && mc mb local/iceberg --ignore-existing"

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
        Write-Host "  Nessie REST   : http://k8s-node-1.local:19120/api/v1"
        Write-Host "  Iceberg REST  : http://k8s-node-1.local:19120/iceberg/v1"
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

    default { Write-Error "Unknown target '$Target'. Use: up | down | clean | status" }
}
