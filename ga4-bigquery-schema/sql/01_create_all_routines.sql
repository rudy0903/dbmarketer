-- ==============================================================================
-- Project: Database Marketer (dbmarketer.com)
-- Component: GA4 BigQuery Production Schema & Marts
-- File: 01_udfs.sql
-- Description: Parameterized User-Defined Functions (Scalar & Table-Valued)
--              for parsing raw GA4 event streams, normalizing UTMs, resolving
--              paid click-ID fallbacks, converting timestamps to EST, stripping
--              trailing slashes, and centralizing 11-rule marketing channel mapping.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. SCALAR UDF: Extract String Parameter from event_params
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION `ga4_utils.fn_extract_param_string`(
  params ARRAY<STRUCT<key STRING, value STRUCT<string_value STRING, int_value INT64, float_value FLOAT64, double_value FLOAT64>>>,
  target_key STRING
)
RETURNS STRING
AS ((
  SELECT val.value.string_value
  FROM UNNEST(params) AS val
  WHERE val.key = target_key
  LIMIT 1
));

-- ------------------------------------------------------------------------------
-- 2. SCALAR UDF: Extract INT64 Parameter from event_params
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION `ga4_utils.fn_extract_param_int`(
  params ARRAY<STRUCT<key STRING, value STRUCT<string_value STRING, int_value INT64, float_value FLOAT64, double_value FLOAT64>>>,
  target_key STRING
)
RETURNS INT64
AS ((
  SELECT val.value.int_value
  FROM UNNEST(params) AS val
  WHERE val.key = target_key
  LIMIT 1
));

-- ------------------------------------------------------------------------------
-- 3. SCALAR UDF: Extract Numeric/Float Parameter from event_params
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION `ga4_utils.fn_extract_param_float`(
  params ARRAY<STRUCT<key STRING, value STRUCT<string_value STRING, int_value INT64, float_value FLOAT64, double_value FLOAT64>>>,
  target_key STRING
)
RETURNS FLOAT64
AS ((
  SELECT COALESCE(val.value.float_value, val.value.double_value, CAST(val.value.int_value AS FLOAT64))
  FROM UNNEST(params) AS val
  WHERE val.key = target_key
  LIMIT 1
));

-- ------------------------------------------------------------------------------
-- 4. SCALAR UDF: Clean and Lowercase UTM Parameter Values
--    Strips whitespace, decodes '+' to spaces, lowercases, and casts empty strings to NULL.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION `ga4_utils.fn_clean_utm`(raw_val STRING)
RETURNS STRING
AS (
  NULLIF(LOWER(TRIM(REGEXP_REPLACE(raw_val, r'\+', ' '))), '')
);

-- ------------------------------------------------------------------------------
-- 5. SCALAR UDF: Regex Extract Query Parameter from URL (Fallback for Redirects)
--    Matches case-insensitively for params in query strings like ?utm_source=... or &utm_source=...
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION `ga4_utils.fn_extract_query_param`(url STRING, param_name STRING)
RETURNS STRING
AS (
  `ga4_utils.fn_clean_utm`(
    REGEXP_EXTRACT(url, CONCAT(r'(?i)[?&]', param_name, r'=([^&#]+)'))
  )
);

-- ------------------------------------------------------------------------------
-- 6. SCALAR UDF: Normalize URL Landing Page Path (Strip Trailing Slash)
--    Extracts the clean path component from a full URL or relative path, converts
--    to lowercase, removes query strings/anchors, and strips any trailing slash.
--    Examples:
--      'https://dbmarketer.com/partners/acme/?source=ad' -> '/partners/acme'
--      'https://dbmarketer.com/partners/acme/'           -> '/partners/acme'
--      'https://dbmarketer.com/'                         -> '/'
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION `ga4_utils.fn_normalize_url_path`(url STRING)
RETURNS STRING
AS ((
  SELECT
    CASE
      WHEN cleaned_path IS NULL OR cleaned_path IN ('', '/') THEN '/'
      ELSE REGEXP_REPLACE(cleaned_path, r'/+$', '')
    END
  FROM (
    SELECT LOWER(TRIM(
      COALESCE(
        REGEXP_EXTRACT(url, r'^[a-zA-Z]+://[^/?#]+([^?#]*)'),
        REGEXP_EXTRACT(url, r'^([^?#]*)')
      )
    )) AS cleaned_path
  )
));

-- ------------------------------------------------------------------------------
-- 7. SCALAR UDF: Centralized 11-Rule Marketing Channel Mapping
--    Single Source of Truth compiled from skills/knowledge_registry/contracts/canonical_channels.yaml
--    Evaluates clean UTMs, HTTP referrer, and normalized landing page path.
--    Separates Paid Social (Rule 3) from Organic Social (Rule 5) to prevent organic
--    social visits from being misclassified as Paid Social (P0.4).
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION `ga4_utils.fn_map_marketing_channel`(
  source STRING,
  medium STRING,
  campaign STRING,
  referrer STRING,
  landing_page_path STRING
)
RETURNS STRING
AS (
  CASE
    -- Rule 1: High-Priority Strategic Partnerships & Co-Marketing Portals
    WHEN landing_page_path LIKE '/partners%'
      OR landing_page_path LIKE '/co-marketing%'
      OR landing_page_path LIKE '/alliances%'
      OR LOWER(referrer) LIKE '%partnerportal.com%'
      OR LOWER(referrer) LIKE '%strategicpartner.org%'
      OR source IN ('strategic_partner', 'cobrand_partner', 'enterprise_affiliate')
      THEN 'Strategic Partnerships'

    -- Rule 2: Dedicated Influencer & Creator Landing Pages
    WHEN landing_page_path LIKE '/creators%'
      OR landing_page_path LIKE '/influencers%'
      OR medium IN ('influencer', 'creator', 'collab')
      THEN 'Influencer / Creator'

    -- Rule 3: Paid Social (Evaluated before generic Paid Search to prevent Facebook/Meta cpc from leaking into search)
    WHEN medium IN ('paidsocial', 'paid_social', 'social_cpc', 'social_paid', 'social-cpc', 'paid-social')
      OR (source IN ('facebook', 'instagram', 'meta', 'tiktok', 'linkedin', 'pinterest', 'twitter', 'x', 't.co', 'reddit', 'threads', 'snapchat')
          AND (medium IN ('cpc', 'ppc', 'cpm', 'paid', 'ad', 'social_ad', 'paidad') OR campaign LIKE '%paid%'))
      THEN 'Paid Social'

    -- Rule 4: Paid Search
    WHEN (source IN ('google', 'bing', 'yahoo', 'duckduckgo', 'ecosia', 'baidu') AND medium IN ('cpc', 'ppc', 'paidsearch', 'paid_search'))
      OR medium IN ('paidsearch', 'paid_search')
      OR (medium IN ('cpc', 'ppc')
          AND COALESCE(source, '') NOT IN ('facebook', 'instagram', 'meta', 'tiktok', 'linkedin', 'pinterest', 'twitter', 'x', 't.co', 'reddit', 'threads', 'snapchat', 'youtube', 'vimeo', 'hulu'))
      THEN 'Paid Search'

    -- Rule 5: Organic Social
    WHEN medium IN ('social', 'social_network', 'social_media', 'social-network', 'social-media', 'sm', 'org_social', 'organic_social')
      OR source IN ('facebook', 'instagram', 'meta', 'tiktok', 'linkedin', 'pinterest', 'twitter', 'x', 't.co', 'reddit', 'threads', 'snapchat')
      OR LOWER(referrer) LIKE '%instagram.com%'
      OR LOWER(referrer) LIKE '%facebook.com%'
      OR LOWER(referrer) LIKE '%linkedin.com%'
      OR LOWER(referrer) LIKE '%tiktok.com%'
      OR LOWER(referrer) LIKE '%reddit.com%'
      OR LOWER(referrer) LIKE '%t.co%'
      OR LOWER(referrer) LIKE '%x.com%'
      THEN 'Organic Social'

    -- Rule 6: Email Marketing
    WHEN medium IN ('email', 'e-mail', 'e_mail', 'newsletter', 'edm', 'flow', 'campaign_email')
      OR source IN ('email', 'e-mail', 'newsletter', 'klaviyo', 'mailchimp', 'braze', 'activecampaign', 'hubspot', 'sailthru', 'customerio')
      THEN 'Email'

    -- Rule 7: Affiliates
    WHEN medium IN ('affiliate', 'affiliates', 'aff')
      OR source IN ('rakuten', 'impact', 'shareasale', 'awin', 'cj', 'pepperjam')
      OR landing_page_path LIKE '/affiliate%'
      THEN 'Affiliates'

    -- Rule 8: Paid Video
    WHEN medium IN ('video', 'cpm_video', 'paid_video', 'paidvideo')
      OR (source IN ('youtube', 'vimeo', 'hulu') AND medium IN ('cpc', 'cpm', 'paid', 'cpv', 'ppc'))
      THEN 'Paid Video'

    -- Rule 9: Organic Search
    WHEN medium = 'organic'
      OR source IN ('google', 'bing', 'yahoo', 'duckduckgo', 'ecosia', 'baidu')
      OR LOWER(referrer) LIKE '%google.%'
      OR LOWER(referrer) LIKE '%bing.%'
      OR LOWER(referrer) LIKE '%duckduckgo.%'
      THEN 'Organic Search'

    -- Rule 10: Referral (Generic non-partner web links)
    WHEN medium IN ('referral', 'referrals', 'link', 'app')
      OR (referrer IS NOT NULL AND referrer NOT IN ('', '(not set)') AND NOT (LOWER(referrer) LIKE '%google.%' OR LOWER(referrer) LIKE '%bing.%' OR LOWER(referrer) LIKE '%duckduckgo.%'))
      THEN 'Referral'

    -- Rule 11: Direct
    WHEN (source IS NULL OR source IN ('(direct)', 'direct', '', '(not set)'))
      AND (medium IS NULL OR medium IN ('(none)', '(not set)', 'none', ''))
      THEN 'Direct'

    -- Fallback
    ELSE 'Other'
  END
);

-- ------------------------------------------------------------------------------
-- 8. SCALAR UDF: Convert Microsecond UTC Timestamp to Eastern Time DATETIME
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION `ga4_utils.fn_utc_to_est_datetime`(ts_micros INT64)
RETURNS DATETIME
AS (
  DATETIME(TIMESTAMP_MICROS(ts_micros), 'America/New_York')
);

-- ------------------------------------------------------------------------------
-- 9. SCALAR UDF: Convert Microsecond UTC Timestamp to Eastern Time DATE
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION `ga4_utils.fn_utc_to_est_date`(ts_micros INT64)
RETURNS DATE
AS (
  DATE(TIMESTAMP_MICROS(ts_micros), 'America/New_York')
);

-- ------------------------------------------------------------------------------
-- 10. SCALAR UDF: Clean and Validate Ecommerce Transaction ID
--     Strips whitespace and converts empty strings or invalid placeholders
--     ('(not set)', 'null', 'undefined') to NULL BEFORE COALESCE fallback.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION `ga4_utils.fn_clean_transaction_id`(raw_id STRING)
RETURNS STRING
AS (
  IF(
    raw_id IS NULL
    OR TRIM(raw_id) = ''
    OR LOWER(TRIM(raw_id)) IN ('(not set)', 'null', 'undefined'),
    NULL,
    TRIM(raw_id)
  )
);

