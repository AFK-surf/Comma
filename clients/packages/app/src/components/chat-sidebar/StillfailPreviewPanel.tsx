import { useTopic } from "@comma/core-client";
import { formatRelativeDate } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";
import { Button } from "@comma/ui/components/Button";
import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";
import {
  ArrowUpRightIcon,
  CircleCheckIcon,
  CircleInfoIcon,
  CircleXIcon,
  LoaderIcon,
  ReloadIcon,
} from "@comma/ui/components/icons";
import { MarkdownStream } from "@comma/ui/components/markdown-stream";
import { RightSidebarToolbarButton } from "@comma/ui/components/right-sidebar";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import {
  Fragment,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type UIEvent,
} from "react";
import { openUrlInExternalBrowser } from "../chat/thread/inline/linkActions";
import { LinkProviderIcon, type StillfailChatPreview } from "../links/linkPreviewCards";
import type { ChatSidebarStillfailPreview } from "./ChatSidebarContext";

const stillfailSource = { appId: "stillfail", appName: "still.fail" } as const;

const RUNNING_POLL_MS = 4_000;
const NEED_POLL_MS = 10_000;
const TIME_GAP_MS = 5 * 60_000;
const STICK_TO_BOTTOM_PX = 48;

const statusIcons = {
  need: CircleInfoIcon,
  running: LoaderIcon,
  done: CircleCheckIcon,
  failed: CircleXIcon,
} as const satisfies Record<StillfailChatPreview["status"], typeof CircleInfoIcon>;

