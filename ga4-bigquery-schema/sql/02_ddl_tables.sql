-- ==============================================================================
-- Project: Database Marketer (dbmarketer.com)
-- Component: GA4 BigQuery Production Schema & Marts
-- File: 02_ddl_tables.sql
-- Description: DDL definitions for Set 2 Materialized Marts & State Tables:
--              1. etl_watermark (ETL State, Deep-Audit Lookback & Audit History)
--              2. etl_pipeline_locks (Atomic Single-Writer Concurrency Lock Table)
--              3. fct_ga4_sessions (Date Partitioned, Source-Isolated, 47 Canonical Columns)
--              4. fct_ga4_transactions (Canonical Order Mart with UTC Timestamp & Duplicate Diagnostics)
--              5. fct_ga4_transaction_products (Item-Level Revenue Mart from Winning Purchase Only)
--              6. fct_ga4_cart_events (Shopping Actions Event Stream, Source-Isolated)
--              All column names strictly adhere to snake_case with underscores.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. ETL Watermark Table
--    Enforces idempotency, tracks pre-read shard metadata cutoffs, and records
--    lookback window depth so 90/365-day deep audits are never skipped.
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `ga4_marts.etl_watermark` (
  pipeline_name STRING NOT NULL OPTIONS(description="ETL pipeline identifier (e.g. sp_hourly_ga4_sync)"),
  source_project_id STRING NOT NULL OPTIONS(description="GCP project ID containing raw GA4 dataset"),
  source_dataset_id STRING NOT NULL OPTIONS(description="Raw GA4 dataset / property identifier, e.g. analytics_123456789"),
  table_name STRING NOT NULL OPTIONS(description="Target table name (e.g. fct_ga4_sessions)"),
  execution_id STRING OPTIONS(description="Unique execution UUID (GENERATE_UUID()) correlating lock and watermark rows"),
  lock_owner STRING OPTIONS(description="Principal / session user that executed the run (SESSION_USER())"),
  last_processed_date_est DATE NOT NULL OPTIONS(description="Latest Eastern Time partition processed"),
  rows_processed INT64 OPTIONS(description="Count of rows inserted in the run"),
  execution_status STRING NOT NULL OPTIONS(description="Status: RUNNING, SUCCESS, SKIPPED_UP_TO_DATE, FAILED"),
  execution_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP() OPTIONS(description="UTC timestamp of the procedure execution"),
  max_source_modified_ts TIMESTAMP OPTIONS(description="Pre-read upper-bound last_modified_time of candidate raw shards in this batch"),
  last_lookback_days INT64 OPTIONS(description="Lookback window in days inspected during this run (default 30, optional recovery 90-365)"),
  notes STRING OPTIONS(description="Runtime diagnostics, batch info, or error messages")
)
PARTITION BY DATE(execution_timestamp)
CLUSTER BY source_dataset_id, table_name
OPTIONS(
  description = "Source- and target-scoped watermark and audit table tracking incremental GA4 ETL executions and shard modification cutoffs."
);

-- ------------------------------------------------------------------------------
-- 2. Atomic Single-Writer Pipeline Lock Table
--    Guarantees single-writer serialization per target_scope_key via atomic
--    BigQuery MERGE with automatic stale-lock recovery after expires_at.
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `ga4_marts.etl_pipeline_locks` (
  target_scope_key STRING NOT NULL OPTIONS(description="Unique target scope lock key, e.g. ga4_marts:project.analytics_123456789"),
  pipeline_name STRING NOT NULL OPTIONS(description="ETL pipeline name, e.g. sp_hourly_ga4_sync"),
  source_project_id STRING NOT NULL OPTIONS(description="Source GCP project ID"),
  source_dataset_id STRING NOT NULL OPTIONS(description="Source GA4 dataset ID, e.g. analytics_123456789"),
  execution_id STRING NOT NULL OPTIONS(description="Active or last execution UUID (GENERATE_UUID())"),
  lock_owner STRING NOT NULL OPTIONS(description="Session principal holding or last releasing the lock (SESSION_USER())"),
  lock_status STRING NOT NULL OPTIONS(description="LOCKED, RELEASED, or FAILED_RELEASED"),
  acquired_at TIMESTAMP NOT NULL OPTIONS(description="UTC timestamp when the lock was acquired"),
  expires_at TIMESTAMP NOT NULL OPTIONS(description="UTC timestamp when a stale lock automatically expires (default +30 minutes)"),
  released_at TIMESTAMP OPTIONS(description="UTC timestamp when the lock was cleanly released"),
  failure_reason STRING OPTIONS(description="Error message if released via exception rollback handler")
)
CLUSTER BY target_scope_key
OPTIONS(
  description = "Single-writer concurrency control table acquired via atomic MERGE before any partition rebuild."
);

