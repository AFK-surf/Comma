import { describe, expect, it, vi } from "vitest";
import {
  MainProductCredentialAuthority,
  type MainProductCredentialLease,
} from "../modules/session";

const credential = {
  audience: "https://api-a.comma.example",
  email: "peng@example.com",
  expiresAtEpochSeconds: 1_900_000_000,
  sessionId: "session-a",
  token: "main-only-secret",
  userId: "user-a",
} as const;

describe("MainProductCredentialAuthority", () => {
  it("opens only a verified exact lease and never projects its token", () => {
    const authority = createAuthority({ persistedCredential: credential });

    expect(authority.getSnapshot()).toMatchObject({
      generation: 0,
      phase: "initializing",
    });
    expect(authority.acquireProductCredential(expectation(0))).toBeNull();

    const snapshot = authority.acceptVerifiedCredential(credential);
    expect(snapshot).toMatchObject({
      generation: 1,
      phase: "signed_in",
      session: {
        audience: credential.audience,
        sessionId: credential.sessionId,
      },
    });
    expect(JSON.stringify(snapshot)).not.toContain(credential.token);

    const lease = authority.acquireProductCredential(expectation(1));
    expect(lease).toMatchObject({
      audience: credential.audience,
      authorityInstanceId: "main-authority",
      generation: 1,
      sessionId: credential.sessionId,
      token: credential.token,
    });
    expect(lease && authority.isCurrentProductCredential(lease)).toBe(true);
    expect(
      authority.acquireProductCredential({
        ...expectation(1),
        expectedSessionId: "session-stale",
      })
    ).toBeNull();
    expect(
      authority.acquireProductCredential({
        ...expectation(1),
        expectedAudience: "https://api-b.comma.example",
      })
    ).toBeNull();
    expect(
      authority.acquireProductCredential({
        ...expectation(1),
        token: "renderer-secret",
      } as never)
    ).toBeNull();
  });

  it("keeps a lease current across revision-only cleanup changes", () => {
    const authority = createAuthority();
    const signedIn = authority.acceptVerifiedCredential(credential);
    const lease = authority.acquireProductCredential(expectation(1));
    expect(lease).not.toBeNull();

    const updated = authority.updateCleanup({
      pendingCount: 1,
      revocation: "pending",
    });

    expect(updated.generation).toBe(signedIn.generation);
    expect(updated.revision).toBe(signedIn.revision + 1);
    expect(lease?.signal.aborted).toBe(false);
    expect(lease && authority.isCurrentProductCredential(lease)).toBe(true);
  });

  it.each(["sign_out", "invalidate"] as const)(
    "closes the product gate before publishing %s intent",
    (operation) => {
      let authority: MainProductCredentialAuthority;
      let lease: MainProductCredentialLease | null = null;
      const observedGate = vi.fn();
      authority = createAuthority({
        onSnapshotChanged(snapshot) {
          if (snapshot.phase === "signing_out" || snapshot.phase === "invalidating") {
            observedGate(
              authority.acquireProductCredential(expectation(1)),
              lease && authority.isCurrentProductCredential(lease)
            );
          }
        },
      });
      authority.acceptVerifiedCredential(credential);
      lease = authority.acquireProductCredential(expectation(1));

      if (operation === "sign_out") {
        authority.beginSignOut();
      } else {
        authority.beginInvalidation(expectation(1));
      }

      expect(observedGate).toHaveBeenCalledWith(null, false);
      expect(lease?.signal.aborted).toBe(true);
      expect(authority.getSnapshot()).toMatchObject({
        generation: 2,
        phase: operation === "sign_out" ? "signing_out" : "invalidating",
      });
    }
  );

  it("ignores a stale invalidation without closing the current gate", () => {
    const authority = createAuthority();
    authority.acceptVerifiedCredential(credential);
    const lease = authority.acquireProductCredential(expectation(1));

    expect(
      authority.beginInvalidation({
        ...expectation(1),
        expectedSessionId: "session-stale",
      })
    ).toBeNull();
    expect(lease && authority.isCurrentProductCredential(lease)).toBe(true);
  });

  it("fails an A/B persisted-audience mismatch closed without callbacks", () => {
    const onSnapshotChanged = vi.fn();
    const authority = createAuthority({
      onSnapshotChanged,
      persistedCredential: credential,
      trustedAudience: "https://api-b.comma.example",
    });

    expect(authority.getSnapshot()).toMatchObject({
      cleanup: { revocation: "idle" },
      generation: 0,
      phase: "indeterminate",
      problem: {
        code: "protocol_mismatch",
        operation: "initialize",
        recovery: "after_host_change",
        retryable: false,
      },
      revision: 0,
    });
    expect(authority.acquireProductCredential(expectation(0))).toBeNull();
    expect(
      authority.acquireProductCredential({
        ...expectation(0),
        expectedAudience: "https://api-b.comma.example",
      })
    ).toBeNull();
    expect(onSnapshotChanged).not.toHaveBeenCalled();
  });

  it("publishes authenticating only from an absence projection", () => {
    const authority = createAuthority();
    const authenticating = authority.beginAuthentication();

    expect(authenticating).toMatchObject({
      generation: 0,
      phase: "authenticating",
      revision: 1,
    });
    expect(authority.beginAuthentication()).toMatchObject({
      phase: "authenticating",
      revision: 2,
    });

    authority.acceptVerifiedCredential(credential);
    expect(authority.beginAuthentication()).toBeNull();
  });

  it("returns the strict token-free recovery reference on admission failure", () => {
    const authority = createAuthority();
    authority.acceptVerifiedCredential(credential);
    authority.beginSignOut();

    expect(authority.admissionFailure()).toEqual({
      code: "session_product_lease_unavailable",
      recovery: {
        authorityInstanceId: "main-authority",
        generation: 2,
        revision: 2,
      },
    });
  });

  it("rejects non-canonical or structurally non-strict credentials", () => {
    const authority = createAuthority();

    expect(() =>
      authority.acceptVerifiedCredential({
        ...credential,
        audience: "https://api-a.comma.example/",
      })
    ).toThrow("canonical");
    expect(() =>
      authority.acceptVerifiedCredential({
        ...credential,
        refreshToken: "forbidden",
      } as never)
    ).toThrow();
  });
});

function createAuthority(
  overrides: Partial<
    ConstructorParameters<typeof MainProductCredentialAuthority>[0]
  > = {}
) {
  return new MainProductCredentialAuthority({
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
