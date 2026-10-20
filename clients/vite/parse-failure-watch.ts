import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import type { Page } from "@playwright/test";
import { playwright } from "@vitest/browser-playwright";
import { parseAst, type Plugin } from "vite";

// About one browser test job in ten fails to import a module with
// "SyntaxError: Unexpected token" while the dev server serves the same bytes
// to every page. When Chromium fails to parse a script, or receives a large
// module that differs from what the dev server sent, this prints Chromium's
// copy next to the dev server's, so the failing job's log shows where the two
// differ, and writes both copies to `PARSE_FAILURE_DIR` for the job to
// upload. It prints nothing otherwise.

/** Where failure reports and both copies of the module go. */
export const PARSE_FAILURE_DIR = resolve(
  import.meta.dirname,
  "../test-results/parse-failure"
);

type Served = { body: Buffer; etag: string | undefined };

/** Every distinct JavaScript body the dev server sent, by request path and sha256. */
const served = new Map<string, Map<string, Served>>();

const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");

function toBuffer(chunk: unknown, encoding: unknown): Buffer | undefined {
  if (typeof chunk === "string") {
    return Buffer.from(
      chunk,
      typeof encoding === "string" ? (encoding as BufferEncoding) : "utf8"
    );
  }
  if (chunk instanceof Uint8Array) return Buffer.from(chunk);
  return undefined;
}

/** What the dev server saw of one request on its connection. */
type Exchange = {
  port: number | undefined;
  path: string;
  /** Milliseconds since the server started. */
  at: number;
  /** The connection's `bytesWritten` when the request arrived. */
  writtenBefore: number;
  /** A response on this connection had not emitted `finish` when the request arrived. */
  overlapped: boolean;
  finishedAt?: number;
  writtenAfter?: number;
  closedEarly?: boolean;
};

/** The most recent requests the dev server saw, oldest first. */
const exchanges: Exchange[] = [];
const MAX_EXCHANGES = 20_000;
const started = Date.now();
const busy = new WeakMap<object, Exchange>();

/** Records every request's connection and every JavaScript response body with its ETag. */
export function parseFailureWatchPlugin(): Plugin {
  return {
    name: "comma:parse-failure-watch",
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        const path = req.url;
        if (!path) return next();
        // Chromium sends a request on a connection only after it has read the
        // previous response there; `overlapped` marks a request that arrived
        // before that response's `finish`.
        const socket = req.socket;
        const previous = busy.get(socket);
        const exchange: Exchange = {
          port: socket.remotePort,
          path,
          at: Date.now() - started,
          writtenBefore: socket.bytesWritten,
          overlapped: previous !== undefined,
        };
        busy.set(socket, exchange);
        exchanges.push(exchange);
        if (exchanges.length > MAX_EXCHANGES) exchanges.shift();
        res.on("finish", () => {
          exchange.finishedAt = Date.now() - started;
          exchange.writtenAfter = socket.bytesWritten;
          if (busy.get(socket) === exchange) busy.delete(socket);
        });
        res.on("close", () => {
          if (exchange.finishedAt === undefined) exchange.closedEarly = true;
          if (busy.get(socket) === exchange) busy.delete(socket);
        });
        const chunks: Buffer[] = [];
        const write = res.write;
        const end = res.end;
        res.write = function (this: typeof res, chunk: unknown, ...rest: unknown[]) {
          const bytes = toBuffer(chunk, rest[0]);
          if (bytes) chunks.push(bytes);
          return Reflect.apply(write, this, [chunk, ...rest]);
        } as typeof res.write;
        res.end = function (this: typeof res, chunk?: unknown, ...rest: unknown[]) {
          const bytes =
            typeof chunk === "function" ? undefined : toBuffer(chunk, rest[0]);
          if (bytes) chunks.push(bytes);
          if (/javascript/.test(String(res.getHeader("content-type") ?? ""))) {
            const body = Buffer.concat(chunks);
            const etag = res.getHeader("etag");
            const bodies = served.get(path) ?? new Map<string, Served>();
            bodies.set(sha256(body), {
              body,
              etag: etag === undefined ? undefined : String(etag),
            });
            served.set(path, bodies);
          }
          return Reflect.apply(end, this, [chunk, ...rest]);
        } as typeof res.end;
        next();
      });
    },
  };
}

function around(text: string, at: number) {
  return JSON.stringify(text.slice(Math.max(0, at - 160), at + 160));
}

