import { createHash } from "node:crypto";
import { afterEach, describe, expect, it, vi } from "vitest";
import { sessionProductLease } from "@comma/session-contract";
import {
  tokenDanceAuthorizationStartCapability,
  tokenDanceAuthorizationStatusCapability,
  tokenDanceAuthorizationSaveCapability,
} from "@comma/native-bridge";
import {
  MainNativeSessionAdmissionGuard,
  MainProductCredentialAuthority,
} from "../modules/session";
import type { MainSessionBoundApi } from "../modules/session/main-session-transport";
import { TokenDanceAuthorizationService } from "../tokendance-authorization";
import { getCommaReleaseConfig } from "../../release-config";
import type { CommaChannel } from "@comma/config";

const services: TokenDanceAuthorizationService[] = [];
afterEach(() => services.splice(0).forEach((service) => service.dispose()));
const input = {
  requestId: "11111111-1111-4111-8111-111111111111",
  workspaceId: "workspace",
};
const models = {
  base_url: "https://tokendance.space/gateway/v1",
  provider: "openai",
  protocol: "responses",
  truncated: false,
  data: [
    {
      id: "gpt-model",
      name: "GPT model",
      supports_images: false,
      supported_protocols: ["responses", "chat_completions"],
    },
  ],
};

function setup(timeoutMs?: number, channel: CommaChannel = "dev") {
  const authority = new MainProductCredentialAuthority({
    authorityInstanceId: "test",
    trustedAudience: "https://cue.test",
  });
  const session = sessionProductLease(
    authority.acceptVerifiedCredential({
      audience: "https://cue.test",
      email: "user@example.test",
      expiresAtEpochSeconds: 1900000000,
      sessionId: "test-session",
      token: "main-session-secret",
      userId: "user",
    })
  )!;
  const guard = new MainNativeSessionAdmissionGuard(authority);
  const abort = new AbortController();
  const current = vi.fn().mockReturnValue(true);
  const discover = vi.fn().mockResolvedValue(models);
  const create = vi.fn().mockResolvedValue({ template_id: "saved" });
  const boundary = {
    api: { discoverModels: discover, createModelTemplate: create },
    session,
    assertCurrent: () => {
      if (!current()) throw new Error("stale_session");
    },
    isCurrent: current,
    signal: abort.signal,
  } as unknown as MainSessionBoundApi & { signal: AbortSignal };
  const open = vi.fn().mockResolvedValue(undefined);
  const exchange = vi
    .fn<typeof fetch>()
    .mockImplementation(async () => Response.json({ key: "provider-key-secret" }));
  const returnToApp = vi.fn();
  const service = new TokenDanceAuthorizationService(
    () => boundary,
    open,
    exchange,
    timeoutMs,
    { url: "comma-dev://authorization/return", open: returnToApp },
    getCommaReleaseConfig(channel)
  );
  services.push(service);
  const startInput = tokenDanceAuthorizationStartCapability.input.parse({
    ...input,
    session,
  });
  const statusInput = tokenDanceAuthorizationStatusCapability.input.parse({
    requestId: input.requestId,
    session,
  });
  const start = () =>
    guard.run({
      contract: tokenDanceAuthorizationStartCapability.contract,
      input: startInput,
      handler: () => service.start(startInput),
    });
  const status = () =>
    guard.run({
      contract: tokenDanceAuthorizationStatusCapability.contract,
      input: statusInput,
      handler: () => service.status(statusInput),
    });
  const saveInput = tokenDanceAuthorizationSaveCapability.input.parse({
    ...statusInput,
    name: "My TokenDance model",
    model: "gpt-model",
    maxTokens: 4096,
    contextTokens: 0,
  });
  const save = () =>
    guard.run({
      contract: tokenDanceAuthorizationSaveCapability.contract,
      input: saveInput,
      handler: () => service.save(saveInput),
    });
  const callback = (code = "one-time-code") => {
    const authorization = new URL(open.mock.calls[0]![0]);
    const url = new URL(authorization.searchParams.get("callback_url")!);
    url.searchParams.set("code", code);
    return url;
  };
  return {
    service,
    returnToApp,
    session,
    guard,
    start,
    status,
    save,
    saveInput,
    open,
    exchange,
    discover,
    create,
    current,
    abort,
    callback,
  };
}

