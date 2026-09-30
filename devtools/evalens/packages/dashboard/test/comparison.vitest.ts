import { describe, expect, it } from "vitest";
import type { EvalComparison } from "../src/data/types";
import {
  analyzeCatalogCompatibility,
  analyzeCompatibility,
  metricId,
} from "../src/lib/comparison";
import { parseCompareSearch } from "../src/lib/url-state";
import { middleEllipsis } from "../src/lib/format";

const comparison: EvalComparison = {
  sharedItemCount: 1,
  itemPage: 1,
  itemPageSize: 100,
  itemMetrics: [
    {
      evaluatorName: "judge",
      evaluatorVersion: "2",
      scoreKey: "score",
    },
  ],
  evaluations: ["a", "b"].map((id) => ({
    id,
    status: "finished" as const,
    params: {},
    aggregatorVersion: "1",
    evaluators: [{ name: "judge", version: "2" }],
    scoreIdentities: [
      { evaluatorName: "judge", evaluatorVersion: "2", scoreKey: "score" },
    ],
    adapters: [],
    aggregateScores: { accuracy: id === "a" ? 0.5 : 0.75 },
    resultCounts: { target: 1, completed: 1, error: 0, skipped: 0 },
    createdAt: "2026-01-01T00:00:00.000Z",
    run: {
      id: `run-${id}`,
      experimentName: "basic",
      datasetName: "fixture",
      datasetDigest: "digest",
      datasetSelectionDigest: "selection",
      tags: [],
      params: {},
      createdAt: "2026-01-01T00:00:00.000Z",
    },
    items: [
      {
        id: "item-1",
        digest: "item-digest",
        status: "completed" as const,
        durationMs: 10,
        evaluatorResults: [
          {
            evaluatorName: "judge",
            evaluatorVersion: "2",
            status: "completed" as const,
            scores: { score: id === "a" ? 1 : 0 },
          },
        ],
      },
    ],
  })),
};

describe("comparison compatibility", () => {
  it("finds the strict common aggregate and item identities", () => {
    expect(analyzeCompatibility(comparison)).toMatchObject({
      compatible: true,
      aggregateKeys: ["accuracy"],
      itemMetrics: [
        { evaluatorName: "judge", evaluatorVersion: "2", scoreKey: "score" },
      ],
      sharedItemCount: 1,
    });
  });

  it("uses the shared item metric key", () => {
    expect(
      metricId({
        evaluatorName: "judge",
        evaluatorVersion: "2",
        scoreKey: "score",
      })
    ).toBe('["judge","2","score"]');
  });

  it("rejects a selection with no global metric intersection", () => {
    const incompatible = structuredClone(comparison);
    incompatible.evaluations[1]!.aggregatorVersion = "other";
    incompatible.evaluations[1]!.evaluators[0]!.version = "other";
    incompatible.evaluations[1]!.scoreIdentities = [
      { evaluatorName: "judge", evaluatorVersion: "other", scoreKey: "score" },
    ];
    incompatible.evaluations[1]!.items[0]!.evaluatorResults[0]!.evaluatorVersion =
      "other";
    incompatible.itemMetrics = [];
    expect(analyzeCompatibility(incompatible).compatible).toBe(false);
  });

  it("uses evaluator name, version, and score key for catalog compatibility", () => {
    const left = structuredClone(comparison.evaluations[0]!);
    const right = structuredClone(comparison.evaluations[1]!);
    left.aggregateScores = { left: 1 };
    right.aggregateScores = { right: 1 };
    left.scoreIdentities = [
      { evaluatorName: "judge", evaluatorVersion: "2", scoreKey: "left" },
    ];
    right.scoreIdentities = [
      { evaluatorName: "judge", evaluatorVersion: "2", scoreKey: "right" },
    ];

    expect(analyzeCatalogCompatibility([left, right])).toMatchObject({
      compatible: false,
      reasons: expect.arrayContaining([{ code: "evaluator-score-identity" }]),
    });
  });

  it("keeps global compatibility stable when a common score appears on a later page", () => {
    const firstPage = structuredClone(comparison);
    firstPage.itemMetrics = [];
    for (const evaluation of firstPage.evaluations) evaluation.items = [];
    const secondPage = structuredClone(comparison);
    secondPage.itemPage = 2;

    expect(analyzeCompatibility(firstPage)).toMatchObject({
      compatible: true,
      itemMetrics: [],
    });
    expect(analyzeCompatibility(secondPage)).toMatchObject({
      compatible: true,
      itemMetrics: [
        { evaluatorName: "judge", evaluatorVersion: "2", scoreKey: "score" },
      ],
    });
  });

  it("treats different selections of the same source dataset as incompatible", () => {
    const incompatible = structuredClone(comparison);
    incompatible.evaluations[1]!.run.datasetSelectionDigest = "other-selection";
    expect(analyzeCompatibility(incompatible)).toMatchObject({
      compatible: false,
      reasons: expect.arrayContaining([{ code: "dataset-identity" }]),
    });
  });
});

describe("middleEllipsis", () => {
  it("preserves both ends within a fixed single-line text budget", () => {
    const value = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const compact = middleEllipsis(value, 20);
    expect(compact).toHaveLength(20);
    expect(compact).toBe("0123456789…RSTUVWXYZ");
    expect(middleEllipsis("short", 20)).toBe("short");
  });
});

describe("compare URL state", () => {
  it("preserves order, removes duplicates, and validates the reference", () => {
    expect(parseCompareSearch({ eval: ["b", "a", "b"], reference: "a" })).toEqual({
      eval: ["b", "a"],
      itemPage: 1,
      catalogPage: 1,
      reference: "a",
    });
    expect(parseCompareSearch({ eval: "a", reference: "missing" })).toEqual({
      eval: ["a"],
      itemPage: 1,
      catalogPage: 1,
    });
    expect(
      parseCompareSearch({
        eval: Array.from({ length: 9 }, (_, index) => `eval-${index}`),
        reference: "eval-0",
      })
    ).toEqual({ eval: [], itemPage: 1, catalogPage: 1 });
  });
});
