/**
 * Deterministic ingredient and additive taxonomy rules grounded in publicly
 * documented FODMAP and food-additive classifications.
 */

const TAXONOMY_LEXICON = [
  {
    patterns: ['lactitol', 'e966'],
    isAdditive: true,
    tags: ['HIGH_FODMAP_POLYOL', 'DAIRY_DERIVED'],
    alert: 'Osmotic & Dairy Alert: Lactitol (E966) is lactose-derived and classified as a fermentable polyol.'
  },
  {
    patterns: ['sorbitol', 'e420', 'mannitol', 'e421', 'maltitol', 'e965'],
    isAdditive: true,
    tags: ['HIGH_FODMAP_POLYOL', 'GLUTEN_RISK'],
    alert: 'Osmotic Polyol & Starch Source Warning: Sorbitol/Mannitol/Maltitol increase luminal water draw; verify gluten-free starch sourcing if applicable.'
  },
  {
    patterns: ['xylitol', 'e967', 'isomalt', 'e953'],
    isAdditive: true,
    tags: ['HIGH_FODMAP_POLYOL'],
    alert: 'Osmotic Polyol Risk: Xylitol/Isomalt may contribute to osmotic fluid shifts (0.5-3h) and colonic fermentation (3-8h).'
  },
  {
    patterns: ['erythritol', 'glycerol'],
    isAdditive: true,
    tags: ['LOW_RISK_POLYOL'],
    alert: null
  },
  {
    patterns: ['xanthan gum', 'guar gum', 'locust bean gum', 'tara gum', 'inulin', 'chicory root'],
    isAdditive: true,
    tags: ['HYDROCOLLOID_GUM'],
    alert: 'Secondary Fermentation Flag: Hydrocolloid gums or chicory/inulin fibers can accelerate gas production.'
  },
  {
    patterns: ['carrageenan'],
    isAdditive: true,
    tags: ['EMULSIFIER_IRRITANT'],
    alert: 'Emulsifier Flag: Carrageenan detected; tracked as a high-priority dietary emulsifier.'
  },
  {
    patterns: ['polysorbate 80', 'carboxymethylcellulose', 'cellulose gum', 'soy lecithin', 'sunflower lecithin'],
    isAdditive: true,
    tags: ['EMULSIFIER_IRRITANT'],
    alert: 'Emulsifier Note: Processed emulsifier/lecithin present in ingredient list.'
  },
  {
    patterns: ['canola oil', 'soybean oil', 'sunflower oil', 'safflower oil', 'corn oil', 'cottonseed oil'],
    isAdditive: true,
    tags: ['SEED_OIL'],
    alert: null
  },
  {
    patterns: ['garlic', 'onion', 'shallot', 'wheat flour', 'barley malt', 'rye', 'cauliflower', 'honey', 'cashew'],
    isAdditive: false,
    tags: ['FERMENTABLE_OLIGOSACCHARIDE'],
    alert: 'Fermentable Carbohydrate Flag: High-fructan/GOS/fructose whole-food ingredient identified.'
  },
  {
    patterns: ['wheat', 'semolina', 'durum', 'barley', 'rye', 'malt extract'],
    isAdditive: false,
    tags: ['GLUTEN_RISK'],
    alert: 'Gluten Exposure Flag: Gluten-containing grain ingredient detected.'
  },
  {
    patterns: ['whey', 'casein', 'milk powder', 'heavy cream', 'buttermilk', 'lactose'],
    isAdditive: false,
    tags: ['DAIRY_DERIVED'],
    alert: 'Dairy Ingredient Flag: Milk protein or lactose source detected.'
  },
  {
    patterns: ['natural flavors', 'savory spices', 'dehydrated vegetables', 'vegetable broth', 'seasoning blend'],
    isAdditive: true,
    tags: ['HIDDEN_ALLIUM_RISK'],
    alert: 'Label Ambiguity Warning: Generic flavoring/broth terms in savory products may conceal onion or garlic.'
  }
];

export function auditIngredientList(rawIngredients = [], options = {}) {
  const { glutenFreeVerified = false, formulation = null } = options;
  const alerts = new Set();

  const annotatedIngredients = rawIngredients.map((rawName) => {
    const normalized = String(rawName).trim().toLowerCase();
    const matchedTags = new Set();
    let isAdditive = false;

    for (const rule of TAXONOMY_LEXICON) {
      const hit = rule.patterns.some((p) => normalized.includes(p));
      if (hit) {
        if (rule.isAdditive) isAdditive = true;
        for (const tag of rule.tags) {
          if (tag === 'GLUTEN_RISK' && glutenFreeVerified && !normalized.includes('wheat') && !normalized.includes('barley')) {
            continue;
          }
          matchedTags.add(tag);
        }
        if (rule.alert) {
          if (rule.tags.includes('GLUTEN_RISK') && glutenFreeVerified && !normalized.includes('wheat')) {
            alerts.add('Osmotic Polyol Risk: Sugar alcohol detected in certified gluten-free product.');
          } else {
            alerts.add(rule.alert);
          }
        }
      }
    }

    return {
      name: String(rawName).trim(),
      is_additive_or_filler: isAdditive,
      tags: Array.from(matchedTags)
    };
  });

  if (formulation && ['liquid', 'chewable'].includes(formulation)) {
    alerts.add(
      'Excipient Advisory: Liquid and chewable supplement formulations frequently use sorbitol or mannitol sweeteners; verify inactive ingredients.'
    );
  }

  return {
    ingredients: annotatedIngredients,
    system_alerts: Array.from(alerts)
  };
}
