/* oxlint-disable jsx-a11y/prefer-tag-over-role -- A source's Routine cards are one labelled group of actions, not a form, so fieldset does not fit. */
import { uiClock } from "@comma/ui/clock";
import { RoutinesCleared } from "./RoutinesCleared";
import { SourceContext } from "./SourceContext";
import {
  useArchiveAction,
  useTaskSummariesState,
  useTaskSummary,
} from "../tasks/useTaskArchive";
import { useProductInboxGroupId } from "../../product-inbox";
import { TaskArchiveMenu } from "@comma/ui/components/task-workspace/TaskArchiveMenu";
import type {
  RecommendationAction,
  RecommendationCard,
  RecommendationDocumentPart,
  RecommendationEnvelope,
  RecommendationGeneratedCard,
  RecommendationQuoteLine,
  RecommendationSource,
} from "@comma/recommendation-contract";
import { recommendationGeneratedCardSchema } from "@comma/recommendation-contract";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import {
  CircleMinusOutlineIcon,
  LoadingCircleIcon,
  PinIcon,
  ReloadIcon,
} from "@comma/ui/components/icons";
import {
  GithubProviderLogo,
  GoogleDriveProviderLogo,
  LinearProviderLogo,
  normalizeProviderBrandName,
  SlackProviderLogo,
} from "@comma/ui/components/provider-brand-logos";
import { HoverCard } from "@comma/ui/components/hover-card";
import {
  isReducedMotionEnabled,
  motionDuration,
  motionEasing,
  motionScale,
} from "@comma/ui/tokens";
import {
  LinkContextMenu,
  type LinkContextMenuAction,
  useTextEditContextMenuState,
} from "@comma/ui/components/menu";
import { MarkdownStream } from "@comma/ui/components/markdown-stream";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { copyWithFeedback, toast } from "@comma/ui/components/toast";
import { Tooltip } from "@comma/ui/components/tooltip";
import {
  type MouseEvent as ReactMouseEvent,
  type ReactElement,
  type ReactNode,
  type RefObject,
  createContext,
  memo,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { Button as AriaButton } from "react-aria-components";
import { type TaskSummary, useCall, useTopic } from "@comma/core-client";
import {
  nativePlatformClipboard,
  openNativePlatformExternalUrl,
} from "../../nativePlatformActions";
import { ShellIconButtonControl } from "../ShellIconButton";
import { useHeldWhileDisabled } from "../useHeldWhileDisabled";
import { showOutOfCreditsToast } from "../billing/outOfCredits";
import { compileTrustedInlineDocument } from "../inline-elements/compileTrustedInlineDocument";
import {
  describeLinkDestination,
  isPrivateMailLink,
  LinkPreviewCard,
  LinkPreviewSkeleton,
  LinkProviderIcon,
  useLinkPreviewMediaUrl,
} from "../links/linkPreviewCards";
import { useLinkPreview } from "../links/useLinkPreview";
import {
  recommendationLinkHrefAttribute,
  resolveRecommendationLinkFromEventTarget,
} from "./recommendationLinkMenu";

// Inline-link hover cards read their rich preview in the rail's workspace.
// Provided once by the rail; documents rendered outside it (stories, tests,
// detached cards) keep the generic destination card. A source context card
// stays inside the boundary, the rail, instead of covering the panel beside it.
type RecommendationLinkPreviewContextValue = {
  boundaryRef?: RefObject<Element | null> | undefined;
  workspaceId: string;
};
const RecommendationLinkPreviewContext = createContext<
  RecommendationLinkPreviewContextValue | undefined
>(undefined);

export function RecommendationLinkPreviewProvider({
  boundaryRef,
  children,
  workspaceId,
}: RecommendationLinkPreviewContextValue & { children: ReactNode }) {
  const value = useMemo(
    () => ({ boundaryRef, workspaceId }),
    [boundaryRef, workspaceId]
  );
  return (
    <RecommendationLinkPreviewContext.Provider value={value}>
      {children}
    </RecommendationLinkPreviewContext.Provider>
  );
}

/** A Routine row's prompt as the composer stages it. */
export type RecommendationComposerPrompt = {
  text: string;
  /** The app the row reads, for the staged tile's mark. */
  source?: RecommendationSource | undefined;
  /** The item the row is about, such as a Linear issue or a Gmail message. */
  sourceUrl?: string | undefined;
};

type RecommendationRailProps = {
  /** The signed-in user's name; greets them by name in the briefing title. */
  greetingName?: string | undefined;
  active?: boolean;
  /** Opens the Plugins route so the user can connect a first app. */
  onConnectApps?: (() => void) | undefined;
  onOpenTask: (conversationId: string) => void;
  onOpenUrl: (url: string) => void;
  onUsePrompt: (prompt: RecommendationComposerPrompt) => void;
  workspaceId: string;
};

// Why the rail has no briefing to show: the projection could not be read, a
// manual refresh was refused by the hourly budget, or the server reports that
// the last generation failed.
type RailFailure = "unavailable" | "rate_limited" | undefined;

const STALE_BRIEFING_MS = 24 * 60 * 60 * 1000;

// Routine failures that the member cannot act on stay out of the UI: the rail
// keeps the last briefing, and the server logs and counts every failed run.
// Exhausted credits name the action the member can take to resume generation.

export const RecommendationRail = memo(function RecommendationRail({
  active = true,
  greetingName,
  onConnectApps,
  onOpenTask,
  onOpenUrl,
  onUsePrompt,
  workspaceId,
}: RecommendationRailProps) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  // The core reads the briefing while the rail shows (and again as runs, discovery and the delivery need). While
  // Home is hidden the rail reads nothing and keeps the briefing it showed, so no loading skeleton mounts in the hidden
  // surface. Home shown again while the topic lingers keeps the same cards; after that the rail reads the briefing anew.
  const call = useCall();
  const timezone = useMemo(() => Intl.DateTimeFormat().resolvedOptions().timeZone, []);
  const shown = useHeldWhileDisabled(
    active,
    useTopic(
      active
        ? { topic: "recommendations", workspace: workspaceId, timezone, locale }
        : null
    ).value
  );
  // Home shown again while the topic lingered: discovery checks start over.
  const wasActiveRef = useRef(active);
  useEffect(() => {
    const was = wasActiveRef.current;
    wasActiveRef.current = active;
    if (active && !was)
      void call("recommendations.visit", { workspace: workspaceId }).catch(
        () => undefined
      );
  }, [active, call, workspaceId]);
  const envelope = shown?.envelope ?? undefined;
  const failure: RailFailure = shown?.failure ?? undefined;
  const error = failure !== undefined;
  const refreshing = shown?.refreshing ?? false;
  const discoveringSources = shown?.discovering ?? false;
  const creditNoticeWorkspaceRef = useRef<string | null>(null);
  const railRef = useRef<HTMLDivElement | null>(null);
  const linkMenuUrlRef = useRef<string | null>(null);
  const {
    isOpen: isLinkMenuOpen,
    pointerOffsets: linkMenuPointerOffsets,
    handleOpenChange: setLinkMenuOpen,
    openAtPointer: openLinkMenuAtPointer,
  } = useTextEditContextMenuState({
    isEnabled: true,
    preserveTextSelection: true,
  });
  // The generation last read for this workspace. A later read with another
  // generation is a new briefing, and the member hears about it once.
  const seenGenerationRef = useRef<{ generation: number | null; workspaceId: string }>(
    undefined
  );
  // Read at announce time, so a language change does not re-create `load`.
  const messagesRef = useRef(messages);
  messagesRef.current = messages;
  const noteGeneration = useCallback(
    (next: RecommendationEnvelope) => {
      const generation = next.snapshot?.generation ?? null;
      const seen = seenGenerationRef.current;
      seenGenerationRef.current = { generation, workspaceId };
      if (
        seen?.workspaceId === workspaceId &&
        generation !== null &&
        generation !== seen.generation
      ) {
        toast.success(messagesRef.current.recommendations_updated(), {
          id: `routine-updated:${workspaceId}`,
          testId: "routine-updated-toast",
        });
      }
    },
    [workspaceId]
  );
  const canRefresh =
    envelope?.settings.sources.some((source) => source.enabled) === true;
  // A server-owned run stays "generating" only while its projection can still
  // be read; once the poll gives up, the last envelope no longer speaks for it.
  const isRefreshing = refreshing || (envelope?.state === "refreshing" && !error);
  // Until the first read answers, the rail takes a briefing's layout, so the
  // briefing most members have lands where its placeholder was. A refresh
  // keeps the current briefing on screen; only the refresh control spins.
  const initialLoading = !envelope && !error && !isRefreshing;
  useEffect(() => {
    if (!active || !envelope) return;
    if (
      (envelope.state === "error" || envelope.state === "stale") &&
      envelope.lastError === "insufficient_credits"
    ) {
      if (creditNoticeWorkspaceRef.current !== workspaceId) {
        creditNoticeWorkspaceRef.current = workspaceId;
        showOutOfCreditsToast(locale, undefined, {
          title: messagesRef.current.recommendations_out_of_credits_title(),
          description: messagesRef.current.recommendations_out_of_credits_detail(),
        });
      }
    } else {
      creditNoticeWorkspaceRef.current = null;
    }
  }, [active, envelope, locale, workspaceId]);

  const snapshotCards = envelope?.snapshot?.cards;
  const snapshotKey = envelope?.snapshot
    ? `${workspaceId}:${envelope.snapshot.generation}:${envelope.snapshot.generatedAt}`
    : undefined;
  const renderableCards = useMemo(
    () =>
      snapshotCards?.flatMap((card) => {
        const generatedCard = parseRenderableRecommendationCard(card);
        return generatedCard ? [generatedCard] : [];
      }) ?? [],
    [snapshotCards]
  );
  // The rows the rail shows: what the status line counts. A row that stands
  // for a Task is gone once the Task ends, as the card hides it.
  const taskGroup = useProductInboxGroupId(workspaceId);
  const linkedTaskIds = useMemo(
    () =>
      renderableCards.flatMap((card) =>
        card.template === "text-list@1"
          ? card.items.flatMap((item) => linkedRowTask(item)?.conversationId ?? [])
          : []
      ),
    [renderableCards]
  );
  const { summaries: taskSummaries, settled: tasksSettled } = useTaskSummariesState(
    taskGroup,
    linkedTaskIds
  );
  const rowCount = useMemo(
    () =>
      renderableCards.reduce(
        (count, card) =>
          count +
          (card.template === "text-list@1"
            ? card.items.filter((item) => {
                const task = linkedRowTask(item);
                return !task || isTaskRowShown(taskSummaries.get(task.conversationId));
              }).length
            : card.items.length),
        0
      ),
    [renderableCards, taskSummaries]
  );

  // A briefing with no row left to show is cleared. The member who clears the
  // last row of the briefing on screen sees it celebrated once; a briefing that
  // is read already cleared, or published without a card, is not. Rows that
  // stand for Tasks count once the core has settled what it knows of them: a
  // Task the server left out is gone, one still being read is not.
  const shownRows = envelope?.snapshot && tasksSettled ? rowCount : undefined;
  const cleared = shownRows === 0;
  const seenCardsRef = useRef<{ count: number; snapshotKey: string }>(undefined);
  const [celebratedKey, setCelebratedKey] = useState<string>();
  useLayoutEffect(() => {
    const seen = seenCardsRef.current;
    seenCardsRef.current =
      snapshotKey !== undefined && shownRows !== undefined
        ? { count: shownRows, snapshotKey }
        : undefined;
    if (seen && seen.snapshotKey === snapshotKey && seen.count > 0 && shownRows === 0)
      setCelebratedKey(snapshotKey);
    // Another briefing (or workspace) on screen ends the celebration, so
    // coming back to the cleared one does not throw the confetti again.
    else if (seen?.snapshotKey !== snapshotKey) setCelebratedKey(undefined);
  }, [shownRows, snapshotKey]);

  // Each new briefing (another generation) is announced once.
  const shownGeneration = envelope?.snapshot?.generation ?? null;
  useEffect(() => {
    if (envelope) noteGeneration(envelope);
  }, [envelope, noteGeneration, shownGeneration]);

  // Coming back to the window reads the briefing again when it is a minute old.
  useEffect(() => {
    if (!active) return undefined;
    const revisit = () => {
      if (document.visibilityState === "visible")
        void call("recommendations.revisit", {}).catch(() => undefined);
    };
    document.addEventListener("visibilitychange", revisit);
    window.addEventListener("focus", revisit);
    return () => {
      document.removeEventListener("visibilitychange", revisit);
      window.removeEventListener("focus", revisit);
    };
  }, [active, call]);

  const refresh = async () => {
    if (isRefreshing) return;
    try {
      const result = await call("recommendations.refresh", { workspace: workspaceId });
      if (result.rateLimited)
        toast.error(messages.recommendations_title(), {
          id: `routine-refresh-refused:${workspaceId}`,
          description: messages.recommendations_rate_limited(),
          testId: "routine-problem-toast",
        });
    } catch {
      // The core says it failed (`failure`); the header refresh stays the way back.
    }
  };

  // The member does not want to hear about this item again; the core shows the
  // briefing the server answers, without it. Says whether the server took it.
  const dismiss = async (item: RecommendationSourceItem) => {
    try {
      await call("recommendations.dismiss", { workspace: workspaceId, ...item });
      return true;
    } catch {
      toast.error(messages.recommendations_title(), {
        id: `routine-dismiss-failed:${workspaceId}`,
        description: messages.recommendations_dismiss_failed(),
        testId: "routine-problem-toast",
      });
      return false;
    }
  };

  const sources = envelope?.settings.sources ?? [];
  const performAction = (
    action: RecommendationAction,
    card: Pick<RecommendationCard, "sourceIds"> = { sourceIds: [] }
  ) => {
    if (action.type === "open_url") {
      onOpenUrl(action.href);
      return;
    }
    // Every prompt action stages its text in the composer; the user decides
    // whether to send. Nothing goes to Comma without an explicit send from the input.
    const member = action.type === "send_to_comma" ? action : undefined;
    onUsePrompt({
      source:
        resolveRecommendationSource(sources, member?.sourceId) ??
        (card.sourceIds.length === 1
          ? resolveRecommendationSource(sources, card.sourceIds[0])
          : undefined),
      sourceUrl: member?.sourceUrl,
      text: recommendationComposerText(action, messages),
    });
  };

  // A briefing link answers a right-click with the same menu chat gives its
  // links, because it is the same gesture on the same kind of target.
  const handleContextMenuCapture = useCallback(
    (event: ReactMouseEvent<HTMLElement>) => {
      const url = resolveRecommendationLinkFromEventTarget(
        event.target,
        event.currentTarget
      );
      if (!url) return;

      event.preventDefault();
      linkMenuUrlRef.current = url;
      openLinkMenuAtPointer(
        event.currentTarget,
        event.clientX,
        event.clientY,
        event.target instanceof Element ? event.target : event.currentTarget
      );
    },
    [openLinkMenuAtPointer]
  );

  const handleLinkMenuAction = useCallback(
    (action: LinkContextMenuAction) => {
      const url = linkMenuUrlRef.current;
      if (!url) return;

      if (action === "open-external-browser") {
        void openNativePlatformExternalUrl(url);
        return;
      }
      if (action === "open-in-comma") {
        onOpenUrl(url);
        return;
      }
      if (action === "copy-link")
        void copyWithFeedback(() => nativePlatformClipboard.writeText(url), messages);
    },
    [onOpenUrl, messages]
  );

  const handleLinkMenuOpenChange = useCallback(
    (open: boolean) => {
      const changed = setLinkMenuOpen(open);
      if (!open && changed) linkMenuUrlRef.current = null;
    },
    [setLinkMenuOpen]
  );

  // A source only the member can repair stays named here until a read succeeds.
  // It is the one Routine failure the member can act on, so it is not a toast.
  const reconnectNames =
    envelope?.settings.sources
      .filter((source) => source.needsReconnect)
      .map((source) => source.appName) ?? [];
  const reconnectNotice =
    reconnectNames.length > 0 ? (
      <div
        className="comma-recommendations-reconnect"
        data-testid="routine-reconnect-notice"
      >
        <p className="comma-recommendations-empty-copy">
          {messages.recommendations_source_needs_reconnect({
            names: new Intl.ListFormat(locale, { type: "conjunction" }).format(
              reconnectNames
            ),
          })}
        </p>
        {onConnectApps ? (
          <Button
            className="h-7 shrink-0 px-lg"
            hierarchy="secondary-gray"
            onPress={onConnectApps}
            size="sm"
          >
            {messages.plugins_reconnect()}
          </Button>
        ) : null}
      </div>
    ) : null;

  // A briefing that the last run could not replace, or that is more than a day
  // old, says when it was made, so it does not pass for today's. It is a date,
  // not a problem notice.
  const generatedAt = envelope?.snapshot?.generatedAt;
  const staleSince =
    generatedAt !== undefined &&
    (envelope?.state === "stale" || uiClock.now() - generatedAt > STALE_BRIEFING_MS)
      ? new Intl.DateTimeFormat(locale, {
          month: "short",
          day: "numeric",
          hour: "2-digit",
          minute: "2-digit",
        }).format(generatedAt)
      : undefined;

  // Over a briefing the heading says what is left to do; with none to show
  // it names the rail.
  const routinesToolbar = (
    <RoutinesToolbar
      // An unreadable projection lists no sources; refresh is the way back.
      isRefreshDisabled={isRefreshing || (!canRefresh && failure !== "unavailable")}
      // Only a briefing on screen swaps its skeleton for the spinner; with no
      // briefing yet the rail keeps its loading and generating states.
      isRefreshing={isRefreshing && Boolean(envelope?.snapshot)}
      onRefresh={() => void refresh()}
      status={
        !envelope?.snapshot
          ? messages.recommendations_title()
          : cleared
            ? messages.recommendations_status_cleared()
            : shownRows !== undefined && shownRows > 0
              ? messages.recommendations_status_count({ count: shownRows })
              : messages.recommendations_title()
      }
    />
  );

  return (
    <RecommendationLinkPreviewProvider boundaryRef={railRef} workspaceId={workspaceId}>
      <div
        className="comma-recommendations"
        data-state={isRefreshing ? "refreshing" : (envelope?.state ?? "loading")}
        onContextMenuCapture={handleContextMenuCapture}
        ref={railRef}
      >
        {isRefreshing || initialLoading ? (
          <output className="app-sr-only">
            {isRefreshing
              ? messages.recommendations_refreshing()
              : messages.common_loading()}
          </output>
        ) : null}
        {envelope?.snapshot || initialLoading ? (
          <ScrollArea
            className="comma-recommendations-scroll"
            // Cleared, the content fills the rail: its copy sits in the middle
            // of what the cards left, and the burst has the whole rail.
            contentClassName={
              cleared && !initialLoading
                ? "comma-recommendations-content comma-recommendations-content-cleared"
                : "comma-recommendations-content"
            }
            edgeEffect="mask"
            orientation="vertical"
            scrollbarVisibility="scroll"
          >
            {reconnectNotice}
            <div className="comma-recommendations-header">
              {/* The greeting is the client's, not the briefing's: it is there
                  before the first read answers. */}
              <h1 className="comma-recommendations-greeting">
                {greetingName
                  ? briefingGreeting(messages, greetingName)
                  : messages.recommendations_fallback_title()}
              </h1>
              {routinesToolbar}
            </div>
            {staleSince ? (
              <p
                className="comma-recommendations-stale"
                data-testid="routine-stale-notice"
              >
                {messages.recommendations_stale({ time: staleSince })}
              </p>
            ) : null}
            {initialLoading ? (
              // The briefing is not on screen yet: its cards give way to their
              // shape until the first read answers.
              <RecommendationsSkeleton
                groups={cardSkeletonLines}
                testId="recommendations-loading"
              />
            ) : cleared ? (
              <RoutinesCleared celebrate={celebratedKey === snapshotKey} />
            ) : (
              renderableCards.map((card) => (
                <RecommendationGeneratedCardView
                  card={card}
                  key={card.id}
                  onAction={(action) => performAction(action, card)}
                  onDismiss={dismiss}
                  onOpenTask={onOpenTask}
                  onOpenUrl={onOpenUrl}
                  sources={envelope?.settings.sources ?? []}
                />
              ))
            )}
          </ScrollArea>
        ) : (
          // No briefing to show. An unreadable projection keeps only the rail
          // header.
          <>
            {reconnectNotice}
            {routinesToolbar}
            {isRefreshing ? (
              // A refresh is generating from the moment the member asks for
              // it: the request itself collects the sources before the server
              // reports the run, and the rail must not keep the failure copy
              // on screen through that.
              <RecommendationsEmptyState
                sources={envelope?.settings.sources}
                testId="recommendations-generating"
              >
                <p className="comma-recommendations-empty-copy comma-recommendations-generating comma-shiny-text">
                  {messages.recommendations_generating()}
                </p>
              </RecommendationsEmptyState>
            ) : !envelope ? null : discoveringSources ? (
              <RecommendationsEmptyState
                sources={envelope.settings.sources}
                testId="recommendations-discovering"
              >
                <p className="comma-recommendations-empty-copy">
                  {messages.recommendations_discovering_sources()}
                </p>
              </RecommendationsEmptyState>
            ) : canRefresh ? (
              <RecommendationsEmptyState
                sources={envelope?.settings.sources}
                testId="recommendations-ready"
              >
                <p className="comma-recommendations-empty-copy">
                  {envelope.lastError === "renderer_declined"
                    ? messages.recommendations_nothing_new()
                    : messages.recommendations_ready()}
                </p>
              </RecommendationsEmptyState>
            ) : (
              <RecommendationsEmptyState
                sources={envelope?.settings.sources}
                testId="recommendations-empty"
              >
                <p className="comma-recommendations-empty-copy">
                  {messages.recommendations_empty()}
                </p>
                {onConnectApps ? (
                  <Button
                    className="comma-recommendations-empty-action h-7 px-lg"
                    hierarchy="secondary-gray"
                    onPress={onConnectApps}
                    size="sm"
                  >
                    {messages.recommendations_connect_apps()}
                  </Button>
                ) : null}
              </RecommendationsEmptyState>
            )}
          </>
        )}
        <LinkContextMenu
          isOpen={isLinkMenuOpen}
          labels={{
            ariaLabel: messages.chat_link_menu(),
            copyLink: messages.chat_copy_link(),
            openInComma: messages.chat_open_in_comma(),
            openInExternalBrowser: messages.chat_open_in_external_browser(),
          }}
          onAction={handleLinkMenuAction}
          onOpenChange={handleLinkMenuOpenChange}
          pointerOffsets={linkMenuPointerOffsets}
          triggerRef={railRef}
        />
      </div>
    </RecommendationLinkPreviewProvider>
  );
});

