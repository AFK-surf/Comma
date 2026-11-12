import type { ListedScreen } from "@comma/core-client";
import { useEffect } from "react";
import {
  useOptionalChatSidebarActions,
  type ChatSidebarHost,
} from "../chat-sidebar/ChatSidebarContext";

/** A computer's screen asked for where there is no chat to hold its tab (Settings › Devices): Home's chat opens it. */
export type PendingScreen = {
  workspaceId: string;
  device: string;
  apps: string[];
} & (
  | { target: "display" | "models"; screen?: undefined }
  | { screen: ListedScreen; target?: undefined }
);

let pending: PendingScreen | null = null;
const listeners = new Set<() => void>();

export function requestScreenOnHome(screen: PendingScreen) {
  pending = screen;
  for (const listener of listeners) listener();
}

/** Home's chat, once it is `host` and shown: opens what was asked for, in a tab of its side panel. */
export function useOpenPendingScreen(host: ChatSidebarHost | undefined) {
  const actions = useOptionalChatSidebarActions();
  const conversationId = host?.conversationId;
  const groupId = host?.groupId;
  const workspaceId = host?.workspaceId;
  useEffect(() => {
    if (!actions || !conversationId || !groupId || !workspaceId) return undefined;
    const take = () => {
      if (!pending || pending.workspaceId !== workspaceId) return;
      const screen = pending;
      pending = null;
      actions.openScreen({ conversationId, groupId, workspaceId }, screen);
    };
    take();
    listeners.add(take);
    return () => void listeners.delete(take);
  }, [actions, conversationId, groupId, workspaceId]);
}
