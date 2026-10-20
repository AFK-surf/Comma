// HTTP between realms of a world (packages/test-utils/src/world). A request
// and each part of its response are messages: the world hands them over one
// at a time, in the order they were sent. The bytes still go over the wire,
// from a real `fetch` to a real server; the wire only decides how long the
// world waits for a message it hands over, not when the message runs.
//
// - The requesting realm (a page, a worker) reports a request when its code
//   calls `fetch`, and names it in the request's URL.
// - The answering realm (./node-realm.ts) holds the request until the world
//   hands it over, then reports the response's head, each write and its end.
// - The requesting realm holds what arrives, and gives its code the head, the
//   bytes of each write and the end as the world hands them over.
// - A request its realm aborts is over for the realm at once; the answering
//   realm learns it as a message and closes the connection then.
// - The browser decides when a request leaves it. The answering realm sends
//   back, unanswered, a request that reached it ahead of its turn when it
//   keeps every connection the browser opens and waits for another: the
//   requesting realm sends it again.
// - A request the browser fails before any answer may never have left: the
//   requesting realm tells the answering one, which fails the world with the
//   browser's failure instead of waiting for the request.

import { realHost } from "../../packages/ui/src/runtime/test/testing";
import type { HttpRoute, RealmOfWorld } from "./realm";
import {
  worldAgainHeader,
  worldLostParameter,
  worldRequestParameter,
} from "./realm-names";

export type HttpMessage =
  /** `label` is the request as its realm made it: its method and URL. */
  | { carrier: "http"; request: string; kind: "request"; label: string }
  | {
      carrier: "http";
      request: string;
      kind: "abort" | "head" | "end" | "whole" | "failed";
    }
  /** `bytes` of the response's body are sent, this write included. */
  | { carrier: "http"; request: string; kind: "chunk"; bytes: number };

/**
 * The proof's perturbation: what arrives is noticed up to `delayMs` of real
 * time late, in the order it arrived.
 */
export function lateNotice(delayMs: number) {
  const host = realHost();
  let last = Promise.resolve();
  return (notice: () => void) => {
    if (delayMs <= 0) {
      notice();
      return;
    }
    last = last
      .then(
        () =>
          new Promise<void>((resolve) => {
            // The perturbation itself: real, random delays, only in proof runs.
            // ast-grep-ignore: ts-test-timer, ts-test-random
            host.setTimeout(resolve, host.random() * delayMs);
          })
      )
      .then(notice);
  };
}

const bodiless = new Set([101, 204, 205, 304]);

/**
 * The response's body is read by the realm's own code, from what the world
 * handed over: the browser's readers (`json`, `text`) finish in a task of
 * their own, after the realm rests.
 */
function readByRealm(response: Response): Response {
  const whole = async () => {
    const reader = response.body!.getReader();
    const parts: Uint8Array[] = [];
    let size = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      parts.push(value);
      size += value.byteLength;
    }
    const bytes = new Uint8Array(size);
    let at = 0;
    for (const part of parts) {
      bytes.set(part, at);
      at += part.byteLength;
    }
    return bytes;
  };
  const text = () => whole().then((bytes) => new TextDecoder().decode(bytes));
  const methods: Record<string, () => unknown> = {
    bytes: whole,
    arrayBuffer: () => whole().then((bytes) => bytes.buffer),
    text,
    json: () => text().then((body) => JSON.parse(body) as unknown),
    blob: () =>
      whole().then(
        (bytes) =>
          new Blob([bytes], { type: response.headers.get("content-type") ?? "" })
      ),
    clone: () => readByRealm(Response.prototype.clone.call(response)),
  };
  for (const [name, value] of Object.entries(methods))
    Object.defineProperty(response, name, { configurable: true, value });
  return response;
}