// Decorative sample of the apps Comma briefs from, shown before any source is
// connected; once sources exist their own marks are shown instead.
const sampleSourceLogos = [
  <LinearProviderLogo key="linear" />,
  <SlackProviderLogo key="slack" />,
  <GithubProviderLogo key="github" />,
  <GoogleDriveProviderLogo key="google-drive" />,
];
const maxEmptyStateSourceLogos = sampleSourceLogos.length;

// Centered rail copy that mirrors the Tasks rail's empty state: a short
// stack of app marks, one line of copy and an optional action.
function RecommendationsEmptyState({
  children,
  sources,
  testId,
}: {
  children: ReactNode;
  sources: readonly RecommendationSource[] | undefined;
  testId: string;
}) {
  const connectedSources = (sources ?? [])
    .filter((source) => source.enabled)
    .slice(0, maxEmptyStateSourceLogos);
  return (
    <div className="comma-recommendations-empty-state" data-testid={testId}>
      <div aria-hidden="true" className="comma-recommendations-empty-logos">
        {connectedSources.length > 0
          ? connectedSources.map((source) => (
              <LinkProviderIcon key={source.connectionId} source={source} />
            ))
          : sampleSourceLogos}
      </div>
      {children}
    </div>
  );
}

// Line widths for the briefing's placeholder: one group per card (its title,
// then its rows).
const cardSkeletonLines = [
  ["w-1/3", "w-5/6", "w-3/4", "w-2/5"],
  ["w-1/4", "w-2/3", "w-5/6"],
  ["w-1/3", "w-3/4", "w-1/2"],
] as const;

