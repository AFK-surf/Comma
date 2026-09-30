import posthog, { type PostHog, type CaptureResult } from "posthog-js";
import { getActiveCommaConfig } from "@comma/config";
import type { SessionLifecycleSnapshot } from "@comma/session-contract";
import type { SessionLifecycleProjectionSource } from "../session/react";

declare const COMMA_DEFINED_APP_VERSION: string | undefined;
declare const COMMA_DEFINED_BUILD_SHA: string | undefined;

declare const COMMA_DEFINED_POSTHOG_KEY: string | undefined;
declare const COMMA_DEFINED_POSTHOG_HOST: string | undefined;

type Runtime = "web" | "electron";
export type ChatSurface = "home" | "route" | "rail" | "side-chat";
type Analytics = {
  client: PostHog;
  userId: string | undefined;
  capturePage: () => void;
  captureReady: () => void;
  sessionResolved: boolean;
  prepareError: () => void;
};
let active: Analytics | undefined;

const eventNames = new Set([
  "$exception",
  "comma_client_ready",
  "comma_conversation_ready",
  "comma_reply_first_visible",
  "comma_reply_wait_timed_out",
  "comma_connection_state_changed",
  "comma_participant_failed",
  "$identify",
  "$pageview",
  "comma_client_opened",
  "comma_session_state_changed",
  "comma_message_send_requested",
  "comma_message_send_accepted",
  "comma_message_send_failed",
]);

// PostHog enriches even manually captured events. Keep that enrichment bounded:
// URLs, referrers, DOM text, person properties and campaign parameters are private.
const propertyNames = new Set([
  "token",
  "distinct_id",
  "$anon_distinct_id",
  "$device_id",
  "$session_id",
  "$window_id",
  "$is_identified_id",
  "$process_person_profile",
  "$lib",
  "$lib_version",
  "$browser",
  "$browser_version",
  "$os",
  "$os_version",
  "$device_type",
  "$screen_height",
  "$screen_width",
  "$viewport_height",
  "$viewport_width",
  "$insert_id",
  "$time",
  "$geoip_disable",
  "runtime",
  "channel",
  "window_role",
  "route",
  "phase",
  "surface",
  "duration_ms",
  "boundary",
  "app_version",
  "build_sha",
  "state",
  "error_kind",
  "severity",
  "login_error_code",
]);

export function sanitizeCommaAnalyticsEvent(event: CaptureResult | null) {
  if (!event || !eventNames.has(event.event)) return null;
  const properties = Object.fromEntries(
    Object.entries(event.properties).filter(([key]) => propertyNames.has(key))
  );
  if (!loginFailureCodes.has(properties.login_error_code))
    delete properties.login_error_code;
  if (event.event === "$pageview") {
    // A stable product route, never a filesystem URL or a URL with OAuth handles.
    properties.$current_url = `comma://client${properties.route}`;
    properties.$pathname = properties.route;
  }
  if (event.event === "$exception") {
    const exceptions = sanitizeExceptionList(event.properties.$exception_list);
    properties.$exception_list = exceptions;
    properties.$exception_level =
      properties.severity === "critical" ? "fatal" : "error";
    // Redaction removes the default message fingerprint. Keep critical UI failures
    // distinct from ordinary errors and group by the last known bundle coordinate.
    const exception = exceptions[0];
    const frame = exception?.stacktrace.frames.findLast(
      (item) => item.filename !== "redacted"
    );
    properties.$exception_fingerprint = JSON.stringify([
      "comma-client.v1",
      properties.error_kind,
      properties.build_sha,
      exception?.type,
      frame?.filename,
      frame?.lineno,
      frame?.colno,
      ...(properties.error_kind === "login_unavailable"
        ? [properties.login_error_code]
        : []),
    ]);
  }
  const sanitized = { ...event, properties };
  delete sanitized.$set;
  delete sanitized.$set_once;
  delete sanitized.$unset;
  return sanitized;
}

