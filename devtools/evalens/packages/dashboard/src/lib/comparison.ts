import type { EvalCatalogEntry, EvalComparison, RunItemSummary } from "../data/types";
import { metricIdentityKey, type MetricIdentity } from "@evalens/core/api";

export type { MetricIdentity } from "@evalens/core/api";

export type Compatibility = {
  compatible: boolean;
  aggregateKeys: string[];
  itemMetrics: MetricIdentity[];
  sharedItemCount: number;
  reasons: CompatibilityReason[];
};

export type CompatibilityReason = {
  code:
    | "no-selection"
    | "dataset-identity"
    | "aggregator-version"
    | "aggregate-score-key"
    | "item-identity"
    | "evaluator-score-identity";
};

export function analyzeCompatibility(comparison: EvalComparison): Compatibility {
  const evaluations = comparison.evaluations;
  if (evaluations.length === 0) {
    return {
      compatible: false,
      aggregateKeys: [],
      itemMetrics: [],
      sharedItemCount: 0,
      reasons: [{ code: "no-selection" }],
    };
  }

  const sameDataset = allEqual(
    evaluations.map(({ run }) =>
      JSON.stringify([run.datasetName, run.datasetSelectionDigest])
    )
  );
  const sameAggregator = allEqual(
    evaluations.map(({ aggregatorVersion }) => aggregatorVersion)
  );
  const aggregateKeys =
    sameDataset && sameAggregator
      ? intersection(
          evaluations.map(({ aggregateScores }) => Object.keys(aggregateScores))
        )
      : [];
  const globalItemMetricKeys = new Set(
    sameDataset ? commonScoreIdentityKeys(evaluations) : []
  );
  const itemMetrics = sameDataset
    ? comparison.itemMetrics.filter((metric) =>
        globalItemMetricKeys.has(metricIdentityKey(metric))
      )
    : [];
  const reasons: CompatibilityReason[] = [];
  if (!sameDataset) reasons.push({ code: "dataset-identity" });
  if (!sameAggregator) reasons.push({ code: "aggregator-version" });
  if (sameDataset && sameAggregator && aggregateKeys.length === 0) {
    reasons.push({ code: "aggregate-score-key" });
  }
  if (comparison.sharedItemCount === 0) reasons.push({ code: "item-identity" });
  if (globalItemMetricKeys.size === 0) {
    reasons.push({ code: "evaluator-score-identity" });
  }
  return {
    compatible:
      sameDataset &&
      (aggregateKeys.length > 0 ||
        (comparison.sharedItemCount > 0 && globalItemMetricKeys.size > 0)),
    aggregateKeys,
    itemMetrics,
    sharedItemCount: comparison.sharedItemCount,
    reasons,
  };
}

export function analyzeCatalogCompatibility(
  evaluations: EvalCatalogEntry[]
): Pick<Compatibility, "compatible" | "reasons"> {
  if (evaluations.length === 0) {
    return { compatible: false, reasons: [{ code: "no-selection" }] };
  }
  const sameDataset = allEqual(
    evaluations.map(({ run }) =>
      JSON.stringify([run.datasetName, run.datasetSelectionDigest])
    )
  );
  const sameAggregator = allEqual(
    evaluations.map(({ aggregatorVersion }) => aggregatorVersion)
  );
  const aggregateKeys =
    sameDataset && sameAggregator
      ? intersection(
          evaluations.map(({ aggregateScores }) => Object.keys(aggregateScores))
        )
      : [];
  const commonScoreIdentities = sameDataset ? commonScoreIdentityKeys(evaluations) : [];
  const reasons: CompatibilityReason[] = [];
  if (!sameDataset) reasons.push({ code: "dataset-identity" });
  if (!sameAggregator) reasons.push({ code: "aggregator-version" });
  if (sameDataset && sameAggregator && aggregateKeys.length === 0) {
    reasons.push({ code: "aggregate-score-key" });
  }
  if (!sameDataset || commonScoreIdentities.length === 0) {
    reasons.push({ code: "item-identity" });
  }
  if (commonScoreIdentities.length === 0) {
    reasons.push({ code: "evaluator-score-identity" });
  }
  return {
    compatible: aggregateKeys.length > 0 || commonScoreIdentities.length > 0,
    reasons,
  };
}

function commonScoreIdentityKeys(evaluations: EvalCatalogEntry[]): string[] {
  return intersection(
    evaluations.map(({ scoreIdentities }) =>
      scoreIdentities.map((identity) => metricIdentityKey(identity))
    )
  );
}

export function metricId(metric: MetricIdentity): string {
  return metricIdentityKey(metric);
}

export function scoreFor(
  item: RunItemSummary,
  metric: MetricIdentity
): number | undefined {
  return item.evaluatorResults.find(
    ({ evaluatorName, evaluatorVersion }) =>
      evaluatorName === metric.evaluatorName &&
      evaluatorVersion === metric.evaluatorVersion
  )?.scores[metric.scoreKey];
}

function intersection(values: string[][]): string[] {
  if (values.length === 0) return [];
  return [...new Set(values[0])]
    .filter((value) => values.every((candidate) => candidate.includes(value)))
    .sort();
}

function allEqual(values: string[]): boolean {
  return values.every((value) => value === values[0]);
}
