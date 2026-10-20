import { useCall, useTopic } from "@comma/core-client";
import type { ReplyStyle } from "@comma/core/contract";
import { useCallback, useState } from "react";
import { useActiveWorkspaceId } from "../activeWorkspace";

export function isReplyStyle(value: string): value is ReplyStyle {
  return value === "default" || value === "concise";
}

/**
 * Settings › General: how the active workspace's Router writes to people.
 * The core reads the Router while General shows; a change shows at once.
 */
export function useRouterReplyStyle(enabled: boolean) {
  const call = useCall();
  const workspaceId = useActiveWorkspaceId();
  const { value: router } = useTopic(
    enabled && workspaceId
      ? { topic: "router", workspace: workspaceId, read: "settings" }
      : null
  );
  const [error, setError] = useState(false);
  const set = useCallback(
    (style: ReplyStyle) => {
      if (!workspaceId) return;
      setError(false);
      void call("models.setReplyStyle", { workspace: workspaceId, style }).catch(() =>
        setError(true)
      );
    },
    [call, workspaceId]
  );
  return {
    value: router ? (router.reply_style ?? "default") : undefined,
    disabled: !router,
    error,
    set,
  };
}
