import { defineExperiment } from "@evalens/core";

export default defineExperiment({
  name: "basic",
  description: "A self-contained Evalens example.",
  metadata: {
    tags: ["example"],
  },
  datasetLoader() {
    return {
      name: "basic-examples",
      items: [
        { id: "one", input: "hello", expected: "HELLO" },
        { id: "two", input: "evalens", expected: "EVALENS" },
      ],
    };
  },
  runItem(item) {
    return { result: item.input.toUpperCase(), trajectories: [] };
  },
  evaluators: [
    {
      name: "exact-match",
      version: "1",
      evaluate(item, output) {
        return {
          score: { exactMatch: output.result === item.expected ? 1 : 0 },
        };
      },
    },
  ],
  aggregator: {
    version: "1",
    aggregate({ "exact-match": results }) {
      return {
        exactMatch:
          results.reduce((total, result) => total + result.score.exactMatch, 0) /
          results.length,
      };
    },
  },
});
