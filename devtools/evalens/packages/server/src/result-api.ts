import {
  AggregateScoresMetadata,
  EvalItemCommitMetadata,
  EvalManifestMetadata,
  type MetadataWriter,
  RunItemCommitMetadata,
  RunManifestMetadata,
} from "@evalens/store/metadata/contracts";
import { EvalId, ExperimentName, ItemId, RunId } from "@evalens/core/schemas";
import { Elysia } from "elysia";
import { z } from "zod";

import type { DownloadObject, ResultDownloadStore } from "@evalens/store";

const RunParams = z.object({
  experimentName: ExperimentName,
  runId: RunId,
});
const RunItemParams = RunParams.extend({ itemId: ItemId });
const EvalItemParams = RunItemParams.extend({ evalId: EvalId });

export function createRemoteIngestionApi(metadataWriter: MetadataWriter) {
  return new Elysia({ prefix: "/results" }).group("/metadata", (metadata) =>
    metadata
      .group("/runs", (runs) =>
        runs
          .post(
            "",
            async ({ body }) => {
              await metadataWriter.upsertRunManifest(body);
              return { ok: true as const };
            },
            { body: RunManifestMetadata }
          )
          .put(
            "/:runId/items/:itemId",
            async ({ params, body, status }) => {
              if (body.runId !== params.runId || body.itemId !== params.itemId) {
                return status(400, {
                  message: "run item identity does not match route",
                });
              }
              await metadataWriter.commitRunItem(body);
              return { ok: true as const };
            },
            {
              params: z.object({ runId: RunId, itemId: ItemId }),
              body: RunItemCommitMetadata,
            }
          )
      )
      .group("/evaluations", (evaluations) =>
        evaluations
          .post(
            "",
            async ({ body }) => {
              await metadataWriter.upsertEvalManifest(body);
              return { ok: true as const };
            },
            { body: EvalManifestMetadata }
          )
          .put(
            "/:evalId/items/:itemId",
            async ({ params, body, status }) => {
              if (body.evalId !== params.evalId || body.itemId !== params.itemId) {
                return status(400, {
                  message: "eval item identity does not match route",
                });
              }
              await metadataWriter.commitEvalItem(body);
              return { ok: true as const };
            },
            {
              params: z.object({ evalId: EvalId, itemId: ItemId }),
              body: EvalItemCommitMetadata,
            }
          )
          .put(
            "/:evalId/aggregate",
            async ({ params, body, status }) => {
              if (body.evalId !== params.evalId) {
                return status(400, {
                  message: "aggregate identity does not match route",
                });
              }
              await metadataWriter.replaceAggregateScores(body);
              return { ok: true as const };
            },
            {
              params: z.object({ evalId: EvalId }),
              body: AggregateScoresMetadata,
            }
          )
      )
  );
}

export function createRemoteIngestionApp(metadataWriter: MetadataWriter) {
  return new Elysia({ prefix: "/api" }).use(createRemoteIngestionApi(metadataWriter));
}

export function createResultDownloadApi(store: ResultDownloadStore) {
  return new Elysia({ prefix: "/results" }).group(
    "/downloads/experiments/:experimentName/runs/:runId",
    (runs) =>
      runs
        .group("/items/:itemId", (items) =>
          items
            .get(
              "/artifact/metadata",
              async ({ params, status }) => {
                const metadata = await store.readRunArtifactMetadata(
                  params.experimentName,
                  params.runId,
                  params.itemId
                );
                return metadata ?? status(404, { message: "artifact not found" });
              },
              { params: RunItemParams }
            )
            .get(
              "/run-result",
              ({ params, status }) =>
                download(
                  store.readRunResult(
                    params.experimentName,
                    params.runId,
                    params.itemId
                  ),
                  "run_result.json",
                  status
                ),
              { params: RunItemParams }
            )
            .get(
              "/trajectories",
              ({ params, status }) => trajectoriesDownload(store, params, status),
              { params: RunItemParams }
            )
            .get(
              "/artifact",
              async ({ params, status }) => {
                const object = await store.readRunArtifact(
                  params.experimentName,
                  params.runId,
                  params.itemId
                );
                return object
                  ? objectResponse(object, "artifacts.tar")
                  : status(404, { message: "artifact not found" });
              },
              { params: RunItemParams }
            )
            .get(
              "/log",
              async ({ params, status }) => {
                const object = await store.readRunLog(
                  params.experimentName,
                  params.runId,
                  params.itemId
                );
                return object
                  ? objectResponse(object, "run.log.jsonl")
                  : status(404, { message: "run log not found" });
              },
              { params: RunItemParams }
            )
        )
        .group("/evals/:evalId/items/:itemId", (items) =>
          items
            .get(
              "/log",
              ({ params, status }) =>
                download(
                  store.readEvalLog(
                    params.experimentName,
                    params.runId,
                    params.evalId,
                    params.itemId
                  ),
                  "eval.log.jsonl",
                  status
                ),
              { params: EvalItemParams }
            )
            .get(
              "/results",
              ({ params, status }) =>
                download(
                  store.readEvalResults(
                    params.experimentName,
                    params.runId,
                    params.evalId,
                    params.itemId
                  ),
                  "eval_results.json",
                  status
                ),
              { params: EvalItemParams }
            )
        )
  );
}

async function download(
  result: Promise<DownloadObject | null>,
  filename: string,
  status: (code: 404, body: { message: string }) => unknown
) {
  const object = await result;
  return object
    ? objectResponse(object, filename)
    : status(404, { message: `${filename} not found` });
}

async function trajectoriesDownload(
  store: ResultDownloadStore,
  params: z.infer<typeof RunItemParams>,
  status: (code: 404, body: { message: string }) => unknown
) {
  const trajectories = await store.readTrajectories(
    params.experimentName,
    params.runId,
    params.itemId
  );
  if (trajectories) return objectResponse(trajectories, "trajectories.json");
  return status(404, { message: "trajectories.json not found" });
}

function objectResponse(object: DownloadObject, filename: string): Response {
  const headers = new Headers();
  const disposition = filename === "artifacts.tar" ? "attachment" : "inline";
  if (object instanceof Blob) {
    if (object.type) headers.set("content-type", object.type);
    headers.set("content-disposition", `${disposition}; filename="${filename}"`);
    return new Response(object, { headers });
  }
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("content-length", String(object.size));
  headers.set("content-disposition", `${disposition}; filename="${filename}"`);
  return new Response(object.body, { headers });
}

export type RemoteIngestionApi = ReturnType<typeof createRemoteIngestionApi>;
