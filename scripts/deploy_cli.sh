#!/usr/bin/env bash
set -e

# Configuration
RESOURCE_GROUP="${RESOURCE_GROUP:-HAMZA-RESOURCE-GROUP}"
LOCATION="${LOCATION:-southcentralus}"
ACR_NAME="${ACR_NAME:-ytpipeline387f2fdeacr}"

echo "===================================================="
echo " Deploying / Updating YouTube Data Pipeline via Azure CLI"
echo " Resource Group: ${RESOURCE_GROUP}"
echo " Location:       ${LOCATION}"
echo " ACR Name:       ${ACR_NAME}"
echo "===================================================="

# 1. Build and Push Container Images to ACR
echo "--> Building & Pushing Container Images to ACR..."
az acr build --registry "${ACR_NAME}" --image yt-ingest:v1 ./jobs/ingest
az acr build --registry "${ACR_NAME}" --image yt-raw-transform:v1 ./jobs/raw_transform
az acr build --registry "${ACR_NAME}" --image yt-dbt:v1 ./dbt
az acr build --registry "${ACR_NAME}" --image yt-dashboard:v1 ./dashboard

echo "✅ Container Images Successfully Pushed to ACR!"
