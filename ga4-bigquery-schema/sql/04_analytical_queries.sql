-- ==============================================================================
-- Project: Database Marketer (dbmarketer.com)
-- Component: GA4 BigQuery Production Schema & Marts
-- File: 04_analytical_queries.sql
-- Description: Practical production queries demonstrating the power of 0/1 integer
--              goal flags, centralized marketing channel mapping, lowercased UTMs,
--              retroactive rule updates, and Eastern Time date partitioning.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- Query 1: The Magic of 0/1 Integer Flags (Instant Funnel & Conversion Rates)
-- Benefit: No complex `COUNT(DISTINCT CASE WHEN ...)`!
--          SUM(has_goal) = Total goal completions
--          AVG(has_goal) = Session Conversion Rate (decimal 0.0 to 1.0)
-- ------------------------------------------------------------------------------
SELECT
  session_date_est,
  COUNT(1) AS total_sessions,
  
  -- Volume summaries via simple SUM()
  SUM(has_view_item) AS product_view_sessions,
  SUM(has_add_to_cart) AS cart_add_sessions,
  SUM(has_checkout) AS checkout_sessions,
  SUM(has_purchase) AS purchase_sessions,
  SUM(has_newsletter_signup) AS newsletter_signup_sessions,

  -- Conversion Rates via simple AVG() * 100
  ROUND(AVG(has_view_item) * 100, 2) AS view_item_rate_pct,
  ROUND(AVG(has_add_to_cart) * 100, 2) AS add_to_cart_rate_pct,
  ROUND(AVG(has_checkout) * 100, 2) AS checkout_rate_pct,
  ROUND(AVG(has_purchase) * 100, 2) AS ecommerce_cvr_pct,
  ROUND(AVG(has_newsletter_signup) * 100, 2) AS newsletter_cvr_pct,

  -- Revenue totals
  ROUND(SUM(total_purchase_revenue), 2) AS gross_revenue,
  ROUND(SAFE_DIVIDE(SUM(total_purchase_revenue), SUM(has_purchase)), 2) AS average_order_value
FROM `ga4_marts.fct_ga4_sessions`
WHERE session_date_est BETWEEN DATE_SUB(CURRENT_DATE('America/New_York'), INTERVAL 30 DAY) AND CURRENT_DATE('America/New_York')
GROUP BY session_date_est
ORDER BY session_date_est DESC;

-- ------------------------------------------------------------------------------
-- Query 2: Centralized Marketing Channel Performance & Full-Funnel Efficiency
-- Benefit: Centralized logic via UDF fn_map_marketing_channel separates
--          Strategic Partnerships, Influencers, Paid Social, Search, and Email.
-- ------------------------------------------------------------------------------
SELECT
  marketing_channel,
  COUNT(1) AS total_sessions,
  SUM(has_view_item) AS product_views,
  SUM(has_add_to_cart) AS cart_adds,
  SUM(has_purchase) AS purchases,
  ROUND(AVG(has_add_to_cart) * 100, 2) AS cart_add_rate_pct,
  ROUND(AVG(has_purchase) * 100, 2) AS cvr_pct,
  ROUND(SUM(total_purchase_revenue), 2) AS total_revenue,
  ROUND(SAFE_DIVIDE(SUM(total_purchase_revenue), COUNT(1)), 2) AS revenue_per_session
FROM `ga4_marts.fct_ga4_sessions`
-- Take advantage of date partitioning: Scans only the target date blocks
WHERE session_date_est >= DATE_SUB(CURRENT_DATE('America/New_York'), INTERVAL 30 DAY)
GROUP BY 1
ORDER BY total_revenue DESC;

-- ------------------------------------------------------------------------------
-- Query 3: Strategic Partnership & Landing-Page-Only Channel Audit
-- Evaluates partners identified by landing page alone (/partners/...) or specific referrers
-- ------------------------------------------------------------------------------
SELECT
  landing_page_path,
  COALESCE(page_referrer, '(no referrer)') AS page_referrer,
  marketing_channel,
  COUNT(1) AS sessions,
  SUM(has_purchase) AS transactions,
  ROUND(AVG(has_purchase) * 100, 2) AS partner_cvr_pct,
  ROUND(SUM(total_purchase_revenue), 2) AS partner_revenue
FROM `ga4_marts.fct_ga4_sessions`
WHERE marketing_channel = 'Strategic Partnerships'
  AND session_date_est >= DATE_SUB(CURRENT_DATE('America/New_York'), INTERVAL 30 DAY)
GROUP BY 1, 2, 3
ORDER BY sessions DESC;

-- ------------------------------------------------------------------------------
-- Query 4: Retroactive Channel Rule Update (How to Update Sessions on Rule Change)
--
-- IMPORTANT ARCHITECTURAL TRADE-OFF:
-- Because marketing_channel is materialized as a physical column in fct_ga4_sessions,
-- updates to ga4_utils.fn_map_marketing_channel will NOT automatically alter past rows.
-- Run this targeted partition update to refresh historical rows without full rebuild:
-- ------------------------------------------------------------------------------
/*
UPDATE `ga4_marts.fct_ga4_sessions`
SET marketing_channel = `ga4_utils.fn_map_marketing_channel`(
  utm_source,
  utm_medium,
  utm_campaign,
  page_referrer,
  landing_page_path
)
WHERE session_date_est BETWEEN '2026-09-01' AND '2026-10-27';
*/

-- ------------------------------------------------------------------------------
-- Query 5: On-the-Fly UDF Channel Mapping vs. Pre-Materialized Column (Compute Cost Comparison)
--
-- Dynamic Approach: Calls the UDF on every single row during query execution.
-- - PROS: Zero maintenance; rules update in real-time.
-- - CONS: Higher compute costs (slot-seconds), regex recalculation across millions of rows,
--         and prevents BigQuery cluster pruning on the channel dimension.
-- ------------------------------------------------------------------------------
SELECT
  -- Dynamic Query-Time Evaluation:
  `ga4_utils.fn_map_marketing_channel`(
    utm_source,
    utm_medium,
    utm_campaign,
    page_referrer,
    landing_page_path
  ) AS dynamic_marketing_channel,
  
  -- Pre-Materialized Column (Zero Regex Execution Cost):
  marketing_channel AS materialized_marketing_channel,
  
  COUNT(1) AS sessions,
  SUM(has_purchase) AS purchases
FROM `ga4_marts.fct_ga4_sessions`
WHERE session_date_est = DATE_SUB(CURRENT_DATE('America/New_York'), INTERVAL 1 DAY)
GROUP BY 1, 2;

-- ------------------------------------------------------------------------------
-- Query 6: Consent Mode v2 Traffic & Conversion Impact Analysis
-- Evaluates the volume and performance of consented vs unconsented traffic
-- ------------------------------------------------------------------------------
SELECT
  consent_status,
  is_consented,
  COUNT(1) AS total_sessions,
  ROUND(COUNT(1) * 100.0 / SUM(COUNT(1)) OVER(), 2) AS pct_of_total_traffic,
  SUM(has_purchase) AS purchases,
  ROUND(AVG(has_purchase) * 100, 2) AS conversion_rate_pct,
  ROUND(SUM(total_purchase_revenue), 2) AS revenue
FROM `ga4_marts.fct_ga4_sessions`
WHERE session_date_est >= DATE_SUB(CURRENT_DATE('America/New_York'), INTERVAL 30 DAY)
GROUP BY 1, 2
ORDER BY total_sessions DESC;