// The briefing's shape while a refresh regenerates it, in the command palette
// preview's skeleton (TaskConversationPreview): pulsing rounded bars, grouped
// the way the lines they stand in for are grouped. The rail's own status line
// announces the refresh, so the bars stay out of the accessibility tree.
function RecommendationsSkeleton({
  groups,
  testId,
}: {
  groups: readonly (readonly string[])[];
  testId?: string;
}) {
  return (
    <div
      aria-hidden="true"
      className="flex flex-col gap-2xl motion-safe:animate-pulse"
      data-testid={testId}
    >
      {groups.map((widths, group) => (
        <div className="flex flex-col items-start gap-sm" key={group}>
          {widths.map((width, line) => (
            <span className={`h-3 rounded-full bg-quaternary ${width}`} key={line} />
          ))}
        </div>
      ))}
    </div>
  );
}

// The rail's heading row: what the Routines hold now, and the refresh that
// asks for a new briefing, on one line.
function RoutinesToolbar({
  isRefreshDisabled,
  isRefreshing,
  onRefresh,
  status,
}: {
  isRefreshDisabled: boolean;
  /** The refresh control turns into a spinner instead of the briefing turning into a skeleton. */
  isRefreshing: boolean;
  onRefresh: () => void;
  /** The heading: the rail's name, or how many cards are left to handle. */
  status: string;
}) {
  const messages = useCommaMessages();
  return (
    <div className="comma-recommendations-heading">
      <h2>{status}</h2>
      <Tooltip content={messages.recommendations_refresh_tooltip()} placement="bottom">
        <ShellIconButtonControl
          aria-label={messages.common_refresh()}
          className="comma-recommendations-refresh-control"
          data-no-press-feedback
          icon={
            isRefreshing ? (
              <LoadingCircleIcon className="comma-input-icon motion-safe:animate-spin" />
            ) : (
              <ReloadIcon className="comma-input-icon" />
            )
          }
          isDisabled={isRefreshDisabled}
          onPress={onRefresh}
        />
      </Tooltip>
    </div>
  );
}

