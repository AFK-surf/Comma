import { createCommaApi, type CommaApiClient } from "@comma/app/api";
import type { SessionProductLease } from "@comma/session-contract";
import { NativeSessionAdmissionError } from "../ipc";
import { getCurrentNativeSessionAdmission } from "./native-session-admission";
import type {
  MainProductCredentialLease,
  MainProductCredentialAuthority,
} from "./main-product-credential-authority";

const requestHeaderAllowlist = new Set([
  "accept",
  "content-type",
  "if-match",
  "if-none-match",
  "last-event-id",
  "range",
]);

export interface MainSessionTransportAuthority {
  readonly authority: MainProductCredentialAuthority;
  reportUnauthorized(lease: MainProductCredentialLease): Promise<void>;
}

export interface MainSessionBoundApi {
  readonly api: CommaApiClient;
  readonly session: SessionProductLease;
  assertCurrent(): void;
  isCurrent(): boolean;
}

export function createCurrentMainSessionApiBinding({
  fetch: fetchImpl = fetch,
  session,
}: {
  fetch?: typeof fetch | undefined;
  session: MainSessionTransportAuthority;
}): MainSessionBoundApi {
  const admission = getCurrentNativeSessionAdmission();
  settleCredential(session, admission.credential);
  const assertCurrent = () => settleCredential(session, admission.credential);
  const api = createCommaApi({
    baseUrl: admission.credential.audience,
    fetch: createMainSessionFetch({
      credential: admission.credential,
      fetch: fetchImpl,
      session,
    }),
    token: admission.credential.token,
  });
  return {
    api: settleCommaApi(api, assertCurrent),
    assertCurrent,
    isCurrent: () => session.authority.isCurrentProductCredential(admission.credential),
    session: admission.session,
  };
}

export function createMainSessionFetch({
  credential,
  fetch: fetchImpl = fetch,
  session,
}: {
  credential: MainProductCredentialLease;
  fetch?: typeof fetch | undefined;
  session: MainSessionTransportAuthority;
}): typeof fetch {
  return async (input, init = {}) => {
    settleCredential(session, credential);
    const url = new URL(
      typeof input === "string" || input instanceof URL ? input : input.url
    );
    if (url.origin !== credential.audience) {
      throw new Error("Main Session request escaped its credential audience.");
    }

    const headers = allowedRequestHeaders(new Headers(init.headers));
    headers.set("authorization", `Bearer ${credential.token}`);
    const signal = init.signal
      ? AbortSignal.any([init.signal, credential.signal])
      : credential.signal;

    let response: Response;
    try {
      response = await fetchImpl(url, {
        ...init,
        credentials: "omit",
        headers,
        redirect: "manual",
        signal,
      });
    } catch (error) {
      settleCredential(session, credential);
      throw error;
    }
    settleCredential(session, credential);

    // Conditional reads return 304 without redirecting. Preserve it for the
    // API's not-modified path while continuing to reject other 3xx responses.
    if (response.status >= 300 && response.status < 400 && response.status !== 304) {
      throw new Error("Main Session transport rejected an HTTP redirect.");
    }
    if (response.status === 401) {
      await session.reportUnauthorized(credential);
      return response;
    }

    if (!response.body) return response;
    const contentType = response.headers.get("content-type")?.toLowerCase() ?? "";
    if (contentType.includes("text/event-stream")) {
      return rebuildResponse(
        response,
        settledStream(response.body, session, credential)
      );
    }

    let body: ArrayBuffer;
    try {
      body = await response.arrayBuffer();
    } catch (error) {
      settleCredential(session, credential);
      throw error;
    }
    settleCredential(session, credential);
    return rebuildResponse(response, body);
  };
}

function settledStream(
  source: ReadableStream<Uint8Array>,
  session: MainSessionTransportAuthority,
  credential: MainProductCredentialLease
) {
  const reader = source.getReader();
  return new ReadableStream<Uint8Array>({
    async cancel(reason) {
      await reader.cancel(reason);
    },
    async pull(controller) {
      try {
        settleCredential(session, credential);
        const next = await reader.read();
        settleCredential(session, credential);
        if (next.done) {
          controller.close();
          return;
        }
        controller.enqueue(next.value);
      } catch (error) {
        let settledError = error;
        try {
          settleCredential(session, credential);
        } catch (settlementError) {
          settledError = settlementError;
        }
        await reader.cancel(settledError).catch(() => undefined);
        controller.error(settledError);
      }
    },
  });
}

function settleCommaApi(api: CommaApiClient, settle: () => void): CommaApiClient {
  return new Proxy(api, {
    get(target, property, receiver) {
      const member = Reflect.get(target, property, receiver);
      if (typeof member !== "function") return member;

      return (...rawArgs: unknown[]) => {
        settle();
        const args =
          property === "streamConversationEvents"
            ? settleStreamCallback(rawArgs, settle)
            : rawArgs;
        let result: unknown;
        try {
          result = Reflect.apply(member, target, args);
        } catch (error) {
          settle();
          throw error;
        }

        return Promise.resolve(result).then(
          (value) => {
            settle();
            return value;
          },
          (error: unknown) => {
            settle();
            throw error;
          }
        );
      };
    },
  }) as CommaApiClient;
}

function settleStreamCallback(args: unknown[], settle: () => void): unknown[] {
  const options = args[2];
  if (!isRecord(options) || typeof options.onEvent !== "function") return args;

  const onEvent = options.onEvent;
  return [
    ...args.slice(0, 2),
    {
      ...options,
      onEvent: (...eventArgs: unknown[]) => {
        settle();
        try {
          return Reflect.apply(onEvent, undefined, eventArgs);
        } finally {
          settle();
        }
      },
    },
    ...args.slice(3),
  ];
}

function settleCredential(
  session: MainSessionTransportAuthority,
  credential: MainProductCredentialLease
) {
  if (!session.authority.isCurrentProductCredential(credential)) {
    throw new NativeSessionAdmissionError(session.authority.admissionFailure());
  }
}

function allowedRequestHeaders(source: Headers) {
  const headers = new Headers();
  for (const [name, value] of source) {
    if (requestHeaderAllowlist.has(name.toLowerCase())) {
      headers.append(name, value);
    }
  }
  return headers;
}

function rebuildResponse(response: Response, body: BodyInit) {
  return new Response(body, {
    headers: response.headers,
    status: response.status,
    statusText: response.statusText,
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
