import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { CaptureResult } from "posthog-js";
import {
  createSessionProblem,
  type SessionLifecycleSnapshot,
} from "@comma/session-contract";
import type { SessionBridge } from "@comma/native-bridge";
import { createElectronSessionHostController } from "../../session/electron/electron-session-host-controller";
import {
  beginCommaMessageSend,
  captureCommaPageView,
  commaAnalyticsRoute,
  sanitizeCommaAnalyticsEvent,
  startCommaAnalytics,
  markCommaClientReady,
  reportCommaClientError,
  reportCommaGoogleLoginFailure,
} from "../client";

const sdk = vi.hoisted(() => ({
  init: vi.fn(),
  capture: vi.fn(),
  captureException: vi.fn(),
  identify: vi.fn(),
  register: vi.fn(),
  reset: vi.fn(),
  get_distinct_id: vi.fn(() => "anonymous"),
}));
vi.mock("posthog-js", () => ({
  default: { init: sdk.init },
}));

function session(userId?: string): SessionLifecycleSnapshot {
  const common = {
    authority: { authorityInstanceId: "test", kind: "electron_main" as const },
    contractVersion: 1 as const,
    generation: 1,
    revision: 1,
    cleanup: { revocation: "idle" as const },
  };
  return userId
    ? {
        ...common,
        phase: "signed_in",
        principal: { userId, email: "private@example.com" },
        session: {
          audience: "https://comma.test",
          expiresAtEpochSeconds: 1_900_000_000,
          sessionId: "secret-session-id",
        },
      }
    : {
        ...common,
        phase: "signed_out",
        reason: "no_session",
        principal: null,
        session: null,
      };
}

function preventDefault(event: ErrorEvent) {
  event.preventDefault();
}

let dispose = () => {};
beforeEach(() => {
  vi.clearAllMocks();
  sdk.init.mockImplementation(() => sdk);
  vi.stubGlobal("COMMA_DEFINED_POSTHOG_KEY", "phc_test");
  vi.stubGlobal("COMMA_DEFINED_POSTHOG_HOST", "https://posthog.comma.test");
  vi.stubGlobal("COMMA_DEFINED_APP_VERSION", "1.2.3");
  vi.stubGlobal("COMMA_DEFINED_BUILD_SHA", "a".repeat(40));
  window.history.replaceState(null, "", "/#/");
});
afterEach(() => {
  dispose();
  vi.unstubAllGlobals();
});

function start(userId?: string, initialSnapshot = session(userId)) {
  let listener: ((snapshot: SessionLifecycleSnapshot) => void) | undefined;
  const unsubscribe = vi.fn();
  dispose = startCommaAnalytics({
    runtime: "web",
    lifecycle: {
      getSnapshotSync: () => initialSnapshot,
      subscribe: (next) => {
        listener = next;
        return unsubscribe;
      },
    },
  });
  return { publish: (id?: string) => listener?.(session(id)), unsubscribe };
}

