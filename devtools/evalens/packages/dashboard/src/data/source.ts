import type { App } from "@evalens/server";
import { treaty } from "@elysia/eden";

import type {
  DashboardDataSource,
  EvalCatalogEntry,
  EvalComparison,
  ExperimentSummary,
  Page,
  RunItemSummary,
  RunSummary,
} from "./types";
import { m } from "../paraglide/messages.js";

const client = treaty<App>(window.location.origin);
const comparisonLoads = new Map<string, Promise<EvalComparison>>();

export const dashboardDataSource: DashboardDataSource = {
  async getState() {
    return unwrap(await client.api.state.get());
  },
  async listExperiments() {
    return unwrapIndexed<ExperimentSummary[]>(await client.api.experiments.get());
  },
  async listRuns(filters = {}) {
    const { params, ...query } = filters;
    return unwrapIndexed<Page<RunSummary>>(
      await client.api.runs.get({
        query: { ...query, ...(params ? { params: JSON.stringify(params) } : {}) },
      })
    );
  },
  async getRun(runId) {
    const response = await client.api.runs({ runId }).get();
    if (response.error?.status === 404) return null;
    return unwrapIndexed<RunSummary>(response);
  },
  async listEvaluations(filters = {}) {
    const { runParams, evalParams, ...query } = filters;
    return unwrapIndexed<Page<EvalCatalogEntry>>(
      await client.api.evaluations.get({
        query: {
          ...query,
          ...(runParams ? { runParams: JSON.stringify(runParams) } : {}),
          ...(evalParams ? { evalParams: JSON.stringify(evalParams) } : {}),
        },
      })
    );
  },
  async getEvaluation(evalId) {
    const response = await client.api.evaluations({ evalId }).get();
    if (response.error?.status === 404) return null;
    return unwrapIndexed<EvalCatalogEntry>(response);
  },
  async listRunItems(runId, evalId, page, pageSize) {
    const response = await client.api.runs({ runId }).items.get({
      query: { evalId, page, pageSize },
    });
    return unwrapIndexed<Page<RunItemSummary>>(response);
  },
  async compareEvaluations(evalIds, itemPage, itemPageSize, referenceEvalId) {
    const key = JSON.stringify([evalIds, itemPage, itemPageSize]);
    const existing = comparisonLoads.get(key);
    if (existing) return existing;
    const operation = client.api.evaluations.compare
      .post({
        evalIds,
        itemPage,
        itemPageSize,
        referenceEvalId,
      })
      .then((response) => unwrapIndexed<EvalComparison>(response))
      .finally(() => comparisonLoads.delete(key));
    comparisonLoads.set(key, operation);
    return operation;
  },
};

function unwrapIndexed<T>(response: {
  data: T | { state: "reindexing"; message: string } | null;
  error: unknown;
}): T {
  const data = unwrap(response);
  if (isReindexing(data)) throw new Error(data.message);
  return data as T;
}

function isReindexing(
  value: unknown
): value is { state: "reindexing"; message: string } {
  return (
    typeof value === "object" &&
    value !== null &&
    "state" in value &&
    value.state === "reindexing"
  );
}

function unwrap<T>(response: { data: T | null; error: unknown }): T {
  if (response.error) throw new Error(apiError(response.error));
  if (response.data === null) throw new Error(m.api_empty_response());
  return response.data;
}

function apiError(error: unknown): string {
  if (typeof error === "object" && error !== null && "value" in error) {
    const value = (error as { value: unknown }).value;
    if (typeof value === "object" && value !== null && "message" in value) {
      return String((value as { message: unknown }).message);
    }
  }
  return String(error);
}
