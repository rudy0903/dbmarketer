-- models/gold/fct_ml_feature_store.sql
-- Gold Layer: Tenant-partitioned, strictly-prior rolling 24h & 48h exposure windows.
-- Uses RANGE BETWEEN 86400 PRECEDING AND 1 PRECEDING to prevent contemporaneous leakage.

{{
  config(
    materialized = 'table',
    partition_by = {
      "field": "event_date_utc",
      "data_type": "date",
      "granularity": "day"
    },
    cluster_by = ["tenant_id", "category"]
  )
}}

WITH silver AS (
  SELECT * FROM {{ ref('int_events_flattened') }}
)

SELECT
  event_id,
  tenant_id,
  event_timestamp,
  event_epoch_sec,
  event_date_utc,
  category,
  discomfort_score,
  is_elevated_discomfort,
  has_high_fodmap_polyol,
  has_fermentable_oligo,
  has_hydrocolloid_gum,
  has_emulsifier_irritant,
  has_seed_oil,
  has_unverified_gluten_risk,
  is_raw_plant_prep,
  took_digestive_supplement,
  sleep_quality_score,
  stress_score,

  COALESCE(SUM(has_high_fodmap_polyol) OVER w24, 0) AS prior_polyol_24h,
  COALESCE(SUM(has_fermentable_oligo) OVER w24, 0) AS prior_oligo_24h,
  COALESCE(SUM(has_hydrocolloid_gum) OVER w24, 0) AS prior_gum_24h,
  COALESCE(SUM(has_emulsifier_irritant) OVER w24, 0) AS prior_emulsifier_24h,
  COALESCE(SUM(has_seed_oil) OVER w24, 0) AS prior_seed_oil_24h,
  COALESCE(SUM(has_unverified_gluten_risk) OVER w24, 0) AS prior_unverified_gluten_24h,
  COALESCE(SUM(is_raw_plant_prep) OVER w24, 0) AS prior_raw_prep_24h,
  COALESCE(SUM(took_digestive_supplement) OVER w24, 0) AS prior_supplement_24h,
  COALESCE(SUM(has_high_fodmap_polyol + has_fermentable_oligo) OVER w48, 0) AS prior_fodmap_48h,

  IF(COALESCE(MAX(IF(sleep_quality_score <= 4, 1, 0)) OVER w24, 0) > 0, 1, 0) AS prior_poor_sleep_24h,
  IF(COALESCE(MAX(IF(stress_score >= 7, 1, 0)) OVER w24, 0) > 0, 1, 0) AS prior_elevated_stress_24h

FROM silver
WINDOW
  w24 AS (
    PARTITION BY tenant_id
    ORDER BY event_epoch_sec ASC
    RANGE BETWEEN 86400 PRECEDING AND 1 PRECEDING
  ),
  w48 AS (
    PARTITION BY tenant_id
    ORDER BY event_epoch_sec ASC
    RANGE BETWEEN 172800 PRECEDING AND 1 PRECEDING
  )
