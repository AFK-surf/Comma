import { afterEach, describe, expect, it, vi } from "vitest";
import {
  SystemBrowserGoogleAuth,
  type OpenIdClientAdapter,
} from "../google-desktop-auth";

const pendingResponses: Promise<Response>[] = [];

afterEach(async () => {
  await Promise.allSettled(pendingResponses.splice(0));
});

describe("SystemBrowserGoogleAuth", () => {
  it("uses a random loopback redirect with PKCE, state, and nonce checks", async () => {
    const adapter = createAdapter();
    let callbackResponse: Promise<Response> | undefined;
    const openExternal = vi.fn(async (href: string) => {
      const authorizationUrl = new URL(href);
      const redirectUri = requiredParameter(authorizationUrl, "redirect_uri");
      const state = requiredParameter(authorizationUrl, "state");
      callbackResponse = fetch(`${redirectUri}?code=provider-code&state=${state}`);
      pendingResponses.push(callbackResponse);
    });
    const auth = new SystemBrowserGoogleAuth({
      oidcAdapter: adapter,
      openExternal,
    });

    const authorization = await auth.authenticate({
      clientId: "desktop-client",
      nonce: "backend-nonce",
    });
    expect(authorization).toMatchObject({
      authorizationCode: "provider-code",
      codeVerifier: "pkce-verifier",
      redirectUri: expect.stringMatching(
        /^http:\/\/127\.0\.0\.1:\d+\/oauth2\/callback$/
      ),
    });

    const authorizationParameters = vi.mocked(adapter.createAuthorizationUrl).mock
      .calls[0]?.[1];
    expect(authorizationParameters).toMatchObject({
      client_id: "desktop-client",
      code_challenge: "pkce-challenge",
      code_challenge_method: "S256",
      nonce: "backend-nonce",
      redirect_uri: expect.stringMatching(
        /^http:\/\/127\.0\.0\.1:\d+\/oauth2\/callback$/
      ),
      response_type: "code",
      scope: "openid email profile",
      state: "oauth-state",
    });
    authorization.complete(true);
    await expect(callbackResponse).resolves.toMatchObject({ status: 200 });
  });

  it("localizes the browser callback page for Simplified Chinese", async () => {
    let callbackResponse: Promise<Response> | undefined;
    const auth = new SystemBrowserGoogleAuth({
      locale: "zh-CN",
      oidcAdapter: createAdapter(),
      openExternal: async (href) => {
        const authorizationUrl = new URL(href);
        const redirectUri = requiredParameter(authorizationUrl, "redirect_uri");
        const state = requiredParameter(authorizationUrl, "state");
        callbackResponse = fetch(`${redirectUri}?code=provider-code&state=${state}`);
        pendingResponses.push(callbackResponse);
      },
    });

    const authorization = await auth.authenticate({
      clientId: "desktop-client",
      nonce: "backend-nonce",
    });
    expect(authorization).toMatchObject({ authorizationCode: "provider-code" });
    authorization.complete(true);

    expect(callbackResponse).toBeDefined();
    const response = await callbackResponse!;
    expect(response.status).toBe(200);
    await expect(response.text()).resolves.toContain("登录已完成，你可以返回 Comma。");
  });

  it.each(
    [
      {
        name: "fails closed when the certified client rejects callback state",
        query: "code=provider-code&state=wrong",
      },
      {
        name: "fails closed when Google returns an authorization error",
        query: "error=access_denied&state=oauth-state",
      },
    ].map((row) => [row.name, row] as [string, typeof row])
  )("%s", async (_name, { query }) => {
    let callbackResponse: Promise<Response> | undefined;
    const auth = new SystemBrowserGoogleAuth({
      oidcAdapter: createAdapter(),
      openExternal: async (href) => {
        const authorizationUrl = new URL(href);
        const redirectUri = requiredParameter(authorizationUrl, "redirect_uri");
        callbackResponse = fetch(`${redirectUri}?${query}`);
        pendingResponses.push(callbackResponse);
      },
    });

    await expect(
      auth.authenticate({ clientId: "desktop-client", nonce: "backend-nonce" })
    ).rejects.toThrow("Google sign-in could not be completed.");
    await expect(callbackResponse).resolves.toMatchObject({ status: 400 });
  });

  it("accepts the loopback callback only once", async () => {
    let firstResponse: Promise<Response> | undefined;
    let replayStatus: number | undefined;
    const auth = new SystemBrowserGoogleAuth({
      oidcAdapter: createAdapter(),
      openExternal: async (href) => {
        const authorizationUrl = new URL(href);
        const redirectUri = requiredParameter(authorizationUrl, "redirect_uri");
        firstResponse = fetch(`${redirectUri}?code=first&state=oauth-state`);
        pendingResponses.push(firstResponse);
        replayStatus = (await fetch(`${redirectUri}?code=replay&state=oauth-state`))
          .status;
      },
    });

    const authorization = await auth.authenticate({
      clientId: "desktop-client",
      nonce: "backend-nonce",
    });
    expect(authorization).toMatchObject({ authorizationCode: "first" });
    expect(replayStatus).toBe(409);
    authorization.complete(true);
    await expect(firstResponse).resolves.toMatchObject({ status: 200 });
  });

  it("closes the loopback listener on timeout or cancellation", async () => {
    const timedOut = new SystemBrowserGoogleAuth({
      oidcAdapter: createAdapter(),
      openExternal: async () => {},
      timeoutMs: 5,
    });
    await expect(
      timedOut.authenticate({ clientId: "desktop-client", nonce: "backend-nonce" })
    ).rejects.toThrow("Google sign-in could not be completed.");

    const controller = new AbortController();
    const canceled = new SystemBrowserGoogleAuth({
      oidcAdapter: createAdapter(),
      openExternal: async () => controller.abort(),
    });
    await expect(
      canceled.authenticate({
        clientId: "desktop-client",
        nonce: "backend-nonce",
        signal: controller.signal,
      })
    ).rejects.toThrow("Google sign-in could not be completed.");
  });

  it("times out while provider discovery never resolves without opening a browser", async () => {
    const openExternal = vi.fn(async () => {});
    const auth = new SystemBrowserGoogleAuth({
      oidcAdapter: createAdapter({
        discover: vi.fn(() => new Promise<never>(() => {})),
      }),
      openExternal,
      timeoutMs: 5,
    });

    await expect(
      auth.authenticate({ clientId: "desktop-client", nonce: "backend-nonce" })
    ).rejects.toThrow("Google sign-in could not be completed.");
    expect(openExternal).not.toHaveBeenCalled();
  });
});

