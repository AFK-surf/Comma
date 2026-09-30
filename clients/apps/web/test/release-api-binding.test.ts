import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import { build } from "vite";

const clientsRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

describe("Comma web release API binding", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
    vi.resetModules();
  });

  it.each([
    ["staging", "https://salix-staging.comma.surf"],
    ["prod", "https://salix.comma.surf"],
  ] as const)(
    "ignores and removes a stale local API override in the %s artifact",
    async (flavor, expectedApiBaseUrl) => {
      vi.stubEnv("COMMA_BUILD_FLAVOR", flavor);
      vi.stubEnv("COMMA_API_BASE_URL", "http://127.0.0.1:4300");
      vi.resetModules();

      const webConfig = (await import("../vite.config")).default;
      const outputRoot = await mkdtemp(join(tmpdir(), `comma-web-${flavor}-`));
      const outputFile = join(outputRoot, "comma-api-resolver.js");

      try {
        await build({
          configFile: false,
          logLevel: "silent",
          resolve: {
            alias: {
              "@comma/config": resolve(clientsRoot, "packages/config/src/index.ts"),
            },
          },
          define: webConfig.define ?? {},
          build: {
            emptyOutDir: true,
            lib: {
              entry: resolve(clientsRoot, "packages/app/src/api/config.ts"),
              formats: ["es"],
              fileName: () => "comma-api-resolver.js",
            },
            minify: false,
            outDir: outputRoot,
          },
        });

        const values = new Map([["comma.apiBaseUrl", "http://127.0.0.1:4300"]]);
        vi.stubGlobal("localStorage", {
          getItem: (key: string) => values.get(key) ?? null,
          removeItem: (key: string) => values.delete(key),
          setItem: (key: string, value: string) => values.set(key, value),
        });

        const releaseConfig = (await import(
          `${pathToFileURL(outputFile).href}?flavor=${flavor}`
        )) as {
          defaultApiBaseUrl(): string;
        };

        expect(releaseConfig.defaultApiBaseUrl()).toBe(expectedApiBaseUrl);
        expect(values.has("comma.apiBaseUrl")).toBe(false);
      } finally {
        await rm(outputRoot, { force: true, recursive: true });
      }
    }
  );
});
