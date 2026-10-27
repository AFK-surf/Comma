import { useCommaMessages } from "@comma/i18n/react";
import { getNativeBridge } from "@comma/native-bridge";
import { MiniAppInWindowNotice } from "@comma/ui/components/mini-apps";
import { useCallback, useRef, useState } from "react";
import { useOptionalChatActionRegistry } from "../chat/ChatProvider";
import {
  appsSidebarHost,
  chatSidebarHostKey,
  useOptionalChatSidebar,
  type ChatSidebarAppPage,
  type ChatSidebarHost,
} from "../chat-sidebar/ChatSidebarContext";
import { MiniAppDraftContext, MiniAppFrame } from "./MiniAppFrame";
import {
  miniAppTaskInReview,
  PublishDialog,
  useShownMiniAppTask,
} from "./MiniAppMessageCard";
import { MiniAppSettingsDialog } from "./MiniAppSettingsDialog";
import { useMiniAppOpenActions } from "./miniAppOpen";

/**
 * A Mini App in the right panel. Beside a chat, its `chat.draft` text goes to that chat's composer; beside the Apps
 * gallery, to Home's. Its menu moves it to a window of its own, opens its settings and, while the Task that built it
 * is in review, publishes the Version it shows.
 *
 * While the app runs in a window of its own (`windowId`, opened from here or anywhere else), the panel keeps its tab
 * and shows that in the app's place: an app runs in one place at a time. Closing the window brings it back here.
 */
export function SidebarMiniApp({
  host,
  page,
  windowId,
}: {
  host: ChatSidebarHost | undefined;
  page: ChatSidebarAppPage;
  windowId?: string | undefined;
}) {
  const registry = useOptionalChatActionRegistry();
  const sidebar = useOptionalChatSidebar();
  const messages = useCommaMessages();
  const open = useMiniAppOpenActions();
  const [settings, setSettings] = useState(false);
  const [publishing, setPublishing] = useState(false);
  // The window being opened from here: the app stays until the window shows over it, so it never leaves the screen.
  const [moving, setMoving] = useState(false);
  const place = useRef<HTMLDivElement>(null);
  const besideChat =
    host !== undefined &&
    chatSidebarHostKey(host) !== chatSidebarHostKey(appsSidebarHost);
  const task = useShownMiniAppTask(besideChat ? host.conversationId : undefined);
  const inReview =
    besideChat &&
    page.version !== undefined &&
    miniAppTaskInReview(task, host.conversationId);
  const draft = useCallback(
    async (text: string) => {
      if (!registry || !host) throw new Error("No chat here.");
      const lease = registry.retain(
        host.workspaceId,
        host.groupId,
        host.conversationId
      );
      try {
        await lease.channel.prefillDraft(text);
      } finally {
        lease.release();
      }
    },
    [registry, host]
  );
  const target = {
    appId: page.appId,
    workspaceId: page.workspaceId,
    version: page.version,
  };
  return (
    <MiniAppDraftContext.Provider value={besideChat ? draft : undefined}>
      <div className="flex min-h-0 min-w-0 flex-1 flex-col" ref={place}>
        {windowId !== undefined && !moving ? (
          <MiniAppInWindowNotice
            onMoveBack={() =>
              void getNativeBridge()
                .windows.close({ windowId })
                .catch(() => {})
            }
            onShowWindow={() =>
              void getNativeBridge()
                .windows.focus({ windowId })
                .catch(() => {})
            }
          />
        ) : (
          <MiniAppFrame
            actions={[
              // Open in window moves the app: the window opens on the panel's place, and the panel lets the app go once
              // the window shows over it, so the app never leaves the screen.
              ...(open.canOpenWindow
                ? [
                    {
                      id: "window",
                      label: messages.mini_app_open_in_window(),
                      onAction: () => {
                        setMoving(true);
                        void open
                          .window(target, place.current)
                          .finally(() => setMoving(false));
                      },
                    },
                  ]
                : []),
              {
                id: "settings",
                label: messages.mini_app_settings(),
                onAction: () => setSettings(true),
              },
              ...(inReview
                ? [
                    {
                      id: "publish",
                      label: messages.mini_app_publish(),
                      onAction: () => setPublishing(true),
                    },
                  ]
                : []),
            ]}
            appId={page.appId}
            detail={
              page.version === undefined
                ? undefined
                : messages.mini_app_preview_version({ version: String(page.version) })
            }
            variant="flush"
            version={page.version}
            via={{ workspace: page.workspaceId }}
          />
        )}
      </div>
      {settings ? (
        <MiniAppSettingsDialog
          appId={page.appId}
          onClose={() => setSettings(false)}
          onRemoved={() => {
            if (host) sidebar?.closeAppPage(host, page.id);
          }}
          workspaceId={page.workspaceId}
        />
      ) : null}
      {publishing && inReview && task && page.version !== undefined && host ? (
        <PublishDialog
          appId={page.appId}
          conversationId={host.conversationId}
          groupId={host.groupId}
          name={page.name}
          onClose={() => setPublishing(false)}
          reviewVersion={task.reviewVersion!}
          version={page.version}
          workspaceId={page.workspaceId}
        />
      ) : null}
    </MiniAppDraftContext.Provider>
  );
}
