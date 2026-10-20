/// <reference lib="dom" />

type CredentialOptions = (CredentialRequestOptions | CredentialCreationOptions) & {
  mediation?: string;
};
type PublicKeyOptions =
  | PublicKeyCredentialCreationOptions
  | PublicKeyCredentialRequestOptions;
type ClientCapabilities = Record<string, boolean>;
type PublicKeyCredentialStatics = typeof PublicKeyCredential & {
  getClientCapabilities?: () => Promise<ClientCapabilities>;
};
type Base64Url = string;

/** What Main returns for a request; `PageCredential` in Main's hybrid module. */
interface CredentialJson {
  id: Base64Url;
  authenticatorAttachment: string;
  response: {
    clientDataJSON: Base64Url;
    authenticatorData: Base64Url;
    attestationObject?: Base64Url;
    transports?: string[];
    publicKey?: Base64Url;
    publicKeyAlgorithm?: number;
    signature?: Base64Url;
    userHandle?: Base64Url | null;
  };
  clientExtensionResults: Record<string, unknown>;
}

type Outcome =
  | { credential: CredentialJson }
  | { error: { message: string; name: string } };

/** Messages to Main. Main reads them through `__commaPasskeys.next()`. */
type BrokerEvent =
  | {
      type: "request";
      document: string;
      origin: string;
      id: number;
      request: unknown;
      securityKey: boolean;
    }
  | { type: "cancel"; document: string; id: number }
  | { type: "replaced" };

/**
 * Electron has no WebAuthn account picker, phone sign-in or platform
 * authenticator, but Chromium still tells the page that they are available,
 * and it never ends a request at its timeout. A passkey prompt then waits with
 * no visible UI, and the pending request makes every later attempt fail with
 * "A request is already pending". Sites that start passkey autofill on load
 * block their own passkey button that way.
 *
 * Runs in the main world of browser sidebar pages before page scripts. It
 * reports only what the tab can do and ends each passkey request, so the site
 * offers its other sign-in methods. A USB security key is the one
 * authenticator that can answer here, and it keeps working.
 *
 * In the top frame of a browser tab, Main also answers passkey requests with
 * a phone: it polls `__commaPasskeys.next()` for requests, shows a QR code and
 * returns the credential with `__commaPasskeys.settle()`. Main takes the
 * origin from the frame, not from the page, and builds clientDataJSON itself.
 * A page that calls the broker itself only reaches its own requests.
 */
