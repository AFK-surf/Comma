// Every request Comma Admin makes goes through `AdminFetch.send`: one wrapper around Effect's fetch client, with the
// session Cookie (`credentials: "include"`) and no tracing headers (the API's CORS policy does not allow them). An
// interrupted request aborts its fetch. The answer comes back read: its status and its JSON body (`undefined` when the
// body is not JSON). A request that got no answer fails `AdminNetworkError`.
import { Context, Data, Effect, Layer } from "effect";
import { FetchHttpClient, HttpBody, HttpClient, HttpClientRequest } from "effect/http";
import { messages } from "@comma/i18n";

/** Where the Admin API is: the build injects it (runtime.ts). */
export class AdminConfig extends Context.Service<
  AdminConfig,
  { readonly apiBaseUrl: string }
>()("admin/AdminConfig") {}

/** The server refused the request: its status and the code of its `{error}` body. */
export class AdminApiError extends Data.TaggedError("AdminApiError")<{
  readonly code: string | undefined;
  readonly message: string;
  readonly status: number;
}> {}

/** The request got no answer. */
export class AdminNetworkError extends Data.TaggedError("AdminNetworkError")<{
  readonly message: string;
}> {}

/** The server answered success with a body the Admin schema does not accept. */
export class AdminResponseError extends Data.TaggedError("AdminResponseError")<{
  readonly message: string;
}> {}

/** No session is signed in, or the session the request was made for ended while it ran. */
export class AdminSessionClosed extends Data.TaggedError("AdminSessionClosed")<{
  readonly message: string;
}> {}

export type AdminRequestError =
  | AdminApiError
  | AdminNetworkError
  | AdminResponseError
  | AdminSessionClosed;

export interface HttpAnswer {
  readonly body: unknown;
  readonly ok: boolean;
  /** The server's `Retry-After`, when the browser lets the page read it. */
  readonly retryAfterMs?: number;
  readonly status: number;
  readonly statusText: string;
}

export interface HttpSend {
  readonly body?: unknown;
  readonly headers: Readonly<Record<string, string>>;
  readonly method: "GET" | "PATCH" | "POST" | "PUT";
  /** A path under the API base URL, such as `/v1/comma/admin/users`. */
  readonly path: string;
}

export class AdminFetch extends Context.Service<
  AdminFetch,
  { readonly send: (request: HttpSend) => Effect.Effect<HttpAnswer, AdminNetworkError> }
>()("admin/AdminFetch") {}

/** `AdminFetch` over `fetch` (`FetchHttpClient.Fetch` where the layer is built: the global one unless a test gives another). */
export const AdminFetchLive = Layer.effect(
  AdminFetch,
  Effect.gen(function* () {
    const { apiBaseUrl } = yield* AdminConfig;
    const baseUrl = apiBaseUrl.replace(/\/+$/, "");
    const client = yield* HttpClient.HttpClient;
    // The fetch this layer was built with, whichever fiber sends the request.
    const fetchFn = yield* FetchHttpClient.Fetch;
    const send = (request: HttpSend) => {
      let outgoing = HttpClientRequest.make(request.method)(
        `${baseUrl}${request.path}`,
        {
          headers: request.headers,
        }
      );
      if (request.body !== undefined) {
        outgoing = HttpClientRequest.setBody(
          outgoing,
          HttpBody.raw(JSON.stringify(request.body), {
            contentType: "application/json",
          })
        );
      }
      return client.execute(outgoing).pipe(
        Effect.flatMap((response) =>
          response.text.pipe(
            Effect.map(
              (text): HttpAnswer => ({
                body: parseJson(text),
                ...retryAfter(response.headers["retry-after"]),
                ok: response.status >= 200 && response.status < 300,
                status: response.status,
                statusText: statusText(response),
              })
            )
          )
        ),
        Effect.mapError(
          (error) => new AdminNetworkError({ message: networkMessage(error) })
        ),
        Effect.provideService(HttpClient.TracerPropagationEnabled, false),
        Effect.provideService(FetchHttpClient.Fetch, fetchFn),
        Effect.provideService(FetchHttpClient.RequestInit, { credentials: "include" })
      );
    };
    return { send };
  })
).pipe(Layer.provide(FetchHttpClient.layer));

function retryAfter(value: string | undefined): { retryAfterMs?: number } {
  const seconds = value === undefined ? Number.NaN : Number(value);
  return Number.isFinite(seconds)
    ? { retryAfterMs: Math.max(1, Math.trunc(seconds * 1_000)) }
    : {};
}

function parseJson(text: string): unknown {
  if (!text) return undefined;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return undefined;
  }
}

function statusText(response: { readonly status: number }) {
  const source = (response as { readonly source?: unknown }).source;
  return source instanceof Response ? source.statusText : "";
}

function networkMessage(error: {
  readonly reason?: unknown;
  readonly message?: string;
}) {
  const cause = (error.reason as { readonly cause?: unknown } | undefined)?.cause;
  if (cause instanceof Error && cause.message) return cause.message;
  return error.message || messages.admin_network_error();
}

/** The code of a refusal: `{error: "code"}`, or `{error: {code}}`. */
export function errorCode(body: unknown): string | undefined {
  const raw =
    typeof body === "object" && body !== null
      ? (body as { readonly error?: unknown }).error
      : undefined;
  if (typeof raw === "string") return raw;
  if (
    typeof raw === "object" &&
    raw !== null &&
    typeof (raw as { readonly code?: unknown }).code === "string"
  ) {
    return (raw as { readonly code: string }).code;
  }
  return undefined;
}
