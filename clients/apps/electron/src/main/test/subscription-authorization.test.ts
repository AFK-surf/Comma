import { sessionProductLease } from "@comma/session-contract";
import {
  subscriptionAuthorizationStartCapability,
  subscriptionAuthorizationStatusCapability,
  subscriptionAuthorizationCancelCapability,
} from "@comma/native-bridge";
import {
  MainNativeSessionAdmissionGuard,
  MainProductCredentialAuthority,
} from "../modules/session";
import { createServer } from "node:http";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SubscriptionAuthorizationService } from "../subscription-authorization";
import type { MainSessionBoundApi } from "../modules/session/main-session-transport";

const services: SubscriptionAuthorizationService[] = [];
afterEach(() => services.splice(0).forEach((service) => service.dispose()));
function setup(timeoutMs?: number, provider: "codex" | "claude" = "codex") {
  const complete = vi.fn().mockResolvedValue({ id: "account" });
  const begin = vi.fn().mockResolvedValue({
    id: "backend-attempt",
    url:
      provider === "codex"
        ? "https://auth.openai.com/oauth/authorize?state=expected&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"
        : "https://claude.ai/oauth/authorize?state=expected&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback",
  });
  const current = vi.fn().mockReturnValue(true);
  const boundary = {
    api: { beginSubscriptionOAuth: begin, completeSubscriptionOAuth: complete },
    assertCurrent: () => {
      if (!current()) throw new Error("session changed");
    },
    isCurrent: current,
  } as unknown as MainSessionBoundApi;
  const open = vi.fn().mockResolvedValue(undefined);
  const returnToApp = vi.fn();
  const service = new SubscriptionAuthorizationService(
    () => boundary,
    open,
    timeoutMs,
    {
      url: "comma-dev://authorization/return",
      open: returnToApp,
    }
  );
  services.push(service);
  return { service, open, begin, complete, current, returnToApp };
}
const input = {
  requestId: "request",
  workspaceId: "workspace",
  provider: "codex" as const,
};
const callback = "http://127.0.0.1:1455/auth/callback";

describe("subscription browser authorization", () => {
  it.each(["codex", "claude"] as const)(
    "%s receives a real loopback callback, rejects unrelated state, exchanges only once, and releases the port",
    async (provider) => {
      const { service, open, complete, returnToApp } = setup(undefined, provider);
      const authority = new MainProductCredentialAuthority({
        authorityInstanceId: "authority-test",
        trustedAudience: "https://comma.test",
      });
      const session = sessionProductLease(
        authority.acceptVerifiedCredential({
          audience: "https://comma.test",
          email: "local@example.test",
          expiresAtEpochSeconds: 1900000000,
          sessionId: "session-test",
          token: "main-only",
          userId: "local-user",
        })
      );
      const guard = new MainNativeSessionAdmissionGuard(authority);
      const request = subscriptionAuthorizationStartCapability.input.parse({
        ...input,
        provider,
        session,
        requestId: "00000000-0000-4000-8000-000000000001",
      });
      const start = () =>
        guard.run({
          contract: subscriptionAuthorizationStartCapability.contract,
          input: request,
          handler: () => service.start(request),
        });
      const statusInput = subscriptionAuthorizationStatusCapability.input.parse({
        session,
        requestId: request.requestId,
      });
      const status = () =>
        guard.run({
          contract: subscriptionAuthorizationStatusCapability.contract,
          input: statusInput,
          handler: () => service.status(statusInput),
        });
      const providerCallback =
        provider === "codex"
          ? "http://127.0.0.1:1455/auth/callback"
          : "http://127.0.0.1:54545/callback";
      expect(await start()).toEqual({ status: "pending" });
      expect(open).toHaveBeenCalledOnce();
      expect((await fetch(`${providerCallback}?state=other&code=secret`)).status).toBe(
        400
      );
      expect(complete).not.toHaveBeenCalled();
      expect(returnToApp).not.toHaveBeenCalled();
      const response = await fetch(`${providerCallback}?state=expected&code=secret`);
      expect(response.status).toBe(200);
      expect(returnToApp).toHaveBeenCalledOnce();
      expect(response.headers.get("content-type")).toContain("text/html");
      const page = await response.text();
      expect(page).toContain("Authorization received");
      expect(page).not.toContain("secret");
      await vi.waitFor(async () => expect((await status()).status).toBe("complete"));
      expect(complete).toHaveBeenCalledExactlyOnceWith(
        "workspace",
        "backend-attempt",
        expect.stringContaining("code=secret")
      );
      expect(JSON.stringify(await status())).not.toContain("secret");
      expect(await start()).toEqual({ status: "pending" });
      const cancelInput =
        subscriptionAuthorizationCancelCapability.input.parse(statusInput);
      await guard.run({
        contract: subscriptionAuthorizationCancelCapability.contract,
        input: cancelInput,
        handler: () => service.cancel(cancelInput),
      });
      await expect(fetch(providerCallback)).rejects.toThrow();
    }
  );
  it("does not open a browser or start backend authorization when the port is occupied", async () => {
    const blocker = createServer();
    await new Promise<void>((resolve) => blocker.listen(1455, "127.0.0.1", resolve));
    try {
      const { service, open, begin } = setup();
      expect(await service.start(input)).toEqual({
        status: "failed",
        error: "authorization_port_in_use",
      });
      expect(open).not.toHaveBeenCalled();
      expect(begin).not.toHaveBeenCalled();
    } finally {
      await new Promise<void>((resolve) => blocker.close(() => resolve()));
    }
  });
  it("cancels a pending start before opening the browser and can retry", async () => {
    const { service, begin, open } = setup();
    const result = Promise.withResolvers<unknown>();
    begin.mockReturnValueOnce(result.promise);
    const starting = service.start(input);
    await vi.waitFor(() => expect(begin).toHaveBeenCalledOnce());
    service.cancel(input);
    result.resolve({ id: "attempt", url: "https://auth.openai.com" });
    await starting;
    expect(open).not.toHaveBeenCalled();
    expect(await service.start({ ...input, requestId: "retry" })).toEqual({
      status: "pending",
    });
  });
  it("expires an abandoned login and releases its listener", async () => {
    const { service } = setup(30);
    await service.start(input);
    await vi.waitFor(() =>
      expect(service.status(input)).toEqual({
        status: "failed",
        error: "authorization_expired",
      })
    );
    expect(await service.start({ ...input, requestId: "retry" })).toEqual({
      status: "pending",
    });
  });
  it("does not exchange credentials after the main session changes", async () => {
    const { service, current, complete, returnToApp } = setup();
    await service.start(input);
    current.mockReturnValue(false);
    await fetch(`${callback}?state=expected&code=secret`);
    expect(returnToApp).not.toHaveBeenCalled();
    expect(complete).not.toHaveBeenCalled();
    expect(service.status(input).status).toBe("failed");
  });
});