-- ------------------------------------------------------------------------------
-- 3. Materialized Sessions Table (fct_ga4_sessions)
--    Grain: 1 row per unique (source_dataset_id, session_key).
--    Canonical 47-Column Contract enforced across CTAS, Stored Procedure, and dbt.
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `ga4_marts.fct_ga4_sessions` (
  source_dataset_id STRING NOT NULL OPTIONS(description="Source GA4 BigQuery dataset / property identifier, e.g. analytics_123456789"),
  session_key STRING NOT NULL OPTIONS(description="Primary Key: user_pseudo_id.session_id for cookied sessions or ping.<date>.<farm_fingerprint> for cookieless event pings"),
  session_date_est DATE NOT NULL OPTIONS(description="Session start date in Eastern Time (America/New_York) - PARTITION KEY"),
  session_start_ts TIMESTAMP NOT NULL OPTIONS(description="First event UTC timestamp (TIMESTAMP_MICROS(MIN(event_timestamp)))"),
  session_end_ts TIMESTAMP NOT NULL OPTIONS(description="Last event UTC timestamp (TIMESTAMP_MICROS(MAX(event_timestamp)))"),
  session_start_est DATETIME NOT NULL OPTIONS(description="First event timestamp in Eastern Time"),
  session_end_est DATETIME NOT NULL OPTIONS(description="Last event timestamp in Eastern Time"),
  session_duration_seconds INT64 OPTIONS(description="Elapsed seconds between first and last event in session computed from UTC event_timestamp microseconds"),
  traffic_type STRING NOT NULL OPTIONS(description="3-state traffic classification: COOKIED_SESSION, CONSENT_DENIED_PING, or UNIDENTIFIED_PING"),

  -- User & Consent Identification
  user_pseudo_id STRING OPTIONS(description="GA4 client_id cookie or NULL for unconsented users"),
  session_id INT64 OPTIONS(description="Integer session counter timestamp from gtag.js; NULL for cookieless pings"),
  session_number INT64 OPTIONS(description="Ordinal session count for this user"),
  consent_status STRING OPTIONS(description="Consent state: GRANTED, DENIED, or UNKNOWN"),
  is_consented INT64 OPTIONS(description="Binary flag: 1 if analytics_storage='YES'/'GRANTED', 0 otherwise"),

  -- Landing & Exit Navigation (Normalized Path)
  landing_page STRING OPTIONS(description="Full raw page location of the first event in the session"),
  landing_page_path STRING OPTIONS(description="Normalized landing page path with query params and trailing slash stripped"),
  landing_page_title STRING OPTIONS(description="Page title of the first event in the session"),
  exit_page STRING OPTIONS(description="Page location of the final event in the session"),
  page_referrer STRING OPTIONS(description="HTTP referrer recorded at session start"),
  page_views INT64 OPTIONS(description="Count of page_view events during the session"),
  event_count INT64 OPTIONS(description="Total event count during the session"),
  is_engaged_session INT64 NOT NULL OPTIONS(description="1 if COOKIED_SESSION with GA4 session_engaged=1 (or >=10s duration, >=2 page_views, or purchase), 0 otherwise"),

  -- Centralized Marketing Channel Classification
  marketing_channel STRING NOT NULL OPTIONS(description="Centralized channel mapped via fn_map_marketing_channel"),

  -- Normalized Lowercased UTM Attribution
  utm_source STRING OPTIONS(description="Cleaned and lowercased source (with click-ID fallback)"),
  utm_medium STRING OPTIONS(description="Cleaned and lowercased medium (with click-ID fallback)"),
  utm_campaign STRING OPTIONS(description="Cleaned and lowercased campaign name"),
  utm_term STRING OPTIONS(description="Cleaned and lowercased keyword/term"),
  utm_content STRING OPTIONS(description="Cleaned and lowercased ad content"),
  utm_id STRING OPTIONS(description="Cleaned and lowercased campaign id"),
  utm_source_platform STRING OPTIONS(description="Cleaned and lowercased source platform (e.g. Google Ads, SA360)"),
  utm_creative_format STRING OPTIONS(description="Cleaned and lowercased creative format"),
  utm_marketing_tactic STRING OPTIONS(description="Cleaned and lowercased marketing tactic"),

  -- Device & Geography Context
  device_category STRING OPTIONS(description="Device category: desktop, mobile, tablet"),
  device_os STRING OPTIONS(description="Operating system: Android, iOS, Windows, Mac"),
  device_browser STRING OPTIONS(description="Browser: Chrome, Safari, Edge, Firefox"),
  geo_country STRING OPTIONS(description="Country of the visitor"),
  geo_region STRING OPTIONS(description="State / Province / Region"),
  geo_city STRING OPTIONS(description="City of the visitor"),

  -- Binary 0/1 Occurrence Flags (Non-sequential session occurrence flags)
  has_view_item INT64 NOT NULL OPTIONS(description="1 if session viewed at least 1 product detail page, 0 otherwise"),
  has_add_to_cart INT64 NOT NULL OPTIONS(description="1 if session triggered at least 1 add_to_cart event, 0 otherwise"),
  has_checkout INT64 NOT NULL OPTIONS(description="1 if session began checkout, 0 otherwise"),
  has_purchase INT64 NOT NULL OPTIONS(description="1 if session owns at least 1 canonical purchase transaction, 0 otherwise"),
  has_newsletter_signup INT64 NOT NULL OPTIONS(description="1 if session triggered newsletter/lead signup event, 0 otherwise"),

  -- E-Commerce Volume Metrics (From Winning Canonical Purchases Only)
  total_purchase_revenue NUMERIC OPTIONS(description="Sum of canonical purchase revenue owned by this session"),
  total_items_purchased INT64 OPTIONS(description="Sum of units purchased across canonical transactions owned by this session"),
  transactions_count INT64 OPTIONS(description="Count of distinct canonical transactions owned by this session"),

  -- Audit Metadata
  processed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP() OPTIONS(description="ETL load timestamp")
)
PARTITION BY session_date_est
CLUSTER BY source_dataset_id, marketing_channel, user_pseudo_id, session_id
OPTIONS(
  description = "Materialized session mart with date partitioning, source-property isolation, 11-rule channel mapping, 3-state traffic typing, UTC duration math, and 0/1 occurrence flags."
);

