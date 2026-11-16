import test from 'node:test';
import assert from 'node:assert/strict';
import {
  IngestRequestSchema,
  CanonicalNutritionEventSchema
} from '../src/contracts/eventSchema.js';
import { auditIngredientList } from '../src/taxonomy/dietaryRules.js';

test('IngestRequestSchema rejects empty text, invalid tenant_id, and non-UTC timestamps', () => {
  assert.throws(() =>
    IngestRequestSchema.parse({
      tenant_id: 'INVALID UPPERCASE!',
      session_id: 'sess_01',
      raw_text: 'Had oatmeal',
      reference_timestamp: '2026-10-14T12:00:00.000Z'
    })
  );

  assert.throws(() =>
    IngestRequestSchema.parse({
      tenant_id: 'demo_persona_alex',
      session_id: 'sess_01',
      raw_text: '   ',
      reference_timestamp: '2026-10-14T12:00:00.000Z'
    })
  );

  assert.throws(() =>
    IngestRequestSchema.parse({
      tenant_id: 'demo_persona_alex',
      session_id: 'sess_01',
      raw_text: 'Grilled chicken',
      reference_timestamp: '10/14/2026 12:00 PM PST'
    })
  );
});

test('CanonicalNutritionEventSchema enforces category-specific metadata contracts', () => {
  assert.throws(() =>
    CanonicalNutritionEventSchema.parse({
      event_id: 'evt_test_0001',
      tenant_id: 'demo_persona_alex',
      event_timestamp: '2026-10-14T12:00:00.000Z',
      ingested_at: '2026-10-14T12:00:05.000Z',
      category: 'food',
      raw_text: 'Grilled salmon'
      // missing food_metadata
    })
  );

  const validSymptom = CanonicalNutritionEventSchema.parse({
    event_id: 'evt_test_0002',
    tenant_id: 'demo_persona_alex',
    event_timestamp: '2026-10-14T18:00:00.000Z',
    ingested_at: '2026-10-14T18:00:02.000Z',
    category: 'symptom',
    raw_text: 'Abdominal discomfort 7/10',
    symptom_metadata: {
      symptom_type: 'gi_distension',
      discomfort_score: 7,
      presentation: 'visible_distension'
    }
  });
  assert.equal(validSymptom.symptom_metadata.discomfort_score, 7);
});

test('Taxonomy rules distinguish high-risk polyols/dairy (Lactitol) from Erythritol and flag chewable excipients', () => {
  const res = auditIngredientList(['Lactitol', 'Erythritol', 'Xanthan Gum', 'Carrageenan'], {
    glutenFreeVerified: true
  });

  const lactitol = res.ingredients.find((i) => i.name === 'Lactitol');
  const erythritol = res.ingredients.find((i) => i.name === 'Erythritol');

  assert.ok(lactitol.tags.includes('HIGH_FODMAP_POLYOL'));
  assert.ok(lactitol.tags.includes('DAIRY_DERIVED'));
  assert.deepEqual(erythritol.tags, ['LOW_RISK_POLYOL']);
  assert.ok(res.system_alerts.length >= 3);

  const chewableRes = auditIngredientList([], { formulation: 'chewable' });
  assert.equal(chewableRes.system_alerts.length, 1);
  assert.match(chewableRes.system_alerts[0], /Liquid and chewable/i);
});
