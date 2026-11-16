import { DatabaseSync } from 'node:sqlite';
import { buildBronzeLayer, buildSilverLayer } from './medallionTransforms.js';

/**
 * Executes the Silver -> Gold relational window transformation inside an in-memory
 * SQLite database (Node >= 22.5) to validate SQL window semantics (PARTITION BY tenant_id,
 * RANGE BETWEEN 86400 PRECEDING AND 1 PRECEDING) against the JS Medallion implementation.
 */
export function runSqliteMedallionPipeline(canonicalEvents = []) {
  const bronze = buildBronzeLayer(canonicalEvents);
  const silver = buildSilverLayer(bronze);

  const db = new DatabaseSync(':memory:');

  db.exec(`
    CREATE TABLE bronze_stg_nutrition_events (
      document_id TEXT PRIMARY KEY,
      tenant_id TEXT NOT NULL,
      event_timestamp TEXT NOT NULL,
      ingested_at TEXT NOT NULL,
      category TEXT NOT NULL,
      raw_payload_json TEXT NOT NULL
    );

    CREATE TABLE silver_int_events_flattened (
      event_id TEXT PRIMARY KEY,
      tenant_id TEXT NOT NULL,
      event_timestamp TEXT NOT NULL,
      event_epoch_sec INTEGER NOT NULL,
      event_date_utc TEXT NOT NULL,
      category TEXT NOT NULL,
      discomfort_score INTEGER,
      is_elevated_discomfort INTEGER,
      has_high_fodmap_polyol INTEGER NOT NULL,
      has_fermentable_oligo INTEGER NOT NULL,
      has_hydrocolloid_gum INTEGER NOT NULL,
      has_emulsifier_irritant INTEGER NOT NULL,
      has_seed_oil INTEGER NOT NULL,
      has_unverified_gluten_risk INTEGER NOT NULL,
      is_raw_plant_prep INTEGER NOT NULL,
      took_digestive_supplement INTEGER NOT NULL,
      sleep_quality_score INTEGER,
      stress_score INTEGER
    );
  `);

  const insertBronze = db.prepare(`
    INSERT INTO bronze_stg_nutrition_events (
      document_id, tenant_id, event_timestamp, ingested_at, category, raw_payload_json
    ) VALUES (?, ?, ?, ?, ?, ?)
  `);

  for (const b of bronze) {
    insertBronze.run(
      b.document_id,
      b.tenant_id,
      b.event_timestamp,
      b.ingested_at,
      b.category,
      b.raw_payload_json
    );
  }

  const insertSilver = db.prepare(`
    INSERT INTO silver_int_events_flattened VALUES (
      ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
    )
  `);

  for (const s of silver) {
    insertSilver.run(
      s.event_id,
      s.tenant_id,
      s.event_timestamp,
      s.event_epoch_sec,
      s.event_date_utc,
      s.category,
      s.discomfort_score,
      s.is_elevated_discomfort,
      s.has_high_fodmap_polyol,
      s.has_fermentable_oligo,
      s.has_hydrocolloid_gum,
      s.has_emulsifier_irritant,
      s.has_seed_oil,
      s.has_unverified_gluten_risk,
      s.is_raw_plant_prep,
      s.took_digestive_supplement,
      s.sleep_quality_score,
      s.stress_score
    );
  }

  db.exec(`
    CREATE TABLE gold_fct_ml_feature_store AS
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
      CASE
        WHEN COALESCE(MAX(CASE WHEN sleep_quality_score IS NOT NULL AND sleep_quality_score <= 4 THEN 1 ELSE 0 END) OVER w24, 0) > 0
        THEN 1 ELSE 0
      END AS prior_poor_sleep_24h,
      CASE
        WHEN COALESCE(MAX(CASE WHEN stress_score IS NOT NULL AND stress_score >= 7 THEN 1 ELSE 0 END) OVER w24, 0) > 0
        THEN 1 ELSE 0
      END AS prior_elevated_stress_24h
    FROM silver_int_events_flattened
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
    ORDER BY tenant_id ASC, event_epoch_sec ASC, event_id ASC;
  `);

  const gold = db.prepare('SELECT * FROM gold_fct_ml_feature_store').all().map((row) => ({ ...row }));
  db.close();

  return { bronze, silver, gold };
}
