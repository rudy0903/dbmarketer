-- models/silver/int_events_flattened.sql
-- Silver Layer: Unnests nested ingredient taxonomy tags into 0/1 binary analytical flags.

WITH bronze AS (
  SELECT * FROM {{ ref('stg_nutrition_events') }}
),

ingredient_flags AS (
  SELECT
    b.event_id,
    MAX(IF(tag = 'HIGH_FODMAP_POLYOL', 1, 0)) AS has_high_fodmap_polyol,
    MAX(IF(tag = 'FERMENTABLE_OLIGOSACCHARIDE', 1, 0)) AS has_fermentable_oligo,
    MAX(IF(tag = 'HYDROCOLLOID_GUM', 1, 0)) AS has_hydrocolloid_gum,
    MAX(IF(tag = 'EMULSIFIER_IRRITANT', 1, 0)) AS has_emulsifier_irritant,
    MAX(IF(tag = 'SEED_OIL', 1, 0)) AS has_seed_oil,
    MAX(IF(tag = 'GLUTEN_RISK', 1, 0)) AS has_gluten_tag
  FROM bronze b
  LEFT JOIN UNNEST(JSON_QUERY_ARRAY(b.food_metadata_json, '$.ingredients')) AS ing_json
  LEFT JOIN UNNEST(JSON_VALUE_ARRAY(ing_json, '$.tags')) AS tag
  GROUP BY b.event_id
)

SELECT
  b.event_id,
  b.tenant_id,
  b.event_timestamp,
  UNIX_SECONDS(b.event_timestamp) AS event_epoch_sec,
  EXTRACT(DATE FROM b.event_timestamp) AS event_date_utc,
  b.category,
  SAFE_CAST(JSON_VALUE(b.symptom_metadata_json, '$.discomfort_score') AS INT64) AS discomfort_score,
  CASE
    WHEN b.category = 'symptom'
      AND SAFE_CAST(JSON_VALUE(b.symptom_metadata_json, '$.discomfort_score') AS INT64) IS NOT NULL
    THEN IF(SAFE_CAST(JSON_VALUE(b.symptom_metadata_json, '$.discomfort_score') AS INT64) >= 7, 1, 0)
    ELSE NULL
  END AS is_elevated_discomfort,
  COALESCE(f.has_high_fodmap_polyol, 0) AS has_high_fodmap_polyol,
  COALESCE(f.has_fermentable_oligo, 0) AS has_fermentable_oligo,
  COALESCE(f.has_hydrocolloid_gum, 0) AS has_hydrocolloid_gum,
  COALESCE(f.has_emulsifier_irritant, 0) AS has_emulsifier_irritant,
  COALESCE(f.has_seed_oil, 0) AS has_seed_oil,
  CASE
    WHEN b.category = 'food'
      AND (
        COALESCE(f.has_gluten_tag, 0) = 1
        OR JSON_VALUE(b.food_metadata_json, '$.gluten_free_verified') = 'false'
      )
    THEN 1
    ELSE 0
  END AS has_unverified_gluten_risk,
  IF(b.category = 'food' AND JSON_VALUE(b.food_metadata_json, '$.prep_state') = 'raw', 1, 0) AS is_raw_plant_prep,
  IF(b.category = 'supplement', 1, 0) AS took_digestive_supplement,
  SAFE_CAST(JSON_VALUE(b.context_metadata_json, '$.sleep_quality_score') AS INT64) AS sleep_quality_score,
  SAFE_CAST(JSON_VALUE(b.context_metadata_json, '$.stress_score') AS INT64) AS stress_score
FROM bronze b
LEFT JOIN ingredient_flags f USING (event_id)
