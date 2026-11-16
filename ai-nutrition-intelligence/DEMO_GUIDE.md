# Local Demonstration Guide

**DBMarketer | AI Nutrition & Ingredient Intelligence**  
*100% Offline Synthetic Mode - Zero External API Keys Required*

> **License Note:** This package (`ai-nutrition-intelligence/`) is source-available under the [Database Marketer Source-Available Portfolio & Evaluation License](LICENSE) (not Apache 2.0). Cloning, installing dependencies, running tests, and executing this demonstration locally for study, hiring review, or internal technical evaluation is permitted without prior permission.

---

## Prerequisites

* **Node.js `>= 22.5.0`** (tested on Node `v24.14.0`; uses Node's built-in `node:test` runner and `node:sqlite` in-memory SQL engine).
* **npm `>= 10.0.0`**.
* **No cloud accounts, `.env` secrets, or network access required** after `npm install`.

---

## 1. Quickstart (Install, Test & Run CLI Pipeline)

```bash
# 1. Navigate to the package directory inside the dbmarketer repository
cd ai-nutrition-intelligence

# 2. Install dependencies
npm install

# 3. Deterministically regenerate the 60-day synthetic dataset (seed = 20261114)
npm run generate:data

# 4. Execute the 12-test validation suite (schema contracts, ambiguity hold, tenant isolation, SQLite parity)
npm test

# 5. Run the end-to-end conversational + Medallion + modeling CLI walkthrough
npm run demo:pipeline
```

---

## 2. Launch the Interactive Web Showcase

```bash
npm run dev
```

Open `http://localhost:4173` in your browser.

### Walkthrough Scenarios in the Web UI

1. **Tab 1 - Executive & System Overview:**
   * Inspect KPI cards for synthetic persona `demo_persona_alex` (60 simulated days) or switch the top-right **Synthetic Tenant** selector to `demo_persona_maya` (30 simulated days) to observe real-time tenant-isolated re-computation across Medallion layers and analytical charts.
2. **Tab 2 - Gatekeeper & Schema Extraction Sandbox:**
   * Click **`1. Ambiguous Meal`** (`"Had pasta and a side salad at 1pm"`). Observe how the Gatekeeper intercepts persistence (`NEEDS_CLARIFICATION`), parses `"1pm"` into `2026-10-14T13:00:00.000Z`, and identifies three missing contract attributes (`missing_gluten_verification`, `missing_dressing_or_sauce`, `missing_prep_state_raw_vs_cooked`).
   * Click **`2. Clarified Resolution`** to see how the follow-up turn stitches context, clears session memory, and produces a `COMPLETE` Zod-validated payload.
   * Click **`3. Barcode Polyol Audit`** (`GTIN-13: 0074312098765`) to inspect how `Maltitol`, `Lactitol`, `Xanthan Gum`, `Carrageenan`, `Soy Lecithin`, and `Natural Flavors` trigger specific additive taxonomy alerts while leaving `Pea Protein Isolate` unflagged.
   * Type your own test prompts in the input box (e.g., `"Had tacos for lunch"` vs. `"Grilled wild salmon with steamed zucchini at 7pm"`).
3. **Tab 3 - Longitudinal Analytics & Forecast:**
   * Review the **60-Day Discomfort Score vs. Rolling 7-Day 95% Baseline Band** chart. Rose markers highlight days exceeding the rolling upper 95% threshold; bottom ticks mark high-polyol meal days.
   * Review **Held-Out Lagged Feature Associations** alongside **Collinearity & Sample Diagnostics** (`polyol_24h <-> emulsifier_24h`), illustrating how co-occurring packaged-food additives share predictive variance.
4. **Tab 4 - Medallion Warehouse (`Bronze -> Silver -> Gold`):**
   * Toggle between **Bronze** (immutable JSON envelope), **Silver** (`0/1` flattened ingredient flags), and **Gold** (`prior_polyol_24h`, `prior_gum_24h`, `prior_fodmap_48h` strictly-prior lag features), and compare against the BigQuery dbt SQL models in `warehouse/dbt_reference/models/`.
