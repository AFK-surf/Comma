import { globSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { availableParallelism, totalmem } from "node:os";
import { basename, resolve } from "node:path";
import type { Plugin, UserConfig } from "vite";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";
import { commaLogoAnimationMarkupPlugin } from "./vite/comma-logo-animation-markup";
import { appShellOrigin, onAppShellOrigin } from "./vite/app-shell-origin";
import { frameQueryEngine, servedDynamicUiFrame } from "./vite/dynamic-ui-frame";
import { servedMiniAppFrame } from "./vite/mini-app-frame";
import { externalFiles } from "./e2e/app-shell/fixtures/external-files";
import { noDependencySourceMapsPlugin } from "./vite/no-dependency-source-maps";
import {
  parseFailureWatchPlugin,
  playwrightWithParseFailureWatch,
} from "./vite/parse-failure-watch";
import localGroupSelectors from "./vite/comma-tailwind";
import { browserCommands } from "./packages/test-utils/src/browser-commands";
import { browserTestFiles } from "./e2e/app-shell/browser-files.mjs";
import { nodeRealmCommands } from "./e2e/ui-runtime/node-realm-host";
import { workerPreludeParameter } from "./e2e/ui-runtime/realm-names";

type OxcConfig = Exclude<UserConfig["oxc"], false | undefined>;

const testTransform = {
  plugins: [commaLogoAnimationMarkupPlugin()],
  resolve: {
    alias: {
      "@comma/app/api": resolve(import.meta.dirname, "packages/app/src/api/index.ts"),
      "@comma/app": resolve(import.meta.dirname, "packages/app/src/index.tsx"),
      "@comma/chat-contract/dynamic-ui-runtime": resolve(
        import.meta.dirname,
        "packages/chat-contract/src/dynamic-ui/runtime.ts"
      ),
      "@comma/chat-contract/dynamic-ui-cards": resolve(
        import.meta.dirname,
        "packages/chat-contract/src/dynamic-ui/cardsEntry.ts"
      ),
      "@comma/chat-contract/dynamic-ui-card-fixtures": resolve(
        import.meta.dirname,
        "packages/chat-contract/src/dynamic-ui/cardFixtures.ts"
      ),
      "@comma/chat-contract/mini-app-runtime": resolve(
        import.meta.dirname,
        "packages/chat-contract/src/mini-app/runtime.ts"
      ),
      "@comma/chat-contract": resolve(
        import.meta.dirname,
        "packages/chat-contract/src/index.ts"
      ),
      "@comma/miniapp-sdk/mock": resolve(
        import.meta.dirname,
        "packages/miniapp-sdk/src/mock.ts"
      ),
      "@comma/miniapp-sdk/frame": resolve(
        import.meta.dirname,
        "packages/miniapp-sdk/src/frame.ts"
      ),
      "@comma/miniapp-sdk": resolve(
        import.meta.dirname,
        "packages/miniapp-sdk/src/index.ts"
      ),
      "@comma/config": resolve(import.meta.dirname, "packages/config/src/index.ts"),
      "@comma/core/contract": resolve(
        import.meta.dirname,
        "packages/core/src/contract.ts"
      ),
      "@comma/core/chat": resolve(
        import.meta.dirname,
        "packages/core/src/chat/public.ts"
      ),
      "@comma/core/markdown": resolve(
        import.meta.dirname,
        "packages/core/src/markdown/index.ts"
      ),
      "@comma/core/api-schemas": resolve(
        import.meta.dirname,
        "packages/core/src/comma/api-schemas.ts"
      ),
      "@comma/core/testing": resolve(
        import.meta.dirname,
        "packages/core/src/testing/index.ts"
      ),
      "@comma/core-client": resolve(
        import.meta.dirname,
        "packages/core-client/src/index.tsx"
      ),
      "@comma/i18n/react": resolve(import.meta.dirname, "packages/i18n/src/react.tsx"),
      "@comma/i18n/vite": resolve(import.meta.dirname, "packages/i18n/src/vite.ts"),
      "@comma/i18n": resolve(import.meta.dirname, "packages/i18n/src/index.ts"),
      "@comma/layout-inspector": resolve(
        import.meta.dirname,
        "packages/layout-inspector/src/index.ts"
      ),
      "@comma/native-bridge": resolve(
        import.meta.dirname,
        "packages/native-bridge/src/index.ts"
      ),
      "@comma/native-bridge/web": resolve(
        import.meta.dirname,
        "packages/native-bridge/src/web.ts"
      ),
      "@comma/mesh/station-native": resolve(
        import.meta.dirname,
        "packages/mesh/src/station-native.ts"
      ),
      "@comma/mesh/testing": resolve(
        import.meta.dirname,
        "packages/mesh/src/memory.ts"
      ),
      "@comma/mesh/web": resolve(import.meta.dirname, "packages/mesh/src/web.ts"),
      "@comma/mesh": resolve(import.meta.dirname, "packages/mesh/src/index.ts"),
      "@comma/session-contract": resolve(
        import.meta.dirname,
        "packages/session-contract/src/index.ts"
      ),
      "@comma/test-utils": resolve(import.meta.dirname, "packages/test-utils/src"),
      "@comma/ui": resolve(import.meta.dirname, "packages/ui/src"),
    },
  },
  oxc: {
    tsconfig: {
      compilerOptions: {
        jsx: "react-jsx",
        jsxImportSource: "react",
        target: "ES2024",
        useDefineForClassFields: true,
      },
    },
  } as unknown as OxcConfig,
} satisfies UserConfig;
/** React's own test scheduler: React renders only when the test runtime flushes it. */
const mockScheduler = createRequire(import.meta.url).resolve("scheduler/unstable_mock");

const buildExclude = ["**/node_modules/**", "**/dist/**", "**/out/**", "**/.vite/**"];
// The UI runtime's own tests run in their project (runtime-jsdom).
const testExclude = [...buildExclude, "**/*.runtime.test.{ts,tsx}"];

/**
 * A test waits for events and states, never for an amount of real time
 * (docs/testing.md#deterministic-tests), so no test or hook has a deadline of
 * its own: the CI job's timeout is the one bound, and it reports a hang.
 */
const noDeadline = { testTimeout: 0, hookTimeout: 0 };

// What a test leaves on mocks does not reach the next test, whatever order
// they run in. A project does not inherit the root config's `test`, so each
// unit project sets it.
const mocksPerTest = { clearMocks: true, restoreMocks: true };

const nodeInclude = ["{apps,packages}/**/test/**/*.test.ts", "scripts/**/*.test.ts"];
const domInclude = ["{apps,packages}/**/test/**/*.test.tsx"];
const domExclude = [...testExclude, "**/*.chromium.test.tsx"];

/**
 * A jsdom test file costs about a second before its first test (a process,
 * jsdom, React and the harness), more than most files' tests take. Files
 * that mock no module run one after another in the processes of the
 * `jsdom-shared` project (`isolate: false`), each on a fresh page with the
 * harness reset (packages/test-utils/src/setup-dom.ts). Mocked modules would
 * reach the next file of the process, so those files keep a process of their
 * own in the `jsdom` project.
 */
const moduleMock = /\bvi\.(mock|doMock|unmock|doUnmock|resetModules)\(/;
const sharedDomFiles = ["apps", "packages"]
  .flatMap((root) =>
    globSync(`${root}/**/test/**/*.test.tsx`, {
      cwd: import.meta.dirname,
      exclude: (path) => path.includes("node_modules"),
    })
  )
  .filter(
    (file) =>
      !file.endsWith(".chromium.test.tsx") &&
      !file.endsWith(".runtime.test.tsx") &&
      !moduleMock.test(readFileSync(resolve(import.meta.dirname, file), "utf8"))
  );

/**
 * Paraglide's compiled messages are one 2.6 MB module. Vite's module runner
 * rewrites and evaluates it in about half a second, once in every test file;
 * Node imports it natively in a few tens of milliseconds.
 */
const unitDependencies = {
  server: { deps: { external: [/\/packages\/i18n\/src\/paraglide\//] } },
  // Each file keeps its own process and module state. Share only the built
  // dependencies: importing one bundle avoids loading hundreds of files.
  // React Aria's public and private entries must share a build, since they
  // own the same focus scopes and interaction modality. React stays native
  // so it and React DOM keep one scheduler across bundled and native code.
  deps: {
    optimizer: {
      ssr: { enabled: true, include: ["effect"] },
      client: {
        enabled: true,
        include: [
          "effect",
          "react-aria",
          "react-aria-components",
          "react-aria/private/interactions/useFocusVisible",
        ],
        exclude: ["react", "react-dom"],
      },
    },
  },
};

/**
 * Real layout, cascade, geometry and input in headless Chromium, without an
 * app build or an E2E harness. Component styles compile as the app builds
 * them, so layout and motion assertions see the shipped CSS.
 */
/**
 * The determinism proof (determinism/manifest.txt) delays every
 * response of the test server by a random time on some runs: a test whose
 * record changes with it depends on how fast IO is.
 */
function ioDelay(): Plugin {
  const maxMs = Number(process.env.DETERMINISM_IO_DELAY_MS ?? 0);
  return {
    name: "determinism-io-delay",
    configureServer(server) {
      if (maxMs <= 0) return;
      server.middlewares.use((_request, _response, next) => {
        // The perturbation itself: real, random delays, only in proof runs.
        // ast-grep-ignore: ts-test-timer, ts-test-random
        setTimeout(next, Math.random() * maxMs);
      });
    },
  };
}

/**
 * Each dynamic import in the pages (their own code and their dependencies')
 * reports to the page while it loads (e2e/app-shell/support/child.ts,
 * `commaTrackImport`): a page knows when the modules it asked for have loaded,
 * from the imports themselves, not from how long no request was seen.
 */
function trackDynamicImports(): Plugin {
  return {
    name: "track-dynamic-imports",
    enforce: "post",
    async transform(code, id) {
      if (!/\.(m?[jt]sx?)(\?|$)/.test(id) || !code.includes("import("))
        return undefined;
      const { init, parse } = await import("es-module-lexer");
      await init;
      let imports;
      try {
        [imports] = parse(code);
      } catch {
        return undefined;
      }
      let out = code;
      for (const entry of imports.toReversed()) {
        if (entry.d < 0) continue;
        out = `${out.slice(0, entry.ss)}globalThis.commaTrackImport(${out.slice(entry.ss, entry.se)})${out.slice(entry.se)}`;
      }
      return out === code ? undefined : { code: out, map: null };
    },
  };
}

/**
 * Node built-ins that the pages' fake timers (@sinonjs/fake-timers) try when
 * they can: in the browser build they are empty, so it uses the window's own.
 */
function emptyNodeBuiltins(names: string[]): Plugin {
  const id = "\0empty-node-builtin";
  return {
    name: "empty-node-builtins",
    enforce: "pre",
    resolveId: (source) =>
      names.includes(source.replace(/^node:/, "")) ? id : undefined,
    load: (loaded) => (loaded === id ? "export default {};" : undefined),
  };
}

/** Where the browser component tests' pages are built (./e2e/app-shell/support/child.ts, ./e2e/ui-runtime/child.ts). */
// Shards that run at the same time in one checkout set their own cache
// (COMMA_VITEST_CACHE_DIR): each builds its own pages, never replacing the
// files the other's pages are loading. Or they share one build made before
// them (COMMA_APP_SHELL_PAGES=prebuilt, in COMMA_APP_SHELL_PAGES_DIR, a path
// in clients/; ./e2e/app-shell/pages.vite.config.ts builds it).
export const appShellPagesDir = process.env.COMMA_APP_SHELL_PAGES_DIR
  ? resolve(import.meta.dirname, process.env.COMMA_APP_SHELL_PAGES_DIR)
  : resolve(
      import.meta.dirname,
      "node_modules/.cache",
      `app-shell-pages${process.env.COMMA_VITEST_CACHE_DIR ? `-${basename(process.env.COMMA_VITEST_CACHE_DIR)}` : ""}`
    );

/**
 * The page each browser component test opens loads from one build of its
 * entry and the fixtures, made once per run (e2e/app-shell/support/global-setup.ts):
 * a few bundled chunks the browser keeps for the run, not hundreds of source
 * modules from the dev server for every page. COMMA_APP_SHELL_PAGES=dev loads
 * them from the dev server instead, for debugging.
 */
/** Puts ./e2e/app-shell/support/worker-seed.ts first in each worker entry of the pages build. */
function seedWorkerEntries(): Plugin {
  // In this order: the worker's seed, then the worker as a realm of its
  // page's world (./e2e/ui-runtime/worker-realm.ts).
  const preludes = [
    resolve(import.meta.dirname, "e2e/app-shell/support/worker-seed.ts"),
    resolve(import.meta.dirname, "e2e/ui-runtime/worker-realm.ts"),
  ];
  return {
    name: "seed-worker-entries",
    transform(code, id) {
      if (preludes.includes(id) || !this.getModuleInfo(id)?.isEntry) return undefined;
      return {
        code: `${preludes.map((prelude) => `import ${JSON.stringify(prelude)};`).join("\n")}\n${code}`,
        map: null,
      };
    },
  };
}

export function appShellPagesBuild() {
  return {
    configFile: false as const,
    root: import.meta.dirname,
    base: "/__pages/",
    logLevel: "warn" as const,
    plugins: [
      emptyNodeBuiltins(["timers", "timers/promises", "util"]),
      trackDynamicImports(),
      ...testTransform.plugins,
      react(),
      tailwindcss({ optimize: false }),
      localGroupSelectors(),
    ],
    // Each worker draws its random numbers from its page's seed
    // (./e2e/app-shell/support/worker-seed.ts), first thing in its entry.
    worker: {
      format: "es" as const,
      // A module a worker imports on demand reports to the worker's realm
      // while it loads (./e2e/ui-runtime/worker-realm.ts).
      plugins: () => [seedWorkerEntries(), trackDynamicImports()],
    },
    // The React users run: the production build, without development checks
    // and warnings, rendering a test's page in a fraction of the time.
    define: { "process.env.NODE_ENV": JSON.stringify("production") },
    oxc: { jsx: { runtime: "automatic" as const, development: false } },
    resolve: {
      alias: {
        "@comma/ui/styles.css": resolve(
          import.meta.dirname,
          "packages/ui/src/styles.css"
        ),
        "@comma/app/styles.css": resolve(
          import.meta.dirname,
          "packages/app/src/styles.css"
        ),
        ...testTransform.resolve.alias,
      },
    },
    build: {
      outDir: appShellPagesDir,
      emptyOutDir: true,
      cssMinify: false,
      minify: false,
      sourcemap: false,
      reportCompressedSize: false,
      // A page loads its lazy modules with its fixture (./e2e/app-shell/support/page.ts):
      // no preload links, which a later import would ask for again.
      modulePreload: false,
      rollupOptions: {
        input: {
          child: resolve(import.meta.dirname, "e2e/app-shell/support/child.ts"),
          // The page of a spec on the UI runtime.
          "runtime-child": resolve(import.meta.dirname, "e2e/ui-runtime/child.ts"),
          // What a worker of the shipped web build runs first (servedWebApp).
          "worker-prelude": resolve(
            import.meta.dirname,
            "e2e/ui-runtime/worker-prelude.ts"
          ),
        },
        preserveEntrySignatures: "exports-only" as const,
        // Dependencies' misplaced pure annotations: noise, not a fault here.
        onLog(
          level: "info" | "debug" | "warn",
          log: { code?: string },
          handler: (level: "info" | "debug" | "warn" | "error", log: never) => void
        ) {
          if (log.code === "INVALID_ANNOTATION") return;
          handler(level, log as never);
        },
        output: {
          entryFileNames: "[name].js",
          chunkFileNames: "assets/[name]-[hash].js",
          // Media keep their names: the tests' media fakes know them by name.
          assetFileNames: (asset: { names?: string[] }) =>
            /\.(webm|mp4|mov|mp3|m4a|wav|ogg)$/.test(asset.names?.[0] ?? "")
              ? "assets/[name][extname]"
              : "assets/[name]-[hash][extname]",
        },
      },
    },
  };
}

const pageContentTypes: Record<string, string> = {
  css: "text/css",
  js: "text/javascript",
  json: "application/json",
  mjs: "text/javascript",
  mp3: "audio/mpeg",
  png: "image/png",
  svg: "image/svg+xml",
  ttf: "font/ttf",
  wasm: "application/wasm",
  webm: "video/webm",
  woff: "font/woff",
  woff2: "font/woff2",
};

// Each built page file once, whole: the build does not change during a run.
const pageBodies = new Map<string, Promise<Buffer>>();
const readPage = (file: string) => {
  let body = pageBodies.get(file);
  if (!body) {
    body = import("node:fs/promises").then(({ readFile }) => readFile(file));
    pageBodies.set(file, body);
    body.catch(() => pageBodies.delete(file));
  }
  return body;
};

/** Reports a built page file that could not be read, with what the build directory holds. */
const reportMissingPage = async (file: string, error: unknown) => {
  const { readdir } = await import("node:fs/promises");
  const files = await readdir(appShellPagesDir, { recursive: true }).then(
    (names) => names.toSorted().join("\n  "),
    (listError: unknown) => `(cannot list: ${String(listError)})`
  );
  console.error(
    `[app-shell pages] cannot serve ${file}: ${String(error)}\n${appShellPagesDir} holds:\n  ${files}`
  );
};

/**
 * Every test page's document (e2e/app-shell/support/virtual-time.ts), the
 * same for every test. It is the run's origin's top, as the web app ships:
 * the relative URLs of a page's HTML, and the app's own links to `/#/…`,
 * resolve from there.
 */
const servedTestPage = {
  prefix: "/",
  exactOrigin: appShellOrigin,
  async read() {
    return {
      body: Buffer.from(
        '<!doctype html><html><head><meta charset="utf-8"><script>parent.commaPageOpening(window)</script></head><body></body></html>'
      ),
      contentType: "text/html",
    };
  },
};

/** Serves the built pages from the test server's origin, under /__pages/. */
// The built pages reach the browser through CDP, whole (vite/
// parse-failure-watch.ts, ServedFiles), never over an HTTP connection
// (refusePagesOverHttp).
/** The files of hosts outside the run a test page may show (e2e/app-shell/fixtures/external-files.ts). */
function servedExternalFiles() {
  return Object.entries(externalFiles).map(([url, file]) => {
    const { origin, pathname } = new URL(url);
    return {
      prefix: pathname,
      exactOrigin: origin,
      read: async () => ({
        body: Buffer.from(file.body),
        contentType: file.contentType,
      }),
    };
  });
}

const servedPages = {
  prefix: "/__pages/",
  async read(path: string) {
    const file = resolve(appShellPagesDir, path);
    if (!file.startsWith(appShellPagesDir)) return undefined;
    try {
      return {
        body: await readPage(file),
        contentType:
          pageContentTypes[file.split(".").at(-1) ?? ""] ?? "application/octet-stream",
      };
    } catch (error) {
      void reportMissingPage(file, error);
      return undefined;
    }
  },
};

/**
 * The shipped web build (apps/web/dist, `pnpm build:web`), for the specs that
 * run the web app itself (./e2e/app-shell/support/web-app.ts). Its files
 * reach the page as they are, but for two things the page's world needs:
 *
 * - each dynamic import reports to the page or the worker while it loads, as
 *   in the test build (trackDynamicImports);
 * - a worker's script (asked for with `workerPreludeParameter`) first imports
 *   the worker's seed and realm (./e2e/ui-runtime/worker-prelude.ts).
 */
const webAppDist = resolve(import.meta.dirname, "apps/web/dist");
const webAppBodies = new Map<string, Promise<Buffer>>();
const readWebApp = (file: string, worker: boolean) => {
  const key = `${worker ? "worker " : ""}${file}`;
  let body = webAppBodies.get(key);
  if (!body) {
    body = (async () => {
      const { readFile } = await import("node:fs/promises");
      const bytes = await readFile(file);
      if (!/\.m?js$/.test(file)) return bytes;
      const { init, parse } = await import("es-module-lexer");
      await init;
      let code = bytes.toString();
      const [imports] = parse(code);
      for (const entry of imports.toReversed()) {
        if (entry.d < 0) continue;
        code = `${code.slice(0, entry.ss)}globalThis.commaTrackImport(${code.slice(entry.ss, entry.se)})${code.slice(entry.se)}`;
      }
      if (worker) code = `import "/__pages/worker-prelude.js";\n${code}`;
      return Buffer.from(code);
    })();
    webAppBodies.set(key, body);
    body.catch(() => webAppBodies.delete(key));
  }
  return body;
};
const servedWebApp = (prefix: string) => ({
  prefix,
  async read(path: string, search: string) {
    const file = resolve(webAppDist, prefix.slice(1), path);
    if (!file.startsWith(webAppDist)) return undefined;
    try {
      return {
        body: await readWebApp(
          file,
          new URLSearchParams(search).has(workerPreludeParameter)
        ),
        contentType:
          pageContentTypes[file.split(".").at(-1) ?? ""] ?? "application/octet-stream",
      };
    } catch (error) {
      console.error(
        `[web app] cannot serve ${file}: ${String(error)}\nBuild the web app first: pnpm build:web`
      );
      return undefined;
    }
  },
});

/** What a page needs of the shipped web build's index.html to load the app as it does. */
async function webAppDocument() {
  const { readdir, readFile } = await import("node:fs/promises");
  const html = await readFile(resolve(webAppDist, "index.html"), "utf8");
  const coreWorker = (await readdir(resolve(webAppDist, "assets"))).find((name) =>
    /^core\.worker-.*\.js$/.test(name)
  );
  if (!coreWorker) throw new Error("The web build has no core worker in assets/.");
  const script = /<script type="module"[^>]* src="([^"]+)"/.exec(html)?.[1];
  if (!script) throw new Error("The web build's index.html names no module script.");
  return {
    script,
    styles: [...html.matchAll(/<link rel="stylesheet"[^>]* href="([^"]+)"/g)].map(
      (match) => match[1]!
    ),
    body: /<body>([\s\S]*)<\/body>/.exec(html)?.[1]?.trim() ?? "",
    // The root element's attributes (its inline style among them).
    root: Object.fromEntries(
      [...(/<html([^>]*)>/.exec(html)?.[1] ?? "").matchAll(/([\w-]+)="([^"]*)"/g)].map(
        (match) => [match[1]!, match[2]!]
      )
    ),
    // The client core's worker, for a spec that runs the core alone.
    coreWorker: `/assets/${coreWorker}`,
  };
}

/**
 * A built page file requested over HTTP fails: the pages reach the browser
 * only through CDP (servedPages). The request is refused, naming its
 * URL, and the page that asked for it fails to load.
 */
function refusePagesOverHttp(): Plugin {
  return {
    name: "refuse-app-shell-pages-over-http",
    configureServer(server) {
      server.middlewares.use((request, response, next) => {
        const path = request.url?.split("?")[0];
        if (!path?.startsWith("/__pages/")) {
          next();
          return;
        }
        const message = `${request.url} reached the dev server: built page files reach the browser only through CDP (vite/parse-failure-watch.ts, ServedFiles).`;
        console.error(message);
        response.writeHead(500, { "Content-Type": "text/plain" }).end(message);
      });
    },
  };
}

const browserPort = Number(process.env.COMMA_VITEST_BROWSER_PORT ?? 63315);

function browserProject(name: string, include: string[]) {
  return {
    ...testTransform,
    plugins: [
      ioDelay(),
      refusePagesOverHttp(),
      ...testTransform.plugins,
      react(),
      tailwindcss({ optimize: false }),
      localGroupSelectors(),
      noDependencySourceMapsPlugin(),
      parseFailureWatchPlugin(),
    ],
    // Fixtures load by dynamic import; scan them up front so a dependency
    // found mid-run does not reload the optimizer under running tests.
    optimizeDeps: {
      entries: [...include, "e2e/app-shell/fixtures/*/src/main.{ts,tsx}"],
      // Effect is plain ES modules; served as its own files, no response is
      // a 4 MB bundle (clients/vite/no-dependency-source-maps.ts).
      exclude: ["effect"],
    },
    // Each Vitest process commits optimized deps by replacing the cache's
    // deps directory. Processes that run at the same time in one checkout,
    // such as CI shards, set their own directory so one never deletes the
    // modules the other's page is loading.
    ...(process.env.COMMA_VITEST_CACHE_DIR
      ? { cacheDir: process.env.COMMA_VITEST_CACHE_DIR }
      : {}),
    define: { "process.env.NODE_ENV": JSON.stringify("test") },
    resolve: {
      alias: {
        "@comma/ui/styles.css": resolve(
          import.meta.dirname,
          "packages/ui/src/styles.css"
        ),
        "@comma/app/styles.css": resolve(
          import.meta.dirname,
          "packages/app/src/styles.css"
        ),
        ...testTransform.resolve.alias,
      },
    },
    test: {
      ...noDeadline,
      // While records are written (the determinism proof), the frame's
      // harness records a test's frame before the test's own cleanup
      // (e2e/app-shell/support/tester-harness.ts). A run without records keeps
      // Vitest's own order.
      ...(process.env.DETERMINISM_RECORD
        ? { sequence: { hooks: "list" as const } }
        : {}),
      name,
      include,
      exclude: testExclude,
      setupFiles: ["./e2e/app-shell/support/browser-env.ts"],
      globalSetup: ["./e2e/app-shell/support/global-setup.ts"],
      // Specs drive the page's one pointer, keyboard focus and media
      // emulation, so files take turns.
      fileParallelism: false,
      browser: {
        enabled: true,
        headless: true,
        // A window larger than any test viewport keeps the test frame unscaled,
        // so pointer coordinates and wheel deltas map one to one.
        provider: onAppShellOrigin(
          playwrightWithParseFailureWatch(
            {
              // The page's time zone and locale are the test's, not the
              // machine's: they reach what the view sends its core.
              contextOptions: {
                viewport: { width: 1920, height: 1200 },
                timezoneId: "UTC",
                locale: "en-US",
              },
              // A smooth scroll runs on the compositor's real time, which the
              // test clock does not move: scrolls land at once.
              // A worker of a test page asks the servers of its world (Node
              // realms on this machine, ./e2e/ui-runtime/node-realm.ts);
              // Chromium counts the worker as public, its script being served
              // through CDP, and would refuse it the local network.
              launchOptions: {
                args: [
                  "--disable-smooth-scrolling",
                  "--disable-features=LocalNetworkAccessChecks",
                ],
              },
            },
            [
              servedPages,
              servedTestPage,
              ...servedExternalFiles(),
              servedDynamicUiFrame(
                testTransform.resolve.alias as Record<string, string>
              ),
              servedMiniAppFrame(testTransform.resolve.alias as Record<string, string>),
              servedWebApp("/assets/"),
              servedWebApp("/brand/"),
            ]
          ),
          browserPort
        ),
        // Runs at the same time (CI shards) listen on ports of their own
        // (COMMA_VITEST_BROWSER_PORT). A taken port fails the run instead of
        // moving to the next one, where a page could load another run's files.
        api: {
          host: "127.0.0.1",
          port: browserPort,
          strictPort: true,
        },
        instances: [{ browser: "chromium" as const }],
        screenshotFailures: false,
        commands: {
          ...browserCommands,
          webAppDocument: () => webAppDocument(),
          frameQueryEngine: () =>
            frameQueryEngine(testTransform.resolve.alias as Record<string, string>),
          ...nodeRealmCommands({
            root: import.meta.dirname,
            alias: testTransform.resolve.alias,
          }),
        },
      },
    },
  };
}

/**
 * A process that runs many jsdom files keeps the modules of all of them:
 * about 350 MB stay alive between files, and V8 collects the rest only as
 * the heap nears its limit. Memory, not CPU, bounds how many run at once. On
 * the 4.8 GB hosts that run Unit Test, four of them (at any heap limit) left
 * the system compressing memory and took longer than a process per file; two
 * with this limit ran the same files in under half that time. So one
 * runs per 2 GB of memory, and no more than the machine has CPUs.
 */
const sharedDomHeapMb = 768;
const sharedDomWorkers = Math.max(
  1,
  Math.min(availableParallelism(), Math.floor(totalmem() / 2 ** 31))
);

/** A unit project of jsdom test files (vitest.config.ts `sharedDomFiles`). */
function domProject(
  name: string,
  files: { include: string[]; exclude?: string[]; isolate?: boolean }
) {
  return {
    ...testTransform,
    test: {
      ...noDeadline,
      ...mocksPerTest,
      ...unitDependencies,
      name,
      environment: "jsdom",
      // While records are written, testing-library's queries are
      // observations (packages/test-utils/src/observed-testing-library.ts).
      ...(process.env.DETERMINISM_RECORD
        ? {
            alias: [
              {
                find: /^@testing-library\/react$/,
                replacement: resolve(
                  import.meta.dirname,
                  "packages/test-utils/src/observed-testing-library.ts"
                ),
              },
            ],
          }
        : {}),
      pool: "forks" as const,
      include: files.include,
      exclude: files.exclude ?? [],
      isolate: files.isolate ?? true,
      // A worker count of its own needs a group of its own, which runs after
      // the other projects.
      ...(files.isolate === false
        ? {
            execArgv: [`--max-old-space-size=${sharedDomHeapMb}`],
            maxWorkers: sharedDomWorkers,
            sequence: { groupOrder: 1 },
          }
        : {}),
      setupFiles: [
        "./packages/test-utils/src/setup-network.ts",
        "./packages/test-utils/src/setup-clock.ts",
        "./packages/test-utils/src/setup-dom.ts",
      ],
    },
  };
}

export default defineConfig({
  ...testTransform,
  test: {
    clearMocks: true,
    restoreMocks: true,
    coverage: {
      provider: "v8",
      reporter: ["text", "lcov"],
    },
    projects: [
      // Every test file runs in a child process of its own, with modules,
      // globals and environment variables of its own: no file sees state that
      // another file left, so its result does not depend on which files ran
      // before it. (The VM pools are faster but load node_modules once per
      // worker and share them between files.) Processes, not worker threads:
      // V8 keeps WebAssembly code (undici's HTTP parser, for one) in tables
      // that every thread of a process shares, and a worker thread ending
      // while another runs crashed the whole run (Check failed: end > addr).
      {
        ...testTransform,
        test: {
          ...noDeadline,
          ...mocksPerTest,
          ...unitDependencies,
          name: "node",
          environment: "node",
          pool: "forks",
          include: nodeInclude,
          exclude: testExclude,
          globalSetup: ["./packages/test-utils/src/install-electron.ts"],
          setupFiles: [
            "./packages/test-utils/src/setup-network.ts",
            "./packages/test-utils/src/setup-node.ts",
          ],
        },
      },
      domProject("jsdom", {
        include: domInclude,
        exclude: [...domExclude, ...sharedDomFiles],
      }),
      domProject("jsdom-shared", { include: sharedDomFiles, isolate: false }),
      // The UI runtime (packages/ui/src/runtime): its services on a test
      // runtime that owns time, order, randomness, storage and loading, and
      // React on its mock scheduler, which renders only when the runtime runs
      // it.
      {
        ...testTransform,
        resolve: {
          alias: [
            { find: /^scheduler$/, replacement: mockScheduler },
            ...Object.entries(testTransform.resolve.alias).map(
              ([find, replacement]) => ({
                find,
                replacement,
              })
            ),
          ],
        },
        test: {
          ...noDeadline,
          name: "runtime-jsdom",
          environment: "jsdom",
          pool: "forks",
          include: ["{apps,packages}/**/test/**/*.runtime.test.{ts,tsx}"],
          exclude: buildExclude,
          setupFiles: [
            "./packages/test-utils/src/setup-network.ts",
            "./e2e/ui-runtime/setup-jsdom.ts",
          ],
        },
      },
      browserProject("browser", browserTestFiles),
    ],
  },
});
