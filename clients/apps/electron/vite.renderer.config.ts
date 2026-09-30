import { analyticsBuildDefines } from "../../vite/analytics-build";
import { resolve } from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../vite/comma-tailwind";
import { commaBrandHtmlPlugin } from "../../vite/comma-brand-html";
import { commaI18nVitePlugin } from "@comma/i18n/vite";
import { getCommaReleaseConfig } from "./src/release-config";
import { layoutInspectorSourcePlugin } from "../../packages/layout-inspector/src/vite";

const releaseConfig = getCommaReleaseConfig();

export default defineConfig({
  root: resolve("src/renderer"),
  define: {
    ...analyticsBuildDefines(import.meta.dirname),
    COMMA_DEFINED_BUILD_FLAVOR: JSON.stringify(releaseConfig.flavor),
    COMMA_DEFINED_API_BASE_URL: JSON.stringify("/"),
    COMMA_DEFINED_POSTHOG_KEY: JSON.stringify(
      process.env.COMMA_POSTHOG_KEY?.trim() ?? ""
    ),
    COMMA_DEFINED_POSTHOG_HOST: JSON.stringify(
      process.env.COMMA_POSTHOG_HOST?.trim() ?? ""
    ),
  },
  resolve: {
    alias: {
      "@comma/app/styles.css": resolve("../../packages/app/src/styles.css"),
      "@comma/app": resolve("../../packages/app/src/index.tsx"),
      "@comma/layout-inspector": resolve(
        "../../packages/layout-inspector/src/index.ts"
      ),
      "@comma/chat-contract/dynamic-ui-cards": resolve(
        "../../packages/chat-contract/src/dynamic-ui/cardsEntry.ts"
      ),
      "@comma/chat-contract": resolve("../../packages/chat-contract/src/index.ts"),
      "@comma/config": resolve("../../packages/config/src/index.ts"),
      "@comma/i18n/react": resolve("../../packages/i18n/src/react.tsx"),
      "@comma/i18n": resolve("../../packages/i18n/src/index.ts"),
      "@comma/native-bridge": resolve("../../packages/native-bridge/src/index.ts"),
      "@comma/session-contract": resolve(
        "../../packages/session-contract/src/index.ts"
      ),
      "@comma/ui/styles.css": resolve("../../packages/ui/src/styles.css"),
      "@comma/ui": resolve("../../packages/ui/src/index.ts"),
    },
  },
  plugins: [
    layoutInspectorSourcePlugin({
      root: resolve(import.meta.dirname, "../../.."),
    }),
    commaI18nVitePlugin(),
    commaBrandHtmlPlugin({
      channel: releaseConfig.flavor,
      productName: releaseConfig.productName,
    }),
    react(),
    tailwindcss(),
    localGroupSelectors(),
  ],
  build: {
    outDir: resolve(".vite/renderer/main_window"),
    emptyOutDir: true,
    rolldownOptions: {
      tsconfig: resolve("tsconfig.renderer.json"),
    },
  },
  optimizeDeps: {
    include: ["react-aria-components", "tailwind-merge"],
    rolldownOptions: {},
  },
});