-- ------------------------------------------------------------------------------
-- 11. SET 1: PARAMETERIZED TABLE-VALUED FUNCTION (TVF)
--     Query any arbitrary daily shard range on the fly without running full ETL.
--     Enforces strict daily shard regex (`^[0-9]{8}$`) so intraday tables are never mixed.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE TABLE FUNCTION `ga4_utils.tvf_get_ga4_events_range`(
  start_table_suffix STRING,
  end_table_suffix STRING
)
AS (
  SELECT
    -- Timestamps: UTC source vs Eastern Time conversion
    e.event_timestamp,
    `ga4_utils.fn_utc_to_est_datetime`(e.event_timestamp) AS event_datetime_est,
    `ga4_utils.fn_utc_to_est_date`(e.event_timestamp) AS event_date_est,
    e.event_date AS admin_event_date,
    e.event_name,

    -- Identification & 3-State Consent Mode v2 Traffic Classification (P1.2)
    e.user_pseudo_id,
    `ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id') AS session_id,
    `ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_number') AS session_number,

    CASE
      WHEN e.user_pseudo_id IS NOT NULL AND `ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id') IS NOT NULL
        THEN 'COOKIED_SESSION'
      WHEN UPPER(COALESCE(e.privacy_info.analytics_storage, '')) IN ('NO', 'DENIED', 'FALSE')
        THEN 'CONSENT_DENIED_PING'
      ELSE 'UNIDENTIFIED_PING'
    END AS traffic_type,

    -- Collision-Resistant Synthetic Session Key: Preserves cookieless pings without collapsing timestamps
    COALESCE(
      IF(
        e.user_pseudo_id IS NOT NULL AND `ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id') IS NOT NULL,
        CONCAT(e.user_pseudo_id, '.', CAST(`ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id') AS STRING)),
        NULL
      ),
      CONCAT(
        'ping.',
        e.event_date,
        '.',
        CAST(
          FARM_FINGERPRINT(
            CONCAT(
              CAST(e.event_timestamp AS STRING), '|',
              COALESCE(e.event_name, ''), '|',
              COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), '|',
              COALESCE(e.user_pseudo_id, 'anon'), '|',
              COALESCE(e.geo.country, '')
            )
          ) AS STRING
        )
      )
    ) AS session_key,

    -- Consent Mode indicators
    e.privacy_info.analytics_storage AS consent_analytics_storage,
    CASE
      WHEN UPPER(COALESCE(e.privacy_info.analytics_storage, '')) IN ('YES', 'GRANTED', 'TRUE') THEN 'GRANTED'
      WHEN UPPER(COALESCE(e.privacy_info.analytics_storage, '')) IN ('NO', 'DENIED', 'FALSE') THEN 'DENIED'
      ELSE 'UNKNOWN'
    END AS consent_status,
    CASE
      WHEN UPPER(COALESCE(e.privacy_info.analytics_storage, '')) IN ('YES', 'GRANTED', 'TRUE') THEN 1
      WHEN UPPER(COALESCE(e.privacy_info.analytics_storage, '')) IN ('NO', 'DENIED', 'FALSE') THEN 0
      ELSE 0
    END AS is_consented,

    -- Page & Screen context
    `ga4_utils.fn_extract_param_string`(e.event_params, 'page_location') AS page_location,
    `ga4_utils.fn_normalize_url_path`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location')) AS landing_page_path,
    `ga4_utils.fn_extract_param_string`(e.event_params, 'page_title') AS page_title,
    `ga4_utils.fn_extract_param_string`(e.event_params, 'page_referrer') AS page_referrer,

    -- Lowercased UTM Attribution Hierarchy with Click-ID Parameter Fallback
    `ga4_utils.fn_clean_utm`(COALESCE(
      e.collected_traffic_source.manual_source,
      `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_source'),
      CASE
        WHEN e.collected_traffic_source.gclid IS NOT NULL
          OR REGEXP_CONTAINS(COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), r'(?i)[?&](gclid|wbraid|gbraid)=')
          THEN 'google'
        WHEN REGEXP_CONTAINS(COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), r'(?i)[?&]msclkid=')
          THEN 'bing'
        WHEN REGEXP_CONTAINS(COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), r'(?i)[?&]fbclid=')
          THEN 'facebook'
        WHEN REGEXP_CONTAINS(COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), r'(?i)[?&]ttclid=')
          THEN 'tiktok'
        ELSE NULL
      END,
      e.traffic_source.source
    )) AS utm_source,

    `ga4_utils.fn_clean_utm`(COALESCE(
      e.collected_traffic_source.manual_medium,
      `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_medium'),
      CASE
        WHEN e.collected_traffic_source.gclid IS NOT NULL
          OR REGEXP_CONTAINS(COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), r'(?i)[?&](gclid|wbraid|gbraid|msclkid)=')
          THEN 'cpc'
        WHEN REGEXP_CONTAINS(COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), r'(?i)[?&]ttclid=')
          THEN 'paid_social'
        WHEN REGEXP_CONTAINS(COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), r'(?i)[?&]fbclid=')
          THEN IF(
            REGEXP_CONTAINS(
              LOWER(COALESCE(e.collected_traffic_source.manual_campaign_name, `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_campaign'), e.traffic_source.name, '')),
              r'(paid|(^|[_ -])(cpc|ppc|cpm|ad|ads|prosp|retarg)($|[_ -]))'
            ),
            'paid_social',
            'social'
          )
        ELSE NULL
      END,
      e.traffic_source.medium
    )) AS utm_medium,

    `ga4_utils.fn_clean_utm`(COALESCE(
      e.collected_traffic_source.manual_campaign_name,
      `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_campaign'),
      e.traffic_source.name
    )) AS utm_campaign,

    `ga4_utils.fn_clean_utm`(COALESCE(
      e.collected_traffic_source.manual_term,
      `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_term')
    )) AS utm_term,

    `ga4_utils.fn_clean_utm`(COALESCE(
      e.collected_traffic_source.manual_content,
      `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_content')
    )) AS utm_content,

    -- Centralized Marketing Channel Mapping (Dynamic UDF execution)
    `ga4_utils.fn_map_marketing_channel`(
      `ga4_utils.fn_clean_utm`(COALESCE(e.collected_traffic_source.manual_source, `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_source'), e.traffic_source.source)),
      `ga4_utils.fn_clean_utm`(COALESCE(e.collected_traffic_source.manual_medium, `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_medium'), e.traffic_source.medium)),
      `ga4_utils.fn_clean_utm`(COALESCE(e.collected_traffic_source.manual_campaign_name, `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_campaign'), e.traffic_source.name)),
      `ga4_utils.fn_extract_param_string`(e.event_params, 'page_referrer'),
      `ga4_utils.fn_normalize_url_path`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'))
    ) AS marketing_channel,

    -- Modern GA4 Extended UTMs
    `ga4_utils.fn_clean_utm`(COALESCE(e.collected_traffic_source.manual_campaign_id, `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_id'))) AS utm_id,
    `ga4_utils.fn_clean_utm`(COALESCE(e.collected_traffic_source.manual_source_platform, `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_source_platform'))) AS utm_source_platform,
    `ga4_utils.fn_clean_utm`(COALESCE(e.collected_traffic_source.manual_creative_format, `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_creative_format'))) AS utm_creative_format,
    `ga4_utils.fn_clean_utm`(COALESCE(e.collected_traffic_source.manual_marketing_tactic, `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_marketing_tactic'))) AS utm_marketing_tactic,

    -- Device & Geography
    e.device.category AS device_category,
    e.device.operating_system AS device_os,
    e.device.web_info.browser AS device_browser,
    e.geo.country AS geo_country,
    e.geo.region AS geo_region,
    e.geo.city AS geo_city,

    -- Ecommerce fields (clean each candidate before COALESCE so invalid placeholders fall back cleanly)
    COALESCE(
      `ga4_utils.fn_clean_transaction_id`(e.ecommerce.transaction_id),
      `ga4_utils.fn_clean_transaction_id`(`ga4_utils.fn_extract_param_string`(e.event_params, 'transaction_id'))
    ) AS transaction_id,
    COALESCE(
      e.ecommerce.purchase_revenue,
      `ga4_utils.fn_extract_param_float`(e.event_params, 'value'),
      0.0
    ) AS purchase_revenue,
    COALESCE(
      NULLIF(e.ecommerce.total_item_quantity, 0),
      (SELECT SUM(COALESCE(i.quantity, 1)) FROM UNNEST(e.items) AS i),
      0
    ) AS total_item_quantity,
    NULLIF(TRIM(`ga4_utils.fn_extract_param_string`(e.event_params, 'coupon')), '') AS transaction_coupon,
    COALESCE(
      NULLIF(TRIM(`ga4_utils.fn_extract_param_string`(e.event_params, 'currency')), ''),
      NULLIF(TRIM(`ga4_utils.fn_extract_param_string`(e.items[SAFE_OFFSET(0)].item_params, 'currency')), ''),
      'UNKNOWN'
    ) AS currency,
    e.items

  FROM `your_project.analytics_123456789.events_*` AS e
  WHERE _TABLE_SUFFIX BETWEEN start_table_suffix AND end_table_suffix
    AND REGEXP_CONTAINS(_TABLE_SUFFIX, r'^[0-9]{8}$')
);

-- ==============================================================================
-- Project: Database Marketer (dbmarketer.com)
-- Component: GA4 BigQuery Production Schema & Marts
-- File: 03_procedure_hourly_sync.sql
-- Description: Metadata-Driven Hourly Reconciliation & Ingestion Procedure.
--              - Monitors Google's daily export settlement window (and optional
--                30/90/365-day recovery windows) via zero-cost table metadata
--                (__TABLES__.last_modified_time).
--              - Isolates settled daily export shards (`r'^events_([0-9]{8})$'`)
--                and excludes streaming intraday shards.
--              - Enforces immutable `(source_project_id, source_dataset_id)`
--                namespace ownership and single-writer concurrency locking via
--                `ga4_marts.etl_pipeline_locks` with full-scope exception recovery.
--              - Discovers affected session start/end dates across midnight and
--                reconciles cross-partition transaction collisions so each
--                `transaction_id` has a single canonical winner across reruns.
--              - Selects the canonical purchase per `(source_dataset_id, transaction_id)`
--                strictly by earliest recorded `event_timestamp ASC, session_key ASC,
--                stable_event_tiebreaker ASC` without favoring item completeness
--                or duplicate revenue amounts, and records duplicate diagnostics.
-- ==============================================================================

CREATE OR REPLACE PROCEDURE `ga4_marts.sp_hourly_ga4_sync`(
  source_dataset_override STRING,
  lookback_days INT64
)
BEGIN
  DECLARE v_source_dataset STRING;
  DECLARE v_source_project_id STRING;
  DECLARE v_source_dataset_id STRING;
  DECLARE v_target_scope_key STRING;
  DECLARE v_execution_id STRING DEFAULT GENERATE_UUID();
  DECLARE v_lock_owner STRING DEFAULT SESSION_USER();
  DECLARE v_lock_acquired BOOL DEFAULT FALSE;
  DECLARE v_in_transaction BOOL DEFAULT FALSE;
  DECLARE v_conflicting_source_count INT64 DEFAULT 0;
  DECLARE v_effective_lookback INT64;
  DECLARE v_prev_max_lookback INT64 DEFAULT 0;
  DECLARE v_last_watermark_ts TIMESTAMP;
  DECLARE v_batch_upper_ts TIMESTAMP;
  DECLARE v_candidate_start_suffix STRING;
  DECLARE v_modified_suffixes ARRAY<STRING>;
  DECLARE v_discovery_suffixes ARRAY<STRING>;
  DECLARE v_discovery_suffix_list STRING;
  DECLARE v_scan_suffixes ARRAY<STRING>;
  DECLARE v_scan_suffix_list STRING;
  DECLARE v_modified_dates ARRAY<DATE>;
  DECLARE v_target_partition_dates ARRAY<DATE>;
  DECLARE v_rows_sessions INT64 DEFAULT 0;
  DECLARE v_rows_transactions INT64 DEFAULT 0;
  DECLARE v_rows_products INT64 DEFAULT 0;
  DECLARE v_rows_cart_events INT64 DEFAULT 0;

  -- Set target raw dataset and effective lookback window (default 30 days; supports 90/365 recovery scans)
  SET v_source_dataset = COALESCE(NULLIF(TRIM(source_dataset_override), ''), 'your_project.analytics_123456789');
  SET v_source_project_id = IF(
    STRPOS(v_source_dataset, '.') > 0,
    SPLIT(v_source_dataset, '.')[OFFSET(0)],
    @@project_id
  );
  SET v_source_dataset_id = IF(
    STRPOS(v_source_dataset, '.') > 0,
    SPLIT(v_source_dataset, '.')[OFFSET(1)],
    v_source_dataset
  );
  SET v_target_scope_key = CONCAT('ga4_marts:', v_source_project_id, '.', v_source_dataset_id);
  SET v_effective_lookback = COALESCE(IF(lookback_days IS NULL OR lookback_days <= 0, 30, lookback_days), 30);

  -- ----------------------------------------------------------------------------
  -- Step 1A: Complete Source Identity & Target Namespace Ownership Guard
  --          Enforces one immutable (source_project_id, source_dataset_id)
  --          owner per ga4_marts target namespace before any lock or table write.
  -- ----------------------------------------------------------------------------
  SET v_conflicting_source_count = (
    SELECT COUNT(1)
    FROM (
      SELECT source_project_id, source_dataset_id
      FROM `ga4_marts.etl_watermark`
      WHERE pipeline_name = 'sp_hourly_ga4_sync'
        AND execution_status IN ('SUCCESS', 'RUNNING')
        AND (source_project_id != v_source_project_id OR source_dataset_id != v_source_dataset_id)
      UNION ALL
      SELECT source_project_id, source_dataset_id
      FROM `ga4_marts.etl_pipeline_locks`
      WHERE pipeline_name = 'sp_hourly_ga4_sync'
        AND (source_project_id != v_source_project_id OR source_dataset_id != v_source_dataset_id)
      UNION ALL
      SELECT v_source_project_id AS source_project_id, source_dataset_id
      FROM `ga4_marts.fct_ga4_sessions`
      WHERE source_dataset_id != v_source_dataset_id
      LIMIT 1
    )
  );

  IF v_conflicting_source_count > 0 THEN
    RAISE USING MESSAGE = FORMAT(
      'SINGLE_SOURCE_OWNERSHIP_VIOLATION: Target schema ga4_marts is already bound to a different (source_project_id, source_dataset_id) owner. Refusing to mutate shared target for %s.%s.',
      v_source_project_id,
      v_source_dataset_id
    );
  END IF;

  -- ----------------------------------------------------------------------------
  -- Step 1B: Atomic Single-Writer Lock Acquisition with Stale-Lock Recovery
  --          Uses an atomic BigQuery MERGE on ga4_marts.etl_pipeline_locks.
  -- ----------------------------------------------------------------------------
  MERGE INTO `ga4_marts.etl_pipeline_locks` AS target
  USING (
    SELECT
      v_target_scope_key AS target_scope_key,
      'sp_hourly_ga4_sync' AS pipeline_name,
      v_source_project_id AS source_project_id,
      v_source_dataset_id AS source_dataset_id,
      v_execution_id AS execution_id,
      v_lock_owner AS lock_owner,
      CURRENT_TIMESTAMP() AS now_ts,
      TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 MINUTE) AS expires_ts
  ) AS src
  ON target.target_scope_key = src.target_scope_key
  WHEN MATCHED AND (target.lock_status != 'LOCKED' OR target.expires_at <= src.now_ts) THEN
    UPDATE SET
      pipeline_name = src.pipeline_name,
      source_project_id = src.source_project_id,
      source_dataset_id = src.source_dataset_id,
      execution_id = src.execution_id,
      lock_owner = src.lock_owner,
      lock_status = 'LOCKED',
      acquired_at = src.now_ts,
      expires_at = src.expires_ts,
      released_at = NULL,
      failure_reason = NULL
  WHEN NOT MATCHED THEN
    INSERT (
      target_scope_key,
      pipeline_name,
      source_project_id,
      source_dataset_id,
      execution_id,
      lock_owner,
      lock_status,
      acquired_at,
      expires_at,
      released_at,
      failure_reason
    )
    VALUES (
      src.target_scope_key,
      src.pipeline_name,
      src.source_project_id,
      src.source_dataset_id,
      src.execution_id,
      src.lock_owner,
      'LOCKED',
      src.now_ts,
      src.expires_ts,
      NULL,
      NULL
    );

  -- Verify that THIS invocation (v_execution_id) is the sole confirmed lock owner
  SET v_lock_acquired = COALESCE(
    (
      SELECT
        COUNTIF(lock_status = 'LOCKED' AND execution_id = v_execution_id) = 1
        AND COUNTIF(lock_status = 'LOCKED') = 1
      FROM `ga4_marts.etl_pipeline_locks`
      WHERE target_scope_key = v_target_scope_key
    ),
    FALSE
  );

  IF NOT v_lock_acquired THEN
    RAISE USING MESSAGE = FORMAT(
      'ABORT_CONCURRENT_RUN: Concurrent sp_hourly_ga4_sync execution already holds active lock on %s for %s.%s.',
      v_target_scope_key,
      v_source_project_id,
      v_source_dataset_id
    );
  END IF;

  -- ----------------------------------------------------------------------------
  -- Outer Lock-Held Protected Block:
  -- Any failure anywhere after lock acquisition — including metadata inspection,
  -- dynamic SQL generation, temporary table staging, or multi-mart transaction
  -- execution — rolls back any active transaction, releases the lock as
  -- FAILED_RELEASED, and logs FAILED to etl_watermark.
  -- ----------------------------------------------------------------------------
  BEGIN
    -- Record RUNNING audit entry correlated by v_execution_id
    INSERT INTO `ga4_marts.etl_watermark` (
      pipeline_name,
      source_project_id,
      source_dataset_id,
      table_name,
      execution_id,
      lock_owner,
      last_processed_date_est,
      rows_processed,
      execution_status,
      execution_timestamp,
      max_source_modified_ts,
      last_lookback_days,
      notes
    ) VALUES (
      'sp_hourly_ga4_sync',
      v_source_project_id,
      v_source_dataset_id,
      'fct_ga4_sessions',
      v_execution_id,
      v_lock_owner,
      CURRENT_DATE('America/New_York'),
      0,
      'RUNNING',
      CURRENT_TIMESTAMP(),
      NULL,
      v_effective_lookback,
      FORMAT('Acquired single-writer lock %s (execution_id=%s)', v_target_scope_key, v_execution_id)
    );

    -- Retrieve latest settled watermark for this (pipeline, source_project, source_dataset, table)
    SET (v_last_watermark_ts, v_prev_max_lookback) = (
      SELECT AS STRUCT
        MAX(COALESCE(max_source_modified_ts, execution_timestamp)),
        COALESCE(MAX(COALESCE(last_lookback_days, 30)), 0)
      FROM `ga4_marts.etl_watermark`
      WHERE pipeline_name = 'sp_hourly_ga4_sync'
        AND source_project_id = v_source_project_id
        AND source_dataset_id = v_source_dataset_id
        AND table_name = 'fct_ga4_sessions'
        AND execution_status = 'SUCCESS'
    );

    IF v_last_watermark_ts IS NULL THEN
      SET v_last_watermark_ts = TIMESTAMP('1970-01-01 00:00:00 UTC');
    END IF;

    SET v_candidate_start_suffix = FORMAT_DATE(
      '%Y%m%d',
      DATE_SUB(CURRENT_DATE('America/New_York'), INTERVAL v_effective_lookback DAY)
    );

    -- --------------------------------------------------------------------------
    -- Step 2: Zero-Byte Metadata Reconciliation Check
    --         Inspects `__TABLES__.last_modified_time` for settled daily shards.
    -- --------------------------------------------------------------------------
    EXECUTE IMMEDIATE FORMAT("""
      WITH candidate_shards AS (
        SELECT
          REGEXP_EXTRACT(table_id, r'^events_([0-9]{8})$') AS suffix,
          TIMESTAMP_MILLIS(last_modified_time) AS shard_mod_ts
        FROM `%s.__TABLES__`
        WHERE REGEXP_CONTAINS(table_id, r'^events_[0-9]{8}$')
          AND NOT table_id LIKE '%%intraday%%'
          AND table_id >= 'events_%s'
      ),
      existing_partitions AS (
        SELECT DISTINCT FORMAT_DATE('%%Y%%m%%d', session_date_est) AS suffix
        FROM `ga4_marts.fct_ga4_sessions`
        WHERE source_dataset_id = '%s'
          AND session_date_est >= PARSE_DATE('%%Y%%m%%d', '%s')
      )
      SELECT
        ARRAY_AGG(c.suffix ORDER BY c.suffix),
        MAX(c.shard_mod_ts)
      FROM candidate_shards AS c
      LEFT JOIN existing_partitions AS p
        ON c.suffix = p.suffix
      WHERE c.shard_mod_ts > TIMESTAMP('%s')
         OR (%d > %d AND p.suffix IS NULL)
    """,
      v_source_dataset,
      v_candidate_start_suffix,
      v_source_dataset_id,
      v_candidate_start_suffix,
      CAST(v_last_watermark_ts AS STRING),
      v_effective_lookback,
      v_prev_max_lookback
    )
    INTO v_modified_suffixes, v_batch_upper_ts;

    -- --------------------------------------------------------------------------
    -- Step 3: Natural Exit Guard (Zero-Cost Idle Exit + Clean Lock Release)
    -- --------------------------------------------------------------------------
    IF v_modified_suffixes IS NULL OR ARRAY_LENGTH(v_modified_suffixes) = 0 THEN
      UPDATE `ga4_marts.etl_pipeline_locks`
      SET
        lock_status = 'RELEASED',
        released_at = CURRENT_TIMESTAMP()
      WHERE target_scope_key = v_target_scope_key
        AND execution_id = v_execution_id;

      INSERT INTO `ga4_marts.etl_watermark` (
        pipeline_name,
        source_project_id,
        source_dataset_id,
        table_name,
        execution_id,
        lock_owner,
        last_processed_date_est,
        rows_processed,
        execution_status,
        execution_timestamp,
        max_source_modified_ts,
        last_lookback_days,
        notes
      ) VALUES
      (
        'sp_hourly_ga4_sync',
        v_source_project_id,
        v_source_dataset_id,
        'fct_ga4_sessions',
        v_execution_id,
        v_lock_owner,
        CURRENT_DATE('America/New_York'),
        0,
        'SKIPPED_UP_TO_DATE',
        CURRENT_TIMESTAMP(),
        v_last_watermark_ts,
        GREATEST(v_prev_max_lookback, v_effective_lookback),
        FORMAT('All daily export shards in %d-day reconciliation window are up to date for %s.%s.', v_effective_lookback, v_source_project_id, v_source_dataset_id)
      ),
      (
        'sp_hourly_ga4_sync',
        v_source_project_id,
        v_source_dataset_id,
        'fct_ga4_transactions',
        v_execution_id,
        v_lock_owner,
        CURRENT_DATE('America/New_York'),
        0,
        'SKIPPED_UP_TO_DATE',
        CURRENT_TIMESTAMP(),
        v_last_watermark_ts,
        GREATEST(v_prev_max_lookback, v_effective_lookback),
        FORMAT('All daily export shards in %d-day reconciliation window are up to date for %s.%s.', v_effective_lookback, v_source_project_id, v_source_dataset_id)
      );
      RETURN;
    END IF;

    -- Compute the DATE array corresponding to modified shards
    SET v_modified_dates = ARRAY(
      SELECT PARSE_DATE('%Y%m%d', s)
      FROM UNNEST(v_modified_suffixes) AS s
    );

    -- --------------------------------------------------------------------------
    -- Step 4A (Pass 1 Discovery): Discover Affected Session Start/End Dates &
    --         Cross-Partition Transaction Collisions
    --         1. Captures MIN(event_date_est) and MAX(event_date_est) for every
    --            session touched by `v_modified_dates` across {-1, 0, +1} days.
    --         2. Checks if any `transaction_id` in the discovery window already
    --            exists in `ga4_marts.fct_ga4_transactions` outside the current
    --            window, and unions its stored `transaction_date_est` and owning
    --            `session_date_est` into `v_target_partition_dates` so historical
    --            and candidate purchase events are reconciled together.
    -- --------------------------------------------------------------------------
    SET v_discovery_suffixes = ARRAY(
      SELECT DISTINCT FORMAT_DATE('%Y%m%d', DATE_ADD(d, INTERVAL offset DAY)) AS suffix
      FROM UNNEST(v_modified_dates) AS d,
      UNNEST([-1, 0, 1]) AS offset
      ORDER BY suffix
    );

    SET v_discovery_suffix_list = (
      SELECT STRING_AGG(FORMAT("'%s'", s), ', ')
      FROM UNNEST(v_discovery_suffixes) AS s
    );

    -- Materialize available settled daily shards so target partition closure
    -- and pre-delete guards never select or delete a partition whose raw daily
    -- export shard has expired or does not exist.
    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TEMP TABLE temp_available_daily_shards AS
      SELECT DISTINCT REGEXP_EXTRACT(table_id, r'^events_([0-9]{8})$') AS suffix
      FROM `%s.__TABLES__`
      WHERE REGEXP_CONTAINS(table_id, r'^events_[0-9]{8}$')
        AND NOT table_id LIKE '%%intraday%%'
    """, v_source_dataset);

    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TEMP TABLE temp_affected_session_starts AS
      WITH raw_keys AS (
        SELECT
          _TABLE_SUFFIX AS source_suffix,
          e.event_timestamp,
          TIMESTAMP_MICROS(e.event_timestamp) AS event_timestamp_utc,
          `ga4_utils.fn_utc_to_est_date`(e.event_timestamp) AS event_date_est,
          e.event_name,
          COALESCE(
            `ga4_utils.fn_clean_transaction_id`(e.ecommerce.transaction_id),
            `ga4_utils.fn_clean_transaction_id`(`ga4_utils.fn_extract_param_string`(e.event_params, 'transaction_id'))
          ) AS transaction_id,
          COALESCE(
            IF(
              e.user_pseudo_id IS NOT NULL AND `ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id') IS NOT NULL,
              CONCAT(e.user_pseudo_id, '.', CAST(`ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id') AS STRING)),
              NULL
            ),
            CONCAT('ping.', e.event_date, '.', CAST(e.event_timestamp AS STRING))
          ) AS session_key
        FROM `%s.events_*` AS e
        WHERE _TABLE_SUFFIX IN (%s)
          AND REGEXP_CONTAINS(_TABLE_SUFFIX, r'^[0-9]{8}$')
          AND NOT REGEXP_CONTAINS(_TABLE_SUFFIX, r'intraday')
      ),
      touched_sessions AS (
        SELECT DISTINCT session_key
        FROM raw_keys
        WHERE PARSE_DATE('%%Y%%m%%d', source_suffix) IN UNNEST(@modified_dates)
           OR event_date_est IN UNNEST(@modified_dates)
      ),
      candidate_txns AS (
        SELECT
          transaction_id,
          MIN(event_timestamp_utc) AS min_candidate_ts
        FROM raw_keys
        WHERE event_name = 'purchase'
          AND transaction_id IS NOT NULL
        GROUP BY transaction_id
      ),
      available_raw_shards AS (
        SELECT REGEXP_EXTRACT(table_id, r'^events_([0-9]{8})$') AS suffix
        FROM `%s.__TABLES__`
        WHERE REGEXP_CONTAINS(table_id, r'^events_[0-9]{8}$')
          AND NOT table_id LIKE '%%intraday%%'
      ),
      prior_stored_txn_dates AS (
        -- Only expand target partitions for a stored transaction when:
        --   (1) A strictly earlier timestamp surfaced via backfill (`c.min_candidate_ts < t.transaction_timestamp`), AND
        --   (2) The historical raw shards exist in `available_raw_shards` so the old partition can be rebuilt from raw data.
        -- When `t.transaction_timestamp <= c.min_candidate_ts` (earlier stored winner still wins) or when the old raw
        -- shard has expired, the historical partition is NEVER added to `v_target_partition_dates` (preventing deletion
        -- of expired-shard winners); Step 5B & Step 6 handle in-place diagnostic updates or surgical supersession.
        SELECT
          t.session_key,
          COALESCE(s.session_date_est, t.transaction_date_est) AS session_date_est,
          t.transaction_date_est AS session_end_date_est
        FROM `ga4_marts.fct_ga4_transactions` AS t
        INNER JOIN candidate_txns AS c
          ON t.transaction_id = c.transaction_id
        LEFT JOIN `ga4_marts.fct_ga4_sessions` AS s
          ON t.source_dataset_id = s.source_dataset_id
         AND t.session_key = s.session_key
        INNER JOIN available_raw_shards AS a_txn
          ON a_txn.suffix = FORMAT_DATE('%%Y%%m%%d', t.transaction_date_est)
        INNER JOIN available_raw_shards AS a_sess
          ON a_sess.suffix = FORMAT_DATE('%%Y%%m%%d', COALESCE(s.session_date_est, t.transaction_date_est))
        WHERE t.source_dataset_id = '%s'
          AND c.min_candidate_ts < t.transaction_timestamp
      )
      SELECT DISTINCT
        r.session_key,
        MIN(r.event_date_est) AS session_date_est,
        MAX(r.event_date_est) AS session_end_date_est
      FROM raw_keys AS r
      INNER JOIN touched_sessions AS t
        ON r.session_key = t.session_key
      GROUP BY r.session_key
      UNION DISTINCT
      SELECT
        session_key,
        session_date_est,
        session_end_date_est
      FROM prior_stored_txn_dates
    """, v_source_dataset, v_discovery_suffix_list, v_source_dataset, v_source_dataset_id)
    USING v_modified_dates AS modified_dates;

    -- Intersect target partitions with temp_available_daily_shards so an expired
    -- historical shard (e.g. a cross-midnight -1 day boundary whose raw events_YYYYMMDD
    -- shard has expired) is never added to v_target_partition_dates or bulk-deleted.
    SET v_target_partition_dates = ARRAY(
      SELECT DISTINCT d
      FROM (
        SELECT d FROM UNNEST(v_modified_dates) AS d
        UNION DISTINCT
        SELECT session_date_est AS d FROM temp_affected_session_starts WHERE session_date_est IS NOT NULL
        UNION DISTINCT
        SELECT session_end_date_est AS d FROM temp_affected_session_starts WHERE session_end_date_est IS NOT NULL
      )
      WHERE FORMAT_DATE('%Y%m%d', d) IN (SELECT suffix FROM temp_available_daily_shards)
      ORDER BY d
    );

    -- --------------------------------------------------------------------------
    -- Step 4B (Pass 2 Closure): Full {-1, 0, +1} Neighbor Shard Closure for Target Partitions
    -- --------------------------------------------------------------------------
    SET v_scan_suffixes = ARRAY(
      SELECT DISTINCT FORMAT_DATE('%Y%m%d', DATE_ADD(p_date, INTERVAL offset DAY)) AS suffix
      FROM UNNEST(v_target_partition_dates) AS p_date,
      UNNEST([-1, 0, 1]) AS offset
      ORDER BY suffix
    );

    SET v_scan_suffix_list = (
      SELECT STRING_AGG(FORMAT("'%s'", s), ', ')
      FROM UNNEST(v_scan_suffixes) AS s
    );

    -- --------------------------------------------------------------------------
    -- Step 5A: Single Set-Based Extraction Across Full {-1, 0, +1} Closure
    --          Extracts authoritative event-level ecommerce attributes and
    --          computes a deterministic `stable_event_tiebreaker` fingerprint.
    -- --------------------------------------------------------------------------
    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TEMP TABLE temp_stage_events AS
      SELECT
        '%s' AS source_dataset_id,
        e.event_timestamp,
        TIMESTAMP_MICROS(e.event_timestamp) AS event_timestamp_utc,
        `ga4_utils.fn_utc_to_est_datetime`(e.event_timestamp) AS event_datetime_est,
        `ga4_utils.fn_utc_to_est_date`(e.event_timestamp) AS event_date_est,
        e.event_name,
        e.user_pseudo_id,
        `ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id') AS session_id,
        `ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_number') AS session_number,
        `ga4_utils.fn_extract_param_int`(e.event_params, 'engaged_session_event') AS engaged_session_event,
        SAFE_CAST(`ga4_utils.fn_extract_param_string`(e.event_params, 'session_engaged') AS INT64) AS session_engaged_str,
        `ga4_utils.fn_extract_param_int`(e.event_params, 'session_engaged') AS session_engaged_int,

        -- 3-State Traffic Classification
        CASE
          WHEN e.user_pseudo_id IS NOT NULL AND `ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id') IS NOT NULL
            THEN 'COOKIED_SESSION'
          WHEN UPPER(COALESCE(e.privacy_info.analytics_storage, '')) IN ('NO', 'DENIED', 'FALSE')
            THEN 'CONSENT_DENIED_PING'
          ELSE 'UNIDENTIFIED_PING'
        END AS traffic_type,

        -- Collision-resistant synthetic key
        COALESCE(
          IF(
            e.user_pseudo_id IS NOT NULL AND `ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id') IS NOT NULL,
            CONCAT(e.user_pseudo_id, '.', CAST(`ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id') AS STRING)),
            NULL
          ),
          CONCAT(
            'ping.',
            e.event_date,
            '.',
            CAST(
              FARM_FINGERPRINT(
                CONCAT(
                  CAST(e.event_timestamp AS STRING), '|',
                  COALESCE(e.event_name, ''), '|',
                  COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), '|',
                  COALESCE(e.user_pseudo_id, 'anon'), '|',
                  COALESCE(e.geo.country, '')
                )
              ) AS STRING
            )
          )
        ) AS session_key,

        -- Independent Consent Mode status
        CASE
          WHEN UPPER(COALESCE(e.privacy_info.analytics_storage, '')) IN ('YES', 'GRANTED', 'TRUE') THEN 'GRANTED'
          WHEN UPPER(COALESCE(e.privacy_info.analytics_storage, '')) IN ('NO', 'DENIED', 'FALSE') THEN 'DENIED'
          ELSE 'UNKNOWN'
        END AS consent_status,
        CASE
          WHEN UPPER(COALESCE(e.privacy_info.analytics_storage, '')) IN ('YES', 'GRANTED', 'TRUE') THEN 1
          ELSE 0
        END AS is_consented,

        -- Navigation Context & Normalized Path
        `ga4_utils.fn_extract_param_string`(e.event_params, 'page_location') AS page_location,
        `ga4_utils.fn_normalize_url_path`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location')) AS landing_page_path,
        `ga4_utils.fn_extract_param_string`(e.event_params, 'page_title') AS page_title,
        `ga4_utils.fn_extract_param_string`(e.event_params, 'page_referrer') AS page_referrer,

        -- Normalized Lowercased UTM Attribution with Conservative Click-ID Fallback
        `ga4_utils.fn_clean_utm`(COALESCE(
          e.collected_traffic_source.manual_source,
          `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_source'),
          CASE
            WHEN e.collected_traffic_source.gclid IS NOT NULL
              OR REGEXP_CONTAINS(COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), r'(?i)[?&](gclid|wbraid|gbraid)=')
              THEN 'google'
            WHEN REGEXP_CONTAINS(COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), r'(?i)[?&]msclkid=')
              THEN 'bing'
            WHEN REGEXP_CONTAINS(COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), r'(?i)[?&]fbclid=')
              THEN 'facebook'
            WHEN REGEXP_CONTAINS(COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), r'(?i)[?&]ttclid=')
              THEN 'tiktok'
            ELSE NULL
          END,
          e.traffic_source.source
        )) AS utm_source,

        `ga4_utils.fn_clean_utm`(COALESCE(
          e.collected_traffic_source.manual_medium,
          `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_medium'),
          CASE
            WHEN e.collected_traffic_source.gclid IS NOT NULL
              OR REGEXP_CONTAINS(COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), r'(?i)[?&](gclid|wbraid|gbraid|msclkid)=')
              THEN 'cpc'
            WHEN REGEXP_CONTAINS(COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), r'(?i)[?&]ttclid=')
              THEN 'paid_social'
            WHEN REGEXP_CONTAINS(COALESCE(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), ''), r'(?i)[?&]fbclid=')
              THEN IF(
                REGEXP_CONTAINS(
                  LOWER(COALESCE(e.collected_traffic_source.manual_campaign_name, `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_campaign'), e.traffic_source.name, '')),
                  r'(paid|(^|[_ -])(cpc|ppc|cpm|ad|ads|prosp|retarg|boost)($|[_ -]))'
                ),
                'paid_social',
                'social'
              )
            ELSE NULL
          END,
          e.traffic_source.medium
        )) AS utm_medium,

        `ga4_utils.fn_clean_utm`(COALESCE(
          e.collected_traffic_source.manual_campaign_name,
          `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_campaign'),
          e.traffic_source.name
        )) AS utm_campaign,

        `ga4_utils.fn_clean_utm`(COALESCE(
          e.collected_traffic_source.manual_term,
          `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_term')
        )) AS utm_term,

        `ga4_utils.fn_clean_utm`(COALESCE(
          e.collected_traffic_source.manual_content,
          `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_content')
        )) AS utm_content,

        `ga4_utils.fn_clean_utm`(COALESCE(
          e.collected_traffic_source.manual_campaign_id,
          `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_id')
        )) AS utm_id,

        `ga4_utils.fn_clean_utm`(COALESCE(
          e.collected_traffic_source.manual_source_platform,
          `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_source_platform')
        )) AS utm_source_platform,

        `ga4_utils.fn_clean_utm`(COALESCE(
          e.collected_traffic_source.manual_creative_format,
          `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_creative_format')
        )) AS utm_creative_format,

        `ga4_utils.fn_clean_utm`(COALESCE(
          e.collected_traffic_source.manual_marketing_tactic,
          `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_marketing_tactic')
        )) AS utm_marketing_tactic,

        -- Device & Geography Context
        e.device.category AS device_category,
        e.device.operating_system AS device_os,
        e.device.web_info.browser AS device_browser,
        e.geo.country AS geo_country,
        e.geo.region AS geo_region,
        e.geo.city AS geo_city,

        -- Authoritative Ecommerce Attributes (clean each transaction_id candidate before COALESCE)
        COALESCE(
          `ga4_utils.fn_clean_transaction_id`(e.ecommerce.transaction_id),
          `ga4_utils.fn_clean_transaction_id`(`ga4_utils.fn_extract_param_string`(e.event_params, 'transaction_id'))
        ) AS transaction_id,
        COALESCE(
          e.ecommerce.purchase_revenue,
          `ga4_utils.fn_extract_param_float`(e.event_params, 'value'),
          0.0
        ) AS purchase_revenue,
        COALESCE(
          e.ecommerce.tax_value,
          `ga4_utils.fn_extract_param_float`(e.event_params, 'tax'),
          `ga4_utils.fn_extract_param_float`(e.items[SAFE_OFFSET(0)].item_params, 'tax'),
          0.0
        ) AS tax_value,
        COALESCE(
          e.ecommerce.shipping_value,
          `ga4_utils.fn_extract_param_float`(e.event_params, 'shipping'),
          `ga4_utils.fn_extract_param_float`(e.items[SAFE_OFFSET(0)].item_params, 'shipping'),
          0.0
        ) AS shipping_value,
        NULLIF(TRIM(`ga4_utils.fn_extract_param_string`(e.event_params, 'coupon')), '') AS transaction_coupon,
        COALESCE(
          NULLIF(TRIM(`ga4_utils.fn_extract_param_string`(e.event_params, 'currency')), ''),
          NULLIF(TRIM(`ga4_utils.fn_extract_param_string`(e.items[SAFE_OFFSET(0)].item_params, 'currency')), ''),
          'UNKNOWN'
        ) AS currency,
        COALESCE(
          NULLIF(e.ecommerce.total_item_quantity, 0),
          (SELECT SUM(COALESCE(i.quantity, 1)) FROM UNNEST(e.items) AS i),
          0
        ) AS total_item_quantity,
        e.items,
        FARM_FINGERPRINT(
          CONCAT(
            CAST(e.event_timestamp AS STRING), '|',
            COALESCE(e.user_pseudo_id, 'anon'), '|',
            CAST(COALESCE(`ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id'), -1) AS STRING), '|',
            CAST(ROUND(COALESCE(e.ecommerce.purchase_revenue, `ga4_utils.fn_extract_param_float`(e.event_params, 'value'), 0.0), 4) AS STRING), '|',
            CAST(COALESCE(ARRAY_LENGTH(e.items), 0) AS STRING), '|',
            COALESCE(TO_JSON_STRING(e.items), '[]')
          )
        ) AS stable_event_tiebreaker

      FROM `%s.events_*` AS e
      WHERE _TABLE_SUFFIX IN (%s)
        AND REGEXP_CONTAINS(_TABLE_SUFFIX, r'^[0-9]{8}$')
        AND NOT REGEXP_CONTAINS(_TABLE_SUFFIX, r'intraday')
    """, v_source_dataset_id, v_source_dataset, v_scan_suffix_list);

    -- --------------------------------------------------------------------------
    -- Step 5B: Canonical Purchase Selection (`temp_canonical_purchases`) &
    --          Cross-Window Preserved Winner Diagnostics (`temp_preserved_stored_winner_updates`)
    --          Universal Canonical Purchase Rule:
    --          1. Filters to valid `transaction_id` values (`NOT IN ('(not set)', 'null', 'undefined')`).
    --          2. Deduplicates globally per `(source_dataset_id, transaction_id)` —
    --             never per `(session_key, transaction_id)`.
    --          3. Selects the earliest recorded purchase event by
    --             `ORDER BY event_timestamp ASC, session_key ASC, stable_event_tiebreaker ASC`,
    --             regardless of whether the event has items, more complete metadata,
    --             or higher duplicate revenue.
    --          4. Preserves cross-window stored winners on historical partitions (`p.transaction_date_est NOT IN UNNEST(v_target_partition_dates)`)
    --             when `p.transaction_timestamp <= window_min_ts` without deleting the historical partition,
    --             and updates their cumulative duplicate diagnostics idempotently via `temp_preserved_stored_winner_updates`.
    --          5. Supersedes stored rows when a strictly earlier backfill event arrives (`window_min_ts < p.transaction_timestamp`).
    -- --------------------------------------------------------------------------
    -- Note on duplicate diagnostic counters (`duplicate_purchase_event_count`,
    -- `distinct_purchase_session_count`): raw_purchase_candidates is deduplicated
    -- by deterministic event identity `(source_dataset_id, transaction_id, event_timestamp,
    -- session_key, stable_event_tiebreaker)`. Within any self-contained scan window,
    -- these counters are exact set cardinalities; across partial/expired-shard rescans,
    -- they represent cumulative window-observed counters.
    CREATE OR REPLACE TEMP TABLE temp_ranked_purchase_candidates AS
    WITH raw_purchase_candidates AS (
      SELECT
        e.*
      FROM temp_stage_events AS e
      WHERE e.event_name = 'purchase'
        AND e.transaction_id IS NOT NULL
        AND TRIM(e.transaction_id) != ''
        AND LOWER(TRIM(e.transaction_id)) NOT IN ('(not set)', 'not set', 'null', 'undefined', 'n/a', 'na', 'none')
      QUALIFY ROW_NUMBER() OVER (
        PARTITION BY
          e.source_dataset_id,
          e.transaction_id,
          e.event_timestamp,
          e.session_key,
          e.stable_event_tiebreaker
        ORDER BY e.event_timestamp ASC
      ) = 1
    ),
    prior_stored_winners AS (
      SELECT
        t.source_dataset_id,
        t.transaction_id,
        t.session_key,
        t.transaction_timestamp,
        t.transaction_date_est,
        t.purchase_revenue,
        t.total_item_quantity,
        t.duplicate_purchase_event_count,
        t.distinct_purchase_session_count,
        t.first_observed_timestamp,
        t.last_observed_timestamp,
        t.min_observed_revenue,
        t.max_observed_revenue,
        t.has_amount_disagreement,
        t.has_items_disagreement,
        t.has_session_disagreement
      FROM `ga4_marts.fct_ga4_transactions` AS t
      WHERE t.source_dataset_id = v_source_dataset_id
        AND t.transaction_id IN (SELECT DISTINCT transaction_id FROM raw_purchase_candidates)
    ),
    candidate_window_rollups AS (
      SELECT
        e.source_dataset_id,
        e.transaction_id,
        COUNT(1) AS window_event_count,
        COUNT(DISTINCT e.session_key) AS window_distinct_sessions,
        MIN(e.event_timestamp_utc) AS window_min_ts,
        MAX(e.event_timestamp_utc) AS window_max_ts,
        CAST(MIN(e.purchase_revenue) AS NUMERIC) AS window_min_rev,
        CAST(MAX(e.purchase_revenue) AS NUMERIC) AS window_max_rev,
        IF(
          MIN(COALESCE(TO_JSON_STRING(e.items), '[]')) != MAX(COALESCE(TO_JSON_STRING(e.items), '[]')),
          1,
          0
        ) AS window_items_disagreement,
        COUNTIF(
          p.transaction_id IS NOT NULL
          AND (
            e.event_timestamp_utc < p.first_observed_timestamp
            OR e.event_timestamp_utc > p.last_observed_timestamp
          )
        ) AS new_outside_events,
        COUNT(
          DISTINCT IF(
            p.transaction_id IS NOT NULL
            AND (
              e.event_timestamp_utc < p.first_observed_timestamp
              OR e.event_timestamp_utc > p.last_observed_timestamp
            )
            AND e.session_key != COALESCE(p.session_key, ''),
            e.session_key,
            NULL
          )
        ) AS new_outside_sessions,
        MAX(IF(p.session_key IS NOT NULL AND e.session_key != p.session_key, 1, 0)) AS any_diff_session_from_stored
      FROM raw_purchase_candidates AS e
      LEFT JOIN prior_stored_winners AS p
        ON e.source_dataset_id = p.source_dataset_id
       AND e.transaction_id = p.transaction_id
      GROUP BY e.source_dataset_id, e.transaction_id
    )
    SELECT
      e.*,
      COALESCE(ARRAY_LENGTH(e.items), 0) AS raw_items_count,
      CASE
        WHEN p.transaction_id IS NULL THEN w.window_event_count
        WHEN p.transaction_date_est NOT IN UNNEST(v_target_partition_dates) THEN
          IF(
            w.new_outside_events > 0,
            COALESCE(p.duplicate_purchase_event_count, 1) + w.new_outside_events,
            GREATEST(w.window_event_count, COALESCE(p.duplicate_purchase_event_count, 1))
          )
        ELSE
          GREATEST(w.window_event_count, COALESCE(p.duplicate_purchase_event_count, 1))
      END AS duplicate_purchase_event_count,
      CASE
        WHEN p.transaction_id IS NULL THEN w.window_distinct_sessions
        WHEN p.transaction_date_est NOT IN UNNEST(v_target_partition_dates) THEN
          IF(
            w.new_outside_events > 0,
            COALESCE(p.distinct_purchase_session_count, 1) + w.new_outside_sessions,
            GREATEST(w.window_distinct_sessions, COALESCE(p.distinct_purchase_session_count, 1))
          )
        ELSE
          GREATEST(w.window_distinct_sessions, COALESCE(p.distinct_purchase_session_count, 1))
      END AS distinct_purchase_session_count,
      LEAST(
        w.window_min_ts,
        COALESCE(p.first_observed_timestamp, w.window_min_ts)
      ) AS first_observed_timestamp,
      GREATEST(
        w.window_max_ts,
        COALESCE(p.last_observed_timestamp, w.window_max_ts)
      ) AS last_observed_timestamp,
      LEAST(
        w.window_min_rev,
        COALESCE(p.min_observed_revenue, w.window_min_rev)
      ) AS min_observed_revenue,
      GREATEST(
        w.window_max_rev,
        COALESCE(p.max_observed_revenue, w.window_max_rev)
      ) AS max_observed_revenue,
      IF(
        LEAST(w.window_min_rev, COALESCE(p.min_observed_revenue, w.window_min_rev))
        != GREATEST(w.window_max_rev, COALESCE(p.max_observed_revenue, w.window_max_rev)),
        1,
        0
      ) AS has_amount_disagreement,
      GREATEST(
        w.window_items_disagreement,
        COALESCE(p.has_items_disagreement, 0)
      ) AS has_items_disagreement,
      IF(
        w.window_distinct_sessions > 1
        OR w.any_diff_session_from_stored = 1
        OR COALESCE(p.has_session_disagreement, 0) = 1,
        1,
        0
      ) AS has_session_disagreement,
      IF(
        p.transaction_id IS NOT NULL
        AND p.transaction_date_est NOT IN UNNEST(v_target_partition_dates)
        AND p.transaction_timestamp <= w.window_min_ts,
        TRUE,
        FALSE
      ) AS has_earlier_expired_stored_winner,
      ROW_NUMBER() OVER (
        PARTITION BY e.source_dataset_id, e.transaction_id
        ORDER BY
          e.event_timestamp ASC,
          e.session_key ASC,
          e.stable_event_tiebreaker ASC
      ) AS purchase_rn
    FROM raw_purchase_candidates AS e
    INNER JOIN candidate_window_rollups AS w
      ON e.source_dataset_id = w.source_dataset_id
     AND e.transaction_id = w.transaction_id
    LEFT JOIN prior_stored_winners AS p
      ON e.source_dataset_id = p.source_dataset_id
     AND e.transaction_id = p.transaction_id;

    CREATE OR REPLACE TEMP TABLE temp_canonical_purchases AS
    SELECT * EXCEPT(purchase_rn, has_earlier_expired_stored_winner)
    FROM temp_ranked_purchase_candidates
    WHERE purchase_rn = 1
      AND NOT has_earlier_expired_stored_winner;

    CREATE OR REPLACE TEMP TABLE temp_preserved_stored_winner_updates AS
    SELECT
      source_dataset_id,
      transaction_id,
      duplicate_purchase_event_count,
      distinct_purchase_session_count,
      first_observed_timestamp,
      last_observed_timestamp,
      min_observed_revenue,
      max_observed_revenue,
      has_amount_disagreement,
      has_items_disagreement,
      has_session_disagreement
    FROM temp_ranked_purchase_candidates
    WHERE purchase_rn = 1
      AND has_earlier_expired_stored_winner;

    -- Materialize displaced old-session purchase deltas for any stored transaction
    -- outside v_target_partition_dates that is superseded by an earlier purchase timestamp
    -- in temp_canonical_purchases, enabling LEFT JOIN existence & pre-decrement sufficiency
    -- checks and post-write cross-partition session reconciliation.
    CREATE OR REPLACE TEMP TABLE temp_affected_old_sessions AS
    SELECT
      t.source_dataset_id,
      t.session_key,
      MAX(IF(t.session_key NOT LIKE 'ping.%' AND t.ga_session_id IS NOT NULL, 1, 0)) AS is_cookied_session,
      COUNT(1) AS superseded_txn_count,
      COALESCE(SUM(t.purchase_revenue), CAST(0 AS NUMERIC)) AS superseded_revenue,
      COALESCE(SUM(t.total_item_quantity), 0) AS superseded_items
    FROM `ga4_marts.fct_ga4_transactions` AS t
    INNER JOIN temp_canonical_purchases AS c
      ON t.source_dataset_id = c.source_dataset_id
     AND t.transaction_id = c.transaction_id
    WHERE t.source_dataset_id = v_source_dataset_id
      AND t.transaction_date_est NOT IN UNNEST(v_target_partition_dates)
      AND t.session_key NOT IN (
        SELECT DISTINCT session_key
        FROM temp_stage_events
        WHERE event_date_est IN UNNEST(v_target_partition_dates)
      )
    GROUP BY t.source_dataset_id, t.session_key;

    -- --------------------------------------------------------------------------
    -- Step 6: Atomic Multi-Mart Transaction with Source Isolation & Rollback
    --         1. Reconciles any out-of-window stored rows superseded by an earlier
    --            backfilled timestamp or updated with new duplicate diagnostics.
    --         2. Deletes and repopulates affected target partitions scoped strictly
    --            by source_dataset_id = v_source_dataset_id across all 4 marts.
    -- --------------------------------------------------------------------------
    SET v_in_transaction = TRUE;
    BEGIN TRANSACTION;

    -- 6.0A: If a backfilled shard introduced a strictly earlier purchase timestamp for a
    --       transaction whose previous winner lived on an untouched partition (e.g., its
    --       historical raw shard expired), verify via LEFT JOIN that the displaced cookied
    --       session row exists in fct_ga4_sessions and has sufficient pre-decrement aggregates
    --       (never clamping negative intermediates to zero), decrement that superseded order
    --       from its old session row, and delete the superseded transaction/product rows.
    ASSERT (
      SELECT COUNTIF(
        (sup.is_cookied_session = 1 AND s.session_key IS NULL)
        OR (
          s.session_key IS NOT NULL
          AND s.session_date_est NOT IN UNNEST(v_target_partition_dates)
          AND (
            s.transactions_count < sup.superseded_txn_count
            OR (s.total_purchase_revenue - sup.superseded_revenue) < CAST(-0.005 AS NUMERIC)
            OR s.total_items_purchased < sup.superseded_items
          )
        )
      )
      FROM temp_affected_old_sessions AS sup
      LEFT JOIN `ga4_marts.fct_ga4_sessions` AS s
        ON s.source_dataset_id = sup.source_dataset_id
       AND s.session_key = sup.session_key
    ) = 0 AS 'CRITICAL FAILURE: Displaced historical session row is missing from fct_ga4_sessions or has stored purchase aggregates smaller than superseded transaction totals.';

    UPDATE `ga4_marts.fct_ga4_sessions` AS s
    SET
      transactions_count = s.transactions_count - sup.superseded_txn_count,
      total_purchase_revenue = s.total_purchase_revenue - sup.superseded_revenue,
      total_items_purchased = s.total_items_purchased - sup.superseded_items,
      has_purchase = IF((s.transactions_count - sup.superseded_txn_count) > 0, 1, 0),
      processed_at = CURRENT_TIMESTAMP()
    FROM temp_affected_old_sessions AS sup
    WHERE s.source_dataset_id = sup.source_dataset_id
      AND s.session_key = sup.session_key
      AND s.session_date_est NOT IN UNNEST(v_target_partition_dates);

    DELETE FROM `ga4_marts.fct_ga4_transaction_products`
    WHERE source_dataset_id = v_source_dataset_id
      AND transaction_date_est NOT IN UNNEST(v_target_partition_dates)
      AND transaction_id IN (SELECT transaction_id FROM temp_canonical_purchases);

    DELETE FROM `ga4_marts.fct_ga4_transactions`
    WHERE source_dataset_id = v_source_dataset_id
      AND transaction_date_est NOT IN UNNEST(v_target_partition_dates)
      AND transaction_id IN (SELECT transaction_id FROM temp_canonical_purchases);

    -- 6.0B: Update duplicate diagnostic columns in-place for preserved historical winners
    --       whose partition is outside `v_target_partition_dates` (never deleting their partition).
    UPDATE `ga4_marts.fct_ga4_transactions` AS t
    SET
      duplicate_purchase_event_count = u.duplicate_purchase_event_count,
      distinct_purchase_session_count = u.distinct_purchase_session_count,
      first_observed_timestamp = u.first_observed_timestamp,
      last_observed_timestamp = u.last_observed_timestamp,
      min_observed_revenue = u.min_observed_revenue,
      max_observed_revenue = u.max_observed_revenue,
      has_amount_disagreement = u.has_amount_disagreement,
      has_items_disagreement = u.has_items_disagreement,
      has_session_disagreement = u.has_session_disagreement,
      processed_at = CURRENT_TIMESTAMP()
    FROM temp_preserved_stored_winner_updates AS u
    WHERE t.source_dataset_id = u.source_dataset_id
      AND t.transaction_id = u.transaction_id
      AND t.transaction_date_est NOT IN UNNEST(v_target_partition_dates);

    -- 6.0C: Fail-closed available-shard guard before partition DELETE.
    --       Verifies that every date in v_target_partition_dates has a corresponding
    --       settled daily shard in temp_available_daily_shards before deleting.
    ASSERT (
      SELECT COUNTIF(
        FORMAT_DATE('%Y%m%d', target_date) NOT IN (SELECT suffix FROM temp_available_daily_shards)
      )
      FROM UNNEST(v_target_partition_dates) AS target_date
    ) = 0 AS 'CRITICAL FAILURE: Attempted to delete a target partition in v_target_partition_dates whose raw daily export shard is unavailable in temp_available_daily_shards.';

    DELETE FROM `ga4_marts.fct_ga4_sessions`
    WHERE source_dataset_id = v_source_dataset_id
      AND session_date_est IN UNNEST(v_target_partition_dates);

    DELETE FROM `ga4_marts.fct_ga4_transactions`
    WHERE source_dataset_id = v_source_dataset_id
      AND transaction_date_est IN UNNEST(v_target_partition_dates);

    DELETE FROM `ga4_marts.fct_ga4_transaction_products`
    WHERE source_dataset_id = v_source_dataset_id
      AND transaction_date_est IN UNNEST(v_target_partition_dates);

    DELETE FROM `ga4_marts.fct_ga4_cart_events`
    WHERE source_dataset_id = v_source_dataset_id
      AND event_date_est IN UNNEST(v_target_partition_dates);

    -- --------------------------------------------------------------------------
    -- Step 6A: Materialize Sessions Mart (fct_ga4_sessions — 47 Canonical Columns)
    --          Joins temp_canonical_purchases so only the globally winning session
    --          receives credit for each transaction_id.
    -- --------------------------------------------------------------------------
    INSERT INTO `ga4_marts.fct_ga4_sessions` (
      source_dataset_id,
      session_key,
      session_date_est,
      session_start_ts,
      session_end_ts,
      session_start_est,
      session_end_est,
      session_duration_seconds,
      traffic_type,
      user_pseudo_id,
      session_id,
      session_number,
      consent_status,
      is_consented,
      landing_page,
      landing_page_path,
      landing_page_title,
      exit_page,
      page_referrer,
      page_views,
      event_count,
      is_engaged_session,
      marketing_channel,
      utm_source,
      utm_medium,
      utm_campaign,
      utm_term,
      utm_content,
      utm_id,
      utm_source_platform,
      utm_creative_format,
      utm_marketing_tactic,
      device_category,
      device_os,
      device_browser,
      geo_country,
      geo_region,
      geo_city,
      has_view_item,
      has_add_to_cart,
      has_checkout,
      has_purchase,
      has_newsletter_signup,
      total_purchase_revenue,
      total_items_purchased,
      transactions_count,
      processed_at
    )
    WITH session_purchase_rollup AS (
      SELECT
        source_dataset_id,
        session_key,
        CAST(SUM(purchase_revenue) AS NUMERIC) AS dedup_purchase_revenue,
        SUM(total_item_quantity) AS dedup_items_purchased,
        COUNT(DISTINCT transaction_id) AS dedup_transactions_count
      FROM temp_canonical_purchases
      GROUP BY source_dataset_id, session_key
    ),
    aggregated_sessions AS (
      SELECT
        e.source_dataset_id,
        e.session_key,
        MIN(e.event_date_est) AS session_date_est,
        TIMESTAMP_MICROS(MIN(e.event_timestamp)) AS session_start_ts,
        TIMESTAMP_MICROS(MAX(e.event_timestamp)) AS session_end_ts,
        MIN(e.event_datetime_est) AS session_start_est,
        MAX(e.event_datetime_est) AS session_end_est,
        CAST(DIV(MAX(e.event_timestamp) - MIN(e.event_timestamp), 1000000) AS INT64) AS session_duration_seconds,

        ANY_VALUE(e.traffic_type) AS traffic_type,
        ANY_VALUE(e.user_pseudo_id) AS user_pseudo_id,
        ANY_VALUE(e.session_id) AS session_id,
        ANY_VALUE(e.session_number) AS session_number,
        ARRAY_AGG(e.consent_status ORDER BY e.event_timestamp DESC LIMIT 1)[OFFSET(0)] AS consent_status,
        MAX(e.is_consented) AS is_consented,

        ARRAY_AGG(e.page_location IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS landing_page,
        COALESCE(ARRAY_AGG(e.landing_page_path IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)], '/') AS landing_page_path,
        ARRAY_AGG(e.page_title IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS landing_page_title,
        ARRAY_AGG(e.page_location IGNORE NULLS ORDER BY e.event_timestamp DESC LIMIT 1)[SAFE_OFFSET(0)] AS exit_page,
        ARRAY_AGG(e.page_referrer IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS page_referrer,
        COUNTIF(e.event_name = 'page_view') AS page_views,
        COUNT(1) AS event_count,
        MAX(COALESCE(e.session_engaged_str, e.session_engaged_int, e.engaged_session_event, 0)) AS native_session_engaged,

        COALESCE(ARRAY_AGG(e.utm_source IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)], '(direct)') AS utm_source,
        COALESCE(ARRAY_AGG(e.utm_medium IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)], '(none)') AS utm_medium,
        COALESCE(ARRAY_AGG(e.utm_campaign IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)], '(not set)') AS utm_campaign,
        ARRAY_AGG(e.utm_term IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS utm_term,
        ARRAY_AGG(e.utm_content IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS utm_content,
        ARRAY_AGG(e.utm_id IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS utm_id,
        ARRAY_AGG(e.utm_source_platform IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS utm_source_platform,
        ARRAY_AGG(e.utm_creative_format IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS utm_creative_format,
        ARRAY_AGG(e.utm_marketing_tactic IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS utm_marketing_tactic,

        ARRAY_AGG(e.device_category IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS device_category,
        ARRAY_AGG(e.device_os IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS device_os,
        ARRAY_AGG(e.device_browser IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS device_browser,
        ARRAY_AGG(e.geo_country IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS geo_country,
        ARRAY_AGG(e.geo_region IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS geo_region,
        ARRAY_AGG(e.geo_city IGNORE NULLS ORDER BY e.event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS geo_city,

        MAX(IF(e.event_name = 'view_item', 1, 0)) AS has_view_item,
        MAX(IF(e.event_name = 'add_to_cart', 1, 0)) AS has_add_to_cart,
        MAX(IF(e.event_name IN ('begin_checkout', 'checkout'), 1, 0)) AS has_checkout,
        IF(COALESCE(ANY_VALUE(p.dedup_transactions_count), 0) > 0, 1, 0) AS has_purchase,
        MAX(IF(e.event_name IN ('newsletter_signup', 'email_signup', 'lead', 'sign_up', 'generate_lead'), 1, 0)) AS has_newsletter_signup,

        COALESCE(ANY_VALUE(p.dedup_purchase_revenue), CAST(0 AS NUMERIC)) AS total_purchase_revenue,
        COALESCE(ANY_VALUE(p.dedup_items_purchased), 0) AS total_items_purchased,
        COALESCE(ANY_VALUE(p.dedup_transactions_count), 0) AS transactions_count,
        CURRENT_TIMESTAMP() AS processed_at
      FROM temp_stage_events AS e
      LEFT JOIN session_purchase_rollup AS p
        ON e.source_dataset_id = p.source_dataset_id
       AND e.session_key = p.session_key
      GROUP BY e.source_dataset_id, e.session_key
    )
    SELECT
      source_dataset_id,
      session_key,
      session_date_est,
      session_start_ts,
      session_end_ts,
      session_start_est,
      session_end_est,
      session_duration_seconds,
      traffic_type,
      user_pseudo_id,
      session_id,
      session_number,
      consent_status,
      is_consented,
      landing_page,
      landing_page_path,
      landing_page_title,
      exit_page,
      page_referrer,
      page_views,
      event_count,
      CASE WHEN traffic_type = 'COOKIED_SESSION' AND (native_session_engaged = 1 OR session_duration_seconds >= 10 OR page_views >= 2 OR has_purchase = 1) THEN 1 ELSE 0 END AS is_engaged_session,
      `ga4_utils.fn_map_marketing_channel`(
        utm_source,
        utm_medium,
        utm_campaign,
        page_referrer,
        landing_page_path
      ) AS marketing_channel,
      utm_source,
      utm_medium,
      utm_campaign,
      utm_term,
      utm_content,
      utm_id,
      utm_source_platform,
      utm_creative_format,
      utm_marketing_tactic,
      device_category,
      device_os,
      device_browser,
      geo_country,
      geo_region,
      geo_city,
      has_view_item,
      has_add_to_cart,
      has_checkout,
      has_purchase,
      has_newsletter_signup,
      total_purchase_revenue,
      total_items_purchased,
      transactions_count,
      processed_at
    FROM aggregated_sessions
    WHERE session_date_est IN UNNEST(v_target_partition_dates);

    SET v_rows_sessions = @@row_count;

    -- --------------------------------------------------------------------------
    -- Step 6B: Materialize Canonical Transactions Mart (fct_ga4_transactions)
    --          Includes native UTC `transaction_timestamp` and duplicate audit
    --          columns (`duplicate_purchase_event_count`, `distinct_purchase_session_count`,
    --          `has_amount_disagreement`, `has_items_disagreement`, `has_session_disagreement`).
    -- --------------------------------------------------------------------------
    INSERT INTO `ga4_marts.fct_ga4_transactions` (
      source_dataset_id,
      transaction_id,
      session_key,
      user_pseudo_id,
      ga_session_id,
      transaction_timestamp,
      transaction_date_est,
      transaction_timestamp_est,
      purchase_revenue,
      tax_value,
      shipping_value,
      coupon,
      currency,
      items_count,
      total_item_quantity,
      marketing_channel,
      utm_source,
      utm_medium,
      utm_campaign,
      duplicate_purchase_event_count,
      distinct_purchase_session_count,
      first_observed_timestamp,
      last_observed_timestamp,
      min_observed_revenue,
      max_observed_revenue,
      has_amount_disagreement,
      has_items_disagreement,
      has_session_disagreement,
      processed_at
    )
    SELECT
      source_dataset_id,
      transaction_id,
      session_key,
      user_pseudo_id,
      session_id AS ga_session_id,
      event_timestamp_utc AS transaction_timestamp,
      event_date_est AS transaction_date_est,
      event_datetime_est AS transaction_timestamp_est,
      CAST(purchase_revenue AS NUMERIC) AS purchase_revenue,
      CAST(tax_value AS NUMERIC) AS tax_value,
      CAST(shipping_value AS NUMERIC) AS shipping_value,
      transaction_coupon AS coupon,
      currency,
      raw_items_count AS items_count,
      total_item_quantity,
      `ga4_utils.fn_map_marketing_channel`(utm_source, utm_medium, utm_campaign, page_referrer, landing_page_path) AS marketing_channel,
      utm_source,
      utm_medium,
      utm_campaign,
      duplicate_purchase_event_count,
      distinct_purchase_session_count,
      first_observed_timestamp,
      last_observed_timestamp,
      min_observed_revenue,
      max_observed_revenue,
      has_amount_disagreement,
      has_items_disagreement,
      has_session_disagreement,
      CURRENT_TIMESTAMP() AS processed_at
    FROM temp_canonical_purchases
    WHERE event_date_est IN UNNEST(v_target_partition_dates);

    SET v_rows_transactions = @@row_count;

    -- --------------------------------------------------------------------------
    -- Step 6C: Materialize Transaction Products Mart (fct_ga4_transaction_products — 17 Columns)
    --          Unnests items strictly from the winning canonical purchase event
    --          with deterministic transaction_line_key and 0-based item_offset.
    -- --------------------------------------------------------------------------
    INSERT INTO `ga4_marts.fct_ga4_transaction_products` (
      source_dataset_id,
      transaction_line_key,
      transaction_id,
      item_offset,
      session_key,
      transaction_date_est,
      item_id,
      item_name,
      item_brand,
      item_category,
      item_category_2,
      item_category_3,
      price,
      quantity,
      item_revenue,
      coupon,
      processed_at
    )
    SELECT
      e.source_dataset_id,
      CONCAT(e.source_dataset_id, '.', e.transaction_id, '.', CAST(item_offset AS STRING)) AS transaction_line_key,
      e.transaction_id,
      item_offset,
      e.session_key,
      e.event_date_est AS transaction_date_est,
      COALESCE(NULLIF(TRIM(item.item_id), ''), NULLIF(TRIM(item.item_name), ''), 'UNKNOWN_ITEM') AS item_id,
      item.item_name,
      item.item_brand,
      item.item_category,
      item.item_category2 AS item_category_2,
      item.item_category3 AS item_category_3,
      CAST(item.price AS NUMERIC) AS price,
      COALESCE(item.quantity, 1) AS quantity,
      CAST(COALESCE(item.item_revenue, item.price * COALESCE(item.quantity, 1)) AS NUMERIC) AS item_revenue,
      COALESCE(
        NULLIF(TRIM(item.coupon), ''),
        NULLIF(TRIM(`ga4_utils.fn_extract_param_string`(item.item_params, 'coupon')), ''),
        e.transaction_coupon
      ) AS coupon,
      CURRENT_TIMESTAMP() AS processed_at
    FROM temp_canonical_purchases AS e
    CROSS JOIN UNNEST(e.items) AS item WITH OFFSET AS item_offset
    WHERE e.event_date_est IN UNNEST(v_target_partition_dates);

    SET v_rows_products = @@row_count;

    -- --------------------------------------------------------------------------
    -- Step 6D: Materialize Cart Events Mart (fct_ga4_cart_events)
    --          Preserves line-item ordinal offset (`WITH OFFSET AS item_offset`)
    --          so repeated SKUs on separate lines in a single cart event are not collapsed.
    -- --------------------------------------------------------------------------
    INSERT INTO `ga4_marts.fct_ga4_cart_events` (
      source_dataset_id,
      event_id,
      session_key,
      user_pseudo_id,
      event_name,
      event_date_est,
      event_timestamp_est,
      item_id,
      item_name,
      item_brand,
      item_category,
      price,
      quantity,
      item_revenue,
      currency,
      processed_at
    )
    SELECT
      e.source_dataset_id,
      TO_HEX(SHA256(CONCAT(
        e.source_dataset_id, '.',
        COALESCE(e.user_pseudo_id, 'anon'), '.',
        CAST(e.event_timestamp AS STRING), '.',
        CAST(e.stable_event_tiebreaker AS STRING), '.',
        e.event_name, '.',
        COALESCE(item.item_id, 'no_item'), '.',
        CAST(COALESCE(item_offset, -1) AS STRING)
      ))) AS event_id,
      e.session_key,
      e.user_pseudo_id,
      e.event_name,
      e.event_date_est,
      e.event_datetime_est AS event_timestamp_est,
      item.item_id,
      item.item_name,
      item.item_brand,
      item.item_category,
      CAST(item.price AS NUMERIC) AS price,
      item.quantity,
      CAST(COALESCE(item.item_revenue, item.price * item.quantity) AS NUMERIC) AS item_revenue,
      COALESCE(
        NULLIF(TRIM(`ga4_utils.fn_extract_param_string`(item.item_params, 'currency')), ''),
        e.currency
      ) AS currency,
      CURRENT_TIMESTAMP() AS processed_at
    FROM temp_stage_events AS e
    LEFT JOIN UNNEST(e.items) AS item WITH OFFSET AS item_offset
    WHERE e.event_name IN ('view_item', 'add_to_cart', 'remove_from_cart', 'view_cart', 'begin_checkout')
      AND e.event_date_est IN UNNEST(v_target_partition_dates);

    SET v_rows_cart_events = @@row_count;

    -- --------------------------------------------------------------------------
    -- Step 6E: Post-Write Fail-Safe Quality Assertions Inside Transaction
    -- --------------------------------------------------------------------------
    ASSERT (
      SELECT COUNT(1) - COUNT(DISTINCT CONCAT(source_dataset_id, ':', session_key))
      FROM `ga4_marts.fct_ga4_sessions`
      WHERE source_dataset_id = v_source_dataset_id
        AND session_date_est IN UNNEST(v_target_partition_dates)
    ) = 0 AS 'Quality Assertion Failure: Duplicate (source_dataset_id, session_key) detected in affected partitions after sync';

    ASSERT (
      SELECT COUNT(1) - COUNT(DISTINCT CONCAT(source_dataset_id, ':', transaction_id))
      FROM `ga4_marts.fct_ga4_transactions`
      WHERE source_dataset_id = v_source_dataset_id
    ) = 0 AS 'Quality Assertion Failure: Duplicate (source_dataset_id, transaction_id) detected in fct_ga4_transactions after sync';

    ASSERT (
      WITH target_and_displaced_sessions AS (
        SELECT
          source_dataset_id,
          session_key,
          transactions_count,
          total_purchase_revenue
        FROM `ga4_marts.fct_ga4_sessions`
        WHERE source_dataset_id = v_source_dataset_id
          AND (
            session_date_est IN UNNEST(v_target_partition_dates)
            OR session_key IN (SELECT session_key FROM temp_affected_old_sessions)
          )
      ),
      affected_txns AS (
        SELECT
          t.session_key,
          COUNT(DISTINCT t.transaction_id) AS txn_cnt,
          COALESCE(SUM(t.purchase_revenue), 0) AS txn_rev
        FROM `ga4_marts.fct_ga4_transactions` AS t
        INNER JOIN target_and_displaced_sessions AS s
          ON t.source_dataset_id = s.source_dataset_id
         AND t.session_key = s.session_key
        WHERE t.source_dataset_id = v_source_dataset_id
        GROUP BY t.session_key
      ),
      session_to_txn_audit AS (
        SELECT COUNTIF(
          s.transactions_count != COALESCE(t.txn_cnt, 0)
          OR ABS(s.total_purchase_revenue - COALESCE(t.txn_rev, 0)) >= 0.01
        ) AS session_mismatch_count
        FROM target_and_displaced_sessions AS s
        LEFT JOIN affected_txns AS t
          ON s.session_key = t.session_key
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
        LEFT JOIN `ga4_marts.fct_ga4_sessions` AS s
          ON t.source_dataset_id = s.source_dataset_id
         AND t.session_key = s.session_key
        WHERE t.source_dataset_id = v_source_dataset_id
          AND t.transaction_date_est IN UNNEST(v_target_partition_dates)
      )
      SELECT
        s_audit.session_mismatch_count
        + t_audit.orphan_cookied_txns
        + IF(t_audit.total_canonical_txns = (t_audit.session_matched_txns + t_audit.unmatched_cookieless_ping_txns), 0, 1)
      FROM session_to_txn_audit AS s_audit
      CROSS JOIN txn_to_session_audit AS t_audit
    ) = 0 AS 'Quality Assertion Failure: Bidirectional session-to-transaction or transaction-to-session reconciliation failed across target and displaced historical sessions';

    -- --------------------------------------------------------------------------
    -- Step 6F: Release Single-Writer Lock & Commit Watermarks for All 4 Marts
    -- --------------------------------------------------------------------------
    UPDATE `ga4_marts.etl_pipeline_locks`
    SET
      lock_status = 'RELEASED',
      released_at = CURRENT_TIMESTAMP(),
      failure_reason = NULL
    WHERE target_scope_key = v_target_scope_key
      AND execution_id = v_execution_id;

    INSERT INTO `ga4_marts.etl_watermark` (
      pipeline_name,
      source_project_id,
      source_dataset_id,
      table_name,
      execution_id,
      lock_owner,
      last_processed_date_est,
      rows_processed,
      execution_status,
      execution_timestamp,
      max_source_modified_ts,
      last_lookback_days,
      notes
    )
    VALUES
      (
        'sp_hourly_ga4_sync',
        v_source_project_id,
        v_source_dataset_id,
        'fct_ga4_sessions',
        v_execution_id,
        v_lock_owner,
        ARRAY_REVERSE(v_target_partition_dates)[SAFE_OFFSET(0)],
        v_rows_sessions,
        'SUCCESS',
        CURRENT_TIMESTAMP(),
        v_batch_upper_ts,
        GREATEST(v_prev_max_lookback, v_effective_lookback),
        FORMAT('Reconciled %d modified shards across %d target partitions (scanned %d shards with {-1,0,+1} closure)', ARRAY_LENGTH(v_modified_suffixes), ARRAY_LENGTH(v_target_partition_dates), ARRAY_LENGTH(v_scan_suffixes))
      ),
      (
        'sp_hourly_ga4_sync',
        v_source_project_id,
        v_source_dataset_id,
        'fct_ga4_transactions',
        v_execution_id,
        v_lock_owner,
        ARRAY_REVERSE(v_target_partition_dates)[SAFE_OFFSET(0)],
        v_rows_transactions,
        'SUCCESS',
        CURRENT_TIMESTAMP(),
        v_batch_upper_ts,
        GREATEST(v_prev_max_lookback, v_effective_lookback),
        'Synchronized deduplicated transaction mart in lockstep with session mart'
      ),
      (
        'sp_hourly_ga4_sync',
        v_source_project_id,
        v_source_dataset_id,
        'fct_ga4_transaction_products',
        v_execution_id,
        v_lock_owner,
        ARRAY_REVERSE(v_target_partition_dates)[SAFE_OFFSET(0)],
        v_rows_products,
        'SUCCESS',
        CURRENT_TIMESTAMP(),
        v_batch_upper_ts,
        GREATEST(v_prev_max_lookback, v_effective_lookback),
        'Synchronized deduplicated transaction_products mart in lockstep with session mart'
      ),
      (
        'sp_hourly_ga4_sync',
        v_source_project_id,
        v_source_dataset_id,
        'fct_ga4_cart_events',
        v_execution_id,
        v_lock_owner,
        ARRAY_REVERSE(v_target_partition_dates)[SAFE_OFFSET(0)],
        v_rows_cart_events,
        'SUCCESS',
        CURRENT_TIMESTAMP(),
        v_batch_upper_ts,
        GREATEST(v_prev_max_lookback, v_effective_lookback),
        'Synchronized cart_events mart in lockstep with session mart'
      );

    COMMIT TRANSACTION;
    SET v_in_transaction = FALSE;

  EXCEPTION WHEN ERROR THEN
    IF v_in_transaction THEN
      ROLLBACK TRANSACTION;
    END IF;

    -- Always release the single-writer lock on any failure (pre-transaction or in-transaction)
    UPDATE `ga4_marts.etl_pipeline_locks`
    SET
      lock_status = 'FAILED_RELEASED',
      released_at = CURRENT_TIMESTAMP(),
      failure_reason = @@error.message
    WHERE target_scope_key = v_target_scope_key
      AND execution_id = v_execution_id;

    INSERT INTO `ga4_marts.etl_watermark` (
      pipeline_name,
      source_project_id,
      source_dataset_id,
      table_name,
      execution_id,
      lock_owner,
      last_processed_date_est,
      rows_processed,
      execution_status,
      execution_timestamp,
      max_source_modified_ts,
      last_lookback_days,
      notes
    ) VALUES (
      'sp_hourly_ga4_sync',
      v_source_project_id,
      v_source_dataset_id,
      'fct_ga4_sessions',
      v_execution_id,
      v_lock_owner,
      CURRENT_DATE('America/New_York'),
      0,
      'FAILED',
      CURRENT_TIMESTAMP(),
      v_last_watermark_ts,
      v_effective_lookback,
      CONCAT('Released lock and aborted run on error: ', @@error.message)
    );
    RAISE;
  END;

END;
