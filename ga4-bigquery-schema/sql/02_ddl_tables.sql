-- ==============================================================================
-- Project: Database Marketer (dbmarketer.com)
-- Component: GA4 BigQuery Production Schema & Marts
-- File: 02_ddl_tables.sql
-- Description: DDL definitions for Set 2 Materialized Marts:
--              1. etl_watermark (ETL State & Duplicate Guard)
--              2. fct_ga4_sessions (Date Partitioned, Marketing Channel, 0/1 Goal Flags)
--              3. fct_ga4_transactions (Deduplicated Order Mart)
--              4. fct_ga4_transaction_products (Item-Level Revenue Mart)
--              5. fct_ga4_cart_events (Shopping Actions Event Stream)
--              All column names strictly adhere to snake_case with underscores.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. ETL Watermark Table
--    Enforces idempotency and tracks hourly synchronization progress.
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `ga4_marts.etl_watermark` (
  table_name STRING NOT NULL OPTIONS(description="Target table name (e.g. fct_ga4_sessions)"),
  last_processed_date_est DATE NOT NULL OPTIONS(description="Latest Eastern Time partition processed"),
  rows_processed INT64 OPTIONS(description="Count of rows inserted in the run"),
  execution_status STRING NOT NULL OPTIONS(description="Status: SUCCESS, SKIPPED_UP_TO_DATE, FAILED"),
  execution_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP() OPTIONS(description="UTC timestamp of the procedure execution"),
  notes STRING OPTIONS(description="Runtime diagnostics, batch info, or error messages")
)
PARTITION BY DATE(execution_timestamp)
OPTIONS(
  description = "Watermark and audit table tracking hourly incremental GA4 ETL executions."
);

-- ------------------------------------------------------------------------------
-- 2. Materialized Sessions Table (fct_ga4_sessions)
--    Grain: 1 row per unique session (including unconsented traffic).
--    Features:
--      - PARTITION BY session_date_est (Daily Eastern Time date partitioning)
--      - CLUSTER BY marketing_channel, user_pseudo_id, session_id
--      - Normalized landing_page_path (trailing slash stripped)
--      - Centralized marketing_channel mapped via ga4_utils.fn_map_marketing_channel
--      - Normalized lowercased UTM parameters (core 5 + modern extended 4)
--      - Binary 0/1 integer goal flags for effortless SUM() and AVG() summaries
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `ga4_marts.fct_ga4_sessions` (
  session_key STRING NOT NULL OPTIONS(description="Primary Key: user_pseudo_id.session_id for cookied sessions or unconsented.<date>.<hash> for cookieless event pings"),
  session_date_est DATE NOT NULL OPTIONS(description="Session start date in Eastern Time (America/New_York) - PARTITION KEY"),
  session_start_est DATETIME NOT NULL OPTIONS(description="First event timestamp in Eastern Time"),
  session_end_est DATETIME NOT NULL OPTIONS(description="Last event timestamp in Eastern Time"),
  session_duration_seconds INT64 OPTIONS(description="Elapsed seconds between first and last event in session"),
  traffic_type STRING NOT NULL OPTIONS(description="Traffic classification: COOKIED_SESSION (consented with session_id) or UNCONSENTED_PING (cookieless Consent Mode v2 ping)"),
  
  -- User & Consent Identification
  user_pseudo_id STRING OPTIONS(description="GA4 client_id cookie or NULL for unconsented users"),
  session_id INT64 OPTIONS(description="Integer session counter timestamp from gtag.js; NULL for unconsented cookieless pings"),
  session_number INT64 OPTIONS(description="Ordinal session count for this user"),
  consent_status STRING OPTIONS(description="Consent state: GRANTED, DENIED, or UNKNOWN"),
  is_consented INT64 OPTIONS(description="Binary flag: 1 if analytics_storage='YES', 0 otherwise"),

  -- Landing & Exit Navigation (Normalized Path)
  landing_page STRING OPTIONS(description="Full raw page location of the first event in the session"),
  landing_page_path STRING OPTIONS(description="Normalized landing page path with query params and trailing slash stripped"),
  landing_page_title STRING OPTIONS(description="Page title of the first event in the session"),
  exit_page STRING OPTIONS(description="Page location of the final event in the session"),
  page_referrer STRING OPTIONS(description="HTTP referrer recorded at session start"),
  page_views INT64 OPTIONS(description="Count of page_view events during the session"),
  event_count INT64 OPTIONS(description="Total event count during the session"),

  -- Centralized Marketing Channel Classification
  marketing_channel STRING NOT NULL OPTIONS(description="Centralized channel mapped via fn_map_marketing_channel (e.g. Strategic Partnerships, Paid Search, Email)"),

  -- Normalized Lowercased UTM Attribution
  utm_source STRING OPTIONS(description="Cleaned and lowercased source"),
  utm_medium STRING OPTIONS(description="Cleaned and lowercased medium"),
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

  -- Binary 0/1 Goal Flags (For easy SUM() count and AVG() rate summaries)
  has_view_item INT64 NOT NULL OPTIONS(description="1 if session viewed at least 1 product detail page, 0 otherwise"),
  has_add_to_cart INT64 NOT NULL OPTIONS(description="1 if session triggered at least 1 add_to_cart event, 0 otherwise"),
  has_checkout INT64 NOT NULL OPTIONS(description="1 if session began checkout, 0 otherwise"),
  has_purchase INT64 NOT NULL OPTIONS(description="1 if session completed at least 1 purchase, 0 otherwise"),
  has_newsletter_signup INT64 NOT NULL OPTIONS(description="1 if session triggered newsletter/lead signup event, 0 otherwise"),

  -- E-Commerce Volume Metrics
  total_purchase_revenue NUMERIC OPTIONS(description="Sum of purchase revenue generated in this session"),
  total_items_purchased INT64 OPTIONS(description="Sum of all units purchased across transactions in this session"),
  transactions_count INT64 OPTIONS(description="Number of completed transactions in this session"),

  -- Audit Metadata
  processed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP() OPTIONS(description="ETL load timestamp")
)
PARTITION BY session_date_est
CLUSTER BY marketing_channel, user_pseudo_id, session_id
OPTIONS(
  description = "Materialized session mart with date partitioning, centralized channel mapping, lowercased UTMs, and 0/1 integer goal flags."
);