-- ------------------------------------------------------------------------------
-- 4. Materialized Transactions Table (fct_ga4_transactions)
--    Grain: 1 canonical row per unique (source_dataset_id, transaction_id).
--    Policy: Earliest recorded `event_timestamp` wins (with deterministic tie-breaker),
--            regardless of item completeness or duplicate revenue amounts.
--            Includes native UTC `transaction_timestamp` for downstream attribution
--            handoff and full duplicate diagnostic columns.
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `ga4_marts.fct_ga4_transactions` (
  source_dataset_id STRING NOT NULL OPTIONS(description="Source GA4 BigQuery dataset / property identifier"),
  transaction_id STRING NOT NULL OPTIONS(description="Unique ecommerce transaction ID (canonical winner per source_dataset_id)"),
  session_key STRING OPTIONS(description="Winning session foreign key referencing fct_ga4_sessions"),
  user_pseudo_id STRING OPTIONS(description="GA4 user identifier on the winning purchase event"),
  ga_session_id INT64 OPTIONS(description="GA4 integer session ID on the winning purchase event; NULL for cookieless pings"),
  transaction_timestamp TIMESTAMP NOT NULL OPTIONS(description="Canonical UTC timestamp of the winning purchase event (TIMESTAMP_MICROS(event_timestamp))"),
  transaction_date_est DATE NOT NULL OPTIONS(description="Transaction date in Eastern Time - PARTITION KEY"),
  transaction_timestamp_est DATETIME NOT NULL OPTIONS(description="Transaction timestamp in Eastern Time"),
  purchase_revenue NUMERIC OPTIONS(description="Canonical monetary value recorded on the earliest winning purchase event"),
  tax_value NUMERIC OPTIONS(description="Tax amount recorded on the winning purchase event"),
  shipping_value NUMERIC OPTIONS(description="Shipping amount recorded on the winning purchase event"),
  coupon STRING OPTIONS(description="Order-level coupon code extracted from event_params on the winning purchase event"),
  currency STRING OPTIONS(description="Transaction currency code extracted from event_params/item_params, or UNKNOWN when omitted"),
  items_count INT64 OPTIONS(description="Number of line-item structs present on the winning purchase event (may be 0)"),
  total_item_quantity INT64 OPTIONS(description="Total item units recorded on the winning purchase event"),
  marketing_channel STRING OPTIONS(description="Attributed marketing channel of the winning purchase event"),
  utm_source STRING OPTIONS(description="Attributed source at time of purchase"),
  utm_medium STRING OPTIONS(description="Attributed medium at time of purchase"),
  utm_campaign STRING OPTIONS(description="Attributed campaign at time of purchase"),

  -- Duplicate & Instrumentation Quality Diagnostics (Preserved Without Enriching Canonical Winner)
  duplicate_purchase_event_count INT64 OPTIONS(description="Approximate observed-window diagnostic counter (>= 1) of raw purchase events seen for this (source_dataset_id, transaction_id); exact within a single full-history scan and a lower-bound observed estimate across partial, overlapping, or expired-shard rescans"),
  distinct_purchase_session_count INT64 OPTIONS(description="Approximate observed-window diagnostic counter (>= 1) of distinct session_key values seen firing this transaction_id; exact within a single full-history scan and a lower-bound observed estimate across partial, overlapping, or expired-shard rescans"),
  first_observed_timestamp TIMESTAMP OPTIONS(description="Earliest observed UTC purchase event timestamp (matches transaction_timestamp)"),
  last_observed_timestamp TIMESTAMP OPTIONS(description="Latest observed UTC purchase event timestamp across any duplicate fires"),
  min_observed_revenue NUMERIC OPTIONS(description="Minimum purchase_revenue observed across all fires of this transaction_id"),
  max_observed_revenue NUMERIC OPTIONS(description="Maximum purchase_revenue observed across all fires of this transaction_id"),
  has_amount_disagreement INT64 OPTIONS(description="1 if duplicate fires reported differing purchase_revenue values, 0 otherwise"),
  has_items_disagreement INT64 OPTIONS(description="1 if duplicate fires reported differing item array payloads, 0 otherwise"),
  has_session_disagreement INT64 OPTIONS(description="1 if the same transaction_id fired across more than one session_key, 0 otherwise"),

  processed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP() OPTIONS(description="ETL load timestamp")
)
PARTITION BY transaction_date_est
CLUSTER BY source_dataset_id, transaction_id, user_pseudo_id
OPTIONS(
  description = "Canonical deduplicated order transactions (earliest event_timestamp wins) with UTC transaction_timestamp, revenue, channel attribution, and duplicate diagnostics."
);

