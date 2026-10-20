// Main's credential gate driven as the client core drives it (packages/core/src/session/electron-lifecycle.ts): the
// snapshots the core would publish, told to the gate with the lease and Main's active credential. For tests of Main's
// consumers, which need a gate that is signed in, invalidated or signed out.
import {
  sessionProductLease,
  type SessionLifecycleSnapshot,
  type SessionPresenceExpectation,
} from "@comma/session-contract";
import type { SecureSessionActiveCredential } from "../main/modules/session/credential";
import type { MainCredentialGate } from "../main/modules/session/main-credential-gate";

function next(
  gate: MainCredentialGate,
  body: Record<string, unknown>,
  generationStep: number
): SessionLifecycleSnapshot {
  const current = gate.getSnapshot();
  return {
    authority: current.authority,
    cleanup: { revocation: "idle" },
    contractVersion: 1,
    generation: current.generation + generationStep,
    revision: current.revision + 1,
    ...body,
  } as SessionLifecycleSnapshot;
}

/** The core confirmed `credential`'s session: a new generation, its lease open in the gate. */
export function acceptVerified(
  gate: MainCredentialGate,
  credential: SecureSessionActiveCredential
): SessionLifecycleSnapshot {
  const snapshot = next(
    gate,
    {
      phase: "signed_in",
      principal: { email: credential.email, userId: credential.userId },
      session: {
        audience: credential.audience,
        expiresAtEpochSeconds: credential.expiresAtEpochSeconds,
        sessionId: credential.sessionId,
      },
    },
    1
  );
  gate.follow(snapshot, sessionProductLease(snapshot) ?? null, credential);
  return gate.getSnapshot();
}

function transient(
  gate: MainCredentialGate,
  phase: "invalidating" | "signing_out"
): SessionLifecycleSnapshot {
  const hadLease = gate.getSnapshot().phase === "signed_in";
  gate.follow(
    next(gate, { phase, principal: null, session: null }, hadLease ? 1 : 0),
    null,
    undefined
  );
  return gate.getSnapshot();
}

/** The core began invalidating the session (a 401): the lease shuts. Null when `expected` is not the current lease. */
export function beginInvalidation(
  gate: MainCredentialGate,
  expected?: SessionPresenceExpectation
): SessionLifecycleSnapshot | null {
  const current = gate.getSnapshot();
  if (current.phase !== "signed_in") return null;
  const lease = sessionProductLease(current)!;
  if (
    expected &&
    (expected.authorityInstanceId !== lease.authorityInstanceId ||
      expected.generation !== lease.generation ||
      expected.expectedSessionId !== lease.sessionId ||
      expected.expectedAudience !== lease.audience)
  )
    return null;
  return transient(gate, "invalidating");
}

/** The core began signing out: the lease shuts. */
export function beginSignOut(gate: MainCredentialGate): SessionLifecycleSnapshot {
  return transient(gate, "signing_out");
}

/** The core settled signed out. */
export function settleSignedOut(
  gate: MainCredentialGate,
  reason: "expired" | "no_session" | "unauthorized" | "user_signed_out"
): SessionLifecycleSnapshot {
  gate.follow(
    next(gate, { phase: "signed_out", principal: null, reason, session: null }, 0),
    null,
    undefined
  );
  return gate.getSnapshot();
}
