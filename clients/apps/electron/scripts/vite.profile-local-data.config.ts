import { resolve } from "node:path";
import { defineConfig } from "vite";

export default defineConfig({
  build: {
    emptyOutDir: true,
    lib: {
      entry: resolve(import.meta.dirname, "profile-local-data.mjs"),
      fileName: "profile-local-data",
      formats: ["es"],
    },
    outDir: resolve(import.meta.dirname, "../.vite/profile"),
    rolldownOptions: {
      external: [/^node:/, "electron"],
      output: {
        codeSplitting: false,
      },
    },
  },
});
