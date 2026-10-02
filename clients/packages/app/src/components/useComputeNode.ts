import {
  getNativeBridge,
  type ComputeNodeConfigureInput,
  type ComputeNodeExpectedBinding,
  type ComputeNodeState,
} from "@comma/native-bridge";
import { useCallback, useEffect, useRef, useState } from "react";

export function useComputeNode() {
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
        setError(reason instanceof Error ? reason.message : String(reason));
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
    [accept, bridge]
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
