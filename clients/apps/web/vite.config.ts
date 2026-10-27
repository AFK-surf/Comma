import { analyticsBuildDefines } from "../../vite/analytics-build";
import { execFileSync } from "node:child_process";
import { cpSync, mkdirSync, rmSync } from "node:fs";
import { resolve } from "node:path";
import { defineConfig, type Connect, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../vite/comma-tailwind";
import { getCommaConfig, parseCommaChannelStrict } from "@comma/config";
import { commaI18nVitePlugin } from "@comma/i18n/vite";
import {
  miniAppRuntimeCsp,
  miniAppRuntimeDocument,
  miniAppWebRuntimePath,
} from "@comma/chat-contract/mini-app-runtime";
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

// Public ingestion tokens, as used by the website and Electron releases.
// Workers Builds does not inherit the GitHub Actions environment variables.
const hostedPosthogProjects = {
  prod: {
    key: "phc_nSEHiHpAFnzfmkiQyatA5KinuGxPsFzCAp94xdg8C2sv",
    host: "https://us.i.posthog.com",
  },
  staging: {
    key: "phc_r5Py57SK42jSQfyQSAxwPMrrTRsucLRfr2k9VmJubdWP",
    host: "https://us.i.posthog.com",
  },
};
const hostedPosthog =
  commaBuildFlavor !== "dev" && process.env.COMMA_SELFHOST_BUILD !== "true"
    ? hostedPosthogProjects[commaBuildFlavor]
    : undefined;

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

const miniAppLinkRequest = /^\/a\/[^/?#]+\/?(?:[?#].*)?$/;

const serveMiniAppRoutes: Connect.NextHandleFunction = (req, res, next) => {
  const path = req.url?.split("?")[0];
  if (path === miniAppWebRuntimePath) {
    res.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "content-security-policy": miniAppRuntimeCsp,
      "cache-control": "no-store",
    });
    res.end(miniAppRuntimeDocument());
    return;
  }
  if (req.url && miniAppLinkRequest.test(req.url)) {
    res.setHeader("cache-control", "no-store");
    res.setHeader("referrer-policy", "no-referrer");
    res.setHeader("x-robots-tag", "noindex");
    req.url = "/";
  }
  next();
};

/**
 * Serves the Comma app runtime (`/app-runtime/`) and app links (`/a/<token>`,
 * the main app) in dev and preview. The deployed Worker does the same.
 */
function miniAppRoutes(): Plugin {
  return {
    name: "comma-mini-app-routes",
    configureServer(server) {
      server.middlewares.use(serveMiniAppRoutes);
    },
    configurePreviewServer(server) {
      server.middlewares.use(serveMiniAppRoutes);
    },
  };
}

/**
 * `virtual:comma-mesh`, which the core worker loads the first time it reaches a station: iroh's browser build
 * (clients/packages/mesh/wasm), prebuilt (systems/station/scripts/native.ts, part web-mesh) or, outside CI, built here
 * when this machine has Rust; copied under node_modules so the build bundles its WebAssembly. Without it the module
 * fails to load, and the page reaches no station.
 */
function commaMeshModule(): Plugin {
  const id = "virtual:comma-mesh";
  let code: string | undefined;
  return {
    name: "comma-mesh-module",
    resolveId: (source) => (source === id ? `\0${id}` : null),
    load: (source) => (source === `\0${id}` ? (code ??= commaMeshCode()) : null),
  };
}

/** The module's code: the browser build put under node_modules and loaded, or a stand-in that fails to load. */
function commaMeshCode(): string {
  const out = resolve(import.meta.dirname, "node_modules/.comma-mesh");
  try {
    const dir = execFileSync(
      process.execPath,
      [
        resolve(import.meta.dirname, "../../../systems/station/scripts/native.ts"),
        process.env.CI ? "fetch" : "path",
        "web-mesh",
        "wasm32",
      ],
      { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }
    ).trim();
    rmSync(out, { recursive: true, force: true });
    mkdirSync(out, { recursive: true });
    cpSync(dir, out, { recursive: true });
    return [
      `import init, { bind } from ${JSON.stringify(resolve(out, "comma_mesh_wasm.js"))};`,
      "export async function load() { await init(); return { bind }; }",
    ].join("\n");
  } catch {
    console.warn(
      "iroh's browser build (web-mesh) is not prebuilt for this source: this build reaches no station."
    );
    return 'export async function load() { throw new Error("This build reaches no station."); }';
  }
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
    // Each build's core worker: an older one retires when a newer one starts.
    COMMA_DEFINED_CORE_BUILD: JSON.stringify(Date.now()),
    COMMA_DEFINED_POSTHOG_KEY: JSON.stringify(
      process.env.COMMA_POSTHOG_KEY?.trim() ?? hostedPosthog?.key ?? ""
    ),
    COMMA_DEFINED_POSTHOG_HOST: JSON.stringify(
      process.env.COMMA_POSTHOG_HOST?.trim() ?? hostedPosthog?.host ?? ""
    ),
  },
  resolve: {
    alias: {
      "@comma/app/task-panel-session": resolve(
        "../../packages/app/src/task-panel-session.ts"
      ),
      "@comma/app/task-panel": resolve("../../packages/app/src/task-panel.ts"),
      "@comma/app/task-share": resolve("../../packages/app/src/task-share.ts"),
      "@comma/app/styles.css": resolve("../../packages/app/src/styles.css"),
      "@comma/app": resolve("../../packages/app/src/index.tsx"),
      "@comma/config": resolve("../../packages/config/src/index.ts"),
      "@comma/core/contract": resolve("../../packages/core/src/contract.ts"),
      "@comma/core/chat": resolve("../../packages/core/src/chat/public.ts"),
      "@comma/core/markdown": resolve("../../packages/core/src/markdown/index.ts"),
      "@comma/core/api-schemas": resolve(
        "../../packages/core/src/comma/api-schemas.ts"
      ),
      "@comma/core/web": resolve("../../packages/core/src/hosts/web.ts"),
      "@comma/core-client": resolve("../../packages/core-client/src/index.tsx"),
      "@comma/i18n/react": resolve("../../packages/i18n/src/react.tsx"),
      "@comma/i18n": resolve("../../packages/i18n/src/index.ts"),
      "@comma/layout-inspector": resolve(
        "../../packages/layout-inspector/src/index.ts"
      ),
      "@comma/native-bridge": resolve("../../packages/native-bridge/src/index.ts"),
      "@comma/session-contract": resolve(
        "../../packages/session-contract/src/index.ts"
      ),
      "@comma/ui/styles.css": resolve("../../packages/ui/src/styles.css"),
      "@comma/ui": resolve("../../packages/ui/src"),
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
    miniAppRoutes(),
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
  // SQLite's WASM build loads its .wasm next to itself: not pre-bundled.
  optimizeDeps: {
    exclude: ["@sqlite.org/sqlite-wasm"],
    rolldownOptions: {},
  },
  worker: { format: "es", plugins: () => [commaMeshModule()] },
});
