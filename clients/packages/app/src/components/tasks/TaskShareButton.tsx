import { useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  ChainLinkIcon,
  CheckIcon,
  CircleInfoIcon,
  Dialog,
  GlobeIcon,
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  MoreHorizontalIcon,
  Tooltip,
  cx,
  dialogActionButton,
  menuCompactClasses,
  spacing,
  toast,
} from "@comma/ui";
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Button as AriaButton } from "react-aria-components";
import type { CommaApiClient, CommaTaskShare } from "../../api";
import {
  copyTextToClipboard,
  openUrlInExternalBrowser,
} from "../chat/thread/inline/linkActions";
import { TaskConversationPreview } from "../search/TaskConversationPreview";
import type { TaskConversationPreviewTarget } from "../search/taskConversationPreviewLoader";

type ShareState =
  | { kind: "loading" }
  | { kind: "failed" }
  | { kind: "ready"; share: CommaTaskShare | undefined };

const SHARE_TOAST_ID = "task-share-feedback";

/** The Task panel's bounded tail: enough turns to recognize the Task. */
const SHARE_PREVIEW_MESSAGE_LIMIT = 20;

/**
 * Sized to the 14px title it follows: the Task row "More" button's 20px hover
 * surface, transparent at rest.
 */
const shareButtonClassName =
  "inline-flex size-5 shrink-0 cursor-pointer items-center justify-center rounded-sm border-0 bg-transparent p-0 text-sidebar-icon-primary outline-none transition-colors duration-[50ms] hover:bg-sidebar-bg-item focus-visible:shadow-focus-gray";

/**
 * One state of the copy button: its icon and label, centered in a shared cell
 * at the icon-to-label distance a Button's leading icon keeps.
 */
const copyLabelClassName =
  "col-start-1 row-start-1 inline-flex items-center justify-center gap-sm";

export type TaskShareButtonProps = {
  api: CommaApiClient;
  conversationId: string;
  groupId: string;
  status?: string | undefined;
  /** The Task title the header shows; the dialog names what it shares. */
  title: string;
  updatedAt?: number | undefined;
  workspaceId: string;
};

/**
 * Opens the public-link dialog for one Task. The dialog reads the link only
 * when it opens and shows only the server's confirmed share state.
 */
export function TaskShareButton(props: TaskShareButtonProps) {
  const messages = useCommaMessages();
  const [open, setOpen] = useState(false);

  return (
    <>
      <Tooltip content={messages.task_share_button()} placement="bottom">
        <AriaButton
          aria-label={messages.task_share_button()}
          className={shareButtonClassName}
          data-testid="task-share-button"
          onPress={() => setOpen(true)}
        >
          <ChainLinkIcon className="size-3.5" />
        </AriaButton>
      </Tooltip>
      {open ? (
        // One dialog instance per Task: its preview and share state never
        // describe the Task the route left.
        <TaskShareDialog
          key={`${props.groupId}\u0000${props.conversationId}`}
          {...props}
          onClose={() => setOpen(false)}
        />
      ) : null}
    </>
  );
}

