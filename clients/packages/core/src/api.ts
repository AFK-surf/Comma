// Requests to the Comma API, as the core makes them: for the account's session (the host adds its credential), each
// answer read through its schema here, so nothing past this point sees the server's data unchecked. A request that got
// no answer fails `network`; one the server refused fails with the server's code (`{error}` of its body) and status;
// one refused for the session (401, or 409 naming the session) also tells the session. One whose lease closes while it
// is under way (the web's lifecycle signed out, or is checking a refused session) is stopped and fails `signed_out`.
import { CoreError, HostError, utf8, fromUtf8 } from "@comma/core-kernel";
import { Effect, type Scope } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import {
  header,
  type ApiRequest,
  type ApiResponse,
  type Host,
  type Pull,
} from "./host.ts";
import type { Session } from "./session.ts";

export type Method = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";

/** How long a request may take before it is given up (`timeout`), unless it says otherwise. */
export const REQUEST_TIMEOUT_MS = 30_000;

/** What refuses a request for its session: another session took its place, or its lease is gone. */
const sessionRefusals = new Set([
  "session_changed",
  "session_product_lease_unavailable",
]);

/** The server's code for a refusal: `{error: "code"}`, or `{error: {code}}` for a session's. */
function errorCode(value: unknown): string | undefined {
  const raw =
    typeof value === "object" && value !== null
      ? (value as { error?: unknown }).error
      : undefined;
  if (typeof raw === "string") return raw;
  if (
    typeof raw === "object" &&
    raw !== null &&
    typeof (raw as { code?: unknown }).code === "string"
  )
    return (raw as { code: string }).code;
  return undefined;
}

/** A read with its validator: `notModified` when the server said the one the core holds is current. */
export type Conditional<T> =
  | { notModified: true }
  | { notModified: false; value: T; etag?: string };

export class Api {
  readonly #host: Host;
  readonly #session: Session;

  constructor(host: Host, session: Session) {
    this.#host = host;
    this.#session = session;
  }

