#!/usr/bin/env bash
# ==============================================================================
# Database Marketer - GA4 BigQuery Production Schema Deployment
# File: deploy_all.sh
# Description: Automated Bash script to deploy datasets, routines, tables, and schedules.
# ==============================================================================

set -euo pipefail

PROJECT_ID="${1:-$(gcloud config get-value project 2>/dev/null || echo "")}"
LOCATION="${2:-US}"
SOURCE_DATASET="${3:-}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "Error: No active GCP Project specified. Pass as arg 1 or set via 'gcloud config set project <ID>'." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="$SCRIPT_DIR/../sql"

echo "============================================================"
echo " Database Marketer: GA4 BigQuery Schema Deployment"
echo " Target Project: $PROJECT_ID | Location: $LOCATION"
echo "============================================================"

echo ""
echo "[Step 1/4] Initializing Datasets..."
bq query --use_legacy_sql=false --project_id="$PROJECT_ID" --location="$LOCATION" < "$SQL_DIR/00_init_datasets.sql"

echo ""
echo "[Step 2/4] Deploying BigQuery Routines (UDFs, TVF, Stored Procedure)..."
bq query --use_legacy_sql=false --project_id="$PROJECT_ID" --location="$LOCATION" < "$SQL_DIR/01_create_all_routines.sql"

echo ""
echo "[Step 3/4] Creating Materialized Mart Tables..."
bq query --use_legacy_sql=false --project_id="$PROJECT_ID" --location="$LOCATION" < "$SQL_DIR/02_ddl_tables.sql"

echo ""
echo "[Step 4/4] Setting Up Hourly Scheduled Routine Call..."
PROC_CALL="CALL \`$PROJECT_ID.ga4_marts.sp_hourly_ga4_sync\`(NULL);"
if [[ -n "$SOURCE_DATASET" ]]; then
  PROC_CALL="CALL \`$PROJECT_ID.ga4_marts.sp_hourly_ga4_sync\`('$SOURCE_DATASET');"
fi

bq mk \
  --transfer_config \
  --project_id="$PROJECT_ID" \
  --data_source=scheduled_query \
  --display_name="GA4 Marts Hourly Sync" \
  --schedule="every 1 hours" \
  --location="$LOCATION" \
  --params="{\"query\": \"$PROC_CALL\"}" || true

echo ""
echo "============================================================"
echo " Deployment Complete! Marts and Hourly Sync are live."
echo "============================================================"