function exchange(
  realm: RealmOfWorld,
  route: HttpRoute,
  key: string,
  label: string,
  request: Request,
  hostFetch: typeof fetch
) {
  const notice = lateNotice(route.delayMs);
  // The wire's side: what has arrived.
  let head: Response | undefined;
  let ended = false;
  let failed = false;
  let failure: unknown;
  const arrived: Uint8Array[] = [];
  let arrivedBytes = 0;
  let moved: (() => void)[] = [];
  const progress = () => {
    const waiting = moved;
    moved = [];
    for (const resolve of waiting) resolve();
  };
  const until = async (met: () => boolean, what: string) => {
    while (!met()) {
      if (failed || ended)
        throw new Error(
          `${label} (${key}): the connection ${failed ? `failed (${String(failure)})` : "ended"} before ${what} of ${route.peer} arrived.`
        );
      await new Promise<void>((resolve) => moved.push(resolve));
    }
  };

  const closed = async () => {
    for (;;) {
      if (failed || ended) return;
      await new Promise<void>((resolve) => moved.push(resolve));
    }
  };

  // The realm's side: what its code was given.
  let answer!: { resolve(response: Response): void; reject(error: unknown): void };
  const response = new Promise<Response>((resolve, reject) => {
    answer = { resolve, reject };
  });
  let body: ReadableStreamDefaultController<Uint8Array> | undefined;
  let given = 0;
  let headGiven = false;
  // The realm's code has the whole answer, a failure, or aborted the request.
  let over = false;
  const giveHead = () => {
    const wire = head!;
    headGiven = true;
    const stream = bodiless.has(wire.status)
      ? null
      : new ReadableStream<Uint8Array>({
          start(controller) {
            body = controller;
          },
          cancel(reason) {
            abort(reason);
          },
        });
    const made = new Response(stream, {
      status: wire.status,
      statusText: wire.statusText,
      headers: wire.headers,
    });
    Object.defineProperty(made, "url", { value: request.url });
    answer.resolve(stream ? readByRealm(made) : made);
  };
  const give = (to: number) => {
    if (to <= given) return;
    const bytes = new Uint8Array(to - given);
    let at = 0;
    while (at < bytes.length) {
      const first = arrived[0]!;
      const part = first.subarray(0, bytes.length - at);
      bytes.set(part, at);
      at += part.length;
      if (part.length === first.length) arrived.shift();
      else arrived[0] = first.subarray(part.length);
    }
    given = to;
    body?.enqueue(bytes);
  };
  function abort(reason: unknown) {
    if (over) return;
    over = true;
    realm.send(route.peer, `abort ${label}`, {
      carrier: "http",
      request: key,
      kind: "abort",
    } satisfies HttpMessage);
    const error = reason ?? new DOMException("The request was aborted.", "AbortError");
    if (!headGiven) answer.reject(error);
    else
      try {
        body?.error(error);
      } catch {
        // The realm's code already cancelled the body.
      }
  }

  if (request.signal.aborted) {
    over = true;
    answer.reject(request.signal.reason);
    return { response, receive: () => Promise.resolve(() => {}) };
  }
  request.signal.addEventListener("abort", () => abort(request.signal.reason));
  realm.send(route.peer, label, {
    carrier: "http",
    request: key,
    kind: "request",
    label,
  } satisfies HttpMessage);

  void (async () => {
    // The wire brought an answer of the server's, or its head.
    let answered = false;
    try {
      const url = new URL(request.url);
      url.hash = "";
      // Added as text: the rest of the URL goes over the wire as the realm wrote it.
      const wireUrl = `${url.href}${url.search ? "&" : "?"}${worldRequestParameter}=${key}`;
      const sent = request.body ? await request.arrayBuffer() : undefined;
      let wire: Response;
      for (;;) {
        wire = await hostFetch(wireUrl, {
          method: request.method,
          headers: request.headers,
          body: sent ?? null,
          mode: request.mode,
          credentials: request.credentials,
          cache: request.cache,
          redirect: request.redirect,
          referrer: request.referrer,
          referrerPolicy: request.referrerPolicy,
          integrity: request.integrity,
        });
        // The answering realm sent the request back, to free the connection
        // for one before it (./node-realm.ts, makeRoom): it goes again.
        if (!wire.headers.has(worldAgainHeader)) break;
      }
      answered = true;
      if (wire.headers.has("content-encoding"))
        throw new Error("A world does not carry an encoded response.");
      notice(() => {
        head = wire;
        progress();
      });
      const reader = wire.body?.getReader();
      for (;;) {
        if (!reader) break;
        const { done, value } = await reader.read();
        if (done) break;
        notice(() => {
          arrived.push(value);
          arrivedBytes += value.byteLength;
          progress();
        });
      }
      notice(() => {
        ended = true;
        progress();
      });
    } catch (error) {
      // The answering realm would wait for a request that never left: it
      // learns of the failure on a request of the wire's own.
      if (!answered)
        void hostFetch(
          `${route.origin}/?${worldLostParameter}&${worldRequestParameter}=${key}`,
          { method: "POST", mode: "no-cors", body: String(error) }
        ).catch(() => {});
      notice(() => {
        failed = true;
        failure = error;
        progress();
      });
    }
  })();

  return {
    response,
    /** Resolves once the part of the answer `detail` names has arrived, with what handing it over runs. */
    async receive(detail: HttpMessage): Promise<() => void> {
      // An aborted request's connection is closed by the answering realm: what
      // that realm sent before it learned of the abort may never arrive.
      if (over) return () => {};
      switch (detail.kind) {
        case "head":
          await until(() => head !== undefined, "the head of the response");
          return () => {
            if (!over) giveHead();
          };
        case "chunk": {
          const { bytes } = detail;
          await until(() => arrivedBytes >= bytes, `${bytes} bytes of the response`);
          return () => {
            if (!over) give(bytes);
          };
        }
        case "end":
        case "whole":
          await until(() => ended, "the end of the response");
          return () => {
            if (over) return;
            if (detail.kind === "whole") giveHead();
            give(arrivedBytes);
            over = true;
            body?.close();
          };
        case "failed":
          await closed();
          return () => {
            if (over) return;
            over = true;
            const error = new TypeError("Failed to fetch");
            if (headGiven) body?.error(error);
            else answer.reject(error);
          };
        default:
          throw new Error(
            `${label} (${key}): a requesting realm receives no ${detail.kind}.`
          );
      }
    },
  };
}

