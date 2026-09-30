import { env, waitUntil } from "cloudflare:workers";
import { Elysia } from "elysia";
import { CloudflareAdapter } from "elysia/adapter/cloudflare-worker";
import {
  D1MetadataWriter,
  D1QueryService,
  R2IndexSource,
  R2ResultDownloadStore,
} from "@evalens/store/cloudflare";
import { IndexService } from "@evalens/store/metadata/index-service";

import { createApi } from "../app";
import { createRemoteIngestionApp } from "../result-api";
import { GitHubDispatcher } from "./github";
import { CloudflareIndexGuard, ReindexScheduler } from "./index-guard";

const bindings = env as unknown as Env;
const metadataWriter = new D1MetadataWriter(bindings.DB);
const indexService = new IndexService(
  new R2IndexSource(bindings.RESULTS),
  metadataWriter
);
const indexGuard = new CloudflareIndexGuard(
  bindings.DB,
  indexService,
  new ReindexScheduler(indexService, waitUntil)
);

export const app = new Elysia({ adapter: CloudflareAdapter })
  .use(
    createApi({
      resultStore: new R2ResultDownloadStore(bindings.RESULTS),
      queryService: new D1QueryService(bindings.DB),
      indexGuard,
      dispatcher: new GitHubDispatcher({
        token: bindings.GITHUB_TOKEN,
        owner: bindings.GITHUB_OWNER,
        repo: bindings.GITHUB_REPO,
        ref: bindings.GITHUB_DEFAULT_REF,
        experiments: [
          {
            name: "basic",
            description: "Self-contained Evalens smoke experiment",
            module: "examples/basic.exp.ts",
          },
        ],
      }),
    })
  )
  .use(createRemoteIngestionApp(metadataWriter))
  .compile();

export default app;
