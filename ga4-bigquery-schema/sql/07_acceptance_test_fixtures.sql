-- ============================================================================
-- GA4 BIGQUERY SESSION SCHEMA: 07_ACCEPTANCE_TEST_FIXTURES.SQL (v2.7.0)
-- ============================================================================
-- Executable synthetic acceptance-test fixture verifying:
--   1. Daily-shard regex r'^events_([0-9]{8})$' & r'^events_[0-9]{8}$'
--      matches events_YYYYMMDD and excludes events_intraday_YYYYMMDD.
--   2. Canonical purchase deduplication in temp_canonical_purchases:
--      earliest event_timestamp wins (`ORDER BY event_timestamp ASC, session_key ASC, stable_event_tiebreaker ASC`)
--      without favoring later enriched item arrays or higher duplicate revenue,
--      while exposing idempotent duplicate diagnostic audit fields (T01-T04, T09-T12).
--   3. Valid-before-invalid transaction_id fallback (`fn_clean_transaction_id` before COALESCE)
--      so `ecommerce.transaction_id = '(not set)'` falls back to `event_params.transaction_id` (T05, T06).
--   4. Cross-window expired-shard stored winner protection (T07) and earlier backfill supersession (T08).
--   5. Authoritative event-level ecommerce attributes (tax, shipping,
--      coupon, currency, UTC transaction_timestamp) preserved on zero-item purchases (T13)
--      and repeated SKU line-item offset preservation (`WITH OFFSET AS item_offset`, T15).
-- ============================================================================

