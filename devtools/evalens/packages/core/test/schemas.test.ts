import { describe, expect, test } from "bun:test";

import {
  aggregateMetricIdentityKey,
  metricIdentityKey,
  parseAggregateMetricIdentityKey,
  parseMetricIdentityKey,
} from "@evalens/core/api";
import { EvalManifest } from "@evalens/core/evaluation";
import { RunManifest } from "@evalens/core/run";
import { ItemId } from "@evalens/core/schemas";

describe("lossless identities", () => {
  test("round-trips metric components containing NUL", () => {
    const metric = {
      evaluatorName: "judge\0one",
      evaluatorVersion: "v\0two",
      scoreKey: "score\0three",
    };
    const aggregate = {
      aggregatorVersion: "aggregate\0one",
      scoreKey: "score\0two",
    };

    expect(parseMetricIdentityKey(metricIdentityKey(metric))).toEqual(metric);
    expect(
      parseAggregateMetricIdentityKey(aggregateMetricIdentityKey(aggregate))
    ).toEqual(aggregate);
    expect(
      metricIdentityKey({
        evaluatorName: "judge",
        evaluatorVersion: "one\0v",
        scoreKey: "score",
      })
    ).not.toBe(
      metricIdentityKey({
        evaluatorName: "judge\0one",
        evaluatorVersion: "v",
        scoreKey: "score",
      })
    );
  });
});

describe("ItemId", () => {
  test("requires a portable lowercase ASCII path component", () => {
    for (const invalid of [
      "case\n",
      "case\ud800",
      "Case",
      "../case",
      ".hidden",
      "é",
      "e\u0301",
      "ß",
      "ς",
      "σ",
      "ſ",
      "ﬀ",
    ]) {
      expect(ItemId.safeParse(invalid).success).toBe(false);
    }
    expect(ItemId.safeParse("a".repeat(240)).success).toBe(true);
    expect(ItemId.safeParse("a".repeat(241)).success).toBe(false);
    expect(ItemId.safeParse("case-01.alpha_beta").success).toBe(true);
  });
});

describe("RunManifest", () => {
  test("requires an explicit dataset selection digest", () => {
    expect(
      RunManifest.safeParse({
        formatVersion: 2,
        runId: Bun.randomUUIDv7(),
        experimentName: "selection-digest",
        datasetName: "cases",
        datasetDigest: "dataset-digest",
        selectedItemIds: ["one"],
        targetItemCount: 1,
        createdAt: new Date(),
        status: "running",
        tags: [],
        params: {},
        paramsDigest: "params-digest",
        adapters: [],
      }).success
    ).toBe(false);
  });

  test("requires explicit adapter identities", () => {
    expect(
      RunManifest.safeParse({
        formatVersion: 2,
        runId: Bun.randomUUIDv7(),
        experimentName: "adapter-identities",
        datasetName: "cases",
        datasetDigest: "dataset-digest",
        datasetSelectionDigest: "dataset-selection-digest",
        selectedItemIds: ["one"],
        targetItemCount: 1,
        createdAt: new Date(),
        status: "running",
        tags: [],
        params: {},
        paramsDigest: "params-digest",
      }).success
    ).toBe(false);
  });

  test("requires an explicit target item count", () => {
    expect(
      RunManifest.safeParse({
        formatVersion: 2,
        runId: Bun.randomUUIDv7(),
        experimentName: "target-count",
        datasetName: "cases",
        datasetDigest: "dataset-digest",
        datasetSelectionDigest: "dataset-selection-digest",
        selectedItemIds: ["one"],
        createdAt: new Date(),
        status: "running",
        tags: [],
        params: {},
        paramsDigest: "params-digest",
        adapters: [],
      }).success
    ).toBe(false);
  });

  test("requires a positive target item count", () => {
    expect(
      RunManifest.safeParse({
        formatVersion: 2,
        runId: Bun.randomUUIDv7(),
        experimentName: "target-count",
        datasetName: "cases",
        datasetDigest: "dataset-digest",
        datasetSelectionDigest: "dataset-selection-digest",
        selectedItemIds: ["one"],
        targetItemCount: 0,
        createdAt: new Date(),
        status: "running",
        tags: [],
        params: {},
        paramsDigest: "params-digest",
        adapters: [],
      }).success
    ).toBe(false);
  });

  test("requires selected item ids to be unique and match the target count", () => {
    const manifest = {
      formatVersion: 2,
      runId: Bun.randomUUIDv7(),
      experimentName: "selection",
      datasetName: "cases",
      datasetDigest: "dataset-digest",
      datasetSelectionDigest: "dataset-selection-digest",
      selectedItemIds: ["one", "one"],
      targetItemCount: 1,
      createdAt: new Date(),
      status: "running",
      tags: [],
      params: {},
      paramsDigest: "params-digest",
      adapters: [],
    };
    expect(RunManifest.safeParse(manifest).success).toBe(false);
    expect(
      RunManifest.safeParse({
        ...manifest,
        selectedItemIds: ["one", "two"],
      }).success
    ).toBe(false);
  });
});

describe("EvalManifest", () => {
  test("requires explicit adapter identities", () => {
    expect(
      EvalManifest.safeParse({
        formatVersion: 1,
        evalId: Bun.randomUUIDv7(),
        runId: Bun.randomUUIDv7(),
        evaluators: [{ name: "judge", version: "1" }],
        aggregatorVersion: "1",
        paramsDigest: "params-digest",
        createdAt: new Date(),
        status: "running",
        params: {},
      }).success
    ).toBe(false);
  });
});
