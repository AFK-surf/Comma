import {
  getNativeBridge,
  type ComputeNodeConfigureInput,
  type ComputeNodeExpectedBinding,
  type ComputeNodeState,
} from "@comma/native-bridge";
import { useCallback, useEffect, useState } from "react";

export function useComputeNode() {
  const bridge = getNativeBridge();
  const available = bridge.platform === "electron";
  const [state, setState] = useState<ComputeNodeState | null>(null);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();

  const accept = useCallback((next: ComputeNodeState) => {
    setState((current) =>
      current && current.revision > next.revision ? current : next
    );
  }, []);

  useEffect(() => {
    if (!available) return;
    return bridge.computeNode.state.subscribe(accept);
  }, [accept, available, bridge]);

  const run = useCallback(
    async (operation: () => Promise<ComputeNodeState>) => {
      setPending(true);
      setError(undefined);
      try {
        accept(await operation());
      } catch (reason) {
        setError(reason instanceof Error ? reason.message : String(reason));
        try {
          accept(await bridge.computeNode.state.get());
        } catch {
          /* retain last fact */
        }
      } finally {
        setPending(false);
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
    repair: () => run(() => bridge.computeNode.repair()),
    rebuild: () => run(() => bridge.computeNode.rebuild()),
  };
}