export function RecommendationCardView({
  card,
  onAction,
  onOpenTask,
  onOpenUrl,
  sources = [],
}: {
  card: RecommendationCard;
  onAction: (action: RecommendationAction) => void;
  onOpenTask: (conversationId: string) => void;
  onOpenUrl: (url: string) => void;
  sources?: readonly RecommendationSource[];
}) {
  const known = parseRenderableRecommendationCard(card);

  if (!known) {
    return <RecommendationFallbackCardView card={card} sources={sources} />;
  }

  return (
    <RecommendationGeneratedCardView
      card={known}
      onAction={onAction}
      onOpenTask={onOpenTask}
      onOpenUrl={onOpenUrl}
      sources={sources}
    />
  );
}

function RecommendationFallbackCardView({
  card,
  sources,
}: {
  card: RecommendationCard;
  sources: readonly RecommendationSource[];
}) {
  // Isolated compatibility surfaces show only server-authored inert text.
  // They never reinterpret unregistered data or invent an action.
  const origin = recommendationCardOrigin(card, sources);
  return (
    <div
      aria-label={origin.name}
      className="comma-recommendation-card"
      data-template="fallback"
      role="group"
    >
      <article className="comma-recommendation-task-card">
        <p className="comma-recommendation-task-objective">{card.fallbackText}</p>
        <RecommendationSourceOrigin {...origin} />
      </article>
    </div>
  );
}

