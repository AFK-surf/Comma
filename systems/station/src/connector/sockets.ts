// The WebSocket client as a service, so the connection to Salix can be replaced by an in-memory one in tests.
import type { Agent } from "node:http";
import { Context, Duration, Effect, Exit, Layer } from "effect";
import { HttpsProxyAgent } from "https-proxy-agent";
import WebSocket from "ws";
import { log } from "../ops/log.ts";
import { readBinaryStreamFrame } from "./message.ts";
import { AuthError, WebSocketHandshakeError } from "./status.ts";

const HANDSHAKE_BODY_LIMIT = 4096;
/** A dial through a proxy completes within this, or is given up: the direct dial has the rest of the connector's dial timeout. */
export const PROXY_DIAL_TIMEOUT = Duration.seconds(10);

/** A connected JSON WebSocket. `receive` fails once the peer closed. */
export type JsonSocket = {
  send(frame: unknown): Effect.Effect<void, Error>;
  /** A binary frame (packets through Salix). */
  sendBinary?(data: Buffer): Effect.Effect<void, Error>;
  /** Where binary frames that come go (none: dropped). */
  onBinary?(handler: (data: Buffer) => void): void;
  readonly receive: Effect.Effect<any, Error>;
  readonly ping: Effect.Effect<void>;
  readonly close: Effect.Effect<void>;
};

export class Sockets extends Context.Service<
  Sockets,
  {
    /** `proxy` (an http or https URL) is tried first; when it does not reach Salix the dial is made again directly. */
    dial(url: string, headers: Record<string, string>, proxy?: string): Effect.Effect<JsonSocket, Error>;
  }
>()("station/Sockets") {}

const toError = (e: unknown) => (e instanceof Error ? e : new Error(String(e)));

/** A `ws` socket (open, or opening) as a JSON socket: frames parsed as they come, sends in order. */
export function jsonSocketOf(ws: WebSocket): JsonSocket {
  const inbox: unknown[] = [];
  const waiters: Array<(frame: { ok: true; value: unknown } | { ok: false; error: Error }) => void> = [];
  let ended: Error | null = null;
  const deliver = (item: { ok: true; value: unknown } | { ok: false; error: Error }) => {
    const waiter = waiters.shift();
    if (waiter) waiter(item);
    else if (item.ok) inbox.push(item.value);
  };
  let binary: ((data: Buffer) => void) | null = null;
  ws.on("message", (data, isBinary) => {
    if (isBinary) {
      const frame = Buffer.isBuffer(data) ? data : Buffer.concat(data as Buffer[]);
      // A stream frame with its bytes comes in order with the JSON frames; any other binary frame is a packet.
      let message;
      try {
        message = readBinaryStreamFrame(frame);
      } catch (e) {
        deliver({ ok: false, error: toError(e) });
        return;
      }
      if (message) deliver({ ok: true, value: message });
      else binary?.(frame);
      return;
    }
    try {
      deliver({ ok: true, value: JSON.parse(data.toString()) });
    } catch (e) {
      deliver({ ok: false, error: toError(e) });
    }
  });
  ws.on("close", () => {
    ended ??= new Error("socket closed");
    for (const waiter of waiters.splice(0)) waiter({ ok: false, error: ended });
  });
  ws.on("error", (error) => {
    ended ??= error;
  });
  const socket: JsonSocket = {
    send: (frame) =>
      Effect.callback<void, Error>((done) => {
        if (ended) return done(Effect.fail(ended));
        ws.send(JSON.stringify(frame), (error) => done(error ? Effect.fail(error) : Effect.void));
      }),
    receive: Effect.callback<unknown, Error>((done) => {
      if (inbox.length) return done(Effect.succeed(inbox.shift()));
      if (ended) return done(Effect.fail(ended));
      waiters.push((item) => done(item.ok ? Effect.succeed(item.value) : Effect.fail(item.error)));
    }),
    sendBinary: (data) =>
      Effect.callback<void, Error>((done) => {
        if (ended) return done(Effect.fail(ended));
        ws.send(data, { binary: true }, (error) => done(error ? Effect.fail(error) : Effect.void));
      }),
    onBinary: (handler) => void (binary = handler),
    ping: Effect.sync(() => ws.ping()),
    close: Effect.sync(() => ws.close()),
  };
  return socket;
}

