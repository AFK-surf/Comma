import type { SessionBridge } from "@comma/native-bridge";
import {
  sessionExpectation,
  sessionPresenceExpectationHeader,
  type SessionLifecycleSnapshot,
  type SignedInSessionSnapshot,
  type SignedOutSessionSnapshot,
} from "@comma/session-contract";
import { waitFor } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { createCommaApi, createElectronSessionHostController } from "../index";

describe("Electron generated Session host controller", () => {
  it("asks Main to recover an unavailable session without inventing an expectation", async () => {
    const { reason: _reason, ...snapshot } = signedOutSnapshot();
    const bridge = new FakeSessionBridge({
      ...snapshot,
      phase: "indeterminate",
      problem: {
        code: "session_probe_unavailable",
        operation: "reconcile",
        recovery: "retry_operation",
        retryable: true,
      },
    });
    const controller = createElectronSessionHostController({ bridge: bridge.value });
    await controller.initialize();
    await controller.recover();
    expect(bridge.value.reconcile).toHaveBeenCalledWith({ reason: "manual_retry" });
    controller.dispose?.();
  });

  it("passes caller-captured expectations and attempts to generated commands", async () => {
    const bridge = new FakeSessionBridge(signedOutSnapshot());
    const controller = createElectronSessionHostController({
      bridge: bridge.value,
    });
    await controller.initialize();

    const challenge =
      await controller.authenticator.requestEmailLogin("person@example.com");
    expect(bridge.requestEmailLogin).toHaveBeenCalledWith({
      email: "person@example.com",
      expected: {
        authorityInstanceId: "main-authority",
        expectedSessionId: null,
        generation: 0,
      },
    });

    await controller.authenticator.verifyEmailLogin({
      challengeId: challenge.challengeId,
      code: "123456",
    });
    expect(bridge.verifyEmailLogin).toHaveBeenCalledWith({
      attempt: {
        attemptId: "attempt-1",
        expected: {
          authorityInstanceId: "main-authority",
          expectedSessionId: null,
          generation: 0,
        },
      },
      challengeId: "challenge-1",
      code: "123456",
    });

    const signedIn = bridge.current;
    if (signedIn.phase !== "signed_in") {
      throw new Error("Expected Main to publish signed-in state.");
    }
    await controller.lifecycle.signOut({
      expected: sessionExpectation(signedIn),
    });
    expect(bridge.signOut).toHaveBeenCalledWith({
      expected: {
        authorityInstanceId: "main-authority",
        expectedAudience: "https://api.example",
        expectedSessionId: "11111111-1111-4111-8111-111111111111",
        generation: 1,
      },
    });
  });

  it.each(["google", "email"] as const)(
    "replaces pending Google with %s and ignores its late result",
    async (replacement) => {
      const bridge = new FakeSessionBridge(signedOutSnapshot());
      let finishOld!: () => void;
      const google = vi.mocked(bridge.value.signInWithGoogle);
      google.mockImplementationOnce(
        (input) =>
          new Promise((resolve) => {
            bridge.emit(authenticatingSnapshot(1));
            finishOld = () =>
              resolve({
                ok: true,
                value: {
                  status: "otp_required",
                  email: "old@example.com",
                  challengeId: "old-challenge",
                  attempt: { attemptId: "old-attempt", expected: input.expected },
                },
              });
          })
      );
      google.mockImplementationOnce(async (input) => ({
        ok: true,
        value: {
          status: "otp_required",
          email: "new@example.com",
          challengeId: "new-challenge",
          attempt: { attemptId: "new-attempt", expected: input.expected },
        },
      }));
      const controller = createElectronSessionHostController({ bridge: bridge.value });
      await controller.initialize();
      const oldCallbacks = { onResult: vi.fn(), onError: vi.fn() };
      const old = controller.authenticator.requestGoogleLogin!(oldCallbacks);
      await waitFor(() => expect(bridge.current.phase).toBe("authenticating"));
      const callbacks = { onResult: vi.fn(), onError: vi.fn() };
      if (replacement === "google") {
        await controller.authenticator.requestGoogleLogin!(callbacks);
        expect(callbacks.onError).not.toHaveBeenCalled();
        expect(callbacks.onResult).toHaveBeenCalledWith(
          expect.objectContaining({ challengeId: "new-challenge" })
        );
        expect(google).toHaveBeenCalledTimes(2);
        expect(google.mock.calls[1]![0].expected).toEqual(
          google.mock.calls[0]![0].expected
        );
      } else {
        await controller.authenticator.requestEmailLogin("person@example.com");
        expect(bridge.requestEmailLogin.mock.calls[0]![0].expected).toEqual(
          google.mock.calls[0]![0].expected
        );
      }
      finishOld();
      await old;
      expect(oldCallbacks.onResult).not.toHaveBeenCalled();
      expect(oldCallbacks.onError).not.toHaveBeenCalled();
      await controller.authenticator.cancelCurrentAttempt();
      expect(bridge.cancelAuthAttempt).toHaveBeenCalledWith({
        attempt: expect.objectContaining({
          attemptId: replacement === "google" ? "new-attempt" : "attempt-1",
        }),
      });
      controller.dispose?.();
    }
  );

  it("reuses the exact email attempt expectation while Main is authenticating", async () => {
    const bridge = new FakeSessionBridge(signedOutSnapshot());
    let requestCount = 0;
    bridge.requestEmailLogin.mockImplementation(async (input) => {
      requestCount += 1;
      bridge.emit(authenticatingSnapshot(bridge.current.revision + 1));
      return {
        ok: true as const,
        value: {
          attempt: {
            attemptId: `attempt-${requestCount}`,
            expected: input.expected,
          },
          challengeId: `challenge-${requestCount}`,
        },
      };
    });
    const controller = createElectronSessionHostController({ bridge: bridge.value });
    await controller.initialize();

    await controller.authenticator.requestEmailLogin("person@example.com");
    const replacement =
      await controller.authenticator.requestEmailLogin("person@example.com");

    expect(bridge.requestEmailLogin).toHaveBeenNthCalledWith(2, {
      email: "person@example.com",
      expected: {
        authorityInstanceId: "main-authority",
        expectedSessionId: null,
        generation: 0,
      },
    });

    await controller.authenticator.verifyEmailLogin({
      challengeId: replacement.challengeId,
      code: "123456",
    });
    expect(bridge.verifyEmailLogin).toHaveBeenCalledWith({
      attempt: {
        attemptId: "attempt-2",
        expected: {
          authorityInstanceId: "main-authority",
          expectedSessionId: null,
          generation: 0,
        },
      },
      challengeId: "challenge-2",
      code: "123456",
    });
  });

  it("clears a superseded renderer attempt when a failed start settles Main signed out", async () => {
    const bridge = new FakeSessionBridge(signedOutSnapshot());
    let requestCount = 0;
    bridge.requestEmailLogin.mockImplementation(async (input) => {
      requestCount += 1;
      if (requestCount === 1) {
        bridge.emit(authenticatingSnapshot(2));
        return {
          ok: true as const,
          value: {
            attempt: { attemptId: "attempt-1", expected: input.expected },
            challengeId: "challenge-1",
          },
        };
      }

      bridge.emit({ ...signedOutSnapshot(), revision: 3 });
      return {
        error: {
          code: "rate_limited" as const,
          operation: "request_email_login" as const,
          recovery: "retry_operation" as const,
          recoveryRef: {
            authorityInstanceId: "main-authority",
            generation: 0,
            revision: 3,
          },
          retryAfterMs: 60_000,
          retryable: true,
        },
        ok: false as const,
      };
    });
    const controller = createElectronSessionHostController({ bridge: bridge.value });
    await controller.initialize();

    const first =
      await controller.authenticator.requestEmailLogin("person@example.com");
    await expect(
      controller.authenticator.requestEmailLogin("person@example.com")
    ).rejects.toThrow();

    await expect(
      controller.authenticator.verifyEmailLogin({
        challengeId: first.challengeId,
        code: "123456",
      })
    ).rejects.toThrow();
    expect(bridge.verifyEmailLogin).not.toHaveBeenCalled();
  });

  it("keeps email and Google-link attempt purposes isolated in the renderer", async () => {
    const bridge = new FakeSessionBridge(signedOutSnapshot());
    const controller = createElectronSessionHostController({ bridge: bridge.value });
    await controller.initialize();

    const challenge =
      await controller.authenticator.requestEmailLogin("person@example.com");

    await expect(
      controller.authenticator.verifyGoogleLink({
        challengeId: challenge.challengeId,
        code: "123456",
      })
    ).rejects.toThrow();
    expect(bridge.value.verifyGoogleLink).not.toHaveBeenCalled();
  });

  it("keeps the exact renderer attempt after a retryable verification failure", async () => {
    const bridge = new FakeSessionBridge(signedOutSnapshot());
    bridge.requestEmailLogin.mockImplementation(async (input) => {
      bridge.emit(authenticatingSnapshot(2));
      return {
        ok: true as const,
        value: {
          attempt: { attemptId: "attempt-1", expected: input.expected },
          challengeId: "challenge-1",
        },
      };
    });
    bridge.verifyEmailLogin
      .mockResolvedValueOnce({
        error: {
          code: "invalid_challenge" as const,
          operation: "verify_email_login" as const,
          recovery: "retry_operation" as const,
          recoveryRef: {
            authorityInstanceId: "main-authority",
            generation: 0,
            revision: 2,
          },
          retryable: true,
        },
        ok: false as const,
      })
      .mockImplementationOnce(async () => {
        const snapshot = signedInSnapshot();
        bridge.emit(snapshot);
        return { ok: true as const, value: snapshot };
      });
    const controller = createElectronSessionHostController({ bridge: bridge.value });
    await controller.initialize();
    const challenge =
      await controller.authenticator.requestEmailLogin("person@example.com");

    await expect(
      controller.authenticator.verifyEmailLogin({
        challengeId: challenge.challengeId,
        code: "000000",
      })
    ).rejects.toThrow();
    await controller.authenticator.verifyEmailLogin({
      challengeId: challenge.challengeId,
      code: "123456",
    });

    expect(bridge.verifyEmailLogin).toHaveBeenNthCalledWith(2, {
      attempt: {
        attemptId: "attempt-1",
        expected: {
          authorityInstanceId: "main-authority",
          expectedSessionId: null,
          generation: 0,
        },
      },
      challengeId: "challenge-1",
      code: "123456",
    });
  });

  it("does not clear a replacement attempt when an older cancellation settles", async () => {
    const bridge = new FakeSessionBridge(signedOutSnapshot());
    const releaseCancellation = deferred<void>();
    let requestCount = 0;
    bridge.requestEmailLogin.mockImplementation(async (input) => {
      requestCount += 1;
      bridge.emit(authenticatingSnapshot(requestCount + 1));
      return {
        ok: true as const,
        value: {
          attempt: {
            attemptId: `attempt-${requestCount}`,
            expected: input.expected,
          },
          challengeId: `challenge-${requestCount}`,
        },
      };
    });
    bridge.cancelAuthAttempt.mockImplementationOnce(async () => {
      await releaseCancellation.promise;
      return { ok: true as const, value: signedOutSnapshot() };
    });
    const controller = createElectronSessionHostController({ bridge: bridge.value });
    await controller.initialize();

    await controller.authenticator.requestEmailLogin("person@example.com");
    const cancellation = controller.authenticator.cancelCurrentAttempt();
    await vi.waitFor(() => expect(bridge.cancelAuthAttempt).toHaveBeenCalledOnce());
    const replacement =
      await controller.authenticator.requestEmailLogin("person@example.com");

    releaseCancellation.resolve();
    await cancellation;
    await controller.authenticator.verifyEmailLogin({
      challengeId: replacement.challengeId,
      code: "123456",
    });

    expect(bridge.verifyEmailLogin).toHaveBeenCalledWith({
      attempt: expect.objectContaining({ attemptId: "attempt-2" }),
      challengeId: "challenge-2",
      code: "123456",
    });
  });

  it("clears an exact renderer attempt after Main reports a conflict", async () => {
    const bridge = new FakeSessionBridge(signedOutSnapshot());
    bridge.requestEmailLogin.mockImplementationOnce(async (input) => {
      bridge.emit(authenticatingSnapshot(2));
      return {
        ok: true as const,
        value: {
          attempt: { attemptId: "attempt-1", expected: input.expected },
          challengeId: "challenge-1",
        },
      };
    });
    bridge.verifyEmailLogin.mockResolvedValueOnce({
      error: {
        code: "conflict",
        operation: "verify_email_login",
        recovery: "new_auth_attempt",
        recoveryRef: {
          authorityInstanceId: "main-authority",
          generation: 0,
          revision: 2,
        },
        retryable: false,
      },
      ok: false,
    });
    const controller = createElectronSessionHostController({ bridge: bridge.value });
    await controller.initialize();
    const challenge =
      await controller.authenticator.requestEmailLogin("person@example.com");

    await expect(
      controller.authenticator.verifyEmailLogin({
        challengeId: challenge.challengeId,
        code: "123456",
      })
    ).rejects.toThrow();
    await expect(
      controller.authenticator.verifyEmailLogin({
        challengeId: challenge.challengeId,
        code: "123456",
      })
    ).rejects.toThrow();

    expect(bridge.verifyEmailLogin).toHaveBeenCalledOnce();
  });

  it("rejects stale Main projections by revision", async () => {
    const bridge = new FakeSessionBridge(signedOutSnapshot());
    const controller = createElectronSessionHostController({
      bridge: bridge.value,
    });
    await controller.initialize();

    bridge.emit(signedInSnapshot());
    bridge.emit({
      ...signedOutSnapshot(),
      revision: 1,
    });

    expect(controller.lifecycle.getSnapshotSync()).toMatchObject({
      generation: 1,
      phase: "signed_in",
      revision: 2,
    });
  });

  it("routes product requests only through the exact Main proxy lease", async () => {
    const bridge = new FakeSessionBridge(signedInSnapshot());
    const controller = createElectronSessionHostController({
      bridge: bridge.value,
    });
    await controller.initialize();
    const transport = controller.getProductTransport();
    if (!transport) {
      throw new Error("Expected a Main proxy product transport.");
    }
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) =>
      jsonResponse({
        data: [{ group_id: "group-1", id: "workspace-1", name: "Main" }],
      })
    );
    const api = createCommaApi({
      baseUrl: controller.apiBaseUrl,
      fetch: fetchMock,
      sessionTransport: transport,
      token: "",
    });

    await expect(api.listWorkspaces()).resolves.toEqual([
      { group_id: "group-1", id: "workspace-1", name: "Main" },
    ]);
    expect(controller.apiBaseUrl).toBe("assets://.");
    expect(transport.credentials).toBe("omit");
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [input, init] = fetchMock.mock.calls[0]!;
    expect(input).toBe("assets://./v1/comma/workspaces");
    expect(init).toEqual(
      expect.objectContaining({
        credentials: "omit",
      })
    );
    const expectationHeader = new Headers(init?.headers).get(
      sessionPresenceExpectationHeader
    );
    expect(expectationHeader).not.toBeNull();
    expect(JSON.parse(expectationHeader ?? "")).toEqual({
      authorityInstanceId: "main-authority",
      expectedAudience: "https://api.example",
      expectedSessionId: "11111111-1111-4111-8111-111111111111",
      generation: 1,
    });
  });

  it("aborts the old product transport when the Main lease changes", async () => {
    const bridge = new FakeSessionBridge(signedInSnapshot());
    const controller = createElectronSessionHostController({
      bridge: bridge.value,
    });
    const first = controller.getProductTransport();
    expect(first).toBeDefined();

    bridge.emit({ ...signedInSnapshot(), revision: 3 });
    expect(controller.getProductTransport()).toBe(first);
    expect(first?.signal.aborted).toBe(false);

    bridge.emit({
      ...signedInSnapshot(),
      generation: 2,
      revision: 4,
      session: {
        ...signedInSnapshot().session,
        sessionId: "22222222-2222-4222-8222-222222222222",
      },
    });

    expect(first?.signal.aborted).toBe(true);
    expect(controller.getProductTransport()).not.toBe(first);
  });

  it("settles a product 401 or 409 through an exact Main reconcile", async () => {
    const bridge = new FakeSessionBridge(signedInSnapshot());
    const controller = createElectronSessionHostController({
      bridge: bridge.value,
    });
    const rejected = controller.getProductTransport();
    if (!rejected) {
      throw new Error("Expected a Main proxy product transport.");
    }

    rejected.reportSessionRejection(409);

    expect(rejected.signal.aborted).toBe(true);
    expect(controller.getProductTransport()).toBeUndefined();
    await waitFor(() =>
      expect(bridge.reconcile).toHaveBeenCalledWith({
        expected: {
          authorityInstanceId: "main-authority",
          expectedAudience: "https://api.example",
          expectedSessionId: "11111111-1111-4111-8111-111111111111",
          generation: 1,
        },
        reason: "peer_mutation",
      })
    );
    await waitFor(() => {
      expect(controller.getProductTransport()).toBeDefined();
    });

    const callsBefore = bridge.reconcile.mock.calls.length;
    rejected.reportSessionRejection(401);
    expect(bridge.reconcile).toHaveBeenCalledTimes(callsBefore);
  });

  it("localizes Electron-owned authentication controls and errors", async () => {
    const bridge = new FakeSessionBridge(signedOutSnapshot());
    const controller = createElectronSessionHostController({
      bridge: bridge.value,
      locale: "zh-CN",
    });
    await controller.initialize();
    const element = document.createElement("div");
    const onError = vi.fn();
    const teardown = await controller.authenticator.mountGoogleControl({
      element,
      onError,
      onResult: vi.fn(),
    });

    expect(element.textContent).toBe("使用 Google 继续");
    (element.firstElementChild as HTMLButtonElement).click();
    await waitFor(() => {
      expect(onError).toHaveBeenCalledWith(
        expect.objectContaining({
          message: "此桌面环境不支持会话登录。",
        })
      );
    });

    teardown();
  });
});

