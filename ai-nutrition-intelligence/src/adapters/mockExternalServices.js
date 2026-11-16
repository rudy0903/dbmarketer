import { GatekeeperDecisionSchema } from '../contracts/eventSchema.js';

const SYNTHETIC_NUTRITION_CATALOG = [
  {
    key: 'gf_pasta_and_raw_greens_salad',
    matchTerms: ['brown rice pasta', 'side salad', 'raw spinach', 'raw greens'],
    barcode: null,
    resolved_food_name: 'Gluten-Free Brown Rice Pasta & Raw Greens Salad (Olive Oil & Lemon)',
    default_prep_state: 'raw',
    gluten_free_verified: true,
    dairy_free_verified: true,
    ingredients: [
      'Organic Brown Rice Pasta',
      'Baby Spinach',
      'Extra Virgin Olive Oil',
      'Lemon Juice',
      'Sea Salt'
    ],
    macros: { calories: 510, protein_g: 11, carbs_g: 70, fat_g: 20 }
  },
  {
    key: 'gf_brown_rice_pasta_olive_oil',
    matchTerms: ['gf pasta', 'gluten-free pasta', 'gluten free pasta', 'brown rice pasta'],
    barcode: '0085239012345',
    resolved_food_name: 'Gluten-Free Brown Rice Pasta with Extra Virgin Olive Oil & Basil',
    default_prep_state: 'cooked',
    gluten_free_verified: true,
    dairy_free_verified: true,
    ingredients: ['Organic Brown Rice Flour', 'Water', 'Extra Virgin Olive Oil', 'Fresh Basil', 'Sea Salt'],
    macros: { calories: 410, protein_g: 9, carbs_g: 64, fat_g: 14 }
  },
  {
    key: 'wheat_pasta_garlic_marinara',
    matchTerms: ['wheat pasta', 'regular pasta', 'marinara', 'garlic sauce'],
    barcode: '0041303054321',
    resolved_food_name: 'Semolina Pasta with Garlic-Onion Marinara',
    default_prep_state: 'cooked',
    gluten_free_verified: false,
    dairy_free_verified: true,
    ingredients: ['Durum Wheat Semolina', 'Crushed Tomatoes', 'Garlic', 'Onion', 'Sunflower Oil', 'Natural Flavors'],
    macros: { calories: 460, protein_g: 14, carbs_g: 78, fat_g: 9 }
  },
  {
    key: 'protein_shake_maltitol_gums',
    matchTerms: ['protein shake', 'protein bar', 'chocolate shake', 'keto bar', 'meal replacement'],
    barcode: '0074312098765',
    resolved_food_name: 'Low-Sugar Chocolate Protein Shake (Packaged)',
    default_prep_state: 'beverage',
    gluten_free_verified: true,
    dairy_free_verified: false,
    ingredients: [
      'Filtered Water',
      'Pea Protein Isolate',
      'Maltitol',
      'Lactitol',
      'Xanthan Gum',
      'Carrageenan',
      'Canola Oil',
      'Soy Lecithin',
      'Natural Flavors'
    ],
    macros: { calories: 190, protein_g: 24, carbs_g: 16, fat_g: 5 }
  },
  {
    key: 'grilled_salmon_steamed_zucchini_rice',
    matchTerms: ['salmon', 'steamed zucchini', 'jasmine rice', 'grilled chicken'],
    barcode: null,
    resolved_food_name: 'Grilled Wild Salmon with Steamed Zucchini & Jasmine Rice',
    default_prep_state: 'cooked',
    gluten_free_verified: true,
    dairy_free_verified: true,
    ingredients: ['Wild Sockeye Salmon', 'Zucchini', 'Jasmine Rice', 'Olive Oil', 'Lemon Juice', 'Sea Salt'],
    macros: { calories: 520, protein_g: 38, carbs_g: 46, fat_g: 18 }
  },
  {
    key: 'mixed_greens_lemon_olive_oil',
    matchTerms: ['lemon olive oil', 'olive oil and lemon', 'vinaigrette', 'cooked greens', 'raw greens'],
    barcode: null,
    resolved_food_name: 'Mixed Greens Salad with Lemon & Olive Oil Dressing',
    default_prep_state: 'raw',
    gluten_free_verified: true,
    dairy_free_verified: true,
    ingredients: ['Baby Spinach', 'Arugula', 'Cucumber', 'Extra Virgin Olive Oil', 'Lemon Juice'],
    macros: { calories: 210, protein_g: 3, carbs_g: 8, fat_g: 18 }
  },
  {
    key: 'restaurant_caesar_salad',
    matchTerms: ['caesar', 'creamy dressing', 'ranch', 'croutons'],
    barcode: null,
    resolved_food_name: 'Restaurant Salad with Creamy Garlic Dressing & Croutons',
    default_prep_state: 'raw',
    gluten_free_verified: false,
    dairy_free_verified: false,
    ingredients: ['Romaine Lettuce', 'Wheat Flour', 'Soybean Oil', 'Buttermilk', 'Garlic', 'Xanthan Gum', 'Natural Flavors'],
    macros: { calories: 480, protein_g: 11, carbs_g: 26, fat_g: 36 }
  },
  {
    key: 'savory_soup_broth',
    matchTerms: ['soup', 'broth', 'ramen', 'bowl'],
    barcode: '0039800011223',
    resolved_food_name: 'Packaged Savory Vegetable Rice Soup',
    default_prep_state: 'cooked',
    gluten_free_verified: true,
    dairy_free_verified: true,
    ingredients: ['Vegetable Broth', 'White Rice', 'Carrots', 'Dehydrated Vegetables', 'Guar Gum', 'Savory Spices'],
    macros: { calories: 240, protein_g: 5, carbs_g: 44, fat_g: 4 }
  },
  {
    key: 'oat_milk_latte',
    matchTerms: ['oat milk', 'latte', 'iced coffee', 'plant milk'],
    barcode: '0091234500119',
    resolved_food_name: 'Barista Oat Milk Espresso Beverage',
    default_prep_state: 'beverage',
    gluten_free_verified: false,
    dairy_free_verified: true,
    ingredients: ['Oat Base', 'Sunflower Oil', 'Guar Gum', 'Gellan Gum', 'Espresso'],
    macros: { calories: 160, protein_g: 3, carbs_g: 21, fat_g: 7 }
  }
];

