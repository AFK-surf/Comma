import { z } from "zod";

export const sessionContractVersion = 1 as const;

const boundedIdSchema = z.string().min(1).max(256);
const boundedAudienceSchema = z.string().min(1).max(2_048);
const nonnegativeSafeIntegerSchema = z
  .number()
  .int()
  .min(0)
  .max(Number.MAX_SAFE_INTEGER);
const positiveSafeIntegerSchema = z.number().int().min(1).max(Number.MAX_SAFE_INTEGER);

export const sessionAuthorityKindSchema = z.enum([
  "web_cookie",
  "electron_main",
  "swiftui_keychain",
]);

export const sessionAuthoritySchema = z.strictObject({
  authorityInstanceId: boundedIdSchema,
  kind: sessionAuthorityKindSchema,
});

export const sessionCleanupSchema = z.discriminatedUnion("revocation", [
  z.strictObject({
    revocation: z.literal("idle"),
  }),
  z.strictObject({
    pendingCount: positiveSafeIntegerSchema,
    revocation: z.literal("pending"),
  }),
  z.strictObject({
    revocation: z.literal("unknown"),
  }),
]);

export const sessionPrincipalSchema = z.strictObject({
  displayName: z.string().min(1).max(512).optional(),
  email: z.string().min(1).max(320),
  userId: boundedIdSchema,
});

export const sessionDescriptorSchema = z.strictObject({
  audience: boundedAudienceSchema,
  expiresAtEpochSeconds: positiveSafeIntegerSchema,
  sessionId: boundedIdSchema,
});

export const sessionProblemCodeSchema = z.enum([
  "session_probe_unavailable",
  "credential_store_unavailable",
  "credential_store_unreadable",
  "credential_mutation_uncertain",
  "protocol_mismatch",
]);

export const sessionProblemOperationSchema = z.enum([
  "initialize",
  "authenticate",
  "reconcile",
  "sign_out",
  "invalidate",
]);

export const sessionRecoveryActionSchema = z.enum([
  "none",
  "retry_operation",
  "reconcile",
  "new_auth_attempt",
  "after_host_change",
]);

export const sessionProblemPolicy = {
  credential_mutation_uncertain: {
    recovery: "reconcile",
    retryable: false,
  },
  credential_store_unavailable: {
    recovery: "after_host_change",
    retryable: false,
  },
  credential_store_unreadable: {
    recovery: "after_host_change",
    retryable: false,
  },
  protocol_mismatch: {
    recovery: "after_host_change",
    retryable: false,
  },
  session_probe_unavailable: {
    recovery: "retry_operation",
    retryable: true,
  },
} as const satisfies Record<
  z.output<typeof sessionProblemCodeSchema>,
  {
    recovery: z.output<typeof sessionRecoveryActionSchema>;
    retryable: boolean;
  }
>;

export const sessionProblemSchema = z
  .strictObject({
    code: sessionProblemCodeSchema,
    operation: sessionProblemOperationSchema,
    recovery: sessionRecoveryActionSchema,
    retryable: z.boolean(),
  })
  .superRefine((problem, context) => {
    const policy = sessionProblemPolicy[problem.code];
    if (problem.recovery !== policy.recovery) {
      context.addIssue({
        code: "custom",
        message: `${problem.code} must recover through ${policy.recovery}.`,
        path: ["recovery"],
      });
    }
    if (problem.retryable !== policy.retryable) {
      context.addIssue({
        code: "custom",
        message: `${problem.code} retryable must be ${policy.retryable}.`,
        path: ["retryable"],
      });
    }
  });

const snapshotHeaderShape = {
  authority: sessionAuthoritySchema,
  cleanup: sessionCleanupSchema,
  contractVersion: z.literal(sessionContractVersion),
  generation: nonnegativeSafeIntegerSchema,
  revision: nonnegativeSafeIntegerSchema,
};

const transientSessionSnapshotSchema = z.strictObject({
  ...snapshotHeaderShape,
  phase: z.enum(["initializing", "authenticating", "signing_out", "invalidating"]),
  principal: z.null(),
  session: z.null(),
});

