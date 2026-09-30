import { defineConfig } from "vite";

export default defineConfig({
  build: {
    rolldownOptions: {
      // The utility process runs inside Electron and must use Electron's
      // node:sqlite implementation rather than a workspace build-time shim.
      external: ["electron", "node:fs", "node:path", "node:sqlite"],
    },
  },
});
