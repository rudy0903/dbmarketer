<div align="center">

# ⚡ GA4 BigQuery Production Schema & Analytics Marts
### *The Battle-Tested, Pure-BigQuery SQL Architecture for High-Volume Ecommerce & Lead Gen*

[![Database Marketer](https://img.shields.io/badge/Maintained%20By-dbmarketer.com-blue?style=for-the-badge&logo=googlecloud)](https://dbmarketer.com)
[![BigQuery](https://img.shields.io/badge/Engine-Google%20BigQuery%20SQL-4285F4?style=for-the-badge&logo=googlebigquery)](https://cloud.google.com/bigquery)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg?style=for-the-badge)](LICENSE)
[![Live Playbook](https://img.shields.io/badge/Read%20Live%20Playbook-dbmarketer.com-blue?style=for-the-badge&logo=googlecloud)](https://dbmarketer.com/playbooks/ga4-bigquery-schema)

**A production-tested, pure-BigQuery SQL data modeling framework that converts raw events_* tables into date-partitioned session and ecommerce marts (`fct_ga4_sessions`, `fct_ga4_transactions`). Features 10 scalar UDFs, automated hourly set-based syncs, 0/1 integer goal flags, and full Google Consent Mode v2 retention with zero external orchestrator dependencies.**

[Read Live Playbook on dbmarketer.com](https://dbmarketer.com/playbooks/ga4-bigquery-schema) • [Architecture Deep Dive (Markdown)](ARTICLE.md) • [SQL Source Code](sql/) • [JSON Schemas](schemas/) • [Analytical Queries](sql/04_analytical_queries.sql)

---

</div>

## 📌 Executive Overview

Querying the raw Google Analytics 4 (GA4) BigQuery export (`events_*`) directly in production is notoriously painful and expensive:
1. **Repeated Array Unnesting:** Massive record scanning costs and complex `UNNEST(event_params)` spaghetti SQL.
2. **The "Lookback Guessing Game":** Blindly re-running multi-day rolling `MERGE` queries 24 times a day wastes cloud budget and causes concurrency locks.
3. **Attribution Fragmentation:** Inconsistent UTM casing (`Facebook` vs `facebook`) splits traffic and throws ad dollars into `(Unassigned)`.
4. **Decentralized Channel Definitions:** Different departments and dashboards copy-paste disparate `CASE WHEN` logic, resulting in conflicting numbers across BI reports.
5. **The Trailing Slash Trap:** Inconsistent landing URLs (`/partners/acme/` vs `/partners/acme`) break fragile string-matching filters.
6. **The Timezone Midnight Split:** `event_timestamp` is **UTC microseconds**, while `event_date` is keyed to your **GA4 Admin Property Timezone**. Blindly casting UTC timestamps splits evening US sessions across calendar days (e.g., 9:30 PM EDT in New York becomes the next day in UTC).
7. **Consent Mode v2 Data Loss:** Naive queries filtering on `user_pseudo_id IS NOT NULL` discard an estimated **20% to 40%** (illustrative benchmark based on EEA unconsented traffic rates) of traffic from unconsented EU/US visitors.

## 🚀 The Dual-Set Architecture

### Set 1: The Dynamic Parameterized Query Layer
- **Persistent Scalar UDFs:** Fast, type-safe unnesting (`fn_extract_param_string`, `fn_extract_param_int`, `fn_extract_param_float`, `fn_clean_utm`).
- **URL Path Normalization:** `fn_normalize_url_path(url)` strips query strings, fragments, and trailing slashes so `/partners/acme/` and `/partners/acme` match identically.
- **Centralized Marketing Channel UDF:** `fn_map_marketing_channel(source, medium, campaign, referrer, landing_page_path)` consolidates all channel rules into a single maintainable function.
- **Parameterized Table-Valued Function (TVF):** `tvf_get_ga4_events_range('20261001', '20261015')` lets analytics engineers slice, filter, and inspect raw event data across any date window without building permanent tables or paying for full partition scans.

### Set 2: Materialized Production Marts
Six physical tables in `ga4_marts` (four partitioned and clustered analytical marts plus two orchestration state tables) populated by a set-based hourly stored procedure:
1. `fct_ga4_sessions` (47 columns): Session-grain table featuring **daily Eastern Time date partitioning (`PARTITION BY session_date_est`)**, multi-property clustering (`CLUSTER BY source_dataset_id, marketing_channel, user_pseudo_id, session_id`), **binary 0/1 integer goal & engagement flags** (`is_engaged_session`, `has_purchase`, etc.), full 9-parameter UTM coverage, UTC epoch bounds (`session_start_ts`, `session_end_ts`), and three-state consent mode tracking.
2. `fct_ga4_transactions` (29 columns): Canonical order-grain table selecting the earliest observed `purchase` event per `(source_dataset_id, transaction_id)` (`ORDER BY event_timestamp ASC, session_key ASC, stable_event_tiebreaker ASC`), storing both UTC `transaction_timestamp` and Eastern Time dates, revenue, tax, shipping, coupon codes, session attribution, and 9 duplicate-event diagnostic columns.
3. `fct_ga4_transaction_products` (17 columns): Line-item product grain table extracted from the canonical purchase event with deterministic `transaction_line_key`, 0-based `item_offset`, SKUs, categories (`item_category`, `item_category_2`, `item_category_3`), prices, quantities, and item revenues.
4. `fct_ga4_cart_events` (16 columns): Shopping action stream (`view_item`, `add_to_cart`, `remove_from_cart`, `view_cart`, `begin_checkout`) keyed by a collision-free deterministic surrogate key (`cart_event_key`).
5. `etl_watermark` & `etl_pipeline_locks`: Per-table, per-property high-water mark audit tracking and atomic single-writer concurrency locking.

---

## ⚙️ Metadata-Driven Hourly Ingestion

The stored procedure [`ga4_marts.sp_hourly_ga4_sync`](sql/03_procedure_hourly_sync.sql) replaces arbitrary rolling lookbacks and slow procedural loops with a **metadata-driven reconciliation lookback engine**:

```mermaid
sequenceDiagram
    autonumber
    actor Cron as BigQuery Hourly Schedule
    participant Proc as sp_hourly_ga4_sync
    participant Meta as source_dataset.__TABLES__
    participant Raw as events_* (Wildcard Shards)
    participant Marts as fct_ga4_sessions

    Cron->>Proc: Run Hourly Ingestion
    Proc->>Proc: Read last_watermark_ts from etl_watermark
    Proc->>Meta: SELECT table_id WHERE TIMESTAMP_MILLIS(last_modified_time) > watermark
    
    alt Zero Shards Modified (v_tables_to_sync is EMPTY)
        Note over Proc: No new or revised tables delivered since last run
        Proc->>Proc: Log SKIPPED_UP_TO_DATE in etl_watermark
        Proc-->>Cron: Natural Exit (< 1 sec, 0 Bytes Scanned)
    else Modified Shards Detected (Fresh Delivery or Late Bundles)
        Note over Proc,Raw: SINGLE Set-Based Wildcard Query
        Proc->>Raw: Extract WHERE _TABLE_SUFFIX IN UNNEST(v_scan_suffixes)
        Proc->>Proc: Convert UTC to EST/EDT, clean UTMs, map channel, compute 0/1 goals
        Proc->>Marts: BEGIN TRANSACTION: DELETE & INSERT affected partitions
        Proc->>Proc: Update watermark timestamp to MAX(last_modified_time)
        Proc-->>Cron: Ingestion Complete
    end
```

### Key Behavioral Guarantees:
1. **Atomic Single-Writer Concurrency Lock (`etl_pipeline_locks`):** Acquires a 2-hour TTL lock via an atomic `MERGE` statement so overlapping scheduled runs exit cleanly (`SKIPPED_CONCURRENT_LOCK`) without colliding.
2. **Zero-Byte Metadata Inspection:** The pipeline checks `source_dataset.__TABLES__` against the minimum watermark across all four destination marts (`v_min_watermark_ts`). Querying `__TABLES__` scans **0 bytes** and runs in sub-seconds.
3. **Two-Pass Cross-Midnight & Cross-Partition Closure:** Pass 1 discovers all candidate `session_key` and `transaction_id` values in the modified shards, expands the scan window by `{-1, 0, +1}` calendar days around every affected session and transaction date, and checks whether any candidate `transaction_id` already exists in `fct_ga4_transactions` on an earlier partition date—unioning both its historical `transaction_date_est` and owning `session_date_est` into `v_target_partition_dates`.
4. **Canonical Earliest-Timestamp Purchase Selection (`temp_canonical_purchases`):** Raw `purchase` events are deduplicated per `(source_dataset_id, transaction_id)` strictly by `ORDER BY event_timestamp ASC, session_key ASC, stable_event_tiebreaker ASC`, preserving the earliest observed purchase fire's attributes and item array while recording 9 duplicate-event diagnostic columns across all observed fires.
5. **Atomic Partition Replacement:** Modified date partitions (`v_target_partition_dates`) across all four marts are atomically deleted and re-materialized within a single transaction, eliminating duplicate sessions and orphan transactions.

---

## 🎯 Centralized Channel Mapping via UDF

Marketing channel grouping rules often diverge across dashboards, dbt models, and ad-hoc analyst scripts. Our framework solves this by establishing **one canonical function**:

```sql
ga4_utils.fn_map_marketing_channel(
  utm_source, 
  utm_medium, 
  utm_campaign, 
  page_referrer, 
  landing_page_path
)
```

### Key Capabilities:
1. **Landing-Page-Driven Channels:** Defines channels based on landing page path alone (e.g. `/partners/*` or `/creators/*`), ensuring un-tagged partner or influencer visits are properly categorized.
2. **Elevated Partner Referrals:** Differentiates high-value strategic alliances from generic web referrals. If a referrer domain is `partnerportal.com` or the landing page is `/partners/enterprise`, it is classified as **"Strategic Partnerships"** rather than dumping it into "Referral".
3. **Trailing Slash Resilience:** `fn_normalize_url_path` cleans `/partners/xyz/` -> `/partners/xyz` before channel evaluation.

### ⚖️ The Architectural Trade-Off: Pre-Materialization vs. Query-Time Execution

| Approach | Where It Runs | Advantages | Disadvantages & Operational Nuance |
| :--- | :--- | :--- | :--- |
| **Pre-Materialized Column** *(Implemented in `fct_ga4_sessions`)* | Hourly Stored Procedure | **Zero query-time CPU cost.** Instant BI rendering. Enables partition and cluster pruning (`WHERE marketing_channel = 'Paid Social'`). | **Rule changes require retroactive updates:** If you change the channel mapping UDF, existing rows retain old labels. You must run an `UPDATE` on the date partition to backfill. |
| **Query-Time Dynamic UDF** | On-the-fly in `SELECT` or `VIEW` | **Instant rule updates:** Changing the UDF immediately updates all downstream views with zero backfilling. | **High compute cost:** BigQuery executes multi-branch regex on millions of rows on every dashboard load, increasing query latency and slot consumption. |

---

## 🎯 The Secret Weapon: 0/1 Integer Goal Flags

In `fct_ga4_sessions`, business goals are modeled as strict `INT64` binary flags:
- `has_view_item` (0 or 1)
- `has_add_to_cart` (0 or 1)
- `has_checkout` (0 or 1)
- `has_purchase` (0 or 1)
- `has_newsletter_signup` (0 or 1)

### Why 0/1 Integers Change Everything:
| Metric Need | Traditional Boolean / Raw Export | dbmarketer 0/1 Schema |
| :--- | :--- | :--- |
| **Total Conversions** | `COUNT(DISTINCT IF(event_name='purchase', session_id, NULL))` | `SUM(has_purchase)` |
| **Conversion Rate (CVR)** | `COUNT(DISTINCT purchase_session) / COUNT(DISTINCT session)` | `AVG(has_purchase) * 100` |
| **Multi-Goal Summary** | Multi-pass subqueries with joins | Single-pass `SUM()` and `AVG()` |
| **BI Tool Performance** | Sluggish computed fields; memory exhaustion | Instant column vector aggregation |

```sql
-- Single-pass Funnel Drop-off and Rates by Channel:
SELECT
  marketing_channel,
  COUNT(1) AS sessions,
  SUM(has_add_to_cart) AS cart_adds,
  SUM(has_purchase) AS purchases,
  ROUND(AVG(has_add_to_cart) * 100, 2) AS cart_add_rate_pct,
  ROUND(AVG(has_purchase) * 100, 2) AS session_cvr_pct,
  ROUND(SUM(total_purchase_revenue), 2) AS revenue
FROM `ga4_marts.fct_ga4_sessions`
WHERE session_date_est >= DATE_SUB(CURRENT_DATE('America/New_York'), INTERVAL 30 DAY)
GROUP BY marketing_channel
ORDER BY revenue DESC;
```

---

## 📅 Date Partitioning & Clustering Strategy

`fct_ga4_sessions` enforces:
1. **`PARTITION BY session_date_est`**: Daily date partitions keyed to the Eastern Time business day. Querying `WHERE session_date_est >= '2026-10-01'` prunes all earlier partitions completely from memory.
2. **`CLUSTER BY source_dataset_id, marketing_channel, user_pseudo_id, session_id`**: Sorts and colocates rows by marketing channel, user, and session within each daily partition. Filtering on `WHERE marketing_channel = 'Strategic Partnerships'` reads only the exact storage blocks matching that channel.

---

## 🛡️ Consent Mode v2 & Unconsented User Retention

Under Google Consent Mode v2, visitors rejecting analytics storage emit cookieless pings (`privacy_info.analytics_storage = 'NO'`). In these pings, `user_pseudo_id` and `session_id` are withheld or null. Naively filtering out unconsented rows discards an estimated **20% to 40%** of site traffic in privacy-regulated markets.

However, an event-timestamp hash preserves event volume and raw pings, but does not reconstruct multi-page user sessions. Our framework resolves this by enforcing **explicit traffic classification**:

```sql
-- Three-state traffic classification for cookied sessions vs. stateless pings
CASE
  WHEN user_pseudo_id IS NOT NULL AND raw_session_id IS NOT NULL THEN 'COOKIED_SESSION'
  WHEN analytics_storage = 'NO' THEN 'CONSENT_DENIED_PING'
  ELSE 'UNIDENTIFIED_PING'
END AS traffic_type,

-- Cookied session key vs. collision-free stateless ping key (paired with source_dataset_id)
COALESCE(
  IF(user_pseudo_id IS NOT NULL AND raw_session_id IS NOT NULL,
    CONCAT(user_pseudo_id, '.', CAST(raw_session_id AS STRING)),
    NULL
  ),
  CONCAT('ping.', event_date, '.', CAST(FARM_FINGERPRINT(CONCAT(CAST(event_timestamp AS STRING), '|', COALESCE(event_name, ''), '|', COALESCE(page_location, ''), '|', COALESCE(user_pseudo_id, 'anon'), '|', COALESCE(geo.country, ''))) AS STRING))
) AS session_key,

-- session_id is preserved for cookied sessions, NULL for cookieless pings
CASE WHEN user_pseudo_id IS NOT NULL AND raw_session_id IS NOT NULL THEN raw_session_id ELSE NULL END AS session_id
```

This ensures analysts can query `traffic_type = 'COOKIED_SESSION'` for session-level journey analytics, while preserving total macro traffic and interaction volume.

---

## 📂 Repository File Tree

```
ga4-bigquery-schema/
├── README.md                           # Open-source overview & documentation
├── ARTICLE.md                          # In-depth technical guide & whitepaper
├── ARTICLE.html                        # Executive standalone HTML document
├── LICENSE                             # Apache 2.0 License
├── scripts/                            # Turnkey deployment automation scripts
│   ├── deploy_all.sh                   # Bash deployment script (Mac / Linux / Cloud Shell)
│   └── deploy_all.ps1                  # PowerShell deployment script (Windows)
├── schemas/                            # BigQuery JSON Schema files
│   ├── fct_ga4_sessions.schema.json
│   ├── fct_ga4_transactions.schema.json
│   ├── fct_ga4_transaction_products.schema.json
│   └── fct_ga4_cart_events.schema.json
└── sql/                                # Production SQL DDL, UDFs, & Procedures
    ├── 00_init_datasets.sql            # Dataset creation (ga4_marts, ga4_utils, ga4_staging)
    ├── 01_create_all_routines.sql      # ALL-IN-ONE: Deploys all 12 BigQuery Routines (10 UDFs + 1 TVF + Procedure)
    ├── 01_udfs.sql                     # Modular: Scalar UDFs, Channel Mapping, & TVF (Set 1)
    ├── 02_ddl_tables.sql               # Date-Partitioned & Clustered Materialized Marts (Set 2)
    ├── 03_procedure_hourly_sync.sql    # Modular: Set-Based Wildcard Procedure (sp_hourly_ga4_sync)
    ├── 04_analytical_queries.sql       # High-performance business queries & partition updates
    ├── 05_schedule_hourly_sync.sql     # Hourly scheduling guide, bq CLI one-liner & Terraform config
    ├── 06_validation_assertions.sql    # 7 automated post-deployment reconciliation ASSERT checks
    └── 07_acceptance_test_fixtures.sql # Self-contained synthetic GA4 acceptance test harness
```

---

## 🛠️ Deployment & Routine Setup Guide

### Option 1: Turnkey Automated Deployment (1 Command)

If you have the Google Cloud CLI (`gcloud` / `bq`) installed:

**Linux / macOS / Cloud Shell:**
```bash
chmod +x scripts/deploy_all.sh
./scripts/deploy_all.sh "your-gcp-project-id" "US"
```

**Windows (PowerShell):**
```powershell
.\scripts\deploy_all.ps1 -ProjectId "your-gcp-project-id" -Location "US"
```

---

### Option 2: Step-by-Step BigQuery Console Setup

#### Step 1: Initialize Datasets
Open [BigQuery Studio](https://console.cloud.google.com/bigquery) and run [sql/00_init_datasets.sql](sql/00_init_datasets.sql) to create `ga4_marts`, `ga4_utils`, and `ga4_staging`.

#### Step 2: Create All BigQuery Routines
Run the consolidated routine deployment script [sql/01_create_all_routines.sql](sql/01_create_all_routines.sql).
This single script compiles and catalogues all 12 routines in BigQuery under your dataset:
- **10 Scalar UDFs (`ga4_utils`):** `fn_extract_param_string`, `fn_extract_param_int`, `fn_extract_param_float`, `fn_clean_utm`, `fn_clean_transaction_id`, `fn_extract_query_param`, `fn_normalize_url_path`, `fn_map_marketing_channel`, `fn_utc_to_est_datetime`, `fn_utc_to_est_date`.
- **1 Table-Valued Function (`ga4_utils`):** `tvf_get_ga4_events_range` (for ad-hoc queries without table materialization).
- **1 Stored Procedure (`ga4_marts`):** `sp_hourly_ga4_sync` (the set-based ingestion engine).

*(Alternatively, you can run [sql/01_udfs.sql](sql/01_udfs.sql) and [sql/03_procedure_hourly_sync.sql](sql/03_procedure_hourly_sync.sql) independently).*

#### Step 3: Create Materialized Mart Tables
Execute [sql/02_ddl_tables.sql](sql/02_ddl_tables.sql) to instantiate `etl_watermark`, `etl_pipeline_locks`, `fct_ga4_sessions`, `fct_ga4_transactions`, `fct_ga4_transaction_products`, and `fct_ga4_cart_events`.

---

## ⏰ Scheduling the Hourly Sync Routine

To keep your marts continuously updated as soon as Google delivers closed daily export tables, schedule the stored procedure `ga4_marts.sp_hourly_ga4_sync` to run every hour.

### Method A: BigQuery Studio UI (Click-by-Click)

1. Navigate to **BigQuery Studio** in Google Cloud Console.
2. In a new Query Editor tab, enter the routine call:
   ```sql
   CALL `your_project_id.ga4_marts.sp_hourly_ga4_sync`(NULL, 30);
   ```
   *(Pass `NULL` to query your default export, or pass `'project.analytics_123456789'` to override).*
3. In the toolbar directly above the SQL editor, click **Schedule** → **Create new scheduled query**.
4. Configure the scheduled query parameters:
   - **Name for scheduled query:** `ga4_marts_hourly_sync`
   - **Repeats:** `Hourly`
   - **Dataset:** Leave blank (the stored procedure handles all table writes internally)
   - **Destination table:** Leave blank
   - **Location:** Choose your dataset region (e.g. `US` or `EU`)
5. Click **Save**. BigQuery will now trigger the procedure at minute 0 of every hour.

### Method B: Google Cloud CLI (`bq mk`)

Execute this single command in your terminal or Cloud Shell:

```bash
bq mk \
  --transfer_config \
  --project_id="YOUR_PROJECT_ID" \
  --data_source=scheduled_query \
  --display_name="GA4 Marts Hourly Sync" \
  --schedule="every 1 hours" \
  --location="US" \
  --params='{"query":"CALL `YOUR_PROJECT_ID.ga4_marts.sp_hourly_ga4_sync`(NULL, 30);"}'
```

### Method C: Monitoring Execution Health

Every execution of the routine writes runtime diagnostics to `ga4_marts.etl_watermark`. Query it anytime to inspect execution status, row counts, and catch-up dates:

```sql
SELECT
  execution_timestamp,
  table_name,
  last_processed_date_est,
  rows_processed,
  execution_status,
  notes
FROM `ga4_marts.etl_watermark`
ORDER BY execution_timestamp DESC
LIMIT 20;
```
When yesterday's data has already been loaded, the procedure logs `SKIPPED_UP_TO_DATE` and terminates naturally within milliseconds, consuming **0 scanned bytes**.

---

## 🤝 About Database Marketer

**[Database Marketer (dbmarketer.com)](https://dbmarketer.com)** is an elite analytics engineering and marketing data practice led by **Rudy Martinez**. We specialize in building bulletproof data pipelines, AI agent skills, enterprise dbt/BigQuery/Snowflake semantic models, and high-impact revenue attribution architectures.

- **Website:** [dbmarketer.com](https://dbmarketer.com)
- **Consulting Inquiries:** [dbmarketer.com/#contact](https://dbmarketer.com/#contact)
- **Flagship Skills:** Ecommerce Marketing Analytics Skill, Multi-Touch Attribution Engine

---

## 📜 Package License

This `ga4-bigquery-schema/` package is open-source software licensed under the **Apache License, Version 2.0** (see [`LICENSE`](LICENSE) and the repository root [`../LICENSE`](../LICENSE)). You may use, modify, and distribute this package commercially or non-commercially subject to the Apache 2.0 terms. *(Note: Other packages in the parent `dbmarketer` repository, such as `ai-nutrition-intelligence/`, carry separate package-specific licenses.)*
