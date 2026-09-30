import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { defineConfig } from "vite";
import { resolveElectronDisplayVersion } from "./src/app-version";
import { getCommaReleaseConfig } from "./src/release-config";

const releaseConfig = getCommaReleaseConfig();
const packageJson = JSON.parse(
  readFileSync(resolve(import.meta.dirname, "package.json"), "utf8")
) as { version: string };
const displayVersion = resolveElectronDisplayVersion({
  flavor: releaseConfig.flavor,
  packageVersion: packageJson.version,
  releaseVersion: process.env.COMMA_PACK_VERSION,
});

export default defineConfig({
  define: {
    COMMA_DEFINED_BUILD_FLAVOR: JSON.stringify(releaseConfig.flavor),
    COMMA_DEFINED_DISPLAY_VERSION: JSON.stringify(displayVersion),
    COMMA_DEFINED_R2_PUBLIC_BASE_URL: JSON.stringify(
      process.env.COMMA_R2_PUBLIC_BASE_URL ??
        process.env.CLOUDFLARE_R2_PUBLIC_BASE_URL ??
        ""
    ),
    COMMA_DEFINED_UPDATE_URL: JSON.stringify(process.env.COMMA_UPDATE_URL ?? ""),
    COMMA_DEFINED_API_BASE_URL: JSON.stringify(releaseConfig.apiBaseUrl),
  },
  resolve: {
    alias: {
      "@comma/config": resolve("../../packages/config/src/index.ts"),
      "@comma/i18n": resolve("../../packages/i18n/src/index.ts"),
      "@comma/app/api": resolve("../../packages/app/src/api/index.ts"),
      "@comma/app/chat-core": resolve("../../packages/app/src/chat-core.ts"),
      "@comma/session-contract": resolve(
        "../../packages/session-contract/src/index.ts"
      ),
    },
  },
  build: {
    rolldownOptions: {
      // Rolldown runs under the workspace Node version, which may not list a
      // newer Electron builtin yet. Keep SQLite as a runtime builtin so its
      // named export remains Electron's real DatabaseSync constructor.
      // @recappi/sdk is a NAPI addon: it must stay a runtime require so the
      // platform binary resolves from the packaged node_modules.
      external: ["@recappi/sdk", "electron", "node:sqlite", "velopack"],
    },
  },
});
