<#
.SYNOPSIS
  Run a smoke test against the local data lake to verify Iceberg CRUD operations via Trino.
#>

$ErrorActionPreference = "Stop"

Write-Host "Running Trino integration test..." -ForegroundColor Cyan

$sql = "CREATE SCHEMA IF NOT EXISTS iceberg.test_schema; CREATE TABLE IF NOT EXISTS iceberg.test_schema.test_table (id INT, name VARCHAR); INSERT INTO iceberg.test_schema.test_table VALUES (1, 'Integration'), (2, 'Test'); SELECT * FROM iceberg.test_schema.test_table; DROP TABLE iceberg.test_schema.test_table; DROP SCHEMA iceberg.test_schema;"

$coordinatorPod = kubectl get pod -l app.kubernetes.io/component=coordinator -n micewriter-infra -o jsonpath="{.items[0].metadata.name}"

if (-not $coordinatorPod) {
    Write-Error "Could not find Trino coordinator pod."
    exit 1
}

Write-Host "Executing SQL queries directly on $coordinatorPod..." -ForegroundColor Cyan

$ErrorActionPreference = "Continue"
# Execute the query directly inside the coordinator pod using the bundled Trino CLI
$output = kubectl exec $coordinatorPod -n micewriter-infra -- trino --execute "$sql" 2>&1
$exitCode = $LASTEXITCODE
$ErrorActionPreference = "Stop"

Write-Host "Test Output:" -ForegroundColor Cyan
Write-Host $output

if ($exitCode -eq 0) {
    Write-Host "Integration test passed! Data lake is fully functional." -ForegroundColor Green
    exit 0
} else {
    Write-Error "Integration test failed with exit code $exitCode"
    exit 1
}
