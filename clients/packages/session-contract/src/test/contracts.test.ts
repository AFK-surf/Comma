import { describe, expect, it } from "vitest";
import {
  sessionAdmissionFailureSchema,
  sessionBoundStateEnvelopeSchema,
  sessionLifecycleSnapshotSchema,
  sessionOperationErrorSchema,
  sessionOperationErrorSchemaFor,
  sessionOperationResultSchema,
  sessionPrincipalKind,
  sessionProductLease,
  sessionReconcileInputSchema,
  sessionReconcileResultSchema,
  sessionRequestEmailLoginInputSchema,
  sessionRequestEmailLoginResultSchema,
  sessionRecoveryRef,
  sessionSignOutInputSchema,
  sessionSignOutResultSchema,
  sessionVerifyEmailLoginResultSchema,
  sessionVerifyLoginInputSchema,
  signedInSessionSnapshotSchema,
} from "../index";
import { z } from "zod";

const signedInSnapshot = {
  authority: {
    authorityInstanceId: "authority-1",
    kind: "electron_main",
  },
  cleanup: { revocation: "idle" },
  contractVersion: 1,
  generation: 4,
  phase: "signed_in",
  principal: {
    email: "peng@example.com",
    userId: "user-1",
  },
  revision: 8,
  session: {
    audience: "https://api.comma.example",
    expiresAtEpochSeconds: 1_800_000_000,
    sessionId: "session-1",
  },
} as const;

