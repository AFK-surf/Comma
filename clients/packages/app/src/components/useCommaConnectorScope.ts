import {
  getNativeBridge,
  type ConnectorRuntimeScopeSnapshot,
  type ConnectorScope,
  type ConnectorScopeState,
} from "@comma/native-bridge";
import { useCallback, useEffect, useRef, useState } from "react";
import { useActiveWorkspace } from "./activeWorkspace";

export function CommaConnectorRuntimeOwner() {
  useCommaConnectorScope(true);
  return null;
}

/**
 * Subscribes to Main's bounded replay-last Connector scope projection. The
 * authenticated owner keeps the selected workspace's Connector alive. Main
 * publishes child startup, acknowledgement, exit and replacement transitions;
 * the renderer never schedules periodic reads or invents a desired scope.
 * Before asking Main to start a child, one bounded Workspace-list read
 * validates the persisted selection. A deleted/stale localStorage id must
 * never become an immortal Connector retry target.
 */
export function useCommaConnectorScope(enabled: boolean) {
  const bridge = getNativeBridge();
  const nativeAvailable = bridge.platform === "electron";
  const [state, setState] = useState<ConnectorScopeState | null>(null);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const mutationRef = useRef(0);
  const revisionRef = useRef(-1);
  const subscriptionRef = useRef(0);

  // A direct Settings entry deliberately does not bootstrap or select a
  // Workspace: the Connector runs only for one the user selected. The core
  // answers the account's workspace for it (the first one when it is gone).
  const resolved = useActiveWorkspace(enabled && nativeAvailable);
  const selected = resolved?.selected === true;
  const workspaceId = selected ? resolved?.workspace?.id : undefined;
  const failed = selected && resolved?.status === "error";
  const missing = selected && resolved?.status === "ready" && !resolved.workspace;

  useEffect(() => {
    const subscription = ++subscriptionRef.current;
    mutationRef.current += 1;
    revisionRef.current = -1;
    setPending(false);
    setState(null);
    setError(undefined);
    if (!enabled || !nativeAvailable || !workspaceId) return undefined;

    let cancelled = false;
    const accept = (snapshot: ConnectorRuntimeScopeSnapshot) => {
      if (cancelled || subscriptionRef.current !== subscription) return;
      // The generated state bridge suppresses an overtaken initial replay;
      // this high-water mark also rejects any delayed older live snapshot.
      if (snapshot.revision < revisionRef.current) return;
      revisionRef.current = snapshot.revision;
      const next =
        snapshot.scopes.find((candidate) => candidate.workspaceId === workspaceId) ??
        null;
      setState(next);
      setError(undefined);
    };
    const unsubscribe = bridge.connectorRuntime.state.subscribe(accept);

    // One bounded request ensures the exact active workspace child exists.
    // Its owner publishes the resulting acknowledgement through state above.
    void bridge.connectorRuntime.scope({ workspaceId }).catch((reason: unknown) => {
      if (!cancelled && subscriptionRef.current === subscription) {
        setError(reason instanceof Error ? reason.message : String(reason));
      }
    });

    return () => {
      cancelled = true;
      subscriptionRef.current = Math.max(subscriptionRef.current, subscription + 1);
      mutationRef.current += 1;
      unsubscribe();
    };
  }, [bridge, enabled, nativeAvailable, workspaceId]);

  // After the effect above, which starts each Workspace with no error.
  useEffect(() => {
    if (failed) setError("The account's Workspaces could not be read.");
    else if (missing)
      setError("No active Workspace is available for Connector permissions.");
  }, [failed, missing]);

  const setScope = useCallback(
    async (scope: ConnectorScope) => {
      if (!enabled || !nativeAvailable || !workspaceId) return;
      const operation = ++mutationRef.current;
      setPending(true);
      setError(undefined);
      try {
        // The command acknowledgement is not renderer state. The runtime owner
        // publishes the accepted scope through connectorRuntime.state.
        const result = await bridge.connectorRuntime.setScope({ scope, workspaceId });
        if (!result.available || result.scope !== scope)
          throw new Error("Connector permission change was not acknowledged.");
      } catch (reason) {
        if (mutationRef.current === operation) {
          setError(reason instanceof Error ? reason.message : String(reason));
        }
      } finally {
        if (mutationRef.current === operation) setPending(false);
      }
    },
    [bridge, enabled, nativeAvailable, workspaceId]
  );

  return {
    available: nativeAvailable && state?.available === true,
    error,
    pending,
    scope: state?.scope,
    deviceId: state?.deviceId,
    setScope,
    workspaceId,
  };
}
