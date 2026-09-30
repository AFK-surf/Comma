import { resolve } from "node:path";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";
import localGroupSelectors from "../../vite/comma-tailwind";

/** Phoenix serves the built SPA from priv/static/bft (gitignored). */
export const bftOutDir = "../../../systems/apps/bridge_for_teams_web/priv/static/bft";

export function createBftViteConfig(command: "build" | "serve") {
  return {
    // Built assets live under /bft/; the dev server serves the SPA routes
    // (`/`, `/orgs/:org`) from the origin root like Phoenix does.
    base: command === "build" ? "/bft/" : "/",
    resolve: {
      alias: {
        "@comma/ui/styles.css": resolve("../../packages/ui/src/styles.css"),
        "@comma/ui": resolve("../../packages/ui/src/index.ts"),
      },
    },
    plugins: [react(), tailwindcss(), localGroupSelectors()],
    build: {
      outDir: bftOutDir,
      emptyOutDir: true,
      rolldownOptions: {
        tsconfig: resolve("tsconfig.app.json"),
      },
    },
  };
}

export default defineConfig(({ command }) => createBftViteConfig(command));