function TaskShareDialog({
  api,
  conversationId,
  groupId,
  onClose,
  status,
  title,
  updatedAt,
  workspaceId,
}: TaskShareButtonProps & { onClose: () => void }) {
  const messages = useCommaMessages();
  const [state, setState] = useState<ShareState>({ kind: "loading" });
  const [pending, setPending] = useState(false);
  // The link a successful copy put on the clipboard. A reset issues another
  // URL, so the button offers to copy again without a timer.
  const [copiedUrl, setCopiedUrl] = useState<string>();
  const controlsRef = useRef<HTMLDivElement>(null);
  // The preview is the Task as the dialog found it. Live updates would reload
  // it under the reader on every streamed message.
  const [previewTask] = useState<TaskConversationPreviewTarget>(() => ({
    conversationId,
    groupId,
    title,
    workspaceId,
    ...(status === undefined ? {} : { status }),
    ...(updatedAt === undefined ? {} : { updatedAt }),
  }));

  const load = useCallback(
    (signal?: AbortSignal) => {
      setState({ kind: "loading" });
      api
        .getTaskShare(groupId, conversationId, signal ? { signal } : {})
        .then((share) => {
          if (!signal?.aborted) setState({ kind: "ready", share });
        })
        .catch(() => {
          if (!signal?.aborted) setState({ kind: "failed" });
        });
    },
    [api, conversationId, groupId]
  );

  useEffect(() => {
    const controller = new AbortController();
    load(controller.signal);
    return () => controller.abort();
  }, [load]);

  // A settled change can remove the control that held focus: Create public
  // link becomes Copy link, and Stop sharing brings Create back. Focus then
  // falls to the document body, so the new state's primary action takes it.
  // It runs in layout: the modal's focus scope answers the same blur on the
  // next frame by focusing its first control, the close button.
  useLayoutEffect(() => {
    const active = document.activeElement;
    if (active && active !== document.body) return;
    controlsRef.current?.querySelector<HTMLElement>("[data-share-primary]")?.focus();
  }, [state]);

  /** Resolves to the share the server confirmed, or undefined on failure. */
  const run = async (change: () => Promise<CommaTaskShare | undefined>) => {
    setPending(true);
    try {
      const next = await change();
      setState({ kind: "ready", share: next });
      return next;
    } catch {
      toast.error(messages.task_share_failed(), { id: SHARE_TOAST_ID });
      return undefined;
    } finally {
      setPending(false);
    }
  };

  const copy = async (url: string, { reportFailure = true } = {}) => {
    // Clearing first makes a repeat copy confirm again: the button label
    // flips back, and the shared toast id replaces any earlier result.
    setCopiedUrl(undefined);
    try {
      await copyTextToClipboard(url);
      setCopiedUrl(url);
      toast.success(messages.task_share_copied(), { id: SHARE_TOAST_ID });
    } catch {
      if (!reportFailure) return;
      toast.error(messages.copy_failed_title(), {
        description: messages.copy_failed_detail(),
        id: SHARE_TOAST_ID,
      });
    }
  };

  const publish = () => run(() => api.publishTaskShare(groupId, conversationId));
  // A new link is created to be pasted somewhere, so it lands on the clipboard.
  // The write runs after the request, outside the click's user activation, and
  // Safari denies it there. That miss stays quiet: the link and Copy link are
  // already on screen.
  const create = async () => {
    const created = await publish();
    if (created) await copy(created.url, { reportFailure: false });
  };
  const share = state.kind === "ready" ? state.share : undefined;
  const copied = share !== undefined && copiedUrl === share.url;

  return (
    <Dialog
      className="w-dialog-preview rounded-2xl"
      description={messages.task_share_intro()}
      isOpen
      onOpenChange={(isOpen) => {
        if (!isOpen) onClose();
      }}
      showCloseButton
      title={messages.task_share_title({ title })}
    >
      <div
        className="flex w-full flex-col gap-xl"
        data-testid="task-share-dialog"
        ref={controlsRef}
      >
        {/* Tall enough to recognize the Task; on a short window it yields
            first, so the link and its actions stay in view. */}
        <div className="h-[min(var(--container-xxs),calc(100vh-var(--container-xs)))] min-h-0">
          <TaskConversationPreview
            apiClient={api}
            className="comma-task-share-preview rounded-xl shadow-none"
            messageLimit={SHARE_PREVIEW_MESSAGE_LIMIT}
            showTitle={false}
            task={previewTask}
          />
        </div>

        {state.kind === "loading" ? (
          <output
            aria-busy="true"
            aria-label={messages.common_loading()}
            className="block h-4xl w-full rounded-md bg-quaternary motion-safe:animate-pulse"
          />
        ) : state.kind === "failed" ? (
          <div className="flex min-h-4xl items-center justify-between gap-md">
            <p className="text-sm text-error-primary" role="alert">
              {messages.task_share_load_failed()}
            </p>
            <Button
              className={dialogActionButton}
              hierarchy="secondary-gray"
              onPress={() => load()}
              size="sm"
            >
              {messages.share_view_retry()}
            </Button>
          </div>
        ) : share ? (
          <div className="flex flex-col gap-md">
            {share.has_newer_messages ? (
              <div
                className="flex items-center gap-md rounded-lg bg-tertiary py-xs pr-xs pl-md"
                data-testid="task-share-newer"
              >
                <CircleInfoIcon className="size-4 shrink-0 text-fg-quaternary" />
                <p className="min-w-0 flex-1 text-sm text-secondary">
                  {messages.task_share_newer()}
                </p>
                <Button
                  className={dialogActionButton}
                  hierarchy="secondary-gray"
                  isPending={pending}
                  onPress={() => void publish()}
                  size="sm"
                >
                  {messages.task_share_update()}
                </Button>
              </div>
            ) : null}
            <div className="flex items-center gap-sm">
              <label className="flex h-4xl min-w-0 flex-1 cursor-text items-center gap-sm rounded-md border border-primary bg-primary px-md shadow-xs focus-within:shadow-focus-gray-shadow-xs">
                <GlobeIcon className="size-4 shrink-0 text-fg-quaternary" />
                <input
                  aria-label={messages.task_share_link_label()}
                  className="min-w-0 flex-1 truncate bg-transparent text-sm text-secondary outline-none"
                  data-testid="task-share-url"
                  onFocus={(event) => event.currentTarget.select()}
                  readOnly
                  value={share.url}
                />
              </label>
              {/* The link's less frequent actions stay one press away, so the
                  row keeps a single primary action. */}
              <MenuTrigger>
                <Button
                  aria-label={messages.task_share_actions()}
                  className="size-8 rounded-md p-0"
                  hierarchy="secondary-gray"
                  iconLeading={<MoreHorizontalIcon />}
                  iconOnly
                  isPending={pending}
                  size="sm"
                />
                <MenuPopover offset={spacing.xs} placement="bottom end">
                  <Menu
                    aria-label={messages.task_share_actions()}
                    className={menuCompactClasses}
                    onAction={(key) => {
                      if (key === "open") void openUrlInExternalBrowser(share.url);
                      else if (key === "reset") {
                        void run(() => api.resetTaskShare(groupId, conversationId));
                      } else if (key === "stop") {
                        void run(async () => {
                          await api.revokeTaskShare(groupId, conversationId);
                          return undefined;
                        });
                      }
                    }}
                  >
                    <MenuItem id="open">{messages.task_share_open()}</MenuItem>
                    <MenuItem id="reset">{messages.task_share_reset()}</MenuItem>
                    <MenuSeparator />
                    <MenuItem id="stop" tone="destructive">
                      {messages.task_share_stop()}
                    </MenuItem>
                  </Menu>
                </MenuPopover>
              </MenuTrigger>
              <Button
                className={dialogActionButton}
                data-share-primary=""
                hierarchy="primary"
                isPending={pending}
                onPress={() => void copy(share.url)}
                size="sm"
              >
                {/* Both states hold the cell, so confirming a copy never
                    resizes the button or the link beside it. */}
                <span className="-ml-xxs grid">
                  <span className={cx(copyLabelClassName, copied && "invisible")}>
                    <ChainLinkIcon className="size-4" />
                    {messages.task_share_copy()}
                  </span>
                  <span className={cx(copyLabelClassName, !copied && "invisible")}>
                    <CheckIcon className="size-4" />
                    {messages.task_share_copied()}
                  </span>
                </span>
              </Button>
            </div>
            {share.artifact_count > 0 ? (
              <p className="text-xs text-tertiary">
                {messages.task_share_file_count({
                  count: share.artifact_count,
                  formattedCount: share.artifact_count.toLocaleString(),
                })}
              </p>
            ) : null}
          </div>
        ) : (
          <div className="flex min-h-4xl items-center justify-between gap-md">
            <p className="text-sm text-tertiary">{messages.task_share_unshared()}</p>
            <Button
              className={dialogActionButton}
              data-share-primary=""
              hierarchy="primary"
              iconLeading={<ChainLinkIcon />}
              isPending={pending}
              onPress={() => void create()}
              size="sm"
            >
              {messages.task_share_create()}
            </Button>
          </div>
        )}
      </div>
    </Dialog>
  );
}