  /** `method path` for `account`, its answer through `schema`; `headers` adds to the request's own. */
  request<S extends z.ZodType>(
    account: Account,
    method: Method,
    path: string,
    schema: S,
    body?: unknown,
    timeoutMs = REQUEST_TIMEOUT_MS,
    headers: [string, string][] = []
  ): Effect.Effect<z.output<S>, CoreError> {
    return this.#send(
      account,
      method,
      path,
      schema,
      body,
      timeoutMs,
      undefined,
      undefined,
      headers
    ).pipe(
      Effect.flatMap((answer) =>
        answer.notModified
          ? Effect.fail(
              new CoreError("bad_response", `${method} ${pathShape(path)} answered 304`)
            )
          : Effect.succeed(answer.value)
      )
    );
  }

  /** A file sent as the form field `field` (multipart), its answer through `schema`. */
  upload<S extends z.ZodType>(
    account: Account,
    method: Method,
    path: string,
    schema: S,
    file: { field: string; name: string; type: string; bytes: Uint8Array },
    timeoutMs = REQUEST_TIMEOUT_MS
  ): Effect.Effect<z.output<S>, CoreError> {
    return Effect.suspend(() => {
      const random = new Uint8Array(12);
      this.#host.randomBytes(random);
      const boundary = `comma-${[...random].map((b) => b.toString(16).padStart(2, "0")).join("")}`;
      const head = utf8(
        `--${boundary}\r\nContent-Disposition: form-data; name="${quoted(file.field)}"; filename="${quoted(file.name)}"\r\nContent-Type: ${quoted(file.type)}\r\n\r\n`
      );
      const tail = utf8(`\r\n--${boundary}--\r\n`);
      const body = new Uint8Array(head.length + file.bytes.length + tail.length);
      body.set(head, 0);
      body.set(file.bytes, head.length);
      body.set(tail, head.length + file.bytes.length);
      return this.#send(
        account,
        method,
        path,
        schema,
        undefined,
        timeoutMs,
        undefined,
        {
          contentType: `multipart/form-data; boundary=${boundary}`,
          body,
        }
      );
    }).pipe(
      Effect.flatMap((answer) =>
        answer.notModified
          ? Effect.fail(
              new CoreError("bad_response", `${method} ${pathShape(path)} answered 304`)
            )
          : Effect.succeed(answer.value)
      )
    );
  }

  /** A GET that sends `etag` (If-None-Match): a 304 answers `notModified`. */
  get<S extends z.ZodType>(
    account: Account,
    path: string,
    schema: S,
    etag: string | undefined,
    timeoutMs = REQUEST_TIMEOUT_MS
  ): Effect.Effect<Conditional<z.output<S>>, CoreError> {
    return this.#send(account, "GET", path, schema, undefined, timeoutMs, etag);
  }

  /**
   * A request with its own headers and body bytes (an upload, a file read): its answer whole, as the server gave it.
   * Refused like any request.
   */
  raw(
    account: Account,
    method: Method,
    path: string,
    init: {
      headers?: [string, string][];
      body?: Uint8Array | null;
      timeoutMs?: number;
    } = {}
  ): Effect.Effect<ApiResponse, CoreError> {
    const request: ApiRequest = {
      method,
      path,
      headers: init.headers ?? [],
      body: init.body ?? null,
      lease: account.lease,
    };
    return this.#host.fetch(request).pipe(
      Effect.mapError((e: HostError) => new CoreError("network", e.message)),
      Effect.timeoutOrElse({
        duration: init.timeoutMs ?? REQUEST_TIMEOUT_MS,
        orElse: () =>
          Effect.fail(
            new CoreError("timeout", `${method} ${pathShape(path)} took too long`)
          ),
      }),
      Effect.filterOrFail(
        (response) => response.status >= 200 && response.status < 300,
        (response) =>
          this.#refusal(request, method, path, response.status, response.body)
      )
    );
  }

  /**
   * An event stream: its body as it arrives, open while the scope is. Refused like any request. A GET, unless `send`
   * gives a body (its method and type).
   */
  stream(
    account: Account,
    path: string,
    send?: { method: "POST"; contentType: string; body: Uint8Array }
  ): Effect.Effect<Pull<Uint8Array>, CoreError, Scope.Scope> {
    const request: ApiRequest = {
      method: send?.method ?? "GET",
      path,
      headers: send
        ? [
            ["accept", "text/event-stream"],
            ["content-type", send.contentType],
          ]
        : [["accept", "text/event-stream"]],
      body: send?.body ?? null,
      lease: account.lease,
    };
    return this.#host.fetchStream(request).pipe(
      Effect.mapError((e: HostError) => new CoreError("network", e.message)),
      Effect.raceFirst(this.#leaseClosed(request)),
      Effect.flatMap((response) => {
        if (response.status >= 200 && response.status < 300) {
          const closed = this.#session
            .closed(request.lease)
            .pipe(Effect.andThen(Effect.fail(new HostError("the session ended"))));
          return Effect.succeed({
            take: response.body.take.pipe(Effect.raceFirst(closed)),
          } as Pull<Uint8Array>);
        }
        return readAll(response.body).pipe(
          Effect.flatMap((bytes) =>
            Effect.fail(
              this.#refusal(request, request.method, path, response.status, bytes)
            )
          )
        );
      })
    );
  }

  #send<S extends z.ZodType>(
    account: Account,
    method: Method,
    path: string,
    schema: S,
    body: unknown,
    timeoutMs: number,
    etag: string | undefined,
    raw?: { contentType: string; body: Uint8Array },
    extra: [string, string][] = []
  ): Effect.Effect<Conditional<z.output<S>>, CoreError> {
    const headers: [string, string][] = [["accept", "application/json"], ...extra];
    if (raw) headers.push(["content-type", raw.contentType]);
    else if (body !== undefined) headers.push(["content-type", "application/json"]);
    if (etag) headers.push(["if-none-match", etag]);
    const request: ApiRequest = {
      method,
      path,
      headers,
      body: raw ? raw.body : body === undefined ? null : utf8(JSON.stringify(body)),
      lease: account.lease,
    };
    return this.#host.fetch(request).pipe(
      Effect.mapError((e: HostError) => new CoreError("network", e.message)),
      Effect.raceFirst(this.#leaseClosed(request)),
      Effect.timeoutOrElse({
        duration: timeoutMs,
        orElse: () =>
          Effect.fail(
            new CoreError("timeout", `${method} ${pathShape(path)} took too long`)
          ),
      }),
      Effect.flatMap((response) =>
        Effect.suspend((): Effect.Effect<Conditional<z.output<S>>, CoreError> => {
          if (response.status === 304 && etag)
            return Effect.succeed({ notModified: true });
          if (response.status < 200 || response.status >= 300)
            return Effect.fail(
              this.#refusal(request, method, path, response.status, response.body)
            );
          const out = schema.safeParse(parseBody(response.body));
          if (!out.success)
            return Effect.fail(
              new CoreError(
                "bad_response",
                `${method} ${pathShape(path)}: ${out.error.issues[0]?.message ?? "unexpected answer"}`,
                response.status
              )
            );
          const tag = header(response, "etag");
          return Effect.succeed({
            notModified: false,
            value: out.data as z.output<S>,
            ...(tag ? { etag: tag } : {}),
          });
        })
      )
    );
  }

  /** Fails once the request's lease closes: the request racing it is stopped (its host fetch aborted). */
  #leaseClosed(request: ApiRequest): Effect.Effect<never, CoreError> {
    return this.#session
      .closed(request.lease)
      .pipe(
        Effect.andThen(
          Effect.fail(
            new CoreError("signed_out", "The session ended before the answer came.")
          )
        )
      );
  }

  /** A refusal as the core's error; one for the session tells the session. */
  #refusal(
    request: ApiRequest,
    method: string,
    path: string,
    status: number,
    body: Uint8Array
  ): CoreError {
    const value = parseBody(body);
    const code = errorCode(value);
    if (status === 401) this.#session.rejected(request.lease, 401);
    else if (status === 409 && code !== undefined && sessionRefusals.has(code))
      this.#session.rejected(request.lease, 409);
    return new CoreError(
      code ?? `http_${status}`,
      code ?? `${method} ${pathShape(path)} answered ${status}`,
      status,
      value
    );
  }
}