export const signedOutSessionSnapshotSchema = z.strictObject({
  ...snapshotHeaderShape,
  phase: z.literal("signed_out"),
  principal: z.null(),
  reason: z.enum(["no_session", "user_signed_out", "unauthorized", "expired"]),
  session: z.null(),
});

export const signedInSessionSnapshotSchema = z.strictObject({
  ...snapshotHeaderShape,
  phase: z.literal("signed_in"),
  principal: sessionPrincipalSchema,
  session: sessionDescriptorSchema,
});

export const indeterminateSessionSnapshotSchema = z.strictObject({
  ...snapshotHeaderShape,
  phase: z.literal("indeterminate"),
  principal: z.null(),
  problem: sessionProblemSchema,
  session: z.null(),
});

export const sessionLifecycleSnapshotSchema = z
  .discriminatedUnion("phase", [
    transientSessionSnapshotSchema,
    signedOutSessionSnapshotSchema,
    signedInSessionSnapshotSchema,
    indeterminateSessionSnapshotSchema,
  ])
  .meta({ id: "CommaSessionLifecycleSnapshot" });

export const sessionVersionExpectationSchema = z.strictObject({
  authorityInstanceId: boundedIdSchema,
  generation: nonnegativeSafeIntegerSchema,
});

export const sessionAbsenceExpectationSchema = sessionVersionExpectationSchema.extend({
  expectedSessionId: z.null(),
});

export const sessionPresenceExpectationSchema = sessionVersionExpectationSchema.extend({
  expectedAudience: boundedAudienceSchema,
  expectedSessionId: boundedIdSchema,
});

export const sessionPresenceExpectationHeader =
  "x-comma-main-session-expectation" as const;

export const sessionLifecycleExpectationSchema = z.union([
  sessionAbsenceExpectationSchema,
  sessionPresenceExpectationSchema,
]);

export const sessionProductLeaseSchema = z.strictObject({
  audience: boundedAudienceSchema,
  authorityInstanceId: boundedIdSchema,
  generation: nonnegativeSafeIntegerSchema,
  sessionId: boundedIdSchema,
});

export const sessionAuthAttemptRefSchema = z.strictObject({
  attemptId: boundedIdSchema,
  expected: sessionAbsenceExpectationSchema,
});

export const sessionReconcileReasonSchema = z.enum([
  "startup",
  "focus",
  "peer_mutation",
  "manual_retry",
]);

export const sessionReconcileInputSchema = z.strictObject({
  expected: sessionLifecycleExpectationSchema.optional(),
  reason: sessionReconcileReasonSchema,
});

export const sessionSignOutInputSchema = z.strictObject({
  expected: sessionLifecycleExpectationSchema,
});

export const sessionRequestEmailLoginInputSchema = z.strictObject({
  email: z.string().min(1).max(320),
  expected: sessionAbsenceExpectationSchema,
});

export const sessionVerifyLoginInputSchema = z.strictObject({
  attempt: sessionAuthAttemptRefSchema,
  challengeId: boundedIdSchema,
  code: z.string().min(1).max(32),
});

export const sessionGoogleSignInInputSchema = z.strictObject({
  expected: sessionAbsenceExpectationSchema,
});

export const sessionCancelAuthAttemptInputSchema = z.strictObject({
  attempt: sessionAuthAttemptRefSchema,
});

export const sessionRecoveryRefSchema = z.strictObject({
  authorityInstanceId: boundedIdSchema,
  generation: nonnegativeSafeIntegerSchema,
  revision: nonnegativeSafeIntegerSchema,
});

export const sessionAdmissionFailureSchema = z.strictObject({
  code: z.literal("session_product_lease_unavailable"),
  recovery: sessionRecoveryRefSchema,
});

export function sessionBoundStateEnvelopeSchema<SnapshotSchema extends z.ZodType>(
  snapshot: SnapshotSchema
) {
  return z.strictObject({
    session: sessionProductLeaseSchema,
    snapshot,
  });
}

export const sessionOperationNameSchema = z.enum([
  "request_email_login",
  "verify_email_login",
  "sign_in_with_google",
  "verify_google_link",
  "cancel_auth_attempt",
  "reconcile",
  "sign_out",
]);