describe("Comma client analytics", () => {
  it("reports terminal login infrastructure failures without credentials and ignores cancellation", () => {
    start();
    for (const code of [
      "cancelled",
      "conflict",
      "invalid_challenge",
      "rate_limited",
      "secret-token",
    ])
      reportCommaGoogleLoginFailure(code);
    expect(sdk.captureException).not.toHaveBeenCalled();
    reportCommaGoogleLoginFailure("provider_unavailable");
    expect(sdk.captureException).toHaveBeenCalledWith(expect.any(Error), {
      error_kind: "login_unavailable",
      login_error_code: "provider_unavailable",
      severity: "critical",
    });
    sdk.captureException.mockImplementationOnce(() => {
      throw new Error("analytics offline");
    });
    expect(() => reportCommaGoogleLoginFailure("network_unavailable")).not.toThrow();
  });
  it.each(["COMMA_DEFINED_POSTHOG_KEY", "COMMA_DEFINED_POSTHOG_HOST"])(
    "makes no SDK calls without %s",
    (setting) => {
      vi.stubGlobal(setting, "");
      start();
      expect(sdk.init).not.toHaveBeenCalled();
      beginCommaMessageSend("home")("failed", "server");
      expect(sdk.capture).not.toHaveBeenCalled();
    }
  );

  it.each(["signed_in", "signed_out", "indeterminate"] as const)(
    "waits for actual Electron authority before reporting a %s startup",
    (phase) => {
      let publish: ((snapshot: SessionLifecycleSnapshot) => void) | undefined;
      const actual: SessionLifecycleSnapshot =
        phase === "indeterminate"
          ? {
              ...session("user-a"),
              phase,
              principal: null,
              session: null,
              problem: createSessionProblem("session_probe_unavailable", "initialize"),
            }
          : session(phase === "signed_in" ? "user-a" : undefined);
      const bridge = {
        state: Object.assign(async () => actual, {
          get: async () => actual,
          subscribe: (listener: (snapshot: SessionLifecycleSnapshot) => void) => {
            publish = listener;
            return () => {
              publish = undefined;
            };
          },
        }),
      } as SessionBridge;
      const controller = createElectronSessionHostController({ bridge });
      const stop = startCommaAnalytics({
        runtime: "electron",
        lifecycle: controller.lifecycle,
      });
      dispose = () => {
        stop();
        controller.dispose?.();
      };
      markCommaClientReady();
      expect(controller.lifecycle.getSnapshotSync().authority.authorityInstanceId).toBe(
        "electron-renderer-uninitialized"
      );
      expect(sdk.reset).not.toHaveBeenCalled();
      expect(sdk.capture).not.toHaveBeenCalled();
      publish?.(actual);
      expect(sdk.capture).toHaveBeenCalledWith("comma_session_state_changed", {
        phase,
        duration_ms: expect.any(Number),
      });
      expect(
        sdk.capture.mock.calls.filter(([event]) => event === "comma_client_opened")
      ).toHaveLength(1);
      expect(
        sdk.capture.mock.calls.filter(([event]) => event === "comma_client_ready")
      ).toHaveLength(1);
      expect(
        sdk.capture.mock.calls.filter(([event]) => event === "$pageview")
      ).toHaveLength(1);
      publish?.(actual);
      expect(
        sdk.capture.mock.calls.filter(([event]) => event === "comma_client_opened")
      ).toHaveLength(1);
    }
  );

  it("waits for session resolution before using persisted identity and restores common properties after reset", () => {
    const host = start(undefined, {
      ...session(),
      phase: "initializing",
      principal: null,
      session: null,
    });
    expect(sdk.capture).not.toHaveBeenCalled();
    host.publish();
    expect(sdk.reset).toHaveBeenCalledWith(true);
    expect(sdk.register).toHaveBeenLastCalledWith({
      runtime: "web",
      channel: "dev",
      window_role: "main-window",
      app_version: "1.2.3",
      build_sha: "a".repeat(40),
    });
    expect(sdk.capture).toHaveBeenCalledWith("comma_client_opened");
  });

  it("identifies only the stable user id, resets on logout and drops an old account's pending result", () => {
    const host = start("user-a");
    host.publish("user-a");
    expect(sdk.identify.mock.calls).toEqual([["user-a"]]);
    const finish = beginCommaMessageSend("home");
    host.publish();
    host.publish("user-b");
    finish("accepted", "runtime");
    expect(sdk.reset).toHaveBeenCalledWith(true);
    expect(sdk.identify.mock.calls).toEqual([["user-a"], ["user-b"]]);
    expect(
      sdk.capture.mock.calls.some(([name]) => name === "comma_message_send_accepted")
    ).toBe(false);
    expect(JSON.stringify(sdk.capture.mock.calls)).not.toContain("private@example.com");
    expect(JSON.stringify(sdk.capture.mock.calls)).not.toContain("secret-session-id");
  });

  it("deduplicates navigation notifications and strips route identifiers and search values", () => {
    start("user-a");
    window.history.replaceState(
      null,
      "",
      "/?oauth_handle=private#/inbox/ws_secret/grp_secret/cnv_secret?text=private"
    );
    captureCommaPageView();
    window.dispatchEvent(new HashChangeEvent("hashchange"));
    expect(sdk.capture.mock.calls.filter(([event]) => event === "$pageview")).toEqual([
      ["$pageview", { route: "/" }],
      ["$pageview", { route: "/inbox/:workspaceId/:groupId/:conversationId" }],
    ]);
    expect(commaAnalyticsRoute("#/unknown/private?token=private")).toBe("/other");
  });

  it("keeps SDK failure out of the product flow", () => {
    sdk.init.mockImplementationOnce(() => {
      throw new Error("offline");
    });
    expect(() => start()).not.toThrow();
    start("user-a");
    sdk.capture.mockImplementationOnce(() => {
      throw new Error("offline");
    });
    expect(() => beginCommaMessageSend("home")("failed", "server")).not.toThrow();
  });

  it("removes SDK enrichment and rejects unsolicited event families", () => {
    const event: CaptureResult = {
      uuid: "event-1",
      event: "$pageview",
      properties: {
        distinct_id: "user-a",
        route: "/settings",
        token: "phc_test",
        $current_url: "file:///Users/private/app?oauth_handle=secret",
        $referrer: "https://private.test",
        $set_once: { email: "private@example.com" },
        text: "private message",
        email: "private@example.com",
        $elements: [{ text: "private" }],
      },
      $set: { email: "private@example.com" },
      $set_once: { $initial_referrer: "https://private.test" },
    };
    const result = sanitizeCommaAnalyticsEvent(event);
    expect(result?.properties).toEqual({
      distinct_id: "user-a",
      route: "/settings",
      token: "phc_test",
      $current_url: "comma://client/settings",
      $pathname: "/settings",
    });
    expect(JSON.stringify(result)).not.toContain("private");
    expect(sanitizeCommaAnalyticsEvent({ ...event, event: "$autocapture" })).toBeNull();
    expect(sanitizeCommaAnalyticsEvent({ ...event, event: "$snapshot" })).toBeNull();
  });

  it("reports readiness once, only after both UI commit and session resolution", () => {
    const host = start(undefined, {
      ...session(),
      phase: "initializing",
      principal: null,
      session: null,
    });
    markCommaClientReady();
    expect(sdk.capture).not.toHaveBeenCalled();
    host.publish("user-a");
    markCommaClientReady();
    host.publish("user-a");
    expect(
      sdk.capture.mock.calls.filter(([event]) => event === "comma_client_ready")
    ).toEqual([["comma_client_ready", { duration_ms: expect.any(Number) }]]);
  });

  it("anonymizes early errors, deduplicates objects, ignores cancellation and bounds reports", () => {
    start(undefined, {
      ...session(),
      phase: "initializing",
      principal: null,
      session: null,
    });
    const failure = new TypeError("private message");
    reportCommaClientError(failure, "react_uncaught");
    reportCommaClientError(failure, "react_uncaught");
    reportCommaClientError(
      new DOMException("cancelled", "AbortError"),
      "unhandled_rejection"
    );
    expect(sdk.reset).toHaveBeenCalledExactlyOnceWith(true);
    expect(sdk.captureException).toHaveBeenCalledExactlyOnceWith(failure, {
      error_kind: "react_uncaught",
      severity: "critical",
    });
    for (let i = 0; i < 30; i++)
      reportCommaClientError(new Error("private"), "unhandled_error");
    expect(sdk.captureException).toHaveBeenCalledTimes(21);
    const upgraded = new Error("private upgraded");
    reportCommaClientError(upgraded, "unhandled_rejection");
    reportCommaClientError(upgraded, "react_uncaught");
    expect(sdk.captureException).toHaveBeenLastCalledWith(upgraded, {
      error_kind: "react_uncaught",
      severity: "critical",
    });
  });

  it("captures global failures and removes listeners on disposal", () => {
    start("user-a");
    window.dispatchEvent(new ErrorEvent("error", { error: new Error("private") }));
    expect(sdk.captureException).toHaveBeenCalledWith(expect.any(Error), {
      error_kind: "unhandled_error",
      severity: "error",
    });
    window.addEventListener("error", preventDefault);
    dispose();
    window.dispatchEvent(
      new ErrorEvent("error", { cancelable: true, error: new Error("after dispose") })
    );
    window.removeEventListener("error", preventDefault);
    expect(sdk.captureException).toHaveBeenCalledTimes(1);
  });

  it("redacts exception messages, local paths, functions and malformed frames while keeping bundle coordinates", () => {
    const result = sanitizeCommaAnalyticsEvent({
      uuid: "error-1",
      event: "$exception",
      properties: {
        error_kind: "react_uncaught",
        severity: "critical",
        $exception_message: "private message",
        $exception_personURL: "private",
        $exception_list: [
          {
            type: "TypeError",
            value: "private message",
            stacktrace: {
              frames: [
                null,
                {
                  filename: "file:///Users/private/index-abc123.js?token=private",
                  function: "private",
                  lineno: 42,
                  colno: 7,
                },
                { filename: "https://private/secret.ts", lineno: -1 },
              ],
            },
          },
        ],
      },
    });
    expect(JSON.stringify(result)).not.toContain("private");
    expect(JSON.stringify(result)).not.toContain("secret");
    expect(result?.properties.$exception_list[0].stacktrace.type).toBe("raw");
    expect(result?.properties.$exception_list[0].stacktrace.frames[1]).toEqual({
      platform: "web:javascript",
      function: "redacted",
      filename: "comma://assets/index-abc123.js",
      lineno: 42,
      colno: 7,
    });
  });
});
