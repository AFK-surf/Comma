import {
  ApiErrorResponse,
  Params,
  ReindexingResponse,
  type EvalCatalogEntry,
  type EvalFilters,
  type Page,
  type RunFilters,
  type RunSummary,
} from "@evalens/core";
import type { App } from "@evalens/server";
import { LocalQueryNotReadyError, createLocalQueryRuntime } from "@evalens/store/local";
import { treaty } from "@elysia/eden";
import { z } from "zod";

import type { EvalensConfig } from "../config";

export interface CliQueryClient {
  listRuns(filters: RunFilters): Promise<Page<RunSummary>>;
  getRun(runId: string): Promise<RunSummary | null>;
  listEvaluations(filters: EvalFilters): Promise<Page<EvalCatalogEntry>>;
  getEvaluation(evalId: string): Promise<EvalCatalogEntry | null>;
  [Symbol.asyncDispose](): Promise<void>;
}

export class CliQueryError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly retryable = false,
    readonly exitCode: 1 | 2 = 1
  ) {
    super(message);
    this.name = "CliQueryError";
  }
}

export function parseParamsFilter(value: string | undefined) {
  if (value === undefined) return undefined;
  try {
    return Params.parse(JSON.parse(value));
  } catch {
    throw new CliQueryError(
      "invalid_arguments",
      "parameter filters must be valid JSON objects with valid Evalens parameter values",
      false,
      2
    );
  }
}

export function parseCreatedRange(createdAfter?: string, createdBefore?: string) {
  try {
    return CreatedRange.parse({ createdAfter, createdBefore });
  } catch (error) {
    const issue = error instanceof z.ZodError ? error.issues[0] : undefined;
    const field = issue?.path[0];
    const message =
      issue?.message === RANGE_ORDER_MESSAGE
        ? RANGE_ORDER_MESSAGE
        : `${field === "createdBefore" ? "created-before" : "created-after"} must be a valid ISO 8601 timestamp with a timezone`;
    throw new CliQueryError("invalid_arguments", message, false, 2);
  }
}

export async function createCliQueryClient(
  config: EvalensConfig,
  fetcher: typeof fetch = globalThis.fetch
): Promise<CliQueryClient> {
  if ("local" in config) {
    return createLocalQueryRuntime(config.local.outputDir, { warn: () => {} });
  }
  return createRemoteQueryClient(config.remote, fetcher);
}

export function structuredCliError(error: unknown) {
  const normalized = normalizeCliQueryError(error);
  return {
    exitCode: normalized.exitCode,
    body: {
      error: {
        code: normalized.code,
        message: normalized.message,
        retryable: normalized.retryable,
      },
    },
  };
}

export function normalizeCliQueryError(error: unknown): CliQueryError {
  if (error instanceof CliQueryError) return error;
  if (error instanceof LocalQueryNotReadyError) {
    return new CliQueryError("reindexing", error.message, true);
  }
  return new CliQueryError(
    "query_failed",
    error instanceof Error ? error.message : String(error),
    false
  );
}

function createRemoteQueryClient(
  remote: Extract<EvalensConfig, { remote: unknown }>["remote"],
  fetcher: typeof fetch
): CliQueryClient {
  const client = treaty<App>(remote.url.replace(/\/$/, ""), {
    headers: {
      "CF-Access-Client-Id": remote.access.clientId,
      "CF-Access-Client-Secret": remote.access.clientSecret,
    },
    fetcher,
    parseDate: true,
  });
  return {
    async listRuns(filters) {
      const { params, ...query } = filters;
      return unwrapRemoteQuery(
        await client.api.runs.get({
          query: { ...query, ...(params ? { params: JSON.stringify(params) } : {}) },
        })
      );
    },
    async getRun(runId) {
      const response = await client.api.runs({ runId }).get();
      if (response.error?.status === 404) return null;
      return unwrapRemoteQuery(response);
    },
    async listEvaluations(filters) {
      const { runParams, evalParams, ...query } = filters;
      return unwrapRemoteQuery(
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
      return unwrapRemoteQuery(response);
    },
    async [Symbol.asyncDispose]() {},
  };
}

function unwrapRemoteQuery<T>(response: {
  data: T | ReindexingResponse | null;
  error: unknown;
}) {
  if (response.error) throw remoteTransportError(response.error);
  if (isReindexingResponse(response.data)) {
    throw new CliQueryError("reindexing", response.data.message, true);
  }
  if (response.data === null) {
    throw new CliQueryError("empty_response", "query returned an empty response", true);
  }
  return response.data;
}

function isReindexingResponse(value: unknown): value is ReindexingResponse {
  return ReindexingResponse.safeParse(value).success;
}

function remoteTransportError(error: unknown) {
  const parsed = TransportError.safeParse(error);
  const status = parsed.success ? parsed.data.status : 0;
  const apiError = parsed.success
    ? ApiErrorResponse.safeParse(parsed.data.value)
    : undefined;
  const message = apiError?.success
    ? apiError.data.message
    : error instanceof Error
      ? error.message
      : String(error);
  return new CliQueryError(
    status === 401 || status === 403 ? "auth_failed" : "query_failed",
    message,
    status !== 401 && status !== 403 && (status >= 500 || status === 0)
  );
}

const RANGE_ORDER_MESSAGE = "created-after must not be later than created-before";
const TransportError = z.object({ status: z.number(), value: z.unknown() });
const ZonedTimestamp = z.iso.datetime({ offset: true });
const CreatedRange = z
  .object({
    createdAfter: ZonedTimestamp.optional(),
    createdBefore: ZonedTimestamp.optional(),
  })
  .refine(
    ({ createdAfter, createdBefore }) =>
      !createdAfter ||
      !createdBefore ||
      new Date(createdAfter).getTime() <= new Date(createdBefore).getTime(),
    { message: RANGE_ORDER_MESSAGE, path: ["createdAfter"] }
  )
  .transform(({ createdAfter, createdBefore }) => ({
    ...(createdAfter ? { createdAfter } : {}),
    ...(createdBefore ? { createdBefore } : {}),
  }));
