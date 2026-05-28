<#
.SYNOPSIS
  Run a smoke test against the local data lake to verify Iceberg CRUD operations via Trino.
#>

$ErrorActionPreference = "Continue"

Write-Host "Cluster networking is degraded (cannot route to VM IPs or stream logs). Running test strictly in-cluster and signaling via ConfigMap." -ForegroundColor Cyan

$rbac = @"
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: micewriter-infra
  name: test-configmap-creator
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["create", "get", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: test-create-configmaps
  namespace: micewriter-infra
subjects:
- kind: ServiceAccount
  name: default
  namespace: micewriter-infra
roleRef:
  kind: Role
  name: test-configmap-creator
  apiGroup: rbac.authorization.k8s.io
"@

Set-Content -Path "rbac.yaml" -Value $rbac
kubectl apply -f rbac.yaml | Out-Null
kubectl delete configmap test-result -n micewriter-infra --ignore-not-found | Out-Null
kubectl delete pod trino-test-client -n micewriter-infra --ignore-not-found | Out-Null

$sql = "CREATE SCHEMA IF NOT EXISTS iceberg.test_schema; CREATE TABLE IF NOT EXISTS iceberg.test_schema.test_table (id INT, name VARCHAR); INSERT INTO iceberg.test_schema.test_table VALUES (1, 'Integration'), (2, 'Test'); SELECT * FROM iceberg.test_schema.test_table; DROP TABLE iceberg.test_schema.test_table; DROP SCHEMA iceberg.test_schema;"

$trinoIp = kubectl get pod -l app.kubernetes.io/component=coordinator -n micewriter-infra -o jsonpath="{.items[0].status.podIP}"
if (-not $trinoIp) {
    Write-Error "Could not find Trino coordinator pod IP."
    exit 1
}

Write-Host "Trino coordinator pod IP: $trinoIp" -ForegroundColor Cyan

$podYaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: trino-test-client
  namespace: micewriter-infra
spec:
  restartPolicy: Never
  containers:
  - name: trino
    image: trinodb/trino:latest
    command: ["/bin/bash", "-c"]
    args:
    - |
      echo "Executing Trino test..." > /dev/termination-log
      trino --server ${trinoIp}:8080 --execute "$sql" >> /dev/termination-log 2>&1
      if [ `$? -eq 0 ]; then
        echo "STATUS:SUCCESS" >> /dev/termination-log
      else
        echo "STATUS:FAILED" >> /dev/termination-log
        exit 1
      fi
"@

Set-Content -Path "pod.yaml" -Value $podYaml
kubectl apply -f pod.yaml | Out-Null

Write-Host "Waiting for test result via termination log..." -ForegroundColor Cyan

$finalOutput = ""
for ($i = 0; $i -lt 30; $i++) {
    $phase = kubectl get pod trino-test-client -n micewriter-infra -o jsonpath='{.status.phase}' 2>$null
    if ($phase -eq "Succeeded" -or $phase -eq "Failed") {
        $finalOutput = kubectl get pod trino-test-client -n micewriter-infra -o jsonpath='{.status.containerStatuses[0].state.terminated.message}' 2>$null
        break
    }
    Start-Sleep -Seconds 3
}

if ($finalOutput) {
    Write-Host "Test Output:" -ForegroundColor Cyan
    Write-Host $finalOutput
}

kubectl delete pod trino-test-client -n micewriter-infra --ignore-not-found | Out-Null
Remove-Item -Path "rbac.yaml" -ErrorAction SilentlyContinue
Remove-Item -Path "pod.yaml" -ErrorAction SilentlyContinue

if ($finalOutput -match "STATUS:SUCCESS") {
    Write-Host "Integration test passed! Data lake is fully functional." -ForegroundColor Green
    exit 0
} else {
    Write-Error "Integration test failed or timed out."
    exit 1
}
