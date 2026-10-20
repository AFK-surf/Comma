import userEvent from "@testing-library/user-event";
import type {
  SessionLifecycleExpectation,
  SessionLifecycleSnapshot,
  SignedInSessionSnapshot,
  SignedOutSessionSnapshot,
} from "@comma/session-contract";
import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import type { ProfileValue } from "@comma/core/contract";
import { advance, flush } from "@comma/test-utils/fake-clock";
import { act, render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CommaAuthGate, useCommaAuth } from "../components/AuthGate";
import type { CommaApiSessionTransport, SessionHostController } from "../index";
import { CommaSessionHostProvider } from "../session/react";

vi.mock("../components/LoginScreen", () => ({
  LoginScreen: ({ guestHandoffNotice }: { guestHandoffNotice?: string }) => (
    <>
      <h1>Mock login</h1>
      {guestHandoffNotice ? <p>{guestHandoffNotice}</p> : null}
    </>
  ),
}));

describe("CommaAuthGate with an injected Session host", () => {
  afterEach(() => {
    initializeCommaI18n(["en"]);
  });

  it.each(["electron_main", "web_cookie"] as const)(
    "shows the core's silent %s recovery, keeps product closed, and asks again when the network returns",
    async (authorityKind) => {
      const snapshot = indeterminateSnapshot();
      const controller = new FakeSessionHostController({
        ...snapshot,
        authority: { ...snapshot.authority, kind: authorityKind },
      });
      controller.sayRecovery("trying");
      const view = render(
        <CommaSessionHostProvider controller={controller}>
          <CommaAuthGate>
            <p>Product</p>
          </CommaAuthGate>
        </CommaSessionHostProvider>
      );
      // The core runs the burst: the window only shows it, and asks nothing itself.
      expect(
        screen.getByRole("status", { name: "Connecting to Comma…" })
      ).toBeVisible();
      expect(screen.queryByRole("button")).toBeNull();
      act(() => window.dispatchEvent(new Event("online")));
      expect(controller.recover).not.toHaveBeenCalled();

      act(() => controller.sayRecovery("exhausted"));
      expect(screen.getByText("Comma is temporarily unavailable")).toBeVisible();
      expect(screen.queryByText("Product")).toBeNull();

      controller.recover.mockImplementation(async () => {
        controller.sayRecovery(null);
        controller.publish(signedInSnapshot());
      });
      act(() => {
        window.dispatchEvent(new Event("online"));
      });
      await flush();
      expect(screen.getByText("Product")).toBeVisible();
      expect(controller.recover).toHaveBeenCalledOnce();
      view.unmount();
    }
  );

  it("asks the core for a new recovery when the person tries again", async () => {
    const controller = new FakeSessionHostController(indeterminateSnapshot());
    controller.sayRecovery("exhausted");
    render(
      <CommaSessionHostProvider controller={controller}>
        <CommaAuthGate>
          <p>Product</p>
        </CommaAuthGate>
      </CommaSessionHostProvider>
    );
    await user().click(screen.getByRole("button", { name: "Try again" }));
    expect(controller.recover).toHaveBeenCalledOnce();
  });

  it("does not silently recover a failed sign-out", async () => {
    const snapshot = indeterminateSnapshot();
    const controller = new FakeSessionHostController({
      ...snapshot,
      problem: { ...snapshot.problem, operation: "sign_out" },
    });
    const view = render(
      <CommaSessionHostProvider controller={controller}>
        <CommaAuthGate>
          <p>Product</p>
        </CommaAuthGate>
      </CommaSessionHostProvider>
    );
    await advance(120_000);
    expect(controller.recover).not.toHaveBeenCalled();
    expect(screen.getByRole("heading", { name: "Comma can’t continue" })).toBeVisible();
    expect(screen.queryByText("Product")).toBeNull();
    view.unmount();
  });

  it("does not automatically reconcile an uncertain credential mutation", async () => {
    const snapshot = indeterminateSnapshot();
    const controller = new FakeSessionHostController({
      ...snapshot,
      authority: { ...snapshot.authority, kind: "electron_main" },
      problem: {
        code: "credential_mutation_uncertain",
        operation: "sign_out",
        recovery: "reconcile",
        retryable: false,
      },
    });
    const view = render(
      <CommaSessionHostProvider controller={controller}>
        <CommaAuthGate>
          <p>Product</p>
        </CommaAuthGate>
      </CommaSessionHostProvider>
    );
    act(() => {
      window.dispatchEvent(new Event("online"));
    });
    await advance(120_000);
    expect(controller.recover).not.toHaveBeenCalled();
    expect(screen.queryByText("Product")).toBeNull();
    expect(screen.getByRole("heading", { name: "Comma can’t continue" })).toBeVisible();
    expect(
      screen.getByText("Your sign-in change may not have been saved. Try again.")
    ).toBeVisible();
    view.unmount();
  });

  it("renders only the host projection and signs out its exact expectation", async () => {
    const controller = new FakeSessionHostController(signedOutSnapshot());

    render(
      <CommaSessionHostProvider controller={controller}>
        <CommaAuthGate>
          <EmailAndSignOut />
        </CommaAuthGate>
      </CommaSessionHostProvider>
    );

    await flush();
    expect(screen.getByRole("heading", { name: "Mock login" })).toBeVisible();

    act(() => {
      controller.publish(signedInSnapshot());
    });
    await flush();
    expect(screen.getByText("person@example.com")).toBeVisible();

    await user().click(screen.getByRole("button", { name: "Sign out" }));
    await flush();
    expect(screen.getByRole("heading", { name: "Mock login" })).toBeVisible();
    expect(controller.signOutInputs).toEqual([
      {
        authorityInstanceId: "tab-authority",
        expectedAudience: "https://api.example",
        expectedSessionId: "11111111-1111-4111-8111-111111111111",
        generation: 1,
      },
    ]);
  });

  it("shows a guest by name only and keeps the handoff notice through sign-in", async () => {
    const controller = new FakeSessionHostController(signedOutSnapshot());

    render(
      <CommaSessionHostProvider controller={controller}>
        <CommaAuthGate>
          <GuestOrRegistered />
        </CommaAuthGate>
      </CommaSessionHostProvider>
    );
    await flush();
    expect(screen.getByRole("heading", { name: "Mock login" })).toBeVisible();

    const guest = signedInSnapshot();
    act(() => {
      controller.publish({
        ...guest,
        principal: {
          email: "g-0123abcd@guest.comma.invalid",
          kind: "guest",
          userId: "guest-user",
        },
      });
    });
    await flush();
    expect(screen.getByText("guest:Guest")).toBeVisible();
    expect(screen.queryByText(/guest\.comma\.invalid/)).toBeNull();

    act(() => {
      controller.publish({
        ...signedOutSnapshot(),
        generation: 2,
        reason: "guest_handoff",
        revision: 3,
      });
    });
    const notice = "Sign in or create an account to keep your guest chat.";
    await flush();
    expect(screen.getByText(notice)).toBeVisible();
    act(() => {
      const { reason: _reason, ...signedOut } = signedOutSnapshot();
      controller.publish({
        ...signedOut,
        generation: 2,
        phase: "authenticating",
        revision: 4,
      });
    });
    await flush();
    expect(screen.getByText(notice)).toBeVisible();

    act(() => {
      controller.publish({ ...signedInSnapshot(), generation: 3, revision: 5 });
    });
    await flush();
    expect(screen.getByText(/^registered:/)).toBeVisible();
  });

  it("passes the host-owned product transport without an invalidate command", async () => {
    const reportSessionRejection = vi.fn();
    const controller = new FakeSessionHostController(
      signedInSnapshot(),
      productTransport(reportSessionRejection)
    );

    render(
      <CommaSessionHostProvider controller={controller}>
        <CommaAuthGate>
          <Product />
        </CommaAuthGate>
      </CommaSessionHostProvider>
    );

    await flush();
    await user().click(screen.getByRole("button", { name: "Load product" }));
    await flush();
    expect(reportSessionRejection).toHaveBeenCalledWith(401);
  });

  it("loads the current profile separately from lifecycle-v1 after sign in", async () => {
    const controller = new FakeSessionHostController(signedInSnapshot());

    // The profile as the core keeps it (core/test/profile.test.ts reads it from GET /v1/comma/me/profile).
    const profile: ProfileValue = {
      status: "ready",
      profile: {
        avatar_id: "avt_profile",
        email: "person@example.com",
        id: "user-1",
        name: "Profile Name",
      },
    };
    const core = createScriptedCore({
      values: (topic) => (topic.topic === "profile" ? profile : undefined),
    });
    render(
      core.wrap(
        <CommaSessionHostProvider controller={controller}>
          <CommaAuthGate>
            <NameAndAvatar />
          </CommaAuthGate>
        </CommaSessionHostProvider>
      )
    );

    await flush();
    expect(screen.getByText("Profile Name:avt_profile")).toBeVisible();
  });

  it("fails visibly when retrying cannot establish Session truth", async () => {
    const controller = new FakeSessionHostController(contractMismatchSnapshot());

    render(
      <CommaSessionHostProvider controller={controller}>
        <CommaAuthGate>
          <p>Product</p>
        </CommaAuthGate>
      </CommaSessionHostProvider>
    );

    await flush();
    expect(screen.getByRole("heading", { name: "Comma can’t continue" })).toBeVisible();
    expect(
      screen.getByText(
        "This version of Comma is out of date. Refresh the page or update Comma, then try again."
      )
    ).toBeVisible();
    await user().click(screen.getByRole("button", { name: "Try again" }));
    expect(controller.recover).toHaveBeenCalledOnce();
    expect(screen.queryByText("Product")).toBeNull();
  });

  it("localizes Session recovery without weakening the retry boundary", async () => {
    const controller = new FakeSessionHostController(contractMismatchSnapshot());

    render(
      <CommaI18nProvider locale="zh-CN">
        <CommaSessionHostProvider controller={controller}>
          <CommaAuthGate>
            <p>Product</p>
          </CommaAuthGate>
        </CommaSessionHostProvider>
      </CommaI18nProvider>
    );

    await flush();
    expect(screen.getByRole("heading", { name: "Comma 无法继续" })).toBeVisible();
    expect(
      screen.getByText("当前 Comma 版本过旧。请刷新页面或更新 Comma 后重试。")
    ).toBeVisible();
    await user().click(screen.getByRole("button", { name: "重试" }));
    expect(controller.recover).toHaveBeenCalledOnce();
    expect(screen.queryByText("Product")).toBeNull();
  });
});

