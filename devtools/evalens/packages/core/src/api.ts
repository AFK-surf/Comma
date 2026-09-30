import type { ParamValue } from "./schemas";
import { z } from "zod";

export const ReindexingResponse = z
  .object({
    state: z.literal("reindexing"),
    message: z.string(),
  })
  .strict();
export type ReindexingResponse = z.infer<typeof ReindexingResponse>;

export const ApiErrorResponse = z.object({ message: z.string() }).strict();
export type ApiErrorResponse = z.infer<typeof ApiErrorResponse>;

export type DataState = "ready" | "reindexing";

export const MAX_COMPARE_EVALUATIONS = 8;

export interface ExperimentSummary {
  name: string;
  description?: string;
  runCount: number;
  latestRunAt?: string;
}

export type { ParamValue } from "./schemas";

export interface RunSummary {
  id: string;
  experimentName: string;
  description?: string;
  datasetName: string;
  datasetDigest: string;
  datasetSelectionDigest: string;
  targetItemCount: number;
  status: "running" | "finished" | "error";
  tags: string[];
  adapters: Array<{ name: string; version: string }>;
  params: Record<string, ParamValue>;
  createdAt: string;
  updatedAt: string;
  finishedAt?: string;
  itemCounts: { completed: number; error: number };
  evalCount: number;
  latestFinishedEvaluation?: EvalCatalogEntry;
}

export interface EvalSummary {
  id: string;
  status: "running" | "finished" | "error";
  params: Record<string, ParamValue>;
  aggregatorVersion: string;
  evaluators: Array<{ name: string; version: string }>;
  scoreIdentities: MetricIdentity[];
  adapters: Array<{ name: string; version: string }>;
  aggregateScores: Record<string, number>;
  createdAt: string;
  finishedAt?: string;
  error?: string;
  resultCounts: { target: number; completed: number; error: number; skipped: number };
}

export interface EvaluatorResultCell {
  evaluatorName: string;
  evaluatorVersion: string;
  status: "completed" | "error" | "skipped";
  scores: Record<string, number>;
  message?: string;
  durationMs?: number;
}

export interface RunItemSummary {
  id: string;
  digest: string;
  status: "completed" | "error";
  durationMs: number;
  error?: string;
  evaluatorResults: EvaluatorResultCell[];
}

export interface Page<T> {
  items: T[];
  page: number;
  pageSize: number;
  total: number;
}

export interface EvalCatalogEntry extends EvalSummary {
  run: Pick<
    RunSummary,
    | "id"
    | "experimentName"
    | "datasetName"
    | "datasetDigest"
    | "datasetSelectionDigest"
    | "tags"
    | "params"
    | "createdAt"
  >;
}

export interface EvalComparisonEntry extends EvalCatalogEntry {
  items: RunItemSummary[];
}

export interface MetricIdentity {
  evaluatorName: string;
  evaluatorVersion: string;
  scoreKey: string;
}

export function metricIdentityKey(metric: MetricIdentity): string {
  return encodeIdentityTuple([
    metric.evaluatorName,
    metric.evaluatorVersion,
    metric.scoreKey,
  ]);
}

export function parseMetricIdentityKey(key: string): MetricIdentity {
  const [evaluatorName, evaluatorVersion, scoreKey] = decodeIdentityTuple(key, 3);
  return {
    evaluatorName,
    evaluatorVersion,
    scoreKey,
  };
}

export interface AggregateMetricIdentity {
  aggregatorVersion: string;
  scoreKey: string;
}

export function aggregateMetricIdentityKey(metric: AggregateMetricIdentity): string {
  return encodeIdentityTuple([metric.aggregatorVersion, metric.scoreKey]);
}

export function parseAggregateMetricIdentityKey(key: string): AggregateMetricIdentity {
  const [aggregatorVersion, scoreKey] = decodeIdentityTuple(key, 2);
  return { aggregatorVersion, scoreKey };
}

function encodeIdentityTuple(parts: string[]): string {
  return JSON.stringify(parts);
}

function decodeIdentityTuple(key: string, length: 2): [string, string];
function decodeIdentityTuple(key: string, length: 3): [string, string, string];
function decodeIdentityTuple(
  key: string,
  length: 2 | 3
): [string, string] | [string, string, string] {
  const parsed: unknown = JSON.parse(key);
  if (Array.isArray(parsed)) {
    if (
      length === 2 &&
      parsed.length === 2 &&
      typeof parsed[0] === "string" &&
      typeof parsed[1] === "string"
    ) {
      return [parsed[0], parsed[1]];
    }
    if (
      length === 3 &&
      parsed.length === 3 &&
      typeof parsed[0] === "string" &&
      typeof parsed[1] === "string" &&
      typeof parsed[2] === "string"
    ) {
      return [parsed[0], parsed[1], parsed[2]];
    }
  }
  throw new Error(`invalid metric identity key: ${key}`);
}

export interface EvalComparison {
  evaluations: EvalComparisonEntry[];
  sharedItemCount: number;
  itemPage: number;
  itemPageSize: number;
  /** Score identities available in the currently loaded item page for detail columns. */
  itemMetrics: MetricIdentity[];
}

export interface RunFilters {
  experimentName?: string;
  status?: "running" | "finished" | "error";
  query?: string;
  page?: number;
  pageSize?: number;
  tag?: string;
  params?: Record<string, ParamValue>;
  createdAfter?: string;
  createdBefore?: string;
}

export interface EvalFilters {
  runId?: string;
  query?: string;
  experimentName?: string;
  status?: "running" | "finished" | "error";
  page?: number;
  pageSize?: number;
  tag?: string;
  runParams?: Record<string, ParamValue>;
  evalParams?: Record<string, ParamValue>;
  createdAfter?: string;
  createdBefore?: string;
}

export interface RunnableExperiment {
  name: string;
  description?: string;
}

export interface TriggerRunInput {
  filter?: string[];
  runParams?: import("./schemas").Params;
  evalParams?: import("./schemas").Params;
}

export interface TriggerRunResponse {
  accepted: true;
  experimentName: string;
  workflow: string;
  ref: string;
}

export interface QueryService {
  getState(): Promise<DataState>;
  listExperiments(): Promise<ExperimentSummary[]>;
  listRuns(filters?: RunFilters): Promise<Page<RunSummary>>;
  getRun(runId: string): Promise<RunSummary | null>;
  listEvaluations(filters?: EvalFilters): Promise<Page<EvalCatalogEntry>>;
  getEvaluation(evalId: string): Promise<EvalCatalogEntry | null>;
  listRunItems(
    runId: string,
    evalId?: string,
    page?: number,
    pageSize?: number
  ): Promise<Page<RunItemSummary>>;
  compareEvaluations(
    evalIds: string[],
    itemPage?: number,
    itemPageSize?: number,
    referenceEvalId?: string
  ): Promise<EvalComparison>;
}
