// The session lifecycle's calls (contract.ts, `session.*`), the web's and Electron's: each checks its params and
// answers the session contract's result. The calls both have are the same calls; the web adds its Google button's two
// steps, guest sessions and Telegram launches, the bearer hosts their Google window and the iPhone's Apple sheet. None is listed in `doing` (its params carry
// codes, credentials and launch data, and the snapshot's phase says what is under way); none stops when its page goes
// (a change of the credential runs to its end).
import {
  sessionAbsenceExpectationSchema,
  sessionAuthAttemptRefSchema,
  sessionCancelAuthAttemptInputSchema,
  sessionLifecycleExpectationSchema,
  sessionRequestEmailLoginInputSchema,
  sessionSignOutInputSchema,
  sessionVerifyLoginInputSchema,
  type SessionOperationName,
} from "@comma/session-contract";
import { CoreError, type Call, type Kernel } from "@comma/core-kernel";
import { Effect } from "effect";
import { z } from "zod";
import type { Session } from "../session.ts";
import { ElectronSessionLifecycle } from "./electron-lifecycle.ts";
import type { WebSessionLifecycle } from "./web-lifecycle.ts";

const absence = z.strictObject({ expected: sessionAbsenceExpectationSchema });
const googleComplete = z.strictObject({
  attempt: sessionAuthAttemptRefSchema,
  credential: z.string().min(1).max(16_384),
  nonce: z.string().min(1).max(2_048),
  providerAttemptId: z.string().min(1).max(256),
});
const telegram = z.strictObject({
  initData: z.string().min(1).max(16_384),
  groupId: z.string().max(256),
});
const handOver = z.strictObject({
  expiresAtEpochSeconds: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
});
const rejected = z.strictObject({
  sessionId: z.string().min(1).max(256),
  generation: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER),
  status: z.union([z.literal(401), z.literal(409)]),
});
const reconcile = z.strictObject({
  reason: z.enum(["focus", "peer_mutation"]),
  expected: sessionLifecycleExpectationSchema.optional(),
});

/** `run(params)` once `schema` accepts them; else `invalid_params`. */
function checked<S extends z.ZodType>(
  schema: S,
  run: (params: z.output<S>) => Effect.Effect<unknown>
): Call {
  return {
    run: (params) => {
      const out = schema.safeParse(params ?? {});
      return out.success
        ? run(out.data)
        : Effect.fail(
            CoreError.invalid(out.error.issues[0]?.message ?? "invalid params")
          );
    },
  };
}

