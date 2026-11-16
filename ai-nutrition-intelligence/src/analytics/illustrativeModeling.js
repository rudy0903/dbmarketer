/**
 * Illustrative longitudinal modeling and baseline forecasting over synthetic Gold features.
 *
 * Analytical governance notes:
 * 1. Evaluates strictly on chronological train/validation splits (no random shuffling).
 * 2. Reports held-out permutation feature attribution alongside regularized risk ratios
 *    and 95% intervals to surface estimation uncertainty on small N-of-1 cohorts.
 * 3. Outputs predictive associations ONLY; never claims causal identification.
 */

export const MODEL_FEATURES = [
  { key: 'prior_polyol_24h', label: 'High-FODMAP Polyol Exposure (Prior 24h)' },
  { key: 'prior_gum_24h', label: 'Hydrocolloid Gum Exposure (Prior 24h)' },
  { key: 'prior_emulsifier_24h', label: 'Dietary Emulsifier Exposure (Prior 24h)' },
  { key: 'prior_fodmap_48h', label: 'Cumulative FODMAP Load (Prior 48h)' },
  { key: 'prior_elevated_stress_24h', label: 'Elevated Stress Context (Prior 24h)' },
  { key: 'prior_poor_sleep_24h', label: 'Poor Sleep Quality (Prior 24h)' },
  { key: 'prior_unverified_gluten_24h', label: 'Unverified Gluten Exposure (Prior 24h)' },
  { key: 'prior_supplement_24h', label: 'Digestive Supplement Logged (Prior 24h)' }
];

function sigmoid(z) {
  if (z > 30) return 1 - 1e-13;
  if (z < -30) return 1e-13;
  return 1 / (1 + Math.exp(-z));
}

function binaryLogLoss(yTrue, yProb) {
  let sum = 0;
  for (let i = 0; i < yTrue.length; i++) {
    const p = Math.min(1 - 1e-9, Math.max(1e-9, yProb[i]));
    sum += -(yTrue[i] * Math.log(p) + (1 - yTrue[i]) * Math.log(1 - p));
  }
  return yTrue.length > 0 ? sum / yTrue.length : 0;
}

function computeRocAuc(yTrue, yProb) {
  const positives = [];
  const negatives = [];
  for (let i = 0; i < yTrue.length; i++) {
    if (yTrue[i] === 1) positives.push(yProb[i]);
    else negatives.push(yProb[i]);
  }
  if (positives.length === 0 || negatives.length === 0) return 0.5;
  let concordant = 0;
  for (const p of positives) {
    for (const n of negatives) {
      if (p > n) concordant += 1;
      else if (p === n) concordant += 0.5;
    }
  }
  return concordant / (positives.length * negatives.length);
}

function pearsonCorrelation(xs, ys) {
  const n = xs.length;
  if (n < 2) return 0;
  const meanX = xs.reduce((a, b) => a + b, 0) / n;
  const meanY = ys.reduce((a, b) => a + b, 0) / n;
  let num = 0;
  let denX = 0;
  let denY = 0;
  for (let i = 0; i < n; i++) {
    const dx = xs[i] - meanX;
    const dy = ys[i] - meanY;
    num += dx * dy;
    denX += dx * dx;
    denY += dy * dy;
  }
  const denom = Math.sqrt(denX * denY);
  return denom === 0 ? 0 : num / denom;
}

/**
 * Fits a lightweight gradient-boosted decision stump ensemble (illustrative local
 * counterpart to BigQuery ML BOOSTED_TREE_CLASSIFIER) using chronological training rows.
 */
function trainBoostedStumps(trainRows, featureKeys, numRounds = 28, learningRate = 0.25) {
  const y = trainRows.map((r) => r.is_elevated_discomfort);
  const posRate = Math.min(0.95, Math.max(0.05, y.reduce((a, b) => a + b, 0) / Math.max(1, y.length)));
  const baseLogit = Math.log(posRate / (1 - posRate));
  const logits = new Array(trainRows.length).fill(baseLogit);
  const trees = [];

  for (let round = 0; round < numRounds; round++) {
    const residuals = y.map((yi, idx) => yi - sigmoid(logits[idx]));
    let bestStump = null;
    let bestLossReduction = -Infinity;

    for (const fKey of featureKeys) {
      const candidateThresholds = [0.5, 1.5, 2.5];
      for (const threshold of candidateThresholds) {
        let leftSum = 0;
        let leftCount = 0;
        let rightSum = 0;
        let rightCount = 0;

        for (let i = 0; i < trainRows.length; i++) {
          if (trainRows[i][fKey] >= threshold) {
            rightSum += residuals[i];
            rightCount++;
          } else {
            leftSum += residuals[i];
            leftCount++;
          }
        }

        if (leftCount < 2 || rightCount < 2) continue;

        // L2-regularized Newton-like leaf step (hessian ~ 0.2, lambda = 1.5)
        const leftVal = leftSum / (leftCount * 0.22 + 1.5);
        const rightVal = rightSum / (rightCount * 0.22 + 1.5);
        const gain = leftSum * leftVal + rightSum * rightVal;

        if (gain > bestLossReduction) {
          bestLossReduction = gain;
          bestStump = { feature: fKey, threshold, leftVal, rightVal };
        }
      }
    }

    if (!bestStump || bestLossReduction <= 1e-6) break;
    trees.push(bestStump);

    for (let i = 0; i < trainRows.length; i++) {
      const step = trainRows[i][bestStump.feature] >= bestStump.threshold ? bestStump.rightVal : bestStump.leftVal;
      logits[i] += learningRate * step;
    }
  }

  return {
    baseLogit,
    learningRate,
    trees,
    predictProba(rows) {
      return rows.map((row) => {
        let z = baseLogit;
        for (const t of trees) {
          z += learningRate * (row[t.feature] >= t.threshold ? t.rightVal : t.leftVal);
        }
        return sigmoid(z);
      });
    }
  };
}

