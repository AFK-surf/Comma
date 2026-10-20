// Comma Admin's session: the httpOnly session Cookie the API sets (JavaScript never reads it), the sign-in that sets
// it (an emailed code, or Google), the sign-out that clears it, and the lease product requests are made for.
//
// The server contract is the web Cookie session's: every lifecycle request carries the session the page expects
// (`x-comma-expected-auth-session-id`: `unknown` at startup, `none` to sign in, the session id otherwise), the
// lifecycle version and the Cookie transport, and waits at most 8 s on the Clock. At startup the page asks
// `GET /v1/comma/auth/session` once (a second time 250 ms later if it got no answer); while the server cannot be
// reached it tries again 0, 1, 3, 10 and 30 s apart, then waits for the operator (or the browser going online).
//
// A product request refused with 401 ends its lease at once and checks that session: still valid gives a new lease,
// 401 signs out, 409 rebinds to the session the Cookie holds now. A 409 for another session checks the lease's session
// while the lease stays usable; if the server cannot be reached the page stays signed in and checks again 1, 3, 10
// and 30 s later. Every wait is on the Clock.
// An emailed code can be sent again once the server's `resend_after` (60 s when absent) has passed; a rate-limited
// request can be asked again once its `Retry-After` has passed (when the browser may read it). Both waits are counted
// down on the Clock into the login state.
import { messages } from "@comma/i18n";
import {
  Clock,
  Context,
  Data,
  Deferred,
  Duration,
  Effect,
  Exit,
  FiberHandle,
  Layer,
  Option,
  Queue,
  Schema,
  Stream,
  SubscriptionRef,
} from "effect";
import { AdminBrowser } from "./adminBrowser";
import { AdminFetch, AdminNetworkError, errorCode, type HttpAnswer } from "./adminHttp";
import { AdminSession, leaseIsOpen, type SessionLease } from "./adminSession";

export type ChallengePurpose = "email_login" | "google_link";

export interface LoginState {
  readonly busy: boolean;
  /** The six-character code (prefilled when the server returns it, as a local server does). */
  readonly code: string;
  readonly email: string;
  readonly error: string;
  /** Google's own button: loading until it is drawn, unavailable when it could not be prepared. */
  readonly google: "loading" | "ready" | "unavailable";
  readonly notice: string;
  /** Seconds until the emailed code can be sent again (0: now); counted down on the Clock. */
  readonly resendSeconds: number;
  /** After a rate-limited request: the address and the seconds until it can be asked again. */
  readonly retryWait: { readonly email: string; readonly seconds: number } | undefined;
  readonly step:
    | { readonly kind: "email" }
    | {
        readonly challengeId: string;
        readonly kind: "code";
        readonly purpose: ChallengePurpose;
      };
}

/** Why the session could not be confirmed, as the session contract names it. */
export type SessionProblem =
  | "credential_mutation_uncertain"
  | "protocol_mismatch"
  | "session_probe_unavailable";

export type AuthState =
  | { readonly phase: "initializing" }
  | { readonly login: LoginState; readonly phase: "signed_out" }
  | { readonly lease: SessionLease; readonly phase: "signed_in" }
  | { readonly phase: "signing_out" }
  | { readonly phase: "invalidating" }
  /** The server could not be reached; it is asked again on a schedule. */
  | { readonly phase: "connecting" }
  /** The schedule ran out; the operator retries. */
  | { readonly phase: "unavailable" }
  | { readonly phase: "problem"; readonly problem: SessionProblem };

export class GoogleUnavailable extends Data.TaggedError("GoogleUnavailable")<{
  readonly message: string;
}> {}

/** Google Identity Services: draws Google's sign-in button, which hands back an ID token for the given nonce. */
export class GoogleIdentity extends Context.Service<
  GoogleIdentity,
  {
    readonly render: (input: {
      readonly clientId: string;
      readonly element: HTMLElement;
      readonly nonce: string;
      readonly onCredential: (credential: string | undefined) => void;
    }) => Effect.Effect<void, GoogleUnavailable>;
  }
>()("admin/GoogleIdentity") {}

