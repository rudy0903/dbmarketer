-- models/bronze/stg_nutrition_events.sql
-- Bronze Layer: Immutable JSON envelope extraction with explicit tenant_id and dual timestamps.

WITH raw_export AS (
  SELECT *
  FROM {{ source('operational_sync', 'nutrition_events_raw_latest') }}
  WHERE operation != 'DELETE'
)

SELECT
  document_id AS event_id,
  JSON_VALUE(data, '$.tenant_id') AS tenant_id,
  COALESCE(
    SAFE.TIMESTAMP(JSON_VALUE(data, '$.event_timestamp')),
    TIMESTAMP(timestamp)
  ) AS event_timestamp,
  SAFE.TIMESTAMP(JSON_VALUE(data, '$.ingested_at')) AS ingested_at,
  JSON_VALUE(data, '$.category') AS category,
  JSON_QUERY(data, '$.food_metadata') AS food_metadata_json,
  JSON_QUERY(data, '$.symptom_metadata') AS symptom_metadata_json,
  JSON_QUERY(data, '$.supplement_metadata') AS supplement_metadata_json,
  JSON_QUERY(data, '$.context_metadata') AS context_metadata_json
FROM raw_export
WHERE JSON_VALUE(data, '$.tenant_id') IS NOT NULL
