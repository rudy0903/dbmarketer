import test from 'node:test';
import assert from 'node:assert/strict';
import {
  ConversationalIngestionPipeline,
  TenantIsolationError
} from '../src/orchestration/ingestionPipeline.js';
import { runMedallionPipeline } from '../src/warehouse/medallionTransforms.js';
import { runSqliteMedallionPipeline } from '../src/warehouse/sqliteMedallionRunner.js';

test('Session store rejects cross-tenant session access with TenantIsolationError', () => {
  const pipeline = new ConversationalIngestionPipeline();

  pipeline.ingestMessage({
    tenant_id: 'tenant_alpha',
    session_id: 'shared_session_token',
    raw_text: 'Had pasta for lunch',
    reference_timestamp: '2026-10-14T12:00:00.000Z'
  });

  assert.throws(
    () =>
      pipeline.ingestMessage({
        tenant_id: 'tenant_bravo',
        session_id: 'shared_session_token',
        raw_text: 'It was gluten-free pasta',
        reference_timestamp: '2026-10-14T12:02:00.000Z'
      }),
    TenantIsolationError
  );

  assert.throws(
    () => pipeline.getSessionState('tenant_bravo', 'shared_session_token'),
    TenantIsolationError
  );
});

test('Warehouse Gold 24h lag windows strictly partition by tenant_id across both JS and SQLite engines', () => {
  const pipeline = new ConversationalIngestionPipeline();

  // Tenant Alpha consumes a high-polyol/gum protein shake at 14:00 UTC
  pipeline.ingestMessage({
    tenant_id: 'tenant_alpha',
    session_id: 'sess_alpha_1',
    modality: 'barcode',
    barcode_gtin13: '0074312098765',
    raw_text: 'Protein shake',
    reference_timestamp: '2026-10-14T14:00:00.000Z'
  });

  // Tenant Bravo logs an evening symptom 4 hours later at 18:00 UTC with ZERO food logs
  pipeline.ingestMessage({
    tenant_id: 'tenant_bravo',
    session_id: 'sess_bravo_1',
    raw_text: 'Severe abdominal distension 8/10',
    reference_timestamp: '2026-10-14T18:00:00.000Z'
  });

  const combinedEvents = [
    ...pipeline.getTenantEvents('tenant_alpha'),
    ...pipeline.getTenantEvents('tenant_bravo')
  ];

  const jsGold = runMedallionPipeline(combinedEvents).gold;
  const sqlGold = runSqliteMedallionPipeline(combinedEvents).gold;

  const bravoJsRow = jsGold.find((r) => r.tenant_id === 'tenant_bravo');
  const bravoSqlRow = sqlGold.find((r) => r.tenant_id === 'tenant_bravo');

  assert.equal(bravoJsRow.prior_polyol_24h, 0, 'JS Gold leaked Tenant Alpha polyol exposure into Tenant Bravo');
  assert.equal(bravoJsRow.prior_gum_24h, 0, 'JS Gold leaked Tenant Alpha gum exposure into Tenant Bravo');
  assert.equal(bravoSqlRow.prior_polyol_24h, 0, 'SQLite Gold leaked Tenant Alpha polyol exposure into Tenant Bravo');
  assert.equal(bravoSqlRow.prior_gum_24h, 0, 'SQLite Gold leaked Tenant Alpha gum exposure into Tenant Bravo');
});