function RecommendationGeneratedCardView({
  card,
  onAction,
  onDismiss,
  onOpenTask,
  onOpenUrl,
  sources,
}: {
  card: RecommendationGeneratedCard;
  onAction: (action: RecommendationAction) => void;
  onDismiss?: RecommendationDismiss | undefined;
  onOpenTask: (conversationId: string) => void;
  onOpenUrl: (url: string) => void;
  sources: readonly RecommendationSource[];
}) {
  return card.template === "media-list@1" ? (
    <RecommendationMediaListCard card={card} onAction={onAction} sources={sources} />
  ) : (
    <RecommendationTextListCard
      card={card}
      onAction={onAction}
      onDismiss={onDismiss}
      onOpenTask={onOpenTask}
      onOpenUrl={onOpenUrl}
      sources={sources}
    />
  );
}

export function RecommendationTextListCard({
  card,
  onAction,
  onDismiss,
  onOpenTask,
  onOpenUrl,
  sources = [],
}: {
  card: Extract<RecommendationGeneratedCard, { template: "text-list@1" }>;
  onAction: (action: RecommendationAction) => void;
  onDismiss?: RecommendationDismiss | undefined;
  onOpenTask: (conversationId: string) => void;
  onOpenUrl: (url: string) => void;
  sources?: readonly RecommendationSource[];
}) {
  const origin = recommendationCardOrigin(card, sources);
  // Each row is a card of its own in the rail's column; the source card only
  // groups them and names their source on each one.
  return (
    <div
      aria-label={origin.name}
      className="comma-recommendation-card"
      data-template={card.template}
      role="group"
    >
      {card.items.map((item) => {
        const task = linkedRowTask(item);
        const row = (
          <RecommendationTextItem
            item={item}
            key={item.id}
            onAction={onAction}
            onDismiss={onDismiss}
            onOpenTask={onOpenTask}
            onOpenUrl={onOpenUrl}
            origin={origin}
            sources={sources}
          />
        );
        return task ? (
          <VisibleRecommendationTaskRow key={item.id} id={task.conversationId}>
            {row}
          </VisibleRecommendationTaskRow>
        ) : (
          row
        );
      })}
      {card.footerAction ? (
        <button
          aria-label={card.footerAction.label}
          className="comma-recommendation-task-card comma-recommendation-footer-action"
          onClick={() => onAction(card.footerAction!)}
          type="button"
        >
          <span className="comma-recommendation-task-objective">
            {card.footerAction.label}
          </span>
          <RecommendationSourceOrigin {...origin} />
        </button>
      ) : null}
    </div>
  );
}

type RecommendationTextListItem = Extract<
  RecommendationGeneratedCard,
  { template: "text-list@1" }
>["items"][number];

/** The source item a row stands for: what the member dismisses. */
export type RecommendationSourceItem = { sourceId: string; sourceUrl: string };

/** Dismisses a row's source item; resolves whether the server took it. */
type RecommendationDismiss = (item: RecommendationSourceItem) => Promise<boolean>;

// A dismissed row leaves before the briefing comes back without it: it fades
// and shrinks where it sits, then gives up its place at once while everything
// below glides up from where it was (only transform and opacity animate, so no
// frame lays out the rail). A source left with no other row gives up its place
// as a whole, taking the column's gap with it. Resolves once the place is
// given up, so the dismissal goes out while the glide plays, with what puts
// the row back when the server refuses. Reduced motion keeps only the fade.
async function leaveRecommendationRow(row: HTMLElement): Promise<() => void> {
  if (typeof row.animate !== "function") return () => {};
  const reduced = isReducedMotionEnabled();
  const source = row.parentElement;
  const place = source?.childElementCount === 1 ? source : row;
  const animations: Animation[] = [];
  const restore = () => {
    for (const animation of animations) animation.cancel();
    place.style.removeProperty("display");
  };
  const fade = row.animate(
    reduced
      ? [{ opacity: 1 }, { opacity: 0 }]
      : [
          { opacity: 1, transform: "scale(1)" },
          { opacity: 0, transform: `scale(${motionScale.routineDismiss})` },
        ],
    {
      duration: motionDuration.routineDismissFade,
      easing: motionEasing.smoothOut,
      fill: "forwards",
    }
  );
  animations.push(fade);
  try {
    await fade.finished;
  } catch {
    // Cancelled: the row is gone already.
    return restore;
  }
  if (reduced) {
    place.style.display = "none";
    return restore;
  }
  // What sits below the row inside the rail's content moves up by its place.
  const below: HTMLElement[] = [];
  for (
    let node: Element | null = place;
    node && !node.classList.contains("comma-recommendations-content");
    node = node.parentElement
  )
    for (let next = node.nextElementSibling; next; next = next.nextElementSibling)
      if (next instanceof HTMLElement) below.push(next);
  const before = below.map((element) => element.getBoundingClientRect().top);
  place.style.display = "none";
  const glides = below.flatMap((element, index) => {
    const shift = before[index]! - element.getBoundingClientRect().top;
    return shift
      ? [
          element.animate(
            [{ transform: `translateY(${shift}px)` }, { transform: "translateY(0)" }],
            {
              // Added to a glide still under way from an earlier dismissal,
              // so that one finishes its own way instead of jumping.
              composite: "add",
              duration: motionDuration.routineDismissClose,
              easing: motionEasing.spatialMove,
            }
          ),
        ]
      : [];
  });
  animations.push(...glides);
  return restore;
}