export class AdminAuth extends Context.Service<
  AdminAuth,
  {
    readonly state: SubscriptionRef.SubscriptionRef<AuthState>;
    /** Reads the session the Cookie holds; runs once. */
    readonly start: Effect.Effect<void>;
    readonly setEmail: (email: string) => Effect.Effect<void>;
    readonly setCode: (code: string) => Effect.Effect<void>;
    readonly requestCode: Effect.Effect<void>;
    /** Emails the code again (only once `resendSeconds` is 0). */
    readonly resendCode: Effect.Effect<void>;
    readonly verifyCode: Effect.Effect<void>;
    readonly useDifferentEmail: Effect.Effect<void>;
    readonly retryGoogle: Effect.Effect<void>;
    /** Keeps Google's button drawn into `element` for each prepared attempt, until interrupted. */
    readonly showGoogleButton: (element: HTMLElement) => Effect.Effect<void>;
    readonly signOut: Effect.Effect<void>;
    /** "Try again" on a screen that could not confirm the session. */
    readonly retry: Effect.Effect<void>;
  }
>()("admin/AdminAuth") {}

const requestTimeout = Duration.seconds(8);
const recoveryBackoff = Duration.millis(250);
const connectionRetryDelays = [0, 1_000, 3_000, 10_000, 30_000] as const;
const backgroundRecheckDelays = [1_000, 3_000, 10_000, 30_000] as const;

const SessionProjection = Schema.Struct({
  expires_at: Schema.Finite.check(Schema.isInt(), Schema.isGreaterThan(0)),
  session_id: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(256)),
  // The Cookie transport must never receive a bearer.
  token: Schema.optional(Schema.Never),
  user: Schema.Struct({
    email: Schema.String.check(Schema.isMinLength(3)),
    id: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(256)),
  }),
});
type SessionProjection = typeof SessionProjection.Type;

const EmailChallenge = Schema.Struct({
  challenge_id: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(256)),
  code: Schema.optional(
    Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(32))
  ),
  // Seconds until the server sends another code; absent from older servers.
  resend_after: Schema.optional(Schema.Finite.check(Schema.isGreaterThanOrEqualTo(0))),
});

/** The resend wait when the server does not say. */
const defaultResendSeconds = 60;

const GoogleAttempt = Schema.Struct({
  attempt_id: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(256)),
  client_id: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(2_048)),
  nonce: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(2_048)),
  platform: Schema.Literal("web"),
});
type GoogleAttempt = typeof GoogleAttempt.Type;

const GoogleLinkChallenge = Schema.Struct({
  challenge_id: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(256)),
  code: Schema.optional(
    Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(32))
  ),
  email: Schema.String.check(Schema.isMinLength(3)),
  status: Schema.Literal("otp_required"),
});

const SignedOut = Schema.Struct({ signed_out: Schema.Literal(true) });

const decode =
  <A>(schema: Schema.Decoder<A>) =>
  (body: unknown): A | undefined => {
    const result = Schema.decodeUnknownExit(schema)(body);
    return Exit.isSuccess(result) ? result.value : undefined;
  };
const readProjection = decode(SessionProjection);
const readEmailChallenge = decode(EmailChallenge);
const readGoogleAttempt = decode(GoogleAttempt);
const readGoogleLink = decode(GoogleLinkChallenge);
const readSignedOut = decode(SignedOut);

const isError = (answer: HttpAnswer, code: string) => errorCode(answer.body) === code;
const isProtocolError = (answer: HttpAnswer) =>
  answer.status === 400 ||
  answer.status === 428 ||
  [
    "invalid_session_precondition",
    "session_lifecycle_version_required",
    "unsupported_session_lifecycle_version",
  ].includes(errorCode(answer.body) ?? "");

/** What a sign-in failure says to the operator (the codes of the session contract). */
export function signInErrorMessage(code: string): string {
  switch (code) {
    case "invalid_challenge":
      return messages.auth_verification_code_invalid();
    case "challenge_expired":
      return messages.auth_verification_code_expired();
    case "rate_limited":
      return messages.auth_rate_limited();
    case "network_unavailable":
      return messages.auth_network_unavailable();
    case "provider_unavailable":
      return messages.auth_temporarily_unavailable();
    case "conflict":
      return messages.auth_attempt_stale();
    default:
      return messages.auth_sign_in_failed();
  }
}

