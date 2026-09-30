import { treaty } from "@elysia/eden";

import type { RemoteIngestionApi } from "@evalens/server/result-api";
import {
  AggregateScoresMetadata,
  EvalItemCommitMetadata,
  EvalManifestMetadata,
  RunItemCommitMetadata,
  RunManifestMetadata,
  type MetadataWriter,
} from "@evalens/store/metadata";

export function createRemoteMetadataWriter(options: {
  url: string;
  access: { clientId: string; clientSecret: string };
  fetcher?: typeof fetch;
}): MetadataWriter {
  const api = treaty<RemoteIngestionApi>(`${options.url.replace(/\/$/, "")}/api`, {
    headers: {
      "CF-Access-Client-Id": options.access.clientId,
      "CF-Access-Client-Secret": options.access.clientSecret,
    },
    fetcher: options.fetcher ?? globalThis.fetch,
    parseDate: true,
    throwHttpError: true,
  });

  return {
    async upsertRunManifest(metadata) {
      await api.results.metadata.runs.post(RunManifestMetadata.parse(metadata));
    },
    async commitRunItem(metadata) {
      await api.results.metadata
        .runs({ runId: metadata.runId })
        .items({ itemId: metadata.itemId })
        .put(RunItemCommitMetadata.parse(metadata));
    },
    async upsertEvalManifest(metadata) {
      await api.results.metadata.evaluations.post(EvalManifestMetadata.parse(metadata));
    },
    async commitEvalItem(metadata) {
      await api.results.metadata
        .evaluations({ evalId: metadata.evalId })
        .items({ itemId: metadata.itemId })
        .put(EvalItemCommitMetadata.parse(metadata));
    },
    async replaceAggregateScores(metadata) {
      await api.results.metadata
        .evaluations({ evalId: metadata.evalId })
        .aggregate.put(AggregateScoresMetadata.parse(metadata));
    },
  };
}
