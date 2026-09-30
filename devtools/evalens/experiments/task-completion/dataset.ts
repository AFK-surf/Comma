import { z } from "zod";
import {
  DatasetItem,
  defineDatasetLoader,
  type LoadedDatasetItem,
} from "@evalens/core";

export const TaskDatasetItem = DatasetItem.extend({
  input: z
    .object({
      task: z.string(),
      provenance: z
        .object({
          source: z.literal("willow-staging-real-messages"),
          willowCandidateId: z.string(),
          willowAgentId: z.string(),
          willowSessionId: z.string(),
        })
        .strict(),
    })
    .strict(),
  expected: z
    .object({
      successCriteria: z.array(z.string()),
      expectedArtifacts: z.array(z.string()).optional(),
      validators: z.array(z.string()),
    })
    .strict(),
});
export type TaskDatasetItem = LoadedDatasetItem<typeof TaskDatasetItem>;

export const loadTaskCompletionDataset = defineDatasetLoader({
  name: "task-completion",
  digest: "2d527a5989a45d6dcfc2c4d1fab587ef78887bb1a637b11d0b4904dbc65bd201",
  itemSchema: TaskDatasetItem,
});