export function commaAnalyticsRoute(hash: string): string {
  const path = hash.replace(/^#/, "").split(/[?#]/, 1)[0] || "/";
  if (["/", "/inbox", "/tasks", "/plugins", "/settings"].includes(path)) {
    return path;
  }
  if (/^\/(inbox|tasks)\/[^/]+\/[^/]+\/[^/]+\/?$/.test(path)) {
    return `/${path.split("/")[1]}/:workspaceId/:groupId/:conversationId`;
  }
  return "/other";
}

export function startCommaAnalytics({
  runtime,
  windowRole = "main-window",
  lifecycle,
}: {
  runtime: Runtime;
  windowRole?: "main-window" | "side-chat-window";
  lifecycle: SessionLifecycleProjectionSource;
}): () => void {
  const key =
    typeof COMMA_DEFINED_POSTHOG_KEY === "undefined" ? "" : COMMA_DEFINED_POSTHOG_KEY;
  const host =
    typeof COMMA_DEFINED_POSTHOG_HOST === "undefined" ? "" : COMMA_DEFINED_POSTHOG_HOST;
  if (!key || !host || active) return () => {};

  let client: PostHog | undefined;
  try {
    client = posthog.init(key, {
      api_host: host,
      autocapture: false,
      capture_pageview: false,
      capture_pageleave: false,
      capture_dead_clicks: false,
      capture_exceptions: false,
      capture_heatmaps: false,
      capture_performance: false,
      disable_session_recording: true,
      disable_surveys: true,
      disable_external_dependency_loading: true,
      advanced_disable_flags: true,
      advanced_disable_feature_flags: true,
      remote_config_refresh_interval_ms: 0,
      enable_recording_console_log: false,
      persistence: "localStorage",
      persistence_name: `comma_${getActiveCommaConfig().channel}_${runtime}_${windowRole}`,
      person_profiles: "identified_only",
      respect_dnt: true,
      save_referrer: false,
      save_campaign_params: false,
      before_send: sanitizeCommaAnalyticsEvent,
    });
  } catch {
    // Analytics must never prevent the product from opening.
    return () => {};
  }
  if (!client) return () => {};
  const analytics: Analytics = {
    client,
    userId: undefined,
    capturePage: () => {},
    captureReady: () => {},
    sessionResolved: false,
    prepareError: () => {},
  };
  active = analytics;
  const commonProperties = {
    runtime,
    channel: getActiveCommaConfig().channel,
    window_role: windowRole,
    app_version:
      typeof COMMA_DEFINED_APP_VERSION === "undefined"
        ? "unknown"
        : COMMA_DEFINED_APP_VERSION,
    build_sha:
      typeof COMMA_DEFINED_BUILD_SHA === "undefined"
        ? "unknown"
        : COMMA_DEFINED_BUILD_SHA,
  };
  let earlyErrorIdentityPrepared = false;
  analytics.prepareError = () => {
    if (!analytics.sessionResolved && !earlyErrorIdentityPrepared) {
      client.reset(true);
      client.register(commonProperties);
      earlyErrorIdentityPrepared = true;
    }
  };
  let previousPhase: SessionLifecycleSnapshot["phase"] | undefined;
  let previousNavigation: string | undefined;
  let sessionResolved = false;
  let readyCaptured = false;
  analytics.captureReady = () => {
    if (!sessionResolved || !uiCommitted || readyCaptured) return;
    readyCaptured = true;
    safely(() =>
      client.capture("comma_client_ready", {
        duration_ms: Math.round(performance.now()),
      })
    );
  };
  safely(() => client.register(commonProperties));

  const capturePage = () => {
    if (!sessionResolved) return;
    const route =
      windowRole === "side-chat-window"
        ? "/side-chat"
        : commaAnalyticsRoute(location.hash);
    const navigation =
      windowRole === "side-chat-window" ? "/side-chat" : location.hash.split("?", 1)[0];
    if (navigation === previousNavigation) return;
    previousNavigation = navigation;
    safely(() => client.capture("$pageview", { route }));
  };
  const updateSession = (snapshot: SessionLifecycleSnapshot) => {
    // Renderer subscription replay is asynchronous. Its sentinel is not a
    // Main-process authority result, including when its phase is indeterminate.
    if (snapshot.authority.authorityInstanceId === "electron-renderer-uninitialized")
      return;
    // Wait for the session authority before attributing startup events to an
    // identity left in SDK storage by a previous visit.
    if (!sessionResolved && ["initializing", "authenticating"].includes(snapshot.phase))
      return;
    const firstSnapshot = !sessionResolved;
    sessionResolved = true;
    analytics.sessionResolved = true;
    const userId =
      snapshot.phase === "signed_in" ? snapshot.principal.userId : undefined;
    if (firstSnapshot)
      safely(() => {
        if (!userId || client.get_distinct_id() !== userId) client.reset(true);
      });
    const identityChanged = analytics.userId !== userId;
    if (identityChanged) {
      if (analytics.userId) safely(() => client.reset(true));
      analytics.userId = userId;
    }
    // reset clears common event properties along with the previous identity.
    safely(() => client.register(commonProperties));
    if (identityChanged && userId) safely(() => client.identify(userId));
    if (snapshot.phase !== previousPhase) {
      previousPhase = snapshot.phase;
      safely(() =>
        client.capture("comma_session_state_changed", {
          phase: snapshot.phase,
          duration_ms: firstSnapshot ? Math.round(performance.now()) : undefined,
        })
      );
    }
    if (firstSnapshot) {
      safely(() => client.capture("comma_client_opened"));
      capturePage();
      analytics.captureReady();
    }
  };
  const unsubscribe = lifecycle.subscribe(updateSession);
  analytics.capturePage = capturePage;
  updateSession(lifecycle.getSnapshotSync());
  window.addEventListener("hashchange", capturePage);
  const onError = (event: ErrorEvent) =>
    reportCommaClientError(event.error, "unhandled_error");
  const onRejection = (event: PromiseRejectionEvent) =>
    reportCommaClientError(event.reason, "unhandled_rejection");
  window.addEventListener("error", onError);
  window.addEventListener("unhandledrejection", onRejection);

  return () => {
    unsubscribe();
    window.removeEventListener("hashchange", capturePage);
    window.removeEventListener("error", onError);
    window.removeEventListener("unhandledrejection", onRejection);
    reportedErrors = new WeakMap<Error, ClientErrorKind>();
    errorReportCounts = {};
    uiCommitted = false;
    if (active === analytics) active = undefined;
  };
}

export function captureCommaPageView() {
  active?.capturePage();
}

export function beginCommaMessageSend(surface: ChatSurface) {
  const analytics = active;
  const userId = analytics?.userId;
  const start = performance.now();
  if (analytics)
    safely(() => analytics.client.capture("comma_message_send_requested", { surface }));
  return (
    result: "accepted" | "failed",
    boundary: "runtime" | "server" | "dispatch"
  ) => {
    // A late result from a previous account must not become the next user's event.
    if (!analytics || active !== analytics || analytics.userId !== userId) return;
    safely(() =>
      analytics.client.capture(`comma_message_send_${result}`, {
        surface,
        boundary,
        duration_ms: Math.round(performance.now() - start),
      })
    );
  };
}

function safely(action: () => unknown) {
  try {
    action();
  } catch {
    // Analytics is best effort and must not change auth, navigation or send results.
  }
}

let uiCommitted = false;
let reportedErrors = new WeakMap<Error, ClientErrorKind>();
let errorReportCounts: Partial<Record<ClientErrorKind, number>> = {};

export function markCommaClientReady() {
  uiCommitted = true;
  active?.captureReady();
}

export function captureCommaExperience(
  event:
    | "comma_conversation_ready"
    | "comma_reply_first_visible"
    | "comma_reply_wait_timed_out"
    | "comma_connection_state_changed"
    | "comma_participant_failed",
  properties: {
    surface: ChatSurface;
    duration_ms?: number | undefined;
    state?: string;
    error_kind?: string;
  }
) {
  if (active?.sessionResolved) safely(() => active?.client.capture(event, properties));
}

export function commaAnalyticsIdentity() {
  return active?.userId;
}

type ClientErrorKind =
  | "react_uncaught"
  | "unhandled_error"
  | "unhandled_rejection"
  | "login_unavailable";

const loginFailureCodes = new Set([
  "network_unavailable",
  "provider_unavailable",
  "protocol_mismatch",
  "credential_store_unavailable",
  "credential_mutation_uncertain",
]);

/** Report infrastructure failures from the user's login attempt. */
export function reportCommaGoogleLoginFailure(code: string) {
  const analytics = active;
  if (
    !analytics ||
    !loginFailureCodes.has(code) ||
    (errorReportCounts.login_unavailable ?? 0) >= 20
  )
    return;
  safely(() => {
    errorReportCounts.login_unavailable =
      (errorReportCounts.login_unavailable ?? 0) + 1;
    analytics.prepareError();
    analytics.client.captureException(new Error("Google sign-in unavailable"), {
      error_kind: "login_unavailable",
      login_error_code: code,
      severity: "critical",
    });
  });
}
const errorTypes = new Set([
  "Error",
  "TypeError",
  "RangeError",
  "ReferenceError",
  "SyntaxError",
  "URIError",
  "EvalError",
]);

type SanitizedException = {
  type: string;
  value: string;
  mechanism: { type: string; handled: boolean };
  stacktrace: {
    type: "raw";
    frames: {
      platform: "web:javascript";
      function: "redacted";
      filename: string;
      lineno: number | undefined;
      colno: number | undefined;
    }[];
  };
};

function sanitizeExceptionList(value: unknown): SanitizedException[] {
  if (!Array.isArray(value)) return [];
  return value.slice(0, 3).map((exception) => ({
    type: errorTypes.has(exception?.type) ? exception.type : "Error",
    value: "Comma client exception (message redacted)",
    mechanism: { type: "generic", handled: false },
    stacktrace: {
      type: "raw",
      frames: (Array.isArray(exception?.stacktrace?.frames)
        ? exception.stacktrace.frames
        : []
      )
        .slice(-30)
        .map((frame: Record<string, unknown>) => {
          // Preserve generated bundle coordinates, never filesystem paths, URL queries or function text.
          const basename =
            typeof frame?.filename === "string"
              ? frame.filename.split(/[?#]/, 1)[0]?.split("/").at(-1)
              : undefined;
          const filename =
            basename && /^(?:index|main|renderer)[A-Za-z0-9_-]*\.js$/.test(basename)
              ? `comma://assets/${basename}`
              : "redacted";
          return {
            // PostHog requires these fields even when frame contents are redacted.
            platform: "web:javascript",
            function: "redacted",
            filename,
            lineno: boundedCoordinate(frame?.lineno),
            colno: boundedCoordinate(frame?.colno),
          };
        }),
    },
  }));
}

function boundedCoordinate(value: unknown) {
  return typeof value === "number" &&
    Number.isInteger(value) &&
    value >= 0 &&
    value <= 10_000_000
    ? value
    : undefined;
}

export function reportCommaClientError(error: unknown, kind: ClientErrorKind) {
  const analytics = active;
  if (!analytics || (errorReportCounts[kind] ?? 0) >= 20) return;
  safely(() => {
    if (error instanceof DOMException && error.name === "AbortError") return;
    const exception = error instanceof Error ? error : new Error("Non-Error rejection");
    const previousKind = reportedErrors.get(exception);
    if (previousKind && (kind !== "react_uncaught" || previousKind === kind)) return;
    reportedErrors.set(exception, kind);
    errorReportCounts[kind] = (errorReportCounts[kind] ?? 0) + 1;
    analytics.prepareError();
    analytics.client.captureException(exception, {
      error_kind: kind,
      severity: kind === "react_uncaught" ? "critical" : "error",
    });
  });
}
