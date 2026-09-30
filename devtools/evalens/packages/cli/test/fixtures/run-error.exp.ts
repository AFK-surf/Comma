import { defineExperiment } from "@evalens/core";

export default defineExperiment({
  name: "cli-run-error",
  metadata: { tags: ["test"] },
  datasetLoader() {
    return {
      name: "cli-run-error-dataset",
      items: [{ id: "error", input: {}, expected: {} }],
    };
  },
  runItem() {
    throw new Error("fixture run failure");
  },
  evaluators: [
    {
      name: "noop",
      version: "1",
      evaluate() {
        return { score: { noop: 1 } };
      },
    },
  ],
  aggregator: {
    version: "1",
    aggregate() {
      return {};
    },
  },
});