// oxlint-disable unicorn/consistent-function-scoping -- executeInMainWorld serializes this function body without module-scope helpers.
export function installBrowserPageWebAuthnGuard(
  wait: { maxMs: number; minMs: number } = { maxMs: 30_000, minMs: 10_000 },
  phoneWait: { maxMs: number; minMs: number } = { maxMs: 600_000, minMs: 180_000 },
  systemDialog = false
) {
  const credentialType = globalThis.PublicKeyCredential as
    | PublicKeyCredentialStatics
    | undefined;
  const container = globalThis.CredentialsContainer?.prototype;
  if (!credentialType || !container) return;

  // On Windows each request opens Windows' own passkey dialog, so requests go
  // to it as they are. Autofill is the exception: it needs an account list in
  // the page, which Electron does not show, and Windows answers it with a
  // dialog as soon as the page loads, holding the one request slot an explicit
  // sign-in needs. It stays pending, as for a user who picks no account.
  if (systemDialog) {
    const holdAutofill = <T extends (...args: never[]) => unknown>(target: T): T =>
      new Proxy(target, {
        apply(native, thisArg, args) {
          const options = args[0] as CredentialOptions | undefined;
          const signal = options?.signal ?? undefined;
          if (
            !options?.publicKey ||
            options.mediation !== "conditional" ||
            signal?.aborted
          ) {
            return Reflect.apply(native, thisArg, args);
          }
          return new Promise((_resolve, reject) => {
            signal?.addEventListener("abort", () => reject(signal.reason), {
              once: true,
            });
          });
        },
      });
    if (typeof credentialType.isConditionalMediationAvailable === "function") {
      credentialType.isConditionalMediationAvailable = new Proxy(
        credentialType.isConditionalMediationAvailable,
        { apply: () => Promise.resolve(false) }
      );
    }
    const systemCapabilities = credentialType.getClientCapabilities;
    if (typeof systemCapabilities === "function") {
      credentialType.getClientCapabilities = new Proxy(systemCapabilities, {
        apply: async (target, thisArg, args) => ({
          ...((await Reflect.apply(target, thisArg, args)) as ClientCapabilities),
          conditionalCreate: false,
          conditionalGet: false,
        }),
      });
    }
    container.get = holdAutofill(container.get);
    container.create = holdAutofill(container.create);
    return;
  }

  // Chromium rejects a request that timed out or that the user dismissed with
  // this error, and sites treat it as "show the other sign-in methods".
  const notAllowed = () =>
    new DOMException(
      "The operation either timed out or was not allowed. See: https://www.w3.org/TR/webauthn-2/#sctn-privacy-considerations-client.",
      "NotAllowedError"
    );
  // A Proxy keeps the native name, length and toString of a replaced method.
  const intercept = <T extends (...args: never[]) => unknown>(
    native: T,
    apply: (target: T, thisArg: unknown, args: unknown[]) => unknown
  ) => new Proxy(native, { apply });
  const clampWait = (timeout: unknown, limits: { maxMs: number; minMs: number }) =>
    Math.min(Math.max(Number(timeout) || limits.maxMs, limits.minMs), limits.maxMs);

  // The broker that Main polls. Only the top frame has one: Main reads the
  // origin of the frame it polls, and it polls only the top frame.
  const topFrame = globalThis.top === globalThis.self;
  const documentId = globalThis.crypto.randomUUID();
  const outbox: BrokerEvent[] = [];
  const settlers = new Map<number, (outcome: Outcome) => void>();
  let poll: ((event: BrokerEvent) => void) | undefined;
  let served = false;
  let lastId = 0;
  const post = (event: BrokerEvent) => {
    const waiting = poll;
    poll = undefined;
    if (waiting) waiting(event);
    else outbox.push(event);
  };
  if (topFrame) {
    Object.defineProperty(globalThis, "__commaPasskeys", {
      value: Object.freeze({
        next: () => {
          served = true;
          // A newer poll takes over; the older one ends.
          const replaced = poll;
          poll = undefined;
          replaced?.({ type: "replaced" });
          const queued = outbox.shift();
          return queued
            ? Promise.resolve(queued)
            : new Promise<BrokerEvent>((resolve) => {
                poll = resolve;
              });
        },
        settle: (document: unknown, id: unknown, outcome: Outcome) => {
          if (document !== documentId || typeof id !== "number") return;
          const settle = settlers.get(id);
          settlers.delete(id);
          settle?.(outcome);
        },
      }),
    });
  }
  const phoneAvailable = () => topFrame && served;

  const platformAuthenticatorAvailable = () =>
    Reflect.apply(
      credentialType.isUserVerifyingPlatformAuthenticatorAvailable,
      credentialType,
      []
    ) as Promise<boolean>;
  if (typeof credentialType.isConditionalMediationAvailable === "function") {
    credentialType.isConditionalMediationAvailable = intercept(
      credentialType.isConditionalMediationAvailable,
      () => Promise.resolve(false)
    );
  }
  const nativeCapabilities = credentialType.getClientCapabilities;
  if (typeof nativeCapabilities === "function") {
    credentialType.getClientCapabilities = intercept(
      nativeCapabilities,
      async (target, thisArg, args) => {
        const [capabilities, platform] = await Promise.all([
          Reflect.apply(target, thisArg, args) as Promise<ClientCapabilities>,
          platformAuthenticatorAvailable(),
        ]);
        return {
          ...capabilities,
          conditionalCreate: false,
          conditionalGet: false,
          hybridTransport: phoneAvailable(),
          passkeyPlatformAuthenticator: platform,
          userVerifyingPlatformAuthenticator: platform,
        };
      }
    );
  }

  // A USB security key can answer unless the credential is bound to this Mac
  // or to a phone (transports "internal" or "hybrid").
  const securityKeyCanAnswer = (
    kind: "create" | "get",
    publicKey: PublicKeyOptions
  ) => {
    if (kind === "create") {
      return (
        (publicKey as PublicKeyCredentialCreationOptions).authenticatorSelection
          ?.authenticatorAttachment !== "platform"
      );
    }
    const allowed = (publicKey as PublicKeyCredentialRequestOptions).allowCredentials;
    return (
      !allowed?.length ||
      allowed.some(
        (credential) =>
          !credential.transports?.length || credential.transports.includes("usb")
      )
    );
  };
  // A phone can answer unless the credential is bound to this Mac or to a
  // security key.
  const phoneCanAnswer = (kind: "create" | "get", publicKey: PublicKeyOptions) => {
    if (kind === "create") {
      return (
        (publicKey as PublicKeyCredentialCreationOptions).authenticatorSelection
          ?.authenticatorAttachment !== "platform"
      );
    }
    const allowed = (publicKey as PublicKeyCredentialRequestOptions).allowCredentials;
    return (
      !allowed?.length ||
      allowed.some(
        (credential) =>
          !credential.transports?.length || credential.transports.includes("hybrid")
      )
    );
  };

  const toBase64Url = (source: BufferSource) => {
    const bytes = ArrayBuffer.isView(source)
      ? new Uint8Array(source.buffer, source.byteOffset, source.byteLength)
      : new Uint8Array(source);
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
  };
  const fromBase64Url = (value: string) =>
    Uint8Array.from(
      atob(value.replaceAll("-", "+").replaceAll("_", "/")),
      (character) => character.charCodeAt(0)
    ).buffer;
  const descriptors = (list: readonly PublicKeyCredentialDescriptor[]) =>
    Array.from(list, (credential) => ({
      id: toBase64Url(credential.id),
      ...(credential.transports
        ? { transports: Array.from(credential.transports, String) }
        : {}),
    }));
  // The options as JSON, as Main reads them. Throws for options that the
  // native call rejects with a TypeError.
  const serialize = (kind: "create" | "get", publicKey: PublicKeyOptions) => {
    if (kind === "create") {
      const options = publicKey as PublicKeyCredentialCreationOptions;
      const selection = options.authenticatorSelection;
      return {
        kind,
        options: {
          challenge: toBase64Url(options.challenge),
          rp: {
            ...(options.rp.id === undefined ? {} : { id: String(options.rp.id) }),
            name: String(options.rp.name),
          },
          user: {
            id: toBase64Url(options.user.id),
            name: String(options.user.name),
            ...(options.user.displayName === undefined
              ? {}
              : { displayName: String(options.user.displayName) }),
          },
          pubKeyCredParams: Array.from(options.pubKeyCredParams, (parameter) => ({
            alg: Number(parameter.alg),
            type: String(parameter.type),
          })),
          ...(options.excludeCredentials
            ? { excludeCredentials: descriptors(options.excludeCredentials) }
            : {}),
          ...(selection
            ? {
                authenticatorSelection: {
                  ...(selection.residentKey === undefined
                    ? {}
                    : { residentKey: String(selection.residentKey) }),
                  ...(selection.requireResidentKey === undefined
                    ? {}
                    : { requireResidentKey: Boolean(selection.requireResidentKey) }),
                  ...(selection.userVerification === undefined
                    ? {}
                    : { userVerification: String(selection.userVerification) }),
                },
              }
            : {}),
          ...(options.attestation === undefined
            ? {}
            : { attestation: String(options.attestation) }),
          ...(options.extensions?.credProps ? { extensions: { credProps: true } } : {}),
        },
      };
    }
    const options = publicKey as PublicKeyCredentialRequestOptions;
    return {
      kind,
      options: {
        challenge: toBase64Url(options.challenge),
        ...(options.rpId === undefined ? {} : { rpId: String(options.rpId) }),
        ...(options.allowCredentials
          ? { allowCredentials: descriptors(options.allowCredentials) }
          : {}),
        ...(options.userVerification === undefined
          ? {}
          : { userVerification: String(options.userVerification) }),
      },
    };
  };

  // Builds the `PublicKeyCredential` the page receives. Own properties stand
  // in for the native getters, so `instanceof` and `toJSON()` work as usual.
  const define = (target: object, values: Record<string, unknown>) => {
    for (const [key, value] of Object.entries(values)) {
      Object.defineProperty(target, key, { enumerable: true, value });
    }
    return target;
  };
  const credentialFrom = (json: CredentialJson) => {
    const { response } = json;
    const attestation = response.attestationObject !== undefined;
    const responseJson = {
      clientDataJSON: response.clientDataJSON,
      authenticatorData: response.authenticatorData,
      ...(attestation
        ? {
            attestationObject: response.attestationObject,
            transports: response.transports ?? [],
            ...(response.publicKey ? { publicKey: response.publicKey } : {}),
            ...(response.publicKeyAlgorithm === undefined
              ? {}
              : { publicKeyAlgorithm: response.publicKeyAlgorithm }),
          }
        : {
            signature: response.signature,
            ...(response.userHandle ? { userHandle: response.userHandle } : {}),
          }),
    };
    const clientDataJSON = fromBase64Url(response.clientDataJSON);
    const nativeResponse = attestation
      ? define(Object.create(globalThis.AuthenticatorAttestationResponse.prototype), {
          clientDataJSON,
          attestationObject: fromBase64Url(response.attestationObject!),
          getAuthenticatorData: () => fromBase64Url(response.authenticatorData),
          getPublicKey: () =>
            response.publicKey ? fromBase64Url(response.publicKey) : null,
          getPublicKeyAlgorithm: () => response.publicKeyAlgorithm,
          getTransports: () => [...(response.transports ?? [])],
        })
      : define(Object.create(globalThis.AuthenticatorAssertionResponse.prototype), {
          clientDataJSON,
          authenticatorData: fromBase64Url(response.authenticatorData),
          signature: fromBase64Url(response.signature!),
          userHandle: response.userHandle ? fromBase64Url(response.userHandle) : null,
        });
    return define(Object.create(credentialType.prototype), {
      id: json.id,
      rawId: fromBase64Url(json.id),
      type: "public-key",
      authenticatorAttachment: json.authenticatorAttachment,
      response: nativeResponse,
      getClientExtensionResults: () => structuredClone(json.clientExtensionResults),
      toJSON: () =>
        structuredClone({
          id: json.id,
          rawId: json.id,
          type: "public-key",
          authenticatorAttachment: json.authenticatorAttachment,
          response: responseJson,
          clientExtensionResults: json.clientExtensionResults,
        }),
    });
  };

  // Main shows a QR code for a phone. A security key can answer at the same
  // time through the native call; the first answer wins.
  const viaPhone = (
    kind: "create" | "get",
    target: (...args: never[]) => unknown,
    thisArg: unknown,
    options: CredentialOptions,
    publicKey: PublicKeyOptions,
    request: unknown
  ) => {
    if (settlers.size > 0) {
      return Promise.reject(
        new DOMException("A request is already pending.", "NotAllowedError")
      );
    }
    const id = ++lastId;
    const pageSignal = options.signal ?? undefined;
    const securityKey = securityKeyCanAnswer(kind, publicKey);
    const native = new AbortController();
    const deadline = AbortSignal.timeout(clampWait(publicKey.timeout, phoneWait));
    return new Promise((resolve, reject) => {
      let done = false;
      const finish = (end: () => void, cancelInMain: boolean) => {
        if (done) return;
        done = true;
        settlers.delete(id);
        native.abort();
        pageSignal?.removeEventListener("abort", onAbort);
        deadline.removeEventListener("abort", onTimeout);
        if (cancelInMain) post({ type: "cancel", document: documentId, id });
        end();
      };
      const onAbort = () => finish(() => reject(pageSignal?.reason), true);
      const onTimeout = () => finish(() => reject(notAllowed()), true);
      pageSignal?.addEventListener("abort", onAbort, { once: true });
      deadline.addEventListener("abort", onTimeout, { once: true });
      settlers.set(id, (outcome) =>
        finish(() => {
          if ("credential" in outcome) {
            try {
              resolve(credentialFrom(outcome.credential));
            } catch {
              reject(notAllowed());
            }
          } else {
            reject(new DOMException(outcome.error.message, outcome.error.name));
          }
        }, false)
      );
      post({
        type: "request",
        document: documentId,
        origin: globalThis.location.origin,
        id,
        request,
        securityKey,
      });
      if (!securityKey) return;
      (
        Reflect.apply(target, thisArg, [
          { ...options, signal: native.signal },
        ]) as Promise<unknown>
      ).then(
        (credential) => finish(() => resolve(credential), true),
        (error: unknown) => {
          // A key that already holds a passkey for this account answers so.
          if ((error as Error | undefined)?.name === "InvalidStateError") {
            finish(() => reject(error), true);
          }
        }
      );
    });
  };

  const guard = (kind: "create" | "get") =>
    intercept(container[kind], (target, thisArg, args) => {
      const options = args[0] as CredentialOptions | undefined;
      const publicKey = options?.publicKey;
      const pageSignal = options?.signal ?? undefined;
      if (!options || !publicKey || pageSignal?.aborted) {
        return Reflect.apply(target, thisArg, args);
      }
      if (kind === "get" && options.mediation === "conditional") {
        // Autofill needs an account list that this tab cannot show. Stay
        // pending, as for a user who picks no account, without taking the
        // single request slot that an explicit passkey sign-in needs.
        return new Promise((_resolve, reject) => {
          pageSignal?.addEventListener("abort", () => reject(pageSignal.reason), {
            once: true,
          });
        });
      }
      if (
        phoneAvailable() &&
        options.mediation !== "conditional" &&
        options.mediation !== "silent" &&
        phoneCanAnswer(kind, publicKey)
      ) {
        let request: unknown;
        try {
          request = serialize(kind, publicKey);
        } catch {
          // The native call reports the invalid options.
          return Reflect.apply(target, thisArg, args);
        }
        return viaPhone(kind, target, thisArg, options, publicKey, request);
      }
      if (
        options.mediation === "conditional" ||
        !securityKeyCanAnswer(kind, publicKey)
      ) {
        return Promise.reject(notAllowed());
      }
      // Nothing on screen tells the user that the tab waits for a security
      // key, so the wait stays short. It is still long enough to insert and
      // touch a key.
      const deadline = AbortSignal.timeout(clampWait(publicKey.timeout, wait));
      const signal = pageSignal ? AbortSignal.any([pageSignal, deadline]) : deadline;
      return (
        Reflect.apply(target, thisArg, [{ ...options, signal }]) as Promise<unknown>
      ).catch((error: unknown) => {
        if (deadline.aborted && !pageSignal?.aborted) throw notAllowed();
        throw error;
      });
    });
  container.get = guard("get");
  container.create = guard("create");
}