/**
 * The requesting end of a realm's HTTP lines. `name` is the realm's, and
 * `hostFetch` the real `fetch`.
 */
export function routeRequests(
  realm: RealmOfWorld,
  { name, hostFetch }: { name: string; hostFetch: typeof fetch }
) {
  const routes = new Map<string, HttpRoute>();
  const exchanges = new Map<string, ReturnType<typeof exchange>>();
  let requests = 0;
  realm.carry("http", (_from, detail: HttpMessage) => {
    const found = exchanges.get(detail.request);
    if (!found) throw new Error(`The realm made no request ${detail.request}.`);
    return found.receive(detail);
  });
  return {
    /** From now on the realm's requests to `route.origin` go to the realm `route.peer`. */
    add(route: HttpRoute) {
      routes.set(route.origin, route);
    },
    /** The answer to a request to a realm; undefined when the request is to none. */
    fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> | undefined {
      const url = new URL(
        input instanceof Request ? input.url : String(input),
        globalThis.location?.href
      );
      const route = routes.get(url.origin);
      if (!route) return undefined;
      let request: Request;
      try {
        request = new Request(input, init);
      } catch (error) {
        return Promise.reject(error);
      }
      requests += 1;
      const key = `${name.replaceAll(" ", "-")}.${route.epoch ?? 0}.${requests}`;
      const made = exchange(
        realm,
        route,
        key,
        `${request.method} ${url.pathname}${url.search}`,
        request,
        hostFetch
      );
      exchanges.set(key, made);
      return made.response;
    },
  };
}