-- ------------------------------------------------------------------------------
-- 3. Materialized Transactions Table (fct_ga4_transactions)
--    Grain: 1 row per unique transaction_id.
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `ga4_marts.fct_ga4_transactions` (
  transaction_id STRING NOT NULL OPTIONS(description="Unique ecommerce transaction ID"),
  session_key STRING OPTIONS(description="Foreign key referencing fct_ga4_sessions"),
  user_pseudo_id STRING OPTIONS(description="GA4 user identifier"),
  transaction_date_est DATE NOT NULL OPTIONS(description="Transaction date in Eastern Time - PARTITION KEY"),
  transaction_timestamp_est DATETIME NOT NULL OPTIONS(description="Transaction timestamp in Eastern Time"),
  purchase_revenue NUMERIC OPTIONS(description="Total monetary value of the transaction"),
  tax_value NUMERIC OPTIONS(description="Tax amount recorded"),
  shipping_value NUMERIC OPTIONS(description="Shipping amount recorded"),
  coupon STRING OPTIONS(description="Order-level coupon code"),
  currency STRING OPTIONS(description="Transaction currency code (e.g. USD)"),
  items_count INT64 OPTIONS(description="Number of line items in order"),
  marketing_channel STRING OPTIONS(description="Attributed marketing channel at time of purchase"),
  utm_source STRING OPTIONS(description="Attributed source at time of purchase"),
  utm_medium STRING OPTIONS(description="Attributed medium at time of purchase"),
  utm_campaign STRING OPTIONS(description="Attributed campaign at time of purchase"),
  processed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP() OPTIONS(description="ETL load timestamp")
)
PARTITION BY transaction_date_est
CLUSTER BY transaction_id, user_pseudo_id
OPTIONS(
  description = "Deduplicated order transactions with revenue, currency, and channel attribution."
);

-- ------------------------------------------------------------------------------
-- 4. Materialized Transaction Products Table (fct_ga4_transaction_products)
--    Grain: 1 row per product item in a completed transaction.
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `ga4_marts.fct_ga4_transaction_products` (
  transaction_id STRING NOT NULL OPTIONS(description="Foreign key referencing fct_ga4_transactions"),
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
CLUSTER BY item_id, transaction_id
OPTIONS(
  description = "Item-level line items unnested from purchase events."
);

-- ------------------------------------------------------------------------------
-- 5. Materialized Cart Events Table (fct_ga4_cart_events)
--    Grain: 1 row per cart/funnel interaction (add_to_cart, remove_from_cart, view_cart, begin_checkout, view_item).
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `ga4_marts.fct_ga4_cart_events` (
  event_id STRING NOT NULL OPTIONS(description="Unique hash of user, session, event_timestamp, and item"),
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
CLUSTER BY event_name, user_pseudo_id
OPTIONS(
  description = "Shopping funnel item interactions: additions, removals, views, and checkouts."
);