describe("SessionLifecycle contract", () => {
  it("strictly decodes a token-free signed-in projection", () => {
    expect(signedInSessionSnapshotSchema.parse(signedInSnapshot)).toEqual(
      signedInSnapshot
    );
    expect(sessionProductLease(signedInSnapshot)).toEqual({
      audience: "https://api.comma.example",
      authorityInstanceId: "authority-1",
      generation: 4,
      sessionId: "session-1",
    });
  });

  it.each([
    [{ ...signedInSnapshot, token: "secret" }],
    [
      {
        ...signedInSnapshot,
        authority: { ...signedInSnapshot.authority, token: "secret" },
      },
    ],
    [
      {
        ...signedInSnapshot,
        principal: { ...signedInSnapshot.principal, authorization: "secret" },
      },
    ],
    [
      {
        ...signedInSnapshot,
        session: { ...signedInSnapshot.session, cookie: "secret" },
      },
    ],
    [
      {
        ...signedInSnapshot,
        cleanup: { revocation: "idle", keychainReference: "secret" },
      },
    ],
  ])("rejects secret-like unknown fields at every object boundary", (value) => {
    expect(() => sessionLifecycleSnapshotSchema.parse(value)).toThrow();
  });

  it("reads a principal without a kind as a registered account", () => {
    const registered = signedInSessionSnapshotSchema.parse(signedInSnapshot);
    const guest = signedInSessionSnapshotSchema.parse({
      ...signedInSnapshot,
      principal: { ...signedInSnapshot.principal, kind: "guest" },
    });

    expect(sessionPrincipalKind(registered.principal)).toBe("registered");
    expect(sessionPrincipalKind(guest.principal)).toBe("guest");
    expect(() =>
      signedInSessionSnapshotSchema.parse({
        ...signedInSnapshot,
        principal: { ...signedInSnapshot.principal, kind: "anonymous" },
      })
    ).toThrow();
  });

  it("requires protocol mismatch to wait for a host change", () => {
    const value = {
      ...signedInSnapshot,
      generation: 5,
      phase: "indeterminate",
      principal: null,
      problem: {
        code: "protocol_mismatch",
        operation: "initialize",
        recovery: "after_host_change",
        retryable: false,
      },
      revision: 9,
      session: null,
    };

    expect(sessionLifecycleSnapshotSchema.parse(value)).toEqual(value);
    expect(() =>
      sessionLifecycleSnapshotSchema.parse({
        ...value,
        problem: {
          ...value.problem,
          recovery: "retry_operation",
          retryable: true,
        },
      })
    ).toThrow();
  });

  it("constrains error code and recovery semantics by operation", () => {
    const recoveryRef = sessionRecoveryRef(signedInSnapshot);
    const valid = {
      code: "rate_limited",
      operation: "request_email_login",
      recovery: "retry_operation",
      recoveryRef,
      retryable: true,
      retryAfterMs: 1_000,
    } as const;

    expect(sessionOperationErrorSchema.parse(valid)).toEqual(valid);
    expect(sessionOperationErrorSchemaFor("request_email_login").parse(valid)).toEqual(
      valid
    );
    expect(() => sessionOperationErrorSchemaFor("sign_out").parse(valid)).toThrow();
    expect(() =>
      sessionOperationErrorSchema.parse({
        ...valid,
        code: "credential_mutation_uncertain",
      })
    ).toThrow();
    expect(() =>
      sessionOperationErrorSchema.parse({
        ...valid,
        retryable: false,
      })
    ).toThrow();
  });

  it("does not permit retryAfterMs on non-retryable recovery", () => {
    expect(() =>
      sessionOperationErrorSchema.parse({
        code: "protocol_mismatch",
        operation: "reconcile",
        recovery: "after_host_change",
        recoveryRef: sessionRecoveryRef(signedInSnapshot),
        retryable: false,
        retryAfterMs: 1_000,
      })
    ).toThrow();
  });

  it("keeps recovery references incapable of acting as product leases", () => {
    const recovery = sessionRecoveryRef(signedInSnapshot);
    expect(recovery).toEqual({
      authorityInstanceId: "authority-1",
      generation: 4,
      revision: 8,
    });
    expect(Object.keys(recovery)).not.toContain("sessionId");
    expect(() =>
      sessionAdmissionFailureSchema.parse({
        code: "session_product_lease_unavailable",
        recovery: { ...recovery, sessionId: "session-1" },
      })
    ).toThrow();
  });

  it("strictly binds session-aware state to the canonical lease", () => {
    const schema = sessionBoundStateEnvelopeSchema(
      z.strictObject({ count: z.number().int().nonnegative() })
    );
    const envelope = {
      session: sessionProductLease(signedInSnapshot),
      snapshot: { count: 1 },
    };

    expect(schema.parse(envelope)).toEqual(envelope);
    expect(() =>
      schema.parse({
        ...envelope,
        session: { ...envelope.session, token: "secret" },
      })
    ).toThrow();
  });

  it("requires operation-specific errors in result schemas", () => {
    const schema = sessionOperationResultSchema(
      z.strictObject({ challengeId: z.string() }),
      "request_email_login"
    );

    expect(
      schema.parse({
        ok: true,
        value: { challengeId: "challenge-1" },
      })
    ).toEqual({
      ok: true,
      value: { challengeId: "challenge-1" },
    });

    expect(() =>
      schema.parse({
        error: {
          code: "conflict",
          operation: "sign_out",
          recovery: "none",
          recoveryRef: sessionRecoveryRef(signedInSnapshot),
          retryable: false,
        },
        ok: false,
      })
    ).toThrow();
  });

  it("makes lifecycle intent carry the caller-captured expectation", () => {
    const absence = {
      authorityInstanceId: "authority-1",
      expectedSessionId: null,
      generation: 4,
    } as const;
    const presence = {
      authorityInstanceId: "authority-1",
      expectedAudience: "https://api.comma.example",
      expectedSessionId: "session-1",
      generation: 4,
    } as const;

    expect(
      sessionRequestEmailLoginInputSchema.parse({
        email: "peng@example.com",
        expected: absence,
      })
    ).toEqual({
      email: "peng@example.com",
      expected: absence,
    });
    expect(
      sessionSignOutInputSchema.parse({
        expected: presence,
      })
    ).toEqual({ expected: presence });
    expect(
      sessionReconcileInputSchema.parse({
        expected: presence,
        reason: "focus",
      })
    ).toEqual({
      expected: presence,
      reason: "focus",
    });
    expect(
      sessionReconcileInputSchema.parse({
        reason: "startup",
      })
    ).toEqual({ reason: "startup" });
    expect(() =>
      sessionRequestEmailLoginInputSchema.parse({
        email: "peng@example.com",
        expected: absence,
        token: "secret",
      })
    ).toThrow();
  });

  it("binds each successful operation to its required lifecycle phase", () => {
    const attempt = {
      attemptId: "attempt-1",
      expected: {
        authorityInstanceId: "authority-1",
        expectedSessionId: null,
        generation: 4,
      },
    } as const;
    const signedOut = {
      ...signedInSnapshot,
      generation: 5,
      phase: "signed_out",
      principal: null,
      reason: "user_signed_out",
      revision: 9,
      session: null,
    } as const;

    expect(
      sessionRequestEmailLoginResultSchema.parse({
        ok: true,
        value: { attempt, challengeId: "challenge-1" },
      })
    ).toMatchObject({ ok: true });
    expect(
      sessionVerifyLoginInputSchema.parse({
        attempt,
        challengeId: "challenge-1",
        code: "123456",
      })
    ).toMatchObject({ attempt });
    expect(
      sessionVerifyEmailLoginResultSchema.parse({
        ok: true,
        value: signedInSnapshot,
      })
    ).toMatchObject({ ok: true });
    expect(
      sessionSignOutResultSchema.parse({
        ok: true,
        value: signedOut,
      })
    ).toMatchObject({ ok: true });
    expect(
      sessionReconcileResultSchema.parse({
        ok: true,
        value: signedOut,
      })
    ).toMatchObject({ ok: true });
    expect(() =>
      sessionVerifyEmailLoginResultSchema.parse({
        ok: true,
        value: signedOut,
      })
    ).toThrow();
    expect(() =>
      sessionSignOutResultSchema.parse({
        ok: true,
        value: signedInSnapshot,
      })
    ).toThrow();
  });
});