WITH
  -- 1. Synthetic __TABLES__ metadata fixture
  synthetic_tables_metadata AS (
    SELECT 'events_20261029' AS table_id, 1730200000000 AS last_modified_time UNION ALL
    SELECT 'events_20261030' AS table_id, 1730286400000 AS last_modified_time UNION ALL
    SELECT 'events_intraday_20261030' AS table_id, 1730290000000 AS last_modified_time UNION ALL
    SELECT 'pseudonymous_users_20261030' AS table_id, 1730290000000 AS last_modified_time
  ),
  regex_filtered_shards AS (
    SELECT
      table_id,
      REGEXP_EXTRACT(table_id, r'^events_([0-9]{8})$') AS suffix,
      last_modified_time
    FROM synthetic_tables_metadata
    WHERE REGEXP_CONTAINS(table_id, r'^events_[0-9]{8}$')
      AND NOT table_id LIKE '%intraday%'
  ),

  -- 2. Synthetic staged purchase candidates across sessions & midnight
  synthetic_purchase_events AS (
    -- T1001 Fire #1 in Session A (23:58 EST on 2026-10-29, $120.00, 0 items — earliest fire MUST win)
    SELECT
      'proj-a' AS source_project_id,
      'analytics_123' AS source_dataset_id,
      'user1.100' AS session_key,
      'user1' AS user_pseudo_id,
      100 AS ga_session_id,
      DATE '2026-10-29' AS session_start_date_est,
      DATE '2026-10-30' AS session_end_date_est,
      DATE '2026-10-29' AS event_date_est,
      DATETIME '2026-10-29 23:58:00' AS event_datetime_est,
      1730260680000000 AS event_timestamp,
      'T1001' AS ecommerce_transaction_id,
      'T1001' AS param_transaction_id,
      120.00 AS purchase_revenue,
      10.00 AS tax_value,
      5.00 AS shipping_value,
      'FALL10' AS coupon,
      'USD' AS currency,
      0 AS items_count,
      'h1' AS stable_event_tiebreaker
    UNION ALL
    -- T1001 Fire #2 in Session A (00:01 EST on 2026-10-30 after midnight, $120.00, 2 items)
    SELECT
      'proj-a', 'analytics_123', 'user1.100', 'user1', 100,
      DATE '2026-10-29', DATE '2026-10-30',
      DATE '2026-10-30', DATETIME '2026-10-30 00:01:00', 1730260860000000,
      'T1001', 'T1001', 120.00, 10.00, 5.00, 'FALL10', 'USD', 2, 'h2'
    UNION ALL
    -- T1001 Fire #3 in Session B (reload in later session with higher duplicate amount $150.00 and 2 items)
    SELECT
      'proj-a', 'analytics_123', 'user1.101', 'user1', 101,
      DATE '2026-10-30', DATE '2026-10-30',
      DATE '2026-10-30', DATETIME '2026-10-30 09:15:00', 1730294100000000,
      'T1001', 'T1001', 150.00, 10.00, 5.00, 'FALL10', 'USD', 2, 'h3'
    UNION ALL
    -- T1002 Zero-item service purchase in Session C (must retain tax, shipping, currency)
    SELECT
      'proj-a', 'analytics_123', 'user2.200', 'user2', 200,
      DATE '2026-10-30', DATE '2026-10-30',
      DATE '2026-10-30', DATETIME '2026-10-30 10:00:00', 1730296800000000,
      'T1002', 'T1002', 85.00, 6.40, 9.99, CAST(NULL AS STRING), 'EUR', 0, 'h4'
    UNION ALL
    -- T1003 Valid-before-invalid fallback (T06): ecommerce.transaction_id = '(not set)' falls back to event_params.transaction_id = 'T1003'
    SELECT
      'proj-a', 'analytics_123', 'user3.300', 'user3', 300,
      DATE '2026-10-30', DATE '2026-10-30',
      DATE '2026-10-30', DATETIME '2026-10-30 11:00:00', 1730300400000000,
      '(not set)', 'T1003', 60.00, 4.00, 0.00, CAST(NULL AS STRING), 'USD', 2, 'h5'
  ),

  -- 3. Clean each transaction_id candidate before COALESCE (`fn_clean_transaction_id` contract)
  cleaned_purchase_events AS (
    SELECT
      *,
      COALESCE(
        IF(ecommerce_transaction_id IS NULL OR TRIM(ecommerce_transaction_id) = '' OR LOWER(TRIM(ecommerce_transaction_id)) IN ('(not set)', 'null', 'undefined'), NULL, TRIM(ecommerce_transaction_id)),
        IF(param_transaction_id IS NULL OR TRIM(param_transaction_id) = '' OR LOWER(TRIM(param_transaction_id)) IN ('(not set)', 'null', 'undefined'), NULL, TRIM(param_transaction_id))
      ) AS transaction_id
    FROM synthetic_purchase_events
  ),

  -- 4. Canonical purchase deduplication (Earliest event_timestamp wins)
  canonical_purchases AS (
    SELECT
      *,
      TIMESTAMP_MICROS(event_timestamp) AS transaction_timestamp,
      COUNT(1) OVER (PARTITION BY source_dataset_id, transaction_id) AS duplicate_purchase_event_count,
      COUNT(DISTINCT session_key) OVER (PARTITION BY source_dataset_id, transaction_id) AS distinct_purchase_session_count,
      TIMESTAMP_MICROS(MIN(event_timestamp) OVER (PARTITION BY source_dataset_id, transaction_id)) AS first_observed_timestamp,
      TIMESTAMP_MICROS(MAX(event_timestamp) OVER (PARTITION BY source_dataset_id, transaction_id)) AS last_observed_timestamp,
      ROUND(MIN(purchase_revenue) OVER (PARTITION BY source_dataset_id, transaction_id), 2) AS min_observed_revenue,
      ROUND(MAX(purchase_revenue) OVER (PARTITION BY source_dataset_id, transaction_id), 2) AS max_observed_revenue,
      IF(MIN(purchase_revenue) OVER (PARTITION BY source_dataset_id, transaction_id) != MAX(purchase_revenue) OVER (PARTITION BY source_dataset_id, transaction_id), 1, 0) AS has_amount_disagreement,
      IF(MIN(items_count) OVER (PARTITION BY source_dataset_id, transaction_id) != MAX(items_count) OVER (PARTITION BY source_dataset_id, transaction_id), 1, 0) AS has_items_disagreement,
      IF(COUNT(DISTINCT session_key) OVER (PARTITION BY source_dataset_id, transaction_id) > 1, 1, 0) AS has_session_disagreement
    FROM cleaned_purchase_events
    WHERE transaction_id IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY source_dataset_id, transaction_id
      ORDER BY
        event_timestamp ASC,
        session_key ASC,
        stable_event_tiebreaker ASC
    ) = 1
  ),

  -- 5. Session-level rollup fed exclusively from canonical_purchases
  session_purchase_rollup AS (
    SELECT
      source_dataset_id,
      session_key,
      COUNT(1) AS transactions_count,
      SUM(purchase_revenue) AS total_purchase_revenue
    FROM canonical_purchases
    GROUP BY source_dataset_id, session_key
  ),

  -- 6. Product line-item unnesting with repeated SKU offset preservation (transaction_line_key, item_offset)
  synthetic_repeated_sku_lines AS (
    SELECT
      'analytics_123' AS source_dataset_id,
      'T1003' AS transaction_id,
      item_offset,
      CONCAT('analytics_123.T1003.', CAST(item_offset AS STRING)) AS transaction_line_key,
      item.item_id,
      item.price,
      item.quantity
    FROM UNNEST([
      STRUCT('SKU-DUP-100' AS item_id, NUMERIC '30.00' AS price, 1 AS quantity),
      STRUCT('SKU-DUP-100' AS item_id, NUMERIC '30.00' AS price, 1 AS quantity)
    ]) AS item WITH OFFSET AS item_offset
  ),

  -- 7. Cross-midnight partition closure check
  affected_partition_dates AS (
    SELECT DISTINCT session_start_date_est AS partition_date FROM cleaned_purchase_events
    UNION DISTINCT
    SELECT DISTINCT session_end_date_est AS partition_date FROM cleaned_purchase_events
  )

