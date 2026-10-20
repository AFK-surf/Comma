// A Node process as a realm of a world (packages/test-utils/src/world): a
// stub server, later a process of the app. Runs first in the process
// (./node-realm-host.ts builds it in front of the realm's entry), so the
// entry's modules find the routed host functions:
//
// - Its timers and clock are the realm's runtime's: they run on world time.
// - Its HTTP servers answer requests as messages (./realm-http.ts): a request
//   is held until the world hands it over, and the head, each write and the
//   end of its response are reported to the world. The server's handler gets
//   the whole request and a response whose state follows what the handler
//   did, not what the connection has flushed.
// - What it would do outside the schedule is a violation, and fails the
//   world: a request from outside the world, a response written while the
//   realm rests, file or network IO of its own.
//
// The world reaches it over the process's IPC channel.

import { createHook } from "node:async_hooks";
import { EventEmitter } from "node:events";
import http from "node:http";
import type { AddressInfo } from "node:net";
import { syncBuiltinESMExports } from "node:module";
import { Readable } from "node:stream";
import timers from "node:timers";
import { testEpoch } from "@comma/test-utils/test-epoch";
import type { RealmReport } from "@comma/test-utils/world/world";
import {
  createTestUiRuntime,
  installTestUiHost,
  realHost,
} from "../../packages/ui/src/runtime/test/testing";
import { createRealm } from "./realm";
import { lateNotice, type HttpMessage } from "./realm-http";
import {
  worldAgainHeader,
  worldLostParameter,
  worldRequestParameter,
} from "./realm-names";

/** What a realm's entry module exports as default: starts the realm's servers. */
export type NodeRealmStart = (
  options: never
) => NodeRealmEntry | Promise<NodeRealmEntry>;
export type NodeRealmEntry = {
  /** What the test needs to reach the realm (its servers' origins). */
  info?: unknown;
  /** What the test may call in the realm; each runs as the realm's code and returns at once. */
  calls?: Record<string, (...args: never[]) => unknown>;
};

/** The world's calls, and the realm's answers, on the IPC channel. */
export type NodeRealmCall =
  | { call: number; op: "settle"; now: number }
  | { call: number; op: "deliver"; from: string; id: number; detail?: unknown }
  | { call: number; op: "call"; name: string; args: unknown[] }
  /** The test is over: answers what the realm did outside the schedule since it last ran. */
  | { call: number; op: "close" }
  | { call: number; op: "forget" };
export type NodeRealmReply =
  | { ready: true; info: unknown; delayMs: number; ports: number[] }
  | { reply: number; value?: unknown; error?: string };

installTestUiHost();
// A timer the process's code takes from the module is the global one.
Object.assign(timers, {
  // ast-grep-ignore: ts-test-timer -- the routed timer: the realm's runtime's.
  setTimeout: (...args: Parameters<typeof setTimeout>) => setTimeout(...args),
  // ast-grep-ignore: ts-test-timer -- the routed timer: the realm's runtime's.
  setInterval: (...args: Parameters<typeof setInterval>) => setInterval(...args),
  clearTimeout: (id: never) => clearTimeout(id),
  clearInterval: (id: never) => clearInterval(id),
});
syncBuiltinESMExports();

const options = JSON.parse(process.argv[2] ?? "{}") as {
  seed?: number;
  start?: unknown;
  origin?: string;
};

/**
 * The origin the pages reach the realm's server at, whatever port it listens
 * on (vite/app-shell-origin.ts): what its answers name as its own.
 */
export function realmOrigin(): string {
  if (!options.origin) throw new Error("The realm was started without an origin.");
  return options.origin;
}
const delayMs = Number(process.env.DETERMINISM_IO_DELAY_MS ?? 0);
const runtime = createTestUiRuntime({ seed: options.seed ?? 0, start: testEpoch });
const realm = createRealm(runtime, {
  advance: (ms) => runtime.advance(ms),
  rest: () => runtime.flush(),
});

// The realm's code runs only while the world settles it or the test calls it.
let running = false;
const violations: string[] = [];
const violation = (text: string) => {
  violations.push(text);
};
const failure = (error: unknown) =>
  error instanceof Error ? (error.stack ?? error.message) : String(error);