function parseRelativeTimeUtc(rawText, referenceIso) {
  const refDate = new Date(referenceIso);
  const match = rawText.match(/\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b/i);
  if (!match) {
    return refDate.toISOString();
  }
  let hours = parseInt(match[1], 10);
  const minutes = match[2] ? parseInt(match[2], 10) : 0;
  const meridiem = match[3].toLowerCase();
  if (meridiem === 'pm' && hours < 12) hours += 12;
  if (meridiem === 'am' && hours === 12) hours = 0;

  const adjusted = new Date(
    Date.UTC(refDate.getUTCFullYear(), refDate.getUTCMonth(), refDate.getUTCDate(), hours, minutes, 0, 0)
  );
  return adjusted.toISOString();
}

function detectAmbiguity(combinedText) {
  const lower = combinedText.toLowerCase();
  const reasons = [];

  const mentionsGrainOrBaked = /\b(pasta|bread|toast|bagel|wrap|tortilla|noodles|sandwich|croissant|muffin)\b/.test(lower);
  const clarifiesGlutenStatus = /\b(gluten[- ]free|\bgf\b|brown rice|wheat|regular wheat|semolina|sourdough wheat)\b/.test(lower);
  if (mentionsGrainOrBaked && !clarifiesGlutenStatus) {
    reasons.push('missing_gluten_verification');
  }

  const mentionsCompositeDish = /\b(salad|tacos|stir[- ]?fry|burrito bowl|grain bowl)\b/.test(lower);
  const clarifiesSauceOrDressing = /\b(dressing|olive oil|vinaigrette|lemon|no sauce|dry|marinara|caesar|ranch|tamari|avocado oil)\b/.test(
    lower
  );
  if (mentionsCompositeDish && !clarifiesSauceOrDressing) {
    reasons.push('missing_dressing_or_sauce');
  }

  const mentionsVegetables = /\b(salad|greens|broccoli|zucchini|carrots|spinach|kale|cauliflower|veggies|vegetables)\b/.test(lower);
  const clarifiesPrepState = /\b(raw|cooked|steamed|roasted|sauteed|grilled|fresh raw|blanched)\b/.test(lower);
  if (mentionsVegetables && !clarifiesPrepState) {
    reasons.push('missing_prep_state_raw_vs_cooked');
  }

  return reasons;
}

