import { resolve } from "node:path";
import { defineConfig, mergeConfig } from "vite";
import webConfig from "../../../../apps/web/vite.config";

// Bundle the crash probe with the app so both use the same analytics instance.
// This entry exists only in the analytics test build.
export default mergeConfig(
  webConfig,
  defineConfig({
    build: {
      rolldownOptions: {
        preserveEntrySignatures: "strict",
        input: {
          index: resolve(import.meta.dirname, "../../../../apps/web/index.html"),
          "fatal-fixture": resolve(import.meta.dirname, "fatal-fixture.tsx"),
        },
        output: { entryFileNames: "assets/[name].js" },
      },
    },
  })
);