(globalThis as { reportError?: (error: unknown) => void }).reportError = (error) =>
  violation(`The realm's code threw: ${failure(error)}`);
process.on("uncaughtException", (error) =>
  violation(`The realm's code threw: ${failure(error)}`)
);
process.on("unhandledRejection", (error) =>
  violation(`A promise of the realm's code rejected: ${failure(error)}`)
);
// IO the realm's code starts for itself completes when the machine decides.
const unscheduled =
  /^(FS|GETADDRINFO|GETNAMEINFO|QUERYWRAP|TCPCONNECT|PIPECONNECT|PROCESS|UDP)/;
createHook({
  init(_id, type) {
    if (running && unscheduled.test(type))
      violation(`The realm's code started IO of its own (${type}).`);
  },
}).enable();
const setImmediateRouted = (work: (...args: unknown[]) => void, ...args: unknown[]) =>
  // ast-grep-ignore: ts-test-timer -- the routed timer: the realm's runtime's.
  setTimeout(work, 0, ...args);
Object.assign(globalThis, {
  setImmediate: setImmediateRouted,
  clearImmediate: clearTimeout,
});

// --- HTTP servers -----------------------------------------------------------

type Held = {
  server: http.Server;
  request: http.IncomingMessage;
  response: http.ServerResponse;
  url: string;
  body: Buffer;
};
const arrived = new Map<string, Held>();
// The connections the realm keeps: on each, a request that arrives, one the
// realm holds for its turn, or an answer its server has not ended. The value
// says which, for the failure of an arrival.
const kept = new Map<http.ServerResponse, { what: string; state: string }>();
// The connections a browser opens to one host at once (Chromium's limit).
const browserConnections = 6;
// Real time, and only to fail: a request on its way arrives in milliseconds.
const arrivalLimitMs = 20_000;
const awaited = new Map<string, { arrived(): void; lost(why: string): void }>();
// The requests that reached the realm, those it sent back aside.
const reached = new Set<string>();
// The requests the browser failed before they reached the realm
// (./realm-http.ts), each with the browser's failure.
const lost = new Map<string, string>();
// The real-time limits of the arrivals awaited, by request.
const arrivalLimits = new Map<string, ReturnType<typeof setTimeout>>();
const aborts = new Map<string, () => void>();
const notice = lateNotice(delayMs);
const named = new RegExp(`[?&]${worldRequestParameter}=([^&]+)$`);

// The ports the realm's servers listen on: the run's proxy carries the
// realm's origin to them.
const listeningPorts: number[] = [];
const serverEmit = http.Server.prototype.emit as (
  this: http.Server,
  event: string,
  ...args: unknown[]
) => boolean;
http.Server.prototype.emit = function (
  this: http.Server,
  event: string,
  ...args: unknown[]
) {
  if (event === "listening") listeningPorts.push((this.address() as AddressInfo).port);
  if (event !== "request") return serverEmit.call(this, event, ...args);
  hold(this, args[0] as http.IncomingMessage, args[1] as http.ServerResponse);
  return true;
} as typeof http.Server.prototype.emit;

// The requests whose connection the realm's server dropped before the end.
const failedRequests = new Set<string>();

const corsOf = (request: http.IncomingMessage) => ({
  "access-control-allow-origin": request.headers.origin ?? "*",
  "access-control-allow-credentials": "true",
  vary: "origin",
});

