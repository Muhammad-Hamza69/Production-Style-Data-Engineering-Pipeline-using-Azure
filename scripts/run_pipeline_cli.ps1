# PowerShell script to trigger and monitor YouTube data pipeline jobs on Azure via CLI

$ResourceGroup = "HAMZA-RESOURCE-GROUP"
$IngestJob = "yt-pipeline-ingest"
$RawTransformJob = "yt-pipeline-raw-transform"
$DbtJob = "yt-pipeline-dbt"

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " Starting YouTube Data Pipeline on Azure via CLI" -ForegroundColor Cyan
Write-Host " Resource Group: $ResourceGroup" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

function Run-AzJob {
    param (
        [string]$JobName
    )
    
    Write-Host "`n--> Triggering Job: $JobName..." -ForegroundColor Yellow
    
    $execId = az containerapp job start `
        --name $JobName `
        --resource-group $ResourceGroup `
        --query name -o tsv

    Write-Host "    Execution ID: $execId"
    Write-Host "    Monitoring execution status..."

    while ($true) {
        $status = az containerapp job execution show `
            --name $JobName `
            --resource-group $ResourceGroup `
            --job-execution-name $execId `
            --query properties.status -o tsv 2>$null

        Write-Host "    Current Status: $status"

        if ($status -eq "Succeeded") {
            Write-Host "✅ Job $JobName finished successfully!" -ForegroundColor Green
            break
        }
        elseif ($status -eq "Failed") {
            Write-Host "❌ Job $JobName failed!" -ForegroundColor Red
            exit 1
        }

        Start-Sleep -Seconds 5
    }
}

# 1. Run Ingest Job
Run-AzJob -JobName $IngestJob

# 2. Run Raw Transform Job
Run-AzJob -JobName $RawTransformJob

# 3. Run DBT Job
Run-AzJob -JobName $DbtJob

Write-Host "`n====================================================" -ForegroundColor Cyan
Write-Host "🎉 Pipeline Execution Completed Successfully!" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