-- ------------------------------------------------------------------------------
-- 5. Materialized Transaction Products Table (fct_ga4_transaction_products)
--    Grain: 1 row per product item line on the winning canonical purchase event
--           (CROSS JOIN UNNEST(e.items) AS item WITH OFFSET AS item_offset),
--           preserving separate line items and deterministic line identity
--           (transaction_line_key, item_offset) even when the same SKU (item_id)
--           appears on multiple lines within the same transaction (17 Columns).
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `ga4_marts.fct_ga4_transaction_products` (
  source_dataset_id STRING NOT NULL OPTIONS(description="Source GA4 BigQuery dataset / property identifier"),
  transaction_line_key STRING NOT NULL OPTIONS(description="Deterministic line-item primary key: CONCAT(source_dataset_id, '.', transaction_id, '.', CAST(item_offset AS STRING))"),
  transaction_id STRING NOT NULL OPTIONS(description="Foreign key referencing fct_ga4_transactions"),
  item_offset INT64 NOT NULL OPTIONS(description="0-based ordinal line offset from UNNEST(items) WITH OFFSET AS item_offset"),
  session_key STRING OPTIONS(description="Foreign key referencing fct_ga4_sessions"),
  transaction_date_est DATE NOT NULL OPTIONS(description="Transaction date in Eastern Time - PARTITION KEY"),
  item_id STRING NOT NULL OPTIONS(description="SKU or product identifier"),
  item_name STRING OPTIONS(description="Product title / name"),
  item_brand STRING OPTIONS(description="Brand of product"),
  item_category STRING OPTIONS(description="Primary category"),
  item_category_2 STRING OPTIONS(description="Secondary category tier"),
  item_category_3 STRING OPTIONS(description="Tertiary category tier"),
  price NUMERIC OPTIONS(description="Item unit price"),
  quantity INT64 OPTIONS(description="Quantity purchased"),
  item_revenue NUMERIC OPTIONS(description="Line-item revenue (price * quantity or explicit)"),
  coupon STRING OPTIONS(description="Item-level discount coupon"),
  processed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP() OPTIONS(description="ETL load timestamp")
)
PARTITION BY transaction_date_est
CLUSTER BY source_dataset_id, item_id, transaction_id
OPTIONS(
  description = "Item-level line items (17 columns) unnested strictly from the winning canonical purchase event with deterministic transaction_line_key and 0-based item_offset preservation."
);

