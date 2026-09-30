import {
  DatasetItem,
  defineDatasetLoader,
  type DatasetItemArchive,
  type LoadedDatasetItem,
} from "@evalens/core";
import { z } from "zod";

import { TEAM_BENCH_SOURCE_REVISION, TEAM_BENCH_SOURCE_URL } from "./contracts";

export const TEAM_BENCH_NATIVE_DATASET_NAME = "teambench-native-leaderboard90-seed0-v1";

export const TeamBenchDatasetItem = DatasetItem.extend({
  input: z
    .object({
      taskId: z.string().min(1),
      seed: z.number().int().nonnegative(),
      category: z.string().min(1),
      refinedCategory: z.string().min(1),
      difficulty: z.string().min(1),
      source: z
        .object({
          repository: z.literal(TEAM_BENCH_SOURCE_URL),
          revision: z.literal(TEAM_BENCH_SOURCE_REVISION),
          subset: z.literal("leaderboard-90"),
        })
        .strict(),
      paths: z
        .object({
          spec: z.literal("agent/spec.md"),
          brief: z.literal("agent/brief.md"),
          taskAssets: z.literal("agent/task"),
          workspace: z.literal("agent/workspace"),
          graderTask: z.string().min(1),
          expected: z.literal("grader/reports/expected.json").optional(),
        })
        .strict(),
    })
    .strict(),
  expected: z
    .object({
      grader: z.literal("teambench-grade-sh-v1"),
      scorePath: z.literal("grader/reports/score.json"),
      attestationFailureModes: z.array(z.string().min(1)),
    })
    .strict(),
});

export type TeamBenchDatasetItem = LoadedDatasetItem<typeof TeamBenchDatasetItem>;

// Updated by build-dataset.ts + `evalens cli dataset pack`.
export const TEAM_BENCH_NATIVE_DATASET_DIGEST =
  "e359f00558442fd445a3d58df8e18c9f772646c6aef822fcee83d71dc7ba4b49";

export const loadTeamBenchNativeDataset = defineDatasetLoader({
  name: TEAM_BENCH_NATIVE_DATASET_NAME,
  digest: TEAM_BENCH_NATIVE_DATASET_DIGEST,
  itemSchema: TeamBenchDatasetItem,
});

export function requireTeamBenchArchive(
  item: TeamBenchDatasetItem
): DatasetItemArchive {
  if (!item.archive) {
    throw new Error(`TeamBench dataset item archive is missing: ${item.id}`);
  }
  return item.archive;
}
