import { useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { readActiveWorkspaceId, subscribeActiveWorkspace } from "../activeWorkspace";
import { useCommaAuth } from "../auth-context";
import { assistantBrandName, routerDisplayName } from "./routerDisplayName";

export type RouterIdentity = {
  /** The Router Agent's stored name, once loaded for the active workspace. */
  name: string | undefined;
  /** `routerDisplayName(name, assistantBrandName)`: "Comma" while unnamed. */
  displayName: string;
  /** The ready workspace whose Router this describes. */
  workspaceId: string | undefined;
  /**
   * Renames the Router of `workspaceId` (default: the active workspace)
   * through the Agent rename and shows the trimmed name. Rejects on failure.
   */
  setRouterName(name: string, workspaceId?: string): Promise<void>;
  /**
   * The Router of `workspaceId` was renamed elsewhere in this window (the
   * Agent models in Settings): `name` shows at once, without another read.
   */
  routerRenamed(name: string, workspaceId: string): void;
};

/**
 * A name, and the read request it answers: a rename answers the latest. A
 * newer read request keeps showing the current name until its answer arrives.
 */
type StoredRouterName = { workspaceId: string; name: string; read: number };

const RouterIdentityContext = createContext<RouterIdentity | undefined>(undefined);
// Chat rows read only the label, so a rename or a workspace switch re-renders
// them, and nothing else in the identity does.
const RouterDisplayNameContext = createContext<string | undefined>(undefined);

/**
 * One owner per signed-in window for the Router's name. It reads the
 * workspace's agent models once per workspace (no polling) and takes the name
 * from each rename response. A rename in another window shows here after the
 * next read: a workspace change, a remount, or the onboarding window closing.
 * That window names the Router while it covers the display, so every window
 * that shows the name reads it once more when it closes: one read per open
 * window per onboarding.
 *
 * It follows the active workspace. A window bound to one workspace's Task
 * (the Side Chat Task window) passes that `workspaceId` instead.
 */
export function RouterIdentityProvider({
  children,
  workspaceId: boundWorkspaceId,
}: {
  children: ReactNode;
  workspaceId?: string;
}) {
  const { api } = useCommaAuth();
  const [activeWorkspaceId, setActiveWorkspaceId] = useState(readActiveWorkspaceId);
  const [stored, setStored] = useState<StoredRouterName>();
  // Read requests: the first read of a workspace, then one each time the
  // onboarding window closes.
  const [read, setRead] = useState(0);
  const latestRead = useRef(read);
  // Each workspace's Router Agent id, from its agent models: the rename names it.
  const routerAgentIds = useRef(new Map<string, string>());
  const workspaceId = boundWorkspaceId ?? activeWorkspaceId;

  useEffect(
    () =>
      boundWorkspaceId ? undefined : subscribeActiveWorkspace(setActiveWorkspaceId),
    [boundWorkspaceId]
  );

  // A rename stores the workspace's name for the latest read request, which
  // ends a read still in flight for it: that read could answer with the name
  // the rename replaced.
  const storedRead =
    stored && stored.workspaceId === workspaceId ? stored.read : undefined;
  useEffect(() => {
    if (!workspaceId || storedRead === read) return;
    const controller = new AbortController();
    api.getAgentModels(workspaceId, { signal: controller.signal }).then(
      (models) => {
        if (controller.signal.aborted) return;
        routerAgentIds.current.set(workspaceId, models.agents.router.agent_id);
        setStored({ workspaceId, name: models.agents.router.name, read });
      },
      // A failed read leaves the label it had; the next workspace change,
      // onboarding close or rename supplies the name.
      () => undefined
    );
    return () => controller.abort();
  }, [api, read, storedRead, workspaceId]);

  const setRouterName = useCallback(
    async (name: string, targetWorkspaceId?: string) => {
      const target = targetWorkspaceId ?? workspaceId;
      if (!target) throw new Error("workspace unavailable");
      let routerAgentId = routerAgentIds.current.get(target);
      if (!routerAgentId) {
        routerAgentId = (await api.getAgentModels(target)).agents.router.agent_id;
        routerAgentIds.current.set(target, routerAgentId);
      }
      await api.renameAgent(target, routerAgentId, name);
      // The server stores the name trimmed.
      setStored({ workspaceId: target, name: name.trim(), read: latestRead.current });
    },
    [api, workspaceId]
  );

  const routerRenamed = useCallback((name: string, target: string) => {
    setStored({ workspaceId: target, name, read: latestRead.current });
  }, []);

  useEffect(() => {
    let onboardingOpen = false;
    return getNativeBridge().onboarding.window.subscribe(({ open }) => {
      if (onboardingOpen && !open) {
        latestRead.current += 1;
        setRead(latestRead.current);
      }
      onboardingOpen = open;
    });
  }, []);

  const name = stored?.workspaceId === workspaceId ? stored?.name : undefined;
  const displayName = routerDisplayName(name, assistantBrandName);
  const identity = useMemo<RouterIdentity>(
    () => ({ name, displayName, workspaceId, setRouterName, routerRenamed }),
    [name, displayName, workspaceId, setRouterName, routerRenamed]
  );

  return (
    <RouterIdentityContext.Provider value={identity}>
      <RouterDisplayNameContext.Provider value={displayName}>
        {children}
      </RouterDisplayNameContext.Provider>
    </RouterIdentityContext.Provider>
  );
}

export function useRouterIdentity(): RouterIdentity {
  const value = useContext(RouterIdentityContext);
  if (!value) {
    throw new Error("useRouterIdentity must be used inside RouterIdentityProvider.");
  }
  return value;
}

/**
 * Tells this window's Router name owner about a rename made on another
 * surface. Outside a provider (a story, the web Task panel) nothing shows the
 * Router's name, so there is nothing to tell.
 */
export function useRouterRenamed(): RouterIdentity["routerRenamed"] {
  return useContext(RouterIdentityContext)?.routerRenamed ?? ignoreRouterRename;
}

const ignoreRouterRename = () => undefined;

/**
 * The Router's label for chat surfaces. The product session, Side Chat and
 * its Task window mount the provider. The web Task panel (a restricted
 * channel session that may not read agent models) and a public Task share
 * render the same rows without it; there the generic Router label applies.
 */
export function useRouterDisplayName(): string {
  const displayName = useContext(RouterDisplayNameContext);
  const messages = useCommaMessages();
  return displayName ?? messages.chat_actor_router();
}