/** Byte ranges `[start, end)` where two equally long buffers differ. */
function differingRuns(a: Buffer, b: Buffer) {
  const runs: [number, number][] = [];
  let at = 0;
  while (at < a.length) {
    if (a[at] === b[at]) {
      at++;
      continue;
    }
    const start = at;
    // A run ends at 64 equal bytes, so a stray equal byte inside foreign
    // text does not split it.
    let equal = 0;
    while (at < a.length && equal < 64) {
      equal = a[at] === b[at] ? equal + 1 : 0;
      at++;
    }
    runs.push([start, at - equal]);
  }
  return runs;
}

/** Where else the dev server sent these bytes: the body and offset they came from. */
function origin(needle: Buffer, skip: Buffer) {
  if (needle.length < 32) return undefined;
  let itself: string | undefined;
  for (const [path, bodies] of served) {
    for (const { body } of bodies.values()) {
      const at = body.indexOf(needle);
      if (at < 0) continue;
      if (body !== skip) return `${path} at byte ${at}`;
      itself = `this module itself at byte ${at}`;
    }
  }
  return itself;
}

/** The recorded response whose ETag a spliced HTTP header names. */
function etagOwner(text: string) {
  const etag = /Etag: (W\/"[^"]+")/i.exec(text)?.[1];
  if (!etag) return undefined;
  for (const [path, bodies] of served) {
    for (const entry of bodies.values()) {
      if (entry.etag === etag) return `${etag}: ${path}, ${entry.body.length} bytes`;
    }
  }
  return `${etag}: no recorded response`;
}

let reports = 0;
/** Modules already reported, so a module is reported once per process. */
const reported = new Set<string>();

type Received = { what: string; text: string };

/**
 * Reports what Chromium received or parsed for `url` next to what the dev
 * server sent, and saves both copies.
 */
async function report(url: URL, received: Received, headline: string) {
  const got = Buffer.from(received.text, "utf8");
  const path = url.pathname + url.search;
  const lines = [
    `[parse-failure] ${headline} ${url.href}`,
    `  Chromium ${received.what} ${got.length} bytes, sha256 ${sha256(got)}`,
  ];
  try {
    parseAst(received.text);
    lines.push("  Vite's parser accepts these bytes");
  } catch (error) {
    const { message, pos } = error as { message: string; pos?: number };
    lines.push(
      `  parse error at character ${pos}: ${message.split("\n")[1] ?? message}`
    );
    if (pos !== undefined)
      lines.push(`  Chromium's text there: ${around(received.text, pos)}`);
  }
  const bodies = [...(served.get(path)?.values() ?? [])];
  for (const { body } of bodies) {
    lines.push(`  dev server sent ${body.length} bytes, sha256 ${sha256(body)}`);
  }
  let sent = bodies.find(({ body }) => body.length === got.length)?.body;
  if (!bodies.length) {
    lines.push("  no recorded dev server response for this path");
    try {
      sent = Buffer.from(await (await fetch(url)).arrayBuffer());
      lines.push(`  fetched again: ${sent.length} bytes, sha256 ${sha256(sent)}`);
    } catch (error) {
      lines.push(`  fetching it again failed: ${String(error)}`);
    }
  }
  if (sent && sent.length === got.length) {
    const runs = differingRuns(got, sent);
    if (!runs.length)
      lines.push(`  the bytes Chromium ${received.what} equal the bytes served`);
    for (const [start, end] of runs.slice(0, 8)) {
      const region = got.subarray(start, end);
      lines.push(
        `  bytes ${start} to ${end} differ (${end - start} bytes)`,
        `    Chromium: ${around(got.toString("latin1"), start)}`,
        `    served:   ${around(sent.toString("latin1"), start)}`,
        `    Chromium's bytes there were also sent as ${origin(region.subarray(0, 256), sent) ?? "nothing recorded"}`
      );
      // A spliced response: its header names its ETag, and its body follows.
      const headerEnd = region.indexOf("\r\n\r\n");
      if (headerEnd >= 0) {
        const body = region.subarray(headerEnd + 4, headerEnd + 4 + 256);
        lines.push(
          `    spliced header's ETag ${etagOwner(region.subarray(0, headerEnd).toString("latin1")) ?? "missing"}`,
          `    bytes after that header were also sent as ${origin(body, sent) ?? "nothing recorded"}`
        );
      }
    }
    if (runs.length > 8) lines.push(`  and ${runs.length - 8} more differing ranges`);
  } else if (sent) {
    lines.push(`  lengths differ: Chromium ${got.length}, served ${sent.length}`);
  }
  const name = `${process.pid}-${++reports}`;
  try {
    mkdirSync(PARSE_FAILURE_DIR, { recursive: true });
    writeFileSync(join(PARSE_FAILURE_DIR, `${name}-chromium.js`), got);
    if (sent) writeFileSync(join(PARSE_FAILURE_DIR, `${name}-served.js`), sent);
    writeFileSync(
      join(PARSE_FAILURE_DIR, `${name}-server-requests.json`),
      JSON.stringify(exchanges)
    );
    writeFileSync(
      join(PARSE_FAILURE_DIR, `${name}-report.txt`),
      `${lines.join("\n")}\n`
    );
    lines.push(
      `  both copies and the dev server's recent requests are in ${PARSE_FAILURE_DIR}/${name}-*`
    );
  } catch (error) {
    lines.push(`  could not save the copies: ${String(error)}`);
  }
  console.error(lines.join("\n"));
}

