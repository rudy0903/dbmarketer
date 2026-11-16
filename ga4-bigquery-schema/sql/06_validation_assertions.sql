-- ==============================================================================
-- Project: Database Marketer (dbmarketer.com)
-- Component: GA4 BigQuery Production Schema & Marts (v2.4)
-- File: 06_validation_assertions.sql
-- Description: Complete 7-Assertion Fail-Safe Data Quality & Reconciliation Suite.
--              Run after `CALL ga4_marts.sp_hourly_ga4_sync(NULL, 30);` to verify:
--              1. Primary Key Uniqueness (`(source_dataset_id, session_key)`) & Single-Source Isolation
--              2. Essential Key Non-Nullability, 3-State `traffic_type`, & `consent_status` Taxonomy
--              3. Attribution Non-Null Guarantee & Organic vs. Paid Social Separation
--              4. Same-Session / Same-Transaction Cross-Mart Purchase & Revenue Reconciliation
--              5. Non-Negative UTC Session Duration & UTC Timestamp Ordering (`session_start_ts <= session_end_ts`)
--              6. Authoritative Ecommerce Attributes, Duplicate Audit Diagnostics & Line-Item Reconciliation
--              7. Complete `(source_project_id, source_dataset_id)` Namespace Ownership & Lock Health
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- ASSERTION 1: Primary Key Uniqueness & Single-Source Namespace Isolation
-- ------------------------------------------------------------------------------
ASSERT (
  (
    SELECT
      (COUNT(1) - COUNT(DISTINCT CONCAT(source_dataset_id, ':', session_key))) = 0
      AND COUNT(DISTINCT source_dataset_id) <= 1
    FROM `ga4_marts.fct_ga4_sessions`
    WHERE session_date_est >= DATE_SUB(CURRENT_DATE('America/New_York'), INTERVAL 30 DAY)
  )
) AS 'CRITICAL FAILURE [Assertion 1]: Duplicate (source_dataset_id, session_key) or multi-property namespace collision detected in ga4_marts.fct_ga4_sessions.';

-- ------------------------------------------------------------------------------
-- ASSERTION 2: Essential Non-Null Keys, 3-State Traffic Type & Cookieless Ping Separation
-- ------------------------------------------------------------------------------
ASSERT (
  (
    SELECT COUNTIF(
      source_dataset_id IS NULL
      OR session_key IS NULL
      OR session_date_est IS NULL
      OR traffic_type NOT IN ('COOKIED_SESSION', 'CONSENT_DENIED_PING', 'UNIDENTIFIED_PING')
      OR consent_status NOT IN ('GRANTED', 'DENIED', 'UNKNOWN')
      OR (traffic_type != 'COOKIED_SESSION' AND session_duration_seconds != 0)
    )
    FROM `ga4_marts.fct_ga4_sessions`
    WHERE session_date_est >= DATE_SUB(CURRENT_DATE('America/New_York'), INTERVAL 30 DAY)
  )
) AS 'CRITICAL FAILURE [Assertion 2]: Missing essential session keys, invalid traffic_type/consent_status taxonomy, or collapsed cookieless pings detected.';

-- ------------------------------------------------------------------------------
-- ASSERTION 3: Attribution Non-Null Guarantee & Organic vs. Paid Social Guard
-- ------------------------------------------------------------------------------
ASSERT (
  (
    SELECT COUNTIF(
      utm_source IS NULL
      OR utm_medium IS NULL
      OR utm_campaign IS NULL
      OR marketing_channel IS NULL
      OR (
        marketing_channel = 'Paid Social'
        AND utm_medium IN ('social', 'organic_social', 'referral', '(none)')
        AND utm_campaign NOT LIKE '%paid%'
      )
    )
    FROM `ga4_marts.fct_ga4_sessions`
    WHERE session_date_est >= DATE_SUB(CURRENT_DATE('America/New_York'), INTERVAL 30 DAY)
  )
) AS 'CRITICAL FAILURE [Assertion 3]: NULL attribution columns or Organic Social misclassified as Paid Social.';

