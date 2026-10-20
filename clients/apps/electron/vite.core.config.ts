import { defineConfig } from "vite";

export default defineConfig({
  build: {
    rolldownOptions: {
      // The core runs inside Electron's utility process: its database is
      // Electron's node:sqlite, not a build-time shim.
      external: ["electron", "node:crypto", "node:fs", "node:path", "node:sqlite"],
    },
  },
});
