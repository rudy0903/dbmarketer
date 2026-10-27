-- ==============================================================================
-- Project: Database Marketer (dbmarketer.com)
-- Component: GA4 BigQuery Production Schema & Marts
-- File: 05_schedule_hourly_sync.sql
-- Description: Complete guide, SQL caller, CLI commands, and Terraform config
--              for setting up the hourly automated execution of the routine
--              `ga4_marts.sp_hourly_ga4_sync`.
-- ==============================================================================

-- ==============================================================================
-- 1. THE SCHEDULED QUERY STATEMENT
-- ==============================================================================
-- This is the exact single line of SQL executed on every hourly trigger.
-- When passing NULL, the procedure resolves the default production analytics export.
-- If overriding the source dataset, supply 'project_id.analytics_property_id'.

CALL `ga4_marts.sp_hourly_ga4_sync`(NULL);

-- Example with explicit source dataset override:
-- CALL `ga4_marts.sp_hourly_ga4_sync`('my-gcp-project.analytics_312984571');


-- ==============================================================================
-- 2. SETUP METHOD A: BIGQUERY CONSOLE UI (STEP-BY-STEP)
-- ==============================================================================
/*
  Follow these steps in the Google Cloud Console:

  1. Open the BigQuery Studio SQL Editor:
     https://console.cloud.google.com/bigquery

  2. In the query editor tab, paste:
     CALL `your_project_id.ga4_marts.sp_hourly_ga4_sync`(NULL);

  3. Click the "Schedule" dropdown button in the query editor toolbar (above the SQL editor)
     and select "Create new scheduled query".

  4. In the side panel that opens, configure the following settings:
     -------------------------------------------------------------------------
     Field Name                Recommended Value
     -------------------------------------------------------------------------
     Name for scheduled query  ga4_marts_hourly_sync
     Repeats                   Hourly
     Starts                    Leave as default (starts immediately)
     Ends                      Never
     Dataset                   Leave blank (stored procedure writes internally)
     Destination table         Leave blank
     Location                  Select the region where your datasets reside (e.g. US or EU)
     Service Account           Default user account OR dedicated ETL Service Account
                               (needs roles/bigquery.dataEditor & roles/bigquery.jobUser)
     -------------------------------------------------------------------------

  5. Click "Save". BigQuery will now trigger the procedure at the top of every hour.
*/


-- ==============================================================================
-- 3. SETUP METHOD B: GOOGLE CLOUD CLI (ONE-LINER)
-- ==============================================================================
/*
  Run this bash command in your terminal or Google Cloud Shell:

  bq mk \
    --transfer_config \
    --project_id="YOUR_PROJECT_ID" \
    --data_source=scheduled_query \
    --display_name="GA4 Marts Hourly Sync" \
    --schedule="every 1 hours" \
    --location="US" \
    --params='{
      "query": "CALL `YOUR_PROJECT_ID.ga4_marts.sp_hourly_ga4_sync`(NULL);"
    }'

  ---------------------------------------------------------------------------
  PowerShell Equivalent (Windows):
  ---------------------------------------------------------------------------
  bq mk `
    --transfer_config `
    --project_id="YOUR_PROJECT_ID" `
    --data_source=scheduled_query `
    --display_name="GA4 Marts Hourly Sync" `
    --schedule="every 1 hours" `
    --location="US" `
    --params='{\"query\": \"CALL `YOUR_PROJECT_ID.ga4_marts.sp_hourly_ga4_sync`(NULL);\"}'
*/


-- ==============================================================================
-- 4. SETUP METHOD C: TERRAFORM (INFRASTRUCTURE-AS-CODE)
-- ==============================================================================
/*
  If your team provisions BigQuery via Terraform, add this resource:

  resource "google_bigquery_data_transfer_config" "ga4_hourly_sync" {
    display_name           = "GA4 Marts Hourly Sync"
    location               = "US"
    data_source_id         = "scheduled_query"
    schedule               = "every 1 hours"
    destination_dataset_id = "" # Stored procedure handles destination writes

    params = {
      query = "CALL `${var.project_id}.ga4_marts.sp_hourly_ga4_sync`(NULL);"
    }

    service_account_name = google_service_account.bq_etl_sa.email
  }
*/


-- ==============================================================================
-- 5. OPERATIONAL MONITORING: AUDIT WATERMARK TABLE
-- ==============================================================================
-- Use this query to inspect hourly runs, monitor execution status, and verify
-- that the procedure skipped naturally when yesterday's data was already loaded.

SELECT
  execution_timestamp,
  table_name,
  last_processed_date_est,
  rows_processed,
  execution_status,
  notes
FROM `ga4_marts.etl_watermark`
ORDER BY execution_timestamp DESC
LIMIT 50;

-- Filter for failures or alerts:
SELECT *
FROM `ga4_marts.etl_watermark`
WHERE execution_status = 'FAILED'
   OR (execution_status = 'SUCCESS' AND rows_processed = 0)
ORDER BY execution_timestamp DESC;
