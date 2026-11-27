import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { useActiveWorkspaceId } from "../../activeWorkspace";
import { useIsGuestSession } from "../../auth-context";
import { NewStationTaskDialog } from "./NewStationTaskDialog";

type NewTaskCreated = { conversationId: string; groupId: string };

type NewTaskOpenOptions = {
  onCreated?: (task: NewTaskCreated) => void;
  requestTo?: string;
};

type NewTaskDialogContextValue = {
  /** A Task can be made now: the app works in a workspace. */
  available: boolean;
  /**
   * Opens the New Task panel on any page: in `workspace` when a page names the
   * one it shows, else in the workspace the app works in. With `requestTo` (a
   * request target's grant) it opens as a New request to it.
   */
  open: (workspace?: string, options?: NewTaskOpenOptions) => void;
};

const NewTaskDialogContext = createContext<NewTaskDialogContextValue | null>(null);

/**
 * Hosts the New Task panel for the whole window, so the Tasks page's button,
 * the New Task shortcut and the application menu open the same panel. A guest
 * Session has no Tasks: it never opens.
 */
export function NewTaskDialogProvider({ children }: { children: ReactNode }) {
  const guest = useIsGuestSession();
  const workspace = useActiveWorkspaceId(!guest);
  const [openIn, setOpenIn] = useState<{
    workspace: string;
    onCreated?: (task: NewTaskCreated) => void;
    requestTo?: string;
  }>();
  const available = !guest && !!workspace;
  const open = useCallback(
    (shown?: string, options?: NewTaskOpenOptions) => {
      const target = guest ? undefined : (shown ?? workspace);
      if (target) setOpenIn({ workspace: target, ...options });
    },
    [guest, workspace]
  );
  const value = useMemo(() => ({ available, open }), [available, open]);
  return (
    <NewTaskDialogContext.Provider value={value}>
      {children}
      {openIn ? (
        <NewStationTaskDialog
          // Opened again for another target, it starts over.
          key={`${openIn.workspace}\t${openIn.requestTo ?? ""}`}
          onClose={() => setOpenIn(undefined)}
          onCreated={openIn.onCreated}
          requestTo={openIn.requestTo}
          workspace={openIn.workspace}
        />
      ) : null}
    </NewTaskDialogContext.Provider>
  );
}

const unavailable: NewTaskDialogContextValue = { available: false, open: () => {} };

/** The window's New Task panel; outside the provider it is never available. */
export function useNewTaskDialog(): NewTaskDialogContextValue {
  return useContext(NewTaskDialogContext) ?? unavailable;
}