function hold(
  server: http.Server,
  request: http.IncomingMessage,
  response: http.ServerResponse
) {
  const cors = corsOf(request);
  // A preflight is the browser's, sent when it decides: the realm's server
  // does not see it.
  if (
    request.method === "OPTIONS" &&
    request.headers["access-control-request-method"]
  ) {
    response
      .writeHead(204, {
        ...cors,
        "access-control-allow-methods":
          request.headers["access-control-request-method"],
        "access-control-allow-headers":
          request.headers["access-control-request-headers"] ?? "",
        "access-control-allow-private-network": "true",
        "access-control-max-age": "600",
      })
      .end();
    return;
  }
  const key = named.exec(request.url ?? "")?.[1];
  // The browser failed the request `key` before any answer, its realm says
  // (./realm-http.ts): unless the request reached the realm, the world fails
  // with the browser's failure where it would wait for the request.
  if (key && request.url?.startsWith(`/?${worldLostParameter}&`)) {
    const why: Buffer[] = [];
    request.on("data", (chunk: Buffer) => why.push(chunk));
    request.on("end", () => {
      response.writeHead(204, cors).end();
      if (reached.has(key)) return;
      lost.set(key, Buffer.concat(why).toString());
      awaited.get(key)?.lost(lost.get(key)!);
    });
    return;
  }
  // The browser sends a GET again when its connection closed without an
  // answer: the world already handed the failure over, so the repeat fails too.
  if (key && failedRequests.has(key)) {
    request.socket.destroy();
    return;
  }
  if (!key) {
    violation(
      `${request.method} ${request.url} reached the realm from outside the world.`
    );
    response.writeHead(500, cors).end("This server is a realm of a world.");
    return;
  }
  const url = (request.url ?? "").replace(named, "");
  reached.add(key);
  const connection = { what: `${key} (${request.method} ${url})`, state: "arriving" };
  kept.set(response, connection);
  response.once("close", () => kept.delete(response));
  const chunks: Buffer[] = [];
  request.on("data", (chunk: Buffer) => chunks.push(chunk));
  request.on("end", () =>
    notice(() => {
      connection.state = "held for its turn";
      arrived.set(key, { server, request, response, url, body: Buffer.concat(chunks) });
      awaited.get(key)?.arrived();
      awaited.delete(key);
      makeRoom();
    })
  );
  // A request that fails on its way never arrives: its realm aborted it.
  request.on("error", () => {});
}

/**
 * The browser decides which of its requests take its connections to the
 * realm, and in what order: a request it sends late, or again (its connection
 * closed as the request was written to it), waits behind the others. The
 * realm answers in the world's order. So while it waits for a request and
 * keeps every connection the browser opens, the request cannot come: the
 * realm sends back the request that reached it last, ahead of its turn. Its
 * realm sends it again (./realm-http.ts), behind the one awaited.
 */
function makeRoom() {
  if (awaited.size === 0) return;
  while (kept.size >= browserConnections) {
    // Not a request whose realm cannot read the answer's headers (`no-cors`):
    // it would take the answer for the server's.
    const last = [...arrived].findLast(
      ([, held]) => held.request.headers["sec-fetch-mode"] !== "no-cors"
    );
    if (!last) return;
    const [key, { request, response }] = last;
    arrived.delete(key);
    reached.delete(key);
    kept.delete(response);
    response
      .writeHead(425, {
        ...corsOf(request),
        "access-control-expose-headers": worldAgainHeader,
        "cache-control": "no-store",
        [worldAgainHeader]: "1",
      })
      .end();
  }
}

const text = (chunk: unknown) =>
  JSON.stringify(
    (typeof chunk === "string"
      ? chunk
      : Buffer.from(chunk as Uint8Array).toString()
    ).slice(0, 40)
  );
const size = (chunk: unknown, encoding: unknown) =>
  typeof chunk === "string"
    ? Buffer.byteLength(
        chunk,
        typeof encoding === "string" ? (encoding as BufferEncoding) : "utf8"
      )
    : ((chunk as Uint8Array | null | undefined)?.byteLength ?? 0);
const parts = (args: unknown[]) => {
  const callback = args.findLast((argument) => typeof argument === "function") as
    | (() => void)
    | undefined;
  const [chunk, encoding] = args.filter((argument) => typeof argument !== "function");
  return { chunk, encoding, callback };
};
const logical = new Set(["close", "finish", "drain", "error"]);
const listening = new Set([
  "on",
  "once",
  "addListener",
  "prependListener",
  "prependOnceListener",
]);

