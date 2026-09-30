import {
  dynamicUiDocument,
  dynamicUiCsp,
} from "@comma/chat-contract/dynamic-ui-runtime";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  sessionPresenceExpectationHeader,
  sessionPresenceExpectationSchema,
  type SessionAdmissionFailure,
  type SessionPresenceExpectation,
} from "@comma/session-contract";
import { net, protocol } from "electron";
import log from "electron-log/main";
import type { MainProductCredentialLease } from "./modules/session";

const internalOrigin = "assets://.";
const commaApiPrefix = "/v1";
// Main owns authentication, so renderers may not call these routes. The
// server still accepts the pre-namespace /v1/auth path for older clients, so
// the block covers both spellings.
const commaAuthPrefixes = ["/v1/comma/auth", "/v1/auth"];
const maxConcurrentDevRendererAssetLoads = 32;
// A read that never got a response is sent once more after a short pause.
// Proxy tunnels, dropped connections and network changes clear in that time;
// a longer outage still fails in well under a second. Writes are never replayed.
const replayableMethods = new Set(["GET", "HEAD"]);
const upstreamRetryDelayMs = 300;

const rendererRequestHeaderAllowlist = new Set([
  "accept",
  "content-type",
  "if-match",
  "if-none-match",
  "last-event-id",
  "range",
]);

const rendererResponseHeaderAllowlist = new Set([
  "accept-ranges",
  "cache-control",
  "content-range",
  "content-type",
  "etag",
  "last-modified",
  "retry-after",
]);

const rendererAuthorityHeaders = new Set([
  "authorization",
  "cookie",
  "proxy-authorization",
  "set-cookie",
  "www-authenticate",
  "proxy-authenticate",
  "x-comma-client-surface",
  "x-comma-expected-auth-session-id",
  "x-comma-session-lifecycle-version",
  sessionPresenceExpectationHeader,
]);

type CommaNetFetch = (
  url: string,
  init: RequestInit & { bypassCustomProtocolHandlers: boolean }
) => Promise<Response>;

export interface CommaApiCredentialAuthority {
  acquireProductCredential(
    expected: SessionPresenceExpectation
  ): MainProductCredentialLease | null;
  admissionFailure(): SessionAdmissionFailure;
  isCurrentProductCredential(lease: MainProductCredentialLease): boolean;
  reportUnauthorized?:
    | ((lease: MainProductCredentialLease) => Promise<void> | void)
    | undefined;
}

export interface AppProtocolOptions {
  fetch?: CommaNetFetch | undefined;
  getCredentialAuthority?: (() => CommaApiCredentialAuthority | undefined) | undefined;
}

export function registerAppProtocol(
  devServerUrl?: string,
  options: AppProtocolOptions = {}
) {
  const rendererRoot = resolve(__dirname, "../renderer/main_window");
  const fetchImpl = options.fetch ?? net.fetch;
  const proxyDevRendererAsset = devServerUrl
    ? createDevRendererAssetProxy(
        devServerUrl,
        fetchImpl,
        maxConcurrentDevRendererAssetLoads
      )
    : undefined;

  protocol.handle("comma-ui", (request) => {
    if (request.url !== "comma-ui://runtime/")
      return new Response("Not found", { status: 404 });
    return new Response(dynamicUiDocument(), {
      headers: {
        "content-type": "text/html; charset=utf-8",
        "content-security-policy": dynamicUiCsp,
        "cache-control": "no-store",
      },
    });
  });

  protocol.handle("assets", async (request) => {
    const url = new URL(request.url);

    if (url.hostname !== ".") {
      return new Response("Not found", { status: 404 });
    }

    if (
      isRendererAuthPath(url.pathname) ||
      isRendererComputeInstallPath(url.pathname)
    ) {
      return rendererAuthBlockedResponse();
    }

    if (isCommaApiPath(url.pathname)) {
      const authority = options.getCredentialAuthority?.();
      return authority
        ? proxyCommaApiRequest(request, url, authority, fetchImpl)
        : sessionLeaseUnavailableResponse();
    }

    if (proxyDevRendererAsset) {
      return proxyDevRendererAsset(request, url);
    }

    return fetchImpl(pathToFileURL(resolveRendererPath(rendererRoot, url)).toString(), {
      bypassCustomProtocolHandlers: true,
      credentials: "omit",
      redirect: "manual",
    });
  });
}

export function appRendererUrl() {
  return `${internalOrigin}/`;
}

export function registerPrivilegedSchemes() {
  protocol.registerSchemesAsPrivileged([
    {
      scheme: "comma-ui",
      privileges: { standard: true, secure: true, supportFetchAPI: true },
    },
    {
      scheme: "assets",
      privileges: {
        corsEnabled: true,
        secure: true,
        standard: true,
        stream: true,
        supportFetchAPI: true,
      },
    },
  ]);
}

