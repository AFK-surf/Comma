import { Elysia } from "elysia";
import path from "node:path";

import {
  LocalResultDownloadStore,
  createLocalQueryRuntime,
} from "@evalens/store/local";

import { createApi } from "../app";
import { connectToFetch } from "./connect";

export async function createLocalApi(outputDir: string) {
  const resolvedOutputDir = path.resolve(outputDir);
  const runtime = await createLocalQueryRuntime(resolvedOutputDir, {
    bootstrap: true,
  });
  const app = createApi({
    resultStore: new LocalResultDownloadStore(resolvedOutputDir),
    queryService: runtime.queryService,
    indexGuard: runtime.indexGuard,
  });
  return {
    app,
    close: () => void runtime[Symbol.asyncDispose](),
  };
}

export async function serveLocal(options: {
  outputDir: string;
  port?: number;
  hmrPort?: number | false;
  dashboardRoot?: string;
}) {
  const local = await createLocalApi(options.outputDir);
  const dashboardRoot = path.resolve(
    options.dashboardRoot ?? path.join(import.meta.dir, "../../../dashboard")
  );
  const { createServer } = await import("vite");
  const vite = await createServer({
    root: dashboardRoot,
    configFile: path.join(dashboardRoot, "vite.config.ts"),
    appType: "spa",
    server: {
      middlewareMode: true,
      hmr:
        options.hmrPort === false
          ? false
          : {
              host: "localhost",
              port: options.hmrPort ?? 24678,
              clientPort: options.hmrPort ?? 24678,
            },
    },
  });
  const viteHandler = connectToFetch(vite.middlewares);
  const app = new Elysia()
    .use(local.app)
    .all("/*", ({ request }) => viteHandler(request))
    .onStop(async () => {
      await vite.close();
      local.close();
    });
  app.listen(options.port ?? 3000);
  const server = app.server;
  if (!server) throw new Error("local Evalens server did not start");
  return {
    url: `http://${server.hostname}:${server.port}`,
    hmrPort: options.hmrPort === false ? undefined : (options.hmrPort ?? 24678),
    async [Symbol.asyncDispose]() {
      await app.stop();
    },
  };
}

if (import.meta.main) {
  if (Bun.argv[2] === "--help") {
    console.log(
      "usage: bun run dashboard:dev [outputDir] [port] [hmrPort]\n" +
        "outputDir defaults to ./runs and can also be set with EVALENS_OUTPUT_DIR"
    );
    process.exit(0);
  }
  const outputDir = path.resolve(
    Bun.argv[2] ??
      Bun.env.EVALENS_OUTPUT_DIR ??
      path.join(import.meta.dir, "../../../../runs")
  );
  const server = await serveLocal({
    outputDir,
    port: Bun.argv[3] === undefined ? undefined : Number(Bun.argv[3]),
    hmrPort: Bun.argv[4] === undefined ? undefined : Number(Bun.argv[4]),
  });
  console.log(`${server.url} (results: ${outputDir}, HMR: ${server.hmrPort})`);
}