function EmailAndSignOut() {
  const auth = useCommaAuth();
  return (
    <>
      <output>{auth.userEmail}</output>
      <button type="button" onClick={auth.signOut}>
        Sign out
      </button>
    </>
  );
}

function GuestOrRegistered() {
  const auth = useCommaAuth();
  return (
    <output>
      {auth.isGuest ? "guest" : "registered"}:{auth.userDisplayName}
    </output>
  );
}

function NameAndAvatar() {
  const auth = useCommaAuth();
  return (
    <output>
      {auth.userDisplayName}:{auth.avatarRevision}
    </output>
  );
}

function user() {
  return userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
}

class FakeSessionHostController implements SessionHostController {
  readonly apiBaseUrl = "https://api.example";
  readonly authenticator = {
    cancelCurrentAttempt: vi.fn(async () => {}),
    mountGoogleControl: vi.fn(async () => () => {}),
    requestEmailLogin: vi.fn(),
    verifyEmailLogin: vi.fn(async () => {}),
    verifyGoogleLink: vi.fn(async () => {}),
  };
  readonly recover = vi.fn(async () => {});
  /** The core's connection recovery, as the test says it. */
  private recovery: "trying" | "exhausted" | null = null;
  private readonly recoveryListeners = new Set<() => void>();
  readonly connectionRecovery = {
    get: () => this.recovery,
    subscribe: (listener: () => void) => {
      this.recoveryListeners.add(listener);
      return () => void this.recoveryListeners.delete(listener);
    },
  };
  sayRecovery(next: "trying" | "exhausted" | null) {
    this.recovery = next;
    for (const listener of Array.from(this.recoveryListeners)) listener();
  }
  readonly signOutInputs: SessionLifecycleExpectation[] = [];
  private readonly listeners = new Set<(snapshot: SessionLifecycleSnapshot) => void>();
  private snapshot: SessionLifecycleSnapshot;
  private transport: CommaApiSessionTransport | undefined;

