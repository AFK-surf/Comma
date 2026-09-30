import { mkdir, rename, rm } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";

import { DatasetName } from "@evalens/core";

import type { EvalensConfig } from "./config";
import {
  redact,
  SalixDatasetItem,
  SalixTrajectoryPage,
  toDatasetItem,
} from "./salix-dataset-item";

const Filters = z
  .object({
    groupId: z.string().nullable(),
    minSeverity: z.number().min(0).max(1),
  })
  .strict();

const SyncState = z
  .object({
    schemaVersion: z.literal(1),
    source: z.literal("salix-l2"),
    cursor: z.string().min(1),
    filters: Filters,
  })
  .strict();

const Dataset = z
  .object({
    name: DatasetName,
    description: z.string().optional(),
    items: z.array(SalixDatasetItem),
  })
  .strict();

type Filters = z.infer<typeof Filters>;
type SyncState = z.infer<typeof SyncState>;
type Dataset = z.infer<typeof Dataset>;

export type SalixDatasetSyncOptions = {
  name: string;
  config: EvalensConfig;
  configDir: string;
  apply: boolean;
  evaluatedFrom?: string;
  bootstrapNow?: boolean;
  resetCursor?: boolean;
  groupId?: string;
  minSeverity?: number;
  limit?: number;
  fetch?: typeof globalThis.fetch;
};

export type SalixDatasetSyncSummary = {
  listed: number;
  added: number;
  unchanged: number;
  rejected: number;
  hasMore: boolean;
  cursorAdvanced: boolean;
  dryRun: boolean;
};

export async function syncSalixL2Dataset(
  options: SalixDatasetSyncOptions
): Promise<SalixDatasetSyncSummary> {
  validateOptions(options);

  const name = DatasetName.parse(options.name);
  const paths = {
    dataset: path.join(options.configDir, "datasets", name, "dataset.json"),
    state: path.join(options.configDir, ".evalens", "sync", name, "salix-l2.json"),
    lock: path.join(options.configDir, ".evalens", "locks", `${name}.lock`),
  };

  const sync = () => syncPage(options, name, paths);
  return options.apply ? withLock(paths.lock, sync) : sync();
}

async function syncPage(
  options: SalixDatasetSyncOptions,
  name: string,
  paths: { dataset: string; state: string; lock: string }
): Promise<SalixDatasetSyncSummary> {
  const state = options.resetCursor ? undefined : await readState(paths.state);
  const filters = resumeFilters(options, state);
  const dataset = await readDataset(paths.dataset, name);
  const page = await fetchPage(options, state?.cursor, filters);
  const knownIds = new Set(dataset.items.map((item) => item.id));

  let unchanged = 0;
  let rejected = 0;
  const additions: SalixDatasetItem[] = [];
  for (const result of page.items) {
    const item = toDatasetItem(result);
    if (!item) {
      rejected += 1;
    } else if (knownIds.has(item.id)) {
      unchanged += 1;
    } else {
      knownIds.add(item.id);
      additions.push(item);
    }
  }

  if (options.apply) {
    await atomicWrite(paths.dataset, {
      ...dataset,
      items: [...dataset.items, ...additions],
    });
    await atomicWrite(paths.state, {
      schemaVersion: 1,
      source: "salix-l2",
      cursor: page.next_cursor,
      filters,
    } satisfies SyncState);
  }

  return {
    listed: page.items.length,
    added: additions.length,
    unchanged,
    rejected,
    hasMore: page.has_more,
    cursorAdvanced: options.apply,
    dryRun: !options.apply,
  };
}

function validateOptions(options: SalixDatasetSyncOptions) {
  const limit = options.limit ?? 50;
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
    throw new Error("limit must be an integer between 1 and 100");
  }
  if (options.evaluatedFrom && options.bootstrapNow) {
    throw new Error("--evaluated-from and --bootstrap-now are mutually exclusive");
  }
  const salix = options.config.adapters?.salix;
  if (!salix?.token) {
    throw new Error("adapters.salix with token is required for dataset sync");
  }
}

function resumeFilters(
  options: SalixDatasetSyncOptions,
  state: SyncState | undefined
): Filters {
  if (!state) {
    if (!options.evaluatedFrom && !options.bootstrapNow) {
      throw new Error("first sync requires --evaluated-from or --bootstrap-now");
    }
    return {
      groupId: options.groupId ?? null,
      minSeverity: options.minSeverity ?? 0.5,
    };
  }

  if (options.evaluatedFrom || options.bootstrapNow) {
    throw new Error("resume cannot include a new bootstrap boundary");
  }
  if (
    (options.groupId !== undefined && options.groupId !== state.filters.groupId) ||
    (options.minSeverity !== undefined &&
      options.minSeverity !== state.filters.minSeverity)
  ) {
    throw new Error("sync filters changed; use --reset-cursor with a new boundary");
  }
  return state.filters;
}

async function fetchPage(
  options: SalixDatasetSyncOptions,
  cursor: string | undefined,
  filters: Filters
) {
  const salix = options.config.adapters!.salix!;
  const url = new URL("/v1/runtime/eval/trajectory-results", salix.baseUrl);
  url.searchParams.set("limit", String(options.limit ?? 50));
  if (cursor) {
    url.searchParams.set("cursor", cursor);
  } else {
    if (options.bootstrapNow) {
      url.searchParams.set("bootstrap", "now");
    } else {
      url.searchParams.set("evaluated_from", options.evaluatedFrom!);
    }
    url.searchParams.set("min_severity", String(filters.minSeverity));
    if (filters.groupId) url.searchParams.set("group_id", filters.groupId);
  }

  const response = await (options.fetch ?? globalThis.fetch)(url, {
    headers: {
      authorization: `Bearer ${salix.token}`,
      accept: "application/json",
    },
  });
  const body: unknown = await response.json().catch(() => null);
  if (!response.ok) {
    throw new Error(
      `Salix trajectory request failed (${response.status}): ${JSON.stringify(redact(body))}`
    );
  }
  return SalixTrajectoryPage.parse(body);
}

async function readDataset(filePath: string, name: string): Promise<Dataset> {
  const file = Bun.file(filePath);
  if (!(await file.exists())) {
    return {
      name,
      description: "L2-confirmed Salix session trajectory regressions.",
      items: [],
    };
  }
  const dataset = Dataset.parse(await file.json());
  if (dataset.name !== name) {
    throw new Error(`dataset manifest name ${dataset.name} does not match ${name}`);
  }
  return dataset;
}

async function readState(filePath: string): Promise<SyncState | undefined> {
  const file = Bun.file(filePath);
  return (await file.exists()) ? SyncState.parse(await file.json()) : undefined;
}

async function withLock<T>(filePath: string, run: () => Promise<T>): Promise<T> {
  await mkdir(path.dirname(filePath), { recursive: true });
  try {
    await mkdir(filePath);
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "EEXIST") {
      throw new Error(`dataset sync is locked: ${filePath}`);
    }
    throw error;
  }

  try {
    return await run();
  } finally {
    await rm(filePath, { recursive: true, force: true });
  }
}

async function atomicWrite(filePath: string, value: unknown) {
  await mkdir(path.dirname(filePath), { recursive: true });
  const temporary = `${filePath}.tmp-${Bun.randomUUIDv7()}`;
  try {
    await Bun.write(temporary, `${JSON.stringify(value, null, 2)}\n`);
    await rename(temporary, filePath);
  } finally {
    await rm(temporary, { force: true });
  }
}
