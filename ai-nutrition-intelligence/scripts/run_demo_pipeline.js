import { ConversationalIngestionPipeline } from '../src/orchestration/ingestionPipeline.js';
import { runMedallionPipeline } from '../src/warehouse/medallionTransforms.js';
import { runSqliteMedallionPipeline } from '../src/warehouse/sqliteMedallionRunner.js';
import { evaluateLongitudinalAnalytics } from '../src/analytics/illustrativeModeling.js';
import { generateSyntheticDataset } from './generate_synthetic_data.js';

console.log('========================================================================');
console.log(' DBMarketer | AI Nutrition & Ingredient Intelligence — CLI Demo Runner');
console.log(' Mode: 100% Offline Synthetic Showcase (Zero External Credentials)');
console.log('========================================================================\n');

const pipeline = new ConversationalIngestionPipeline();

console.log('1) Turn 1 — Ambiguous Composite Meal Input:');
const turn1 = pipeline.ingestMessage({
  tenant_id: 'demo_persona_alex',
  session_id: 'sess_cli_demo_01',
  channel: 'web_demo',
  modality: 'text',
  raw_text: 'Had pasta and a side salad at 1pm',
  reference_timestamp: '2026-10-14T20:00:00.000Z'
});
console.log('   Status:', turn1.status);
console.log('   Ambiguity Reasons:', turn1.gatekeeper.ambiguity_reasons.join(', '));
console.log('   Gatekeeper Prompt:', turn1.followup_prompt, '\n');

console.log('2) Turn 2 — User Clarification Resolves Contract:');
const turn2 = pipeline.ingestMessage({
  tenant_id: 'demo_persona_alex',
  session_id: 'sess_cli_demo_01',
  channel: 'web_demo',
  modality: 'text',
  raw_text: 'Certified gluten-free brown rice pasta and raw greens with olive oil and lemon',
  reference_timestamp: '2026-10-14T20:01:00.000Z'
});
console.log('   Status:', turn2.status);
console.log('   Parsed Event UTC Timestamp:', turn2.persisted_event.event_timestamp);
console.log('   Resolved Food:', turn2.persisted_event.food_metadata.resolved_food_name);
console.log('   Prep State:', turn2.persisted_event.food_metadata.prep_state);
console.log('   GF Verified:', turn2.persisted_event.food_metadata.gluten_free_verified, '\n');

console.log('3) Turn 3 — Packaged Protein Shake with Polyols & Gums:');
const turn3 = pipeline.ingestMessage({
  tenant_id: 'demo_persona_alex',
  session_id: 'sess_cli_demo_02',
  channel: 'web_demo',
  modality: 'barcode',
  barcode_gtin13: '0074312098765',
  raw_text: 'Scanned barcode for afternoon chocolate protein shake',
  reference_timestamp: '2026-10-14T21:15:00.000Z'
});
console.log('   Resolved Food:', turn3.persisted_event.food_metadata.resolved_food_name);
console.log('   Taxonomy Alerts Triggered:', turn3.persisted_event.system_alerts.length);
for (const alert of turn3.persisted_event.system_alerts) {
  console.log(`     - ${alert}`);
}
console.log('');

console.log('4) Synthetic 60-Day Medallion Warehouse & SQLite Parity Verification:');
const dataset = generateSyntheticDataset(20261114);
const jsGold = runMedallionPipeline(dataset.events).gold;
const sqlGold = runSqliteMedallionPipeline(dataset.events).gold;
console.log(`   JS Gold Rows: ${jsGold.length} | SQLite Window-SQL Gold Rows: ${sqlGold.length}`);

const analytics = evaluateLongitudinalAnalytics(sqlGold, 'demo_persona_alex');
console.log('\n5) Illustrative Longitudinal Modeling Summary (demo_persona_alex — Synthetic):');
console.log('   Split Strategy:', analytics.governance.split_strategy);
console.log('   Held-Out Validation ROC-AUC:', analytics.validation_metrics.held_out_roc_auc);
console.log('   Top Observational Feature Associations (NOT Causal Effects):');
for (const feat of analytics.feature_attributions.slice(0, 4)) {
  console.log(
    `     - ${feat.label}: share=${(feat.relative_attribution_share * 100).toFixed(1)}%, RR=${feat.observational_risk_ratio}x (95% CI ${feat.ci95_low}-${feat.ci95_high})`
  );
}
console.log(`   Collinearity Warnings Surfaced: ${analytics.collinearity_diagnostics.length}`);
console.log('\nDone. Non-clinical engineering showcase verified successfully.');