  readonly lifecycle = {
    getSnapshot: () => Promise.resolve(this.snapshot),
    getSnapshotSync: () => this.snapshot,
    reconcile: vi.fn(async () => ({
      error: {
        code: "unsupported" as const,
        operation: "reconcile" as const,
        recovery: "none" as const,
        recoveryRef: {
          authorityInstanceId: this.snapshot.authority.authorityInstanceId,
          generation: this.snapshot.generation,
          revision: this.snapshot.revision,
        },
        retryable: false,
      },
      ok: false as const,
    })),
    signOut: async (input: { expected: SessionLifecycleExpectation }) => {
      this.signOutInputs.push(input.expected);
      this.publish({
        ...signedOutSnapshot(),
        generation: this.snapshot.generation + 1,
        revision: this.snapshot.revision + 1,
      });
    },
    subscribe: (listener: (snapshot: SessionLifecycleSnapshot) => void) => {
      this.listeners.add(listener);
      listener(this.snapshot);
      return () => {
        this.listeners.delete(listener);
      };
    },
  };

  constructor(
    snapshot: SessionLifecycleSnapshot,
    transport = snapshot.phase === "signed_in" ? productTransport() : undefined
  ) {
    this.snapshot = snapshot;
    this.transport = transport;
  }

  getProductTransport() {
    return this.snapshot.phase === "signed_in" ? this.transport : undefined;
  }

