import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { CanonicalNutritionEventSchema } from '../src/contracts/eventSchema.js';
import { auditIngredientList } from '../src/taxonomy/dietaryRules.js';
import { runMedallionPipeline } from '../src/warehouse/medallionTransforms.js';
import { evaluateLongitudinalAnalytics } from '../src/analytics/illustrativeModeling.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(__dirname, '..');

function createSeededRng(seed = 20261114) {
  let state = seed >>> 0;
  return function nextFloat() {
    state += 0x6d2b79f5;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const SYNTHETIC_MEAL_TEMPLATES = [
  {
    label: 'Grilled Wild Salmon with Steamed Zucchini & Jasmine Rice',
    raw: 'Grilled wild salmon with steamed zucchini and jasmine rice',
    prep: 'cooked',
    gf: true,
    df: true,
    ingredients: ['Wild Sockeye Salmon', 'Zucchini', 'Jasmine Rice', 'Extra Virgin Olive Oil', 'Sea Salt'],
    macros: { calories: 520, protein_g: 38, carbs_g: 46, fat_g: 18 },
    riskWeight: 0.05
  },
  {
    label: 'Gluten-Free Brown Rice Pasta with Olive Oil & Basil',
    raw: 'Certified gluten-free brown rice pasta cooked with olive oil and basil',
    prep: 'cooked',
    gf: true,
    df: true,
    ingredients: ['Organic Brown Rice Flour', 'Water', 'Extra Virgin Olive Oil', 'Fresh Basil'],
    macros: { calories: 410, protein_g: 9, carbs_g: 64, fat_g: 14 },
    riskWeight: 0.08
  },
  {
    label: 'Low-Sugar Packaged Protein Bar (Maltitol + Xanthan Gum + Soy Lecithin)',
    raw: 'Had a low-sugar chocolate protein bar after afternoon meeting',
    prep: 'packaged',
    gf: true,
    df: false,
    ingredients: ['Pea Protein Isolate', 'Maltitol', 'Lactitol', 'Xanthan Gum', 'Carrageenan', 'Soy Lecithin', 'Natural Flavors'],
    macros: { calories: 210, protein_g: 20, carbs_g: 18, fat_g: 7 },
    riskWeight: 0.62
  },
  {
    label: 'Barista Oat Milk Latte (Guar Gum + Sunflower Oil)',
    raw: 'Iced barista oat milk latte at 9am',
    prep: 'beverage',
    gf: false,
    df: true,
    ingredients: ['Oat Base', 'Sunflower Oil', 'Guar Gum', 'Espresso'],
    macros: { calories: 160, protein_g: 3, carbs_g: 21, fat_g: 7 },
    riskWeight: 0.28
  },
  {
    label: 'Packaged Savory Broth Bowl (Dehydrated Vegetables + Guar Gum)',
    raw: 'Quick packaged vegetable rice soup bowl for lunch',
    prep: 'cooked',
    gf: true,
    df: true,
    ingredients: ['Vegetable Broth', 'White Rice', 'Dehydrated Vegetables', 'Guar Gum', 'Savory Spices'],
    macros: { calories: 250, protein_g: 5, carbs_g: 45, fat_g: 4 },
    riskWeight: 0.34
  },
  {
    label: 'Fresh Mixed Greens Salad with Lemon & Olive Oil',
    raw: 'Raw spinach and cucumber salad dressed with olive oil and lemon',
    prep: 'raw',
    gf: true,
    df: true,
    ingredients: ['Baby Spinach', 'Cucumber', 'Extra Virgin Olive Oil', 'Lemon Juice'],
    macros: { calories: 210, protein_g: 3, carbs_g: 8, fat_g: 18 },
    riskWeight: 0.14
  },
  {
    label: 'Restaurant Wheat Pasta with Garlic-Onion Marinara',
    raw: 'Dinner out: regular wheat pasta with garlic marinara sauce',
    prep: 'cooked',
    gf: false,
    df: true,
    ingredients: ['Durum Wheat Semolina', 'Crushed Tomatoes', 'Garlic', 'Onion', 'Canola Oil'],
    macros: { calories: 490, protein_g: 15, carbs_g: 80, fat_g: 11 },
    riskWeight: 0.55
  }
];

export function generateSyntheticDataset(seed = 20261114) {
  const rng = createSeededRng(seed);
  const events = [];
  let seq = 1;

  const personas = [
    { tenantId: 'demo_persona_alex', days: 60, baseSensitivity: 0.18, polyolWeight: 2.05, stressWeight: 0.85 },
    { tenantId: 'demo_persona_maya', days: 30, baseSensitivity: 0.14, polyolWeight: 1.45, stressWeight: 1.25 }
  ];

  const startEpochMs = Date.UTC(2026, 7, 15, 0, 0, 0); // 2026-08-15T00:00:00Z

  for (const persona of personas) {
    let prevDayRisk = 0;

    for (let day = 0; day < persona.days; day++) {
      const dayBaseMs = startEpochMs + day * 86400 * 1000;

      // 1. Morning sleep/stress context log (~07:15 UTC)
      const sleepScore = Math.max(2, Math.min(9, Math.round(7 - rng() * 4 + (rng() > 0.78 ? -2 : 1))));
      const stressScore = Math.max(2, Math.min(9, Math.round(3 + rng() * 4 + (rng() > 0.8 ? 2 : 0))));
      const ctxTs = new Date(dayBaseMs + (7 * 3600 + 15 * 60) * 1000).toISOString();

      events.push(
        CanonicalNutritionEventSchema.parse({
          event_id: `syn_${persona.tenantId.slice(-4)}_${String(seq++).padStart(4, '0')}`,
          tenant_id: persona.tenantId,
          event_timestamp: ctxTs,
          ingested_at: ctxTs,
          category: 'context',
          raw_text: `Morning check-in: sleep ${sleepScore}/10, work stress ${stressScore}/10`,
          clarification_turns: 0,
          system_alerts: [],
          context_metadata: {
            sleep_quality_score: sleepScore,
            stress_score: stressScore,
            notes: 'Synthetic daily baseline context'
          }
        })
      );

      // 2. Midday meal (~12:30 UTC)
      const lunchIdx = Math.floor(rng() * SYNTHETIC_MEAL_TEMPLATES.length);
      const lunch = SYNTHETIC_MEAL_TEMPLATES[lunchIdx];
      const lunchAudit = auditIngredientList(lunch.ingredients, { glutenFreeVerified: lunch.gf });
      const lunchTs = new Date(dayBaseMs + (12 * 3600 + 30 * 60) * 1000).toISOString();

      events.push(
        CanonicalNutritionEventSchema.parse({
          event_id: `syn_${persona.tenantId.slice(-4)}_${String(seq++).padStart(4, '0')}`,
          tenant_id: persona.tenantId,
          event_timestamp: lunchTs,
          ingested_at: lunchTs,
          category: 'food',
          raw_text: lunch.raw,
          clarification_turns: rng() > 0.65 ? 1 : 0,
          system_alerts: lunchAudit.system_alerts,
          food_metadata: {
            resolved_food_name: lunch.label,
            prep_state: lunch.prep,
            gluten_free_verified: lunch.gf,
            dairy_free_verified: lunch.df,
            ingredients: lunchAudit.ingredients,
            macros: lunch.macros
          }
        })
      );

      // 3. Optional afternoon supplement (~15:00 UTC)
      if (rng() > 0.45) {
        const suppTs = new Date(dayBaseMs + 15 * 3600 * 1000).toISOString();
        events.push(
          CanonicalNutritionEventSchema.parse({
            event_id: `syn_${persona.tenantId.slice(-4)}_${String(seq++).padStart(4, '0')}`,
            tenant_id: persona.tenantId,
            event_timestamp: suppTs,
            ingested_at: suppTs,
            category: 'supplement',
            raw_text: 'Took Magnesium Glycinate capsule',
            clarification_turns: 0,
            system_alerts: [],
            supplement_metadata: {
              supplement_name: 'Magnesium Glycinate',
              formulation: 'capsule',
              dosage_label: '200 mg'
            }
          })
        );
      }

      // 4. Evening meal (~18:45 UTC)
      const dinnerIdx = Math.floor(rng() * SYNTHETIC_MEAL_TEMPLATES.length);
      const dinner = SYNTHETIC_MEAL_TEMPLATES[dinnerIdx];
      const dinnerAudit = auditIngredientList(dinner.ingredients, { glutenFreeVerified: dinner.gf });
      const dinnerTs = new Date(dayBaseMs + (18 * 3600 + 45 * 60) * 1000).toISOString();

      events.push(
        CanonicalNutritionEventSchema.parse({
          event_id: `syn_${persona.tenantId.slice(-4)}_${String(seq++).padStart(4, '0')}`,
          tenant_id: persona.tenantId,
          event_timestamp: dinnerTs,
          ingested_at: dinnerTs,
          category: 'food',
          raw_text: dinner.raw,
          clarification_turns: rng() > 0.7 ? 1 : 0,
          system_alerts: dinnerAudit.system_alerts,
          food_metadata: {
            resolved_food_name: dinner.label,
            prep_state: dinner.prep,
            gluten_free_verified: dinner.gf,
            dairy_free_verified: dinner.df,
            ingredients: dinnerAudit.ingredients,
            macros: dinner.macros
          }
        })
      );

      // 5. Evening digestive comfort check-in (~21:30 UTC) — probabilistic lag + realistic baseline noise
      const hasPolyolToday = [lunch, dinner].some((m) =>
        m.ingredients.some((i) => /maltitol|lactitol|sorbitol/i.test(i))
      );
      const hasGumToday = [lunch, dinner].some((m) =>
        m.ingredients.some((i) => /gum/i.test(i))
      );
      const hasWheatGarlic = [lunch, dinner].some((m) =>
        m.ingredients.some((i) => /wheat|garlic/i.test(i))
      );

      const idiopathicShock = rng() > 0.86 ? 2.6 : 0;
      let latentDiscomfort =
        3.2 +
        (hasPolyolToday ? persona.polyolWeight * 1.15 : 0) +
        (hasGumToday ? 0.65 : 0) +
        (hasWheatGarlic ? 0.95 : 0) +
        prevDayRisk * 0.45 +
        (stressScore >= 7 ? persona.stressWeight : 0) +
        (sleepScore <= 4 ? 0.65 : 0) +
        idiopathicShock +
        (rng() - 0.5) * 3.1;

      const discomfortScore = Math.max(1, Math.min(10, Math.round(latentDiscomfort)));
      const symTs = new Date(dayBaseMs + (21 * 3600 + 30 * 60) * 1000).toISOString();

      events.push(
        CanonicalNutritionEventSchema.parse({
          event_id: `syn_${persona.tenantId.slice(-4)}_${String(seq++).padStart(4, '0')}`,
          tenant_id: persona.tenantId,
          event_timestamp: symTs,
          ingested_at: symTs,
          category: 'symptom',
          raw_text:
            discomfortScore >= 7
              ? `Evening GI check-in: noticeable abdominal distension (${discomfortScore}/10) a few hours after meals`
              : `Evening GI check-in: mild/comfortable digestion (${discomfortScore}/10)`,
          clarification_turns: 0,
          system_alerts: [],
          symptom_metadata: {
            symptom_type: discomfortScore >= 7 ? 'gi_distension' : 'abdominal_pressure',
            discomfort_score: discomfortScore,
            presentation: discomfortScore >= 7 ? 'visible_distension' : 'unspecified',
            onset_window_estimate: discomfortScore >= 7 ? 'delayed_3_8h' : 'unknown'
          }
        })
      );

      prevDayRisk = (hasPolyolToday ? 1.1 : 0) + (hasWheatGarlic ? 0.8 : 0);
    }
  }

  const medallion = runMedallionPipeline(events);
  const alexAnalytics = evaluateLongitudinalAnalytics(medallion.gold, 'demo_persona_alex');
  const mayaAnalytics = evaluateLongitudinalAnalytics(medallion.gold, 'demo_persona_maya');

  return {
    metadata: {
      generator: 'scripts/generate_synthetic_data.js',
      seed,
      synthetic_guarantee:
        '100% computer-generated synthetic records via seeded Mulberry32 PRNG. Zero personal or production records were transformed or sampled.',
      personas: ['demo_persona_alex', 'demo_persona_maya'],
      record_counts: {
        canonical_events: events.length,
        bronze_rows: medallion.bronze.length,
        silver_rows: medallion.silver.length,
        gold_rows: medallion.gold.length
      }
    },
    events,
    medallion,
    analytics_by_tenant: {
      demo_persona_alex: alexAnalytics,
      demo_persona_maya: mayaAnalytics
    }
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const dataset = generateSyntheticDataset(20261114);
  const outDir = path.join(ROOT_DIR, 'data');
  const uiDataDir = path.join(ROOT_DIR, 'src', 'data');
  fs.mkdirSync(outDir, { recursive: true });
  fs.mkdirSync(uiDataDir, { recursive: true });

  fs.writeFileSync(
    path.join(outDir, 'synthetic_events_60d.json'),
    JSON.stringify({ metadata: dataset.metadata, events: dataset.events }, null, 2)
  );
  fs.writeFileSync(
    path.join(outDir, 'synthetic_gold_features.json'),
    JSON.stringify({ metadata: dataset.metadata, gold: dataset.medallion.gold }, null, 2)
  );
  fs.writeFileSync(
    path.join(uiDataDir, 'precomputedDemoBundle.json'),
    JSON.stringify(
      {
        metadata: dataset.metadata,
        events: dataset.events,
        analytics_by_tenant: dataset.analytics_by_tenant
      },
      null,
      2
    )
  );

  console.log(
    `[Synthetic Data Generator] Wrote ${dataset.events.length} synthetic events and ${dataset.medallion.gold.length} Gold feature rows.`
  );
}