export const sessionOperationErrorCodeSchema = z.enum([
  "session_probe_unavailable",
  "credential_store_unavailable",
  "credential_store_unreadable",
  "credential_mutation_uncertain",
  "protocol_mismatch",
  "cancelled",
  "invalid_challenge",
  "challenge_expired",
  "account_disabled",
  "conflict",
  "rate_limited",
  "network_unavailable",
  "provider_unavailable",
  "unsupported",
  "unknown",
]);

type OperationErrorRule = {
  recovery: z.output<typeof sessionRecoveryActionSchema>;
  retryable: boolean;
  retryAfterAllowed?: true;
};

const noRetry = {
  recovery: "none",
  retryable: false,
} as const satisfies OperationErrorRule;
const retryOperation = {
  recovery: "retry_operation",
  retryable: true,
  retryAfterAllowed: true,
} as const satisfies OperationErrorRule;
const reconcileBeforeContinuing = {
  recovery: "reconcile",
  retryable: false,
} as const satisfies OperationErrorRule;
const startNewAuthAttempt = {
  recovery: "new_auth_attempt",
  retryable: false,
} as const satisfies OperationErrorRule;
const waitForHostChange = {
  recovery: "after_host_change",
  retryable: false,
} as const satisfies OperationErrorRule;

export const sessionOperationErrorPolicy = {
  cancel_auth_attempt: {
    cancelled: noRetry,
    conflict: noRetry,
    credential_mutation_uncertain: reconcileBeforeContinuing,
    protocol_mismatch: waitForHostChange,
    unsupported: noRetry,
    unknown: noRetry,
  },
  reconcile: {
    cancelled: noRetry,
    conflict: noRetry,
    credential_mutation_uncertain: reconcileBeforeContinuing,
    credential_store_unavailable: waitForHostChange,
    credential_store_unreadable: waitForHostChange,
    network_unavailable: retryOperation,
    protocol_mismatch: waitForHostChange,
    session_probe_unavailable: retryOperation,
    unsupported: noRetry,
    unknown: noRetry,
  },
  request_email_login: {
    cancelled: noRetry,
    conflict: noRetry,
    credential_store_unavailable: waitForHostChange,
    network_unavailable: retryOperation,
    protocol_mismatch: waitForHostChange,
    provider_unavailable: retryOperation,
    rate_limited: retryOperation,
    unsupported: noRetry,
    unknown: noRetry,
  },
  sign_in_with_google: {
    account_disabled: noRetry,
    cancelled: noRetry,
    conflict: noRetry,
    credential_mutation_uncertain: reconcileBeforeContinuing,
    credential_store_unavailable: waitForHostChange,
    network_unavailable: retryOperation,
    protocol_mismatch: waitForHostChange,
    provider_unavailable: retryOperation,
    rate_limited: retryOperation,
    unsupported: noRetry,
    unknown: noRetry,
  },
  sign_out: {
    cancelled: noRetry,
    conflict: noRetry,
    credential_mutation_uncertain: reconcileBeforeContinuing,
    credential_store_unavailable: waitForHostChange,
    credential_store_unreadable: waitForHostChange,
    network_unavailable: retryOperation,
    protocol_mismatch: waitForHostChange,
    unsupported: noRetry,
    unknown: noRetry,
  },
  verify_email_login: {
    account_disabled: noRetry,
    cancelled: noRetry,
    challenge_expired: startNewAuthAttempt,
    conflict: noRetry,
    credential_mutation_uncertain: reconcileBeforeContinuing,
    credential_store_unavailable: waitForHostChange,
    invalid_challenge: retryOperation,
    network_unavailable: retryOperation,
    protocol_mismatch: waitForHostChange,
    provider_unavailable: retryOperation,
    rate_limited: retryOperation,
    unsupported: noRetry,
    unknown: noRetry,
  },
  verify_google_link: {
    account_disabled: noRetry,
    cancelled: noRetry,
    challenge_expired: startNewAuthAttempt,
    conflict: noRetry,
    credential_mutation_uncertain: reconcileBeforeContinuing,
    credential_store_unavailable: waitForHostChange,
    invalid_challenge: retryOperation,
    network_unavailable: retryOperation,
    protocol_mismatch: waitForHostChange,
    provider_unavailable: retryOperation,
    rate_limited: retryOperation,
    unsupported: noRetry,
    unknown: noRetry,
  },
} as const satisfies Record<
  z.output<typeof sessionOperationNameSchema>,
  Partial<Record<z.output<typeof sessionOperationErrorCodeSchema>, OperationErrorRule>>
