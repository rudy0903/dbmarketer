import test from 'node:test';
import assert from 'node:assert/strict';
import { generateSyntheticDataset } from '../scripts/generate_synthetic_data.js';
import { runMedallionPipeline } from '../src/warehouse/medallionTransforms.js';
import { runSqliteMedallionPipeline } from '../src/warehouse/sqliteMedallionRunner.js';
import { evaluateLongitudinalAnalytics } from '../src/analytics/illustrativeModeling.js';

test('Seeded synthetic generator is 100% deterministic across runs', () => {
  const runA = generateSyntheticDataset(20261114);
  const runB = generateSyntheticDataset(20261114);

  assert.equal(runA.events.length, runB.events.length);
  assert.deepEqual(runA.events[0], runB.events[0]);
  assert.deepEqual(runA.medallion.gold[42], runB.medallion.gold[42]);
});

test('JS Medallion and SQLite Window-SQL Medallion produce identical Gold feature matrices', () => {
  const dataset = generateSyntheticDataset(20261114);
  const jsOut = runMedallionPipeline(dataset.events);
  const sqlOut = runSqliteMedallionPipeline(dataset.events);

  assert.equal(jsOut.gold.length, sqlOut.gold.length);

  for (let i = 0; i < jsOut.gold.length; i++) {
    assert.deepEqual(sqlOut.gold[i], jsOut.gold[i], `Row mismatch at index ${i}`);
  }
});

test('Prior rolling window excludes contemporaneous same-timestamp events (zero temporal leakage)', () => {
  const sameSecondEvents = [
    {
      event_id: 'evt_same_01',
      tenant_id: 'demo_persona_alex',
      event_timestamp: '2026-10-14T18:00:00.000Z',
      ingested_at: '2026-10-14T18:00:00.000Z',
      category: 'food',
      raw_text: 'Packaged bar with maltitol',
      clarification_turns: 0,
      system_alerts: [],
      food_metadata: {
        resolved_food_name: 'Maltitol Bar',
        prep_state: 'packaged',
        gluten_free_verified: true,
        dairy_free_verified: true,
        ingredients: [{ name: 'Maltitol', is_additive_or_filler: true, tags: ['HIGH_FODMAP_POLYOL'] }]
      }
    },
    {
      event_id: 'evt_same_02',
      tenant_id: 'demo_persona_alex',
      event_timestamp: '2026-10-14T18:00:00.000Z',
      ingested_at: '2026-10-14T18:00:00.000Z',
      category: 'symptom',
      raw_text: 'Discomfort 8/10',
      clarification_turns: 0,
      system_alerts: [],
      symptom_metadata: {
        symptom_type: 'gi_distension',
        discomfort_score: 8,
        presentation: 'visible_distension',
        onset_window_estimate: 'unknown'
      }
    }
  ];

  const sqlGold = runSqliteMedallionPipeline(sameSecondEvents).gold;
  const symptomRow = sqlGold.find((r) => r.event_id === 'evt_same_02');
  assert.equal(symptomRow.prior_polyol_24h, 0, 'Same-second exposure must not leak into prior_polyol_24h');
});

test('Illustrative longitudinal modeling enforces non-causal governance and chronological split', () => {
  const dataset = generateSyntheticDataset(20261114);
  const report = evaluateLongitudinalAnalytics(dataset.medallion.gold, 'demo_persona_alex');

  assert.equal(report.governance.is_causal_inference, false);
  assert.equal(report.governance.synthetic_data_only, true);
  assert.equal(report.sample_summary.total_symptom_observations, 60);
  assert.equal(report.sample_summary.train_observations, 45);
  assert.equal(report.sample_summary.validation_observations, 15);
  assert.ok(report.validation_metrics.held_out_roc_auc > 0.55);
  assert.ok(report.collinearity_diagnostics.length >= 1, 'Expected collinearity warning for co-occurring additives');
  assert.equal(report.daily_forecast_series.length, 60);
});
