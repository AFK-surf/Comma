// Main's bearer gate as the client core drives it: it follows the snapshots the core publishes, opens only for the
// active credential the core's lease names, refuses an older generation, and shuts for good at a generation a 401 hit.
import { describe, expect, it, vi } from "vitest";
import {
  MainCredentialGate,
  type MainProductCredentialLease,
} from "../modules/session";
import {
  acceptVerified,
  beginInvalidation,
  beginSignOut,
} from "../../test-support/session-gate";

const credential = {
  audience: "https://api-a.comma.example",
  email: "peng@example.com",
  expiresAtEpochSeconds: 1_900_000_000,
  sessionId: "session-a",
  token: "main-only-secret",
  userId: "user-a",
} as const;

describe("MainCredentialGate", () => {
  it("starts shut and opens only the exact lease the core confirmed, never projecting its token", () => {
    const gate = createGate();
    expect(gate.getSnapshot()).toMatchObject({ generation: 0, phase: "initializing" });
    expect(gate.acquireProductCredential(expectation(0))).toBeNull();

    const snapshot = acceptVerified(gate, credential);
    expect(snapshot).toMatchObject({
      generation: 1,
      phase: "signed_in",
      session: { audience: credential.audience, sessionId: credential.sessionId },
    });
    expect(JSON.stringify(snapshot)).not.toContain(credential.token);

    const lease = gate.acquireProductCredential(expectation(1));
    expect(lease).toMatchObject({
      audience: credential.audience,
      authorityInstanceId: "main-authority",
      generation: 1,
      sessionId: credential.sessionId,
      token: credential.token,
    });
    expect(lease && gate.isCurrentProductCredential(lease)).toBe(true);
    expect(
      gate.acquireProductCredential({
        ...expectation(1),
        expectedSessionId: "session-stale",
      })
    ).toBeNull();
    expect(
      gate.acquireProductCredential({
        ...expectation(1),
        expectedAudience: "https://api-b.comma.example",
      })
    ).toBeNull();
    expect(
      gate.acquireProductCredential({
        ...expectation(1),
        token: "renderer-secret",
      } as never)
    ).toBeNull();
  });

  it("keeps a lease current across a snapshot that only changes its cleanup", () => {
    const gate = createGate();
    const signedIn = acceptVerified(gate, credential);
    const lease = gate.acquireProductCredential(expectation(1));
    expect(
      gate.follow(
        {
          ...signedIn,
          cleanup: { pendingCount: 1, revocation: "pending" },
          revision: signedIn.revision + 1,
        },
        {
          audience: credential.audience,
          authorityInstanceId: "main-authority",
          generation: 1,
          sessionId: credential.sessionId,
        },
        credential
      )
    ).toBe(true);
    expect(gate.getSnapshot().revision).toBe(signedIn.revision + 1);
    expect(lease?.signal.aborted).toBe(false);
    expect(lease && gate.isCurrentProductCredential(lease)).toBe(true);
  });

  it.each(["sign_out", "invalidate"] as const)(
    "shuts before its consumers hear the core's %s",
    (operation) => {
      let lease: MainProductCredentialLease | null = null;
      const observed = vi.fn();
      const gate: MainCredentialGate = createGate({
        onSnapshotChanged(snapshot) {
          if (snapshot.phase === "signing_out" || snapshot.phase === "invalidating")
            observed(
              gate.acquireProductCredential(expectation(1)),
              lease && gate.isCurrentProductCredential(lease)
            );
        },
      });
      acceptVerified(gate, credential);
      lease = gate.acquireProductCredential(expectation(1));
      if (operation === "sign_out") beginSignOut(gate);
      else beginInvalidation(gate, expectation(1));
      expect(observed).toHaveBeenCalledWith(null, false);
      expect(lease?.signal.aborted).toBe(true);
      expect(gate.getSnapshot()).toMatchObject({
        generation: 2,
        phase: operation === "sign_out" ? "signing_out" : "invalidating",
      });
    }
  );

  it("refuses a snapshot whose generation went back, and shuts", () => {
    const gate = createGate();
    const signedIn = acceptVerified(gate, credential);
    acceptVerified(gate, { ...credential, sessionId: "session-b" });
    expect(
      gate.follow(
        { ...signedIn, revision: 10 },
        {
          audience: credential.audience,
          authorityInstanceId: "main-authority",
          generation: 1,
          sessionId: credential.sessionId,
        },
        credential
      )
    ).toBe(false);
    expect(gate.acquireProductCredential(expectation(1))).toBeNull();
    expect(gate.getSnapshot()).toMatchObject({ generation: 2 });
  });

  it("opens no lease for a credential of another audience or session than the lease names", () => {
    const gate = createGate();
    acceptVerified(gate, { ...credential, audience: "https://api-b.comma.example" });
    expect(gate.acquireProductCredential(expectation(1))).toBeNull();
    expect(
      gate.acquireProductCredential({
        ...expectation(1),
        expectedAudience: "https://api-b.comma.example",
      })
    ).toBeNull();
    const snapshot = gate.getSnapshot();
    gate.follow(
      {
        ...snapshot,
        revision: snapshot.revision + 1,
        generation: 2,
        session: {
          audience: credential.audience,
          expiresAtEpochSeconds: 1,
          sessionId: credential.sessionId,
        },
        phase: "signed_in",
        principal: { email: credential.email, userId: credential.userId },
      },
      {
        audience: credential.audience,
        authorityInstanceId: "main-authority",
        generation: 2,
        sessionId: credential.sessionId,
      },
      { ...credential, sessionId: "session-other" }
    );
    expect(gate.acquireProductCredential(expectation(2))).toBeNull();
  });

  it("shuts on a 401 Main saw and never opens that generation again", () => {
    const gate = createGate();
    const signedIn = acceptVerified(gate, credential);
    const lease = gate.acquireProductCredential(expectation(1))!;
    expect(gate.revoke(lease)).toBe(true);
    expect(gate.isCurrentProductCredential(lease)).toBe(false);
    expect(gate.resume()).toMatchObject({ generation: 1, sessionId: null });
    // A core that restarts and finds the same session at that generation is not let through.
    gate.follow(
      { ...signedIn, revision: signedIn.revision + 1 },
      {
        audience: credential.audience,
        authorityInstanceId: "main-authority",
        generation: 1,
        sessionId: credential.sessionId,
      },
      credential
    );
    expect(gate.acquireProductCredential(expectation(1))).toBeNull();
    acceptVerified(gate, credential);
    expect(gate.acquireProductCredential(expectation(2))).not.toBeNull();
  });

  it("answers the token-free recovery reference when it refuses a lease", () => {
    const gate = createGate();
    acceptVerified(gate, credential);
    beginSignOut(gate);
    expect(gate.admissionFailure()).toEqual({
      code: "session_product_lease_unavailable",
      recovery: { authorityInstanceId: "main-authority", generation: 2, revision: 2 },
    });
  });
});

function createGate(
  overrides: Partial<ConstructorParameters<typeof MainCredentialGate>[0]> = {}
) {
  return new MainCredentialGate({
    authorityInstanceId: "main-authority",
    trustedAudience: credential.audience,
    ...overrides,
  });
}

function expectation(generation: number) {
  return {
    authorityInstanceId: "main-authority",
    expectedAudience: credential.audience,
    expectedSessionId: credential.sessionId,
    generation,
  };
}