-- ------------------------------------------------------------------------------
-- ASSERTION 4: Bidirectional Whole-Table Session & Global Transaction Reconciliation
--              1. Verifies 0 duplicate (source_dataset_id, transaction_id) across fct_ga4_transactions.
--              2. Session -> Transaction: Reconciles ALL partitions of fct_ga4_sessions against
--                 fct_ga4_transactions on (source_dataset_id, session_key) with no 30-day filter.
--              3. Transaction -> Session: Verifies 0 orphan cookied transactions (every cookied
--                 transaction has a matching session_key in fct_ga4_sessions) and verifies
--                 total_canonical_txns = session_matched_txns + unmatched_cookieless_ping_txns.
-- ------------------------------------------------------------------------------
ASSERT (
  (
    WITH target_sessions AS (
      SELECT
        source_dataset_id,
        session_key,
        transactions_count,
        total_purchase_revenue
      FROM `ga4_marts.fct_ga4_sessions`
    ),
    matched_txns AS (
      SELECT
        t.source_dataset_id,
        t.session_key,
        COUNT(1) AS raw_txn_rows,
        COUNT(DISTINCT t.transaction_id) AS distinct_txns,
        COALESCE(SUM(t.purchase_revenue), 0) AS txn_rev
      FROM `ga4_marts.fct_ga4_transactions` AS t
      INNER JOIN target_sessions AS s
        ON t.source_dataset_id = s.source_dataset_id
       AND t.session_key = s.session_key
      GROUP BY t.source_dataset_id, t.session_key
    ),
    session_to_txn_audit AS (
      SELECT
        COUNTIF(
          s.transactions_count != COALESCE(m.distinct_txns, 0)
          OR COALESCE(m.raw_txn_rows, 0) != COALESCE(m.distinct_txns, 0)
          OR ABS(s.total_purchase_revenue - COALESCE(m.txn_rev, 0)) >= 0.01
        ) AS session_mismatch_count
      FROM target_sessions AS s
      LEFT JOIN matched_txns AS m
        ON s.source_dataset_id = m.source_dataset_id
       AND s.session_key = m.session_key
    ),
    txn_to_session_audit AS (
      SELECT
        COUNTIF(
          t.session_key NOT LIKE 'ping.%'
          AND t.ga_session_id IS NOT NULL
          AND s.session_key IS NULL
        ) AS orphan_cookied_txns,
        COUNT(1) AS total_canonical_txns,
        COUNTIF(s.session_key IS NOT NULL) AS session_matched_txns,
        COUNTIF(s.session_key IS NULL AND (t.session_key LIKE 'ping.%' OR t.ga_session_id IS NULL)) AS unmatched_cookieless_ping_txns
      FROM `ga4_marts.fct_ga4_transactions` AS t
      LEFT JOIN target_sessions AS s
        ON t.source_dataset_id = s.source_dataset_id
       AND t.session_key = s.session_key
    ),
    global_txn_uniqueness AS (
      -- Whole-table uniqueness check across all partitions (no date filter)
      SELECT
        COUNT(1) - COUNT(DISTINCT CONCAT(source_dataset_id, ':', transaction_id)) AS duplicate_txn_ids
      FROM `ga4_marts.fct_ga4_transactions`
    )
    SELECT
      g.duplicate_txn_ids = 0
      AND s_audit.session_mismatch_count = 0
      AND t_audit.orphan_cookied_txns = 0
      AND t_audit.total_canonical_txns = (t_audit.session_matched_txns + t_audit.unmatched_cookieless_ping_txns)
    FROM global_txn_uniqueness AS g
    CROSS JOIN session_to_txn_audit AS s_audit
    CROSS JOIN txn_to_session_audit AS t_audit
  )
) AS 'CRITICAL FAILURE [Assertion 4]: Bidirectional whole-table session/transaction mismatch, orphan cookied transaction, or duplicate transaction_id between fct_ga4_sessions and fct_ga4_transactions.';