function createAdapter(
  overrides: Partial<OpenIdClientAdapter> = {}
): OpenIdClientAdapter {
  return {
    calculatePKCECodeChallenge: vi.fn(async () => "pkce-challenge"),
    createAuthorizationUrl: vi.fn((_configuration, parameters) => {
      const url = new URL("https://accounts.google.test/o/oauth2/v2/auth");
      for (const [key, value] of Object.entries(parameters)) {
        url.searchParams.set(key, String(value));
      }
      return url;
    }),
    discover: vi.fn(async () => ({ issuer: "google" })),
    randomPKCECodeVerifier: vi.fn(() => "pkce-verifier"),
    randomState: vi.fn(() => "oauth-state"),
    validateAuthorizationResponse: vi.fn(
      (_configuration, callbackUrl, expectedState) => {
        if (callbackUrl.searchParams.has("error")) {
          throw new Error("provider rejected authorization");
        }
        if (callbackUrl.searchParams.get("state") !== expectedState) {
          throw new Error("state mismatch");
        }
        const code = callbackUrl.searchParams.get("code");
        if (!code) throw new Error("authorization code missing");
        return code;
      }
    ),
    ...overrides,
  };
}

function requiredParameter(url: URL, name: string) {
  const value = url.searchParams.get(name);
  if (!value) {
    throw new Error(`Missing ${name}.`);
  }
  return value;
}