function buildClarificationPrompt(reasons) {
  const questions = [];
  if (reasons.includes('missing_gluten_verification')) {
    questions.push('was the grain/pasta certified gluten-free or wheat-based');
  }
  if (reasons.includes('missing_dressing_or_sauce')) {
    questions.push('what dressing, oil, or sauce was used');
  }
  if (reasons.includes('missing_prep_state_raw_vs_cooked')) {
    questions.push('were the greens/vegetables eaten raw or cooked');
  }
  return `Quick check before logging this meal so your ingredient flags stay accurate: ${questions.join(', and ')}?`;
}

export class MockGeminiOrchestrator {
  evaluateGatekeeper({ rawText, referenceTimestamp, modality = 'text', barcodeGtin13 = null }) {
    const lower = rawText.toLowerCase();
    const eventTimestamp = parseRelativeTimeUtc(rawText, referenceTimestamp);

    if (modality === 'barcode' || barcodeGtin13) {
      return GatekeeperDecisionSchema.parse({
        status: 'COMPLETE',
        event_timestamp: eventTimestamp,
        event_category: 'FOOD',
        modality_detected: 'barcode',
        extracted_barcode: barcodeGtin13 || '0074312098765',
        ambiguity_reasons: [],
        followup_prompt: null
      });
    }

    if (/\b(bloat|bloated|distension|cramp|cramping|pressure|discomfort|stomach|fatigue|nausea)\b/.test(lower)) {
      return GatekeeperDecisionSchema.parse({
        status: 'COMPLETE',
        event_timestamp: eventTimestamp,
        event_category: 'SYMPTOM',
        modality_detected: modality,
        extracted_barcode: null,
        ambiguity_reasons: [],
        followup_prompt: null
      });
    }

    if (/\b(supplement|magnesium|probiotic|digestive enzyme|l-glutamine|capsule|chewable|electrolyte)\b/.test(lower)) {
      return GatekeeperDecisionSchema.parse({
        status: 'COMPLETE',
        event_timestamp: eventTimestamp,
        event_category: 'SUPPLEMENT',
        modality_detected: modality,
        extracted_barcode: null,
        ambiguity_reasons: [],
        followup_prompt: null
      });
    }

    if (/\b(slept|sleep|stress|stressed|restless)\b/.test(lower)) {
      return GatekeeperDecisionSchema.parse({
        status: 'COMPLETE',
        event_timestamp: eventTimestamp,
        event_category: 'CONTEXT',
        modality_detected: modality,
        extracted_barcode: null,
        ambiguity_reasons: [],
        followup_prompt: null
      });
    }

    const ambiguityReasons = detectAmbiguity(rawText);
    if (ambiguityReasons.length > 0) {
      return GatekeeperDecisionSchema.parse({
        status: 'NEEDS_CLARIFICATION',
        event_timestamp: eventTimestamp,
        event_category: 'FOOD',
        modality_detected: modality,
        extracted_barcode: null,
        ambiguity_reasons: ambiguityReasons,
        followup_prompt: buildClarificationPrompt(ambiguityReasons)
      });
    }

    return GatekeeperDecisionSchema.parse({
      status: 'COMPLETE',
      event_timestamp: eventTimestamp,
      event_category: 'FOOD',
      modality_detected: modality,
      extracted_barcode: null,
      ambiguity_reasons: [],
      followup_prompt: null
    });
  }

