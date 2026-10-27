-- ==============================================================================
-- Project: Database Marketer (dbmarketer.com)
-- Component: GA4 BigQuery Production Schema & Marts
-- File: 01_create_all_routines.sql
-- Description: Complete, consolidated DDL script for all BigQuery Routines:
--              - 9 Scalar User-Defined Functions (ga4_utils.fn_*)
--              - 1 Table-Valued Function (ga4_utils.tvf_get_ga4_events_range)
--              - 1 Stored Procedure (ga4_marts.sp_hourly_ga4_sync)
--              Run this single script in BigQuery Studio to create all routines.
-- ==============================================================================

-- ==============================================================================
-- Project: Database Marketer (dbmarketer.com)
-- Component: GA4 BigQuery Production Schema & Marts
-- File: 01_udfs.sql
-- Description: Parameterized User-Defined Functions (Scalar & Table-Valued)
--              for parsing raw GA4 event streams, normalizing UTMs, converting
--              timestamps to EST, stripping trailing slashes, and centralizing
--              multi-tier marketing channel mapping.
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
-- 7. SCALAR UDF: Centralized Marketing Channel Mapping
--    Evaluates clean UTMs, HTTP referrer, and normalized landing page path.
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

    -- Rule 3: Paid Search
    WHEN medium IN ('cpc', 'ppc', 'paidsearch', 'paid_search')
      OR (source IN ('google', 'bing', 'yahoo', 'duckduckgo', 'baidu') AND medium IN ('cpc', 'ppc'))
      THEN 'Paid Search'

    -- Rule 4: Paid Social
    WHEN medium IN ('paidsocial', 'paid_social', 'social_cpc', 'social_paid', 'social-cpc', 'paid-social')
      OR (source IN ('facebook', 'instagram', 'meta', 'tiktok', 'linkedin', 'pinterest', 'twitter', 'x', 'snapchat')
          AND (medium IN ('cpc', 'cpm', 'paid', 'ad', 'social_ad', 'paidad') OR campaign LIKE '%paid%'))
      THEN 'Paid Social'

    -- Rule 5: Organic Social
    WHEN medium IN ('social', 'social_network', 'social_media', 'sm', 'org_social', 'organic_social')
      OR source IN ('facebook', 'instagram', 'tiktok', 'linkedin', 'pinterest', 'twitter', 'x', 't.co', 'reddit', 'threads')
      OR LOWER(referrer) LIKE '%instagram.com%'
      OR LOWER(referrer) LIKE '%facebook.com%'
      OR LOWER(referrer) LIKE '%linkedin.com%'
      OR LOWER(referrer) LIKE '%tiktok.com%'
      OR LOWER(referrer) LIKE '%reddit.com%'
      THEN 'Organic Social'

    -- Rule 6: Email Marketing
    WHEN medium IN ('email', 'e-mail', 'newsletter', 'edm', 'flow', 'campaign_email')
      OR source IN ('klaviyo', 'mailchimp', 'braze', 'activecampaign', 'hubspot', 'sailthru', 'customerio')
      THEN 'Email'

    -- Rule 7: Affiliates
    WHEN medium IN ('affiliate', 'affiliates', 'aff')
      OR source IN ('rakuten', 'impact', 'shareasale', 'awin', 'cj', 'pepperjam')
      OR landing_page_path LIKE '/affiliate%'
      THEN 'Affiliates'

    -- Rule 8: Paid Video
    WHEN medium IN ('video', 'cpm_video')
      OR (source IN ('youtube', 'vimeo', 'hulu') AND medium IN ('cpc', 'cpm', 'paid'))
      THEN 'Paid Video'

    -- Rule 9: Organic Search
    WHEN medium = 'organic'
      OR source IN ('google', 'bing', 'yahoo', 'duckduckgo', 'ecosia', 'baidu')
      OR LOWER(referrer) LIKE '%google.%'
      OR LOWER(referrer) LIKE '%bing.%'
      OR LOWER(referrer) LIKE '%duckduckgo.%'
      THEN 'Organic Search'

    -- Rule 10: Referral (Generic non-partner web links)
    WHEN medium IN ('referral', 'referrals', 'link')
      OR (referrer IS NOT NULL AND referrer NOT IN ('', '(not set)') AND NOT (LOWER(referrer) LIKE '%google.%' OR LOWER(referrer) LIKE '%bing.%'))
      THEN 'Referral'

    -- Rule 11: Direct
    WHEN (source IS NULL OR source IN ('(direct)', 'direct'))
      AND (medium IS NULL OR medium IN ('(none)', '(not set)', 'none'))
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
-- 10. SET 1: PARAMETERIZED TABLE-VALUED FUNCTION (TVF)
--     Query any arbitrary date range on the fly without running full ETL.
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

    -- Identification & Consent Mode v2 Handling
    e.user_pseudo_id,
    `ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id') AS session_id,
    `ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_number') AS session_number,
    
    -- Synthetic Session Key: Preserves unconsented traffic
    COALESCE(
      CONCAT(e.user_pseudo_id, '.', CAST(`ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id') AS STRING)),
      CONCAT('anon.', e.event_date, '.', CAST(FARM_FINGERPRINT(CONCAT(COALESCE(e.user_pseudo_id, 'unconsented'), CAST(e.event_timestamp AS STRING), COALESCE(e.geo.country, ''))) AS STRING))
    ) AS session_key,

    -- Consent Mode indicators
    e.privacy_info.analytics_storage AS consent_analytics_storage,
    CASE 
      WHEN e.privacy_info.analytics_storage = 'YES' THEN 1 
      WHEN e.privacy_info.analytics_storage = 'NO' THEN 0 
      ELSE NULL 
    END AS is_consented,

    -- Page & Screen context
    `ga4_utils.fn_extract_param_string`(e.event_params, 'page_location') AS page_location,
    `ga4_utils.fn_normalize_url_path`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location')) AS landing_page_path,
    `ga4_utils.fn_extract_param_string`(e.event_params, 'page_title') AS page_title,
    `ga4_utils.fn_extract_param_string`(e.event_params, 'page_referrer') AS page_referrer,

    -- Lowercased UTM Attribution Hierarchy
    `ga4_utils.fn_clean_utm`(COALESCE(
      e.collected_traffic_source.manual_source,
      `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_source'),
      e.traffic_source.source
    )) AS utm_source,

    `ga4_utils.fn_clean_utm`(COALESCE(
      e.collected_traffic_source.manual_medium,
      `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_medium'),
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

    -- Ecommerce fields
    e.ecommerce.transaction_id,
    e.ecommerce.purchase_revenue,
    e.ecommerce.total_item_quantity,
    e.items

  FROM `your_project.analytics_123456789.events_*` AS e
  WHERE _TABLE_SUFFIX BETWEEN start_table_suffix AND end_table_suffix
);


-- ==============================================================================
-- STORED PROCEDURE ROUTINE
-- ==============================================================================

CREATE OR REPLACE PROCEDURE `ga4_marts.sp_hourly_ga4_sync`(
  source_dataset_override STRING
)
BEGIN
  -- ----------------------------------------------------------------------------
  -- Configuration & Variables
  -- ----------------------------------------------------------------------------
  DECLARE v_source_dataset STRING;
  DECLARE v_last_session_date DATE;
  DECLARE v_next_process_date DATE;
  DECLARE v_next_suffix STRING;
  DECLARE v_max_available_suffix STRING;
  DECLARE v_rows_processed INT64 DEFAULT 0;

  -- Set target raw dataset: use override parameter if provided, else default to production export
  SET v_source_dataset = COALESCE(source_dataset_override, 'your_project.analytics_123456789');

  -- ----------------------------------------------------------------------------
  -- Step 1: Determine Next Target Processing Date (Last Processed Date + 1 Day)
  -- ----------------------------------------------------------------------------
  SET v_last_session_date = (
    SELECT MAX(session_date_est)
    FROM `ga4_marts.fct_ga4_sessions`
  );

  -- Initial Bootstrap Guard: If fct_ga4_sessions is completely empty, start from 30 days ago
  IF v_last_session_date IS NULL THEN
    SET v_last_session_date = DATE_SUB(CURRENT_DATE('America/New_York'), INTERVAL 30 DAY);
  END IF;

  -- The next required date to process:
  SET v_next_process_date = DATE_ADD(v_last_session_date, INTERVAL 1 DAY);
  SET v_next_suffix = FORMAT_DATE('%Y%m%d', v_next_process_date);

  -- ----------------------------------------------------------------------------
  -- Step 2: Check If Any New Closed Daily Table Is Delivered by Google
  --         Checks metadata for _TABLE_SUFFIX >= v_next_suffix, strictly
  --         excluding 'intraday' tables.
  --         Cost: 0 bytes scanned (metadata only).
  -- ----------------------------------------------------------------------------
  EXECUTE IMMEDIATE FORMAT("""
    SELECT COALESCE(MAX(_TABLE_SUFFIX), '')
    FROM `%s.events_*`
    WHERE _TABLE_SUFFIX >= '%s'
      AND NOT REGEXP_CONTAINS(_TABLE_SUFFIX, r'intraday')
  """, v_source_dataset, v_next_suffix) INTO v_max_available_suffix;

  -- ----------------------------------------------------------------------------
  -- Step 3: Natural Exit Guard (No Guessing Game)
  --         If yesterday's data is already in the warehouse and Google has not yet
  --         delivered today's closed table (which lands tomorrow), exit immediately.
  -- ----------------------------------------------------------------------------
  IF v_max_available_suffix = '' OR v_max_available_suffix IS NULL THEN
    INSERT INTO `ga4_marts.etl_watermark` (
      table_name,
      last_processed_date_est,
      rows_processed,
      execution_status,
      execution_timestamp,
      notes
    ) VALUES (
      'fct_ga4_sessions',
      v_last_session_date,
      0,
      'SKIPPED_UP_TO_DATE',
      CURRENT_TIMESTAMP(),
      FORMAT('Warehouse is up to date through %s. Next required suffix (%s) not yet delivered by Google. Exiting naturally.',
        CAST(v_last_session_date AS STRING),
        v_next_suffix)
    );
    RETURN;
  END IF;

  -- ----------------------------------------------------------------------------
  -- Step 4: Single Set-Based Extraction (No Loop)
  --         Extracts all pending dates in one shot where _TABLE_SUFFIX >= v_next_suffix.
  --         Clean snake_case column names enforced throughout.
  -- ----------------------------------------------------------------------------
  EXECUTE IMMEDIATE FORMAT("""
    CREATE OR REPLACE TEMP TABLE temp_stage_events AS
    SELECT
      e.event_timestamp,
      `ga4_utils.fn_utc_to_est_datetime`(e.event_timestamp) AS event_datetime_est,
      `ga4_utils.fn_utc_to_est_date`(e.event_timestamp) AS event_date_est,
      e.event_name,
      e.user_pseudo_id,
      `ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id') AS session_id,
      `ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_number') AS session_number,

      -- Synthetic session key: Guarantees unconsented users are not dropped
      COALESCE(
        IF(e.user_pseudo_id IS NOT NULL AND `ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id') IS NOT NULL,
           CONCAT(e.user_pseudo_id, '.', CAST(`ga4_utils.fn_extract_param_int`(e.event_params, 'ga_session_id') AS STRING)),
           NULL),
        CONCAT('anon.', e.event_date, '.', CAST(FARM_FINGERPRINT(CONCAT(COALESCE(e.user_pseudo_id, 'unconsented'), CAST(e.event_timestamp AS STRING), COALESCE(e.geo.country, ''))) AS STRING))
      ) AS session_key,

      -- Consent Mode status
      COALESCE(e.privacy_info.analytics_storage, 'UNKNOWN') AS consent_analytics_storage,
      CASE WHEN e.privacy_info.analytics_storage = 'YES' THEN 1 ELSE 0 END AS is_consented,

      -- Navigation Context & Normalized Path (Trailing Slash Stripped)
      `ga4_utils.fn_extract_param_string`(e.event_params, 'page_location') AS page_location,
      `ga4_utils.fn_normalize_url_path`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location')) AS landing_page_path,
      `ga4_utils.fn_extract_param_string`(e.event_params, 'page_title') AS page_title,
      `ga4_utils.fn_extract_param_string`(e.event_params, 'page_referrer') AS page_referrer,

      -- Normalized Lowercased UTM Attribution
      `ga4_utils.fn_clean_utm`(COALESCE(
        e.collected_traffic_source.manual_source,
        `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_source'),
        e.traffic_source.source
      )) AS utm_source,

      `ga4_utils.fn_clean_utm`(COALESCE(
        e.collected_traffic_source.manual_medium,
        `ga4_utils.fn_extract_query_param`(`ga4_utils.fn_extract_param_string`(e.event_params, 'page_location'), 'utm_medium'),
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

      -- Ecommerce metrics
      e.ecommerce.transaction_id,
      COALESCE(e.ecommerce.purchase_revenue, 0) AS purchase_revenue,
      COALESCE(e.ecommerce.total_item_quantity, 0) AS total_item_quantity,
      e.items

    FROM `%s.events_*` AS e
    WHERE _TABLE_SUFFIX >= '%s'
      AND NOT REGEXP_CONTAINS(_TABLE_SUFFIX, r'intraday')
  """, v_source_dataset, v_next_suffix);

  -- ----------------------------------------------------------------------------
  -- Step 5: Idempotent Partition Reset (Safety Cleanup)
  -- ----------------------------------------------------------------------------
  DELETE FROM `ga4_marts.fct_ga4_sessions` 
  WHERE session_date_est >= v_next_process_date;

  DELETE FROM `ga4_marts.fct_ga4_transactions` 
  WHERE transaction_date_est >= v_next_process_date;

  DELETE FROM `ga4_marts.fct_ga4_transaction_products` 
  WHERE transaction_date_est >= v_next_process_date;

  DELETE FROM `ga4_marts.fct_ga4_cart_events` 
  WHERE event_date_est >= v_next_process_date;

  -- ----------------------------------------------------------------------------
  -- Step 6: Materialize Sessions Mart (fct_ga4_sessions)
  -- ----------------------------------------------------------------------------
  INSERT INTO `ga4_marts.fct_ga4_sessions` (
    session_key,
    session_date_est,
    session_start_est,
    session_end_est,
    session_duration_seconds,
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
  WITH aggregated_sessions AS (
    SELECT
      session_key,
      MIN(event_date_est) AS session_date_est,
      MIN(event_datetime_est) AS session_start_est,
      MAX(event_datetime_est) AS session_end_est,
      DATETIME_DIFF(MAX(event_datetime_est), MIN(event_datetime_est), SECOND) AS session_duration_seconds,

      ANY_VALUE(user_pseudo_id) AS user_pseudo_id,
      ANY_VALUE(session_id) AS session_id,
      ANY_VALUE(session_number) AS session_number,
      ANY_VALUE(consent_analytics_storage) AS consent_status,
      MAX(is_consented) AS is_consented,

      ARRAY_AGG(page_location ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)] AS landing_page,
      ARRAY_AGG(landing_page_path ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)] AS landing_page_path,
      ARRAY_AGG(page_title ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)] AS landing_page_title,
      ARRAY_AGG(page_location ORDER BY event_timestamp DESC LIMIT 1)[OFFSET(0)] AS exit_page,
      ARRAY_AGG(page_referrer ORDER BY event_timestamp ASC LIMIT 1)[OFFSET(0)] AS page_referrer,
      COUNTIF(event_name = 'page_view') AS page_views,
      COUNT(1) AS event_count,

      ARRAY_AGG(utm_source IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS utm_source,
      ARRAY_AGG(utm_medium IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS utm_medium,
      ARRAY_AGG(utm_campaign IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS utm_campaign,
      ARRAY_AGG(utm_term IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS utm_term,
      ARRAY_AGG(utm_content IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS utm_content,
      ARRAY_AGG(utm_id IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS utm_id,
      ARRAY_AGG(utm_source_platform IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS utm_source_platform,
      ARRAY_AGG(utm_creative_format IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS utm_creative_format,
      ARRAY_AGG(utm_marketing_tactic IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS utm_marketing_tactic,

      ARRAY_AGG(device_category IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS device_category,
      ARRAY_AGG(device_os IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS device_os,
      ARRAY_AGG(device_browser IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS device_browser,
      ARRAY_AGG(geo_country IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS geo_country,
      ARRAY_AGG(geo_region IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS geo_region,
      ARRAY_AGG(geo_city IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1)[SAFE_OFFSET(0)] AS geo_city,

      -- Binary 0/1 Integer Goal Flags
      MAX(IF(event_name = 'view_item', 1, 0)) AS has_view_item,
      MAX(IF(event_name = 'add_to_cart', 1, 0)) AS has_add_to_cart,
      MAX(IF(event_name IN ('begin_checkout', 'checkout'), 1, 0)) AS has_checkout,
      MAX(IF(event_name = 'purchase', 1, 0)) AS has_purchase,
      MAX(IF(event_name IN ('newsletter_signup', 'email_signup', 'lead', 'sign_up'), 1, 0)) AS has_newsletter_signup,

      CAST(SUM(purchase_revenue) AS NUMERIC) AS total_purchase_revenue,
      SUM(total_item_quantity) AS total_items_purchased,
      COUNT(DISTINCT transaction_id) AS transactions_count,
      CURRENT_TIMESTAMP() AS processed_at
    FROM temp_stage_events
    GROUP BY session_key
  )
  SELECT
    session_key,
    session_date_est,
    session_start_est,
    session_end_est,
    session_duration_seconds,
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
    -- Centralized channel mapping via UDF
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
  FROM aggregated_sessions;

  SET v_rows_processed = (SELECT COUNT(1) FROM temp_stage_events);

  -- ----------------------------------------------------------------------------
  -- Step 7: Materialize Transactions Mart (fct_ga4_transactions)
  -- ----------------------------------------------------------------------------
  INSERT INTO `ga4_marts.fct_ga4_transactions` (
    transaction_id,
    session_key,
    user_pseudo_id,
    transaction_date_est,
    transaction_timestamp_est,
    purchase_revenue,
    tax_value,
    shipping_value,
    coupon,
    currency,
    items_count,
    marketing_channel,
    utm_source,
    utm_medium,
    utm_campaign,
    processed_at
  )
  SELECT
    transaction_id,
    session_key,
    user_pseudo_id,
    MIN(event_date_est) AS transaction_date_est,
    MIN(event_datetime_est) AS transaction_timestamp_est,
    CAST(MAX(purchase_revenue) AS NUMERIC) AS purchase_revenue,
    CAST(`ga4_utils.fn_extract_param_float`(ANY_VALUE(items[SAFE_OFFSET(0)].item_params), 'tax') AS NUMERIC) AS tax_value,
    CAST(`ga4_utils.fn_extract_param_float`(ANY_VALUE(items[SAFE_OFFSET(0)].item_params), 'shipping') AS NUMERIC) AS shipping_value,
    ANY_VALUE(items[SAFE_OFFSET(0)].coupon) AS coupon,
    ANY_VALUE(`ga4_utils.fn_extract_param_string`(ANY_VALUE(items[SAFE_OFFSET(0)].item_params), 'currency')) AS currency,
    SUM(ARRAY_LENGTH(items)) AS items_count,
    ANY_VALUE(`ga4_utils.fn_map_marketing_channel`(utm_source, utm_medium, utm_campaign, page_referrer, landing_page_path)) AS marketing_channel,
    ANY_VALUE(utm_source) AS utm_source,
    ANY_VALUE(utm_medium) AS utm_medium,
    ANY_VALUE(utm_campaign) AS utm_campaign,
    CURRENT_TIMESTAMP() AS processed_at
  FROM temp_stage_events
  WHERE event_name = 'purchase'
    AND transaction_id IS NOT NULL
    AND transaction_id != '(not set)'
  GROUP BY transaction_id, session_key, user_pseudo_id;

  -- ----------------------------------------------------------------------------
  -- Step 8: Materialize Transaction Products Mart (fct_ga4_transaction_products)
  -- ----------------------------------------------------------------------------
  INSERT INTO `ga4_marts.fct_ga4_transaction_products` (
    transaction_id,
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
    e.transaction_id,
    e.session_key,
    e.event_date_est AS transaction_date_est,
    COALESCE(item.item_id, item.item_name) AS item_id,
    item.item_name,
    item.item_brand,
    item.item_category,
    item.item_category2 AS item_category_2,
    item.item_category3 AS item_category_3,
    CAST(item.price AS NUMERIC) AS price,
    COALESCE(item.quantity, 1) AS quantity,
    CAST(COALESCE(item.item_revenue, item.price * COALESCE(item.quantity, 1)) AS NUMERIC) AS item_revenue,
    item.coupon,
    CURRENT_TIMESTAMP() AS processed_at
  FROM temp_stage_events AS e
  CROSS JOIN UNNEST(e.items) AS item
  WHERE e.event_name = 'purchase'
    AND e.transaction_id IS NOT NULL;

  -- ----------------------------------------------------------------------------
  -- Step 9: Materialize Cart Events Mart (fct_ga4_cart_events)
  -- ----------------------------------------------------------------------------
  INSERT INTO `ga4_marts.fct_ga4_cart_events` (
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
    CONCAT(e.session_key, '.', CAST(e.event_timestamp AS STRING), '.', COALESCE(item.item_id, 'no_item')) AS event_id,
    e.session_key,
    e.user_pseudo_id,
    e.event_name,
    e.event_date_est,
    e.event_datetime_est,
    item.item_id,
    item.item_name,
    item.item_brand,
    item.item_category,
    CAST(item.price AS NUMERIC) AS price,
    item.quantity,
    CAST(COALESCE(item.item_revenue, item.price * COALESCE(item.quantity, 1)) AS NUMERIC) AS item_revenue,
    `ga4_utils.fn_extract_param_string`(e.items[SAFE_OFFSET(0)].item_params, 'currency') AS currency,
    CURRENT_TIMESTAMP() AS processed_at
  FROM temp_stage_events AS e
  LEFT JOIN UNNEST(e.items) AS item
  WHERE e.event_name IN ('view_item', 'add_to_cart', 'remove_from_cart', 'view_cart', 'begin_checkout');

  -- ----------------------------------------------------------------------------
  -- Step 10: Commit Watermark Audit Record
  -- ----------------------------------------------------------------------------
  INSERT INTO `ga4_marts.etl_watermark` (
    table_name,
    last_processed_date_est,
    rows_processed,
    execution_status,
    execution_timestamp,
    notes
  ) VALUES (
    'fct_ga4_sessions',
    PARSE_DATE('%Y%m%d', v_max_available_suffix),
    v_rows_processed,
    'SUCCESS',
    CURRENT_TIMESTAMP(),
    FORMAT('Processed %d raw events from _TABLE_SUFFIX between %s and %s in a single set-based pass.',
      v_rows_processed,
      v_next_suffix,
      v_max_available_suffix)
  );

  -- Clean up temporary staging
  DROP TABLE temp_stage_events;

END;
