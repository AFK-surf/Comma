import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { resolve } from "node:path";

export default defineConfig({
  root: resolve(import.meta.dirname, "src/devtools/proactive-chat-prototype"),
  plugins: [react(), tailwindcss()],
  server: {
    host: "127.0.0.1",
    port: 54870,
    strictPort: true,
    fs: { allow: [resolve(import.meta.dirname, "../../..")] },
  },
  build: {
    outDir: resolve(
      import.meta.dirname,
      "../../../.codex-artifacts/pr-1970/proactive-ui"
    ),
    emptyOutDir: true,
  },
});
