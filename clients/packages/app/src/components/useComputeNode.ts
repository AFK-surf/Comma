import {
  getNativeBridge,
  type ComputeNodeConfigureInput,
  type ComputeNodeExpectedBinding,
  type ComputeNodeProblem,
  type ComputeNodeState,
} from "@comma/native-bridge";
import { useCommaMessages } from "@comma/i18n/react";
import { useCallback, useEffect, useRef, useState } from "react";

export function computeOperationMessage(
  reason: unknown,
  m: ReturnType<typeof useCommaMessages>
): string {
  const code =
    reason && typeof reason === "object" && "bridgeError" in reason
      ? (reason.bridgeError as { code?: string })?.code
      : undefined;
  if (code === "COMPUTE_RECOVERY_UNVERIFIED") return m.compute_recovery_unverified();
  if (code === "COMPUTE_SETUP_FAILED") return m.compute_setup_failed();
  if (code === "COMPUTE_CONNECTION_FAILED") return m.compute_connection_failed();
  if (code === "COMPUTE_CLOUD_UNAVAILABLE") return m.compute_cloud_unavailable();
  if (code === "COMPUTE_SETUP_UNKNOWN") return m.compute_setup_unknown();
  return reason instanceof Error ? reason.message : String(reason);
}

/** The localized text for each problem code that Main publishes. */
export function computeProblemMessage(
  problem: ComputeNodeProblem,
  m: ReturnType<typeof useCommaMessages>
): string {
  switch (problem) {
    case "setup_unknown":
      return m.compute_setup_unknown();
    case "setup_failed":
      return m.compute_setup_failed();
    case "setup_handoff_expired":
      return m.compute_problem_setup_handoff_expired();
    case "setup_blocked":
      return m.compute_problem_setup_blocked();
    case "components_failed":
      return m.compute_problem_components_failed();
    case "connection_failed":
      return m.compute_connection_failed();
    case "connection_retry_limit":
      return m.compute_problem_connection_retry_limit();
    case "authorization_attention":
      return m.compute_authorization_problem();
    case "rebuild_failed":
      return m.compute_problem_rebuild_failed();
    case "repair_failed":
      return m.compute_problem_repair_failed();
    case "stop_failed":
      return m.compute_problem_stop_failed();
    case "removal_failed":
      return m.compute_problem_removal_failed();
    case "removal_unconfirmed":
      return m.compute_problem_removal_unconfirmed();
    case "remote_revocation_unconfirmed":
      return m.compute_local_removed();
    case "intent_unreadable":
      return m.compute_problem_intent_unreadable();
    case "operation_unknown":
      return m.compute_operation_unknown();
    case "operation_failed":
      return m.compute_problem_operation_failed();
  }
}

export function useComputeNode() {
  const m = useCommaMessages();
  const bridge = getNativeBridge();
  const available = bridge.platform === "electron";
  const [state, setState] = useState<ComputeNodeState | null>(null);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const authority = useRef<string | undefined>(undefined);

  const accept = useCallback((next: ComputeNodeState) => {
    setState((current) =>
      current &&
      current.confirmationId === next.confirmationId &&
      current.revision > next.revision
        ? current
        : next
    );
  }, []);

  useEffect(() => {
    if (!available) return;
    return bridge.computeNode.state.subscribe((next) => {
      if (authority.current !== next.confirmationId) {
        setPending(false);
        setError(undefined);
      }
      authority.current = next.confirmationId;
      accept(next);
    });
  }, [accept, available, bridge]);

  const run = useCallback(
    async (operation: () => Promise<ComputeNodeState>) => {
      const generation = authority.current;
      setPending(true);
      setError(undefined);
      try {
        const next = await operation();
        if (authority.current === generation) {
          accept(next);
          return next;
        }
      } catch (reason) {
        if (authority.current !== generation) return;
        setError(computeOperationMessage(reason, m));
        try {
          const next = await bridge.computeNode.state.get();
          if (authority.current === generation) accept(next);
        } catch {
          /* retain last fact */
        }
      } finally {
        if (authority.current === generation) setPending(false);
      }
    },
    [accept, bridge, m]
  );

  return {
    available,
    error,
    pending,
    state,
    refresh: () => run(() => bridge.computeNode.refresh()),
    configure: (input: ComputeNodeConfigureInput) =>
      run(() => bridge.computeNode.configure(input)),
    drain: (expected: ComputeNodeExpectedBinding) =>
      run(() => bridge.computeNode.drain(expected)),
    remove: (expected: ComputeNodeExpectedBinding) =>
      run(() => bridge.computeNode.remove(expected)),
    abandon: (expected: ComputeNodeExpectedBinding) =>
      run(() => bridge.computeNode.abandon(expected)),
    repair: () => run(() => bridge.computeNode.repair()),
    rebuild: () => run(() => bridge.computeNode.rebuild()),
  };
}
