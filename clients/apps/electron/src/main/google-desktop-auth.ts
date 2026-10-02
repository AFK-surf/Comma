import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import * as oidc from "openid-client";
import * as oauth from "oauth4webapi";
import { baseLocale, messages, type CommaLocale } from "@comma/i18n";
import { readMainLocale, type MainLocaleSource } from "./main-locale";

const googleIssuer = new URL("https://accounts.google.com");
const callbackPath = "/oauth2/callback";
const defaultTimeoutMs = 5 * 60 * 1_000;

export interface DesktopGoogleAuthProvider {
  authenticate(input: {
    clientId: string;
    nonce: string;
    signal?: AbortSignal | undefined;
  }): Promise<DesktopGoogleAuthorizationCode>;
}

export interface DesktopGoogleAuthorizationCode {
  authorizationCode: string;
  codeVerifier: string;
  complete(success: boolean): void;
  redirectUri: string;
}

export interface OpenIdClientAdapter {
  calculatePKCECodeChallenge(verifier: string): Promise<string>;
  createAuthorizationUrl(
    configuration: unknown,
    parameters: Record<string, string>
  ): URL;
  discover(
    clientId: string,
    options: { signal: AbortSignal; timeoutMs: number }
  ): Promise<unknown>;
  randomPKCECodeVerifier(): string;
  randomState(): string;
  validateAuthorizationResponse(
    configuration: unknown,
    callbackUrl: URL,
    expectedState: string
  ): string;
}

const openIdClientAdapter: OpenIdClientAdapter = {
  calculatePKCECodeChallenge: oidc.calculatePKCECodeChallenge,
  createAuthorizationUrl(configuration, parameters) {
    return oidc.buildAuthorizationUrl(configuration as oidc.Configuration, parameters);
  },
  discover(clientId, { signal, timeoutMs }) {
    const operationFetch: oidc.CustomFetch = (url, options) => {
      const { body, ...request } = options;
      return fetch(url, {
        ...request,
        ...(body === undefined ? {} : { body: body as BodyInit }),
        signal: combineAbortSignals(signal, options.signal),
      });
    };

    return oidc.discovery(googleIssuer, clientId, undefined, oidc.None(), {
      [oidc.customFetch]: operationFetch,
      timeout: Math.max(1, Math.ceil(timeoutMs / 1_000)),
    });
  },
  randomPKCECodeVerifier: oidc.randomPKCECodeVerifier,
  randomState: oidc.randomState,
  validateAuthorizationResponse(configuration, callbackUrl, expectedState) {
    const resolved = configuration as oidc.Configuration;
    const parameters = oauth.validateAuthResponse(
      resolved.serverMetadata(),
      resolved.clientMetadata(),
      callbackUrl,
      expectedState
    );
    const authorizationCode = parameters.get("code")?.trim();
    if (!authorizationCode) {
      throw new Error("Google did not return an authorization code.");
    }
    return authorizationCode;
  },
};

export class SystemBrowserGoogleAuth implements DesktopGoogleAuthProvider {
  readonly #locale: MainLocaleSource;
  readonly #oidc: OpenIdClientAdapter;
  readonly #openExternal: (url: string) => Promise<void>;
  readonly #timeoutMs: number;

  constructor({
    locale = baseLocale,
    oidcAdapter = openIdClientAdapter,
    openExternal,
    timeoutMs = defaultTimeoutMs,
  }: {
    locale?: MainLocaleSource;
    oidcAdapter?: OpenIdClientAdapter | undefined;
    openExternal: (url: string) => Promise<void>;
    timeoutMs?: number | undefined;
  }) {
    this.#locale = locale;
    this.#oidc = oidcAdapter;
    this.#openExternal = openExternal;
    this.#timeoutMs = timeoutMs;
  }

  async authenticate({
    clientId,
    nonce,
    signal,
  }: {
    clientId: string;
    nonce: string;
    signal?: AbortSignal | undefined;
  }): Promise<DesktopGoogleAuthorizationCode> {
    const timeoutMs = normalizeTimeout(this.#timeoutMs);
    const operationSignal = combineAbortSignals(signal, AbortSignal.timeout(timeoutMs));
    let callback: LoopbackCallback | undefined;
    let completionHandedOff = false;

    try {
      throwIfAborted(operationSignal);
      callback = await LoopbackCallback.open({
        locale: readMainLocale(this.#locale),
        signal: operationSignal,
      });
      const configuration = await waitForOperation(
        this.#oidc.discover(clientId, {
          signal: operationSignal,
          timeoutMs,
        }),
        operationSignal
      );

      const codeVerifier = this.#oidc.randomPKCECodeVerifier();
      const codeChallenge = await waitForOperation(
        this.#oidc.calculatePKCECodeChallenge(codeVerifier),
        operationSignal
      );
      const state = this.#oidc.randomState();
      const authorizationUrl = this.#oidc.createAuthorizationUrl(configuration, {
        client_id: clientId,
        code_challenge: codeChallenge,
        code_challenge_method: "S256",
        nonce,
        prompt: "select_account",
        redirect_uri: callback.redirectUri,
        response_type: "code",
        scope: "openid email profile",
        state,
      });

      await waitForOperation(
        this.#openExternal(authorizationUrl.href),
        operationSignal
      );
      const callbackUrl = await waitForOperation(callback.wait(), operationSignal);
      const authorizationCode = this.#oidc.validateAuthorizationResponse(
        configuration,
        callbackUrl,
        state
      );
      const liveCallback = callback;
      let completed = false;
      completionHandedOff = true;
      return {
        authorizationCode,
        codeVerifier,
        complete(success) {
          if (completed) return;
          completed = true;
          liveCallback.complete(success);
          liveCallback.close();
        },
        redirectUri: callback.redirectUri,
      };
    } catch {
      callback?.complete(false);
      throw new Error("Google sign-in could not be completed.");
    } finally {
      if (!completionHandedOff) callback?.close();
    }
  }
}

