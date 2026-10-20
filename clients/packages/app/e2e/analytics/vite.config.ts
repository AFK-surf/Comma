import { resolve } from "node:path";
import { defineConfig, mergeConfig } from "vite";
import webConfig from "../../../../apps/web/vite.config";
import { apiBaseUrl } from "./posthog-capture";

// Bundle the crash probe with the app so both use the same analytics instance.
// This entry exists only in the analytics test build.
export default mergeConfig(
  webConfig,
  defineConfig({
    plugins: [
      {
        name: "analytics-launch-page",
        generateBundle() {
          this.emitFile({
            type: "asset",
            fileName: "launch.html",
            source: "<!doctype html><title>Desktop launch analytics fixture</title>",
          });
        },
      },
    ],
    // Use the production build flavor against the test's local API fixture.
    define: { COMMA_DEFINED_API_BASE_URL: JSON.stringify(apiBaseUrl) },
    build: {
      rolldownOptions: {
        preserveEntrySignatures: "strict",
        input: {
          index: resolve(import.meta.dirname, "../../../../apps/web/index.html"),
          "reply-fixture": resolve(import.meta.dirname, "reply-fixture.ts"),
          "launch-fixture": resolve(import.meta.dirname, "launch-fixture.ts"),
          "fatal-fixture": resolve(import.meta.dirname, "fatal-fixture.tsx"),
        },
        output: { entryFileNames: "assets/[name].js" },
      },
    },
  })
);
