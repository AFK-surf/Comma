import {
  MAX_COMPARE_EVALUATIONS,
  type QueryService,
  type ReindexingResponse,
} from "@evalens/core/api";
import { EvalId, ItemId, Params, RunId } from "@evalens/core/schemas";
import { Elysia } from "elysia";
import { z } from "zod";
import type { ResultDownloadStore } from "@evalens/store";

import type { QueryIndexGuard, RunDispatcher } from "./contracts";
import { createResultDownloadApi } from "./result-api";

export type ApiDependencies = {
  resultStore: ResultDownloadStore;
  queryService: QueryService;
  indexGuard?: QueryIndexGuard;
  dispatcher?: RunDispatcher;
};

const RunQuery = z.object({
  experimentName: z.string().optional(),
  status: z.enum(["running", "finished", "error"]).optional(),
  query: z.string().optional(),
  tag: z.string().optional(),
  params: z.string().optional(),
  createdAfter: z.string().optional(),
  createdBefore: z.string().optional(),
  page: z.coerce.number().int().positive().optional(),
  pageSize: z.coerce.number().int().positive().max(100).optional(),
});

const RunItemsQuery = z.object({
  evalId: EvalId.optional(),
  page: z.coerce.number().int().positive().optional(),
  pageSize: z.coerce.number().int().positive().max(200).optional(),
});
const EvalQuery = z.object({
  runId: RunId.optional(),
  query: z.string().optional(),
  experimentName: z.string().optional(),
  status: z.enum(["running", "finished", "error"]).optional(),
  tag: z.string().optional(),
  runParams: z.string().optional(),
  evalParams: z.string().optional(),
  createdAfter: z.string().optional(),
  createdBefore: z.string().optional(),
  page: z.coerce.number().int().positive().optional(),
  pageSize: z.coerce.number().int().positive().max(100).optional(),
});
const CompareBody = z.object({
  evalIds: z.array(z.string()).max(MAX_COMPARE_EVALUATIONS),
  itemPage: z.number().int().positive().optional(),
  itemPageSize: z.number().int().positive().max(200).optional(),
  referenceEvalId: z.string().optional(),
});
const TriggerRunBody = z
  .object({
    filter: z.array(ItemId).min(1).optional(),
    runParams: Params.optional(),
    evalParams: Params.optional(),
  })
  .strict();

