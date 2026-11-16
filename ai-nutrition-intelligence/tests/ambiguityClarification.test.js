import test from 'node:test';
import assert from 'node:assert/strict';
import { ConversationalIngestionPipeline } from '../src/orchestration/ingestionPipeline.js';
import { LiteratureSynthesisInterface } from '../src/adapters/mockExternalServices.js';

test('Ambiguous meal triggers NEEDS_CLARIFICATION and resolves cleanly on follow-up turn', () => {
  const pipeline = new ConversationalIngestionPipeline();

  const firstTurn = pipeline.ingestMessage({
    tenant_id: 'demo_persona_alex',
    session_id: 'sess_ambig_01',
    raw_text: 'Had pasta and a side salad at 1pm',
    reference_timestamp: '2026-10-14T20:00:00.000Z'
  });

  assert.equal(firstTurn.status, 'NEEDS_CLARIFICATION');
  assert.equal(firstTurn.persisted_event, null);
  assert.ok(firstTurn.gatekeeper.ambiguity_reasons.includes('missing_gluten_verification'));
  assert.ok(firstTurn.gatekeeper.ambiguity_reasons.includes('missing_dressing_or_sauce'));
  assert.ok(firstTurn.gatekeeper.ambiguity_reasons.includes('missing_prep_state_raw_vs_cooked'));
  assert.equal(pipeline.getTenantEvents('demo_persona_alex').length, 0);

  const secondTurn = pipeline.ingestMessage({
    tenant_id: 'demo_persona_alex',
    session_id: 'sess_ambig_01',
    raw_text: 'Gluten-free brown rice pasta and raw spinach with olive oil and lemon',
    reference_timestamp: '2026-10-14T20:01:30.000Z'
  });

  assert.equal(secondTurn.status, 'COMPLETE');
  assert.ok(secondTurn.persisted_event);
  assert.equal(secondTurn.persisted_event.clarification_turns, 1);
  assert.equal(secondTurn.persisted_event.event_timestamp, '2026-10-14T13:00:00.000Z');
  assert.equal(secondTurn.persisted_event.food_metadata.gluten_free_verified, true);
  assert.equal(secondTurn.persisted_event.food_metadata.prep_state, 'raw');
  assert.equal(pipeline.getSessionState('demo_persona_alex', 'sess_ambig_01'), null);
  assert.equal(pipeline.getTenantEvents('demo_persona_alex').length, 1);
});

test('Fully specified meal logs in a single turn without unnecessary clarification', () => {
  const pipeline = new ConversationalIngestionPipeline();

  const turn = pipeline.ingestMessage({
    tenant_id: 'demo_persona_alex',
    session_id: 'sess_clear_01',
    raw_text: 'Grilled wild salmon with steamed zucchini and jasmine rice at 7pm',
    reference_timestamp: '2026-10-14T22:00:00.000Z'
  });

  assert.equal(turn.status, 'COMPLETE');
  assert.equal(turn.persisted_event.clarification_turns, 0);
  assert.equal(turn.persisted_event.event_timestamp, '2026-10-14T19:00:00.000Z');
});

test('LiteratureSynthesisInterface explicitly documents contract and blocks live calls in offline demo', async () => {
  const spec = LiteratureSynthesisInterface.describeContract();
  assert.equal(spec.status, 'INTERFACE_DOCUMENTED_ONLY');

  const adapter = new LiteratureSynthesisInterface();
  await assert.rejects(() => adapter.executeLiveSearch(), /OfflineDemoBoundaryError/);
});