>;

export const sessionOperationErrorSchema = z
  .strictObject({
    code: sessionOperationErrorCodeSchema,
    operation: sessionOperationNameSchema,
    recovery: sessionRecoveryActionSchema,
    recoveryRef: sessionRecoveryRefSchema,
    retryable: z.boolean(),
    retryAfterMs: positiveSafeIntegerSchema.optional(),
  })
  .superRefine((error, context) => {
    const operationPolicy = sessionOperationErrorPolicy[error.operation];
    const policy = (
      operationPolicy as Partial<
        Record<z.output<typeof sessionOperationErrorCodeSchema>, OperationErrorRule>
      >
    )[error.code];

    if (!policy) {
      context.addIssue({
        code: "custom",
        message: `${error.code} is not legal for ${error.operation}.`,
        path: ["code"],
      });
      return;
    }

    if (error.recovery !== policy.recovery) {
      context.addIssue({
        code: "custom",
        message: `${error.code} must recover through ${policy.recovery}.`,
        path: ["recovery"],
      });
    }

    if (error.retryable !== policy.retryable) {
      context.addIssue({
        code: "custom",
        message: `${error.code} retryable must be ${policy.retryable}.`,
        path: ["retryable"],
      });
    }

    if (error.retryAfterMs !== undefined && !policy.retryAfterAllowed) {
      context.addIssue({
        code: "custom",
        message: `${error.code} cannot carry retryAfterMs.`,
        path: ["retryAfterMs"],
      });
    }
  });

export function sessionOperationErrorSchemaFor<Operation extends SessionOperationName>(
  operation: Operation
): z.ZodType<SessionOperationError<Operation>> {
  return sessionOperationErrorSchema.refine(
    (error): error is SessionOperationError<Operation> => error.operation === operation,
    {
      message: `Expected ${operation} operation error.`,
      path: ["operation"],
    }
  );
}

export function sessionOperationResultSchema<
  ValueSchema extends z.ZodType,
  Operation extends SessionOperationName,
>(value: ValueSchema, operation: Operation) {
  return z.discriminatedUnion("ok", [
    z.strictObject({
      ok: z.literal(true),
      value,
    }),
    z.strictObject({
      error: sessionOperationErrorSchemaFor(operation),
      ok: z.literal(false),
    }),
  ]);
}

export const sessionRequestEmailLoginValueSchema = z.strictObject({
  attempt: sessionAuthAttemptRefSchema,
  challengeId: boundedIdSchema,
});

export const sessionGoogleSignInValueSchema = z.discriminatedUnion("status", [
  z.strictObject({
    snapshot: signedInSessionSnapshotSchema,
    status: z.literal("signed_in"),
  }),
  z.strictObject({
    attempt: sessionAuthAttemptRefSchema,
    challengeId: boundedIdSchema,
    email: z.string().min(1).max(320),
    status: z.literal("otp_required"),
  }),
]);

export const sessionReconcileResultSchema = sessionOperationResultSchema(
  z.union([signedInSessionSnapshotSchema, signedOutSessionSnapshotSchema]),
  "reconcile"
);
export const sessionSignOutResultSchema = sessionOperationResultSchema(
  signedOutSessionSnapshotSchema,
  "sign_out"
);
export const sessionRequestEmailLoginResultSchema = sessionOperationResultSchema(
  sessionRequestEmailLoginValueSchema,
  "request_email_login"
);
export const sessionVerifyEmailLoginResultSchema = sessionOperationResultSchema(
  signedInSessionSnapshotSchema,
  "verify_email_login"
);
export const sessionGoogleSignInResultSchema = sessionOperationResultSchema(
  sessionGoogleSignInValueSchema,
  "sign_in_with_google"
);
export const sessionVerifyGoogleLinkResultSchema = sessionOperationResultSchema(
  signedInSessionSnapshotSchema,
  "verify_google_link"
);
export const sessionCancelAuthAttemptResultSchema = sessionOperationResultSchema(
  signedOutSessionSnapshotSchema,
  "cancel_auth_attempt"
);

