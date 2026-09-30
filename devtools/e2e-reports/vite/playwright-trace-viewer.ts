import {
  createReadStream,
  existsSync,
  readdirSync,
  readFileSync,
  statSync,
} from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import type { Plugin } from "vite";

const traceViewerBasePath = "/e2e-reports/trace-viewer";
const traceViewerAssetPrefix = "e2e-reports/trace-viewer";
const requiredTraceViewerFiles = [
  "index.html",
  "snapshot.html",
  "sw.bundle.js",
  "manifest.webmanifest",
];
const emittedTraceViewerKey: symbol = Symbol.for(
  "comma.e2eReports.traceViewerEmitted",
);
const emittedTraceViewerState = globalThis as typeof globalThis &
  Record<symbol, boolean | undefined>;

function assertTraceViewerSource(source: string) {
  if (!existsSync(source) || !statSync(source).isDirectory()) {
    throw new Error(`Playwright trace viewer source not found: ${source}`);
  }

  for (const file of requiredTraceViewerFiles) {
    const target = path.join(source, file);
    if (!existsSync(target) || !statSync(target).isFile()) {
      throw new Error(`Playwright trace viewer is missing ${file}: ${source}`);
    }
  }
}

function resolveTraceViewerSource() {
  const require = createRequire(import.meta.url);
  const packageJsonPath = require.resolve("playwright-core/package.json");
  const packageRoot = path.dirname(packageJsonPath);
  return path.join(packageRoot, "lib", "vite", "traceViewer");
}

function listFiles(root: string, directory = root): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const absolutePath = path.join(directory, entry.name);
    if (entry.isDirectory()) return listFiles(root, absolutePath);
    return path.relative(root, absolutePath).split(path.sep).join("/");
  });
}

function contentType(filePath: string) {
  if (filePath.endsWith(".css")) return "text/css; charset=utf-8";
  if (filePath.endsWith(".html")) return "text/html; charset=utf-8";
  if (filePath.endsWith(".js")) return "text/javascript; charset=utf-8";
  if (filePath.endsWith(".json") || filePath.endsWith(".webmanifest"))
    return "application/json; charset=utf-8";
  if (filePath.endsWith(".svg")) return "image/svg+xml";
  if (filePath.endsWith(".ttf")) return "font/ttf";
  return "application/octet-stream";
}

function resolveRequestPath(url = "") {
  const pathname = new URL(url, "http://localhost").pathname;
  if (
    pathname === traceViewerBasePath ||
    pathname === `${traceViewerBasePath}/`
  ) {
    return "index.html";
  }

  if (!pathname.startsWith(`${traceViewerBasePath}/`)) return null;
  return decodeURIComponent(pathname.slice(traceViewerBasePath.length + 1));
}

export function playwrightTraceViewer(): Plugin {
  const traceViewerSource = resolveTraceViewerSource();
  assertTraceViewerSource(traceViewerSource);

  return {
    name: "playwright-trace-viewer",
    configureServer(server) {
      server.middlewares.use((request, response, next) => {
        const relativePath = resolveRequestPath(request.url);
        if (!relativePath) {
          next();
          return;
        }

        const filePath = path.resolve(traceViewerSource, relativePath);
        if (
          !filePath.startsWith(`${traceViewerSource}${path.sep}`) ||
          !existsSync(filePath) ||
          !statSync(filePath).isFile()
        ) {
          next();
          return;
        }

        response.setHeader("Content-Type", contentType(filePath));
        createReadStream(filePath).pipe(response);
      });
    },
    generateBundle(options) {
      if (
        !options.dir ||
        path.basename(options.dir) !== "client" ||
        emittedTraceViewerState[emittedTraceViewerKey]
      )
        return;
      emittedTraceViewerState[emittedTraceViewerKey] = true;

      for (const file of listFiles(traceViewerSource)) {
        this.emitFile({
          type: "asset",
          fileName: `${traceViewerAssetPrefix}/${file}`,
          source: readFileSync(path.join(traceViewerSource, file)),
        });
      }
    },
  };
}