describe("TokenDance Responses authorization", () => {
  it.each([
    ["prod", "app://comma", "Comma"],
    ["staging", "app://comma-staging", "Comma Staging"],
    ["dev", "app://comma-dev", "Comma Dev"],
  ] as const)(
    "attributes %s authorization to its build channel",
    async (channel, appUrl, keyName) => {
      const flow = setup(undefined, channel);
      expect(await flow.start()).toEqual({ status: "pending" });
      const authorization = new URL(flow.open.mock.calls[0]![0]);
      expect(authorization.searchParams.get("app_url")).toBe(appUrl);
      expect(authorization.searchParams.get("key_name")).toBe(keyName);
    }
  );

  it("uses a real loopback callback and PKCE, keeps the Key in Main, and saves to the original workspace", async () => {
    const flow = setup();
    expect(await flow.start()).toEqual({ status: "pending" });
    const authorization = new URL(flow.open.mock.calls[0]![0]);
    expect(authorization.origin).toBe("https://tokendance.space");
    expect(authorization.searchParams.get("app_url")).toBe("app://comma-dev");
    const callback = flow.callback();
    const wrongState = new URL(callback);
    wrongState.searchParams.set("state", "unrelated");
    expect((await fetch(wrongState)).status).toBe(400);
    expect(flow.exchange).not.toHaveBeenCalled();
    expect(flow.returnToApp).not.toHaveBeenCalled();
    const received = await fetch(callback);
    expect(received.status).toBe(200);
    expect(flow.returnToApp).toHaveBeenCalledOnce();
    expect(await received.text()).not.toContain("one-time-code");
    await vi.waitFor(async () => expect((await flow.status()).status).toBe("complete"));
    expect(flow.exchange).toHaveBeenCalledOnce();
    const [url, options] = flow.exchange.mock.calls[0]!;
    expect(url).toBe("https://tokendance.space/portal/api/v1/auth/keys");
    expect(options?.redirect).toBe("error");
    const body = JSON.parse(options?.body as string);
    expect(body.code).toBe("one-time-code");
    expect(createHash("sha256").update(body.code_verifier).digest("base64url")).toBe(
      authorization.searchParams.get("code_challenge")
    );
    expect(flow.discover).toHaveBeenCalledWith(
      "workspace",
      {
        base_url: "https://tokendance.space/gateway/v1",
        api_key: "provider-key-secret",
        protocol: "responses",
      },
      expect.objectContaining({ signal: expect.any(AbortSignal) })
    );
    const metadata = tokenDanceAuthorizationStatusCapability.output.parse(
      await flow.status()
    );
    expect(metadata.models?.data[0]?.supported_protocols).toEqual([
      "responses",
      "chat_completions",
    ]);
    expect(JSON.stringify(metadata)).not.toContain("secret");
    expect(await flow.save()).toEqual({ ok: true });
    expect(flow.create).toHaveBeenCalledWith(
      "workspace",
      expect.objectContaining({
        model: "gpt-model",
        protocol: "responses",
        provider: "openai",
        base_url: "https://tokendance.space/gateway/v1",
        api_key: "provider-key-secret",
      })
    );
    await expect(flow.save()).rejects.toThrow();
    await expect(fetch(callback)).rejects.toThrow();
  });

  it("discards an exchange result when authorization is cancelled or the Session changes", async () => {
    for (const stop of ["cancel", "session"] as const) {
      const flow = setup();
      const exchanging = Promise.withResolvers<Response>();
      flow.exchange.mockReturnValueOnce(exchanging.promise);
      await flow.start();
      const callback = flow.callback();
      await fetch(callback);
      await vi.waitFor(() => expect(flow.exchange).toHaveBeenCalledOnce());
      if (stop === "cancel") flow.service.cancel(input);
      else {
        flow.current.mockReturnValue(false);
        flow.abort.abort();
      }
      exchanging.resolve(Response.json({ key: "late-secret" }));
      await vi.waitFor(async () =>
        expect((await flow.service.status(input)).status).toBe("failed")
      );
      expect(flow.discover).not.toHaveBeenCalled();
      await expect(flow.save()).rejects.toThrow();
      expect(flow.create).not.toHaveBeenCalled();
    }
  });

  it("expires abandoned authorization and rejects models outside the discovered list", async () => {
    const expired = setup(30);
    await expired.start();
    const callback = expired.callback();
    await vi.waitFor(async () =>
      expect((await expired.status()).error).toBe("authorization_expired")
    );
    await expect(fetch(callback)).rejects.toThrow();
    const flow = setup();
    await flow.start();
    await fetch(flow.callback());
    await vi.waitFor(async () => expect((await flow.status()).status).toBe("complete"));
    await expect(
      flow.service.save({ ...flow.saveInput, model: "video-model" })
    ).rejects.toThrow("invalid_model_configuration");
    expect(flow.create).not.toHaveBeenCalled();
  });

  it("keeps a new authorization when an earlier cancelled save completes", async () => {
    const flow = setup();
    await flow.start();
    await fetch(flow.callback());
    await vi.waitFor(async () => expect((await flow.status()).status).toBe("complete"));
    const saving = Promise.withResolvers<{ template_id: string }>();
    flow.create.mockReturnValueOnce(saving.promise);
    const saved = flow.save();
    await vi.waitFor(() => expect(flow.create).toHaveBeenCalledOnce());
    flow.service.cancel(input);
    const next = { ...input, requestId: "22222222-2222-4222-8222-222222222222" };
    expect(await flow.service.start(next)).toEqual({ status: "pending" });
    saving.resolve({ template_id: "saved" });
    await saved;
    expect(flow.service.status(next)).toEqual({ status: "pending" });
  });

  it("bounds the Key response and never exposes provider error content", async () => {
    const flow = setup();
    flow.exchange.mockResolvedValueOnce(Response.json({ key: "x".repeat(20_000) }));
    await flow.start();
    await fetch(flow.callback());
    await vi.waitFor(async () => expect((await flow.status()).status).toBe("failed"));
    expect(await flow.status()).toEqual({
      status: "failed",
      error: "authorization_failed",
    });
    expect(flow.discover).not.toHaveBeenCalled();
  });
});
