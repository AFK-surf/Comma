import { firstTouch, sanitizeAttribution, webPersistence } from "@comma/analytics";
import posthog, { type PostHog, type CaptureResult } from "posthog-js";
import { uiClock } from "@comma/ui/clock";
import { getActiveCommaConfig } from "@comma/config";
import type { SessionLifecycleSnapshot } from "@comma/session-contract";
import type { NativeInfo } from "@comma/native-bridge";
import type { CoreFailure } from "@comma/core-client";
import type { SessionLifecycleProjectionSource } from "../session/react";

declare const COMMA_DEFINED_APP_VERSION: string | undefined;
declare const COMMA_DEFINED_BUILD_SHA: string | undefined;

declare const COMMA_DEFINED_POSTHOG_KEY: string | undefined;
declare const COMMA_DEFINED_POSTHOG_HOST: string | undefined;

type Runtime = "web" | "electron";
export type ChatSurface = "home" | "route" | "rail";
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
  "comma_desktop_launched",
  "comma_session_state_changed",
  "comma_message_send_requested",
  "comma_message_send_accepted",
  "comma_message_send_failed",
]);

// PostHog enriches even manually captured events. Keep that enrichment bounded:
// Keep only public campaign slugs; raw URLs, DOM text and account details are private.
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
  "error_detail",
  "severity",
  "login_error_code",
  "source_message_id",
  "launch_kind",
]);

export function sanitizeCommaAnalyticsEvent(event: CaptureResult | null) {
  if (!event || !eventNames.has(event.event)) return null;
  const properties = Object.fromEntries(
    Object.entries(event.properties).filter(([key]) => propertyNames.has(key))
  );
  Object.assign(properties, sanitizeAttribution(event.properties));
  if (event.event === "$identify") {
    const first = sanitizeAttribution(event.properties.$set_once);
    if (Object.keys(first).length) properties.$set_once = first;
  }
  if (!loginFailureCodes.has(properties.login_error_code))
    delete properties.login_error_code;
  if (!errorDetails.has(properties.error_detail)) delete properties.error_detail;
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
      // Errors without a stack of their own (non-Error values, a failed core channel) group by what failed.
      ...(properties.error_detail ? [properties.error_detail] : []),
    ]);
  }
  // Only canonical opaque Message IDs may correlate visible replies with server facts.
  if (
    event.event !== "comma_reply_first_visible" ||
    typeof properties.source_message_id !== "string" ||
    !/^msg1_[0-9]{19}$/.test(properties.source_message_id)
  )
    delete properties.source_message_id;
  const sanitized = { ...event, properties };
  delete sanitized.$set;
  const first = event.event === "$identify" ? sanitizeAttribution(event.$set_once) : {};
  if (Object.keys(first).length) sanitized.$set_once = first;
  else delete sanitized.$set_once;
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

// Only the main window reports. The name stays in the SDK storage key and in
// every event, so an existing install keeps its analytics identity.
const windowRole = "main-window";

export function startCommaAnalytics({
  runtime,
  lifecycle,
  desktopLaunch,
}: {
  runtime: Runtime;
  lifecycle: SessionLifecycleProjectionSource;
  desktopLaunch?: Promise<NativeInfo["desktopLaunch"]> | undefined;
}): () => void {
  const key =
    typeof COMMA_DEFINED_POSTHOG_KEY === "undefined" ? "" : COMMA_DEFINED_POSTHOG_KEY;
  const host =
    typeof COMMA_DEFINED_POSTHOG_HOST === "undefined" ? "" : COMMA_DEFINED_POSTHOG_HOST;
  if (!key || !host || active) return () => {};

  const sharedWebIdentity = runtime === "web";
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
      ...(sharedWebIdentity ? webPersistence(getActiveCommaConfig().channel) : {}),
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
  let launch: NativeInfo["desktopLaunch"];
  let launchCaptured = false;
  const captureDesktopLaunch = () => {
    if (!sessionResolved || !launch || launchCaptured || active !== analytics) return;
    launchCaptured = true;
    const snapshot = launch;
    safely(() => {
      const launchKey = `comma_${getActiveCommaConfig().channel}_last_launch`;
      // Main's snapshot survives renderer reloads; SDK identity resets do not
      // clear this marker. If storage fails, omit this observation.
      if (localStorage.getItem(launchKey) === snapshot.eventId) return;
      localStorage.setItem(launchKey, snapshot.eventId);
      client.capture("comma_desktop_launched", {
        launch_kind: snapshot.kind,
      });
    });
  };
  if (runtime === "electron") {
    void desktopLaunch
      ?.then((snapshot) => {
        launch = snapshot;
        captureDesktopLaunch();
      })
      .catch(() => undefined);
  }
  let readyCaptured = false;
  analytics.captureReady = () => {
    if (!sessionResolved || !uiCommitted || readyCaptured) return;
    readyCaptured = true;
    safely(() =>
      client.capture("comma_client_ready", {
        duration_ms: Math.round(uiClock.monotonic()),
      })
    );
  };
  safely(() => client.register(commonProperties));

  const capturePage = () => {
    if (!sessionResolved) return;
    const route = commaAnalyticsRoute(location.hash);
    const navigation = location.hash.split("?", 1)[0];
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
        const previousUser = client.get_property("$user_id");
        if (
          sharedWebIdentity
            ? previousUser && previousUser !== userId
            : !userId || client.get_distinct_id() !== userId
        )
          client.reset(true);
      });
    const identityChanged = analytics.userId !== userId;
    if (identityChanged) {
      if (analytics.userId) safely(() => client.reset(true));
      analytics.userId = userId;
    }
    // reset clears common event properties along with the previous identity.
    safely(() => client.register(commonProperties));
    safely(() => {
      const attribution = sharedWebIdentity ? firstTouch(client, "/app") : undefined;
      if (identityChanged && userId) {
        if (attribution) client.identify(userId, undefined, attribution);
        else client.identify(userId);
      }
    });
    if (snapshot.phase !== previousPhase) {
      previousPhase = snapshot.phase;
      safely(() =>
        client.capture("comma_session_state_changed", {
          phase: snapshot.phase,
          duration_ms: firstSnapshot ? Math.round(uiClock.monotonic()) : undefined,
        })
      );
    }
    if (firstSnapshot) {
      safely(() => client.capture("comma_client_opened"));
      captureDesktopLaunch();
      capturePage();
      analytics.captureReady();
    }
  };
  const unsubscribe = lifecycle.subscribe(updateSession);
  analytics.capturePage = capturePage;
  updateSession(lifecycle.getSnapshotSync());
  window.addEventListener("hashchange", capturePage);
  const onError = (event: ErrorEvent) =>
    reportCommaClientError(event.error, "unhandled_error", errorEventDetail(event));
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
  const start = uiClock.monotonic();
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
        duration_ms: Math.round(uiClock.monotonic() - start),
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
// ResizeObserver loop errors are harmless and can repeat every frame: they get a budget of their own, so a page that
// keeps raising them still leaves room to report the real unhandled errors.
let errorReportCounts: Partial<
  Record<ClientErrorKind | "resize_observer_loop", number>