/** Runs the server's handler on a request the world handed over. */
function answer(from: string, key: string, held: Held) {
  const { server, request, response } = held;
  const label = `${request.method} ${held.url}`;
  const send = (kind: HttpMessage["kind"], what: string, bytes?: number) => {
    if (!running) violation(`${what} was sent while the world held the realm at rest.`);
    realm.send(from, what, {
      carrier: "http",
      request: key,
      kind,
      ...(bytes === undefined ? {} : { bytes }),
    });
  };
  // The handler's request: the whole of it, as it arrived.
  const replay = Object.assign(new Readable({ read() {} }), {
    method: request.method,
    url: held.url,
    headers: request.headers,
    rawHeaders: request.rawHeaders,
    httpVersion: request.httpVersion,
    httpVersionMajor: request.httpVersionMajor,
    httpVersionMinor: request.httpVersionMinor,
    socket: request.socket,
    connection: request.socket,
    complete: true,
    aborted: false,
    trailers: {},
  });
  replay.push(held.body);
  replay.push(null);

  // The handler's response: what the handler did decides its state and its
  // events, at once; the connection only carries the bytes.
  const events = new EventEmitter();
  let headSent = false;
  let bytes = 0;
  let ended = false;
  let finished = false;
  let closed = false;
  let flushed = Promise.resolve();
  const close = () => {
    if (closed) return;
    closed = true;
    aborts.delete(key);
    events.emit("close");
  };
  const head = () => {
    if (headSent) return;
    headSent = true;
    send("head", `${response.statusCode} ${label}`);
  };
  const write = (chunk: unknown, encoding: unknown) => {
    flushed = new Promise<void>((resolve) => {
      response.write(chunk as string, (encoding ?? "utf8") as BufferEncoding, () =>
        resolve()
      );
    });
  };
  const overrides: Record<string, unknown> = {
    write(...args: unknown[]) {
      const { chunk, encoding, callback } = parts(args);
      if (ended || closed) return true;
      head();
      const length = size(chunk, encoding);
      if (length > 0) {
        bytes += length;
        send("chunk", `${text(chunk)} of ${label}`, bytes);
        write(chunk, encoding);
      }
      if (callback) runtime.task.post(callback);
      return true;
    },
    end(...args: unknown[]) {
      const { chunk, encoding, callback } = parts(args);
      if (ended || closed) return proxy;
      ended = true;
      const length = size(chunk, encoding);
      bytes += length;
      if (!headSent) {
        headSent = true;
        send("whole", `${response.statusCode} ${label}`);
      } else {
        if (length > 0) send("chunk", `${text(chunk)} of ${label}`, bytes);
        send("end", `end of ${label}`);
      }
      if (length > 0)
        response.end(chunk as string, (encoding ?? "utf8") as BufferEncoding);
      else response.end();
      runtime.task.post(() => {
        finished = true;
        events.emit("finish");
        close();
        callback?.();
      });
      return proxy;
    },
    flushHeaders() {
      if (ended || closed) return;
      head();
      response.flushHeaders();
    },
    destroy(error?: Error) {
      if (closed) return proxy;
      if (!ended) {
        failedRequests.add(key);
        send("failed", `failure of ${label}`);
      }
      ended = true;
      // After what was written left: the other realm receives all of it.
      void flushed.then(() => response.destroy(error));
      runtime.task.post(close);
      return proxy;
    },
  };
  const state: Record<string, () => unknown> = {
    destroyed: () => closed,
    closed: () => closed,
    writableEnded: () => ended,
    writableFinished: () => finished,
    finished: () => ended,
  };
  const proxy: http.ServerResponse = new Proxy(response, {
    get(target, property) {
      if (typeof property === "string") {
        if (property in overrides) return overrides[property];
        if (property in state) return state[property]!();
      }
      const value = Reflect.get(target, property, target) as unknown;
      if (typeof value !== "function") return value;
      return (...args: unknown[]) => {
        const event = args[0];
        // The response's own events follow the handler, not the connection.
        const emitter =
          typeof property === "string" &&
          typeof event === "string" &&
          logical.has(event) &&
          (listening.has(property) ||
            property === "off" ||
            property === "removeListener")
            ? events
            : target;
        const result = (
          emitter as unknown as Record<PropertyKey, (...a: unknown[]) => unknown>
        )[property]!(...args);
        return result === emitter ? proxy : result;
      };
    },
  });
  // The requesting realm aborted: the connection closes here, as the world
  // hands the abort over.
  aborts.set(key, () => {
    if (closed) return;
    ended = true;
    close();
    if (!replay.destroyed) {
      replay.aborted = true;
      replay.emit("aborted");
      replay.destroy();
    }
    void flushed.then(() => response.destroy());
  });
  serverEmit.call(server, "request", replay, proxy);
}