function parseBody(body: Uint8Array): unknown {
  const text = fromUtf8(body);
  if (text === "") return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

/** A form-data header value with nothing that could end it. */
const quoted = (v: string) => v.replace(/["\r\n]/g, "_");

/** What remains of a body, whole. */
function readAll(body: Pull<Uint8Array>): Effect.Effect<Uint8Array, CoreError> {
  return Effect.gen(function* () {
    const parts: Uint8Array[] = [];
    let size = 0;
    for (;;) {
      const piece = yield* body.take.pipe(
        Effect.mapError((e) => new CoreError("network", e.message))
      );
      if (piece === null || size > 65_536) break;
      parts.push(piece);
      size += piece.length;
    }
    const out = new Uint8Array(size);
    let at = 0;
    for (const part of parts) {
      out.set(part, at);
      at += part.length;
    }
    return out;
  });
}

/** The route without identifiers, for messages: `/v1/comma/workspaces/:id/plugins`. */
export function pathShape(path: string): string {
  return path
    .split("?")[0]!
    .split("/")
    .map((segment) =>
      segment === "" || /^(v1|[a-z]+(-[a-z]+)*)$/.test(segment) ? segment : ":id"
    )
    .join("/");
}

/** `/v1/…` with each id encoded. */
export function route(strings: TemplateStringsArray, ...ids: string[]): string {
  return strings.reduce(
    (out, part, i) => out + part + (i < ids.length ? encodeURIComponent(ids[i]!) : ""),
    ""
  );
}