export type SessionAuthorityKind = z.output<typeof sessionAuthorityKindSchema>;
export type SessionAuthority = z.output<typeof sessionAuthoritySchema>;
export type SessionCleanup = z.output<typeof sessionCleanupSchema>;
export type SessionPrincipal = z.output<typeof sessionPrincipalSchema>;
export type SessionDescriptor = z.output<typeof sessionDescriptorSchema>;
export type SessionProblemCode = z.output<typeof sessionProblemCodeSchema>;
export type SessionProblemOperation = z.output<typeof sessionProblemOperationSchema>;
export type SessionProblem = z.output<typeof sessionProblemSchema>;
export type SessionLifecycleSnapshot = z.output<typeof sessionLifecycleSnapshotSchema>;
export type SignedInSessionSnapshot = z.output<typeof signedInSessionSnapshotSchema>;
export type SignedOutSessionSnapshot = z.output<typeof signedOutSessionSnapshotSchema>;
export type TerminalSessionSnapshot =
  | SignedInSessionSnapshot
  | SignedOutSessionSnapshot;
export type SessionVersionExpectation = z.output<
  typeof sessionVersionExpectationSchema
>;
export type SessionAbsenceExpectation = z.output<
  typeof sessionAbsenceExpectationSchema
>;
export type SessionPresenceExpectation = z.output<
  typeof sessionPresenceExpectationSchema
>;
export type SessionLifecycleExpectation = z.output<
  typeof sessionLifecycleExpectationSchema
>;
export type SessionProductLease = z.output<typeof sessionProductLeaseSchema>;
export type SessionAuthAttemptRef = z.output<typeof sessionAuthAttemptRefSchema>;
export type SessionReconcileReason = z.output<typeof sessionReconcileReasonSchema>;
export type SessionReconcileInput = z.output<typeof sessionReconcileInputSchema>;
export type SessionSignOutInput = z.output<typeof sessionSignOutInputSchema>;
export type SessionRequestEmailLoginInput = z.output<
  typeof sessionRequestEmailLoginInputSchema
>;
export type SessionVerifyLoginInput = z.output<typeof sessionVerifyLoginInputSchema>;
export type SessionGoogleSignInInput = z.output<typeof sessionGoogleSignInInputSchema>;
export type SessionCancelAuthAttemptInput = z.output<
  typeof sessionCancelAuthAttemptInputSchema
>;
export type SessionRecoveryRef = z.output<typeof sessionRecoveryRefSchema>;
export type SessionAdmissionFailure = z.output<typeof sessionAdmissionFailureSchema>;
export type SessionBoundStateEnvelope<Snapshot> = {
  session: SessionProductLease;
  snapshot: Snapshot;
};
export type SessionOperationName = z.output<typeof sessionOperationNameSchema>;
export type SessionOperationErrorCode = z.output<
  typeof sessionOperationErrorCodeSchema
>;
export type SessionOperationErrorCodeFor<Operation extends SessionOperationName> =
  keyof (typeof sessionOperationErrorPolicy)[Operation] & SessionOperationErrorCode;
export type SessionRecoveryAction = z.output<typeof sessionRecoveryActionSchema>;
export type SessionOperationError<Operation extends SessionOperationName> = {
  code: SessionOperationErrorCodeFor<Operation>;
  operation: Operation;
  recovery: SessionRecoveryAction;
  recoveryRef: SessionRecoveryRef;
  retryable: boolean;
  retryAfterMs?: number | undefined;
};
export type SessionOperationResult<Value, Operation extends SessionOperationName> =
  | { ok: true; value: Value }
  | { error: SessionOperationError<Operation>; ok: false };