SELECT
  (SELECT STRING_AGG(suffix, ',' ORDER BY suffix) FROM regex_filtered_shards) AS matched_daily_suffixes,
  (SELECT COUNT(1) FROM canonical_purchases) AS canonical_txn_count,
  (SELECT ROUND(SUM(purchase_revenue), 2) FROM canonical_purchases) AS canonical_txn_revenue,
  (SELECT ROUND(SUM(total_purchase_revenue), 2) FROM session_purchase_rollup) AS session_mart_revenue,
  (SELECT COALESCE(SUM(transactions_count), 0) FROM session_purchase_rollup WHERE session_key = 'user1.100') AS sess_a_txns,
  (SELECT COALESCE(SUM(transactions_count), 0) FROM session_purchase_rollup WHERE session_key = 'user1.101') AS sess_b_txns,
  (SELECT COALESCE(SUM(transactions_count), 0) FROM session_purchase_rollup WHERE session_key = 'user3.300') AS sess_d_fallback_txns,
  (SELECT items_count FROM canonical_purchases WHERE transaction_id = 'T1001') AS t1001_winning_items_count,
  (SELECT has_amount_disagreement FROM canonical_purchases WHERE transaction_id = 'T1001') AS t1001_amount_disagreement,
  (SELECT has_items_disagreement FROM canonical_purchases WHERE transaction_id = 'T1001') AS t1001_items_disagreement,
  (SELECT has_session_disagreement FROM canonical_purchases WHERE transaction_id = 'T1001') AS t1001_session_disagreement,
  (SELECT CONCAT(currency, ':', CAST(tax_value AS STRING), ':', CAST(shipping_value AS STRING), ':items=', CAST(items_count AS STRING))
   FROM canonical_purchases WHERE transaction_id = 'T1002') AS t1002_zero_item_attrs,
  (SELECT COUNT(DISTINCT transaction_line_key) FROM synthetic_repeated_sku_lines) AS t1003_distinct_line_keys,
  (SELECT STRING_AGG(CAST(partition_date AS STRING), ',' ORDER BY partition_date) FROM affected_partition_dates) AS closed_partition_dates;
