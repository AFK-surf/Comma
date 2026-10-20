import { useCall, useTopic, type ProactiveValue } from "@comma/core-client";
import { useState } from "react";
import { useWorkspacePreference } from "../activeWorkspace";

export type ProactiveSetting = ProactiveValue;

// The owner's automatic proactive messages, read by the core when Routines settings open.
// A failed save keeps the saved value on screen and reports the failure.
export function useProactiveSetting(active: boolean) {
  const call = useCall();
  const prefer = useWorkspacePreference();
  const { value } = useTopic(
    active && prefer !== undefined ? { topic: "proactive", prefer } : null
  );
  const setting: ProactiveSetting = value ?? { kind: "loading" };
  const [pending, setPending] = useState(false);
  const [saveFailed, setSaveFailed] = useState(false);
  const failure: "load" | "save" | undefined =
    setting.kind === "failed" ? "load" : saveFailed ? "save" : undefined;

  const toggle = async (enabled: boolean) => {
    if (setting.kind !== "ready" || pending) return;
    setPending(true);
    setSaveFailed(false);
    try {
      await call("proactive.set", { prefer: prefer ?? "", enabled });
    } catch {
      setSaveFailed(true);
    } finally {
      setPending(false);
    }
  };

  return { setting, pending, failure, toggle };
}