export function resolveRendererPath(rendererRoot: string, url: URL) {
  const pathname = decodeURIComponent(url.pathname);
  const relativePath = pathname === "/" ? "index.html" : pathname.replace(/^\/+/, "");
  const filePath = resolve(rendererRoot, relativePath);

  if (isPathInside(rendererRoot, filePath) && existsSync(filePath)) {
    return filePath;
  }

  return join(rendererRoot, "index.html");
}

export async function proxyCommaApiRequest(
  request: Request,
  url: URL,
  authority: CommaApiCredentialAuthority,
  fetchImpl: CommaNetFetch = net.fetch
): Promise<Response> {
  const expected = readRendererSessionExpectation(request.headers);
  if (!expected) {
    return sessionLeaseUnavailableResponse(authority.admissionFailure());
  }

  const lease = authority.acquireProductCredential(expected);
  if (!lease) {
    return sessionLeaseUnavailableResponse(authority.admissionFailure());
  }

  const targetUrl = new URL(`${url.pathname}${url.search}`, lease.audience);
  const headers = rendererRequestHeaders(request.headers);
  headers.set("authorization", `Bearer ${lease.token}`);

  const init: RequestInit & { bypassCustomProtocolHandlers: boolean } = {
    bypassCustomProtocolHandlers: true,
    credentials: "omit",
    headers,
    method: request.method,
    redirect: "manual",
    signal: lease.signal,
  };

  if (request.method !== "GET" && request.method !== "HEAD" && request.body) {
    init.body = await request.clone().arrayBuffer();
  }

  let response: Response | undefined;
  for (let attempt = 1; !response; attempt += 1) {
    try {
      response = await fetchImpl(targetUrl.toString(), init);
    } catch (error) {
      if (!authority.isCurrentProductCredential(lease)) {
        return sessionLeaseUnavailableResponse(authority.admissionFailure());
      }
      log.warn(
        `Comma API ${request.method} ${pathShape(url.pathname)} got no response ` +
          `(attempt ${attempt}): ${error instanceof Error ? error.message : String(error)}`
      );
      if (attempt > 1 || !replayableMethods.has(request.method)) {
        return upstreamUnavailableResponse();
      }
      await pause(upstreamRetryDelayMs, lease.signal);
      if (!authority.isCurrentProductCredential(lease)) {
        return sessionLeaseUnavailableResponse(authority.admissionFailure());
      }
    }
  }

  if (!authority.isCurrentProductCredential(lease)) {
    return sessionLeaseUnavailableResponse(authority.admissionFailure());
  }

  if (isRedirectStatus(response.status)) {
    return upstreamRedirectBlockedResponse();
  }

  if (response.status === 401) {
    await authority.reportUnauthorized?.(lease);
    return unauthorizedResponse();
  }

  return rebuildRendererResponse(response, lease, authority);
}

/** Resolves after `ms`, or at once when the lease ends. */
function pause(ms: number, signal: AbortSignal) {
  return new Promise<void>((wake) => {
    const timer = setTimeout(done, ms);
    signal.addEventListener("abort", done, { once: true });
    function done() {
      clearTimeout(timer);
      signal.removeEventListener("abort", done);
      wake();
    }
  });
}

/** The route without identifiers, e.g. `/v1/comma/groups/:id/conversations/:id`. */
function pathShape(pathname: string) {
  return pathname
    .split("/")
    .map((segment) =>
      segment === "" || /^(v1|[a-z]+(-[a-z]+)*)$/.test(segment) ? segment : ":id"
    )
    .join("/");
}

function readRendererSessionExpectation(
  headers: Headers
): SessionPresenceExpectation | undefined {
  const raw = headers.get(sessionPresenceExpectationHeader);
  if (!raw) return undefined;

  try {
    const parsed: unknown = JSON.parse(raw);
    const expectation = sessionPresenceExpectationSchema.safeParse(parsed);
    return expectation.success ? expectation.data : undefined;
  } catch {
    return undefined;
  }
}

function rendererRequestHeaders(source: Headers) {
  const headers = new Headers();
  for (const [name, value] of source) {
    const normalized = name.toLowerCase();
    if (
      rendererRequestHeaderAllowlist.has(normalized) &&
      !rendererAuthorityHeaders.has(normalized)
    ) {
      headers.append(normalized, value);
    }
  }
  return headers;
}

function rebuildRendererResponse(
  response: Response,
  lease: MainProductCredentialLease,
  authority: CommaApiCredentialAuthority
) {
  if (!authority.isCurrentProductCredential(lease)) {
    return sessionLeaseUnavailableResponse(authority.admissionFailure());
  }

  const headers = new Headers();
  for (const [name, value] of response.headers) {
    const normalized = name.toLowerCase();
    if (
      rendererResponseHeaderAllowlist.has(normalized) &&
      !rendererAuthorityHeaders.has(normalized)
    ) {
      headers.append(normalized, value);
    }
  }

  const body = response.body
    ? settledRendererResponseBody(response.body, lease, authority)
    : null;

  return new Response(body, {
    headers,
    status: response.status,
    statusText: response.statusText,
  });
}

