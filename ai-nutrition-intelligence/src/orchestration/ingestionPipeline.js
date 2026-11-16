import {
  IngestRequestSchema,
  CanonicalNutritionEventSchema
} from '../contracts/eventSchema.js';
import { auditIngredientList } from '../taxonomy/dietaryRules.js';
import {
  MockGeminiOrchestrator,
  MockNutritionCatalogAdapter
} from '../adapters/mockExternalServices.js';

export class TenantIsolationError extends Error {
  constructor(message) {
    super(message);
    this.name = 'TenantIsolationError';
  }
}

export class ConversationalIngestionPipeline {
  constructor({
    orchestrator = new MockGeminiOrchestrator(),
    nutritionCatalog = new MockNutritionCatalogAdapter()
  } = {}) {
    this.orchestrator = orchestrator;
    this.nutritionCatalog = nutritionCatalog;
    // Map<sessionId, { ownerTenantId, pendingText, clarificationQuestion, turns, updatedAt }>
    this.sessions = new Map();
    // Map<tenantId, Array<CanonicalNutritionEvent>>
    this.tenantEvents = new Map();
    this.counter = 1;
  }

  _nextEventId(tenantId) {
    const seq = String(this.counter++).padStart(5, '0');
    return `evt_${tenantId.slice(0, 12)}_${seq}`;
  }

  getSessionState(tenantId, sessionId) {
    const existing = this.sessions.get(sessionId);
    if (!existing) return null;
    if (existing.ownerTenantId !== tenantId) {
      throw new TenantIsolationError(
        `Cross-tenant session access denied for session "${sessionId}".`
      );
    }
    return { ...existing };
  }

  getTenantEvents(tenantId) {
    return (this.tenantEvents.get(tenantId) || []).map((evt) => structuredClone(evt));
  }

  ingestMessage(rawRequest) {
    const req = IngestRequestSchema.parse(rawRequest);
    const existingSession = this.sessions.get(req.session_id);

    if (existingSession && existingSession.ownerTenantId !== req.tenant_id) {
      throw new TenantIsolationError(
        `Session "${req.session_id}" belongs to another tenant; access rejected.`
      );
    }

    let combinedText = req.raw_text;
    let clarificationTurns = 0;

    if (existingSession && existingSession.pendingText) {
      clarificationTurns = existingSession.turns + 1;
      combinedText = `${existingSession.pendingText} | Clarification: ${req.raw_text}`;
    }

    const gatekeeperDecision = this.orchestrator.evaluateGatekeeper({
      rawText: combinedText,
      referenceTimestamp: req.reference_timestamp,
      modality: req.modality,
      barcodeGtin13: req.barcode_gtin13 || null
    });

    if (gatekeeperDecision.status === 'NEEDS_CLARIFICATION') {
      const updatedSession = {
        ownerTenantId: req.tenant_id,
        pendingText: combinedText,
        clarificationQuestion: gatekeeperDecision.followup_prompt,
        ambiguityReasons: gatekeeperDecision.ambiguity_reasons,
        turns: clarificationTurns,
        updatedAt: req.reference_timestamp
      };
      this.sessions.set(req.session_id, updatedSession);

      return {
        status: 'NEEDS_CLARIFICATION',
        tenant_id: req.tenant_id,
        session_id: req.session_id,
        gatekeeper: gatekeeperDecision,
        followup_prompt: gatekeeperDecision.followup_prompt,
        persisted_event: null
      };
    }

    if (existingSession) {
      this.sessions.delete(req.session_id);
    }

    const draft = this.orchestrator.extractStructuredDraft({
      rawText: combinedText,
      gatekeeperDecision
    });

    let eventCandidate = {
      event_id: this._nextEventId(req.tenant_id),
      tenant_id: req.tenant_id,
      event_timestamp: gatekeeperDecision.event_timestamp,
      ingested_at: req.reference_timestamp,
      category: draft.category,
      raw_text: combinedText,
      clarification_turns: clarificationTurns,
      system_alerts: []
    };

    if (draft.category === 'food') {
      const catalogMatch =
        gatekeeperDecision.modality_detected === 'barcode' && gatekeeperDecision.extracted_barcode
          ? this.nutritionCatalog.lookupByBarcode(gatekeeperDecision.extracted_barcode)
          : this.nutritionCatalog.lookupByNaturalLanguage(combinedText);

      const resolvedGf =
        draft.food_draft.gluten_free_verified || catalogMatch.gluten_free_verified;
      const resolvedPrep =
        draft.food_draft.prep_state !== 'unknown'
          ? draft.food_draft.prep_state
          : catalogMatch.default_prep_state;

      const audit = auditIngredientList(catalogMatch.ingredients, {
        glutenFreeVerified: resolvedGf
      });

      eventCandidate.system_alerts = audit.system_alerts;
      eventCandidate.food_metadata = {
        resolved_food_name: catalogMatch.resolved_food_name,
        prep_state: resolvedPrep,
        gluten_free_verified: resolvedGf,
        dairy_free_verified: catalogMatch.dairy_free_verified,
        ingredients: audit.ingredients,
        macros: catalogMatch.macros
      };
    } else if (draft.category === 'symptom') {
      eventCandidate.symptom_metadata = draft.symptom_metadata;
    } else if (draft.category === 'supplement') {
      const audit = auditIngredientList([], {
        formulation: draft.supplement_metadata.formulation
      });
      eventCandidate.system_alerts = audit.system_alerts;
      eventCandidate.supplement_metadata = draft.supplement_metadata;
    } else if (draft.category === 'context') {
      eventCandidate.context_metadata = draft.context_metadata;
    }

    const validatedEvent = CanonicalNutritionEventSchema.parse(eventCandidate);

    if (!this.tenantEvents.has(req.tenant_id)) {
      this.tenantEvents.set(req.tenant_id, []);
    }
    this.tenantEvents.get(req.tenant_id).push(validatedEvent);

    return {
      status: 'COMPLETE',
      tenant_id: req.tenant_id,
      session_id: req.session_id,
      gatekeeper: gatekeeperDecision,
      followup_prompt: null,
      persisted_event: validatedEvent
    };
  }
}
