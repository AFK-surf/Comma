import {
  sessionLifecycleSnapshotSchema,
  sessionProductLease,
  sessionProductLeaseSchema,
  type SessionLifecycleSnapshot,
  type SessionProductLease,
} from "./contracts.ts";

export type SessionSnapshotRejection =
  | "authority_rebind_required"
  | "authority_kind_changed"
  | "generation_regressed"
  | "lease_changed_without_generation"
  | "stale_revision";

export type SessionSnapshotMergeResult =
  | {
      accepted: true;
      leaseIssued: boolean;
      leaseRevoked: boolean;
      snapshot: SessionLifecycleSnapshot;
    }
  | {
      accepted: false;
      reason: SessionSnapshotRejection;
      snapshot: SessionLifecycleSnapshot;
    };

export function mergeSessionSnapshot(
  current: SessionLifecycleSnapshot | undefined,
  incomingValue: unknown,
  options: { trustedAuthorityRebind?: boolean } = {}
): SessionSnapshotMergeResult {
  const incoming = sessionLifecycleSnapshotSchema.parse(incomingValue);

  if (!current) {
    return {
      accepted: true,
      leaseIssued: sessionProductLease(incoming) !== undefined,
      leaseRevoked: false,
      snapshot: incoming,
    };
  }

  const currentAuthority = current.authority;
  const incomingAuthority = incoming.authority;
  const authorityChanged =
    currentAuthority.authorityInstanceId !== incomingAuthority.authorityInstanceId;

  if (authorityChanged) {
    if (!options.trustedAuthorityRebind) {
      return {
        accepted: false,
        reason: "authority_rebind_required",
        snapshot: current,
      };
    }

    return acceptedMerge(current, incoming);
  }

  if (currentAuthority.kind !== incomingAuthority.kind) {
    return {
      accepted: false,
      reason: "authority_kind_changed",
      snapshot: current,
    };
  }

  if (incoming.revision <= current.revision) {
    return {
      accepted: false,
      reason: "stale_revision",
      snapshot: current,
    };
  }

  if (incoming.generation < current.generation) {
    return {
      accepted: false,
      reason: "generation_regressed",
      snapshot: current,
    };
  }

  if (
    incoming.generation === current.generation &&
    !sameOptionalSessionProductLease(
      sessionProductLease(current),
      sessionProductLease(incoming)
    )
  ) {
    return {
      accepted: false,
      reason: "lease_changed_without_generation",
      snapshot: current,
    };
  }

  return acceptedMerge(current, incoming);
}

export function sameSessionProductLease(
  leftValue: unknown,
  rightValue: unknown
): boolean {
  const left = sessionProductLeaseSchema.parse(leftValue);
  const right = sessionProductLeaseSchema.parse(rightValue);

  return (
    left.authorityInstanceId === right.authorityInstanceId &&
    left.generation === right.generation &&
    left.sessionId === right.sessionId &&
    left.audience === right.audience
  );
}

export function snapshotMatchesSessionProductLease(
  snapshot: SessionLifecycleSnapshot,
  lease: SessionProductLease
): boolean {
  const currentLease = sessionProductLease(snapshot);
  return currentLease !== undefined && sameSessionProductLease(currentLease, lease);
}

function acceptedMerge(
  current: SessionLifecycleSnapshot,
  incoming: SessionLifecycleSnapshot
): Extract<SessionSnapshotMergeResult, { accepted: true }> {
  const currentLease = sessionProductLease(current);
  const incomingLease = sessionProductLease(incoming);

  return {
    accepted: true,
    leaseIssued:
      incomingLease !== undefined &&
      !sameOptionalSessionProductLease(currentLease, incomingLease),
    leaseRevoked:
      currentLease !== undefined &&
      !sameOptionalSessionProductLease(currentLease, incomingLease),
    snapshot: incoming,
  };
}

function sameOptionalSessionProductLease(
  left: SessionProductLease | undefined,
  right: SessionProductLease | undefined
): boolean {
  if (!left || !right) {
    return left === right;
  }

  return sameSessionProductLease(left, right);
}
