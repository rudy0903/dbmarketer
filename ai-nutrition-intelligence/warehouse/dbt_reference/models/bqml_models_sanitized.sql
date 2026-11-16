-- Sanitized BigQuery ML Reference Definitions
-- Replace `your-gcp-project-id.nutrition_marts` with an isolated sandbox dataset.
-- Methodological Note: ML.GLOBAL_EXPLAIN attributions reflect observational predictive
-- associations within historical logs and must not be interpreted as causal effects.

-- ==============================================================================
-- MODEL 1: Boosted Tree Classifier with Chronological Data Split
-- ==============================================================================
CREATE OR REPLACE MODEL `your-gcp-project-id.nutrition_marts.discomfort_association_xgb`
OPTIONS(
  model_type = 'BOOSTED_TREE_CLASSIFIER',
  input_label_cols = ['is_elevated_discomfort'],
  data_split_method = 'SEQ',
  data_split_col = 'event_timestamp',
  data_split_eval_fraction = 0.25,
  max_tree_depth = 3,
  l2_reg = 1.5,
  enable_global_explain = TRUE
) AS
SELECT
  event_timestamp,
  is_elevated_discomfort,
  prior_polyol_24h,
  prior_gum_24h,
  prior_emulsifier_24h,
  prior_fodmap_48h,
  prior_unverified_gluten_24h,
  prior_raw_prep_24h,
  prior_supplement_24h,
  prior_poor_sleep_24h,
  prior_elevated_stress_24h
FROM
  `your-gcp-project-id.nutrition_marts.fct_ml_feature_store`
WHERE
  category = 'symptom'
  AND is_elevated_discomfort IS NOT NULL
  AND tenant_id = 'demo_persona_alex';

-- ==============================================================================
-- MODEL 2: ARIMA_PLUS Longitudinal Baseline & Anomaly Detection
-- ==============================================================================
CREATE OR REPLACE MODEL `your-gcp-project-id.nutrition_marts.daily_discomfort_arima`
OPTIONS(
  model_type = 'ARIMA_PLUS',
  time_series_timestamp_col = 'event_date_utc',
  time_series_data_col = 'daily_max_discomfort',
  time_series_id_col = 'tenant_id',
  auto_arima = TRUE
) AS
SELECT
  tenant_id,
  event_date_utc,
  MAX(discomfort_score) AS daily_max_discomfort
FROM
  `your-gcp-project-id.nutrition_marts.fct_ml_feature_store`
WHERE
  discomfort_score IS NOT NULL
GROUP BY
  tenant_id,
  event_date_utc;
