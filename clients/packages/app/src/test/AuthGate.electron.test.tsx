// An Electron window on the session the client core runs (packages/core, session/electron-lifecycle.ts): what AuthGate
// and the login screen show for the core's `session` topic, which `session.*` call each thing a person does makes, and
// the product requests the window makes through Main's `/v1` proxy for exactly the lease the core gives. The core is
// scripted.
import {
  sessionPresenceExpectationHeader,
  type SessionLifecycleSnapshot,
  type SignedInSessionSnapshot,
  type SignedOutSessionSnapshot,
} from "@comma/session-contract";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import {
  CommaAuthGate,
  CommaSessionHostProvider,
  createCoreSessionHostController,
} from "../index";

const authority = "core-authority";

function signedOutSnapshot(): SignedOutSessionSnapshot {
  return {
    authority: { authorityInstanceId: authority, kind: "electron_main" },
    cleanup: { revocation: "idle" },
    contractVersion: 1,
    generation: 0,
    phase: "signed_out",
    principal: null,
    reason: "no_session",
    revision: 1,
    session: null,
  };
}

function authenticatingSnapshot(revision: number): SessionLifecycleSnapshot {
  return {
    authority: { authorityInstanceId: authority, kind: "electron_main" },
    cleanup: { revocation: "idle" },
    contractVersion: 1,
    generation: 0,
    phase: "authenticating",
    principal: null,
    revision,
    session: null,
  };
}

function signedInSnapshot(): SignedInSessionSnapshot {
  return {
    authority: { authorityInstanceId: authority, kind: "electron_main" },
    cleanup: { revocation: "idle" },
    contractVersion: 1,
    generation: 1,
    phase: "signed_in",
    principal: { email: "person@example.com", userId: "user-1" },
    revision: 2,
    session: {
      audience: "https://api.example",
      expiresAtEpochSeconds: 2_000_000_000,
      sessionId: "11111111-1111-4111-8111-111111111111",
    },
  };
}

/** The `session` topic's value for a lifecycle snapshot. */
function topic(
  lifecycle: SessionLifecycleSnapshot,
  extra: Record<string, unknown> = {}
) {
  const account =
    lifecycle.phase === "signed_in"
      ? {
          phase: "signed_in",
          userId: lifecycle.principal.userId,
          audience: lifecycle.session.audience,
          sessionId: lifecycle.session.sessionId,
        }
      : { phase: lifecycle.phase === "signed_out" ? "signed_out" : "unknown" };
  return { ...account, lifecycle, attempt: null, guestImports: 0, ...extra };
}

const absence = {
  authorityInstanceId: authority,
  expectedSessionId: null,
  generation: 0,
};

/** An Electron window's controller over a scripted core; `answer` scripts the `session.*` calls. */
function electron(
  initial: SessionLifecycleSnapshot | undefined,
  answer: (name: string, params: unknown) => unknown = () => null,
  locale?: "zh-CN"
) {
  const calls: [string, unknown][] = [];
  const scripted = createScriptedCore({
    owns: (name) => name === "session" || name.startsWith("session."),
    values: (t) => (t.topic === "session" && initial ? topic(initial) : undefined),
    calls(name, params) {
      calls.push([name, params]);
      return answer(name, params);
    },
  });
  const controller = createCoreSessionHostController({
    apiBaseUrl: "assets://.",
    core: scripted.client,
    host: "electron",
    ...(locale ? { locale } : {}),
  });
  return {
    calls,
    controller,
    scripted,
    named: (name: string) => calls.filter(([n]) => n === name).map(([, p]) => p),
    /** The core sends a new `session` value. */
    send: (value: SessionLifecycleSnapshot, extra: Record<string, unknown> = {}) =>
      act(() => scripted.emit("session", topic(value, extra))),
  };
}

const challenge = (attemptId: string, challengeId: string, expected = absence) => ({
  ok: true,
  value: { attempt: { attemptId, expected }, challengeId },
});