function startFailureCode(answer: HttpAnswer) {
  if (answer.status === 429) return "rate_limited";
  if (answer.status >= 500) return "provider_unavailable";
  return "unknown";
}

function completionFailureCode(answer: HttpAnswer, unauthorized: string) {
  if (answer.status === 401) return unauthorized;
  if (answer.status === 409 && isError(answer, "session_changed")) return "conflict";
  if (answer.status === 429) return "rate_limited";
  if (answer.status >= 500) return "provider_unavailable";
  return "unknown";
}

function clientMetadata() {
  const userAgent =
    typeof navigator === "undefined" ? "" : navigator.userAgent.toLowerCase();
  let clientPlatform: "android" | "ios" | "linux" | "macos" | "unknown" | "windows" =
    "unknown";
  if (userAgent.includes("android")) clientPlatform = "android";
  else if (/iphone|ipad|ipod/.test(userAgent)) clientPlatform = "ios";
  else if (userAgent.includes("windows")) clientPlatform = "windows";
  else if (userAgent.includes("mac os") || userAgent.includes("macintosh"))
    clientPlatform = "macos";
  else if (userAgent.includes("linux")) clientPlatform = "linux";
  return { client_kind: "web", client_platform: clientPlatform } as const;
}

const sameAddress = (left: string, right: string) =>
  left.trim().toLowerCase() === right.trim().toLowerCase();

const freshLogin: LoginState = {
  busy: false,
  code: "",
  email: "",
  error: "",
  google: "loading",
  notice: "",
  resendSeconds: 0,
  retryWait: undefined,
  step: { kind: "email" },
};

type ProbeOutcome = "settled" | "unreachable";
const settled: ProbeOutcome = "settled";
const unreachable: ProbeOutcome = "unreachable";