export function createApi(dependencies: ApiDependencies) {
  return new Elysia({ prefix: "/api" })
    .get("/health", () => ({ ok: true as const }))
    .get("/state", async () => {
      if (!dependencies.indexGuard) return dependencies.queryService.getState();
      return (await dependencies.indexGuard.ensureAll()) ? "ready" : "reindexing";
    })
    .group("/experiments", (experiments) =>
      experiments
        .get("", async ({ status }) => {
          if (dependencies.indexGuard && !(await dependencies.indexGuard.ensureAll())) {
            return status(202, reindexingResponse);
          }
          return dependencies.queryService.listExperiments();
        })
        .get("/runnable", () =>
          (dependencies.dispatcher?.listExperiments() ?? []).map(
            ({ name, description }) => ({
              name,
              ...(description ? { description } : {}),
            })
          )
        )
        .post(
          "/:experimentName/runs",
          async ({ params, body, status }) => {
            if (!dependencies.dispatcher) {
              return status(503, { message: "GitHub dispatch is not configured" });
            }
            try {
              return await dependencies.dispatcher.trigger(
                params.experimentName,
                TriggerRunBody.parse(body)
              );
            } catch (error) {
              const message = error instanceof Error ? error.message : String(error);
              return status(message.startsWith("unknown runnable") ? 404 : 502, {
                message,
              });
            }
          },
          {
            params: z.object({ experimentName: z.string() }),
            body: TriggerRunBody,
          }
        )
    )
    .group("/runs", (runs) =>
      runs
        .get(
          "",
          async ({ query, status }) => {
            const indexed = query.experimentName
              ? await dependencies.indexGuard?.ensureExperiment(query.experimentName)
              : await dependencies.indexGuard?.ensureAll();
            if (indexed === false) return status(202, reindexingResponse);
            const { params: encodedParams, ...filters } = query;
            return dependencies.queryService.listRuns({
              ...filters,
              ...(encodedParams
                ? { params: Params.parse(JSON.parse(encodedParams)) }
                : {}),
            });
          },
          { query: RunQuery }
        )
        .get(
          "/:runId",
          async ({ params, status }) => {
            if (
              dependencies.indexGuard &&
              !(await dependencies.indexGuard.ensureRun(params.runId))
            ) {
              return status(202, reindexingResponse);
            }
            const run = await dependencies.queryService.getRun(params.runId);
            return run ?? status(404, { message: "run not found" });
          },
          {
            params: z.object({ runId: RunId }),
          }
        )
        .get(
          "/:runId/items",
          async ({ params, query, status }) => {
            if (
              dependencies.indexGuard &&
              !(await dependencies.indexGuard.ensureRun(params.runId))
            ) {
              return status(202, reindexingResponse);
            }
            if (
              query.evalId &&
              dependencies.indexGuard &&
              !(await dependencies.indexGuard.ensureEvaluations([query.evalId]))
            ) {
              return status(202, reindexingResponse);
            }
            if (!(await dependencies.queryService.getRun(params.runId))) {
              return status(404, { message: "run not found" });
            }
            if (query.evalId) {
              const evaluation = await dependencies.queryService.getEvaluation(
                query.evalId
              );
              if (!evaluation || evaluation.run.id !== params.runId) {
                return status(404, { message: "evaluation not found for run" });
              }
            }
            return dependencies.queryService.listRunItems(
              params.runId,
              query.evalId,
              query.page,
              query.pageSize
            );
          },
          {
            params: z.object({ runId: RunId }),
            query: RunItemsQuery,
          }
        )
    )
    .group("/evaluations", (evaluations) =>
      evaluations
        .get(
          "",
          async ({ query, status }) => {
            const indexed = query.runId
              ? await dependencies.indexGuard?.ensureRun(query.runId)
              : query.experimentName
                ? await dependencies.indexGuard?.ensureExperiment(query.experimentName)
                : await dependencies.indexGuard?.ensureAll();
            if (indexed === false) return status(202, reindexingResponse);
            const { runParams, evalParams, ...filters } = query;
            return dependencies.queryService.listEvaluations({
              ...filters,
              ...(runParams ? { runParams: Params.parse(JSON.parse(runParams)) } : {}),
              ...(evalParams
                ? { evalParams: Params.parse(JSON.parse(evalParams)) }
                : {}),
            });
          },
          { query: EvalQuery }
        )
        .get(
          "/:evalId",
          async ({ params, status }) => {
            if (
              dependencies.indexGuard &&
              !(await dependencies.indexGuard.ensureEvaluations([params.evalId]))
            ) {
              return status(202, reindexingResponse);
            }
            const evaluation = await dependencies.queryService.getEvaluation(
              params.evalId
            );
            return evaluation ?? status(404, { message: "evaluation not found" });
          },
          { params: z.object({ evalId: EvalId }) }
        )
        .post(
          "/compare",
          async ({ body, status }) => {
            if (
              dependencies.indexGuard &&
              !(await dependencies.indexGuard.ensureEvaluations(body.evalIds))
            ) {
              return status(202, reindexingResponse);
            }
            try {
              return await dependencies.queryService.compareEvaluations(
                body.evalIds,
                body.itemPage,
                body.itemPageSize,
                body.referenceEvalId
              );
            } catch (error) {
              return status(400, {
                message: error instanceof Error ? error.message : String(error),
              });
            }
          },
          { body: CompareBody }
        )
    )
    .use(createResultDownloadApi(dependencies.resultStore));
}

const reindexingResponse = {
  state: "reindexing",
  message: "result index is rebuilding",
} satisfies ReindexingResponse;

export type App = ReturnType<typeof createApi>;