/** Responses at least this large are compared with the dev server's copy on arrival. */
const COMPARE_MIN_BYTES = 1024 * 1024;

/** True when the dev server sent exactly these bytes for `url`. */
function sentAsIs(url: URL, text: string) {
  const bodies = served.get(url.pathname + url.search);
  if (!bodies) return true;
  return bodies.has(sha256(Buffer.from(text, "utf8")));
}

function failed(url: string, error: unknown) {
  console.error(`[parse-failure] could not report ${url}: ${String(error)}`);
}

async function watch(page: Page) {
  const cdp = await page.context().newCDPSession(page);
  // Large modules are read from Chromium as they finish loading: a failed
  // parse may be reported only after the page is gone.
  const scripts = new Map<string, URL>();
  cdp.on("Network.responseReceived", ({ requestId, type, response }) => {
    if (type === "Script" && /^https?:/.test(response.url)) {
      scripts.set(requestId, new URL(response.url));
    }
  });
  // A script request that fails is reported with Chromium's reason: a page
  // only learns "Failed to fetch dynamically imported module".
  const requested = new Map<string, string>();
  cdp.on("Network.requestWillBeSent", ({ requestId, request, type }) => {
    if (type === "Script") requested.set(requestId, request.url);
  });
  cdp.on(
    "Network.loadingFailed",
    ({ requestId, errorText, canceled, blockedReason }) => {
      scripts.delete(requestId);
      const url = requested.get(requestId);
      requested.delete(requestId);
      if (url)
        console.error(
          `[browser] script failed to load: ${url} (${errorText}${canceled ? ", canceled" : ""}${blockedReason ? `, blocked: ${blockedReason}` : ""})`
        );
    }
  );
  cdp.on("Network.loadingFinished", ({ requestId, encodedDataLength }) => {
    requested.delete(requestId);
    const url = scripts.get(requestId);
    scripts.delete(requestId);
    if (!url || encodedDataLength < COMPARE_MIN_BYTES) return;
    cdp
      .send("Network.getResponseBody", { requestId })
      .then(async ({ body, base64Encoded }) => {
        const text = base64Encoded
          ? Buffer.from(body, "base64").toString("utf8")
          : body;
        if (sentAsIs(url, text) || reported.has(url.href)) return;
        reported.add(url.href);
        await report(
          url,
          { what: "received", text },
          "Chromium received other bytes than the dev server sent for"
        );
      })
      .catch((error: unknown) => {
        if (!page.isClosed()) failed(url.href, error);
      });
  });
  cdp.on("Debugger.scriptFailedToParse", (event) => {
    // Code that evaluates a bad string fails without a URL; only fetched
    // modules can differ from what the dev server sent.
    if (!/^https?:/.test(event.url) || reported.has(event.url)) return;
    reported.add(event.url);
    cdp
      .send("Debugger.getScriptSource", { scriptId: event.scriptId })
      .then(({ scriptSource }) =>
        report(
          new URL(event.url),
          { what: "parsed", text: scriptSource },
          "Chromium failed to parse"
        )
      )
      .catch((error: unknown) => failed(event.url, error));
  });
  await cdp.send("Network.enable", {
    maxResourceBufferSize: 64 * 1024 * 1024,
    maxTotalBufferSize: 256 * 1024 * 1024,
  });
  // Keep only recent script sources: a failed script is read right away.
  await cdp.send("Debugger.enable", { maxScriptsCacheSize: 64 * 1024 * 1024 });
}

