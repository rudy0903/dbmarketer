# ==============================================================================
# Database Marketer - GA4 BigQuery Production Schema Deployment
# File: deploy_all.ps1
# Description: Automated PowerShell script to deploy all BigQuery datasets,
#              routines (UDFs, TVF, Stored Procedure), tables, and scheduled sync.
# ==============================================================================

param(
  [Parameter(Mandatory=$false)]
  [string]$ProjectId,

  [Parameter(Mandatory=$false)]
  [string]$Location = "US",

  [Parameter(Mandatory=$false)]
  [string]$SourceDataset = ""
)

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Database Marketer: GA4 BigQuery Schema Deployment" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# 1. Resolve Project ID
if (-not $ProjectId) {
  $ProjectId = (gcloud config get-value project 2>$null)
  if (-not $ProjectId) {
    Write-Error "ERROR: No active GCP project found. Provide -ProjectId or run 'gcloud config set project <ID>'."
    exit 1
  }
}
Write-Host "Target GCP Project: $ProjectId" -ForegroundColor Green
Write-Host "Target Region:      $Location" -ForegroundColor Green

# 2. Step 0: Initialize Datasets
Write-Host "`n[Step 1/4] Initializing BigQuery Datasets (ga4_marts, ga4_utils, ga4_staging)..." -ForegroundColor Yellow
bq query --use_legacy_sql=false --project_id="$ProjectId" --location="$Location" < "$PSScriptRoot\..\sql\00_init_datasets.sql"
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to initialize datasets"; exit 1 }
Write-Host "✓ Datasets initialized." -ForegroundColor Green

# 3. Step 1: Deploy All Routines (UDFs, TVF, and Stored Procedure)
Write-Host "`n[Step 2/4] Deploying BigQuery Routines (9 Scalar UDFs + 1 TVF + Stored Procedure)..." -ForegroundColor Yellow
bq query --use_legacy_sql=false --project_id="$ProjectId" --location="$Location" < "$PSScriptRoot\..\sql\01_create_all_routines.sql"
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to deploy routines"; exit 1 }
Write-Host "✓ All routines created successfully." -ForegroundColor Green

# 4. Step 2: Create Materialized Mart Tables
Write-Host "`n[Step 3/4] Creating Materialized Mart Tables (Partitioned & Clustered)..." -ForegroundColor Yellow
bq query --use_legacy_sql=false --project_id="$ProjectId" --location="$Location" < "$PSScriptRoot\..\sql\02_ddl_tables.sql"
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create mart tables"; exit 1 }
Write-Host "✓ Mart tables created successfully." -ForegroundColor Green

# 5. Step 3: Setup Scheduled Query
Write-Host "`n[Step 4/4] Setting up Hourly Scheduled Routine Call..." -ForegroundColor Yellow
$procCall = "CALL \`$ProjectId.ga4_marts.sp_hourly_ga4_sync\`(NULL);"
if ($SourceDataset) {
  $procCall = "CALL \`$ProjectId.ga4_marts.sp_hourly_ga4_sync\`('$SourceDataset');"
}

Write-Host "To create the hourly scheduled query via bq CLI, execute:" -ForegroundColor Cyan
Write-Host "bq mk --transfer_config --project_id=$ProjectId --data_source=scheduled_query --display_name='GA4 Marts Hourly Sync' --schedule='every 1 hours' --location=$Location --params='{\`"query\`\": \`"$procCall\`\"}'" -ForegroundColor Gray

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " Deployment Complete!" -ForegroundColor Green
Write-Host " Next step: verify runs via: SELECT * FROM \`$ProjectId.ga4_marts.etl_watermark\`" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