realm.carry("http", async (from, detail: HttpMessage) => {
  const key = detail.request;
  if (detail.kind === "request") {
    // A browser sends a server only so many requests at once: this one may
    // leave it only when the server answered one before it.
    const failed = (why: string) =>
      new Error(
        `Request ${key} (${detail.label}) of ${from} did not reach the realm: the browser failed it (${why}).`
      );
    const here = async () => {
      if (arrived.has(key)) return;
      if (lost.has(key)) throw failed(lost.get(key)!);
      await new Promise<void>((resolve, reject) => {
        // A request that is not on its way never arrives (the browser refused
        // it, the realm that made it is gone): the world would wait for ever.
        // ast-grep-ignore: ts-test-timer -- real time, only to fail the test.
        const limit = realHost().setTimeout(
          () =>
            reject(
              new Error(
                [
                  `Request ${key} (${detail.label}) of ${from} did not reach the realm in ${arrivalLimitMs / 1000} s: it is not on its way.`,
                  `The realm keeps ${kept.size} connections${kept.size >= browserConnections ? ", all a browser opens to it" : ""}:`,
                  ...[...kept.values()].map(({ what, state }) => `  ${what}: ${state}`),
                ].join("\n")
              )
            ),
          arrivalLimitMs
        );
        arrivalLimits.set(key, limit);
        const over = () => {
          realHost().clearTimeout(limit);
          arrivalLimits.delete(key);
        };
        awaited.set(key, {
          arrived() {
            over();
            resolve();
          },
          lost(why) {
            over();
            awaited.delete(key);
            reject(failed(why));
          },
        });
        makeRoom();
      });
    };
    return {
      arrived: here,
      run() {
        const held = arrived.get(key)!;
        arrived.delete(key);
        const connection = kept.get(held.response);
        if (connection) connection.state = "its answer is open";
        answer(from, key, held);
      },
    };
  }
  if (detail.kind === "abort") return () => aborts.get(key)?.();
  throw new Error(`An answering realm receives no ${detail.kind}.`);
});

// --- the world's calls ------------------------------------------------------

async function run<T>(work: () => T | Promise<T>): Promise<T> {
  running = true;
  try {
    const result = await work();
    if (violations.length > 0) throw new Error(violations.splice(0).join("\n"));
    return result;
  } finally {
    running = false;
  }
}

const post = (message: NodeRealmReply) => process.send!(message);

/** Starts the realm's entry, then answers the world. */
export async function serveNodeRealm(start: NodeRealmStart) {
  // The entry starts on real time: its servers listen when the machine says.
  const entry = await start((options.start ?? {}) as never);
  runtime.install();
  process.on("message", (message: NodeRealmCall) => {
    let done: Promise<unknown>;
    if (message.op === "settle")
      done = run<RealmReport>(() => realm.control.settle(message.now));
    else if (message.op === "deliver")
      done = realm.control.deliver(message.from, message.id, message.detail);
    else if (message.op === "close") done = Promise.resolve(violations.splice(0));
    else if (message.op === "forget")
      // The page that made the requests in flight closed: their connections
      // close, as the browser closes them, and what was on its way is gone.
      done = run(() => {
        for (const abort of aborts.values()) abort();
        aborts.clear();
        for (const held of arrived.values()) held.response.destroy();
        arrived.clear();
        for (const limit of arrivalLimits.values()) realHost().clearTimeout(limit);
        arrivalLimits.clear();
        awaited.clear();
        reached.clear();
        lost.clear();
        realm.control.forget?.();
      });
    else
      done = run(() => {
        const call = entry.calls?.[message.name] as
          | ((...args: unknown[]) => unknown)
          | undefined;
        if (!call) throw new Error(`The realm has no call "${message.name}".`);
        return call(...message.args);
      });
    done.then(
      (value) => post({ reply: message.call, value }),
      (error: unknown) => post({ reply: message.call, error: failure(error) })
    );
  });
  post({ ready: true, info: entry.info, delayMs, ports: listeningPorts });
}