function computeRiskRatioWithCI(rows, featureKey) {
  // Haldane-Anscombe +0.5 continuity correction for sparse longitudinal cells
  let exposedEvents = 0.5;
  let exposedTotal = 1.0;
  let unexposedEvents = 0.5;
  let unexposedTotal = 1.0;

  for (const r of rows) {
    const exposed = r[featureKey] >= 1;
    if (exposed) {
      exposedTotal += 1;
      if (r.is_elevated_discomfort === 1) exposedEvents += 1;
    } else {
      unexposedTotal += 1;
      if (r.is_elevated_discomfort === 1) unexposedEvents += 1;
    }
  }

  const pExposed = exposedEvents / exposedTotal;
  const pUnexposed = unexposedEvents / unexposedTotal;
  const riskRatio = pExposed / pUnexposed;

  const seLogRR = Math.sqrt(
    (1 - pExposed) / exposedEvents + (1 - pUnexposed) / unexposedEvents
  );
  const logRR = Math.log(riskRatio);
  const ciLow = Math.exp(logRR - 1.96 * seLogRR);
  const ciHigh = Math.exp(logRR + 1.96 * seLogRR);

  return {
    observational_risk_ratio: Number(riskRatio.toFixed(2)),
    ci95_low: Number(ciLow.toFixed(2)),
    ci95_high: Number(ciHigh.toFixed(2)),
    exposed_observations: Math.round(exposedTotal - 1),
    unexposed_observations: Math.round(unexposedTotal - 1)
  };
}

