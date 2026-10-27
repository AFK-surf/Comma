import type { ChatMessagePart } from "@comma/chat-contract";
import { useCall, type MiniAppVisibility } from "@comma/core-client";
import { taskStatusBucket } from "@comma/i18n";
import { useCommaMessages } from "@comma/i18n/react";
import { Dialog } from "@comma/ui/components/dialog";
import { SquareGridCircleIcon } from "@comma/ui/components/icons";
import { MiniAppCard } from "@comma/ui/components/mini-apps";
import { toast } from "@comma/ui/components/toast";
import {
  createContext,
  memo,
  useContext,
  useEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { useReportWidgetPresence } from "../chat/dynamic-ui/widgetPresence";
import { useOptionalChatSidebar } from "../chat-sidebar/ChatSidebarContext";
import { MiniAppFrame } from "./MiniAppFrame";
import { MiniAppSettingsDialog } from "./MiniAppSettingsDialog";
import { useMiniAppOpenActions } from "./miniAppOpen";
import { MiniAppVisibilityPicker } from "./MiniAppVisibilityPicker";

/** The Task a conversation view shows: its card offers Publish while the Task is in review. */
export type MiniAppTaskState = {
  conversationId: string;
  status: string | undefined;
  reviewVersion: number | undefined;
};
export const MiniAppTaskContext = createContext<MiniAppTaskState | undefined>(
  undefined
);

/** Whether `task` is in review and may publish what `conversationId` built. */
export function miniAppTaskInReview(
  task: MiniAppTaskState | undefined,
  conversationId: string | undefined
): task is MiniAppTaskState & { reviewVersion: number } {
  return (
    task !== undefined &&
    task.conversationId === conversationId &&
    task.status !== undefined &&
    taskStatusBucket(task.status) === "needs_review" &&
    typeof task.reviewVersion === "number" &&
    task.reviewVersion > 0
  );
}

// The Task each conversation view on screen shows, by its conversation: the right panel, which lives outside the
// view, offers Publish from it.
const shownTasks = new Map<string, MiniAppTaskState>();
const shownTaskListeners = new Set<() => void>();
const subscribeShownTasks = (listener: () => void) => {
  shownTaskListeners.add(listener);
  return () => shownTaskListeners.delete(listener);
};
const announceShownTasks = () => {
  for (const listener of shownTaskListeners) listener();
};

/** A conversation view shares the Task it shows while it is mounted. */
export function useShareMiniAppTask(task: MiniAppTaskState | undefined) {
  useEffect(() => {
    if (!task) return;
    shownTasks.set(task.conversationId, task);
    announceShownTasks();
    return () => {
      if (shownTasks.get(task.conversationId) !== task) return;
      shownTasks.delete(task.conversationId);
      announceShownTasks();
    };
  }, [task]);
}

/** The Task a conversation view on screen shows for `conversationId`, if any. */
export function useShownMiniAppTask(conversationId: string | undefined) {
  return useSyncExternalStore(subscribeShownTasks, () =>
    conversationId ? shownTasks.get(conversationId) : undefined
  );
}

/** The launch cover's height: the top of the app's first screen, under a gray margin. */
const COVER_HEIGHT = 240;

type MiniAppPart = Extract<ChatMessagePart, { kind: "mini-app" }>;

type Props = {
  part: MiniAppPart;
  /** A live thread runs the preview; a static surface (a report, a share) shows the summary. */
  live: boolean;
  groupId: string;
  workspaceId: string;
};

/**
 * The app cards a Task message carries, after its text. They sit outside the Markdown renderer, whose element resets
 * would otherwise restyle the card's buttons and type.
 */
export const MessageMiniAppCards = memo(function MessageMiniAppCards({
  message,
  ...context
}: Omit<Props, "part"> & {
  message: { parts?: readonly ChatMessagePart[] | undefined };
}) {
  const apps = (message.parts ?? []).filter(
    (part): part is MiniAppPart => part.kind === "mini-app"
  );
  if (apps.length === 0) return null;
  return (
    <>
      {apps.map((part) => (
        <MiniAppMessageCard
          key={`${part.appId}:${part.appVersion}`}
          part={part}
          {...context}
        />
      ))}
    </>
  );
});

/**
 * A Task message's app card: a preview of the Version the Task's agent deployed, running once the card comes into view
 * (at most three apps run at once). The preview is a phone's width, so the app always shows its phone layout, as the
 * template builds it (DESIGN.md §3); a wide chat does not turn it into the iPad layout in a 360px card. A press opens it
 * in the right panel; its menu has the other open mode, settings and, while the Task is in review, Publish.
 */
export function MiniAppMessageCard({ part, live, groupId, workspaceId }: Props) {
  return (
    <div
      className="mt-md w-full min-w-0 max-w-(--container-xs)"
      data-testid="mini-app-message-card"
    >
      {live ? (
        <LiveMiniAppCard groupId={groupId} part={part} workspaceId={workspaceId} />
      ) : (
        <MiniAppCard
          name={part.name}
          summary={part.summary}
          version={part.appVersion}
        />
      )}
    </div>
  );
}

function LiveMiniAppCard({ part, groupId, workspaceId }: Omit<Props, "live">) {
  const messages = useCommaMessages();
  const ref = useRef<HTMLDivElement>(null);
  const [seen, setSeen] = useState(false);
  const sidebar = useOptionalChatSidebar();
  const open = useMiniAppOpenActions();
  const task = useContext(MiniAppTaskContext);
  const [publishing, setPublishing] = useState(false);
  const [settings, setSettings] = useState(false);
  const [gone, setGone] = useState<"unavailable" | "disabled">();
  const target = { appId: part.appId, workspaceId, version: part.appVersion };
  const inReview = miniAppTaskInReview(task, part.conversationId);

  useEffect(() => {
    if (seen || !ref.current || typeof IntersectionObserver === "undefined") return;
    const root = ref.current.closest('[data-slot="scroll-area-viewport"]');
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) setSeen(true);
      },
      { root, rootMargin: "240px 0px" }
    );
    observer.observe(ref.current);
    return () => observer.disconnect();
  }, [seen]);

  // The card is a preview: a press opens the app in the right panel of the chat on screen. A Task's card also shows in
  // other chats (Home's), and the Task's own panel is not on screen there.
  const openBeside = () => {
    if (sidebar)
      sidebar.openApp(
        sidebar.getActiveHost() ?? {
          workspaceId,
          groupId,
          conversationId: part.conversationId,
        },
        { ...target, name: part.name }
      );
    else open.inPanel(target);
  };

  // An app that will not run again keeps its place in the conversation as a plain gray block that says why.
  if (gone) return <GoneMiniAppCard kind={gone} name={part.name} />;

  return (
    <div ref={ref} className="relative">
      <TakesConversationWidth />
      <MiniAppFrame
        actions={[
          ...(open.canOpenWindow
            ? [
                {
                  id: "window",
                  label: messages.mini_app_open_in_window(),
                  onAction: () => void open.window(target, ref.current),
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
        appId={part.appId}
        detail={messages.mini_app_cover_version({ version: String(part.appVersion) })}
        height={COVER_HEIGHT}
        idle={!seen}
        inert
        // A page switch back shows the running preview at once.
        keepKey={`${workspaceId}/${part.appId}@${part.appVersion}`}
        known={{ name: part.name, author: "" }}
        onGone={setGone}
        onOpen={openBeside}
        openLabel={messages.mini_app_open_beside_chat()}
        variant="cover"
        version={part.appVersion}
        via={{ workspace: workspaceId }}
      />
      {settings ? (
        <MiniAppSettingsDialog
          appId={part.appId}
          onClose={() => setSettings(false)}
          workspaceId={workspaceId}
        />
      ) : null}
      {publishing && task?.reviewVersion !== undefined ? (
        <PublishDialog
          appId={part.appId}
          conversationId={part.conversationId}
          groupId={groupId}
          name={part.name}
          onClose={() => setPublishing(false)}
          reviewVersion={task.reviewVersion}
          version={part.appVersion}
          workspaceId={workspaceId}
        />
      ) : null}
    </div>
  );
}

/**
 * The live card's row takes the conversation's width, as a generated UI widget does, so the card reaches a phone's
 * width beside short text; the unavailable block does not.
 */
function TakesConversationWidth() {
  useReportWidgetPresence();
  return null;
}

/** A Task's app that was deleted, is no longer shared, or was turned off: no frame, no actions, only why. */
function GoneMiniAppCard({
  kind,
  name,
}: {
  kind: "unavailable" | "disabled";
  name: string;
}) {
  const messages = useCommaMessages();
  return (
    <output
      className="flex w-fit max-w-[min(100%,var(--container-md))] items-center gap-md rounded-2xl bg-secondary px-lg py-md ring-1 ring-secondary"
      data-testid="mini-app-card-gone"
    >
      <span
        aria-hidden
        className="flex size-8 shrink-0 items-center justify-center rounded-lg bg-tertiary"
      >
        <SquareGridCircleIcon className="size-5 text-fg-quaternary" />
      </span>
      <span className="flex min-w-0 flex-col gap-xxs">
        <span className="text-sm font-medium text-secondary">
          {messages.mini_app_gone_title()}
        </span>
        <span className="text-xs text-tertiary">
          {kind === "disabled"
            ? messages.mini_app_gone_disabled({ name })
            : messages.mini_app_gone_unavailable({ name })}
        </span>
      </span>
    </output>
  );
}

/**
 * Publish: make the Version this card previews live. The server opens the Task's pull request when it has none, accepts
 * the review and merges at that Version's commit (a branch that moved past it is refused).
 */
export function PublishDialog({
  appId,
  conversationId,
  groupId,
  name,
  onClose,
  reviewVersion,
  version,
  workspaceId,
}: {
  appId: string;
  conversationId: string;
  groupId: string;
  name: string;
  onClose: () => void;
  reviewVersion: number;
  version: number;
  workspaceId: string;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const [visibility, setVisibility] = useState<MiniAppVisibility>("workspace");
  const publish = () => {
    onClose();
    void call("miniApps.publish", {
      workspace: workspaceId,
      app: appId,
      group: groupId,
      conversation: conversationId,
      reviewVersion,
      version,
      visibility,
    }).then(
      () => toast.success(messages.mini_app_published()),
      (error: { message?: string }) =>
        toast.error(messages.mini_app_publish_failed({ reason: error.message ?? "" }))
    );
  };
  return (
    <Dialog
      actions={[
        {
          label: messages.mini_app_cancel(),
          hierarchy: "secondary-gray",
          onPress: onClose,
        },
        {
          label: messages.mini_app_publish(),
          hierarchy: "primary",
          onPress: publish,
        },
      ]}
      description={messages.mini_app_publish_description()}
      isOpen
      onOpenChange={(isOpen) => {
        if (!isOpen) onClose();
      }}
      title={messages.mini_app_publish_title({ name })}
    >
      <MiniAppVisibilityPicker onChange={setVisibility} value={visibility} />
    </Dialog>
  );
}
