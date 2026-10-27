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
