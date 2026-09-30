import { useEffect, useRef, useState } from "react";
import { CommaApiError, type CommaApiClient } from "../../api";
import { readActiveWorkspaceId } from "../activeWorkspace";

export type ProactiveSetting =
  | { kind: "loading" }
  // Automatic messages belong to the workspace owner's Home conversation.
  | { kind: "owner-only" }
  | { kind: "ready"; groupId: string; enabled: boolean };

// The owner's automatic proactive messages, read when Routines settings open.
// A failed save keeps the saved value on screen and reports the failure.
export function useProactiveSetting(api: CommaApiClient, active: boolean) {
  const [setting, setSetting] = useState<ProactiveSetting>({ kind: "loading" });
  const [pending, setPending] = useState(false);
  const [failure, setFailure] = useState<"load" | "save">();
  const revision = useRef(0);

  useEffect(() => {
    if (!active) return;
    const current = ++revision.current;
    const controller = new AbortController();
    setSetting({ kind: "loading" });
    setFailure(undefined);
    void (async () => {
      const workspaces = await api.listWorkspaces({ signal: controller.signal });
      const workspace =
        workspaces.find((candidate) => candidate.id === readActiveWorkspaceId()) ??
        workspaces[0];
      if (!workspace) throw new Error("workspace unavailable");
      const saved = await api.getProactiveSettings(workspace.group_id, {
        signal: controller.signal,
      });
      if (current === revision.current)
        setSetting({
          kind: "ready",
          groupId: workspace.group_id,
          enabled: saved.enabled,
        });
    })().catch((error: unknown) => {
      if (current !== revision.current || controller.signal.aborted) return;
      if (error instanceof CommaApiError && error.status === 403)
        setSetting({ kind: "owner-only" });
      else setFailure("load");
    });
    return () => {
      revision.current = current + 1;
      controller.abort();
    };
  }, [active, api]);

  const toggle = async (enabled: boolean) => {
    if (setting.kind !== "ready" || pending) return;
    const current = revision.current;
    setPending(true);
    setFailure(undefined);
    try {
      const saved = await api.updateProactiveSettings(setting.groupId, {
        enabled,
        requestId: crypto.randomUUID(),
      });
      if (current === revision.current)
        setSetting({ ...setting, enabled: saved.enabled });
    } catch {
      if (current === revision.current) setFailure("save");
    } finally {
      if (current === revision.current) setPending(false);
    }
  };

  return { setting, pending, failure, toggle };
}