function settledRendererResponseBody(
  source: ReadableStream<Uint8Array>,
  lease: MainProductCredentialLease,
  authority: CommaApiCredentialAuthority
) {
  const reader = source.getReader();
  let consumerCancelled = false;
  let terminal = false;

  return new ReadableStream<Uint8Array>(
    {
      async cancel(reason) {
        consumerCancelled = true;
        terminal = true;
        await reader.cancel(reason);
      },
      async pull(controller) {
        if (terminal) return;

        try {
          settleRendererResponseLease(lease, authority);
          const next = await reader.read();
          if (terminal) return;
          settleRendererResponseLease(lease, authority);

          if (next.done) {
            terminal = true;
            controller.close();
            return;
          }

          // No asynchronous boundary may separate the final exact-lease
          // settlement from delivery into the renderer-visible stream.
          controller.enqueue(next.value);
        } catch (error) {
          if (consumerCancelled || terminal) return;

          let deliveryError = error;
          try {
            settleRendererResponseLease(lease, authority);
          } catch (settlementError) {
            deliveryError = settlementError;
          }

          terminal = true;
          await reader.cancel(deliveryError).catch(() => undefined);
          if (!consumerCancelled) {
            controller.error(deliveryError);
          }
        }
      },
    },
    // A default positive high-water mark permits the wrapper to prefetch and
    // queue account-A bytes before a renderer asks for them. Zero makes each
    // pull correspond to an actual pending consumer read, so the settlement
    // immediately before enqueue is also the delivery boundary.
    { highWaterMark: 0 }
  );
}

function settleRendererResponseLease(
  lease: MainProductCredentialLease,
  authority: CommaApiCredentialAuthority
) {
  if (!authority.isCurrentProductCredential(lease)) {
    throw new Error(
      "The Electron Main Session lease changed before response-body delivery."
    );
  }
}

function isCommaApiPath(pathname: string) {
  return pathname === commaApiPrefix || pathname.startsWith(`${commaApiPrefix}/`);
}

function isRendererAuthPath(pathname: string) {
  const decodedPathname = repeatedlyDecodePathname(pathname);
  return commaAuthPrefixes.some(
    (prefix) => decodedPathname === prefix || decodedPathname.startsWith(`${prefix}/`)
  );
}

function isRendererComputeInstallPath(pathname: string) {
  const decodedPathname = repeatedlyDecodePathname(pathname);
  // Also the pre-namespace /v1/workspaces spelling, which the server still accepts.
  return /^\/v1\/(?:comma\/)?workspaces\/[^/]+\/compute-nodes\/agent-vmm\/install-operations(?:\/.*)?$/.test(
    decodedPathname
  );
}

function repeatedlyDecodePathname(pathname: string) {
  let decoded = pathname;

  for (let pass = 0; pass < 4; pass += 1) {
    try {
      const next = decodeURIComponent(decoded);
      if (next === decoded) return decoded;
      decoded = next;
    } catch {
      return pathname;
    }
  }

  return decoded;
}

function rendererAuthBlockedResponse() {
  return jsonErrorResponse("not_found", 404);
}

function unauthorizedResponse() {
  return jsonErrorResponse("unauthorized", 401);
}

function upstreamRedirectBlockedResponse() {
  return jsonErrorResponse("upstream_redirect_blocked", 502);
}

function upstreamUnavailableResponse() {
  return jsonErrorResponse("upstream_unavailable", 502);
}

function sessionLeaseUnavailableResponse(
  failure: SessionAdmissionFailure = {
    code: "session_product_lease_unavailable",
    recovery: {
      authorityInstanceId: "electron-main-unavailable",
      generation: 0,
      revision: 0,
    },
  }
) {
  return new Response(JSON.stringify({ error: failure }), {
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json",
    },
    status: 409,
  });
}

function jsonErrorResponse(error: string, status: number) {
  return new Response(JSON.stringify({ error }), {
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json",
    },
    status,
  });
}