class FakeSessionBridge {
  readonly cancelAuthAttempt = vi.fn<SessionBridge["cancelAuthAttempt"]>(async () => ({
    ok: true as const,
    value: signedOutSnapshot(),
  }));
  readonly requestEmailLogin = vi.fn<SessionBridge["requestEmailLogin"]>(
    async (input) => ({
      ok: true as const,
      value: {
        attempt: {
          attemptId: "attempt-1",
          expected: input.expected,
        },
        challengeId: "challenge-1",
      },
    })
  );
  readonly verifyEmailLogin = vi.fn<SessionBridge["verifyEmailLogin"]>(
    async (_input) => {
      const snapshot = signedInSnapshot();
      this.emit(snapshot);
      return { ok: true as const, value: snapshot };
    }
  );
  readonly signOut = vi.fn(
    async (_input: { expected: ReturnType<typeof sessionExpectation> }) => {
      const snapshot: SessionLifecycleSnapshot = {
        ...signedOutSnapshot(),
        generation: 2,
        revision: 3,
      };
      this.emit(snapshot);
      return { ok: true as const, value: snapshot };
    }
  );
  readonly reconcile = vi.fn(
    async (_input: {
      expected?: ReturnType<typeof sessionExpectation>;
      reason: "focus" | "manual_retry" | "peer_mutation" | "startup";
    }) => {
      if (this.current.phase === "signed_in") {
        const snapshot = {
          ...this.current,
          revision: this.current.revision + 1,
        } satisfies SessionLifecycleSnapshot;
        this.emit(snapshot);
        return { ok: true as const, value: snapshot };
      }
      return { ok: true as const, value: this.current };
    }
  );
  current: SessionLifecycleSnapshot;
  private readonly stateListeners = new Set<
    (snapshot: SessionLifecycleSnapshot) => void
  >();

