// A window's view of the session the client core runs (packages/core, session/web-lifecycle.ts on the web,
// session/electron-lifecycle.ts in Electron). The window holds no session state of its own: what it shows is the
// `session` topic (the lifecycle snapshot, the sign-in under way, the guest imports), and what a person does is a
// `session.*` call. What only a window can do stays here: on the web the Google button (its script and popup), in
// Electron the button that opens Main's Google window through the core; and the product requests the window still
// makes itself, which name the session the core gives (the web: its Cookie; Electron: Main's `/v1` proxy, which adds
// the bearer for exactly that lease). No credential ever reaches a window.
import { baseLocale, messages, type CommaLocale } from "@comma/i18n";
import type {
  CallName,
  Calls,
  CoreClient,
  SessionAttempt,
  SessionEmailCooldown,
  SessionValue,
} from "@comma/core-client";
import {
  encodeSessionPresenceExpectation,
  sessionExpectation,
  sessionPresenceExpectationHeader,
  type SessionAbsenceExpectation,
  type SessionAuthAttemptRef,
  type SessionLifecycleSnapshot,
} from "@comma/session-contract";
import type { CommaApiSessionTransport } from "./controller";
import { renderGoogleSignInButton } from "../auth/googleIdentityServices";
import type {
  SessionAuthenticatorController,
  SessionLoginTiming,
  SessionGuestController,
  SessionHostController,
  SessionLifecycleController,
  SessionLoginChallenge,
} from "./controller";
import { sessionOperationDisplayError } from "./operation-error-message";

type Call = <N extends CallName>(
  name: N,
  params: Calls[N]["params"]
) => Promise<Calls[N]["result"]>;

/** Which product lease a signed-in snapshot gives (null: none). */
function leaseKey(snapshot: SessionLifecycleSnapshot): string | null {
  if (snapshot.phase !== "signed_in") return null;
  const { authority, generation, session } = snapshot;
  return `${authority.authorityInstanceId}\n${generation}\n${session.sessionId}\n${session.audience}`;
}

/** Shown until the core's first value: the window knows nothing yet (AuthGate renders nothing). */
function starting(kind: "electron_main" | "web_cookie"): SessionLifecycleSnapshot {
  return {
    authority: { authorityInstanceId: "core", kind },
    cleanup: { revocation: "idle" },
    contractVersion: 1,
    generation: 0,
    phase: "initializing",
    principal: null,
    revision: 0,
    session: null,
  };
}