function createDevRendererAssetProxy(
  targetBaseUrl: string,
  fetchImpl: CommaNetFetch,
  maxConcurrency: number
) {
  if (!Number.isInteger(maxConcurrency) || maxConcurrency < 2) {
    throw new Error(
      "Dev renderer concurrency must leave one permit for document navigation."
    );
  }

  // A replacement document cannot cancel the old document's subresource
  // requests until it commits. If subresources can occupy every permit, the
  // replacement document queues behind the very requests that only its commit
  // can cancel. Keep one permit independent so a reload can always make the
  // progress that releases the old document's loaders while preserving the
  // same total loader bound.
  const acquireDocumentPermit = createConcurrencyPermitPool(1);
  const acquireAssetPermit = createConcurrencyPermitPool(maxConcurrency - 1);

  return async (request: Request, url: URL) => {
    const acquirePermit = isDevRendererDocument(url)
      ? acquireDocumentPermit
      : acquireAssetPermit;
    const release = await acquirePermit();
    const fetchLifetime = createDevRendererFetchLifetime(request.signal, release);

    try {
      fetchLifetime.signal.throwIfAborted();
      const targetUrl = new URL(`${url.pathname}${url.search}`, targetBaseUrl);
      const response = await fetchImpl(targetUrl.toString(), {
        bypassCustomProtocolHandlers: true,
        credentials: "omit",
        method: request.method,
        redirect: "manual",
        signal: fetchLifetime.signal,
      });

      if (!response.body) {
        fetchLifetime.complete();
      }

      const body = response.body
        ? devRendererResponseBody(response.body, fetchLifetime)
        : null;
      return new Response(body, {
        headers: response.headers,
        status: response.status,
        statusText: response.statusText,
      });
    } catch (error) {
      fetchLifetime.cancel(error);
      throw error;
    }
  };
}

function isDevRendererDocument(url: URL) {
  // Comma routes live in the URL hash, which is not sent through the protocol.
  // Every app window therefore obtains its Vite document from this root path;
  // modules and other renderer assets use non-root paths.
  return url.pathname === "/";
}

function createConcurrencyPermitPool(maxConcurrency: number) {
  if (!Number.isInteger(maxConcurrency) || maxConcurrency < 1) {
    throw new Error("Dev renderer concurrency must be a positive integer.");
  }

  let active = 0;
  const waiters: Array<(release: () => void) => void> = [];

  const createRelease = () => {
    let released = false;

    return () => {
      if (released) return;
      released = true;

      const next = waiters.shift();
      if (next) {
        next(createRelease());
      } else {
        active -= 1;
      }
    };
  };

  return function acquire() {
    if (active < maxConcurrency) {
      active += 1;
      return Promise.resolve(createRelease());
    }

    return new Promise<() => void>((resolvePermit) => {
      waiters.push(resolvePermit);
    });
  };
}

interface DevRendererFetchLifetime {
  signal: AbortSignal;
  cancel(reason?: unknown): void;
  complete(): void;
}

function createDevRendererFetchLifetime(
  requestSignal: AbortSignal,
  release: () => void
): DevRendererFetchLifetime {
  const controller = new AbortController();
  let settled = false;

  const finish = () => {
    if (settled) return;
    settled = true;
    requestSignal.removeEventListener("abort", forwardRequestAbort);
    release();
  };
  const cancel = (reason?: unknown) => {
    if (!controller.signal.aborted) {
      controller.abort(reason);
    }
    finish();
  };
  function forwardRequestAbort() {
    cancel(requestSignal.reason);
  }

  if (requestSignal.aborted) {
    forwardRequestAbort();
  } else {
    requestSignal.addEventListener("abort", forwardRequestAbort, { once: true });
  }

  return {
    cancel,
    complete: finish,
    signal: controller.signal,
  };
}

function devRendererResponseBody(
  source: ReadableStream<Uint8Array>,
  fetchLifetime: DevRendererFetchLifetime
) {
  const reader = source.getReader();
  let terminal = false;

  return new ReadableStream<Uint8Array>(
    {
      cancel(reason) {
        if (terminal) return undefined;
        terminal = true;

        // Electron does not propagate cancellation of this wrapper's reader
        // through net.fetch to its native loader. Abort the transport itself
        // before handing admission to the next request, then cancel the reader
        // as a best-effort cleanup of the wrapped stream.
        fetchLifetime.cancel(reason);
        return reader.cancel(reason).catch(() => undefined);
      },
      async pull(controller) {
        if (terminal) return;

        try {
          const next = await reader.read();
          if (terminal) return;

          if (next.done) {
            terminal = true;
            fetchLifetime.complete();
            controller.close();
            return;
          }

          controller.enqueue(next.value);
        } catch (error) {
          if (terminal) return;
          terminal = true;
          fetchLifetime.complete();
          void reader.cancel(error).catch(() => undefined);
          controller.error(error);
        }
      },
    },
    // Do not pull Vite bytes before Electron has attached the native consumer
    // that can cancel them when a navigation is superseded.
    { highWaterMark: 0 }
  );
}

function isRedirectStatus(status: number) {
  return status >= 300 && status < 400;
}

function isPathInside(root: string, target: string) {
  const normalizedRoot = root.endsWith("/") ? root : `${root}/`;
  return target === root || target.startsWith(normalizedRoot);
}
