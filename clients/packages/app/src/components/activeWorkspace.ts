const ACTIVE_WORKSPACE_STORAGE_KEY = "comma.activeWorkspaceId";
const ACTIVE_WORKSPACE_CHANGED_EVENT = "comma:active-workspace-changed";

type ActiveWorkspaceListener = (workspaceId: string | undefined) => void;

export function readActiveWorkspaceId() {
  try {
    return globalThis.localStorage?.getItem(ACTIVE_WORKSPACE_STORAGE_KEY) ?? undefined;
  } catch {
    return undefined;
  }
}

export function writeActiveWorkspaceId(workspaceId: string) {
  try {
    globalThis.localStorage?.setItem(ACTIVE_WORKSPACE_STORAGE_KEY, workspaceId);
  } catch {
    // A blocked storage write should not prevent this shell from changing scope.
  }

  globalThis.window?.dispatchEvent(
    new CustomEvent(ACTIVE_WORKSPACE_CHANGED_EVENT, {
      detail: { workspaceId },
    })
  );
}

export function subscribeActiveWorkspace(listener: ActiveWorkspaceListener) {
  if (!globalThis.window) {
    return () => undefined;
  }

  const handleActiveWorkspaceChange = (event: Event) => {
    const workspaceId = (event as CustomEvent<{ workspaceId?: string }>).detail
      ?.workspaceId;
    listener(workspaceId || readActiveWorkspaceId());
  };
  const handleStorage = (event: StorageEvent) => {
    if (event.key === ACTIVE_WORKSPACE_STORAGE_KEY) {
      listener(event.newValue || undefined);
    }
  };

  window.addEventListener(ACTIVE_WORKSPACE_CHANGED_EVENT, handleActiveWorkspaceChange);
  window.addEventListener("storage", handleStorage);
  return () => {
    window.removeEventListener(
      ACTIVE_WORKSPACE_CHANGED_EVENT,
      handleActiveWorkspaceChange
    );
    window.removeEventListener("storage", handleStorage);
  };
}