-- Non-destructive migration helper for existing deployments upgrading to 17 columns:
ALTER TABLE `ga4_marts.fct_ga4_transaction_products`
  ADD COLUMN IF NOT EXISTS transaction_line_key STRING OPTIONS(description="Deterministic line-item primary key: CONCAT(source_dataset_id, '.', transaction_id, '.', CAST(item_offset AS STRING))"),
  ADD COLUMN IF NOT EXISTS item_offset INT64 OPTIONS(description="0-based ordinal line offset from UNNEST(items) WITH OFFSET AS item_offset");

-- ------------------------------------------------------------------------------
-- 6. Materialized Cart Events Table (fct_ga4_cart_events)
--    Grain: 1 row per cart/funnel interaction (add_to_cart, remove_from_cart, view_cart, begin_checkout, view_item).
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `ga4_marts.fct_ga4_cart_events` (
  source_dataset_id STRING NOT NULL OPTIONS(description="Source GA4 BigQuery dataset / property identifier"),
  event_id STRING NOT NULL OPTIONS(description="Unique hash of source_dataset_id, user, session, event_timestamp, and item"),
  session_key STRING OPTIONS(description="Foreign key referencing fct_ga4_sessions"),
  user_pseudo_id STRING OPTIONS(description="GA4 user identifier"),
  event_name STRING NOT NULL OPTIONS(description="Event name: add_to_cart, remove_from_cart, view_item, begin_checkout"),
  event_date_est DATE NOT NULL OPTIONS(description="Event date in Eastern Time - PARTITION KEY"),
  event_timestamp_est DATETIME NOT NULL OPTIONS(description="Event timestamp in Eastern Time"),
  item_id STRING OPTIONS(description="Product SKU interacted with"),
  item_name STRING OPTIONS(description="Product name"),
  item_brand STRING OPTIONS(description="Product brand"),
  item_category STRING OPTIONS(description="Product category"),
  price NUMERIC OPTIONS(description="Item unit price"),
  quantity INT64 OPTIONS(description="Quantity added or viewed"),
  item_revenue NUMERIC OPTIONS(description="Monetary value associated with action"),
  currency STRING OPTIONS(description="Currency code"),
  processed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP() OPTIONS(description="ETL load timestamp")
)
PARTITION BY event_date_est
CLUSTER BY source_dataset_id, event_name, user_pseudo_id
OPTIONS(
  description = "Shopping funnel item interactions with source-property isolation: additions, removals, views, and checkouts."
);
