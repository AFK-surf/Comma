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
  if (code === "COMPUTE_REQUEST_HANDED_OFF") return m.compute_request_handed_off();
  // Any other failure, such as a generic native command failure, gets one bounded localized sentence.
  // Main keeps the raw message in its diagnostics log.
  return m.compute_action_failed();
}

/** The localized text for each problem code that Main publishes. */
export function computeProblemMessage(
  problem: ComputeNodeProblem,
  m: ReturnType<typeof useCommaMessages>,
  state?: Pick<ComputeNodeState, "diskRequirement"> | null
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
    case "request_blocked":
      return m.compute_request_blocked();
    case "operation_unknown":
      return m.compute_operation_unknown();
    case "operation_failed":
      return m.compute_problem_operation_failed();
    case "continuation_paused":
      return m.compute_continuation_paused();
    case "registration_revoked":
      return m.compute_problem_registration_invalid();
    case "registration_invalid":
      return m.compute_problem_registration_invalid();
    case "clock_skew":
      return m.compute_problem_clock_skew();
    case "identity_mismatch":
      return m.compute_problem_identity_mismatch();
    case "insufficient_disk":
      return m.compute_problem_insufficient_disk({
        gb: String(
          Math.ceil((state?.diskRequirement?.requiredBytes ?? 0) / 1024 ** 3) || "?"
        ),
      });
    case "host_update_interrupts_work":
      return m.compute_problem_host_update_interrupts_work();
    case "target_older_than_data":
      return m.compute_problem_target_older_than_data();
    case "comma_update_required":
      return m.compute_problem_comma_update_required();
    case "service_update_required":
      return m.compute_problem_service_update_required();
    case "local_data_migration":
      return m.compute_problem_local_data_migration();
    case "host_uninstalled":
      return m.compute_problem_host_uninstalled();
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
    continue: () => run(() => bridge.computeNode.continue()),
    reauthorize: (expected: ComputeNodeExpectedBinding) =>
      run(() => bridge.computeNode.reauthorize(expected)),
    refresh: () => run(() => bridge.computeNode.refresh()),
    configure: (input: ComputeNodeConfigureInput) =>
      run(() => bridge.computeNode.configure(input)),
    drain: (expected: ComputeNodeExpectedBinding) =>
      run(() => bridge.computeNode.drain(expected)),
    remove: (expected: ComputeNodeExpectedBinding) =>
      run(() => bridge.computeNode.remove(expected)),
  };
}
