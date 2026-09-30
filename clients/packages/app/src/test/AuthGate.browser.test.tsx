import userEvent from "@testing-library/user-event";
import type {
  SessionLifecycleExpectation,
  SessionLifecycleSnapshot,
  SignedInSessionSnapshot,
  SignedOutSessionSnapshot,
} from "@comma/session-contract";
import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { CommaApiSessionTransport, SessionHostController } from "../index";

vi.mock("../components/LoginScreen", () => ({
  LoginScreen: () => <h1>Mock login</h1>,
}));

describe("CommaAuthGate with an injected Session host", () => {
  beforeEach(() => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        jsonResponse({
          avatar_id: "avt_profile",
          email: "person@example.com",
          id: "user-1",
          name: "Profile Name",
        })
      )
    );
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
    initializeCommaI18n(["en"]);
  });

  it.each(["electron_main", "web_cookie"] as const)(
    "bounds silent %s recovery, keeps product closed, and reconnects when the network returns",
    async (authorityKind) => {
      const snapshot = indeterminateSnapshot();
      const controller = new FakeSessionHostController({
        ...snapshot,
        authority: { ...snapshot.authority, kind: authorityKind },
      });
      const { CommaAuthGate } = await import("../components/AuthGate");
      const { CommaSessionHostProvider } = await import("../session/react");
      vi.useFakeTimers();
      const view = render(
        <CommaSessionHostProvider controller={controller}>
          <CommaAuthGate>
            <p>Product</p>
          </CommaAuthGate>
        </CommaSessionHostProvider>
      );
      expect(
        screen.getByRole("status", { name: "Connecting to Comma…" })
      ).toBeVisible();
      expect(screen.queryByRole("button")).toBeNull();
      await act(async () => {
        await vi.advanceTimersByTimeAsync(44_000);
      });
      expect(controller.recover).toHaveBeenCalledTimes(5);
      expect(screen.getByText("Comma is temporarily unavailable")).toBeVisible();
      expect(screen.queryByText("Product")).toBeNull();
      await act(async () => {
        await vi.advanceTimersByTimeAsync(120_000);
      });
      expect(controller.recover).toHaveBeenCalledTimes(5);

      controller.recover.mockImplementation(async () =>
        controller.publish(signedInSnapshot())
      );
      act(() => {
        window.dispatchEvent(new Event("online"));
      });
      await act(async () => {
        await vi.advanceTimersByTimeAsync(0);
      });
      expect(screen.getByText("Product")).toBeVisible();
      expect(controller.recover).toHaveBeenCalledTimes(6);
      view.unmount();
      await act(async () => {
        await vi.advanceTimersByTimeAsync(120_000);
      });
      expect(controller.recover).toHaveBeenCalledTimes(6);
    }
  );

  it("does not silently recover a failed sign-out", async () => {
    const snapshot = indeterminateSnapshot();
    const controller = new FakeSessionHostController({
      ...snapshot,
      problem: { ...snapshot.problem, operation: "sign_out" },
    });
    const { CommaAuthGate } = await import("../components/AuthGate");
    const { CommaSessionHostProvider } = await import("../session/react");
    vi.useFakeTimers();
    const view = render(
      <CommaSessionHostProvider controller={controller}>
        <CommaAuthGate>
          <p>Product</p>
        </CommaAuthGate>
      </CommaSessionHostProvider>
    );
    await act(async () => {
      await vi.advanceTimersByTimeAsync(120_000);
    });
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
    const { CommaAuthGate } = await import("../components/AuthGate");
    const { CommaSessionHostProvider } = await import("../session/react");
    vi.useFakeTimers();
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
    await act(async () => {
      await vi.advanceTimersByTimeAsync(120_000);
    });
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
    const { CommaAuthGate, useCommaAuth } = await import("../components/AuthGate");
    const { CommaSessionHostProvider } = await import("../session/react");

    function Product() {
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

    render(
      <CommaSessionHostProvider controller={controller}>
        <CommaAuthGate>
          <Product />
        </CommaAuthGate>
      </CommaSessionHostProvider>
    );

    expect(await screen.findByRole("heading", { name: "Mock login" })).toBeVisible();

    act(() => {
      controller.publish(signedInSnapshot());
    });
    expect(await screen.findByText("person@example.com")).toBeVisible();

    await userEvent.click(screen.getByRole("button", { name: "Sign out" }));
    await screen.findByRole("heading", { name: "Mock login" });
    expect(controller.signOutInputs).toEqual([
      {
        authorityInstanceId: "tab-authority",
        expectedAudience: "https://api.example",
        expectedSessionId: "11111111-1111-4111-8111-111111111111",
        generation: 1,
      },
    ]);
  });

  it("passes the host-owned product transport without an invalidate command", async () => {
    const reportSessionRejection = vi.fn();
    const controller = new FakeSessionHostController(
      signedInSnapshot(),
      productTransport(reportSessionRejection)
    );
    const [
      { createCommaApi },
      { CommaAuthGate, useCommaAuth },
      { CommaSessionHostProvider },
    ] = await Promise.all([
      import("../api"),
      import("../components/AuthGate"),
      import("../session/react"),
    ]);

    function Product() {
      const auth = useCommaAuth();
      const api = createCommaApi({
        baseUrl: auth.apiBaseUrl,
        fetch: vi.fn(async () => jsonResponse({ error: "unauthorized" }, 401)),
        sessionTransport: auth.sessionTransport,
        token: "",
      });
      return (
        <button
          type="button"
          onClick={() => void api.listWorkspaces().catch(() => undefined)}
        >
          Load product
        </button>
      );
    }

    render(
      <CommaSessionHostProvider controller={controller}>
        <CommaAuthGate>
          <Product />
        </CommaAuthGate>
      </CommaSessionHostProvider>
    );

    await userEvent.click(await screen.findByRole("button", { name: "Load product" }));
    await waitFor(() => expect(reportSessionRejection).toHaveBeenCalledWith(401));
  });

  it("loads the current profile separately from lifecycle-v1 after sign in", async () => {
    const controller = new FakeSessionHostController(signedInSnapshot());
    const { CommaAuthGate, useCommaAuth } = await import("../components/AuthGate");
    const { CommaSessionHostProvider } = await import("../session/react");

    function Product() {
      const auth = useCommaAuth();
      return (
        <output>
          {auth.userDisplayName}:{auth.avatarRevision}
        </output>
      );
    }

    render(
      <CommaSessionHostProvider controller={controller}>
        <CommaAuthGate>
          <Product />
        </CommaAuthGate>
      </CommaSessionHostProvider>
    );

    expect(await screen.findByText("Profile Name:avt_profile")).toBeVisible();
    expect(fetch).toHaveBeenCalledWith(
      "https://api.example/v1/comma/me/profile",
      expect.objectContaining({ method: "GET" })
    );
  });

  it("fails visibly when retrying cannot establish Session truth", async () => {
    const controller = new FakeSessionHostController(contractMismatchSnapshot());
    const { CommaAuthGate } = await import("../components/AuthGate");
    const { CommaSessionHostProvider } = await import("../session/react");

    render(
      <CommaSessionHostProvider controller={controller}>
        <CommaAuthGate>
          <p>Product</p>
        </CommaAuthGate>
      </CommaSessionHostProvider>
    );

    expect(
      await screen.findByRole("heading", { name: "Comma can’t continue" })
    ).toBeVisible();
    expect(
      screen.getByText(
        "This version of Comma is out of date. Refresh the page or update Comma, then try again."
      )
    ).toBeVisible();
    await userEvent.click(screen.getByRole("button", { name: "Try again" }));
    expect(controller.recover).toHaveBeenCalledOnce();
    expect(screen.queryByText("Product")).toBeNull();
  });

  it("localizes Session recovery without weakening the retry boundary", async () => {
    const controller = new FakeSessionHostController(contractMismatchSnapshot());
    const { CommaAuthGate } = await import("../components/AuthGate");
    const { CommaSessionHostProvider } = await import("../session/react");

    render(
      <CommaI18nProvider locale="zh-CN">
        <CommaSessionHostProvider controller={controller}>
          <CommaAuthGate>
            <p>Product</p>
          </CommaAuthGate>
        </CommaSessionHostProvider>
      </CommaI18nProvider>
    );

    expect(
      await screen.findByRole("heading", { name: "Comma 无法继续" })
    ).toBeVisible();
    expect(
      screen.getByText("当前 Comma 版本过旧。请刷新页面或更新 Comma 后重试。")
    ).toBeVisible();
    await userEvent.click(screen.getByRole("button", { name: "重试" }));
    expect(controller.recover).toHaveBeenCalledOnce();
    expect(screen.queryByText("Product")).toBeNull();
  });
});

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

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
    status,
  });
}
