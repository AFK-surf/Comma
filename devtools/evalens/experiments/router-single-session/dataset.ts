import { z } from "zod";

import {
  DatasetItem,
  defineDatasetLoader,
  type LoadedDatasetItem,
} from "@evalens/core";

const JsonObject = z.record(z.string(), z.json());

const AgentLongBenchOfficialMessage = z
  .object({
    role: z.string().min(1),
    content: z.json().optional(),
  })
  .catchall(z.json());

export const AgentLongBenchOfficialEpisode = z
  .object({
    id: z.string().min(1),
    question: z.string().min(1),
    messages: z.array(AgentLongBenchOfficialMessage).min(1),
  })
  .strict();

const RouterHistoryTurn = z
  .object({
    role: z.enum(["user", "assistant", "runtime", "summary", "tool"]),
    content: z.string(),
    sourceMessageId: z.string().optional(),
    createdAt: z.union([z.string(), z.number()]).optional(),
    metadata: JsonObject.optional(),
  })
  .strict();

export const RouterSingleSessionItem = DatasetItem.extend({
  input: z
    .object({
      currentHistory: z.array(RouterHistoryTurn).default([]),
      priorHistory: z.array(RouterHistoryTurn).default([]),
      probe: z.object({ message: z.string().min(1) }).strict(),
      officialEpisodes: z
        .object({
          current: AgentLongBenchOfficialEpisode,
          prior: AgentLongBenchOfficialEpisode,
        })
        .strict()
        .optional(),
      officialEpisodeArchive: z
        .object({
          format: z.literal("agentlongbench-official-episodes-v1"),
          currentPath: z.literal("current.json"),
          priorPath: z.literal("prior.json"),
          currentSha256: z.string().regex(/^[a-f0-9]{64}$/u),
          priorSha256: z.string().regex(/^[a-f0-9]{64}$/u),
        })
        .strict()
        .optional(),
      rawHistory: z
        .object({
          format: z.literal("longmemeval-v2-trajectory-json-v1"),
          currentTrajectoryIds: z.array(z.string().min(1)).min(1),
          priorTrajectoryIds: z.array(z.string().min(1)).min(1),
          trajectoriesSha256: z.string().regex(/^[a-f0-9]{64}$/u),
        })
        .strict()
        .optional(),
    })
    .strict()
    .superRefine((input, context) => {
      if (
        !input.rawHistory &&
        !input.officialEpisodes &&
        !input.officialEpisodeArchive &&
        (input.currentHistory.length === 0 || input.priorHistory.length === 0)
      ) {
        context.addIssue({
          code: "custom",
          message: "inline history requires non-empty currentHistory and priorHistory",
        });
      }
      const sourceRepresentations = [
        input.rawHistory,
        input.officialEpisodes,
        input.officialEpisodeArchive,
      ].filter(Boolean).length;
      if (sourceRepresentations > 1) {
        context.addIssue({
          code: "custom",
          message:
            "rawHistory, officialEpisodes, and officialEpisodeArchive are mutually exclusive",
        });
      }
    }),
  expected: z
    .object({
      match: z.enum([
        "normalized_exact",
        "normalized_name",
        "phrase_set",
        "phrase_set_ordered",
        "mc_choice",
        "mc_choice_set",
        "token_set_f1",
        "ordered_pair",
        "boolean",
        "number",
        "llm_abstention",
        "llm_gotchas",
      ]),
      answer: z.string().min(1),
      requiredClaims: z.array(z.string().min(1)).min(1),
      forbiddenClaims: z.array(z.string().min(1)).default([]),
    })
    .strict(),
  source: z
    .object({
      dataset: z.enum(["agentlongbench", "longmemeval-v2"]),
      revision: z.string().min(1),
      itemId: z.string().min(1),
      url: z.url(),
      evaluator: z.string().min(1),
      sourcePath: z.string().min(1).optional(),
    })
    .strict(),
  metadata: z
    .object({
      questionType: z.string().min(1),
      historyMode: z.string().min(1),
      knowledgeMode: z.string().min(1).optional(),
      responseMode: z.string().min(1).optional(),
      tokenLength: z.string().min(1).optional(),
      notes: z.string().optional(),
    })
    .strict(),
  schemaVersion: z.literal(1),
  kind: z.literal("salix.router_single_session_dataset_item"),
});

export type RouterSingleSessionItem = LoadedDatasetItem<typeof RouterSingleSessionItem>;

export const AgentLongBenchTier = z.enum(["32k", "256k", "1m"]);
export type AgentLongBenchTier = z.output<typeof AgentLongBenchTier>;

export const loadAgentLongBenchDataset = {
  "32k": defineDatasetLoader({
    name: "agentlongbench-32k-raw-v1",
    digest: "f74e2ed6657992da109fa8962d2feaa459a79f8ce90be7ca3b45fc7c3f316f9a",
    itemSchema: RouterSingleSessionItem,
  }),
  "256k": defineDatasetLoader({
    name: "agentlongbench-256k-raw-v1",
    digest: "671de0f2e7eb9257462ddd441a3048939ef1ac4863ebe96a3c385127a156f435",
    itemSchema: RouterSingleSessionItem,
  }),
  "1m": defineDatasetLoader({
    name: "agentlongbench-1m-raw-v1",
    digest: "bc232d39b5e669faac37f0047b40772f477c058c54fed6654aaaefa414b642ed",
    itemSchema: RouterSingleSessionItem,
  }),
} as const satisfies Record<
  AgentLongBenchTier,
  ReturnType<typeof defineDatasetLoader<typeof RouterSingleSessionItem>>
>;

export const loadLongMemEvalSingleSessionDataset = defineDatasetLoader({
  name: "longmemeval-v2-triple-branch-raw-v1",
  digest: "cd87d5f1d420bdcb749f5f8a70c4da56a85b03af6c753464eed6cd8dcbc54b69",
  itemSchema: RouterSingleSessionItem,
});
