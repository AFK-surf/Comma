import { describe, expect, test } from "bun:test";

import { type DatasetItem, defineExperiment } from "@evalens/core";

type TestItem = DatasetItem<{ value: string }, { value: string }>;

type EvaluationIdentityOptions = {
  evaluators?: { name: string; version: string }[];
  aggregatorVersion?: string;
};

function createExperiment(
  name: string,
  description?: string,
  options: EvaluationIdentityOptions = {}
) {
  const evaluatorIdentities = options.evaluators ?? [{ name: "value", version: "1" }];
  return defineExperiment({
    name,
    ...(description === undefined ? {} : { description }),
    metadata: { tags: [] },
    datasetLoader() {
      return {
        name: "experiment-name-dataset",
        items: [
          { id: "one", input: { value: "one" }, expected: { value: "one" } },
        ] satisfies TestItem[],
      };
    },
    runItem(item) {
      return { result: { value: item.input.value }, trajectories: [] };
    },
    evaluators: evaluatorIdentities.map(({ name: evaluatorName, version }) => ({
      name: evaluatorName,
      version,
      evaluate() {
        return { score: { value: 1 } };
      },
    })),
    aggregator: {
      version: options.aggregatorVersion ?? "1",
      aggregate() {
        return {};
      },
    },
  });
}

describe("defineExperiment", () => {
  test("accepts lowercase ASCII identity slugs", () => {
    for (const name of ["a", "0", "basic-example", "eval.v2_test", "a".repeat(128)]) {
      expect(() => createExperiment(name)).not.toThrow();
    }
  });

  test("rejects invalid experiment identity names", () => {
    for (const name of [
      "",
      ".",
      "..",
      "-leading",
      "_leading",
      "Uppercase",
      "has space",
      "has/slash",
      "évaluation",
      "a".repeat(129),
    ]) {
      expect(() => createExperiment(name)).toThrow();
    }
  });

  test("preserves an optional human-readable description", () => {
    const described = createExperiment("described", "Human-readable purpose.");
    const description: string | undefined = described.description;

    expect(description).toBe("Human-readable purpose.");
    expect(createExperiment("undescribed").description).toBeUndefined();
  });

  test("requires at least one evaluator", () => {
    expect(() =>
      createExperiment("no-evaluators", undefined, { evaluators: [] })
    ).toThrow("at least one evaluator");
  });

  test("validates evaluator and aggregator identity byte limits", () => {
    for (const invalid of ["", "a".repeat(129), "é".repeat(65)]) {
      expect(() =>
        createExperiment("invalid-evaluator-name", undefined, {
          evaluators: [{ name: invalid, version: "1" }],
        })
      ).toThrow();
      expect(() =>
        createExperiment("invalid-evaluator-version", undefined, {
          evaluators: [{ name: "value", version: invalid }],
        })
      ).toThrow();
      expect(() =>
        createExperiment("invalid-aggregator-version", undefined, {
          aggregatorVersion: invalid,
        })
      ).toThrow();
    }
  });

  test("keeps evaluator identities case-sensitive and unnormalized", () => {
    const experiment = createExperiment("identity-semantics", undefined, {
      evaluators: [
        { name: "Judge", version: " V1 " },
        { name: "judge", version: "v1" },
      ],
      aggregatorVersion: " Aggregate V1 ",
    });

    expect(
      experiment.evaluators.map(({ name, version }) => ({ name, version }))
    ).toEqual([
      { name: "Judge", version: " V1 " },
      { name: "judge", version: "v1" },
    ]);
    expect(experiment.aggregator.version).toBe(" Aggregate V1 ");
  });

  test("rejects duplicate adapter declarations within a phase", () => {
    expect(() =>
      defineExperiment({
        ...createExperiment("duplicate-adapters"),
        adapters: { run: ["salix", "salix"], eval: [] },
      } as never)
    ).toThrow("adapter names must be unique within each phase");
  });
});
