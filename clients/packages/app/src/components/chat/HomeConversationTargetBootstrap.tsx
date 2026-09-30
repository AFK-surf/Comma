import { useRouterState } from "@tanstack/react-router";
import { useLayoutEffect } from "react";
import { showsProductRouteOutlet } from "../productShellPaths";
import { useChatApi, useChatRegistry, useHomeConversationTarget } from "./ChatProvider";
import { useWorkspaceChat } from "./useWorkspaceChat";

// The Comma assistant sidebar card is route-independent, but the Home
// conversation target it renders was only ever resolved by HomeRoute — after a
// cold renderer start on a non-Home product route (⌘R on /plugins, /tasks, …)
// nothing resolved it and the card sat idle until the user visited Home. This
// bootstrap resolves the target from any product route. It stands down while
// Home is on screen (HomeRoute owns resolution there), under the full-window
// Settings overlay (a direct Settings entry must not bootstrap a Workspace),
// and once a target is remembered.
export function HomeConversationTargetBootstrap() {
  const target = useHomeConversationTarget();
  const productRouteActive = useRouterState({
    select: (state) => showsProductRouteOutlet(state.location.pathname),
  });

  if (target || !productRouteActive) return null;
  return <ResolveHomeConversationTarget />;
}

function ResolveHomeConversationTarget() {
  const api = useChatApi();
  const registry = useChatRegistry();
  // Background resolution must not rescope the visible route: activating the
  // resolved default Workspace would rip a multi-Workspace user's selected
  // Workspace out from under /tasks and every other active-Workspace
  // subscriber. Only the identifiers are remembered here.
  const { state } = useWorkspaceChat({ activateWorkspace: false, api });

  useLayoutEffect(() => {
    if (state.status !== "ready") return;
    registry.rememberHomeConversationTarget(
      state.workspaceId,
      state.groupId,
      state.conversation.id,
      state.conversation
    );
  }, [registry, state]);

  return null;
}