describe("an Electron window on the core's session", () => {
  it("shows no session failure while the core has not answered at startup", async () => {
    const t = electron(undefined);
    render(
      t.scripted.wrap(
        <CommaSessionHostProvider controller={t.controller}>
          <CommaAuthGate signedOutFallback={<p>Signed out</p>}>
            <p>Product</p>
          </CommaAuthGate>
        </CommaSessionHostProvider>
      )
    );
    expect(screen.queryByRole("heading", { name: "Comma can’t continue" })).toBeNull();
    expect(screen.queryByText("Signed out")).toBeNull();
    t.send(signedOutSnapshot());
    expect(await screen.findByText("Signed out")).toBeVisible();
    t.controller.dispose?.();
  });

  it("asks the core to recover an unavailable session without inventing an expectation", async () => {
    const { reason: _reason, ...snapshot } = signedOutSnapshot();
    const t = electron({
      ...snapshot,
      phase: "indeterminate",
      problem: {
        code: "session_probe_unavailable",
        operation: "reconcile",
        recovery: "retry_operation",
        retryable: true,
      },
    });
    await waitFor(() =>
      expect(t.controller.lifecycle.getSnapshotSync().phase).toBe("indeterminate")
    );
    await t.controller.recover();
    expect(t.named("session.recover")).toEqual([{}]);
    t.controller.dispose?.();
  });

  it("passes the expectations and the attempt the core gave to its calls", async () => {
    const t = electron(signedOutSnapshot(), (name) => {
      if (name === "session.email.request")
        return challenge("attempt-1", "challenge-1");
      if (name === "session.email.verify")
        return { ok: true, value: signedInSnapshot() };
      if (name === "session.signOut") return { ok: true, value: signedOutSnapshot() };
      return null;
    });
    await waitFor(() =>
      expect(t.controller.lifecycle.getSnapshotSync().phase).toBe("signed_out")
    );
    const requested =
      await t.controller.authenticator.requestEmailLogin("person@example.com");
    expect(t.named("session.email.request")).toEqual([
      { email: "person@example.com", expected: absence },
    ]);
    await t.controller.authenticator.verifyEmailLogin({
      challengeId: requested.challengeId,
      code: "123456",
    });
    expect(t.named("session.email.verify")).toEqual([
      {
        attempt: { attemptId: "attempt-1", expected: absence },
        challengeId: "challenge-1",
        code: "123456",
      },
    ]);
    t.send(signedInSnapshot());
    await t.controller.lifecycle.signOut({
      expected: {
        authorityInstanceId: authority,
        expectedAudience: "https://api.example",
        expectedSessionId: "11111111-1111-4111-8111-111111111111",
        generation: 1,
      },
    });
    expect(t.named("session.signOut")).toEqual([
      {
        expected: {
          authorityInstanceId: authority,
          expectedAudience: "https://api.example",
          expectedSessionId: "11111111-1111-4111-8111-111111111111",
          generation: 1,
        },
      },
    ]);
  });

  it.each(["google", "email"] as const)(
    "replaces a pending Google sign-in with %s and ignores its late answer",
    async (replacement) => {
      let finishOld!: (value: unknown) => void;
      let googleCalls = 0;
      const t = electron(signedOutSnapshot(), (name) => {
        if (name === "session.google.desktop") {
          googleCalls += 1;
          if (googleCalls === 1)
            return new Promise((resolve) => {
              finishOld = resolve;
            });
          return {
            ok: true,
            value: {
              attempt: { attemptId: "new-attempt", expected: absence },
              challengeId: "new-challenge",
              email: "new@example.com",
              status: "otp_required",
            },
          };
        }
        if (name === "session.email.request")
          return challenge("attempt-1", "challenge-1");
        return null;
      });
      await waitFor(() =>
        expect(t.controller.lifecycle.getSnapshotSync().phase).toBe("signed_out")
      );
      const old = { onError: vi.fn(), onResult: vi.fn() };
      const pending = t.controller.authenticator.requestGoogleLogin!(old);
      await waitFor(() => expect(googleCalls).toBe(1));
      t.send(authenticatingSnapshot(2));
      const callbacks = { onError: vi.fn(), onResult: vi.fn() };
      if (replacement === "google") {
        await t.controller.authenticator.requestGoogleLogin!(callbacks);
        expect(callbacks.onError).not.toHaveBeenCalled();
        expect(callbacks.onResult).toHaveBeenCalledWith(
          expect.objectContaining({ challengeId: "new-challenge" })
        );
        // The core keeps the attempt: the same absence the first one named supersedes it.
        expect(t.named("session.google.desktop")).toEqual([
          { expected: absence },
          { expected: absence },
        ]);
      } else {
        await t.controller.authenticator.requestEmailLogin("person@example.com");
        expect(t.named("session.email.request")).toEqual([
          { email: "person@example.com", expected: absence },
        ]);
      }
      finishOld({
        ok: true,
        value: {
          attempt: { attemptId: "old-attempt", expected: absence },
          challengeId: "old-challenge",
          email: "old@example.com",
          status: "otp_required",
        },
      });
      await pending;
      expect(old.onResult).not.toHaveBeenCalled();
      expect(old.onError).not.toHaveBeenCalled();
      t.controller.dispose?.();
    }
  );

  it("names the same absence for a resend while the core is authenticating, and verifies the code the core waits for", async () => {
    let requests = 0;
    const t = electron(signedOutSnapshot(), (name) => {
      if (name === "session.email.request") {
        requests += 1;
        return challenge(`attempt-${requests}`, `challenge-${requests}`);
      }
      if (name === "session.email.verify")
        return { ok: true, value: signedInSnapshot() };
      return null;
    });
    await waitFor(() =>
      expect(t.controller.lifecycle.getSnapshotSync().phase).toBe("signed_out")
    );
    await t.controller.authenticator.requestEmailLogin("person@example.com");
    t.send(authenticatingSnapshot(2), {
      attempt: {
        ref: { attemptId: "attempt-1", expected: absence },
        method: "email",
        challenge: { challengeId: "challenge-1", purpose: "email_login" },
      },
    });
    const resent =
      await t.controller.authenticator.requestEmailLogin("person@example.com");
    expect(t.named("session.email.request")).toEqual([
      { email: "person@example.com", expected: absence },
      { email: "person@example.com", expected: absence },
    ]);
    await t.controller.authenticator.verifyEmailLogin({
      challengeId: resent.challengeId,
      code: "123456",
    });
    expect(t.named("session.email.verify")).toEqual([
      {
        attempt: { attemptId: "attempt-2", expected: absence },
        challengeId: "challenge-2",
        code: "123456",
      },
    ]);
  });

  it("keeps the attempt after a wrong code, so the right one goes to the same attempt", async () => {
    let verifications = 0;
    const t = electron(signedOutSnapshot(), (name) => {
      if (name === "session.email.request")
        return challenge("attempt-1", "challenge-1");
      if (name === "session.email.verify") {
        verifications += 1;
        return verifications === 1
          ? {
              ok: false,
              error: {
                code: "invalid_challenge",
                operation: "verify_email_login",
                recovery: "retry_operation",
                recoveryRef: {
                  authorityInstanceId: authority,
                  generation: 0,
                  revision: 2,
                },
                retryable: true,
              },
            }
          : { ok: true, value: signedInSnapshot() };
      }
      return null;
    });
    await waitFor(() =>
      expect(t.controller.lifecycle.getSnapshotSync().phase).toBe("signed_out")
    );
    const requested =
      await t.controller.authenticator.requestEmailLogin("person@example.com");
    await expect(
      t.controller.authenticator.verifyEmailLogin({
        challengeId: requested.challengeId,
        code: "000000",
      })
    ).rejects.toThrow();
    await t.controller.authenticator.verifyEmailLogin({
      challengeId: requested.challengeId,
      code: "123456",
    });
    expect(t.named("session.email.verify")).toEqual([
      expect.objectContaining({ code: "000000" }),
      {
        attempt: { attemptId: "attempt-1", expected: absence },
        challengeId: "challenge-1",
        code: "123456",
      },
    ]);
  });

  it("routes product requests only through Main's proxy, for exactly the lease the core gives", async () => {
    const t = electron(signedInSnapshot());
    await waitFor(() =>
      expect(t.controller.lifecycle.getSnapshotSync().phase).toBe("signed_in")
    );
    const transport = t.controller.getProductTransport();
    if (!transport) throw new Error("Expected a Main proxy product transport.");
    expect(t.controller.apiBaseUrl).toBe("assets://.");
    expect(transport.credentials).toBe("omit");
    const applied: Record<string, string> = {};
    transport.applyHeaders(applied);
    const headers = new Headers(applied);
    expect(headers.get("authorization")).toBeNull();
    expect(JSON.parse(headers.get(sessionPresenceExpectationHeader) ?? "")).toEqual({
      authorityInstanceId: authority,
      expectedAudience: "https://api.example",
      expectedSessionId: "11111111-1111-4111-8111-111111111111",
      generation: 1,
    });
  });

  it("aborts the old product transport when the core's lease changes", async () => {
    const t = electron(signedInSnapshot());
    await waitFor(() =>
      expect(t.controller.lifecycle.getSnapshotSync().phase).toBe("signed_in")
    );
    const first = t.controller.getProductTransport();
    expect(first).toBeDefined();
    t.send({ ...signedInSnapshot(), revision: 3 });
    expect(t.controller.getProductTransport()).toBe(first);
    expect(first?.signal.aborted).toBe(false);
    t.send({
      ...signedInSnapshot(),
      generation: 2,
      revision: 4,
      session: {
        ...signedInSnapshot().session,
        sessionId: "22222222-2222-4222-8222-222222222222",
      },
    });
    await waitFor(() => expect(first?.signal.aborted).toBe(true));
    expect(t.controller.getProductTransport()).not.toBe(first);
  });

  it("tells the core of a product 401 or 409 for the lease it gave", async () => {
    const t = electron(signedInSnapshot());
    await waitFor(() =>
      expect(t.controller.lifecycle.getSnapshotSync().phase).toBe("signed_in")
    );
    const transport = t.controller.getProductTransport()!;
    transport.reportSessionRejection(409);
    transport.reportSessionRejection(401);
    await waitFor(() =>
      expect(t.named("session.rejected")).toEqual([
        {
          generation: 1,
          sessionId: "11111111-1111-4111-8111-111111111111",
          status: 409,
        },
        {
          generation: 1,
          sessionId: "11111111-1111-4111-8111-111111111111",
          status: 401,
        },
      ])
    );
  });

  it("localizes the Electron Google control and its errors", async () => {
    const t = electron(
      signedOutSnapshot(),
      (name) =>
        name === "session.google.desktop"
          ? {
              ok: false,
              error: {
                code: "unsupported",
                operation: "sign_in_with_google",
                recovery: "none",
                recoveryRef: {
                  authorityInstanceId: authority,
                  generation: 0,
                  revision: 1,
                },
                retryable: false,
              },
            }
          : null,
      "zh-CN"
    );
    await waitFor(() =>
      expect(t.controller.lifecycle.getSnapshotSync().phase).toBe("signed_out")
    );
    const element = document.createElement("div");
    const onError = vi.fn();
    const teardown = await t.controller.authenticator.mountGoogleControl({
      element,
      onError,
      onResult: vi.fn(),
    });
    expect(element.textContent).toBe("使用 Google 继续");
    (element.firstElementChild as HTMLButtonElement).click();
    await waitFor(() =>
      expect(onError).toHaveBeenCalledWith(
        expect.objectContaining({ message: "此桌面环境不支持会话登录。" })
      )
    );
    teardown();
  });
});