> = {};

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
    source_message_id?: string | undefined;
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
  | "login_unavailable"
  /** The client core reported an error in its own work, or its channel failed. */
  | "core_fault";

// What is known about an error without its text: the type of a non-Error value that was thrown or rejected, what the
// browser said about an error event that carries no error, or why the core's channel failed (a CoreFailed error).
const nonErrorDetails = [
  "resize_observer_loop",
  "cross_origin_script",
  "non_error_undefined",
  "non_error_null",
  "non_error_string",
  "non_error_number",
  "non_error_boolean",
  "non_error_event",
  "non_error_object",
  "non_error_other",
] as const;
const coreFailures = [
  "worker_load",
  "worker_exception",
  "process_exit",
  "core_fatal",
  "channel_open",
  "channel",
] as const satisfies readonly CoreFailure[];
type ErrorDetail = (typeof nonErrorDetails)[number];
const errorDetails = new Set<unknown>([...nonErrorDetails, ...coreFailures]);

/** Classifies an error event that carries no Error by what the browser says of it; the text itself is never sent. */
function errorEventDetail(event: ErrorEvent): ErrorDetail | undefined {
  if (event.error instanceof Error) return undefined;
  if (event.message.startsWith("ResizeObserver loop ")) return "resize_observer_loop";
  // The browser hides all of an error from a script of another origin loaded without CORS.
  if (/^Script error\.?$/.test(event.message)) return "cross_origin_script";
  return undefined;
}

function nonErrorDetail(value: unknown): ErrorDetail {
  if (value === undefined) return "non_error_undefined";
  if (value === null) return "non_error_null";
  if (typeof value === "string") return "non_error_string";
  if (typeof value === "number") return "non_error_number";
  if (typeof value === "boolean") return "non_error_boolean";
  if (value instanceof Event) return "non_error_event";
  if (typeof value === "object") return "non_error_object";
  return "non_error_other";
}

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
          // Preserve generated bundle coordinates, never filesystem paths, URL queries or function text. Every
          // bundle, its chunks and the core's worker are served from an `assets/` directory, on the web and in Electron.
          const [directory, basename] =
            typeof frame?.filename === "string"
              ? (frame.filename.split(/[?#]/, 1)[0]?.split("/").slice(-2) ?? [])
              : [];
          const filename =
            directory === "assets" && basename && /^[A-Za-z0-9_.-]+\.js$/.test(basename)
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

export function reportCommaClientError(
  error: unknown,
  kind: ClientErrorKind,
  detail?: ErrorDetail
) {
  const analytics = active;
  const budget = detail === "resize_observer_loop" ? detail : kind;
  if (!analytics || (errorReportCounts[budget] ?? 0) >= 20) return;
  safely(() => {
    if (error instanceof DOMException && error.name === "AbortError") return;
    // A stand-in for a non-Error value has no stack: its own would locate this reporter, not the failure.
    const exception =
      error instanceof Error
        ? error
        : Object.assign(new Error("Non-Error value"), { stack: "" });
    const errorDetail =
      detail ??
      (error instanceof Error
        ? error.name === "CoreFailed"
          ? (error as { failure?: unknown }).failure
          : undefined
        : nonErrorDetail(error));
    const previousKind = reportedErrors.get(exception);
    if (previousKind && (kind !== "react_uncaught" || previousKind === kind)) return;
    reportedErrors.set(exception, kind);
    errorReportCounts[budget] = (errorReportCounts[budget] ?? 0) + 1;
    analytics.prepareError();
    analytics.client.captureException(exception, {
      error_kind: kind,
      severity: kind === "react_uncaught" ? "critical" : "error",
      ...(errorDetails.has(errorDetail) ? { error_detail: errorDetail } : {}),
    });
  });
}
