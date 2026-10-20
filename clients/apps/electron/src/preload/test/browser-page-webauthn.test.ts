import { createContext, runInContext } from "node:vm";
import { describe, expect, it, vi } from "vitest";
import { installBrowserPageWebAuthnGuard } from "../browser-page-webauthn";

const challenge = new Uint8Array(32);
const shortWait = { maxMs: 40, minMs: 20 };

// Chromium in Electron: a request waits until its caller aborts it.
const pendingUntilAborted = (options?: CredentialRequestOptions) =>
  new Promise((_resolve, reject) => {
    options?.signal?.addEventListener("abort", () => reject(options.signal!.reason), {
      once: true,
    });
  });

// Response constructors the page can test with `instanceof`.
function AttestationResponse() {}
function AssertionResponse() {}

interface Broker {
  next(): Promise<Record<string, unknown>>;
  settle(document: unknown, id: unknown, outcome: unknown): void;
}

/**
 * A page of a browser tab whose static methods report autofill, phone sign-in
 * and platform passkeys, as Electron's do. The guard runs from its source in
 * a realm of its own, as `contextBridge.executeInMainWorld` runs it.
 */
function installElectronWebAuthn({
  topFrame = true,
  systemDialog = false,
}: { topFrame?: boolean; systemDialog?: boolean } = {}) {
  const nativeGet = vi.fn(pendingUntilAborted);
  const nativeCreate = vi.fn(pendingUntilAborted);
  class FakeCredentialsContainer {
    create(options?: CredentialCreationOptions) {
      return nativeCreate(options);
    }
    get(options?: CredentialRequestOptions) {
      return nativeGet(options);
    }
  }
  // Constructors the page can test with `instanceof`; the page never calls them.
  const FakePublicKeyCredential = Object.assign(function PublicKeyCredential() {}, {
    getClientCapabilities: vi.fn(async () => ({
      conditionalCreate: true,
      conditionalGet: true,
      "extension:prf": true,
      hybridTransport: true,
      passkeyPlatformAuthenticator: true,
      userVerifyingPlatformAuthenticator: false,
    })),
    isConditionalMediationAvailable: vi.fn(async () => true),
    isUserVerifyingPlatformAuthenticatorAvailable: vi.fn(async () => false),
  });
  // Node fires `AbortSignal.timeout` after real time, on a timer that fake
  // timers do not reach; the page's timeouts expire when the test says so.
  const timeouts: Array<{ delay: number; expire(): void }> = [];
  const FakeAbortSignal = {
    any: (signals: AbortSignal[]) => AbortSignal.any(signals),
    timeout(delay: number) {
      const timeout = new AbortController();
      timeouts.push({
        delay,
        expire: () =>
          timeout.abort(new DOMException("signal timed out", "TimeoutError")),
      });
      return timeout.signal;
    },
  };
  const page: Record<string, unknown> = {
    AbortController,
    AbortSignal: FakeAbortSignal,
    AuthenticatorAssertionResponse: AssertionResponse,
    AuthenticatorAttestationResponse: AttestationResponse,
    CredentialsContainer: FakeCredentialsContainer,
    DOMException,
    PublicKeyCredential: FakePublicKeyCredential,
    atob,
    btoa,
    crypto,
    location: { origin: "https://login.example.com" },
    structuredClone,
  };
  page.self = page;
  page.top = topFrame ? page : {};
  const context = createContext(page);
  runInContext(
    `(${installBrowserPageWebAuthnGuard.toString()})(${JSON.stringify(shortWait)}, undefined, ${systemDialog})`,
    context
  );
  return {
    broker: runInContext("globalThis.__commaPasskeys", context) as Broker | undefined,
    credentialType: FakePublicKeyCredential,
    credentials: new FakeCredentialsContainer() as CredentialsContainer,
    nativeCreate,
    nativeGet,
    timeouts,
  };
}

const base64Url = (text: string) => Buffer.from(text).toString("base64url");
const creation = {
  challenge,
  pubKeyCredParams: [{ alg: -7, type: "public-key" as const }],
  rp: { name: "Example" },
  user: { displayName: "Ada", id: new Uint8Array([1, 2]), name: "ada@example.com" },
};

