import tailwindcss from "@tailwindcss/vite";
import { sveltekit } from "@sveltejs/kit/vite";
import { defineConfig } from "vite";
import { playwrightTraceViewer } from "./vite/playwright-trace-viewer";

export default defineConfig({
  plugins: [playwrightTraceViewer(), tailwindcss(), sveltekit()],
  server: {
    proxy: {
      "/v1": {
        target: "http://localhost:6880",
        changeOrigin: true,
      },
    },
  },
});