type OpenBrowserPage = (sessionId: string, options: unknown) => Promise<Page>;
type Internal = { openBrowserPage: OpenBrowserPage };

/**
 * The Playwright provider, with every page's script parse failures reported
 * by `parseFailureWatchPlugin`'s comparison. The watch starts before the page
 * loads anything.
 */
export function playwrightWithParseFailureWatch(
  options?: Parameters<typeof playwright>[0],
  pages?: readonly ServedFiles[]
): ReturnType<typeof playwright> {
  const base = playwright(options);
  return {
    ...base,
    providerFactory(project) {
      const provider = base.providerFactory(project);
      const internal = provider as unknown as Internal;
      const open = internal.openBrowserPage.bind(provider);
      internal.openBrowserPage = async (sessionId, pageOptions) => {
        const page = await open(sessionId, pageOptions);
        await watch(page);
        if (pages && pages.length > 0) await serveInPage(page, pages);
        return page;
      };
      return provider;
    },
  };
}

/**
 * Files the browser receives from the test run itself, not over HTTP: each
 * request under `prefix` is answered whole through CDP (Fetch.fulfillRequest),
 * from `read`. No socket carries them, so no response of theirs can be cut short
 * or interleaved with another's bytes. A media element's own load of one
 * fails: the tests' media play from fakes (e2e/app-shell/support/fake-media),
 * and an element that read its file would take its size from it on real time.
 */
export type ServedFiles = {
  prefix: string;
  /** Only the URL `origin` + `prefix` itself, its query and fragment aside: no path under it. */
  exactOrigin?: string;
  /** The file at `path` under the prefix; `search` is the request's query. */
  read(
    path: string,
    search: string
  ): Promise<
    { body: Buffer; contentType: string; headers?: Record<string, string> } | undefined
  >;
};

// The page let go of the request (its frame went away) before the answer:
// nobody waits for it.
function unlessGone(error: unknown) {
  const message = String(error);
  if (
    !message.includes("Invalid InterceptionId") &&
    !message.includes("has been closed")
  )
    throw error;
}

async function serveInPage(page: Page, sets: readonly ServedFiles[]) {
  // CDP's own interception, not Playwright's routing (which turns the HTTP
  // cache off): an immutable module the page already has comes from the
  // cache without a request, so only first loads are paused here.
  const session = await page.context().newCDPSession(page);
  session.on(
    "Fetch.requestPaused",
    (event: { requestId: string; resourceType?: string; request: { url: string } }) => {
      void (async () => {
        if (event.resourceType === "Media") {
          await session
            .send("Fetch.failRequest", {
              requestId: event.requestId,
              errorReason: "Aborted",
            })
            .catch(unlessGone);
          return;
        }
        const url = new URL(event.request.url);
        const files = sets.find(({ prefix, exactOrigin }) =>
          exactOrigin
            ? url.origin === exactOrigin && url.pathname === prefix
            : url.pathname.startsWith(prefix)
        );
        // A pattern matches anywhere in a URL: another path is the server's.
        if (!files) {
          await session
            .send("Fetch.continueRequest", { requestId: event.requestId })
            .catch(unlessGone);
          return;
        }
        const file = await files.read(
          url.pathname.slice(files.prefix.length),
          url.search
        );
        await session
          .send(
            "Fetch.fulfillRequest",
            file
              ? {
                  requestId: event.requestId,
                  responseCode: 200,
                  responseHeaders: [
                    { name: "Content-Type", value: file.contentType },
                    { name: "Cache-Control", value: "max-age=86400, immutable" },
                    { name: "Content-Length", value: String(file.body.byteLength) },
                    ...Object.entries(file.headers ?? {}).map(([name, value]) => ({
                      name,
                      value,
                    })),
                  ],
                  body: file.body.toString("base64"),
                }
              : { requestId: event.requestId, responseCode: 404, responseHeaders: [] }
          )
          .catch(unlessGone);
      })();
    }
  );
  await session.send("Fetch.enable", {
    patterns: sets.map(({ prefix, exactOrigin }) => ({
      urlPattern: exactOrigin ? `${exactOrigin}${prefix}` : `*${prefix}*`,
      requestStage: "Request" as const,
    })),
  });
}