export function createCoreSessionHostController(input: {
  apiBaseUrl: string;
  core: CoreClient;
  locale?: CommaLocale;
  /**
   * Whose session the core runs: the web's (its Cookie, the Google button, guest sessions) or Electron's (Main keeps
   * the bearer: product requests go through Main's `/v1` proxy, Google signs in through Main's window).
   */
  host?: "electron" | "web";
}): SessionHostController {
  const { core } = input;
  const electron = input.host === "electron";
  const locale = input.locale ?? baseLocale;
  const call: Call = (name, params) => core.call(name, params) as never;
  let snapshot = starting(electron ? "electron_main" : "web_cookie");
  let attempt: SessionAttempt | null = null;
  let timing: SessionLoginTiming = {};
  let recovery: "trying" | "exhausted" | null = null;
  const recoveryListeners = new Set<() => void>();
  let stopRecovery: (() => void) | null = null;
  let guestImports: number | undefined;
  const snapshotListeners = new Set<(snapshot: SessionLifecycleSnapshot) => void>();
  const attemptListeners = new Set<() => void>();
  const importListeners = new Set<() => void>();
  let product: {
    key: string;
    transport: CommaApiSessionTransport;
    stop(): void;
  } | null = null;

  const stopSession = core.subscribe(
    { topic: "session" },
    (raw) => {
      const value = raw as SessionValue;
      const next = value.lifecycle;
      // A core that starts again (the tab that ran it closed) finds the session out anew: the page keeps what it
      // shows until it has.
      if (
        next &&
        next !== snapshot &&
        !(next.phase === "initializing" && snapshot.phase !== "initializing")
      ) {
        snapshot = next;
        // Another lease, or none: what the page started with the last one stops.
        if (product && product.key !== leaseKey(snapshot)) {
          product.stop();
          product = null;
        }
        for (const listener of Array.from(snapshotListeners)) listener(snapshot);
      }
      const nextAttempt = value.attempt ?? null;
      const nextTiming = loginTiming(nextAttempt, value.emailCooldown ?? null);
      if (
        JSON.stringify(nextAttempt) !== JSON.stringify(attempt) ||
        JSON.stringify(nextTiming) !== JSON.stringify(timing)
      ) {
        attempt = nextAttempt;
        timing = nextTiming;
        for (const listener of Array.from(attemptListeners)) listener();
      }
      const imports = value.guestImports ?? 0;
      // Imports done before this page saw the core are not this page's news.
      if (guestImports !== undefined && imports > guestImports)
        for (const listener of Array.from(importListeners)) listener();
      guestImports = imports;
    },
    () => undefined
  );

  const operationError = (code: string, retryAfterMs?: number) =>
    sessionOperationDisplayError(
      code,
      (electron
        ? messages.auth_desktop_unsupported
        : messages.auth_browser_unsupported)({}, { locale }),
      locale,
      retryAfterMs
    );
  const stale = () => new Error(messages.auth_attempt_stale({}, { locale }));

  /** The session must be absent to start a sign-in (one under way is replaced). */
  const absence = (): SessionAbsenceExpectation => {
    if (snapshot.phase !== "signed_out" && snapshot.phase !== "authenticating")
      throw stale();
    return {
      authorityInstanceId: snapshot.authority.authorityInstanceId,
      expectedSessionId: null,
      generation: snapshot.generation,
    };
  };

  // The attempts this page started, by the challenge each waits for: the call's answer can come before the topic.
  const started = new Map<string, SessionAuthAttemptRef>();
  const attemptFor = (
    challengeId: string,
    purpose: SessionLoginChallenge["purpose"]
  ) => {
    const shared =
      attempt?.challenge?.challengeId === challengeId &&
      attempt.challenge.purpose === purpose
        ? attempt.ref
        : undefined;
    const ref = shared ?? started.get(challengeId);
    if (!ref) throw stale();
    return ref;
  };

  const lifecycle: SessionLifecycleController = {
    getSnapshot: () => Promise.resolve(snapshot),
    getSnapshotSync: () => snapshot,
    reconcile: (request) =>
      call("session.reconcile", {
        reason: request.reason === "focus" ? "focus" : "peer_mutation",
        ...(request.expected ? { expected: request.expected } : {}),
      }),
    signOut: (request) => call("session.signOut", { expected: request.expected }),
    subscribe(listener) {
      snapshotListeners.add(listener);
      return () => void snapshotListeners.delete(listener);
    },
  };

  const cancelCurrentAttempt = async () => {
    const current = attempt?.ref;
    if (!current) return;
    const result = await call("session.cancelAuth", { attempt: current });
    if (!result.ok && result.error.code !== "conflict")
      throw operationError(result.error.code);
  };

  /** The desktop Google sign-in under way: a newer sign-in started here makes its late answer go unheard. */
  let pendingGoogle: object | undefined;

  /** Electron: Google in Main's window, through the core (one call: the attempt, the window, the exchange). */
  const signInWithGoogle = async (callbacks: {
    onError(error: Error): void;
    onResult(result: { kind: "signed_in" } | SessionLoginChallenge): void;
  }) => {
    const pending = {};
    pendingGoogle = pending;
    try {
      const result = await call("session.google.desktop", { expected: absence() });
      if (pendingGoogle !== pending) return;
      if (!result.ok) return callbacks.onError(operationError(result.error.code));
      if (result.value.status === "signed_in")
        return callbacks.onResult({ kind: "signed_in" });
      started.set(result.value.challengeId, result.value.attempt);
      callbacks.onResult({
        challengeId: result.value.challengeId,
        email: result.value.email,
        kind: "challenge",
        purpose: "google_link",
      });
    } catch (error) {
      if (pendingGoogle !== pending) return;
      callbacks.onError(error instanceof Error ? error : new Error(String(error)));
    } finally {
      if (pendingGoogle === pending) pendingGoogle = undefined;
    }
  };

  const authenticator: SessionAuthenticatorController = {
    cancelCurrentAttempt,
    async requestEmailLogin(email, options) {
      pendingGoogle = undefined;
      // A Google account waiting to be linked gives way to the address typed now.
      if (attempt?.challenge?.purpose === "google_link") await cancelCurrentAttempt();
      const result = await call("session.email.request", {
        email,
        expected: absence(),
        ...(options?.resend ? { resend: true as const } : {}),
      });
      if (!result.ok)
        throw operationError(result.error.code, result.error.retryAfterMs);
      started.set(result.value.challengeId, result.value.attempt);
      return {
        challengeId: result.value.challengeId,
        ...(result.value.code ? { code: result.value.code } : {}),
        ...(electron ? { email } : {}),
        kind: "challenge",
        purpose: "email_login",
      };
    },
    async verifyEmailLogin({ challengeId, code }) {
      const result = await call("session.email.verify", {
        attempt: attemptFor(challengeId, "email_login"),
        challengeId,
        code,
      });
      if (!result.ok) throw operationError(result.error.code);
    },
    async verifyGoogleLink({ challengeId, code }) {
      const result = await call("session.google.linkVerify", {
        attempt: attemptFor(challengeId, "google_link"),
        challengeId,
        code,
      });
      if (!result.ok) throw operationError(result.error.code);
    },
    ...(electron
      ? {
          requestGoogleLogin: (callbacks: Parameters<typeof signInWithGoogle>[0]) =>
            signInWithGoogle(callbacks),
        }
      : {}),
    async mountGoogleControl({ element, onError, onResult }) {
      if (electron) {
        // Main's window, not a provider-rendered control: a plain button starts it.
        let active = true;
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = messages.auth_continue_google({}, { locale });
        button.className = "app-login-primary";
        const onClick = () => {
          if (active) void signInWithGoogle({ onError, onResult });
        };
        button.addEventListener("click", onClick);
        element.replaceChildren(button);
        return () => {
          active = false;
          button.removeEventListener("click", onClick);
          element.replaceChildren();
        };
      }
      if (attempt?.challenge?.purpose === "google_link") await cancelCurrentAttempt();
      const prepared = await call("session.google.attempt", { expected: absence() });
      if (!prepared.ok) throw operationError(prepared.error.code);
      const { attempt: ref, clientId, nonce, providerAttemptId } = prepared.value;
      let active = true;
      const complete = async (credential: string) => {
        const result = await call("session.google.complete", {
          attempt: ref,
          credential,
          nonce,
          providerAttemptId,
        });
        if (!active) return;
        if (!result.ok) return onError(operationError(result.error.code));
        if (result.value.status === "signed_in") return onResult({ kind: "signed_in" });
        started.set(result.value.challengeId, result.value.attempt);
        onResult({
          challengeId: result.value.challengeId,
          ...(result.value.code ? { code: result.value.code } : {}),
          email: result.value.email,
          kind: "challenge",
          purpose: "google_link",
        });
      };
      try {
        await renderGoogleSignInButton({
          clientId,
          element,
          nonce,
          onCredential: (response) => {
            if (!active) return;
            const credential = response.credential?.trim();
            if (!credential) {
              onError(
                new Error(messages.auth_google_missing_credential({}, { locale }))
              );
              return;
            }
            void complete(credential).catch((error: unknown) => {
              if (active)
                onError(error instanceof Error ? error : new Error(String(error)));
            });
          },
        });
      } catch (error) {
        await cancelCurrentAttempt().catch(() => undefined);
        throw error;
      }
      return () => {
        active = false;
      };
    },
    // The core counts these down on its clock; the screen only shows them.
    loginTiming: {
      get: () => timing,
      subscribe(listener) {
        attemptListeners.add(listener);
        return () => void attemptListeners.delete(listener);
      },
    },
    sharedChallenge: {
      get() {
        const challenge = attempt?.challenge;
        return challenge
          ? {
              challengeId: challenge.challengeId,
              ...(challenge.email ? { email: challenge.email } : {}),
              kind: "challenge",
              purpose: challenge.purpose,
            }
          : undefined;
      },
      subscribe(listener) {
        attemptListeners.add(listener);
        return () => void attemptListeners.delete(listener);
      },
    },
  };

  const guestError = (code: string) =>
    sessionOperationDisplayError(
      code,
      messages.auth_guest_unavailable({}, { locale }),
      locale
    );
  const guest: SessionGuestController = {
    availability: () => call("session.guest.availability", {}).catch(() => false),
    async beginSignUp() {
      if (snapshot.phase !== "signed_in") throw stale();
      const result = await call("session.guest.signUp", {
        expected: sessionExpectation(snapshot),
      });
      if (!result.ok) throw guestError(result.error.code);
    },
    async start() {
      const result = await call("session.guest.start", { expected: absence() });
      if (!result.ok) throw guestError(result.error.code);
    },
    subscribeImported(listener) {
      importListeners.add(listener);
      return () => void importListeners.delete(listener);
    },
  };

  return {
    apiBaseUrl: input.apiBaseUrl,
    authenticator,
    ...(electron ? {} : { guest }),
    lifecycle,
    // Subscribed while a window shows the recovery: the core runs it only then.
    connectionRecovery: {
      get: () => recovery,
      subscribe(listener) {
        recoveryListeners.add(listener);
        stopRecovery ??= core.subscribe(
          { topic: "sessionRecovery" },
          (raw) => {
            recovery = (raw as "trying" | "exhausted" | null) ?? null;
            for (const each of Array.from(recoveryListeners)) each();
          },
          () => undefined
        );
        return () => {
          recoveryListeners.delete(listener);
          if (recoveryListeners.size > 0) return;
          stopRecovery?.();
          stopRecovery = null;
          recovery = null;
        };
      },
    },
    dispose() {
      stopSession();
      product?.stop();
      product = null;
    },
    getProductTransport() {
      const key = leaseKey(snapshot);
      if (snapshot.phase !== "signed_in" || key === null) return undefined;
      if (product?.key === key) return product.transport;
      const { generation, session } = snapshot;
      const controller = new AbortController();
      // Electron: Main's proxy adds the bearer for exactly this lease, and refuses the request for any other.
      const presence = encodeSessionPresenceExpectation({
        authorityInstanceId: snapshot.authority.authorityInstanceId,
        expectedAudience: session.audience,
        expectedSessionId: session.sessionId,
        generation,
      });
      const transport: CommaApiSessionTransport = {
        credentials: electron ? "omit" : "include",
        signal: controller.signal,
        applyHeaders(headers) {
          if (electron) {
            headers[sessionPresenceExpectationHeader] = presence;
            return;
          }
          headers["x-comma-expected-auth-session-id"] = session.sessionId;
          headers["x-comma-session-lifecycle-version"] = "1";
          headers["x-comma-session-transport"] = "cookie";
        },
        // The core hears it, as when one of its own requests is refused.
        reportSessionRejection(status) {
          void call("session.rejected", {
            sessionId: session.sessionId,
            generation,
            status,
          }).catch(() => undefined);
        },
      };
      product = { key, transport, stop: () => controller.abort() };
      return transport;
    },
    // The core finds the session out as it starts; a page has nothing to start.
    initialize: () => Promise.resolve(),
    recover: () => call("session.recover", {}).then(() => undefined),
  };
}

/** The login screen's countdowns from the core's view (a new object only when one moved). */
function loginTiming(
  attempt: SessionAttempt | null,
  cooldown: SessionEmailCooldown | null
): SessionLoginTiming {
  const challenge = attempt?.challenge;
  return {
    ...(challenge
      ? {
          challenge: {
            challengeId: challenge.challengeId,
            expired: challenge.expired === true,
            resendInSeconds: challenge.resendInSeconds ?? 0,
            ...(challenge.retrySameCode ? { retrySameCode: true } : {}),
          },
        }
      : {}),
    ...(cooldown && cooldown.seconds > 0 ? { cooldown } : {}),
  };
}