export function evaluateLongitudinalAnalytics(goldRows = [], targetTenantId = null) {
  const filtered = goldRows.filter(
    (r) =>
      r.category === 'symptom' &&
      r.is_elevated_discomfort !== null &&
      (!targetTenantId || r.tenant_id === targetTenantId)
  );

  const sortedOutcomes = [...filtered].sort((a, b) => a.event_epoch_sec - b.event_epoch_sec);
  const splitIdx = Math.max(1, Math.floor(sortedOutcomes.length * 0.75));
  const trainRows = sortedOutcomes.slice(0, splitIdx);
  const valRows = sortedOutcomes.slice(splitIdx);

  const featureKeys = MODEL_FEATURES.map((f) => f.key);
  const model = trainBoostedStumps(trainRows, featureKeys);

  const trainProbs = model.predictProba(trainRows);
  const valProbs = model.predictProba(valRows);

  const trainY = trainRows.map((r) => r.is_elevated_discomfort);
  const valY = valRows.map((r) => r.is_elevated_discomfort);

  const baseValLogLoss = binaryLogLoss(valY, valProbs);
  const valAuc = computeRocAuc(valY, valProbs);

  // Deterministic cyclic shift permutation importance on held-out chronological window
  const evalPool = valRows.length >= 6 ? valRows : sortedOutcomes;
  const evalY = evalPool.map((r) => r.is_elevated_discomfort);
  const baseEvalLoss = binaryLogLoss(evalY, model.predictProba(evalPool));

  const rawAttributions = MODEL_FEATURES.map((meta) => {
    let deltaLossSum = 0;
    const shifts = [1, 3, 5];
    for (const shift of shifts) {
      const permuted = evalPool.map((row, idx) => ({
        ...row,
        [meta.key]: evalPool[(idx + shift) % evalPool.length][meta.key]
      }));
      const permLoss = binaryLogLoss(evalY, model.predictProba(permuted));
      deltaLossSum += Math.max(0, permLoss - baseEvalLoss);
    }
    const meanDelta = deltaLossSum / shifts.length;
    const rrStats = computeRiskRatioWithCI(sortedOutcomes, meta.key);

    return {
      feature: meta.key,
      label: meta.label,
      permutation_attribution: Number(meanDelta.toFixed(4)),
      ...rrStats
    };
  });

  const totalAttr = rawAttributions.reduce((s, f) => s + f.permutation_attribution, 0) || 1;
  const normalizedAttributions = rawAttributions
    .map((f) => ({
      ...f,
      relative_attribution_share: Number((f.permutation_attribution / totalAttr).toFixed(3))
    }))
    .sort((a, b) => b.permutation_attribution - a.permutation_attribution);

  // Collinearity diagnostics across commonly co-occurring additive features
  const collinearityPairs = [];
  for (let i = 0; i < featureKeys.length; i++) {
    for (let j = i + 1; j < featureKeys.length; j++) {
      const r = pearsonCorrelation(
        sortedOutcomes.map((row) => row[featureKeys[i]]),
        sortedOutcomes.map((row) => row[featureKeys[j]])
      );
      if (Math.abs(r) >= 0.35) {
        collinearityPairs.push({
          feature_a: featureKeys[i],
          feature_b: featureKeys[j],
          pearson_r: Number(r.toFixed(2)),
          interpretation:
            'Co-occurring exposure in packaged foods; single-feature attributions share variance and cannot isolate independent biological effects.'
        });
      }
    }
  }

  // Daily maximum discomfort time-series & rolling 7-day baseline forecast (ARIMA_PLUS analogue)
  const dailyMap = new Map();
  const tenantAllRows = goldRows.filter((r) => !targetTenantId || r.tenant_id === targetTenantId);
  for (const r of tenantAllRows) {
    if (!dailyMap.has(r.event_date_utc)) {
      dailyMap.set(r.event_date_utc, {
        date: r.event_date_utc,
        daily_max_discomfort: null,
        polyol_exposures: 0,
        gum_exposures: 0,
        emulsifier_exposures: 0
      });
    }
    const bucket = dailyMap.get(r.event_date_utc);
    bucket.polyol_exposures += r.has_high_fodmap_polyol;
    bucket.gum_exposures += r.has_hydrocolloid_gum;
    bucket.emulsifier_exposures += r.has_emulsifier_irritant;
    if (r.discomfort_score !== null) {
      bucket.daily_max_discomfort =
        bucket.daily_max_discomfort === null
          ? r.discomfort_score
          : Math.max(bucket.daily_max_discomfort, r.discomfort_score);
    }
  }

  const dailySeries = Array.from(dailyMap.values()).sort((a, b) => a.date.localeCompare(b.date));
  const historyValues = [];

  const forecastSeries = dailySeries.map((day) => {
    const windowVals = historyValues.slice(-7);
    const baselineMean =
      windowVals.length > 0
        ? windowVals.reduce((a, b) => a + b, 0) / windowVals.length
        : 3.5;
    const variance =
      windowVals.length > 1
        ? windowVals.reduce((acc, v) => acc + (v - baselineMean) ** 2, 0) / (windowVals.length - 1)
        : 1.4;
    const stdDev = Math.max(0.85, Math.sqrt(variance));
    const upperBound = Math.min(10, baselineMean + 1.96 * stdDev);
    const lowerBound = Math.max(1, baselineMean - 1.96 * stdDev);

    const observed = day.daily_max_discomfort;
    const isAnomaly = observed !== null && observed > upperBound;

    if (observed !== null) {
      historyValues.push(observed);
    }

    return {
      ...day,
      expected_baseline: Number(baselineMean.toFixed(2)),
      upper_95_band: Number(upperBound.toFixed(2)),
      lower_95_band: Number(lowerBound.toFixed(2)),
      is_anomaly_spike: isAnomaly
    };
  });

  return {
    governance: {
      is_causal_inference: false,
      synthetic_data_only: true,
      split_strategy: 'chronological_75_25_no_shuffle',
      methodology_note:
        'Feature attributions and risk ratios measure observational predictive association within synthetic longitudinal logs. Confounding, co-ingredient collinearity, and self-selected logging prevent causal interpretation.'
    },
    sample_summary: {
      tenant_scope: targetTenantId || 'all_tenants',
      total_symptom_observations: sortedOutcomes.length,
      train_observations: trainRows.length,
      validation_observations: valRows.length,
      elevated_discomfort_prevalence: Number(
        (
          sortedOutcomes.filter((r) => r.is_elevated_discomfort === 1).length /
          Math.max(1, sortedOutcomes.length)
        ).toFixed(3)
      )
    },
    validation_metrics: {
      held_out_roc_auc: Number(valAuc.toFixed(3)),
      held_out_log_loss: Number(baseValLogLoss.toFixed(3)),
      train_log_loss: Number(binaryLogLoss(trainY, trainProbs).toFixed(3))
    },
    feature_attributions: normalizedAttributions,
    collinearity_diagnostics: collinearityPairs,
    daily_forecast_series: forecastSeries
  };
}