  initialize() {
    return Promise.resolve();
  }

  publish(snapshot: SessionLifecycleSnapshot) {
    this.snapshot = snapshot;
    if (snapshot.phase === "signed_in" && !this.transport) {
      this.transport = productTransport();
    }
    for (const listener of this.listeners) {
      listener(snapshot);
    }
  }
}

function signedOutSnapshot(): SignedOutSessionSnapshot {
  return {
    authority: {
      authorityInstanceId: "tab-authority",
      kind: "web_cookie",
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

function signedInSnapshot(): SignedInSessionSnapshot {
  return {
    authority: {
      authorityInstanceId: "tab-authority",
      kind: "web_cookie",
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

function indeterminateSnapshot(): Extract<
  SessionLifecycleSnapshot,
  { phase: "indeterminate" }
> {
  return {
    authority: {
      authorityInstanceId: "tab-authority",
      kind: "web_cookie",
    },
    cleanup: { revocation: "idle" },
    contractVersion: 1,
    generation: 1,
    phase: "indeterminate",
    principal: null,
    problem: {
      code: "session_probe_unavailable",
      operation: "reconcile",
      recovery: "retry_operation",
      retryable: true,
    },
    revision: 3,
    session: null,
  };
}

function contractMismatchSnapshot(): Extract<
  SessionLifecycleSnapshot,
  { phase: "indeterminate" }
> {
  return {
    ...indeterminateSnapshot(),
    problem: {
      code: "protocol_mismatch",
      operation: "reconcile",
      recovery: "after_host_change",
      retryable: false,
    },
  };
}

/** Reports a 401 through the product transport the gate gives. */
function Product() {
  const auth = useCommaAuth();
  return (
    <button
      type="button"
      onClick={() => auth.sessionTransport.reportSessionRejection(401)}
    >
      Load product
    </button>
  );
}

function productTransport(
  reportSessionRejection: (status: 401 | 409) => void = () => {}
): CommaApiSessionTransport {
  return {
    credentials: "include",
    signal: new AbortController().signal,
    applyHeaders() {},
    reportSessionRejection,
  };
}