// A row names its source item with its source link. A row that stands for an
// existing Task leaves with that Task instead.
function rowSourceItem(
  item: RecommendationTextListItem
): RecommendationSourceItem | undefined {
  if (linkedRowTask(item)) return undefined;
  for (const part of item.parts) {
    if (part.kind === "inline-link" && part.link.sourceId)
      return { sourceId: part.link.sourceId, sourceUrl: part.link.href };
  }
  return undefined;
}

// A member row's prompt is the member's own task title, then its source URL.
// Sent as is, the imperative would hand the member's part, such as a decision,
// to Comma. The composer asks Comma for help with it in the member's first person.
function recommendationComposerText(
  action: Extract<RecommendationAction, { prompt: string }>,
  messages: ReturnType<typeof useCommaMessages>
) {
  if (action.type !== "send_to_comma" || !action.memberTask) return action.prompt;
  // "Decide whether..." follows "Help me" in lower case. A leading name such
  // as "GitHub" or "PR" keeps its case.
  const task = action.prompt.replace(/^[A-Z](?=[a-z]+\b)/, (letter) =>
    letter.toLowerCase()
  );
  return messages.recommendations_task_request({ task });
}

// The server turns every row into a prompt, except a row that stands for an
// existing Task (mail with a confirmed Task): that row keeps a source link
// action and names exactly one Task. It opens the Task and leaves once the Task
// ends. Its chip may sit inside a sentence. A prompt row that only mentions a
// Task keeps its prompt.
function linkedRowTask(item: RecommendationTextListItem) {
  if (item.action.type !== "open_url") return undefined;
  const tasks = item.parts.filter(
    (part): part is Extract<RecommendationDocumentPart, { kind: "inline-task" }> =>
      part.kind === "inline-task"
  );
  return tasks.length === 1 ? tasks[0]!.task : undefined;
}

// A row is a card that shows what its hover card used to: the task, the quoted
// source words as its evidence, then the source. The card is one target with
// one action, so a full-bleed button underneath carries the press. Links in the
// quote, inline chips and the dismiss control sit above it and take their own
// pointer events back.
function RecommendationTextItem({
  item,
  onAction,
  onDismiss,
  onOpenTask,
  onOpenUrl,
  origin,
  sources,
}: {
  item: RecommendationTextListItem;
  onAction: (action: RecommendationAction) => void;
  onDismiss?: RecommendationDismiss | undefined;
  onOpenTask: (conversationId: string) => void;
  onOpenUrl: (url: string) => void;
  origin: RecommendationOrigin;
  sources: readonly RecommendationSource[];
}) {
  const messages = useCommaMessages();
  const sourceItem = onDismiss ? rowSourceItem(item) : undefined;
  const rowRef = useRef<HTMLDivElement>(null);
  const [leaving, setLeaving] = useState(false);
  // The row fades out first and is dismissed once it has given up its place;
  // a refusal brings it back.
  const leave = async () => {
    if (!sourceItem || !onDismiss || leaving) return;
    setLeaving(true);
    const restore = rowRef.current
      ? await leaveRecommendationRow(rowRef.current)
      : () => {};
    if (await onDismiss(sourceItem)) return;
    restore();
    setLeaving(false);
  };
  // A row that is only its source link is the member's task: the card leads
  // with the task's objective (the link's label without one), then quotes the
  // source words.
  const sourceLink =
    item.parts.length === 1 && item.parts[0]?.kind === "inline-link"
      ? item.parts[0].link
      : undefined;
  const linkedTask = linkedRowTask(item);

  return (
    <div
      className="comma-recommendation-task-card comma-recommendation-text-item"
      inert={leaving}
      ref={rowRef}
    >
      <button
        aria-label={linkedTask?.label ?? item.action.label}
        className="comma-recommendation-text-item-action"
        onClick={() =>
          linkedTask ? onOpenTask(linkedTask.conversationId) : onAction(item.action)
        }
        type="button"
      />
      {sourceLink ? (
        <p className="comma-recommendation-task-objective">
          {sourceLink.objective ?? sourceLink.label}
        </p>
      ) : (
        <RecommendationDocument
          className="comma-recommendation-task-objective comma-recommendation-text-item-content"
          onAction={onAction}
          fallbackAction={item.action}
          onOpenTask={onOpenTask}
          onOpenUrl={onOpenUrl}
          parts={item.parts}
          sources={sources}
        />
      )}
      {sourceLink?.quote ? (
        <blockquote
          aria-label={messages.recommendations_source_context()}
          className="comma-recommendation-source-detail"
        >
          <SourceContext lines={sourceLink.quote} onOpenUrl={onOpenUrl} />
        </blockquote>
      ) : null}
      <RecommendationSourceOrigin {...origin} />
      {sourceItem && onDismiss ? (
        <Tooltip content={messages.recommendations_dismiss()} placement="top">
          <AriaButton
            aria-label={messages.recommendations_dismiss()}
            className="comma-recommendation-row-dismiss"
            data-testid="routine-row-dismiss"
            onPress={() => void leave()}
          >
            <CircleMinusOutlineIcon aria-hidden="true" />
          </AriaButton>
        </Tooltip>
      ) : null}
    </div>
  );
}

export function RecommendationMediaListCard({
  card,
  onAction,
  sources = [],
}: {
  card: Extract<RecommendationGeneratedCard, { template: "media-list@1" }>;
  onAction: (action: RecommendationAction) => void;
  sources?: readonly RecommendationSource[];
}) {
  const origin = recommendationCardOrigin(card, sources);
  return (
    <div
      aria-label={origin.name}
      className="comma-recommendation-card"
      data-template={card.template}
      role="group"
    >
      {card.items.map((item) => (
        <RecommendationMediaItem
          item={item}
          key={item.id}
          onAction={onAction}
          origin={origin}
        />
      ))}
    </div>
  );
}