-- ------------------------------------------------------------------------------
-- ASSERTION 5: Non-Negative UTC Session Duration & UTC Timestamp Presence
-- ------------------------------------------------------------------------------
ASSERT (
  (
    SELECT COUNTIF(
      session_duration_seconds < 0
      OR session_duration_seconds IS NULL
      OR session_start_ts IS NULL
      OR session_end_ts IS NULL
      OR session_end_ts < session_start_ts
    )
    FROM `ga4_marts.fct_ga4_sessions`
    WHERE session_date_est >= DATE_SUB(CURRENT_DATE('America/New_York'), INTERVAL 30 DAY)
  )
) AS 'CRITICAL FAILURE [Assertion 5]: Negative/NULL session_duration_seconds or invalid session_start_ts/session_end_ts detected.';

-- ------------------------------------------------------------------------------
-- ASSERTION 6: Authoritative Ecommerce Attributes, Duplicate Diagnostics & Product Quantity Reconciliation
--              Verifies transaction currency/tax/shipping and UTC transaction_timestamp are valid
--              even when items_count = 0, duplicate diagnostic columns are populated, and item
--              rows in fct_ga4_transaction_products match transactions that contain item lines.
-- ------------------------------------------------------------------------------
ASSERT (
  (
    WITH txn_items AS (
      SELECT
        source_dataset_id,
        transaction_id,
        COUNT(1) AS product_rows,
        COUNT(DISTINCT transaction_line_key) AS distinct_line_keys,
        COUNTIF(transaction_line_key IS NULL OR item_offset IS NULL OR item_offset < 0) AS invalid_line_keys,
        COALESCE(SUM(quantity), 0) AS total_product_qty
      FROM `ga4_marts.fct_ga4_transaction_products`
      WHERE transaction_date_est >= DATE_SUB(CURRENT_DATE('America/New_York'), INTERVAL 30 DAY)
      GROUP BY source_dataset_id, transaction_id
    )
    SELECT COUNTIF(
      t.transaction_timestamp IS NULL
      OR t.purchase_revenue IS NULL
      OR t.tax_value IS NULL
      OR t.shipping_value IS NULL
      OR t.currency IS NULL
      OR t.items_count < 0
      OR t.duplicate_purchase_event_count < 1
      OR t.distinct_purchase_session_count < 1
      OR t.first_observed_timestamp IS NULL
      OR t.last_observed_timestamp IS NULL
      OR t.min_observed_revenue IS NULL
      OR t.max_observed_revenue IS NULL
      OR t.has_amount_disagreement NOT IN (0, 1)
      OR t.has_items_disagreement NOT IN (0, 1)
      OR t.has_session_disagreement NOT IN (0, 1)
      OR (t.items_count > 0 AND COALESCE(p.product_rows, 0) != t.items_count)
      OR (t.items_count > 0 AND COALESCE(p.distinct_line_keys, 0) != t.items_count)
      OR COALESCE(p.invalid_line_keys, 0) > 0
      OR (t.items_count = 0 AND COALESCE(p.product_rows, 0) != 0)
    )
    FROM `ga4_marts.fct_ga4_transactions` AS t
    LEFT JOIN txn_items AS p
      ON t.source_dataset_id = p.source_dataset_id
     AND t.transaction_id = p.transaction_id
    WHERE t.transaction_date_est >= DATE_SUB(CURRENT_DATE('America/New_York'), INTERVAL 30 DAY)
  )
) AS 'CRITICAL FAILURE [Assertion 6]: NULL order attributes/diagnostics or item row count mismatch between fct_ga4_transactions and fct_ga4_transaction_products.';

-- ------------------------------------------------------------------------------
-- ASSERTION 7: Complete (source_project_id, source_dataset_id) Namespace Ownership
-- ------------------------------------------------------------------------------
ASSERT (
  (
    SELECT
      COUNT(DISTINCT CONCAT(source_project_id, '.', source_dataset_id)) <= 1
    FROM `ga4_marts.etl_watermark`
    WHERE pipeline_name = 'sp_hourly_ga4_sync'
      AND execution_status = 'SUCCESS'
  )
) AS 'CRITICAL FAILURE [Assertion 7]: Multiple (source_project_id, source_dataset_id) owners detected in ga4_marts.etl_watermark.';