export function createSessionProblem(
  code: SessionProblemCode,
  operation: SessionProblemOperation
): SessionProblem {
  return sessionProblemSchema.parse({
    code,
    operation,
    ...sessionProblemPolicy[code],
  });
}

export function sessionOperationErrorRule(
  operation: SessionOperationName,
  code: SessionOperationErrorCode
): OperationErrorRule | undefined {
  return (
    sessionOperationErrorPolicy[operation] as Partial<
      Record<SessionOperationErrorCode, OperationErrorRule>
    >
  )[code];
}

export function createSessionOperationError<
  Operation extends SessionOperationName,
  Code extends SessionOperationErrorCodeFor<Operation>,
>(
  operation: Operation,
  code: Code,
  snapshot: SessionLifecycleSnapshot,
  retryAfterMs?: number
): SessionOperationError<Operation> {
  const rule = sessionOperationErrorRule(operation, code);
  if (!rule) {
    throw new Error(`${code} is not legal for ${operation}.`);
  }

  return sessionOperationErrorSchemaFor(operation).parse({
    code,
    operation,
    recovery: rule.recovery,
    recoveryRef: sessionRecoveryRef(snapshot),
    retryable: rule.retryable,
    ...(retryAfterMs !== undefined && rule.retryAfterAllowed ? { retryAfterMs } : {}),
  });
}

export function createSessionOperationErrorOrUnknown<
  Operation extends SessionOperationName,
>(
  operation: Operation,
  code: SessionOperationErrorCode,
  snapshot: SessionLifecycleSnapshot,
  retryAfterMs?: number
): SessionOperationError<Operation> {
  const resolvedCode = sessionOperationErrorRule(operation, code) ? code : "unknown";
  const rule = sessionOperationErrorRule(operation, resolvedCode);
  if (!rule) {
    throw new Error(`Session operation ${operation} does not allow unknown errors.`);
  }

  return sessionOperationErrorSchemaFor(operation).parse({
    code: resolvedCode,
    operation,
    recovery: rule.recovery,
    recoveryRef: sessionRecoveryRef(snapshot),
    retryable: rule.retryable,
    ...(retryAfterMs !== undefined && rule.retryAfterAllowed ? { retryAfterMs } : {}),
  });
}

export function sessionRecoveryRef(
  snapshot: SessionLifecycleSnapshot
): SessionRecoveryRef {
  return {
    authorityInstanceId: snapshot.authority.authorityInstanceId,
    generation: snapshot.generation,
    revision: snapshot.revision,
  };
}

export function sessionExpectation(
  snapshot: SignedOutSessionSnapshot
): SessionAbsenceExpectation;
export function sessionExpectation(
  snapshot: SignedInSessionSnapshot
): SessionPresenceExpectation;
export function sessionExpectation(
  snapshot: TerminalSessionSnapshot
): SessionLifecycleExpectation;
export function sessionExpectation(
  snapshot: TerminalSessionSnapshot
): SessionLifecycleExpectation {
  if (snapshot.phase === "signed_out") {
    return {
      authorityInstanceId: snapshot.authority.authorityInstanceId,
      expectedSessionId: null,
      generation: snapshot.generation,
    };
  }

  return {
    authorityInstanceId: snapshot.authority.authorityInstanceId,
    expectedAudience: snapshot.session.audience,
    expectedSessionId: snapshot.session.sessionId,
    generation: snapshot.generation,
  };
}

export function encodeSessionPresenceExpectation(
  expectationValue: SessionPresenceExpectation
): string {
  return JSON.stringify(sessionPresenceExpectationSchema.parse(expectationValue));
}

export function sessionProductLease(
  snapshot: SessionLifecycleSnapshot
): SessionProductLease | undefined {
  if (snapshot.phase !== "signed_in") {
    return undefined;
  }

  return {
    audience: snapshot.session.audience,
    authorityInstanceId: snapshot.authority.authorityInstanceId,
    generation: snapshot.generation,
    sessionId: snapshot.session.sessionId,
  };
}
