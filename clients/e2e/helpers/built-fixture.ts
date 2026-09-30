import { mkdtemp, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { build, preview, type InlineConfig, type PreviewServer } from "vite";

export type BuiltFixtureServer = Pick<
  PreviewServer,
  "httpServer" | "close" | "resolvedUrls"
>;

// These component fixtures test rendered behavior, not Vite's source server.
// Keep their plugins and defines, but load built assets in each fresh context.
export async function createBuiltFixtureServer(
  config: InlineConfig & { root: string }
): Promise<BuiltFixtureServer> {
  const root = await realpath(config.root);
  const outDir = await realpath(await mkdtemp(join(tmpdir(), "comma-built-fixture-")));
  let server: PreviewServer | undefined;
  try {
    await build({
      ...config,
      root,
      // Preserve the unoptimized CSS used by the original source fixtures.
      // Only the JavaScript module graph needs prebundling here.
      build: { ...config.build, cssMinify: false, outDir, emptyOutDir: true },
    });
    server = await preview({
      configFile: false,
      root,
      build: { outDir },
      preview: { host: "127.0.0.1", port: 0 },
    });
    return {
      httpServer: server.httpServer,
      resolvedUrls: server.resolvedUrls,
      async close() {
        try {
          await server?.close();
        } finally {
          await rm(outDir, { recursive: true, force: true });
        }
      },
    };
  } catch (error) {
    try {
      await server?.close();
    } finally {
      await rm(outDir, { recursive: true, force: true });
    }
    throw error;
  }
}
