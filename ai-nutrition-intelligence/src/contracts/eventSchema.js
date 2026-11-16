import { z } from 'zod';

export const TenantIdSchema = z
  .string()
  .regex(/^[a-z0-9_]{4,64}$/, 'tenant_id must be 4-64 lowercase alphanumeric or underscore characters');

export const SessionIdSchema = z
  .string()
  .regex(/^[a-zA-Z0-9_-]{4,96}$/, 'session_id must be 4-96 safe identifier characters');

export const IsoUtcTimestampSchema = z
  .string()
  .refine((val) => {
    const parsed = Date.parse(val);
    return !Number.isNaN(parsed) && val.endsWith('Z');
  }, 'Timestamp must be a valid ISO-8601 UTC string ending in Z');

export const IngredientTagSchema = z.enum([
  'HIGH_FODMAP_POLYOL',
  'FERMENTABLE_OLIGOSACCHARIDE',
  'HYDROCOLLOID_GUM',
  'EMULSIFIER_IRRITANT',
  'SEED_OIL',
  'DAIRY_DERIVED',
  'GLUTEN_RISK',
  'HIDDEN_ALLIUM_RISK',
  'LOW_RISK_POLYOL'
]);

export const IngestRequestSchema = z.object({
  tenant_id: TenantIdSchema,
  session_id: SessionIdSchema,
  channel: z.enum(['web_demo', 'chat_webhook']).default('web_demo'),
  modality: z.enum(['text', 'barcode', 'plate_photo']).default('text'),
  raw_text: z.string().trim().min(1, 'Input text cannot be empty').max(1000, 'Input text exceeds 1000 chars'),
  barcode_gtin13: z
    .string()
    .regex(/^\d{12,13}$/, 'Barcode must be a 12 or 13 digit GTIN/UPC')
    .nullable()
    .optional(),
  reference_timestamp: IsoUtcTimestampSchema
});

export const GatekeeperDecisionSchema = z.object({
  status: z.enum(['COMPLETE', 'NEEDS_CLARIFICATION']),
  event_timestamp: IsoUtcTimestampSchema,
  event_category: z.enum(['FOOD', 'SYMPTOM', 'SUPPLEMENT', 'CONTEXT']),
  modality_detected: z.enum(['text', 'barcode', 'plate_photo']),
  extracted_barcode: z.string().nullable(),
  ambiguity_reasons: z.array(z.string()),
  followup_prompt: z.string().nullable()
});

export const IngredientItemSchema = z.object({
  name: z.string().min(1),
  is_additive_or_filler: z.boolean(),
  tags: z.array(IngredientTagSchema)
});

export const FoodMetadataSchema = z.object({
  resolved_food_name: z.string().min(1),
  prep_state: z.enum(['raw', 'cooked', 'packaged', 'beverage', 'unknown']),
  gluten_free_verified: z.boolean(),
  dairy_free_verified: z.boolean(),
  ingredients: z.array(IngredientItemSchema),
  macros: z
    .object({
      calories: z.number().int().nonnegative(),
      protein_g: z.number().nonnegative(),
      carbs_g: z.number().nonnegative(),
      fat_g: z.number().nonnegative()
    })
    .optional()
});

export const SymptomMetadataSchema = z.object({
  symptom_type: z.enum(['gi_distension', 'abdominal_pressure', 'cramping', 'motility_shift', 'fatigue']),
  discomfort_score: z.number().int().min(1).max(10),
  presentation: z.enum(['visible_distension', 'internal_pressure', 'diffuse', 'unspecified']),
  onset_window_estimate: z.enum(['acute_0_3h', 'delayed_3_8h', 'overnight', 'unknown']).default('unknown')
});

export const SupplementMetadataSchema = z.object({
  supplement_name: z.string().min(1),
  formulation: z.enum(['capsule', 'powder', 'liquid', 'chewable', 'unknown']).default('capsule'),
  dosage_label: z.string().optional()
});