export function StillfailPreviewPanel({
  active,
  onTitleChange,
  preview: tab,
}: {
  active: boolean;
  onTitleChange?: ((title: string) => void) | undefined;
  preview: ChatSidebarStillfailPreview;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const [refreshCount, setRefreshCount] = useState(0);
  const [cached, setCached] = useState<{
    href: string;
    preview: StillfailChatPreview;
  } | null>(null);
  const bottomRef = useRef<HTMLDivElement>(null);
  const stickToBottomRef = useRef(true);
  const initializedHrefRef = useRef<string | null>(null);
  const lastTailKeyRef = useRef<string | null>(null);
  const previousSignalRef = useRef<string | null>(null);

  const triggerRefresh = useCallback(() => {
    setRefreshCount((count) => count + 1);
  }, []);

  const { value } = useTopic(
    active
      ? {
          topic: "linkPreview",
          workspace: tab.workspaceId,
          href: tab.href,
          source: "",
          read: String(refreshCount),
        }
      : null,
    { lingerMs: 0 }
  );

  // Subscribe to the workspace's stationTasks stream while visible so any
  // station-side status or activity revision change refreshes immediately.
  const { value: stationTasks } = useTopic(
    active ? { topic: "stationTasks", workspace: tab.workspaceId } : null,
    { lingerMs: 0 }
  );

  const livePreview =
    value?.status === "ready" && value.preview.kind === "stillfail_chat"
      ? value.preview
      : undefined;

  useEffect(() => {
    if (!livePreview) return;
    setCached((previous) => {
      if (
        previous &&
        previous.href === tab.href &&
        previous.preview.messages.length > 0 &&
        livePreview.offline &&
        livePreview.messages.length === 0
      ) {
        // Keep previously loaded messages visible during transient station
        // disconnects instead of clearing the panel.
        return {
          href: tab.href,
          preview: {
            ...livePreview,
            messages: previous.preview.messages,
          },
        };
      }
      return { href: tab.href, preview: livePreview };
    });
  }, [livePreview, tab.href]);

  const cachedForHref = cached?.href === tab.href ? cached.preview : undefined;
  const readyPreview = useMemo<StillfailChatPreview | undefined>(() => {
    if (livePreview) {
      if (
        cachedForHref &&
        cachedForHref.messages.length > 0 &&
        livePreview.offline &&
        livePreview.messages.length === 0
      ) {
        return {
          ...livePreview,
          messages: cachedForHref.messages,
        };
      }
      return livePreview;
    }
    if (cachedForHref) {
      return value?.status === "missing"
        ? { ...cachedForHref, offline: true }
        : cachedForHref;
    }
    return undefined;
  }, [cachedForHref, livePreview, value?.status]);

  const liveTaskSignal = useMemo(() => {
    const tasks = stationTasks?.tasks;
    if (!tasks?.length) return null;
    const match = tasks.find(
      (task) =>
        (readyPreview?.ref && task.id === readyPreview.ref) ||
        (task.url !== null && task.url.trim() === tab.href.trim())
    );
    if (!match) return null;
    return `${match.status}:${match.lastActivityAt ?? 0}`;
  }, [readyPreview?.ref, stationTasks?.tasks, tab.href]);

  useEffect(() => {
    if (!active || liveTaskSignal === null) return;
    if (
      previousSignalRef.current !== null &&
      previousSignalRef.current !== liveTaskSignal
    ) {
      triggerRefresh();
    }
    previousSignalRef.current = liveTaskSignal;
  }, [active, liveTaskSignal, triggerRefresh]);

  // Bounded live refresh while active and visible: 4s while the agent is
  // actively running, 10s while waiting on the user, stopped once done/failed.
  const status = readyPreview?.status;
  useEffect(() => {
    if (!active) return;
    const intervalMs =
      status === "running" ? RUNNING_POLL_MS : status === "need" ? NEED_POLL_MS : null;
    if (intervalMs === null) return;
    return uiClock.every(intervalMs, () => {
      if (typeof document === "undefined" || document.visibilityState === "visible") {
        triggerRefresh();
      }
    });
  }, [active, status, triggerRefresh]);

  // Refresh immediately when the user returns to the Comma window.
  useEffect(() => {
    if (!active || typeof window === "undefined") return;
    const handleFocus = () => triggerRefresh();
    const handleVisibility = () => {
      if (document.visibilityState === "visible") triggerRefresh();
    };
    window.addEventListener("focus", handleFocus);
    document.addEventListener("visibilitychange", handleVisibility);
    return () => {
      window.removeEventListener("focus", handleFocus);
      document.removeEventListener("visibilitychange", handleVisibility);
    };
  }, [active, triggerRefresh]);

  useEffect(() => {
    if (readyPreview?.title && readyPreview.title !== tab.title) {
      onTitleChange?.(readyPreview.title);
    }
  }, [onTitleChange, readyPreview?.title, tab.title]);

  const visibleMessages = useMemo(
    () =>
      (readyPreview?.messages ?? []).filter(
        (message) => message.text.trim().length > 0 || message.card !== null
      ),
    [readyPreview?.messages]
  );

  const lastMessage = visibleMessages[visibleMessages.length - 1];
  const tailKey = lastMessage
    ? `${lastMessage.seq}:${lastMessage.text.length}:${lastMessage.card?.choice ?? ""}:${lastMessage.card?.closed ? 1 : 0}`
    : null;

  useEffect(() => {
    if (!active || !tailKey) return;
    if (initializedHrefRef.current !== tab.href) {
      initializedHrefRef.current = tab.href;
      lastTailKeyRef.current = tailKey;
      stickToBottomRef.current = true;
      bottomRef.current?.scrollIntoView({ block: "end" });
      return;
    }
    if (lastTailKeyRef.current !== tailKey) {
      lastTailKeyRef.current = tailKey;
      if (stickToBottomRef.current) {
        bottomRef.current?.scrollIntoView({ block: "end" });
      }
    }
  }, [active, tab.href, tailKey]);

  const handleScroll = useCallback((event: UIEvent<HTMLDivElement>) => {
    const viewport = event.currentTarget;
    const distance = viewport.scrollHeight - viewport.clientHeight - viewport.scrollTop;
    stickToBottomRef.current = distance <= STICK_TO_BOTTOM_PX;
  }, []);

  const StatusIcon = status ? statusIcons[status] : undefined;
  const statusLabel = status
    ? {
        need: messages.stillfail_preview_status_need(),
        running: messages.stillfail_preview_status_running(),
        done: messages.stillfail_preview_status_done(),
        failed: messages.stillfail_preview_status_failed(),
      }[status]
    : undefined;

  const title = readyPreview?.title ?? tab.title ?? "still.fail";
  const isFetching = !value || value.status === "loading";
  const loading = !readyPreview && isFetching;
  const isRefreshing = Boolean(readyPreview) && isFetching;

  return (
    <div className="comma-stillfail-panel" data-testid="stillfail-preview-panel">
      <header className="comma-stillfail-header">
        <div className="comma-stillfail-header-main">
          <span aria-hidden="true" className="comma-stillfail-header-mark">
            <LinkProviderIcon source={stillfailSource} />
          </span>
          <span className="comma-stillfail-header-title" title={title}>
            {title}
          </span>
          {status && statusLabel && StatusIcon ? (
            <span className="comma-stillfail-status" data-status={status}>
              <StatusIcon
                className={
                  status === "running"
                    ? "size-3 shrink-0 animate-spin"
                    : "size-3 shrink-0"
                }
              />
              <span>{statusLabel}</span>
            </span>
          ) : null}
          {readyPreview?.stationName ? (
            <span className="comma-stillfail-station" title={readyPreview.stationName}>
              {readyPreview.stationName}
            </span>
          ) : null}
        </div>
        <div className="comma-stillfail-header-actions">
          <RightSidebarToolbarButton
            aria-label={messages.stillfail_preview_refresh()}
            onClick={triggerRefresh}
            title={messages.stillfail_preview_refresh()}
          >
            <ReloadIcon className={isRefreshing ? "size-4 animate-spin" : "size-4"} />
          </RightSidebarToolbarButton>
          <RightSidebarToolbarButton
            aria-label={messages.stillfail_preview_open_external()}
            onClick={() => {
              void openUrlInExternalBrowser(readyPreview?.href ?? tab.href);
            }}
            title={messages.stillfail_preview_open_external()}
          >
            <ArrowUpRightIcon className="size-4" />
          </RightSidebarToolbarButton>
        </div>
      </header>

      <ScrollArea className="min-h-0 flex-1" onScroll={handleScroll}>
        <div className="comma-stillfail-thread">
          {loading ? (
            <div className="flex items-center justify-center py-4xl">
              <LoadingIndicator label={title} />
            </div>
          ) : !readyPreview ? (
            <div className="comma-stillfail-notice">
              <span>{messages.stillfail_preview_unavailable()}</span>
              <Button
                hierarchy="secondary-gray"
                iconTrailing={<ArrowUpRightIcon />}
                onPress={() => {
                  void openUrlInExternalBrowser(tab.href);
                }}
                size="sm"
              >
                {messages.stillfail_preview_open_external()}
              </Button>
            </div>
          ) : (
            <>
              {readyPreview.offline ? (
                <div className="comma-stillfail-offline-banner">
                  {messages.stillfail_preview_offline()}
                  {readyPreview.note ? ` · ${readyPreview.note}` : ""}
                </div>
              ) : null}

              {visibleMessages.length === 0 ? (
                <div className="comma-stillfail-notice">
                  {readyPreview.note ?? messages.stillfail_preview_empty()}
                </div>
              ) : (
                visibleMessages.map((message, index) => {
                  const previous = visibleMessages[index - 1];
                  const showTime =
                    message.createdAt !== null &&
                    (index === 0 ||
                      previous?.createdAt === null ||
                      previous?.createdAt === undefined ||
                      message.createdAt - previous.createdAt >= TIME_GAP_MS);
                  const isPerson = message.authorKind === "person";

                  return (
                    <Fragment key={message.seq}>
                      {showTime && message.createdAt !== null ? (
                        <time
                          className="comma-stillfail-time"
                          dateTime={new Date(message.createdAt).toISOString()}
                        >
                          {formatRelativeDate(message.createdAt, locale)}
                        </time>
                      ) : null}
                      <article
                        className="comma-stillfail-row"
                        data-author-kind={message.authorKind}
                      >
                        <div
                          className={
                            isPerson
                              ? "comma-stillfail-user-bubble"
                              : "comma-stillfail-agent-bubble"
                          }
                        >
                          {message.text ? (
                            <MarkdownStream content={message.text} />
                          ) : null}

                          {message.card ? (
                            <div className="comma-stillfail-card-footer">
                              {message.card.choice ? (
                                <span
                                  className="comma-stillfail-chip"
                                  data-tone="answered"
                                >
                                  <CircleCheckIcon className="size-3.5 shrink-0 text-text-brand-tertiary" />
                                  <span>
                                    {messages.stillfail_preview_card_answered({
                                      choice: message.card.choice,
                                    })}
                                  </span>
                                </span>
                              ) : message.card.closed ? (
                                <span className="comma-stillfail-chip">
                                  {messages.stillfail_preview_card_closed()}
                                </span>
                              ) : message.card.options.length > 0 ? (
                                message.card.options.map((option) => (
                                  <span key={option} className="comma-stillfail-chip">
                                    {option}
                                  </span>
                                ))
                              ) : null}
                            </div>
                          ) : null}
                        </div>
                      </article>
                    </Fragment>
                  );
                })
              )}
              <div ref={bottomRef} />
            </>
          )}
        </div>
      </ScrollArea>
    </div>
  );
}
