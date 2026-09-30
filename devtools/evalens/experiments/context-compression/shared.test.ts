import { describe, expect, test } from "bun:test";
import { defineSalixContextCompressionExperiment } from "./shared";

describe("context compression evaluation", () => {
  test("runs with Salix and judges semantic retention with Codex", () => {
    const experiment = defineSalixContextCompressionExperiment({
      name: "context-compression-test",
      variant: "summary",
    });

    expect(experiment.adapters).toEqual({ run: ["salix"], eval: ["codex"] });
    expect(
      experiment.evaluators.map(({ name, version }) => ({ name, version }))
    ).toEqual([{ name: "retained-facts", version: "3" }]);
  });
});
