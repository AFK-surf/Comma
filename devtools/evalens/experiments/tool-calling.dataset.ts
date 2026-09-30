import { z } from "zod";
import {
  DatasetItem,
  defineDatasetLoader,
  type LoadedDatasetItem,
} from "@evalens/core";

const ToolExpectation = z
  .object({
    toolName: z.string(),
    input: z
      .object({
        includes: z.array(z.string()).optional(),
        excludes: z.array(z.string()).optional(),
      })
      .strict()
      .optional(),
    status: z.string().optional(),
    minCount: z.number().int().positive().optional(),
  })
  .strict();

export const ToolCallingDatasetItem = DatasetItem.extend({
  input: z
    .object({
      category: z.string(),
      targetAgentRole: z.enum(["router", "worker"]),
      task: z.string(),
      context: z.string().optional(),
    })
    .strict(),
  expected: z
    .object({
      requiredToolCalls: z.array(ToolExpectation),
      forbiddenToolCalls: z.array(ToolExpectation).optional(),
      expectedArtifacts: z.array(
        z.object({ kind: z.string(), description: z.string() }).strict()
      ),
      successCriteria: z.array(z.string()),
    })
    .strict(),
});
export type ToolCallingDatasetItem = LoadedDatasetItem<typeof ToolCallingDatasetItem>;

export const loadToolCallingDataset = defineDatasetLoader({
  name: "tool-calling",
  digest: "5052904ff1cb4933cad770ff2e4870eca40738638734e4368eaf2f03232ead60",
  itemSchema: ToolCallingDatasetItem,
});
