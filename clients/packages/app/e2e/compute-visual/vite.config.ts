import { defineConfig } from "vite";
import { resolve } from "node:path";
import base from "../../../../apps/web/vite.config";
// The tests load this page from a build (`vite preview`), not the development server: a development server compiles
// a module on its first request and re-bundles dependencies its scan missed, which reloads the page under a test.
export default defineConfig({
  ...base,
  root: import.meta.dirname,
  build: {
    ...base.build,
    rolldownOptions: {
      ...base.build?.rolldownOptions,
      input: { preview: resolve(import.meta.dirname, "preview.html") },
    },
  },
});