export function registerSessionCalls(
  kernel: Kernel,
  lifecycle: WebSessionLifecycle | ElectronSessionLifecycle,
  session: Session
): void {
  const none = z.strictObject({});
  // A defect answers the operation's `unknown` failure, the snapshot settled (`SessionLifecycle.guard`).
  const failing =
    <Operation extends SessionOperationName>(operation: Operation) =>
    () =>
      lifecycle.unknownFailure(operation);
  const signIn = "authenticate" as const;
  // The recovery runs while a window shows it, and stops as soon as none does.
  let stopWatching: (() => void) | null = null;
  kernel.source("sessionRecovery", {
    start: () => {
      stopWatching ??= lifecycle.watchRecovery();
    },
    stop: () => {
      stopWatching?.();
      stopWatching = null;
    },
    compute: () => ({ ok: lifecycle.recoveryState() }),
    evictAfterMs: 0,
  });
  lifecycle.onRecovery(() => kernel.store.invalidate({ topic: "sessionRecovery" }));
  kernel.calls({
    "session.email.request": checked(sessionRequestEmailLoginInputSchema, (p) =>
      lifecycle.guard(
        lifecycle.requestEmailLogin(p),
        signIn,
        failing("request_email_login")
      )
    ),
    "session.email.verify": checked(sessionVerifyLoginInputSchema, (p) =>
      lifecycle.guard(
        lifecycle.verifyCode("verify_email_login", p, lifecycle.verifyEmailLogin(p)),
        signIn,
        failing("verify_email_login")
      )
    ),
    "session.google.linkVerify": checked(sessionVerifyLoginInputSchema, (p) =>
      lifecycle.guard(
        lifecycle.verifyCode("verify_google_link", p, lifecycle.verifyGoogleLink(p)),
        signIn,
        failing("verify_google_link")
      )
    ),
    "session.cancelAuth": checked(sessionCancelAuthAttemptInputSchema, (p) =>
      lifecycle.guard(
        lifecycle.cancelAuthAttempt(p),
        signIn,
        failing("cancel_auth_attempt")
      )
    ),
    "session.signOut": checked(sessionSignOutInputSchema, (p) =>
      lifecycle.guard(lifecycle.signOut(p), "sign_out", failing("sign_out"))
    ),
    "session.recover": checked(none, () =>
      lifecycle.guard(
        Effect.as(lifecycle.retryConnection(), null),
        "reconcile",
        () => null
      )
    ),
    // The page's own product request was refused: as for one of the core's, if it was made for the lease given now.
    "session.rejected": checked(rejected, (p) =>
      Effect.sync(() => {
        const lease = session.lease();
        if (lease?.sessionId === p.sessionId && lease.generation === p.generation)
          session.rejected(lease, p.status);
        return null;
      })
    ),
    "session.reconcile": checked(reconcile, (p) => {
      const expected = p.expected ?? lifecycle.expectation();
      return lifecycle.guard(
        lifecycle.reconcile(
          expected ? { expected, reason: p.reason } : { reason: p.reason }
        ),
        "reconcile",
        failing("reconcile")
      );
    }),
  });
  if (lifecycle instanceof ElectronSessionLifecycle) {
    kernel.calls({
      // Sign in with Apple through the iPhone's sheet: one call, as Google through Main's window.
      "session.apple": checked(absence, (p) =>
        lifecycle.guard(
          lifecycle.signInWithApple(p),
          signIn,
          failing("sign_in_with_apple")
        )
      ),
      "session.apple.linkVerify": checked(sessionVerifyLoginInputSchema, (p) =>
        lifecycle.guard(
          lifecycle.verifyCode("verify_apple_link", p, lifecycle.verifyAppleLink(p)),
          signIn,
          failing("verify_apple_link")
        )
      ),
      // Google through Main's window: one call, the window's attempt and the exchange in it.
      "session.google.desktop": checked(absence, (p) =>
        lifecycle.guard(
          lifecycle.signInWithGoogle(p),
          signIn,
          failing("sign_in_with_google")
        )
      ),
    });
    return;
  }
  kernel.calls({
    "session.google.attempt": checked(absence, (p) =>
      lifecycle.guard(
        lifecycle.beginGoogleLogin(p),
        signIn,
        failing("sign_in_with_google")
      )
    ),
    "session.google.complete": checked(googleComplete, (p) =>
      lifecycle.guard(
        lifecycle.completeGoogleLogin(p),
        signIn,
        failing("sign_in_with_google")
      )
    ),
    "session.guest.availability": checked(none, () =>
      lifecycle.guard(lifecycle.guestAvailability(), signIn, () => false)
    ),
    "session.guest.start": checked(absence, (p) =>
      lifecycle.guard(
        lifecycle.startGuestSession(p),
        signIn,
        failing("start_guest_session")
      )
    ),
    "session.guest.signUp": checked(sessionSignOutInputSchema, (p) =>
      lifecycle.guard(
        lifecycle.beginGuestSignUp(p),
        signIn,
        failing("begin_guest_sign_up")
      )
    ),
    "session.guest.handOverImport": checked(handOver, (p) =>
      lifecycle.guard(
        lifecycle.handOverGuestImport(p.expiresAtEpochSeconds),
        signIn,
        () => false
      )
    ),
    "session.telegram": checked(telegram, (p) =>
      lifecycle.guard(lifecycle.telegram(p), signIn, () => "failed" as const)
    ),
  });
}
