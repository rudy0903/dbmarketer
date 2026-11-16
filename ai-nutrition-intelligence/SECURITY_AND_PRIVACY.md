# Security, Privacy & Responsible AI Controls

**AI Nutrition & Ingredient Intelligence**  
By Database Marketer | [https://dbmarketer.com](https://dbmarketer.com)

---

## 1. Non-Clinical & Non-Diagnostic Disclaimer

> **Important Notice:** This package (`ai-nutrition-intelligence/`) and interactive demonstration present software engineering, data modeling, and applied analytics methods only, governed by the [Database Marketer Source-Available Portfolio & Evaluation License](LICENSE). It is **not** a medical device, clinical decision-support system, diagnostic service, or validated dietary treatment protocol. All records, personas, timelines, and analytical outputs in this package are **100% computer-generated synthetic data**. Observational associations surfaced by statistical or machine learning models do not establish biological causation.

---

## 2. Clean-Room Isolation & Synthetic Data Guarantees

1. **Clean-Room Positive-Allowlist Package:** Authored from scratch inside `ai-nutrition-intelligence/` using a strict positive allowlist with zero shared Git history from any private operational repository.
2. **Zero De-Identified Personal Records:** Real household or health logs are **never** "anonymized" or perturbed for public display. Instead, `scripts/generate_synthetic_data.js` synthesizes artificial events from scratch using a deterministic Mulberry32 pseudorandom number generator (`seed = 20261114`) for two fictional personas (`demo_persona_alex` and `demo_persona_maya`).
3. **Zero External Credentials or Cloud SDK Surface:** Runtime dependencies exclude cloud SDKs (`firebase`, `@google-cloud/bigquery`, `@google/genai`). No API keys, OAuth secrets, webhook URLs, or project identifiers are required or accepted by the demo.
4. **Asset & Build Hygiene:**
   * Production Vite builds disable source maps (`build.sourcemap = false`).
   * Every screenshot and rendered diagram in `assets/originals/` and `assets/web/` has all ancillary PNG metadata chunks (`eXIf`, `tEXt`, `iTXt`, `zTXt`, `tIME`) stripped, retaining only essential pixel/header chunks (`IHDR`, `PLTE`, `tRNS`, `sRGB`, `IDAT`, `IEND`).

---

## 3. Multi-Tenant Isolation Controls

Multi-tenant health and nutrition systems require defense-in-depth across four layers:

### 3.1 Conversational Session Isolation
In `src/orchestration/ingestionPipeline.js`, every active clarification thread binds `session_id` to `ownerTenantId`. Any attempt by a second tenant to read or resume another tenant's session throws `TenantIsolationError` (verified in `tests/tenantIsolation.test.js`).

### 3.2 Operational Document Store Rules (Least-Privilege Pattern)
A frequent pitfall in document-database security rules is pairing a collection-specific ownership rule with a global authenticated fallback (`match /{document=**} { allow read, write: if request.auth != null; }`). Because rule engines grant access if *any* matching `allow` statement evaluates to `true`, a global wildcard rule overrides stricter per-collection tenant checks.

Production deployments must omit global wildcards and enforce explicit per-collection tenant predicates with default deny:

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /logs/{logId} {
      allow create: if request.auth != null
                    && request.resource.data.tenant_id == request.auth.uid;
      allow read, update, delete: if request.auth != null
                                  && resource.data.tenant_id == request.auth.uid;
    }

    match /users/{userId}/regimen/{itemId} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }

    // Explicit default deny for all unmatched paths
    match /{document=**} {
      allow read, write: if false;
    }
  }
}
```

### 3.3 Webhook Origin & Secret-Token Verification
Conversational webhooks (such as messaging bot HTTPS endpoints) should never rely solely on checking the sender identifier inside the JSON body, because an external caller who discovers the HTTPS endpoint URL can forge POST payloads. Production webhook handlers should validate a cryptographic secret header (`X-Telegram-Bot-Api-Secret-Token`) via constant-time comparison (`crypto.timingSafeEqual`) before parsing media or request bodies, and all callable RPC endpoints must verify `request.auth.uid` against an authorized tenant check prior to reading data or invoking paid LLM/warehouse APIs.

### 3.4 Warehouse Window Isolation
In `warehouse/dbt_reference/models/gold/fct_ml_feature_store.sql` and `src/warehouse/sqliteMedallionRunner.js`, every rolling `24h` and `48h` window enforces `PARTITION BY tenant_id` and `RANGE BETWEEN 86400 PRECEDING AND 1 PRECEDING`, preventing cross-tenant feature bleed and same-timestamp outcome leakage (verified in `tests/tenantIsolation.test.js`).