  extractStructuredDraft({ rawText, gatekeeperDecision }) {
    const lower = rawText.toLowerCase();
    const categoryMap = {
      FOOD: 'food',
      SYMPTOM: 'symptom',
      SUPPLEMENT: 'supplement',
      CONTEXT: 'context'
    };
    const category = categoryMap[gatekeeperDecision.event_category];

    if (category === 'symptom') {
      const scoreMatch = rawText.match(/\b([1-9]|10)\s*(?:\/\s*10|out of 10)?\b/);
      let score = scoreMatch ? Math.min(10, Math.max(1, parseInt(scoreMatch[1], 10))) : 6;
      if (/\b(severe|intense|sharp|heavy)\b/.test(lower) && !scoreMatch) score = 8;
      if (/\b(mild|slight)\b/.test(lower) && !scoreMatch) score = 3;

      const presentation = /\b(visible|balloon|distension|swollen)\b/.test(lower)
        ? 'visible_distension'
        : /\b(pressure|tight|knot)\b/.test(lower)
          ? 'internal_pressure'
          : 'unspecified';

      const symptomType = /\b(cramp|cramping)\b/.test(lower)
        ? 'cramping'
        : /\b(pressure|knot)\b/.test(lower)
          ? 'abdominal_pressure'
          : /\b(fatigue|tired)\b/.test(lower)
            ? 'fatigue'
            : 'gi_distension';

      return {
        category,
        symptom_metadata: {
          symptom_type: symptomType,
          discomfort_score: score,
          presentation,
          onset_window_estimate: /\b(after dinner|hours after|evening)\b/.test(lower) ? 'delayed_3_8h' : 'unknown'
        }
      };
    }

    if (category === 'supplement') {
      const formulation = /\bchewable\b/.test(lower)
        ? 'chewable'
        : /\bliquid\b/.test(lower)
          ? 'liquid'
          : /\bpowder\b/.test(lower)
            ? 'powder'
            : 'capsule';
      const name = /\bmagnesium\b/.test(lower)
        ? 'Magnesium Glycinate'
        : /\bdigestive enzyme\b/.test(lower)
          ? 'Broad-Spectrum Digestive Enzymes'
          : /\bl-glutamine\b/.test(lower)
            ? 'L-Glutamine Powder'
            : 'Daily Microbiome Support Supplement';
      return {
        category,
        supplement_metadata: {
          supplement_name: name,
          formulation,
          dosage_label: '1 serving'
        }
      };
    }

    if (category === 'context') {
      const numMatch = rawText.match(/\b([1-9]|10)\b/);
      const val = numMatch ? parseInt(numMatch[1], 10) : 5;
      const isSleep = /\b(sleep|slept|restless)\b/.test(lower);
      return {
        category,
        context_metadata: {
          sleep_quality_score: isSleep ? val : undefined,
          stress_score: !isSleep ? val : undefined,
          notes: rawText
        }
      };
    }

    const prepState = /\braw\b/.test(lower)
      ? 'raw'
      : /\b(cooked|steamed|roasted|grilled|sauteed)\b/.test(lower)
        ? 'cooked'
        : /\b(shake|latte|coffee|drink)\b/.test(lower)
          ? 'beverage'
          : /\b(bar|packaged)\b/.test(lower)
            ? 'packaged'
            : 'unknown';

    const glutenFreeVerified = /\b(gluten[- ]free|\bgf\b|brown rice|salmon|jasmine rice)\b/.test(lower) &&
      !/\b(wheat|semolina|regular pasta|croutons)\b/.test(lower);

    return {
      category: 'food',
      search_query: rawText,
      food_draft: {
        prep_state: prepState,
        gluten_free_verified: glutenFreeVerified
      }
    };
  }
}