/** `AdminAuth`, and the lease side of it (`AdminSession`) the Admin API makes its requests for. */
export const AdminAuthLive = Layer.effectContext(
  Effect.gen(function* () {
    const http = yield* AdminFetch;
    const state = yield* SubscriptionRef.make<AuthState>({ phase: "initializing" });
    const google = yield* SubscriptionRef.make<
      { readonly attempt: GoogleAttempt; readonly revision: number } | undefined
    >(undefined);
    const credentials = yield* Queue.unbounded<{
      readonly attempt: GoogleAttempt;
      readonly credential: string | undefined;
    }>();
    const googleFiber = yield* FiberHandle.make();
    const recoveryFiber = yield* FiberHandle.make();
    const resendFiber = yield* FiberHandle.make();
    const retryFiber = yield* FiberHandle.make();
    const recheckFiber = yield* FiberHandle.make();
    let started = false;
    let googleRevision = 0;
    const reconciling = new Set<SessionLease>();

    const lifecycle = (
      method: "GET" | "POST",
      path: string,
      expectedSessionId: string,
      body?: Record<string, unknown>
    ) =>
      http
        .send({
          ...(body ? { body } : {}),
          headers: {
            accept: "application/json",
            "x-comma-expected-auth-session-id": expectedSessionId,
            "x-comma-session-lifecycle-version": "1",
            "x-comma-session-transport": "cookie",
          },
          method,
          path,
        })
        .pipe(
          Effect.timeoutOrElse({
            duration: requestTimeout,
            orElse: () =>
              Effect.fail(new AdminNetworkError({ message: "The request timed out." })),
          })
        );

    const updateLogin = (update: (login: LoginState) => LoginState) =>
      SubscriptionRef.update(
        state,
        (current): AuthState =>
          current.phase === "signed_out"
            ? { login: update(current.login), phase: "signed_out" }
            : current
      );

    const currentLease = SubscriptionRef.get(state).pipe(
      Effect.map((current) =>
        current.phase === "signed_in" ? current.lease : undefined
      )
    );

    const closeLease = Effect.gen(function* () {
      const lease = yield* currentLease;
      if (lease) yield* Deferred.succeed(lease.closed, undefined);
    });

    const signedIn = (projection: SessionProjection) =>
      Effect.gen(function* () {
        yield* FiberHandle.clear(googleFiber);
        yield* FiberHandle.clear(resendFiber);
        yield* FiberHandle.clear(retryFiber);
        const current = yield* currentLease;
        if (
          current &&
          leaseIsOpen(current) &&
          current.sessionId === projection.session_id
        ) {
          return;
        }
        if (current) yield* Deferred.succeed(current.closed, undefined);
        const lease: SessionLease = {
          closed: yield* Deferred.make<void>(),
          email: projection.user.email,
          sessionId: projection.session_id,
          userId: projection.user.id,
        };
        yield* SubscriptionRef.set(state, { lease, phase: "signed_in" });
      });

    const prepareGoogle = Effect.gen(function* () {
      googleRevision += 1;
      const revision = googleRevision;
      yield* SubscriptionRef.set(google, undefined);
      yield* updateLogin((login) => ({ ...login, google: "loading" }));
      const answer = yield* lifecycle("POST", "/v1/comma/auth/google/attempt", "none", {
        platform: "web",
      }).pipe(Effect.option);
      const attempt =
        Option.isSome(answer) && answer.value.ok
          ? readGoogleAttempt(answer.value.body)
          : undefined;
      if (!attempt) {
        yield* updateLogin((login) => ({ ...login, google: "unavailable" }));
        return;
      }
      yield* SubscriptionRef.set(google, { attempt, revision });
    });

    const signedOut = Effect.gen(function* () {
      yield* closeLease;
      yield* FiberHandle.clear(resendFiber);
      yield* FiberHandle.clear(retryFiber);
      yield* SubscriptionRef.set(state, { login: freshLogin, phase: "signed_out" });
      yield* FiberHandle.run(googleFiber, prepareGoogle);
    });

    const problem = (code: SessionProblem) =>
      Effect.gen(function* () {
        yield* closeLease;
        yield* SubscriptionRef.set(state, { phase: "problem", problem: code });
      });

    /** Adopts what the server says of the session the Cookie holds; `unreachable` when it said nothing usable. */
    const adopt = (answer: HttpAnswer, expected: string) =>
      Effect.gen(function* () {
        if (answer.ok) {
          const projection = readProjection(answer.body);
          if (
            !projection ||
            (expected !== "unknown" && projection.session_id !== expected)
          ) {
            yield* problem("protocol_mismatch");
            return settled;
          }
          yield* signedIn(projection);
          return settled;
        }
        if (answer.status === 401 && isError(answer, "unauthorized")) {
          yield* signedOut;
          return settled;
        }
        if (isProtocolError(answer)) {
          yield* problem("protocol_mismatch");
          return settled;
        }
        return unreachable;
      });

    /** Asks which session the Cookie holds (expecting none in particular): twice, 250 ms apart, if no answer. */
    const probeCookie = Effect.gen(function* () {
      for (let attempt = 0; attempt < 2; attempt += 1) {
        if (attempt > 0) yield* Effect.sleep(recoveryBackoff);
        const answer = yield* lifecycle(
          "GET",
          "/v1/comma/auth/session",
          "unknown"
        ).pipe(Effect.option);
        if (Option.isSome(answer)) {
          const outcome = yield* adopt(answer.value, "unknown");
          if (outcome === settled) return settled;
        }
      }
      return unreachable;
    });

    /** While the server cannot be reached: asks 0, 1, 3, 10 and 30 s apart, then waits for the operator. */
    const reconnect = Effect.gen(function* () {
      yield* SubscriptionRef.set(state, { phase: "connecting" });
      for (const delay of connectionRetryDelays) {
        if (delay > 0) yield* Effect.sleep(Duration.millis(delay));
        if ((yield* probeCookie) === "settled") return;
      }
      yield* SubscriptionRef.set(state, { phase: "unavailable" });
    });

    const recover = Effect.gen(function* () {
      if ((yield* probeCookie) === "unreachable") {
        yield* FiberHandle.run(recoveryFiber, reconnect);
      }
    });

    /** A product request for `lease` got 401: the lease ends now, then the server says what the Cookie holds. */
    const invalidate = (lease: SessionLease) =>
      Effect.gen(function* () {
        yield* Deferred.succeed(lease.closed, undefined);
        yield* SubscriptionRef.set(state, { phase: "invalidating" });
        const answer = yield* lifecycle(
          "GET",
          "/v1/comma/auth/session",
          lease.sessionId
        ).pipe(Effect.option);
        if (Option.isNone(answer)) {
          yield* problem("credential_mutation_uncertain");
          return;
        }
        if (answer.value.status === 409 && isError(answer.value, "session_changed")) {
          yield* recover;
          return;
        }
        if ((yield* adopt(answer.value, lease.sessionId)) === "unreachable") {
          yield* problem("credential_mutation_uncertain");
        }
      });

    /** A product request for `lease` got 409: checks the lease's session while it stays usable. */
    const reconcile = (lease: SessionLease) =>
      Effect.gen(function* () {
        for (const delay of [0, ...backgroundRecheckDelays]) {
          if (delay > 0) yield* Effect.sleep(Duration.millis(delay));
          if ((yield* currentLease) !== lease || !leaseIsOpen(lease)) return;
          const answer = yield* lifecycle(
            "GET",
            "/v1/comma/auth/session",
            lease.sessionId
          ).pipe(Effect.option);
          if (Option.isNone(answer) || answer.value.status >= 500) continue;
          if (answer.value.status === 409 && isError(answer.value, "session_changed")) {
            yield* recover;
            return;
          }
          if ((yield* adopt(answer.value, lease.sessionId)) === "settled") return;
        }
      }).pipe(Effect.ensuring(Effect.sync(() => reconciling.delete(lease))));

    const session = AdminSession.of({
      lease: currentLease.pipe(
        Effect.map((lease) => (lease && leaseIsOpen(lease) ? lease : undefined))
      ),
      refused: (lease, status) =>
        Effect.gen(function* () {
          if ((yield* currentLease) !== lease || !leaseIsOpen(lease)) return;
          if (status === 401) {
            yield* FiberHandle.clear(recheckFiber);
            yield* FiberHandle.run(recheckFiber, invalidate(lease));
            return;
          }
          if (reconciling.has(lease)) return;
          reconciling.add(lease);
          yield* FiberHandle.run(recheckFiber, reconcile(lease));
        }),
    });

    const failLogin = (code: string) =>
      updateLogin((login) => ({
        ...login,
        busy: false,
        error: signInErrorMessage(code),
      }));

    /** Counts `seconds` down on the Clock into the login state, one second at a time. */
    const countDown = (
      seconds: number,
      show: (login: LoginState, left: number) => LoginState
    ) =>
      Effect.gen(function* () {
        const deadline = (yield* Clock.currentTimeMillis) + seconds * 1_000;
        for (;;) {
          const now = yield* Clock.currentTimeMillis;
          const left = Math.max(0, Math.ceil((deadline - now) / 1_000));
          yield* updateLogin((login) => show(login, left));
          if (left === 0) return;
          yield* Effect.sleep(Duration.millis(deadline - now - (left - 1) * 1_000));
        }
      });

    const showResend = (seconds: number) =>
      FiberHandle.run(
        resendFiber,
        countDown(seconds, (login, left) => ({ ...login, resendSeconds: left }))
      ).pipe(Effect.asVoid);

    /** Asks the server to email a code to `email`; on success the code step shows it. */
    const sendCode = (email: string, resend: boolean) =>
      Effect.gen(function* () {
        yield* updateLogin((login) => ({
          ...login,
          busy: true,
          error: "",
          notice: "",
        }));
        const answer = yield* lifecycle("POST", "/v1/comma/auth/email/login", "none", {
          email,
        }).pipe(Effect.option);
        if (Option.isNone(answer)) return yield* failLogin("network_unavailable");
        if (!answer.value.ok) {
          const code = startFailureCode(answer.value);
          const waitMs =
            code === "rate_limited" ? answer.value.retryAfterMs : undefined;
          yield* failLogin(code);
          if (waitMs === undefined) return;
          const seconds = Math.ceil(waitMs / 1_000);
          if (resend) return yield* showResend(seconds);
          yield* FiberHandle.run(
            retryFiber,
            countDown(seconds, (login, left) => ({
              ...login,
              retryWait: left > 0 ? { email, seconds: left } : undefined,
            }))
          );
          return;
        }
        const challenge = readEmailChallenge(answer.value.body);
        if (!challenge) return yield* failLogin("protocol_mismatch");
        yield* FiberHandle.clear(googleFiber);
        yield* updateLogin((login) => ({
          ...login,
          busy: false,
          code: challenge.code ?? "",
          email,
          notice: messages.auth_verification_code_sent(),
          step: {
            challengeId: challenge.challenge_id,
            kind: "code",
            purpose: "email_login",
          },
        }));
        yield* showResend(challenge.resend_after ?? defaultResendSeconds);
      });

    const requestCode = Effect.gen(function* () {
      const current = yield* SubscriptionRef.get(state);
      if (current.phase !== "signed_out" || current.login.busy) return;
      const email = current.login.email.trim();
      if (!email) {
        yield* updateLogin((login) => ({
          ...login,
          error: messages.auth_enter_email(),
        }));
        return;
      }
      const wait = current.login.retryWait;
      if (wait && wait.seconds > 0 && sameAddress(wait.email, email)) return;
      yield* sendCode(email, false);
    });

    /** Emails the code again, once the resend wait is over. */
    const resendCode = Effect.gen(function* () {
      const current = yield* SubscriptionRef.get(state);
      if (current.phase !== "signed_out" || current.login.busy) return;
      const { login } = current;
      if (login.step.kind !== "code" || login.step.purpose !== "email_login") return;
      if (login.resendSeconds > 0) return;
      yield* sendCode(login.email, true);
    });

    /** Completes a sign-in (`path`), which answers with the new session. */
    const complete = (
      path: string,
      body: Record<string, unknown>,
      unauthorized: string
    ) =>
      Effect.gen(function* () {
        const answer = yield* lifecycle("POST", path, "none", {
          ...body,
          ...clientMetadata(),
        }).pipe(Effect.option);
        if (Option.isNone(answer)) {
          yield* problem("credential_mutation_uncertain");
          return undefined;
        }
        if (!answer.value.ok) {
          yield* failLogin(completionFailureCode(answer.value, unauthorized));
          return undefined;
        }
        return answer.value.body;
      });

    const verifyCode = Effect.gen(function* () {
      const current = yield* SubscriptionRef.get(state);
      if (current.phase !== "signed_out" || current.login.busy) return;
      const { login } = current;
      if (login.step.kind !== "code") return;
      const code = login.code.trim();
      if (!code) {
        yield* updateLogin((value) => ({
          ...value,
          error: messages.auth_enter_verification_code(),
        }));
        return;
      }
      yield* updateLogin((value) => ({ ...value, busy: true, error: "", notice: "" }));
      const body = yield* complete(
        login.step.purpose === "google_link"
          ? "/v1/comma/auth/google/link/verify"
          : "/v1/comma/auth/email/verify",
        { challenge_id: login.step.challengeId, code },
        "invalid_challenge"
      );
      if (body === undefined) return;
      const projection = readProjection(body);
      if (!projection) return yield* problem("protocol_mismatch");
      yield* signedIn(projection);
    });

    const completeGoogle = (attempt: GoogleAttempt, credential: string | undefined) =>
      Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        if (current.phase !== "signed_out") return;
        const token = credential?.trim();
        if (!token) {
          yield* updateLogin((login) => ({
            ...login,
            error: messages.auth_google_missing_credential(),
            google: "unavailable",
          }));
          return;
        }
        const body = yield* complete(
          "/v1/comma/auth/google",
          { attempt_id: attempt.attempt_id, credential: token, nonce: attempt.nonce },
          "unknown"
        );
        if (body === undefined) {
          yield* updateLogin((login) => ({ ...login, google: "unavailable" }));
          return;
        }
        const projection = readProjection(body);
        if (projection) return yield* signedIn(projection);
        const link = readGoogleLink(body);
        if (!link) return yield* problem("protocol_mismatch");
        yield* FiberHandle.clear(googleFiber);
        yield* updateLogin((login) => ({
          ...login,
          code: link.code ?? "",
          email: link.email,
          error: "",
          notice: messages.auth_verification_code_sent(),
          step: {
            challengeId: link.challenge_id,
            kind: "code",
            purpose: "google_link",
          },
        }));
      });

    yield* Queue.take(credentials).pipe(
      Effect.flatMap(({ attempt, credential }) => completeGoogle(attempt, credential)),
      Effect.forever,
      Effect.forkScoped
    );

    const googleIdentity = yield* GoogleIdentity;
    const showGoogleButton = (element: HTMLElement) =>
      SubscriptionRef.changes(google).pipe(
        Stream.runForEach((prepared) =>
          prepared
            ? googleIdentity
                .render({
                  clientId: prepared.attempt.client_id,
                  element,
                  nonce: prepared.attempt.nonce,
                  onCredential: (credential) => {
                    Queue.offerUnsafe(credentials, {
                      attempt: prepared.attempt,
                      credential,
                    });
                  },
                })
                .pipe(
                  Effect.matchEffect({
                    onFailure: () =>
                      updateLogin((login) => ({ ...login, google: "unavailable" })),
                    onSuccess: () =>
                      prepared.revision === googleRevision
                        ? updateLogin((login) => ({ ...login, google: "ready" }))
                        : Effect.void,
                  })
                )
            : Effect.void
        )
      );

    const signOut = Effect.gen(function* () {
      const lease = yield* currentLease;
      if (!lease) return;
      yield* FiberHandle.clear(recheckFiber);
      yield* Deferred.succeed(lease.closed, undefined);
      yield* SubscriptionRef.set(state, { phase: "signing_out" });
      const answer = yield* lifecycle(
        "POST",
        "/v1/comma/auth/logout",
        lease.sessionId,
        {}
      ).pipe(Effect.option);
      if (Option.isNone(answer)) return yield* problem("credential_mutation_uncertain");
      const { value } = answer;
      if (value.ok && readSignedOut(value.body)) return yield* signedOut;
      if (value.status === 401 && isError(value, "unauthorized"))
        return yield* signedOut;
      yield* problem(
        value.status >= 500 ? "session_probe_unavailable" : "protocol_mismatch"
      );
    });

    const online = (yield* AdminBrowser).online.pipe(
      Stream.runForEach(() =>
        SubscriptionRef.get(state).pipe(
          Effect.flatMap((current) =>
            current.phase === "unavailable"
              ? FiberHandle.run(recoveryFiber, reconnect)
              : Effect.void
          )
        )
      )
    );
    yield* Effect.forkScoped(online);

    const auth = AdminAuth.of({
      state,
      start: Effect.suspend(() => {
        if (started) return Effect.void;
        started = true;
        return recover;
      }),
      setEmail: (email) => updateLogin((login) => ({ ...login, email })),
      setCode: (code) => updateLogin((login) => ({ ...login, code })),
      requestCode,
      resendCode,
      verifyCode,
      useDifferentEmail: Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        if (current.phase !== "signed_out" || current.login.busy) return;
        yield* FiberHandle.clear(resendFiber);
        yield* updateLogin((login) => ({
          ...login,
          code: "",
          error: "",
          notice: "",
          resendSeconds: 0,
          step: { kind: "email" },
        }));
        yield* FiberHandle.run(googleFiber, prepareGoogle);
      }),
      retryGoogle: Effect.gen(function* () {
        yield* updateLogin((login) => ({ ...login, error: "", notice: "" }));
        yield* FiberHandle.run(googleFiber, prepareGoogle);
      }),
      showGoogleButton,
      signOut,
      retry: Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        if (current.phase === "unavailable") {
          yield* FiberHandle.run(recoveryFiber, reconnect);
        } else if (current.phase === "problem") {
          yield* recover;
        }
      }),
    });
    return Context.make(AdminAuth, auth).pipe(Context.add(AdminSession, session));
  })
);