  readonly value: SessionBridge;

  constructor(initial: SessionLifecycleSnapshot) {
    this.current = initial;
    const state = Object.assign(async () => this.current, {
      get: async () => this.current,
      subscribe: (listener: (snapshot: SessionLifecycleSnapshot) => void) => {
        this.stateListeners.add(listener);
        listener(this.current);
        return () => {
          this.stateListeners.delete(listener);
        };
      },
    }) as SessionBridge["state"];

    this.value = {
      cancelAuthAttempt: this.cancelAuthAttempt,
      reconcile: this.reconcile,
      requestEmailLogin: this.requestEmailLogin,
      signInWithGoogle: vi.fn(async () => ({
        ok: false,
        error: {
          code: "unsupported",
          operation: "sign_in_with_google",
          recovery: "none",
          recoveryRef: {
            authorityInstanceId: this.current.authority.authorityInstanceId,
            generation: this.current.generation,
            revision: this.current.revision,
          },
          retryable: false,
        },
      })),
      signOut: this.signOut,
      state,
      verifyEmailLogin: this.verifyEmailLogin,
      verifyGoogleLink: vi.fn(async () => ({
        ok: true,
        value: signedInSnapshot(),
      })),
    } as SessionBridge;
  }

  emit(snapshot: SessionLifecycleSnapshot) {
    this.current = snapshot;
    for (const listener of this.stateListeners) {
      listener(snapshot);
    }
  }
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
    status,
  });
}

function signedOutSnapshot(): SignedOutSessionSnapshot {
  return {
    authority: {
      authorityInstanceId: "main-authority",
      kind: "electron_main",
    },
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
    authority: {
      authorityInstanceId: "main-authority",
      kind: "electron_main",
    },
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
    authority: {
      authorityInstanceId: "main-authority",
      kind: "electron_main",
    },
    cleanup: { revocation: "idle" },
    contractVersion: 1,
    generation: 1,
    phase: "signed_in",
    principal: {
      email: "person@example.com",
      userId: "user-1",
    },
    revision: 2,
    session: {
      audience: "https://api.example",
      expiresAtEpochSeconds: 2_000_000_000,
      sessionId: "11111111-1111-4111-8111-111111111111",
    },
  };
}
