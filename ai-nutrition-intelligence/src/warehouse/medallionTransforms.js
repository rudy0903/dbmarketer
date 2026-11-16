import {
  CanonicalNutritionEventSchema,
  SilverFlattenedRowSchema,
  GoldFeatureRowSchema
} from '../contracts/eventSchema.js';

/**
 * Bronze Layer (stg_nutrition_events):
 * Preserves raw operational JSON document envelope alongside immutable metadata.
 */
export function buildBronzeLayer(events = []) {
  return events.map((rawEvt) => {
    const evt = CanonicalNutritionEventSchema.parse(rawEvt);
    return {
      document_id: evt.event_id,
      tenant_id: evt.tenant_id,
      event_timestamp: evt.event_timestamp,
      ingested_at: evt.ingested_at,
      category: evt.category,
      raw_payload_json: JSON.stringify(evt)
    };
  });
}

/**
 * Silver Layer (int_events_flattened):
 * Parses Bronze JSON payloads into typed analytical columns and binary 0/1 flags.
 */
export function buildSilverLayer(bronzeRows = []) {
  return bronzeRows.map((row) => {
    const payload = JSON.parse(row.raw_payload_json);
    const epochSec = Math.floor(Date.parse(payload.event_timestamp) / 1000);
    const dateUtc = payload.event_timestamp.slice(0, 10);

    const allTags = new Set();
    if (payload.food_metadata?.ingredients) {
      for (const ing of payload.food_metadata.ingredients) {
        for (const tag of ing.tags || []) {
          allTags.add(tag);
        }
      }
    }

    const discomfortScore =
      payload.category === 'symptom' && payload.symptom_metadata
        ? payload.symptom_metadata.discomfort_score
        : null;

    const isElevatedDiscomfort =
      discomfortScore !== null ? (discomfortScore >= 7 ? 1 : 0) : null;

    const isRawPrep =
      payload.category === 'food' && payload.food_metadata?.prep_state === 'raw' ? 1 : 0;

    const hasUnverifiedGluten =
      payload.category === 'food' &&
      (allTags.has('GLUTEN_RISK') || payload.food_metadata?.gluten_free_verified === false)
        ? 1
        : 0;

    const silverCandidate = {
      event_id: row.document_id,
      tenant_id: row.tenant_id,
      event_timestamp: row.event_timestamp,
      event_epoch_sec: epochSec,
      event_date_utc: dateUtc,
      category: payload.category,
      discomfort_score: discomfortScore,
      is_elevated_discomfort: isElevatedDiscomfort,
      has_high_fodmap_polyol: allTags.has('HIGH_FODMAP_POLYOL') ? 1 : 0,
      has_fermentable_oligo: allTags.has('FERMENTABLE_OLIGOSACCHARIDE') ? 1 : 0,
      has_hydrocolloid_gum: allTags.has('HYDROCOLLOID_GUM') ? 1 : 0,
      has_emulsifier_irritant: allTags.has('EMULSIFIER_IRRITANT') ? 1 : 0,
      has_seed_oil: allTags.has('SEED_OIL') ? 1 : 0,
      has_unverified_gluten_risk: hasUnverifiedGluten,
      is_raw_plant_prep: isRawPrep,
      took_digestive_supplement: payload.category === 'supplement' ? 1 : 0,
      sleep_quality_score: payload.context_metadata?.sleep_quality_score ?? null,
      stress_score: payload.context_metadata?.stress_score ?? null
    };

    return SilverFlattenedRowSchema.parse(silverCandidate);
  });
}

/**
 * Gold Layer (fct_ml_feature_store):
 * Computes tenant-partitioned, strictly-prior 24h and 48h lag exposure windows
 * [t - windowSec, t - 1] to prevent cross-tenant contamination and contemporaneous leakage.
 */
export function buildGoldFeatureStore(silverRows = []) {
  const byTenant = new Map();
  for (const row of silverRows) {
    if (!byTenant.has(row.tenant_id)) {
      byTenant.set(row.tenant_id, []);
    }
    byTenant.get(row.tenant_id).push(row);
  }

  const goldRows = [];

  for (const [, tenantRows] of byTenant.entries()) {
    const sorted = [...tenantRows].sort(
      (a, b) => a.event_epoch_sec - b.event_epoch_sec || a.event_id.localeCompare(b.event_id)
    );

    for (let i = 0; i < sorted.length; i++) {
      const current = sorted[i];
      const t = current.event_epoch_sec;

      let priorPolyol24h = 0;
      let priorOligo24h = 0;
      let priorGum24h = 0;
      let priorEmulsifier24h = 0;
      let priorSeedOil24h = 0;
      let priorGluten24h = 0;
      let priorRawPrep24h = 0;
      let priorSupplement24h = 0;
      let priorFodmap48h = 0;
      let priorPoorSleep24h = 0;
      let priorElevatedStress24h = 0;

      for (let j = 0; j < i; j++) {
        const prev = sorted[j];
        const delta = t - prev.event_epoch_sec;
        // Strict prior lag: must occur at least 1 second earlier
        if (delta < 1) continue;

        if (delta <= 172800) {
          priorFodmap48h += prev.has_high_fodmap_polyol + prev.has_fermentable_oligo;
        }
        if (delta <= 86400) {
          priorPolyol24h += prev.has_high_fodmap_polyol;
          priorOligo24h += prev.has_fermentable_oligo;
          priorGum24h += prev.has_hydrocolloid_gum;
          priorEmulsifier24h += prev.has_emulsifier_irritant;
          priorSeedOil24h += prev.has_seed_oil;
          priorGluten24h += prev.has_unverified_gluten_risk;
          priorRawPrep24h += prev.is_raw_plant_prep;
          priorSupplement24h += prev.took_digestive_supplement;
          if (prev.sleep_quality_score !== null && prev.sleep_quality_score <= 4) {
            priorPoorSleep24h = 1;
          }
          if (prev.stress_score !== null && prev.stress_score >= 7) {
            priorElevatedStress24h = 1;
          }
        }
      }

      const goldCandidate = {
        ...current,
        prior_polyol_24h: priorPolyol24h,
        prior_oligo_24h: priorOligo24h,
        prior_gum_24h: priorGum24h,
        prior_emulsifier_24h: priorEmulsifier24h,
        prior_seed_oil_24h: priorSeedOil24h,
        prior_unverified_gluten_24h: priorGluten24h,
        prior_raw_prep_24h: priorRawPrep24h,
        prior_supplement_24h: priorSupplement24h,
        prior_fodmap_48h: priorFodmap48h,
        prior_poor_sleep_24h: priorPoorSleep24h,
        prior_elevated_stress_24h: priorElevatedStress24h
      };

      goldRows.push(GoldFeatureRowSchema.parse(goldCandidate));
    }
  }

  return goldRows;
}

export function runMedallionPipeline(canonicalEvents = []) {
  const bronze = buildBronzeLayer(canonicalEvents);
  const silver = buildSilverLayer(bronze);
  const gold = buildGoldFeatureStore(silver);
  return { bronze, silver, gold };
}
