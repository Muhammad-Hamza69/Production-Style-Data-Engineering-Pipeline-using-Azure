#!/usr/bin/env bash
set -e

# Configuration
RESOURCE_GROUP="${RESOURCE_GROUP:-HAMZA-RESOURCE-GROUP}"
INGEST_JOB="${INGEST_JOB:-yt-pipeline-ingest}"
RAW_TRANSFORM_JOB="${RAW_TRANSFORM_JOB:-yt-pipeline-raw-transform}"
DBT_JOB="${DBT_JOB:-yt-pipeline-dbt}"

echo "===================================================="
echo " Starting YouTube Data Pipeline on Azure via CLI"
echo " Resource Group: ${RESOURCE_GROUP}"
echo "===================================================="

run_job() {
  local job_name="$1"
  echo ""
  echo "--> Triggering Job: ${job_name}..."
  
  EXEC_ID=$(az containerapp job start \
    --name "${job_name}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query name -o tsv)
    
  echo "    Execution ID: ${EXEC_ID}"
  echo "    Monitoring execution status..."

  while true; do
    STATUS=$(az containerapp job execution show \
      --name "${job_name}" \
      --resource-group "${RESOURCE_GROUP}" \
      --job-execution-name "${EXEC_ID}" \
      --query properties.status -o tsv 2>/dev/null || echo "Unknown")

    echo "    Current Status: ${STATUS}"
    
    if [ "${STATUS}" == "Succeeded" ]; then
      echo "✅ Job ${job_name} finished successfully!"
      break
    elif [ "${STATUS}" == "Failed" ]; then
      echo "❌ Job ${job_name} failed!"
      exit 1
    fi
    
    sleep 5
  done
}

# 1. Run Ingest Job
run_job "${INGEST_JOB}"

# 2. Run Raw Transform Job
run_job "${RAW_TRANSFORM_JOB}"

# 3. Run DBT Job
run_job "${DBT_JOB}"

echo ""
echo "===================================================="
echo "🎉 Pipeline Execution Completed Successfully!"
echo "===================================================="
