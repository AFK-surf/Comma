import { defineExperiment } from "@evalens/core";
import { loadBasicDataset } from "./basic.dataset";

export default defineExperiment({
  name: "basic-example",
  description: "A deterministic smoke experiment for the Evalens execution pipeline.",
  metadata: { tags: ["example", "deterministic"] },
  datasetLoader: loadBasicDataset,
  runItem: (item) => ({ result: { answer: item.input.answer }, trajectories: [] }),
  evaluators: [
    {
      name: "answer-match",
      version: "1",
      evaluate: (item, output) => {
        const matched = output.result.answer === item.expected.answer;
        return {
          score: { answerMatch: matched ? 1 : 0 },
          explanation: `actual=${output.result.answer}, expected=${item.expected.answer}`,
        };
      },
    },
  ],
  aggregator: {
    version: "1",
    aggregate: ({ "answer-match": results }) => ({
      answerMatch:
        results.reduce((total, result) => total + result.score.answerMatch, 0) /
        results.length,
    }),
  },
});
