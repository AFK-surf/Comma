import { describe, expect, it } from "vitest";
import { mergeSessionSnapshot, type SessionLifecycleSnapshot } from "../index";

function signedIn(
  overrides: Partial<SessionLifecycleSnapshot> = {}
): SessionLifecycleSnapshot {
  return {
    authority: {
      authorityInstanceId: "authority-1",
      kind: "electron_main",
    },
    cleanup: { revocation: "idle" },
    contractVersion: 1,
    generation: 1,
    phase: "signed_in",
    principal: {
      email: "peng@example.com",
      userId: "user-1",
    },
    revision: 1,
    session: {
      audience: "https://api-a.comma.example",
      expiresAtEpochSeconds: 1_800_000_000,
      sessionId: "session-a",
    },
    ...overrides,
  } as SessionLifecycleSnapshot;
}

describe("SessionLifecycle reducer", () => {
  it("accepts revision-only metadata without revoking a product lease", () => {
    const current = signedIn();
    const result = mergeSessionSnapshot(current, {
      ...current,
      cleanup: { pendingCount: 1, revocation: "pending" },
      revision: 2,
    });

    expect(result).toMatchObject({
      accepted: true,
      leaseIssued: false,
      leaseRevoked: false,
    });
  });

  it("rejects a Session or audience replacement inside one generation", () => {
    const current = signedIn();
    const replaced = {
      ...current,
      revision: 2,
      session: {
        ...current.session,
        audience: "https://api-b.comma.example",
        sessionId: "session-b",
      },
    };

    expect(mergeSessionSnapshot(current, replaced)).toEqual({
      accepted: false,
      reason: "lease_changed_without_generation",
      snapshot: current,
    });
  });

  it("revokes account A before accepting account B", () => {
    const current = signedIn();
    const next = signedIn({
      generation: 2,
      revision: 2,
      session: {
        audience: "https://api-b.comma.example",
        expiresAtEpochSeconds: 1_800_000_100,
        sessionId: "session-b",
      },
    });
    const result = mergeSessionSnapshot(current, next);

    expect(result).toMatchObject({
      accepted: true,
      leaseIssued: true,
      leaseRevoked: true,
    });
  });

  it("requires a trusted host rebind for a new authority instance", () => {
    const current = signedIn();
    const rebound = signedIn({
      authority: {
        authorityInstanceId: "authority-2",
        kind: "electron_main",
      },
      generation: 0,
      revision: 0,
    });

    expect(mergeSessionSnapshot(current, rebound)).toMatchObject({
      accepted: false,
      reason: "authority_rebind_required",
    });
    expect(
      mergeSessionSnapshot(current, rebound, {
        trustedAuthorityRebind: true,
      })
    ).toMatchObject({
      accepted: true,
      leaseIssued: true,
      leaseRevoked: true,
    });
  });

  it("drops duplicate, out-of-order, and generation-regressing projections", () => {
    const current = signedIn({ generation: 3, revision: 5 });

    expect(mergeSessionSnapshot(current, { ...current, revision: 5 })).toMatchObject({
      accepted: false,
      reason: "stale_revision",
    });
    expect(
      mergeSessionSnapshot(current, {
        ...current,
        generation: 2,
        revision: 6,
      })
    ).toMatchObject({ accepted: false, reason: "generation_regressed" });
  });
});
