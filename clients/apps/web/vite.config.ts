import { analyticsBuildDefines } from "../../vite/analytics-build";
import { resolve } from "node:path";
import { defineConfig, type Connect, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../vite/comma-tailwind";
import { getCommaConfig, parseCommaChannelStrict } from "@comma/config";
import { commaI18nVitePlugin } from "@comma/i18n/vite";
import { commaBrandHtmlPlugin } from "../../vite/comma-brand-html";
import { layoutInspectorSourcePlugin } from "../../packages/layout-inspector/src/vite";

const commaBuildFlavor = normalizeCommaBuildFlavorStrict(
  process.env.COMMA_BUILD_FLAVOR
);
const commaConfig = getCommaConfig(commaBuildFlavor);
const explicitApiBaseUrl = process.env.COMMA_API_BASE_URL?.trim();
const apiBaseUrl =
  commaBuildFlavor === "dev" || process.env.COMMA_SELFHOST_BUILD === "true"
    ? explicitApiBaseUrl || commaConfig.apiBaseUrl
    : commaConfig.apiBaseUrl;

const publicShareRequest = /^\/s\/[^/?#]+\/?(?:[?#].*)?$/;

const rewritePublicShare: Connect.NextHandleFunction = (req, _res, next) => {
  if (req.url && publicShareRequest.test(req.url)) req.url = "/share.html";
  next();
};

/**
 * Serves `share.html` for public share links (`/s/<token>`) in dev and preview.
 * The deployed Worker applies the same rewrite.
 */
function publicShareRoute(): Plugin {
  return {
    name: "comma-public-share-route",
    configureServer(server) {
      server.middlewares.use(rewritePublicShare);
    },
    configurePreviewServer(server) {
      server.middlewares.use(rewritePublicShare);
    },
  };
}

function normalizeCommaBuildFlavorStrict(value: string | undefined) {
  if (value && !["prod", "staging", "dev"].includes(value)) {
    throw new Error(
      `Invalid COMMA_BUILD_FLAVOR "${value}". Expected prod, staging, or dev.`
    );
  }

  return parseCommaChannelStrict(value);
}

export default defineConfig({
  define: {
    ...analyticsBuildDefines(import.meta.dirname),
    COMMA_DEFINED_BUILD_FLAVOR: JSON.stringify(commaBuildFlavor),
    COMMA_DEFINED_API_BASE_URL: JSON.stringify(apiBaseUrl),
    COMMA_DEFINED_POSTHOG_KEY: JSON.stringify(
      process.env.COMMA_POSTHOG_KEY?.trim() ?? ""
    ),
    COMMA_DEFINED_POSTHOG_HOST: JSON.stringify(
      process.env.COMMA_POSTHOG_HOST?.trim() ?? ""
    ),
  },
  resolve: {
    alias: {
      "@comma/app/host-runtime": resolve(
        "../../packages/app/src/runtime-chat/CommaAppRuntime.ts"
      ),
      "@comma/app/chat-coordinator": resolve(
        "../../packages/app/src/runtime-chat/coordinator/ChatCoordinator.ts"
      ),
      "@comma/app/task-panel-session": resolve(
        "../../packages/app/src/task-panel-session.ts"
      ),
      "@comma/app/task-panel": resolve("../../packages/app/src/task-panel.ts"),
      "@comma/app/task-share": resolve("../../packages/app/src/task-share.ts"),
      "@comma/app/api": resolve("../../packages/app/src/api/index.ts"),
      "@comma/app/styles.css": resolve("../../packages/app/src/styles.css"),
      "@comma/app": resolve("../../packages/app/src/index.tsx"),
      "@comma/config": resolve("../../packages/config/src/index.ts"),
      "@comma/i18n/react": resolve("../../packages/i18n/src/react.tsx"),
      "@comma/i18n": resolve("../../packages/i18n/src/index.ts"),
      "@comma/layout-inspector": resolve(
        "../../packages/layout-inspector/src/index.ts"
      ),
      "@comma/native-bridge": resolve("../../packages/native-bridge/src/index.ts"),
      "@comma/product-inbox-runtime": resolve(
        "../../packages/product-inbox-runtime/src/index.ts"
      ),
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
      channel: commaBuildFlavor,
      productName: commaConfig.productName,
    }),
    react(),
    tailwindcss(),
    localGroupSelectors(),
    publicShareRoute(),
  ],
  build: {
    rolldownOptions: {
      tsconfig: resolve("tsconfig.app.json"),
      input: {
        main: resolve(import.meta.dirname, "index.html"),
        taskPanel: resolve(import.meta.dirname, "task-panel.html"),
        share: resolve(import.meta.dirname, "share.html"),
      },
    },
  },
  optimizeDeps: {
    rolldownOptions: {},
  },
});