describe("installBrowserPageWebAuthnGuard", () => {
  it("reports only what a browser sidebar tab can do", async () => {
    const { credentialType } = installElectronWebAuthn();

    await expect(credentialType.isConditionalMediationAvailable()).resolves.toBe(false);
    await expect(credentialType.getClientCapabilities()).resolves.toEqual({
      conditionalCreate: false,
      conditionalGet: false,
      "extension:prf": true,
      hybridTransport: false,
      passkeyPlatformAuthenticator: false,
      userVerifyingPlatformAuthenticator: false,
    });
  });

  it("keeps autofill off the request slot so an explicit sign-in still runs", async () => {
    const { credentials, nativeGet, timeouts } = installElectronWebAuthn();
    const autofill = new AbortController();
    const autofillRequest = credentials.get({
      mediation: "conditional",
      publicKey: { challenge },
      signal: autofill.signal,
    });

    const signIn = credentials.get({ publicKey: { challenge } });

    expect(nativeGet).toHaveBeenCalledOnce();
    // No security key answers before the wait ends.
    timeouts[0]!.expire();
    await expect(signIn).rejects.toMatchObject({ name: "NotAllowedError" });
    autofill.abort(new DOMException("Autofill ended.", "AbortError"));
    await expect(autofillRequest).rejects.toMatchObject({ name: "AbortError" });
  });

  it("ends a request at once when only this Mac or a phone could answer it", async () => {
    const { credentials, nativeCreate, nativeGet } = installElectronWebAuthn();

    await expect(
      credentials.get({
        publicKey: {
          allowCredentials: [
            { id: challenge, transports: ["internal", "hybrid"], type: "public-key" },
          ],
          challenge,
          timeout: 300_000,
        },
      })
    ).rejects.toMatchObject({ name: "NotAllowedError" });
    await expect(
      credentials.create({
        publicKey: {
          authenticatorSelection: { authenticatorAttachment: "platform" },
          challenge,
          pubKeyCredParams: [{ alg: -7, type: "public-key" }],
          rp: { name: "Example" },
          user: { displayName: "Ada", id: challenge, name: "ada@example.com" },
        },
      })
    ).rejects.toMatchObject({ name: "NotAllowedError" });
    expect(nativeGet).not.toHaveBeenCalled();
    expect(nativeCreate).not.toHaveBeenCalled();
  });

  it("gives a security key a bounded wait and keeps the page's own abort reason", async () => {
    const { credentials, nativeGet, timeouts } = installElectronWebAuthn();

    const securityKey = credentials.get({
      publicKey: {
        allowCredentials: [{ id: challenge, transports: ["usb"], type: "public-key" }],
        challenge,
        timeout: 300_000,
      },
    });
    // The page asks for five minutes; a key gets the tab's longest wait.
    expect(timeouts.map(({ delay }) => delay)).toEqual([shortWait.maxMs]);
    const keySignal = nativeGet.mock.calls[0]?.[0]?.signal;
    expect(keySignal?.aborted).toBe(false);
    timeouts[0]!.expire();
    expect(keySignal?.aborted).toBe(true);
    await expect(securityKey).rejects.toMatchObject({ name: "NotAllowedError" });

    const page = new AbortController();
    const cancelled = credentials.get({
      publicKey: { challenge },
      signal: page.signal,
    });
    page.abort(new DOMException("The page cancelled.", "AbortError"));
    await expect(cancelled).rejects.toMatchObject({
      message: "The page cancelled.",
      name: "AbortError",
    });
  });

  it("sends a request a phone can answer to Main, and returns Main's credential", async () => {
    const { broker, credentialType, credentials } = installElectronWebAuthn();
    // Main starts polling once the document committed.
    const firstPoll = broker!.next();
    await expect(credentialType.getClientCapabilities()).resolves.toMatchObject({
      hybridTransport: true,
    });

    const created = credentials.create({ publicKey: creation });
    const request = await firstPoll;
    expect(request).toMatchObject({
      type: "request",
      origin: "https://login.example.com",
      id: 1,
      securityKey: true,
      request: {
        kind: "create",
        options: {
          challenge: Buffer.from(challenge).toString("base64url"),
          rp: { name: "Example" },
          user: { displayName: "Ada", id: "AQI", name: "ada@example.com" },
        },
      },
    });
    // Only the document that asked accepts the answer.
    broker!.settle("another-document", 1, {
      error: { message: "x", name: "SecurityError" },
    });
    broker!.settle(request.document, 1, {
      credential: {
        id: "AQID",
        authenticatorAttachment: "cross-platform",
        response: {
          clientDataJSON: base64Url("{}"),
          attestationObject: base64Url("attestation"),
          authenticatorData: base64Url("authenticator-data"),
          transports: ["hybrid", "internal"],
          publicKey: base64Url("spki"),
          publicKeyAlgorithm: -7,
        },
        clientExtensionResults: {},
      },
    });

    const credential = (await created) as PublicKeyCredential;
    expect(credential).toBeInstanceOf(credentialType);
    expect(credential.response).toBeInstanceOf(AttestationResponse);
    expect(new Uint8Array(credential.rawId)).toEqual(new Uint8Array([1, 2, 3]));
    expect(
      (credential.response as AuthenticatorAttestationResponse).getTransports()
    ).toEqual(["hybrid", "internal"]);
    expect(credential.toJSON()).toMatchObject({
      id: "AQID",
      rawId: "AQID",
      type: "public-key",
      response: { publicKeyAlgorithm: -7, transports: ["hybrid", "internal"] },
    });
  });

  it("tells Main when the page cancels or a security key answers first", async () => {
    const { broker, credentials, nativeCreate } = installElectronWebAuthn();
    const events: Array<Record<string, unknown>> = [];
    void (async () => {
      for (;;) events.push(await broker!.next());
    })();

    const page = new AbortController();
    const cancelled = credentials.get({
      publicKey: { challenge },
      signal: page.signal,
    });
    page.abort(new DOMException("The page cancelled.", "AbortError"));
    await expect(cancelled).rejects.toMatchObject({ name: "AbortError" });

    const securityKeyCredential = { id: "from-a-security-key" };
    nativeCreate.mockResolvedValueOnce(securityKeyCredential);
    await expect(credentials.create({ publicKey: creation })).resolves.toBe(
      securityKeyCredential
    );
    expect(events.map(({ id, type }) => `${String(type)}:${String(id)}`)).toEqual([
      "request:1",
      "cancel:1",
      "request:2",
      "cancel:2",
    ]);
  });

  it("keeps an iframe on the security key path", async () => {
    const { broker, credentialType, credentials } = installElectronWebAuthn({
      topFrame: false,
    });

    expect(broker).toBeUndefined();
    await expect(credentialType.getClientCapabilities()).resolves.toMatchObject({
      hybridTransport: false,
    });
    await expect(
      credentials.get({
        publicKey: {
          allowCredentials: [
            { id: challenge, transports: ["hybrid"], type: "public-key" },
          ],
          challenge,
        },
      })
    ).rejects.toMatchObject({ name: "NotAllowedError" });
  });

  it("on Windows leaves passkey requests to Windows' dialog and holds back only autofill", async () => {
    const { broker, credentialType, credentials, nativeCreate, nativeGet, timeouts } =
      installElectronWebAuthn({ systemDialog: true });

    await expect(credentialType.isConditionalMediationAvailable()).resolves.toBe(false);
    await expect(credentialType.getClientCapabilities()).resolves.toMatchObject({
      conditionalCreate: false,
      conditionalGet: false,
      hybridTransport: true,
      passkeyPlatformAuthenticator: true,
    });
    expect(broker).toBeUndefined();

    // Autofill started on load does not reach Windows, so it opens no dialog.
    const autofill = new AbortController();
    const autofillRequest = credentials.get({
      mediation: "conditional",
      publicKey: { challenge },
      signal: autofill.signal,
    });
    expect(nativeGet).not.toHaveBeenCalled();

    // A sign-in and a passkey for this computer go to Windows as the page asked,
    // with no wait of the tab's own.
    const page = new AbortController();
    void credentials.get({ publicKey: { challenge }, signal: page.signal });
    void credentials.create({
      publicKey: {
        ...creation,
        authenticatorSelection: { authenticatorAttachment: "platform" },
      },
      signal: page.signal,
    });
    expect(nativeGet).toHaveBeenCalledOnce();
    expect(nativeGet.mock.calls[0]![0]!.signal).toBe(page.signal);
    expect(nativeCreate).toHaveBeenCalledOnce();
    expect(timeouts).toEqual([]);

    autofill.abort(new DOMException("Autofill ended.", "AbortError"));
    await expect(autofillRequest).rejects.toMatchObject({ name: "AbortError" });
    page.abort();
  });

  it("leaves password and other non-WebAuthn requests unchanged", async () => {
    const { credentials, nativeGet } = installElectronWebAuthn();
    nativeGet.mockResolvedValueOnce(null);
    const options = { password: true } as CredentialRequestOptions;

    await expect(credentials.get(options)).resolves.toBeNull();
    expect(nativeGet).toHaveBeenCalledWith(options);
  });
});