export const ContextMetadataSchema = z.object({
  sleep_quality_score: z.number().int().min(1).max(10).optional(),
  stress_score: z.number().int().min(1).max(10).optional(),
  notes: z.string().optional()
});

export const CanonicalNutritionEventSchema = z
  .object({
    event_id: z.string().min(6),
    tenant_id: TenantIdSchema,
    event_timestamp: IsoUtcTimestampSchema,
    ingested_at: IsoUtcTimestampSchema,
    category: z.enum(['food', 'symptom', 'supplement', 'context']),
    raw_text: z.string().min(1),
    clarification_turns: z.number().int().nonnegative().default(0),
    system_alerts: z.array(z.string()).default([]),
    food_metadata: FoodMetadataSchema.optional(),
    symptom_metadata: SymptomMetadataSchema.optional(),
    supplement_metadata: SupplementMetadataSchema.optional(),
    context_metadata: ContextMetadataSchema.optional()
  })
  .superRefine((event, ctx) => {
    if (event.category === 'food' && !event.food_metadata) {
      ctx.addIssue({
        code: 'custom',
        path: ['food_metadata'],
        message: 'food_metadata is required when category is food'
      });
    }
    if (event.category === 'symptom' && !event.symptom_metadata) {
      ctx.addIssue({
        code: 'custom',
        path: ['symptom_metadata'],
        message: 'symptom_metadata is required when category is symptom'
      });
    }
    if (event.category === 'supplement' && !event.supplement_metadata) {
      ctx.addIssue({
        code: 'custom',
        path: ['supplement_metadata'],
        message: 'supplement_metadata is required when category is supplement'
      });
    }
    if (event.category === 'context' && !event.context_metadata) {
      ctx.addIssue({
        code: 'custom',
        path: ['context_metadata'],
        message: 'context_metadata is required when category is context'
      });
    }
  });

export const SilverFlattenedRowSchema = z.object({
  event_id: z.string(),
  tenant_id: TenantIdSchema,
  event_timestamp: IsoUtcTimestampSchema,
  event_epoch_sec: z.number().int(),
  event_date_utc: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  category: z.enum(['food', 'symptom', 'supplement', 'context']),
  discomfort_score: z.number().int().min(1).max(10).nullable(),
  is_elevated_discomfort: z.union([z.literal(0), z.literal(1)]).nullable(),
  has_high_fodmap_polyol: z.union([z.literal(0), z.literal(1)]),
  has_fermentable_oligo: z.union([z.literal(0), z.literal(1)]),
  has_hydrocolloid_gum: z.union([z.literal(0), z.literal(1)]),
  has_emulsifier_irritant: z.union([z.literal(0), z.literal(1)]),
  has_seed_oil: z.union([z.literal(0), z.literal(1)]),
  has_unverified_gluten_risk: z.union([z.literal(0), z.literal(1)]),
  is_raw_plant_prep: z.union([z.literal(0), z.literal(1)]),
  took_digestive_supplement: z.union([z.literal(0), z.literal(1)]),
  sleep_quality_score: z.number().int().min(1).max(10).nullable(),
  stress_score: z.number().int().min(1).max(10).nullable()
});

export const GoldFeatureRowSchema = SilverFlattenedRowSchema.extend({
  prior_polyol_24h: z.number().int().nonnegative(),
  prior_oligo_24h: z.number().int().nonnegative(),
  prior_gum_24h: z.number().int().nonnegative(),
  prior_emulsifier_24h: z.number().int().nonnegative(),
  prior_seed_oil_24h: z.number().int().nonnegative(),
  prior_unverified_gluten_24h: z.number().int().nonnegative(),
  prior_raw_prep_24h: z.number().int().nonnegative(),
  prior_supplement_24h: z.number().int().nonnegative(),
  prior_fodmap_48h: z.number().int().nonnegative(),
  prior_poor_sleep_24h: z.union([z.literal(0), z.literal(1)]),
  prior_elevated_stress_24h: z.union([z.literal(0), z.literal(1)])
});