/** One WebSocket to `url`: direct, or through `agent`. */
const open = (url: string, headers: Record<string, string>, agent?: Agent) =>
  Effect.callback<JsonSocket, Error>((resume) => {
    const ws = new WebSocket(url, { headers, maxPayload: 16 * 1024 * 1024, ...(agent ? { agent } : {}) });
    const opened = new Promise<void>((resolve, reject) => {
      ws.once("open", () => resolve());
      ws.once("error", reject);
      // A refused credential (401, 403) is an AuthError: the app mints another on `auth_required`.
      ws.once("unexpected-response", (_request, response) => {
        const chunks: Buffer[] = [];
        let size = 0;
        const settle = () => {
          const body = Buffer.concat(chunks).toString("utf8");
          const status = response.statusCode ?? 0;
          reject(status === 401 || status === 403 ? new AuthError(status, body) : new WebSocketHandshakeError(status, body));
          ws.terminate();
        };
        response.on("data", (chunk: Buffer) => {
          if (size < HANDSHAKE_BODY_LIMIT) chunks.push(chunk.subarray(0, HANDSHAKE_BODY_LIMIT - size));
          size += chunk.length;
        });
        response.once("end", settle);
        response.once("error", settle);
      });
    });
    const socket = jsonSocketOf(ws);
    opened.then(
      () => resume(Effect.succeed(socket)),
      (error) => resume(Effect.fail(toError(error))),
    );
    // A dial given up before it completed (the connector's dial timeout) closes its connection, half-open or not.
    return Effect.sync(() => ws.terminate());
  });

/**
 * Through the proxy first. Salix's own answer through the tunnel stands (a refused credential, a refused upgrade).
 * Anything else is the proxy's failure (it is not there, it refused the tunnel, nothing came through it in time), and
 * the dial is made again directly, as it is without a proxy: a proxy that went away never keeps the station offline.
 */
const openThrough = (proxy: string, url: string, headers: Record<string, string>, within: Duration.Duration) =>
  Effect.suspend(() => {
    // An attempt that is given up also closes its connection to the proxy. While the proxy has not answered CONNECT the
    // request has no socket yet, so neither a request timeout nor closing the WebSocket reaches that connection.
    const givenUp = new AbortController();
    const agent = new HttpsProxyAgent(proxy, { signal: givenUp.signal });
    // The proxy's answer to CONNECT: only after its 200 does a response come from Salix. A refusal of its own (a 403,
    // a 407) comes back as the request's response, and is not Salix refusing the credential.
    let tunneled = false;
    agent.on("proxyConnect", (response: { statusCode?: number }) => void (tunneled = response.statusCode === 200));
    return open(url, headers, agent).pipe(
      Effect.timeoutOrElse({
        duration: within,
        orElse: () => Effect.fail(new Error(`nothing came through the proxy in ${Duration.toSeconds(within)} seconds`)),
      }),
      Effect.onExit((exit) => Effect.sync(() => void (Exit.isSuccess(exit) || givenUp.abort()))),
      Effect.tap(() => Effect.sync(() => log.info("connector", "dialed Salix through the proxy", { proxy: agent.proxy.host }))),
      Effect.catch((error: Error) => {
        if (tunneled && (error instanceof AuthError || error instanceof WebSocketHandshakeError)) return Effect.fail(error);
        log.warn("connector", "the proxy did not reach Salix; dialing directly", { proxy: agent.proxy.host, error: error.message });
        return open(url, headers);
      }),
    );
  });

/** Real sockets (the `ws` package); `proxyDialTimeout` is a test's shorter wait for a proxy. */
export const makeLiveSockets = (options: { proxyDialTimeout?: Duration.Duration } = {}) =>
  Layer.succeed(Sockets)({
    dial: (url, headers, proxy) => (proxy ? openThrough(proxy, url, headers, options.proxyDialTimeout ?? PROXY_DIAL_TIMEOUT) : open(url, headers)),
  });

export const liveSockets = makeLiveSockets();
