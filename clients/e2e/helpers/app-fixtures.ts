import { readdir } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { build, preview } from "vite";
import { sharedBuildDir } from "./shared-build";

const webRoot = fileURLToPath(new URL("../../apps/web/", import.meta.url));
const fixturesRoot = fileURLToPath(
  new URL("../../packages/app/e2e/fixtures/", import.meta.url)
);

/**
 * Serves the pages of packages/app/e2e/fixtures (`/<name>.html`) from one
 * production build of all of them with the web app's Vite config. The build
 * runs once per Playwright run; each worker serves it with its own preview
 * server.
 */
export async function serveAppFixtures(): Promise<{
  url: string;
  close(): Promise<void>;
}> {
  const directory = await sharedBuildDir("app-fixtures", async (outDir) => {
    const pages = (await readdir(fixturesRoot))
      .filter((name) => name.endsWith(".html"))
      .map((name) => join(fixturesRoot, name));
    await inWebRoot(() =>
      build({
        root: fixturesRoot,
        configFile: join(webRoot, "vite.config.ts"),
        logLevel: "error",
        build: { outDir, emptyOutDir: false },
        // The web config names its own pages as inputs; config merging would
        // add these to them, so the bundler's options are replaced instead.
        plugins: [
          {
            name: "comma-app-fixture-pages",
            options: (options) => ({ ...options, input: pages }),
          },
        ],
      })
    );
  });
  const server = await inWebRoot(() =>
    preview({
      root: webRoot,
      configFile: join(webRoot, "vite.config.ts"),
      build: { outDir: directory },
      preview: { host: "127.0.0.1", port: 0, strictPort: false },
    })
  );
  return {
    url: server.resolvedUrls!.local[0]!,
    close: () =>
      new Promise<void>((resolve) => server.httpServer.close(() => resolve())),
  };
}

// The web app's Vite config resolves workspace source aliases from its own cwd.
async function inWebRoot<T>(run: () => Promise<T>): Promise<T> {
  const previous = process.cwd();
  process.chdir(webRoot);
  try {
    return await run();
  } finally {
    process.chdir(previous);
  }
}
