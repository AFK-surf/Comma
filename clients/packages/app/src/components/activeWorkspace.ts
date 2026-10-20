import { useCall, useTopic } from "@comma/core-client";
import type { ResolvedWorkspace } from "@comma/core/contract";
import { useCallback, useEffect } from "react";

/**
 * The workspace the app works in, as the core keeps it for the signed-in
 * account (`workspace` with no preference): the one last selected while the
 * account has it, else its first. Undefined while the list is read.
 */
export function useActiveWorkspace(enabled = true): ResolvedWorkspace | undefined {
  return useTopic(enabled ? { topic: "workspace" } : null).value;
}

/** The id of the workspace the app works in; undefined while the list is read. */
export function useActiveWorkspaceId(enabled = true): string | undefined {
  return useActiveWorkspace(enabled)?.workspace?.id;
}

/**
 * What a surface hands the core as its `prefer`: the workspace the app works
 * in, "" when the account has none, undefined while the list is read (the
 * surface waits rather than reading the first workspace's page first).
 */
export function useWorkspacePreference(enabled = true): string | undefined {
  const resolved = useActiveWorkspace(enabled);
  if (!resolved || resolved.status === "loading") return undefined;
  return resolved.workspace?.id ?? "";
}

/** Makes a workspace the one the app works in, on every window (`workspace.select`). */
export function useSelectWorkspace(): (workspaceId: string) => void {
  const call = useCall();
  return useCallback(
    (workspaceId: string) => {
      // A failed selection leaves the one before in place; nothing to tell the user.
      void call("workspace.select", { workspace: workspaceId }).catch(() => undefined);
    },
    [call]
  );
}

const LEGACY_STORAGE_KEY = "comma.activeWorkspaceId";

/**
 * Before the core kept it, a window kept the selection in its own storage:
 * hands it to the core once and forgets it. Mounted once per signed-in window.
 */
export function LegacyActiveWorkspace(): null {
  useLegacyActiveWorkspace();
  return null;
}

function useLegacyActiveWorkspace(): void {
  const select = useSelectWorkspace();
  useEffect(() => {
    let legacy: string | null = null;
    try {
      legacy = globalThis.localStorage?.getItem(LEGACY_STORAGE_KEY) ?? null;
      globalThis.localStorage?.removeItem(LEGACY_STORAGE_KEY);
    } catch {
      return;
    }
    if (legacy) select(legacy);
  }, [select]);
}