function parseRenderableRecommendationCard(
  card: RecommendationCard
): RecommendationGeneratedCard | undefined {
  // Keep this check independent from the shared parser: Vite can retain an older
  // optimized workspace dependency while hot-reloading this component.
  if (card.template !== "text-list@1" && card.template !== "media-list@1") {
    return undefined;
  }
  const parsed = recommendationGeneratedCardSchema.safeParse(card);
  if (!parsed.success) return undefined;
  const known = parsed.data;
  if (
    known.items.some((item) => !hasRenderableAction(item)) ||
    ("footerAction" in known &&
      known.footerAction !== undefined &&
      !isRenderableAction(known.footerAction))
  ) {
    return undefined;
  }
  return known;
}

function hasRenderableAction(
  value: unknown
): value is { action: RecommendationAction } {
  if (!value || typeof value !== "object" || !("action" in value)) return false;
  return isRenderableAction(value.action);
}

function isRenderableAction(value: unknown): value is RecommendationAction {
  if (!value || typeof value !== "object") return false;
  if (!("type" in value) || !("label" in value) || !("requiresConfirmation" in value)) {
    return false;
  }
  if (
    typeof value.label !== "string" ||
    value.label.length === 0 ||
    typeof value.requiresConfirmation !== "boolean"
  ) {
    return false;
  }

  if (value.type === "open_url") {
    return "href" in value && typeof value.href === "string";
  }
  if (value.type === "open_task_form" || value.type === "send_to_comma") {
    return "prompt" in value && typeof value.prompt === "string";
  }
  return false;
}

function RecommendationMediaItem({
  item,
  onAction,
  origin,
}: {
  item: Extract<RecommendationCard, { template: "media-list@1" }>["items"][number];
  onAction: (action: RecommendationAction) => void;
  origin: RecommendationOrigin;
}) {
  const safeImageUrl = useLinkPreviewMediaUrl(item.imageUrl);
  return (
    <button
      className="comma-recommendation-task-card comma-recommendation-media-item"
      data-has-image={safeImageUrl ? "true" : "false"}
      onClick={() => onAction(item.action)}
      type="button"
    >
      <span className="comma-recommendation-media-item-body">
        {safeImageUrl ? <img alt="" src={safeImageUrl} /> : null}
        <span>
          <strong>{item.title}</strong>
          {item.description ? <small>{item.description}</small> : null}
        </span>
      </span>
      <RecommendationSourceOrigin {...origin} />
    </button>
  );
}

// Hovering an inline link chip previews where it goes. A link the server can
// read opens on the rich card's skeleton and settles into the per-kind card
// once the workspace API answers; every other link — and any failed read —
// shows the generic destination tile (source mark, link label, app ·
// host/path).
function RecommendationLinkHoverCard({
  children,
  link,
  source,
  onOpenUrl,
}: {
  children: ReactElement;
  onOpenUrl: (url: string) => void;
  link: {
    href: string;
    label: string;
    sourceId?: string | undefined;
    objective?: string | undefined;
    quote?: readonly RecommendationQuoteLine[] | undefined;
  };
  source: RecommendationSource | undefined;
}) {
  const messages = useCommaMessages();
  const previewContext = useContext(RecommendationLinkPreviewContext);
  // Read lazily, once the card first opens; an excerpt admitted with the snapshot needs none.
  const [preview, handleOpenChange] = useLinkPreview(
    previewContext && !link.quote
      ? {
          workspaceId: previewContext.workspaceId,
          href: link.href,
          sourceId: link.sourceId,
        }
      : undefined
  );

  // This excerpt was admitted with the member snapshot. Render only supported
  // inline tokens, not arbitrary HTML or another provider's fetched preview.
  if (link.quote) {
    return (
      <HoverCard
        boundaryRef={previewContext?.boundaryRef}
        className="comma-recommendation-prompt-hover-card comma-recommendation-source-detail-card"
        content={
          <ScrollArea
            className="comma-recommendation-source-scroll"
            contentClassName="comma-recommendation-source-card"
            orientation="vertical"
            edgeEffect="none"
          >
            {/* The task the link starts leads, as on its Routine card. The
                quoted source words under it are its evidence, and the last
                line names their source. */}
            {link.objective ? (
              <p className="comma-recommendation-task-objective">{link.objective}</p>
            ) : null}
            <blockquote
              aria-label={messages.recommendations_source_context()}
              className="comma-recommendation-source-detail"
            >
              <SourceContext lines={link.quote} onOpenUrl={onOpenUrl} />
            </blockquote>
            <RecommendationSourceOrigin
              name={source?.appName ?? messages.recommendations_source_context()}
              source={source}
            />
          </ScrollArea>
        }
        placement="bottom start"
      >
        {children}
      </HoverCard>
    );
  }

  // Mail is private: there is nothing to preview beyond the label the chip
  // already shows, so a Gmail link never gets a link card.
  if (isPrivateMailLink(link.href, source)) return children;

  const destination = describeLinkDestination(link.href);
  return (
    <HoverCard
      className={
        preview
          ? "comma-recommendation-prompt-hover-card comma-recommendation-link-hover-card comma-recommendation-rich-link-hover-card"
          : "comma-recommendation-prompt-hover-card comma-recommendation-link-hover-card"
      }
      content={
        preview === "loading" ? (
          <LinkPreviewSkeleton />
        ) : preview ? (
          <LinkPreviewCard preview={preview} source={source} />
        ) : (
          <div className="comma-recommendation-link-preview">
            <span
              aria-hidden="true"
              className="comma-recommendation-link-preview-thumb"
            >
              <LinkProviderIcon source={source} />
            </span>
            <div className="comma-recommendation-link-preview-body">
              <strong>{link.label}</strong>
              <span className="comma-recommendation-link-preview-url" title={link.href}>
                {source?.appName ? `${source.appName} · ${destination}` : destination}
              </span>
            </div>
          </div>
        )
      }
      onOpenChange={handleOpenChange}
      placement="bottom start"
    >
      {children}
    </HoverCard>
  );
}

/** The rail's heading, always "<time-of-day greeting>, <name>". */
export function briefingGreeting(
  messages: ReturnType<typeof useCommaMessages>,
  name: string,
  now: Date = new Date(uiClock.now())
): string {
  const hour = now.getHours();
  if (hour < 12) return messages.recommendations_greeting_morning({ name });
  if (hour < 18) return messages.recommendations_greeting_afternoon({ name });
  return messages.recommendations_greeting_evening({ name });
}