class LoopbackCallback {
  readonly redirectUri: string;
  readonly #cancelWait: (error: Error) => void;
  readonly #server: Server;
  readonly #waitPromise: Promise<URL>;
  #completeResponse: ((success: boolean) => void) | undefined;
  #closed = false;

  private constructor({
    cancelWait,
    redirectUri,
    server,
    waitPromise,
  }: {
    cancelWait: (error: Error) => void;
    redirectUri: string;
    server: Server;
    waitPromise: Promise<URL>;
  }) {
    this.#cancelWait = cancelWait;
    this.redirectUri = redirectUri;
    this.#server = server;
    this.#waitPromise = waitPromise;
  }

  static async open({
    locale,
    signal,
  }: {
    locale: CommaLocale;
    signal: AbortSignal;
  }): Promise<LoopbackCallback> {
    let resolveCallback!: (url: URL) => void;
    let rejectCallback!: (error: Error) => void;
    let consumed = false;
    let origin = "http://127.0.0.1";
    let response: import("node:http").ServerResponse | undefined;
    let settled = false;

    const waitPromise = new Promise<URL>((resolve, reject) => {
      resolveCallback = (url) => {
        if (!settled) {
          settled = true;
          resolve(url);
        }
      };
      rejectCallback = (error) => {
        if (!settled) {
          settled = true;
          reject(error);
        }
      };
    });

    const server = createServer((request, nextResponse) => {
      const requestUrl = new URL(request.url ?? "/", origin);

      if (request.method !== "GET" || requestUrl.pathname !== callbackPath) {
        sendCallbackResponse(
          nextResponse,
          404,
          messages.auth_callback_not_found({}, { locale })
        );
        return;
      }

      if (consumed) {
        sendCallbackResponse(
          nextResponse,
          409,
          messages.auth_callback_already_used({}, { locale })
        );
        return;
      }

      consumed = true;
      response = nextResponse;
      resolveCallback(requestUrl);
    });

    await listenOnLoopback(server);
    const address = server.address() as AddressInfo;
    origin = `http://127.0.0.1:${address.port}`;
    const redirectUri = `http://127.0.0.1:${address.port}${callbackPath}`;
    const callback = new LoopbackCallback({
      cancelWait: rejectCallback,
      redirectUri,
      server,
      waitPromise,
    });

    callback.#completeResponse = (success) => {
      if (!response || response.writableEnded) {
        return;
      }

      sendCallbackResponse(
        response,
        success ? 200 : 400,
        success
          ? messages.auth_callback_complete({}, { locale })
          : messages.auth_callback_failed({}, { locale })
      );
    };

    const abort = () => {
      callback.close(new Error("Google sign-in was canceled."));
    };

    signal.addEventListener("abort", abort, { once: true });
    const cleanup = () => {
      signal.removeEventListener("abort", abort);
    };
    void waitPromise.then(cleanup, cleanup);

    if (signal.aborted) {
      abort();
    }

    return callback;
  }

  wait() {
    return this.#waitPromise;
  }

  complete(success: boolean) {
    this.#completeResponse?.(success);
  }

  close(error = new Error("Google sign-in callback was closed.")) {
    if (this.#closed) {
      return;
    }
    this.#closed = true;
    this.#cancelWait(error);
    this.#server.close();
  }
}

function listenOnLoopback(server: Server) {
  return new Promise<void>((resolve, reject) => {
    const onError = (error: Error) => {
      server.off("listening", onListening);
      reject(error);
    };
    const onListening = () => {
      server.off("error", onError);
      resolve();
    };

    server.once("error", onError);
    server.once("listening", onListening);
    server.listen(0, "127.0.0.1");
  });
}

function sendCallbackResponse(
  response: import("node:http").ServerResponse,
  status: number,
  message: string
) {
  response.writeHead(status, {
    "cache-control": "no-store",
    connection: "close",
    "content-type": "text/plain; charset=utf-8",
    "x-content-type-options": "nosniff",
  });
  response.end(message);
}

function throwIfAborted(signal: AbortSignal | undefined) {
  if (signal?.aborted) {
    throw new Error("Google sign-in was canceled.");
  }
}

function combineAbortSignals(
  first: AbortSignal | undefined,
  second: AbortSignal | undefined
) {
  const signals = [first, second].filter(
    (candidate): candidate is AbortSignal => candidate !== undefined
  );
  return signals.length === 1 ? signals[0]! : AbortSignal.any(signals);
}

function normalizeTimeout(timeoutMs: number) {
  return Number.isFinite(timeoutMs) ? Math.max(1, Math.trunc(timeoutMs)) : 1;
}

function waitForOperation<T>(operation: Promise<T>, signal: AbortSignal) {
  if (signal.aborted) {
    return Promise.reject(new Error("Google sign-in was canceled."));
  }

  return new Promise<T>((resolve, reject) => {
    const abort = () => {
      reject(new Error("Google sign-in was canceled."));
    };
    signal.addEventListener("abort", abort, { once: true });
    void operation.then(
      (value) => {
        signal.removeEventListener("abort", abort);
        resolve(value);
      },
      (error: unknown) => {
        signal.removeEventListener("abort", abort);
        reject(error);
      }
    );
  });
}