export class MockNutritionCatalogAdapter {
  lookupByBarcode(barcodeGtin13) {
    const found = SYNTHETIC_NUTRITION_CATALOG.find((item) => item.barcode === barcodeGtin13);
    return found || SYNTHETIC_NUTRITION_CATALOG[2];
  }

  lookupByNaturalLanguage(queryText) {
    const lower = queryText.toLowerCase();

    const explicitIngredients = [];
    const knownTokens = [
      'maltitol',
      'sorbitol',
      'lactitol',
      'xylitol',
      'erythritol',
      'xanthan gum',
      'guar gum',
      'carrageenan',
      'soy lecithin',
      'canola oil',
      'sunflower oil',
      'garlic',
      'onion',
      'natural flavors',
      'olive oil',
      'lemon'
    ];
    for (const token of knownTokens) {
      if (lower.includes(token)) {
        explicitIngredients.push(token.replace(/\b\w/g, (c) => c.toUpperCase()));
      }
    }

    let bestMatch = null;
    let bestScore = 0;
    for (const entry of SYNTHETIC_NUTRITION_CATALOG) {
      let score = 0;
      for (const term of entry.matchTerms) {
        if (lower.includes(term)) score += 2;
      }
      if (score > bestScore) {
        bestScore = score;
        bestMatch = entry;
      }
    }

    if (bestMatch) {
      const mergedIngredients = Array.from(new Set([...bestMatch.ingredients, ...explicitIngredients]));
      return {
        ...bestMatch,
        ingredients: mergedIngredients
      };
    }

    return {
      resolved_food_name: 'Custom Logged Meal',
      default_prep_state: 'cooked',
      gluten_free_verified: /\b(gluten[- ]free|\bgf\b)\b/.test(lower),
      dairy_free_verified: !/\b(cheese|cream|milk|whey|lactitol)\b/.test(lower),
      ingredients: explicitIngredients.length > 0 ? explicitIngredients : ['Whole Food Base', 'Olive Oil', 'Sea Salt'],
      macros: { calories: 350, protein_g: 18, carbs_g: 32, fat_g: 14 }
    };
  }
}

/**
 * Documented interface boundary for academic literature retrieval.
 * Intentionally non-executing in the public offline showcase so mocked
 * responses are never mistaken for live biomedical evidence synthesis.
 */
export class LiteratureSynthesisInterface {
  static describeContract() {
    return {
      component: 'LiteratureSynthesisInterface',
      status: 'INTERFACE_DOCUMENTED_ONLY',
      external_provider_in_private_system: 'Semantic Scholar Academic Graph API v1 (/graph/v1/paper/search)',
      input_contract: {
        dietary_tags: 'string[] (e.g., ["HIGH_FODMAP_POLYOL", "HYDROCOLLOID_GUM"])',
        mesh_boolean_query: 'string (e.g., "\"Sugar Alcohols\" AND \"Gastrointestinal Transit\"")'
      },
      output_contract: {
        searchQuery: 'string',
        papers: 'Array<{ paperId: string, title: string, year: number, influentialCitationCount: number, url: string }>',
        pathway_summaries: 'Array<{ category: string, summary: string }>'
      },
      public_demo_policy:
        'Disabled in offline demo mode to avoid presenting simulated citations or unverified clinical literature claims.'
    };
  }

  async executeLiveSearch() {
    throw new Error(
      'OfflineDemoBoundaryError: Live Semantic Scholar execution is disabled in the sanitized public demo. Inspect LiteratureSynthesisInterface.describeContract() for the integration specification.'
    );
  }
}