export function RecommendationDocument({
  className,
  onAction,
  fallbackAction,
  onOpenTask,
  onOpenUrl,
  parts,
  sources = [],
}: {
  className?: string;
  onAction?: ((action: RecommendationAction) => void) | undefined;
  /** The action of the row this document fills: a task link chip stages it. */
  fallbackAction?: RecommendationAction | undefined;
  onOpenTask: (conversationId: string) => void;
  onOpenUrl: (url: string) => void;
  parts: readonly RecommendationDocumentPart[];
  sources?: readonly RecommendationSource[];
}) {
  const compiled = useMemo(
    () =>
      compileTrustedInlineDocument(parts, {
        markdownText: (part) => (part.kind === "markdown" ? part.text : undefined),
        renderInline: (part) => {
          if (part.kind === "inline-link") {
            const source = resolveRecommendationSource(sources, part.link.sourceId);
            return (
              <RecommendationLinkHoverCard
                link={part.link}
                onOpenUrl={onOpenUrl}
                source={source}
              >
                <button
                  className="comma-recommendation-inline comma-recommendation-inline-link comma-recommendation-inline-source"
                  data-source-detail={part.link.quote ? "true" : undefined}
                  onClick={() =>
                    part.link.taskPrompt && onAction && fallbackAction
                      ? onAction(fallbackAction)
                      : onOpenUrl(part.link.href)
                  }
                  type="button"
                  {...{ [recommendationLinkHrefAttribute]: part.link.href }}
                >
                  {part.link.sourceId === addedSourceId ? null : (
                    <LinkProviderIcon source={source} />
                  )}
                  <span>{part.link.label}</span>
                </button>
              </RecommendationLinkHoverCard>
            );
          }
          if (part.kind === "inline-task") {
            const source = resolveRecommendationSource(sources, part.task.sourceId);
            const sourceClassName = part.task.sourceId
              ? " comma-recommendation-inline-source"
              : "";
            return (
              <VisibleRecommendationTask id={part.task.conversationId}>
                <button
                  className={`comma-recommendation-inline${sourceClassName}`}
                  onClick={() => onOpenTask(part.task.conversationId)}
                  type="button"
                >
                  {part.task.sourceId ? <LinkProviderIcon source={source} /> : null}
                  <span>{part.task.label}</span>
                </button>
              </VisibleRecommendationTask>
            );
          }
          return null;
        },
      }),
    [fallbackAction, onAction, onOpenTask, onOpenUrl, parts, sources]
  );

  return (
    <div className={className}>
      <MarkdownStream
        animation="none"
        final
        inlineElements={compiled.inlineElements}
        nodes={compiled.nodes}
        streamId="comma-recommendation-document"
      />
    </div>
  );
}

function normalizeRecommendationIntegrationName(value: string | undefined) {
  return normalizeProviderBrandName(value);
}

const builtInRecommendationSources: Readonly<Record<string, RecommendationSource>> = {
  stillfail: {
    appId: "stillfail",
    appName: "Monoid",
    connectionId: "stillfail",
    enabled: true,
    kind: "im_connect",
    label: "Monoid",
  },
};

function resolveRecommendationSource(
  sources: readonly RecommendationSource[],
  sourceId: string | undefined
) {
  if (!sourceId) return undefined;
  return (
    sources.find(
      (source) => source.connectionId === sourceId || source.appId === sourceId
    ) ?? builtInRecommendationSources[sourceId]
  );
}

/**
 * The source of matters the member added through their Router
 * (Comma.Recommendations.add_item/4). No connection stands behind it, so it
 * shows a pin, not a provider mark.
 */
const addedSourceId = "comma-added";

/** The source a Routine card names under its words: its mark and app name. */
type RecommendationOrigin = {
  name: string;
  source: RecommendationSource | undefined;
  added?: boolean;
};

function recommendationCardOrigin(
  card: Pick<RecommendationCard, "sourceIds" | "title">,
  sources: readonly RecommendationSource[]
): RecommendationOrigin {
  return {
    name: recommendationCardDisplayTitle(card, sources),
    added: card.sourceIds.length === 1 && card.sourceIds[0] === addedSourceId,
    source:
      card.sourceIds.length === 1
        ? resolveRecommendationSource(sources, card.sourceIds[0])
        : undefined,
  };
}

function RecommendationSourceOrigin({ added, name, source }: RecommendationOrigin) {
  return (
    <span className="comma-recommendation-source-origin">
      <span aria-hidden="true" className="comma-recommendation-source-origin-mark">
        {added ? <PinIcon /> : <LinkProviderIcon source={source} />}
      </span>
      <span className="comma-recommendation-source-origin-name">{name}</span>
    </span>
  );
}

function recommendationCardDisplayTitle(
  card: Pick<RecommendationCard, "sourceIds" | "title">,
  sources: readonly RecommendationSource[]
) {
  const source =
    card.sourceIds.length === 1
      ? resolveRecommendationSource(sources, card.sourceIds[0])
      : undefined;
  const appId = normalizeRecommendationIntegrationName(source?.appId);
  const title = normalizeRecommendationIntegrationName(card.title);

  if (
    appId === "googlecalendar" &&
    (title === "googlecalendar" || title === "googlecaleandar")
  ) {
    return "Google Calendar";
  }

  return card.title;
}

// A row that stands for a Task shows while the Task is known and still open.
function isTaskRowShown(summary: TaskSummary | undefined) {
  return (
    summary !== undefined &&
    !["completed", "cancelled", "archived", "ready_for_review"].includes(summary.status)
  );
}

function VisibleRecommendationTaskRow({
  id,
  children,
}: {
  id: string;
  children: ReactNode;
}) {
  const context = useContext(RecommendationLinkPreviewContext);
  const group = useProductInboxGroupId(context?.workspaceId);
  const summary = useTaskSummary(context ? group : "", id);
  if (context && !isTaskRowShown(summary)) return null;
  return children;
}

function VisibleRecommendationTask({
  id,
  children,
}: {
  id: string;
  children: ReactNode;
}) {
  const context = useContext(RecommendationLinkPreviewContext);
  const group = useProductInboxGroupId(context?.workspaceId);
  const summary = useTaskSummary(context ? group : "", id);
  const action = useArchiveAction(context ? group : "", id);
  if (!context) return children;
  if (summary?.status === "archived") return null;
  return (
    <TaskArchiveMenu inline action={action}>
      {children}
    </TaskArchiveMenu>
  );
}
