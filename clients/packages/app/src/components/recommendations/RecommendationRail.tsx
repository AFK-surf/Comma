import { SourceContext } from "./SourceContext";
import { useTaskSummary, useArchiveAction } from "../tasks/useTaskArchive";
import { useProductInboxSnapshot } from "../../product-inbox";
import { TaskArchiveMenu } from "@comma/ui";
import type {
  RecommendationAction,
  RecommendationCard,
  RecommendationDocumentPart,
  RecommendationEnvelope,
  RecommendationGeneratedCard,
  RecommendationSource,
} from "@comma/recommendation-contract";
import {
  recommendationGeneratedCardSchema,
  recommendationLimits,
} from "@comma/recommendation-contract";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  CirclePlusIcon,
  DragHandleIcon,
  Dropdown,
  GithubProviderLogo,
  GoogleDriveProviderLogo,
  HoverCard,
  isReducedMotionEnabled,
  subscribeToReducedMotion,
  LinearProviderLogo,
  LinkContextMenu,
  type LinkContextMenuAction,
  MarkdownStream,
  Menu,
  MenuItem,
  MenuPopover,
  motionDuration,
  motionEasing,
  normalizeProviderBrandName,
  ReloadIcon,
  ScrollArea,
  SettingsSliderThreeIcon,
  SlackProviderLogo,
  spacing,
  toast,
  Tooltip,
  useTextEditContextMenuState,
} from "@comma/ui";
import {
  type MouseEvent as ReactMouseEvent,
  type PointerEvent as ReactPointerEvent,
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
import {
  Button as AriaButton,
  Dialog as AriaDialog,
  DialogTrigger,
  type DragAndDropHooks,
  GridList,
  GridListItem,
  useDragAndDrop,
} from "react-aria-components";
import {
  CommaApiError,
  type CommaApiClient,
  type CommaRecommendationLinkPreview,
} from "../../api";
import {
  nativePlatformClipboard,
  openNativePlatformExternalUrl,
} from "../../runtime-chat/nativePlatformActions";
import { ShellIconButtonControl } from "../ShellIconButton";
import {
  boundPointerReorderTranslation,
  cancelFlipAnimations,
  pointerReorderOverdragCap,
  sameStringOrder,
} from "../pointerReorder";
import { compileTrustedInlineDocument } from "../inline-elements/compileTrustedInlineDocument";
import {
  describeLinkDestination,
  isPrivateMailLink,
  LinkPreviewCard,
  LinkPreviewSkeleton,
  LinkProviderIcon,
  useLinkPreviewMediaUrl,
} from "../links/linkPreviewCards";
import {
  hasRecommendationLinkPreview,
  loadRecommendationLinkPreview,
  peekRecommendationLinkPreview,
} from "./linkPreviewCache";
import {
  recommendationLinkHrefAttribute,
  resolveRecommendationLinkFromEventTarget,
} from "./recommendationLinkMenu";

// Inline-link hover cards read their rich preview through the workspace API.
// Provided once by the rail; documents rendered outside it (stories, tests,
// detached cards) keep the generic destination card.
type RecommendationLinkPreviewContextValue = {
  api: CommaApiClient;
  workspaceId: string;
};
const RecommendationLinkPreviewContext = createContext<
  RecommendationLinkPreviewContextValue | undefined
>(undefined);

export function RecommendationLinkPreviewProvider({
  api,
  children,
  workspaceId,
}: RecommendationLinkPreviewContextValue & { children: ReactNode }) {
  const value = useMemo(() => ({ api, workspaceId }), [api, workspaceId]);
  return (
    <RecommendationLinkPreviewContext.Provider value={value}>
      {children}
    </RecommendationLinkPreviewContext.Provider>
  );
}

type RecommendationRailProps = {
  /** The signed-in user's name; greets them by name in the briefing title. */
  greetingName?: string | undefined;
  active?: boolean;
  api: CommaApiClient;
  /** Opens the Plugins route so the user can connect a first app. */
  onConnectApps?: (() => void) | undefined;
  onOpenTask: (conversationId: string) => void;
  onOpenUrl: (url: string) => void;
  onUsePrompt: (prompt: string) => void;
  workspaceId: string;
};

type RoutineCardPreferences = {
  hiddenIds: ReadonlySet<string>;
  order: readonly string[];
  snapshotKey: string;
};

type RoutineDropPosition = "after" | "before";

type RoutinePointerDrag = {
  active: boolean;
  captureTarget: HTMLElement;
  currentClientY: number;
  draggedId: string;
  initialOrder: readonly string[];
  initialTops: ReadonlyMap<string, number>;
  pointerId: number;
  rowHeight: number;
  scrollViewport: HTMLElement | null;
  sourceIndex: number;
  startClientY: number;
  startRowTop: number;
  startScrollTop: number;
  targetIndex: number;
};

const emptyRoutineCardIds: ReadonlySet<string> = new Set<string>();
const routineCardDragType = "application/x-comma-routine-card-id";

function setRoutineDragCursor(active: boolean) {
  if (typeof document === "undefined") return;
  if (active) {
    document.documentElement.setAttribute("data-comma-routine-dragging", "true");
  } else {
    document.documentElement.removeAttribute("data-comma-routine-dragging");
  }
}

function withoutNativePointerDrag<T>(hooks: DragAndDropHooks<T>): DragAndDropHooks<T> {
  const useDraggableItem = hooks.useDraggableItem;
  if (!useDraggableItem) return hooks;

  return {
    ...hooks,
    useDraggableItem(props, state) {
      const result = useDraggableItem(props, state);
      return {
        ...result,
        dragProps: {
          ...result.dragProps,
          draggable: false,
          onDrag: undefined,
          onDragEnd: undefined,
          onDragStart: undefined,
        },
      };
    },
  };
}

export function reconcileRoutineCardOrder(
  currentOrder: readonly string[],
  currentCardIds: readonly string[]
) {
  const currentCardIdSet = new Set(currentCardIds);
  const retained = currentOrder.filter((id) => currentCardIdSet.has(id));
  const retainedSet = new Set(retained);
  return [...retained, ...currentCardIds.filter((id) => !retainedSet.has(id))];
}

export function reorderRoutineCardIds(
  currentOrder: readonly string[],
  draggedIds: Iterable<string>,
  targetId: string,
  dropPosition: RoutineDropPosition
) {
  const draggedIdSet = new Set(draggedIds);
  if (draggedIdSet.size === 0 || draggedIdSet.has(targetId)) return currentOrder;

  const dragged = currentOrder.filter((id) => draggedIdSet.has(id));
  const remaining = currentOrder.filter((id) => !draggedIdSet.has(id));
  const targetIndex = remaining.indexOf(targetId);
  if (dragged.length === 0 || targetIndex === -1) return currentOrder;

  const insertionIndex = targetIndex + (dropPosition === "after" ? 1 : 0);
  return [
    ...remaining.slice(0, insertionIndex),
    ...dragged,
    ...remaining.slice(insertionIndex),
  ];
}

/** Asymptotic ceiling for dragging past the row band, in px. */
export const routineDragOverdragCap = pointerReorderOverdragCap;

/** Rubber-band bounded translation; shared with the icon rail's reorder. */
export const boundRoutineDragTranslation = boundPointerReorderTranslation;

// The daily run publishes while Home may already be open, and the rail only
// polls while a run is active. Coming back to the window re-reads the
// projection at most this often.
const revisitReloadIntervalMs = 60_000;

// The scheduled run starts at the delivery instant and takes about a minute to
// collect and render; one read shortly after that instant picks the new
// briefing up, or finds the run still active and hands over to the poll.
export const deliveryReloadGraceMs = 120_000;

type RecommendationSchedule = RecommendationEnvelope["settings"]["schedule"];

/**
 * Milliseconds from `now` until the next daily delivery instant, read on the
 * schedule's own wall clock. `undefined` when the timezone is unknown to this
 * runtime.
 */
export function msUntilDailyDelivery(
  schedule: Pick<RecommendationSchedule, "hour" | "minute" | "timezone">,
  now: number
): number | undefined {
  const dayMs = 86_400_000;
  try {
    const formatter = new Intl.DateTimeFormat("en-US", {
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      hourCycle: "h23",
      minute: "2-digit",
      second: "2-digit",
      timeZone: schedule.timezone,
    });
    // Encode wall-clock fields as UTC only for calendar arithmetic.
    const wallTime = (instant: number) => {
      const parts = formatter.formatToParts(new Date(instant));
      const read = (type: Intl.DateTimeFormatPartTypes) =>
        Number(parts.find((part) => part.type === type)?.value);
      return Date.UTC(
        read("year"),
        read("month") - 1,
        read("day"),
        read("hour"),
        read("minute"),
        read("second")
      );
    };
    const today = Math.floor(wallTime(now) / dayMs) * dayMs;
    const targetTime = (schedule.hour * 60 + schedule.minute) * 60_000;

    // Examine three calendar days, using offsets on both sides of a possible
    // DST transition. Validate each candidate against the schedule's clock:
    // a missing spring-forward time is skipped, and a repeated time uses
    // the next future occurrence. The third day covers an already-passed
    // target today followed by a missing target tomorrow. No network polling.
    for (const day of [today, today + dayMs, today + 2 * dayMs]) {
      const target = day + targetTime;
      const offsets = new Set(
        [-dayMs, 0, dayMs].map((shift) => wallTime(target + shift) - (target + shift))
      );
      const candidates = [...offsets]
        .map((offset) => target - offset)
        .filter((instant) => instant > now && wallTime(instant) === target);
      if (candidates.length > 0) return Math.min(...candidates) - now;
    }
  } catch {
    return undefined;
  }
  return undefined;
}

// A server-owned run is polled every two seconds. The server keeps a run
// active within its eight-minute queue, collection, and model budget,
// so this budget is not the run's life: a poll that keeps failing for 90
// seconds has lost the projection, not the run.
const maxConsecutivePollFailures = 45;

// Why the rail has no briefing to show: the projection could not be read, a
// manual refresh was refused by the hourly budget, or the server reports that
// the last generation failed.
type RailFailure = "unavailable" | "rate_limited" | undefined;

// Routine failures that the member cannot act on stay out of the UI: the rail
// keeps the last briefing, and the server logs and counts every failed run.
// Only a refused manual refresh answers the member, because they asked for it.

export const RecommendationRail = memo(function RecommendationRail({
  active = true,
  api,
  greetingName,
  onConnectApps,
  onOpenTask,
  onOpenUrl,
  onUsePrompt,
  workspaceId,
}: RecommendationRailProps) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const [envelope, setEnvelope] = useState<RecommendationEnvelope>();
  const [failure, setFailure] = useState<RailFailure>();
  const error = failure !== undefined;
  const [refreshing, setRefreshing] = useState(false);
  const requestRef = useRef(0);
  const lastLoadedAtRef = useRef(0);
  const lastGenerationRef = useRef<number | null>(null);
  const pollFailuresRef = useRef(0);
  const [deliveryReloads, setDeliveryReloads] = useState(0);
  // True while the bounded discovery checks wait for the first source listing.
  const [discoveringSources, setDiscoveringSources] = useState(false);
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
  const sourceRetryRef = useRef(0);
  const sourceRetryTimerRef = useRef<number | undefined>(undefined);
  const serverRefreshingRef = useRef(false);
  const pollRetryTimerRef = useRef<number | undefined>(undefined);
  const canRefresh =
    envelope?.settings.sources.some((source) => source.enabled) === true;
  // A server-owned run stays "generating" only while its projection can still
  // be read; once the poll gives up, the last envelope no longer speaks for it.
  const isRefreshing = refreshing || (envelope?.state === "refreshing" && !error);
  // Until the first read answers, the rail takes a briefing's layout, so the
  // briefing most members have lands where its placeholder was.
  const initialLoading = !envelope && !error && !isRefreshing;
  const briefingPending = isRefreshing || initialLoading;
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
  const renderableCardIds = useMemo(
    () => renderableCards.map((card) => card.id),
    [renderableCards]
  );
  const [cardPreferences, setCardPreferences] = useState<RoutineCardPreferences>(
    () => ({ hiddenIds: emptyRoutineCardIds, order: [], snapshotKey: "" })
  );

  useEffect(() => {
    if (!snapshotKey) return;
    setCardPreferences((current) => {
      if (current.snapshotKey !== snapshotKey) {
        return {
          hiddenIds: new Set<string>(),
          order: renderableCardIds,
          snapshotKey,
        };
      }

      const order = reconcileRoutineCardOrder(current.order, renderableCardIds);
      const currentCardIdSet = new Set(renderableCardIds);
      const hiddenIds = new Set(
        [...current.hiddenIds].filter((id) => currentCardIdSet.has(id))
      );
      if (
        sameStringOrder(order, current.order) &&
        hiddenIds.size === current.hiddenIds.size
      ) {
        return current;
      }
      return { hiddenIds, order, snapshotKey };
    });
  }, [renderableCardIds, snapshotKey]);

  const preferencesMatchSnapshot = cardPreferences.snapshotKey === snapshotKey;
  const effectiveCardOrder = preferencesMatchSnapshot
    ? reconcileRoutineCardOrder(cardPreferences.order, renderableCardIds)
    : renderableCardIds;
  const effectiveHiddenCardIds = preferencesMatchSnapshot
    ? cardPreferences.hiddenIds
    : emptyRoutineCardIds;
  const orderedCards = useMemo(() => {
    const cardsById = new Map(renderableCards.map((card) => [card.id, card]));
    return effectiveCardOrder.flatMap((id) => {
      const card = cardsById.get(id);
      return card ? [card] : [];
    });
  }, [effectiveCardOrder, renderableCards]);

  const setCardVisibility = useCallback(
    (cardId: string, visible: boolean) => {
      if (!snapshotKey) return;
      setCardPreferences((current) => {
        const matchesSnapshot = current.snapshotKey === snapshotKey;
        const hiddenIds = new Set(matchesSnapshot ? current.hiddenIds : []);
        if (visible) hiddenIds.delete(cardId);
        else hiddenIds.add(cardId);
        return {
          hiddenIds,
          order: matchesSnapshot
            ? reconcileRoutineCardOrder(current.order, renderableCardIds)
            : renderableCardIds,
          snapshotKey,
        };
      });
    },
    [renderableCardIds, snapshotKey]
  );

  const setCardOrder = useCallback(
    (nextOrder: readonly string[]) => {
      if (!snapshotKey) return;
      setCardPreferences((current) => {
        const matchesSnapshot = current.snapshotKey === snapshotKey;
        return {
          hiddenIds: matchesSnapshot ? current.hiddenIds : new Set<string>(),
          order: reconcileRoutineCardOrder(nextOrder, renderableCardIds),
          snapshotKey,
        };
      });
    },
    [renderableCardIds, snapshotKey]
  );

  const load = useCallback(async () => {
    if (!active) return undefined;
    const request = ++requestRef.current;
    // Stamp the request, not the response: a window focus during the initial
    // read must not issue a second one.
    lastLoadedAtRef.current = Date.now();
    try {
      const next = await api.getRecommendations(workspaceId, {
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      });
      if (request === requestRef.current) {
        pollFailuresRef.current = 0;
        const generation = next.snapshot?.generation ?? null;
        const generationChanged = generation !== lastGenerationRef.current;
        lastGenerationRef.current = generation;
        setEnvelope(next);
        serverRefreshingRef.current = next.state === "refreshing";
        // A successful read heals an unreadable projection. A refused refresh
        // stays explained until a run starts or a new briefing arrives.
        setFailure((current) =>
          current === "rate_limited" &&
          next.state !== "refreshing" &&
          !generationChanged
            ? current
            : undefined
        );

        // A failed generation is terminal until the member refreshes; the
        // discovery checks are for a projection that is still being prepared.
        const checking =
          sourceRetryRef.current < 10 &&
          next.state !== "refreshing" &&
          next.state !== "error" &&
          (!next.settings.sourcesCheckedAt ||
            (next.snapshot === null &&
              next.settings.sources.some((source) => source.enabled)));
        if (checking) {
          // At most ten discovery/dispatch checks per visible rail mount.
          sourceRetryRef.current += 1;
          sourceRetryTimerRef.current = window.setTimeout(() => void load(), 1_500);
        }
        setDiscoveringSources(checking && !next.settings.sourcesCheckedAt);
      }
      return next;
    } catch {
      if (request === requestRef.current) {
        pollFailuresRef.current += 1;
        if (
          serverRefreshingRef.current &&
          pollFailuresRef.current <= maxConsecutivePollFailures
        ) {
          if (pollRetryTimerRef.current !== undefined) {
            window.clearTimeout(pollRetryTimerRef.current);
          }
          pollRetryTimerRef.current = window.setTimeout(() => void load(), 2_000);
        } else {
          serverRefreshingRef.current = false;
          setFailure("unavailable");
        }
      }
      return undefined;
    }
  }, [active, api, workspaceId]);

  // An app language change regenerates the briefing on the server. Read again
  // at once, so the rail shows that run instead of the old language.
  const readLocaleRef = useRef(locale);
  useEffect(() => {
    if (readLocaleRef.current === locale) return;
    readLocaleRef.current = locale;
    void load();
  }, [load, locale]);

  useEffect(() => {
    if (!active) return undefined;
    void load();
    return () => {
      requestRef.current += 1;
      sourceRetryRef.current = 0;
      if (sourceRetryTimerRef.current !== undefined) {
        window.clearTimeout(sourceRetryTimerRef.current);
      }
      if (pollRetryTimerRef.current !== undefined) {
        window.clearTimeout(pollRetryTimerRef.current);
      }
    };
  }, [active, load]);

  useEffect(() => {
    if (!active || envelope?.state !== "refreshing") return;

    // One bounded request per visible rail every two seconds while the server owns an
    // active run. The server ends every run, including across page reloads: from the
    // 90-second check on, as soon as its renderer goes idle, or at the eight-minute hard cap.
    const timer = window.setTimeout(() => void load(), 2_000);
    return () => window.clearTimeout(timer);
  }, [active, envelope?.state, envelope, load]);

  useEffect(() => {
    if (!active) return undefined;
    const reloadIfStale = () => {
      if (document.visibilityState !== "visible") return;
      if (Date.now() - lastLoadedAtRef.current < revisitReloadIntervalMs) return;
      void load();
    };
    document.addEventListener("visibilitychange", reloadIfStale);
    window.addEventListener("focus", reloadIfStale);
    return () => {
      document.removeEventListener("visibilitychange", reloadIfStale);
      window.removeEventListener("focus", reloadIfStale);
    };
  }, [active, load]);

  const schedule = envelope?.settings.schedule;
  const scheduleEnabled = schedule?.enabled === true;
  const scheduleHour = schedule?.hour;
  const scheduleMinute = schedule?.minute;
  const scheduleTimezone = schedule?.timezone;
  useEffect(() => {
    if (
      !active ||
      !scheduleEnabled ||
      scheduleHour === undefined ||
      scheduleMinute === undefined ||
      scheduleTimezone === undefined
    ) {
      return undefined;
    }
    const delay = msUntilDailyDelivery(
      { hour: scheduleHour, minute: scheduleMinute, timezone: scheduleTimezone },
      Date.now()
    );
    if (delay === undefined) return undefined;
    const timer = window.setTimeout(() => {
      // Counting the reload re-arms this effect for the next day.
      void load().then(() => setDeliveryReloads((count) => count + 1));
    }, delay + deliveryReloadGraceMs);
    return () => window.clearTimeout(timer);
  }, [
    active,
    deliveryReloads,
    load,
    scheduleEnabled,
    scheduleHour,
    scheduleMinute,
    scheduleTimezone,
  ]);

  const refresh = async () => {
    if (isRefreshing) return;
    if (sourceRetryTimerRef.current !== undefined) {
      window.clearTimeout(sourceRetryTimerRef.current);
      sourceRetryTimerRef.current = undefined;
    }
    setRefreshing(true);
    setFailure(undefined);
    try {
      const result = await api.refreshRecommendations(workspaceId);
      lastLoadedAtRef.current = Date.now();
      serverRefreshingRef.current = result.envelope.state === "refreshing";
      setEnvelope(result.envelope);
    } catch (cause) {
      const rateLimited = cause instanceof CommaApiError && cause.status === 429;
      const next = await load();
      if (rateLimited) {
        setFailure("rate_limited");
        toast.error(messages.recommendations_title(), {
          id: `routine-refresh-refused:${workspaceId}`,
          description: messages.recommendations_rate_limited(),
          testId: "routine-problem-toast",
        });
      } else if (!next || next.settings.sources.some((source) => source.enabled)) {
        setFailure("unavailable");
      }
    } finally {
      setRefreshing(false);
    }
  };

  const performAction = (action: RecommendationAction) => {
    if (action.type === "open_url") {
      onOpenUrl(action.href);
      return;
    }
    // Every prompt action fills the composer draft; the user decides whether
    // to send. Nothing goes to Comma without an explicit send from the input.
    onUsePrompt(recommendationComposerText(action, messages));
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
      if (action === "copy-link") void nativePlatformClipboard.writeText(url);
    },
    [onOpenUrl]
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

  const routinesToolbar = (
    <RoutinesToolbar
      cards={orderedCards}
      hiddenCardIds={effectiveHiddenCardIds}
      // An unreadable projection lists no sources; refresh is the way back.
      isRefreshDisabled={isRefreshing || (!canRefresh && failure !== "unavailable")}
      onRefresh={() => void refresh()}
      onOrderChange={setCardOrder}
      onVisibilityChange={setCardVisibility}
      sources={envelope?.settings.sources ?? []}
    />
  );

  return (
    <RecommendationLinkPreviewProvider api={api} workspaceId={workspaceId}>
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
            contentClassName="comma-recommendations-content"
            edgeEffect="mask"
            orientation="vertical"
            scrollbarVisibility="scroll"
          >
            {reconnectNotice}
            <RecommendationSummary
              fallbackTitle={messages.recommendations_fallback_title()}
              greetingName={greetingName}
              onOpenTask={onOpenTask}
              onOpenUrl={onOpenUrl}
              parts={envelope?.snapshot?.summary ?? []}
              pending={briefingPending}
              sources={envelope?.settings.sources ?? []}
            />
            {routinesToolbar}
            {briefingPending ? (
              // The briefing is not on screen yet, or is being replaced: its
              // cards give way to their shape until a briefing is read.
              <RecommendationsSkeleton
                groups={cardSkeletonLines}
                testId={
                  initialLoading
                    ? "recommendations-loading"
                    : "recommendations-refreshing"
                }
              />
            ) : (
              orderedCards
                .filter((card) => !effectiveHiddenCardIds.has(card.id))
                .map((card) => (
                  <RecommendationGeneratedCardView
                    card={card}
                    key={card.id}
                    onAction={performAction}
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

// Line widths for the briefing's placeholder: one group for the summary body,
// and one per card (its title, then its rows).
const summarySkeletonLines = [["w-full", "w-5/6", "w-2/3"]] as const;
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

function RoutinesToolbar({
  cards,
  hiddenCardIds,
  isRefreshDisabled,
  onRefresh,
  onOrderChange,
  onVisibilityChange,
  sources,
}: {
  cards: readonly RecommendationGeneratedCard[];
  hiddenCardIds: ReadonlySet<string>;
  isRefreshDisabled: boolean;
  onRefresh: () => void;
  onOrderChange: (orderedIds: readonly string[]) => void;
  onVisibilityChange: (cardId: string, visible: boolean) => void;
  sources: readonly RecommendationSource[];
}) {
  const messages = useCommaMessages();
  const [isOpen, setIsOpen] = useState(false);
  const cardsRef = useRef(cards);
  cardsRef.current = cards;
  const hasRoutineCards = cards.length > 0;
  const routineScrollViewportRef = useRef<HTMLDivElement>(null);
  const routineListRef = useRef<HTMLDivElement>(null);
  const routineRowRefs = useRef(new Map<string, HTMLElement>());
  const previousRoutineRowTops = useRef(new Map<string, number>());
  const pendingRoutineLayoutAnimation = useRef(false);
  const routinePointerDrag = useRef<RoutinePointerDrag | null>(null);
  const routinePointerFrame = useRef<number | null>(null);
  const visibilityItems = useMemo(
    () => [
      { id: "show", label: messages.recommendations_card_show() },
      { id: "hidden", label: messages.recommendations_card_hidden() },
    ],
    [messages]
  );
  const registerRoutineRow = useCallback(
    (cardId: string, element: HTMLElement | null) => {
      if (element) routineRowRefs.current.set(cardId, element);
      else routineRowRefs.current.delete(cardId);
    },
    []
  );
  const measureRoutineRowTops = useCallback(() => {
    const tops = new Map<string, number>();
    routineRowRefs.current.forEach((element, cardId) => {
      if (element.isConnected) {
        tops.set(cardId, element.getBoundingClientRect().top);
      }
    });
    return tops;
  }, []);
  const animateRoutineRowsFromTops = useCallback(
    (previousTops: ReadonlyMap<string, number>) => {
      const nextTops = measureRoutineRowTops();
      previousRoutineRowTops.current = nextTops;
      pendingRoutineLayoutAnimation.current = false;
      if (isReducedMotionEnabled()) return;

      for (const card of cardsRef.current) {
        const before = previousTops.get(card.id);
        const after = nextTops.get(card.id);
        if (before === undefined || after === undefined || before === after) continue;
        const row = routineRowRefs.current.get(card.id);
        if (row) cancelFlipAnimations(row);
        row?.animate(
          [
            { transform: `translateY(${before - after}px)` },
            { transform: "translateY(0)" },
          ],
          {
            // Travel back into the slot; matches the row's lift-fade transition
            // so the drop reads as one settle.
            duration: motionDuration.spatialMove,
            easing: motionEasing.surfaceSmoothOut,
          }
        );
      }
    },
    [measureRoutineRowTops]
  );
  useLayoutEffect(() => {
    const list = routineListRef.current;
    if (!list) return;

    const observer = new MutationObserver(() => {
      if (!pendingRoutineLayoutAnimation.current) return;
      animateRoutineRowsFromTops(previousRoutineRowTops.current);
    });
    observer.observe(list, { childList: true });
    return () => observer.disconnect();
  }, [animateRoutineRowsFromTops, hasRoutineCards, isOpen]);
  const clearRoutinePointerTransforms = useCallback(() => {
    routineListRef.current?.style.removeProperty("--comma-routines-drag-shift");
    routineRowRefs.current.forEach((row) => {
      row.removeAttribute("data-pointer-dragging");
      row.removeAttribute("data-routine-drag-shift");
      row.style.removeProperty("transform");
    });
  }, []);
  const updateRoutinePointerDrag = useCallback((clientY: number) => {
    const drag = routinePointerDrag.current;
    if (!drag) return;
    drag.currentClientY = clientY;

    let pointerDeltaY = clientY - drag.startClientY;
    if (!drag.active) {
      if (Math.abs(pointerDeltaY) < spacing.xs) return;
      drag.active = true;
      // Consume the activation threshold so the row starts from rest under the
      // pointer instead of jumping by the accumulated slack.
      const consumedThreshold = Math.sign(pointerDeltaY) * spacing.xs;
      drag.startClientY += consumedThreshold;
      pointerDeltaY -= consumedThreshold;
      routineListRef.current?.style.setProperty(
        "--comma-routines-drag-shift",
        `${drag.rowHeight}px`
      );
      setRoutineDragCursor(true);
    }
    const scrollDelta =
      (drag.scrollViewport?.scrollTop ?? drag.startScrollTop) - drag.startScrollTop;
    const translatedY = boundRoutineDragTranslation(
      pointerDeltaY + scrollDelta,
      drag.initialTops,
      drag.startRowTop
    );
    const draggedCenter = drag.startRowTop + pointerDeltaY + drag.rowHeight / 2;
    const remainingOrder = drag.initialOrder.filter((id) => id !== drag.draggedId);
    const targetIndex = remainingOrder.reduce((index, id) => {
      const top = drag.initialTops.get(id);
      return top !== undefined && draggedCenter > top - scrollDelta + drag.rowHeight / 2
        ? index + 1
        : index;
    }, 0);
    drag.targetIndex = targetIndex;

    routineRowRefs.current.forEach((row, cardId) => {
      if (cardId === drag.draggedId) {
        row.setAttribute("data-pointer-dragging", "true");
        row.style.transform = `translate3d(0, ${translatedY}px, 0)`;
        return;
      }

      const index = drag.initialOrder.indexOf(cardId);
      const shiftsUp =
        targetIndex > drag.sourceIndex &&
        index > drag.sourceIndex &&
        index <= targetIndex;
      const shiftsDown =
        targetIndex < drag.sourceIndex &&
        index >= targetIndex &&
        index < drag.sourceIndex;
      if (shiftsUp) row.setAttribute("data-routine-drag-shift", "up");
      else if (shiftsDown) row.setAttribute("data-routine-drag-shift", "down");
      // "none" keeps the shift transition armed: dropping the attribute would
      // fall back to the base rule, which has no transform transition, and the
      // row would snap home instead of gliding when the drag reverses.
      else row.setAttribute("data-routine-drag-shift", "none");
    });
  }, []);
  const queueRoutinePointerDrag = useCallback(
    (clientY: number) => {
      const drag = routinePointerDrag.current;
      if (!drag) return;
      drag.currentClientY = clientY;
      if (routinePointerFrame.current !== null) return;

      const runFrame = () => {
        const current = routinePointerDrag.current;
        if (!current) {
          routinePointerFrame.current = null;
          return;
        }

        updateRoutinePointerDrag(current.currentClientY);
        const viewport = current.scrollViewport;
        let didScroll = false;
        if (current.active && viewport) {
          const bounds = viewport.getBoundingClientRect();
          const edge = spacing["3xl"];
          const maxStep = spacing.md;
          const distanceFromTop = current.currentClientY - bounds.top;
          const distanceFromBottom = bounds.bottom - current.currentClientY;
          const step =
            distanceFromTop < edge
              ? -Math.ceil(maxStep * Math.min(1, (edge - distanceFromTop) / edge))
              : distanceFromBottom < edge
                ? Math.ceil(maxStep * Math.min(1, (edge - distanceFromBottom) / edge))
                : 0;
          if (step !== 0) {
            const before = viewport.scrollTop;
            viewport.scrollTop = Math.max(
              0,
              Math.min(
                viewport.scrollHeight - viewport.clientHeight,
                viewport.scrollTop + step
              )
            );
            didScroll = viewport.scrollTop !== before;
            if (didScroll) updateRoutinePointerDrag(current.currentClientY);
          }
        }

        routinePointerFrame.current = didScroll
          ? requestAnimationFrame(runFrame)
          : null;
      };

      routinePointerFrame.current = requestAnimationFrame(runFrame);
    },
    [updateRoutinePointerDrag]
  );
  const finishRoutinePointerDrag = useCallback(
    (commit: boolean) => {
      const drag = routinePointerDrag.current;
      if (!drag) return;
      if (routinePointerFrame.current !== null) {
        cancelAnimationFrame(routinePointerFrame.current);
        routinePointerFrame.current = null;
        updateRoutinePointerDrag(drag.currentClientY);
      }
      routinePointerDrag.current = null;
      if (drag.captureTarget.hasPointerCapture(drag.pointerId)) {
        drag.captureTarget.releasePointerCapture(drag.pointerId);
      }

      if (!drag.active) {
        clearRoutinePointerTransforms();
        setRoutineDragCursor(false);
        return;
      }

      const visualTops = measureRoutineRowTops();
      routineRowRefs.current.forEach((row) => {
        cancelFlipAnimations(row);
      });
      const remainingOrder = drag.initialOrder.filter((id) => id !== drag.draggedId);
      const nextOrder = [...remainingOrder];
      nextOrder.splice(drag.targetIndex, 0, drag.draggedId);
      clearRoutinePointerTransforms();
      setRoutineDragCursor(false);
      const settlingRow = routineRowRefs.current.get(drag.draggedId);
      if (settlingRow) {
        // The card is still opaque while its lift fades; keep it above the
        // rows it may cross during the settle travel.
        settlingRow.setAttribute("data-routine-drag-settling", "true");
        window.setTimeout(() => {
          settlingRow.removeAttribute("data-routine-drag-settling");
        }, motionDuration.spatialMove);
      }

      if (commit && !sameStringOrder(nextOrder, drag.initialOrder)) {
        previousRoutineRowTops.current = visualTops;
        pendingRoutineLayoutAnimation.current = true;
        onOrderChange(nextOrder);
      } else {
        animateRoutineRowsFromTops(visualTops);
      }
    },
    [
      animateRoutineRowsFromTops,
      clearRoutinePointerTransforms,
      measureRoutineRowTops,
      onOrderChange,
      updateRoutinePointerDrag,
    ]
  );
  const startRoutinePointerDrag = useCallback(
    (cardId: string, event: ReactPointerEvent<HTMLSpanElement>) => {
      if (!event.isPrimary || event.button !== 0 || routinePointerDrag.current) return;
      const row = routineRowRefs.current.get(cardId);
      if (!row) return;

      event.preventDefault();
      event.currentTarget.setPointerCapture(event.pointerId);
      routineRowRefs.current.forEach((routineRow) => {
        cancelFlipAnimations(routineRow);
      });
      const initialOrder = cardsRef.current.map((card) => card.id);
      const initialTops = measureRoutineRowTops();
      const rowBounds = row.getBoundingClientRect();
      const scrollViewport = routineScrollViewportRef.current;
      routinePointerDrag.current = {
        active: false,
        captureTarget: event.currentTarget,
        currentClientY: event.clientY,
        draggedId: cardId,
        initialOrder,
        initialTops,
        pointerId: event.pointerId,
        rowHeight: rowBounds.height,
        scrollViewport,
        sourceIndex: initialOrder.indexOf(cardId),
        startClientY: event.clientY,
        startRowTop: rowBounds.top,
        startScrollTop: scrollViewport?.scrollTop ?? 0,
        targetIndex: initialOrder.indexOf(cardId),
      };
    },
    [measureRoutineRowTops]
  );
  useEffect(() => {
    const cancelFromKeyboard = (event: KeyboardEvent) => {
      if (event.key === "Escape" && routinePointerDrag.current) {
        event.preventDefault();
        event.stopImmediatePropagation();
        finishRoutinePointerDrag(false);
      }
    };
    document.addEventListener("keydown", cancelFromKeyboard, true);
    return () => document.removeEventListener("keydown", cancelFromKeyboard, true);
  }, [finishRoutinePointerDrag]);
  useEffect(() => {
    const drag = routinePointerDrag.current;
    if (
      drag &&
      (!isOpen ||
        !sameStringOrder(
          drag.initialOrder,
          cards.map((card) => card.id)
        ))
    ) {
      finishRoutinePointerDrag(false);
    }
  }, [cards, finishRoutinePointerDrag, isOpen]);
  useEffect(
    () => () => {
      if (routinePointerFrame.current !== null) {
        cancelAnimationFrame(routinePointerFrame.current);
        routinePointerFrame.current = null;
      }
      routinePointerDrag.current = null;
      clearRoutinePointerTransforms();
      setRoutineDragCursor(false);
    },
    [clearRoutinePointerTransforms]
  );
  const { dragAndDropHooks } = useDragAndDrop<RecommendationGeneratedCard>({
    getAllowedDropOperations: () => ["move"],
    getItems: (_keys, items) =>
      items.map((item) => ({
        [routineCardDragType]: item.id,
        "text/plain": recommendationCardDisplayTitle(item, sources),
      })),
    onDragEnd: () => setRoutineDragCursor(false),
    onDragStart: () => setRoutineDragCursor(true),
    onReorder: (event) => {
      const position = event.target.dropPosition;
      if (position !== "before" && position !== "after") return;
      const currentOrder = cardsRef.current.map((card) => card.id);
      const nextOrder = reorderRoutineCardIds(
        currentOrder,
        [...event.keys].map(String),
        String(event.target.key),
        position
      );
      if (sameStringOrder(nextOrder, currentOrder)) return;
      previousRoutineRowTops.current = measureRoutineRowTops();
      pendingRoutineLayoutAnimation.current = true;
      onOrderChange(nextOrder);
    },
  });
  const directManipulationDragAndDropHooks = useMemo(
    () => withoutNativePointerDrag(dragAndDropHooks),
    [dragAndDropHooks]
  );

  return (
    <div className="comma-recommendations-heading">
      <h2>{messages.recommendations_title()}</h2>
      <div className="comma-recommendations-heading-actions">
        <Tooltip
          content={messages.recommendations_refresh_tooltip()}
          placement="bottom"
        >
          <ShellIconButtonControl
            aria-label={messages.common_refresh()}
            className="comma-recommendations-refresh-control"
            data-no-press-feedback
            icon={<ReloadIcon className="comma-input-icon" />}
            isDisabled={isRefreshDisabled}
            onPress={onRefresh}
          />
        </Tooltip>
        <DialogTrigger isOpen={isOpen} onOpenChange={setIsOpen}>
          <Tooltip
            content={messages.recommendations_customize_tooltip()}
            placement="bottom"
          >
            <ShellIconButtonControl
              aria-label={messages.recommendations_customize()}
              className="comma-recommendations-heading-control"
              data-no-press-feedback
              icon={<SettingsSliderThreeIcon className="comma-input-icon" />}
            />
          </Tooltip>
          <MenuPopover
            className="comma-routines-popover"
            offset={spacing.md}
            placement="right top"
          >
            <AriaDialog
              aria-label={messages.recommendations_customize()}
              className="comma-routines-panel"
              data-has-cards={cards.length > 0 ? "true" : "false"}
            >
              {cards.length > 0 ? (
                <ScrollArea
                  className="comma-routines-card-scroll"
                  contentClassName="comma-routines-card-scroll-content"
                  edgeEffect="mask"
                  orientation="vertical"
                  ref={routineScrollViewportRef}
                  scrollbarVisibility="scroll"
                  viewportProps={{ tabIndex: -1 }}
                >
                  <GridList
                    aria-label={messages.recommendations_customize()}
                    className="comma-routines-card-list"
                    dependencies={[hiddenCardIds, sources, visibilityItems]}
                    dragAndDropHooks={directManipulationDragAndDropHooks}
                    items={cards}
                    keyboardNavigationBehavior="tab"
                    ref={routineListRef}
                    selectionMode="none"
                  >
                    {(card) => {
                      const displayTitle = recommendationCardDisplayTitle(
                        card,
                        sources
                      );
                      return (
                        <GridListItem
                          className="comma-routines-card-row"
                          id={card.id}
                          ref={(element) => registerRoutineRow(card.id, element)}
                          textValue={displayTitle}
                        >
                          <span
                            className="comma-routines-card-drag-hit-area"
                            onLostPointerCapture={(event) => {
                              if (
                                routinePointerDrag.current?.pointerId ===
                                event.pointerId
                              ) {
                                finishRoutinePointerDrag(false);
                              }
                            }}
                            onPointerCancel={(event) => {
                              if (
                                routinePointerDrag.current?.pointerId ===
                                event.pointerId
                              ) {
                                finishRoutinePointerDrag(false);
                              }
                            }}
                            onPointerDown={(event) =>
                              startRoutinePointerDrag(card.id, event)
                            }
                            onPointerMove={(event) => {
                              if (
                                routinePointerDrag.current?.pointerId !==
                                event.pointerId
                              ) {
                                return;
                              }
                              event.preventDefault();
                              queueRoutinePointerDrag(event.clientY);
                            }}
                            onPointerUp={(event) => {
                              if (
                                routinePointerDrag.current?.pointerId !==
                                event.pointerId
                              ) {
                                return;
                              }
                              event.preventDefault();
                              routinePointerDrag.current.currentClientY = event.clientY;
                              finishRoutinePointerDrag(true);
                            }}
                          >
                            <AriaButton
                              aria-label={messages.recommendations_card_reorder({
                                title: displayTitle,
                              })}
                              className="comma-routines-card-drag-handle"
                              slot="drag"
                            >
                              <DragHandleIcon aria-hidden="true" />
                            </AriaButton>
                          </span>
                          <RecommendationCardLogo card={card} sources={sources} />
                          <span className="comma-routines-card-title">
                            {displayTitle}
                          </span>
                          <Dropdown
                            ariaLabel={messages.recommendations_card_visibility({
                              title: displayTitle,
                            })}
                            className="comma-routines-card-visibility"
                            items={visibilityItems}
                            onChange={(value) =>
                              onVisibilityChange(card.id, value === "show")
                            }
                            size="xs"
                            value={hiddenCardIds.has(card.id) ? "hidden" : "show"}
                            width="content"
                          />
                        </GridListItem>
                      );
                    }}
                  </GridList>
                </ScrollArea>
              ) : null}
              <Menu
                aria-label={messages.recommendations_settings()}
                className="comma-routines-panel-actions"
                onAction={() => setIsOpen(false)}
                variant="embedded"
              >
                <MenuItem
                  className="block"
                  href="/#/settings?category=recommendations"
                  id="settings"
                >
                  {messages.recommendations_settings()}
                </MenuItem>
              </Menu>
            </AriaDialog>
          </MenuPopover>
        </DialogTrigger>
      </div>
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
  return (
    <article className="comma-recommendation-card" data-template="fallback">
      <RecommendationCardHeading card={card} sources={sources} />
      <p>{card.fallbackText}</p>
    </article>
  );
}

function RecommendationGeneratedCardView({
  card,
  onAction,
  onOpenTask,
  onOpenUrl,
  sources,
}: {
  card: RecommendationGeneratedCard;
  onAction: (action: RecommendationAction) => void;
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
      onOpenTask={onOpenTask}
      onOpenUrl={onOpenUrl}
      sources={sources}
    />
  );
}

export function RecommendationTextListCard({
  card,
  onAction,
  onOpenTask,
  onOpenUrl,
  sources = [],
}: {
  card: Extract<RecommendationGeneratedCard, { template: "text-list@1" }>;
  onAction: (action: RecommendationAction) => void;
  onOpenTask: (conversationId: string) => void;
  onOpenUrl: (url: string) => void;
  sources?: readonly RecommendationSource[];
}) {
  return (
    <article className="comma-recommendation-card" data-template={card.template}>
      <RecommendationCardHeading card={card} sources={sources} />
      <div className="comma-recommendation-items">
        {card.items.map((item) => {
          const task = linkedRowTask(item);
          const row = (
            <RecommendationTextItem
              item={item}
              key={item.id}
              onAction={onAction}
              onOpenTask={onOpenTask}
              onOpenUrl={onOpenUrl}
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
      </div>
      {card.footerAction ? (
        <RecommendationActionHoverCard action={card.footerAction}>
          <button
            className="comma-recommendation-footer-action"
            onClick={() => onAction(card.footerAction!)}
            type="button"
          >
            <span>{card.footerAction.label}</span>
            <CirclePlusIcon
              aria-hidden="true"
              className="comma-recommendation-row-icon"
            />
          </button>
        </RecommendationActionHoverCard>
      ) : null}
    </article>
  );
}

type RecommendationTextListItem = Extract<
  RecommendationGeneratedCard,
  { template: "text-list@1" }
>["items"][number];

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

// The row is one target with one action, so a full-bleed button underneath the
// prose carries the press and the prompt preview. Inline chips sit above it and
// take their own pointer events back, which would leave every chip a hole in
// that hover surface; each chip without a preview of its own therefore stands in
// for the row, anchored to the row so the card holds still across the sweep.
function RecommendationTextItem({
  item,
  onAction,
  onOpenTask,
  onOpenUrl,
  sources,
}: {
  item: RecommendationTextListItem;
  onAction: (action: RecommendationAction) => void;
  onOpenTask: (conversationId: string) => void;
  onOpenUrl: (url: string) => void;
  sources: readonly RecommendationSource[];
}) {
  const rowRef = useRef<HTMLDivElement | null>(null);

  const sourceLink =
    item.parts.length === 1 && item.parts[0]?.kind === "inline-link"
      ? item.parts[0].link
      : undefined;
  useEffect(() => {
    const row = rowRef.current;
    if (!sourceLink || !row) return;
    let label: HTMLElement | null = null;
    let frame = 0;
    const reset = () => {
      cancelAnimationFrame(frame);
      if (label) label.scrollLeft = 0;
      delete row.dataset.scrolling;
    };
    const update = () => {
      reset();
      // The Markdown renderer can mount its inline label after this row's effect.
      label = row.querySelector<HTMLElement>(
        ".comma-recommendation-inline-source > span"
      );
      if (!label) return;
      const target = label;
      const active = row.matches(":hover") || row.contains(document.activeElement);
      const distance = label.scrollWidth - label.clientWidth;
      if (!active || distance <= 0 || isReducedMotionEnabled()) return;
      row.dataset.scrolling = "true";
      const start = performance.now() + 600;
      const tick = (now: number) => {
        const offset = Math.min(distance, Math.max(0, now - start) * 0.04);
        target.scrollLeft = offset;
        if (offset < distance) frame = requestAnimationFrame(tick);
      };
      frame = requestAnimationFrame(tick);
    };
    const blur = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(update);
    };
    row.addEventListener("pointerenter", update);
    row.addEventListener("pointerleave", update);
    row.addEventListener("focusin", update);
    row.addEventListener("focusout", blur);
    const observer = new ResizeObserver(update);
    observer.observe(row);
    const unsubscribeMotion = subscribeToReducedMotion(update);
    return () => {
      reset();
      observer.disconnect();
      unsubscribeMotion();
      row.removeEventListener("pointerenter", update);
      row.removeEventListener("pointerleave", update);
      row.removeEventListener("focusin", update);
      row.removeEventListener("focusout", blur);
    };
  }, [sourceLink]);

  const linkedTask = linkedRowTask(item);
  const trigger = (
    <button
      aria-label={linkedTask?.label ?? item.action.label}
      className="comma-recommendation-text-item-action"
      onClick={() =>
        linkedTask ? onOpenTask(linkedTask.conversationId) : onAction(item.action)
      }
      type="button"
    />
  );

  return (
    <div
      className="comma-recommendation-text-item"
      data-source-only={
        item.parts.length === 1 && item.parts[0]?.kind === "inline-link"
          ? "true"
          : undefined
      }
      ref={rowRef}
    >
      {sourceLink?.previewText ? (
        <RecommendationLinkHoverCard
          fallbackAnchorRef={rowRef}
          onOpenUrl={onOpenUrl}
          link={sourceLink}
          source={resolveRecommendationSource(sources, sourceLink.sourceId)}
        >
          {trigger}
        </RecommendationLinkHoverCard>
      ) : (
        <RecommendationActionHoverCard action={item.action} anchorRef={rowRef}>
          {trigger}
        </RecommendationActionHoverCard>
      )}
      <RecommendationDocument
        className="comma-recommendation-text-item-content"
        onAction={onAction}
        fallbackAction={item.action}
        fallbackAnchorRef={rowRef}
        onOpenTask={onOpenTask}
        onOpenUrl={onOpenUrl}
        parts={item.parts}
        sources={sources}
        variant="card"
      />
      <CirclePlusIcon aria-hidden="true" className="comma-recommendation-row-icon" />
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
  return (
    <article className="comma-recommendation-card" data-template={card.template}>
      <RecommendationCardHeading card={card} sources={sources} />
      <div className="comma-recommendation-items">
        {card.items.map((item) => (
          <RecommendationMediaItem item={item} key={item.id} onAction={onAction} />
        ))}
      </div>
    </article>
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
}: {
  item: Extract<RecommendationCard, { template: "media-list@1" }>["items"][number];
  onAction: (action: RecommendationAction) => void;
}) {
  const safeImageUrl = useLinkPreviewMediaUrl(item.imageUrl);
  const content = (
    <>
      {safeImageUrl ? <img alt="" src={safeImageUrl} /> : null}
      <span>
        <strong>{item.title}</strong>
        {item.description ? <small>{item.description}</small> : null}
      </span>
      <CirclePlusIcon aria-hidden="true" className="comma-recommendation-row-icon" />
    </>
  );

  return (
    <RecommendationActionHoverCard action={item.action}>
      <button
        className="comma-recommendation-media-item"
        data-has-image={safeImageUrl ? "true" : "false"}
        onClick={() => onAction(item.action)}
        type="button"
      >
        {content}
      </button>
    </RecommendationActionHoverCard>
  );
}

// Hovering an inline link chip previews where it goes. A link the server can
// read opens on the rich card's skeleton and settles into the per-kind card
// once the workspace API answers; every other link — and any failed read —
// shows the generic destination tile (source mark, link label, app ·
// host/path).
function RecommendationLinkHoverCard({
  children,
  fallbackAction,
  fallbackAnchorRef,
  link,
  source,
  onOpenUrl,
}: {
  children: ReactElement;
  onOpenUrl: (url: string) => void;
  fallbackAction?: RecommendationAction | undefined;
  fallbackAnchorRef?: RefObject<Element | null> | undefined;
  link: {
    href: string;
    label: string;
    sourceId?: string | undefined;
    previewText?: string | undefined;
    taskPrompt?: string | undefined;
  };
  source: RecommendationSource | undefined;
}) {
  const messages = useCommaMessages();
  const previewContext = useContext(RecommendationLinkPreviewContext);
  const [preview, setPreview] = useState<CommaRecommendationLinkPreview | "loading">();
  const requestGeneration = useRef(0);
  const richPreview =
    previewContext !== undefined && hasRecommendationLinkPreview(link.href);

  useEffect(() => {
    requestGeneration.current += 1;
    setPreview(undefined);
    return () => {
      requestGeneration.current += 1;
    };
  }, [link.href, link.sourceId]);

  const handleOpenChange = (open: boolean) => {
    if (!open || link.previewText || !richPreview || preview !== undefined) return;
    // A settled answer renders at once: no skeleton flash, no request.
    const cached = peekRecommendationLinkPreview(
      previewContext.api,
      previewContext.workspaceId,
      { href: link.href, sourceId: link.sourceId }
    );
    if (cached === "missing") return;
    if (cached) {
      setPreview(cached);
      return;
    }
    const generation = ++requestGeneration.current;
    setPreview("loading");
    void loadRecommendationLinkPreview(previewContext.api, previewContext.workspaceId, {
      href: link.href,
      sourceId: link.sourceId,
    }).then(
      (next) => {
        if (requestGeneration.current === generation) setPreview(next);
      },
      () => {
        // Unavailable: the generic card is the complete answer.
        if (requestGeneration.current === generation) setPreview(undefined);
      }
    );
  };

  // This excerpt was admitted with the member snapshot. Render only supported
  // inline tokens, not arbitrary HTML or another provider's fetched preview.
  if (link.previewText) {
    return (
      <HoverCard
        anchorRef={fallbackAnchorRef}
        className="comma-recommendation-prompt-hover-card comma-recommendation-source-detail-card"
        content={
          <ScrollArea
            className="comma-recommendation-source-scroll"
            contentClassName="comma-recommendation-prompt-preview"
            orientation="vertical"
            edgeEffect="none"
          >
            <section className="comma-recommendation-source-section comma-recommendation-source-context">
              <strong>{messages.recommendations_source_context()}</strong>
              <p className="comma-recommendation-source-detail">
                <SourceContext
                  text={link.previewText}
                  sourceHref={link.href}
                  onOpenUrl={onOpenUrl}
                />
              </p>
            </section>
            {link.taskPrompt ? (
              <p className="comma-recommendation-task-objective">
                {/* The task prompt starts with the objective. A blank line separates the source URL. */}
                {link.taskPrompt.split("\n\n", 1)[0]}
              </p>
            ) : null}
          </ScrollArea>
        }
        placement="bottom start"
      >
        {children}
      </HoverCard>
    );
  }

  // Mail is private: there is nothing to preview beyond the label the chip
  // already shows, so a Gmail link never gets a link card. It still stands in
  // for the row it sits in, so the chip is not a hole in the row's hover.
  if (isPrivateMailLink(link.href, source)) {
    return (
      <RecommendationActionHoverCard
        action={fallbackAction}
        anchorRef={fallbackAnchorRef}
      >
        {children}
      </RecommendationActionHoverCard>
    );
  }

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

function RecommendationActionHoverCard({
  action,
  anchorRef,
  children,
}: {
  action: RecommendationAction | undefined;
  anchorRef?: RefObject<Element | null> | undefined;
  children: ReactElement;
}) {
  const messages = useCommaMessages();
  if (!action || !("prompt" in action)) return children;

  return (
    <HoverCard
      anchorRef={anchorRef}
      className="comma-recommendation-prompt-hover-card"
      content={
        <div className="comma-recommendation-prompt-preview">
          <strong>{action.label}</strong>
          <p>{recommendationComposerText(action, messages)}</p>
        </div>
      }
      placement="right top"
    >
      {children}
    </HoverCard>
  );
}

export function RecommendationSummary({
  fallbackTitle,
  greetingName,
  onOpenTask,
  onOpenUrl,
  parts,
  pending = false,
  sources = [],
}: {
  fallbackTitle: string;
  greetingName?: string | undefined;
  onOpenTask: (conversationId: string) => void;
  onOpenUrl: (url: string) => void;
  parts: readonly RecommendationDocumentPart[];
  /** A refresh is regenerating the body; the greeting stays, it is not model output. */
  pending?: boolean;
  sources?: readonly RecommendationSource[];
}) {
  const messages = useCommaMessages();
  const split = splitRecommendationSummary(parts, fallbackTitle);
  const body = split.body;
  // The briefing heading is a fixed greeting, not model output. The split still
  // runs so an authored title line is stripped from the body instead of being
  // rendered twice; only isolated surfaces without a signed-in name (stories,
  // tests) fall back to what the model wrote.
  const title = greetingName ? briefingGreeting(messages, greetingName) : split.title;

  return (
    <section className="comma-recommendations-summary">
      <h1>{title}</h1>
      {pending ? (
        <RecommendationsSkeleton groups={summarySkeletonLines} />
      ) : body.length > 0 ? (
        <RecommendationDocument
          className="comma-recommendations-summary-body"
          onOpenTask={onOpenTask}
          onOpenUrl={onOpenUrl}
          parts={body}
          sources={sources}
          variant="summary"
        />
      ) : null}
    </section>
  );
}

/**
 * The briefing heading, always "<time-of-day greeting>, <name>". Rendering the
 * model's own opener here made the heading drift ("Here's your clearest path
 * through today"); the greeting is chrome, so the client owns it and the
 * model's prose stays in the body.
 */
export function briefingGreeting(
  messages: ReturnType<typeof useCommaMessages>,
  name: string,
  now: Date = new Date()
): string {
  const hour = now.getHours();
  if (hour < 12) return messages.recommendations_greeting_morning({ name });
  if (hour < 18) return messages.recommendations_greeting_afternoon({ name });
  return messages.recommendations_greeting_evening({ name });
}

function splitRecommendationSummary(
  parts: readonly RecommendationDocumentPart[],
  fallbackTitle: string
): { body: readonly RecommendationDocumentPart[]; title: string } {
  const first = parts[0];
  if (first?.kind !== "markdown") return { body: parts, title: fallbackTitle };

  const separator = /\r?\n\s*\r?\n/.exec(first.text);
  const candidate = (
    separator ? first.text.slice(0, separator.index) : first.text
  ).trim();
  const validTitle =
    candidate.length > 0 &&
    candidate.length <= recommendationLimits.summaryTitleCharacters &&
    !candidate.includes("\n") &&
    !candidate.includes("\r");

  const remainder = separator
    ? first.text.slice(separator.index + separator[0].length)
    : undefined;
  const hasBody = Boolean(remainder?.trim()) || parts.length > 1;
  if (!validTitle || !hasBody) return { body: parts, title: fallbackTitle };

  const body = remainder?.trim()
    ? [{ kind: "markdown" as const, text: remainder }, ...parts.slice(1)]
    : parts.slice(1);
  return { body, title: candidate };
}

export function RecommendationDocument({
  className,
  onAction,
  fallbackAction,
  fallbackAnchorRef,
  onOpenTask,
  onOpenUrl,
  parts,
  sources = [],
  variant = "card",
}: {
  className?: string;
  onAction?: ((action: RecommendationAction) => void) | undefined;
  /**
   * The action of the row this document fills, if it has one. Chips carry their
   * own pointer events, so a chip with no preview of its own shows this instead
   * of swallowing the row's hover.
   */
  fallbackAction?: RecommendationAction | undefined;
  fallbackAnchorRef?: RefObject<Element | null> | undefined;
  onOpenTask: (conversationId: string) => void;
  onOpenUrl: (url: string) => void;
  parts: readonly RecommendationDocumentPart[];
  sources?: readonly RecommendationSource[];
  variant?: "card" | "summary";
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
                fallbackAction={fallbackAction}
                fallbackAnchorRef={fallbackAnchorRef}
                link={part.link}
                onOpenUrl={onOpenUrl}
                source={source}
              >
                <button
                  className="comma-recommendation-inline comma-recommendation-inline-link comma-recommendation-inline-source"
                  data-variant={variant}
                  data-source-detail={part.link.previewText ? "true" : undefined}
                  onClick={() =>
                    part.link.taskPrompt && fallbackAction && onAction
                      ? onAction(fallbackAction)
                      : onOpenUrl(part.link.href)
                  }
                  type="button"
                  {...{ [recommendationLinkHrefAttribute]: part.link.href }}
                >
                  {variant === "card" && parts.length === 1 ? null : (
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
                <RecommendationActionHoverCard
                  action={fallbackAction}
                  anchorRef={fallbackAnchorRef}
                >
                  <button
                    className={`comma-recommendation-inline${sourceClassName}`}
                    data-variant={variant}
                    onClick={() => onOpenTask(part.task.conversationId)}
                    type="button"
                  >
                    {part.task.sourceId ? <LinkProviderIcon source={source} /> : null}
                    <span>{part.task.label}</span>
                  </button>
                </RecommendationActionHoverCard>
              </VisibleRecommendationTask>
            );
          }
          return null;
        },
      }),
    [
      fallbackAction,
      fallbackAnchorRef,
      onAction,
      onOpenTask,
      onOpenUrl,
      parts,
      sources,
      variant,
    ]
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

function resolveRecommendationSource(
  sources: readonly RecommendationSource[],
  sourceId: string | undefined
) {
  if (!sourceId) return undefined;
  return sources.find(
    (source) => source.connectionId === sourceId || source.appId === sourceId
  );
}

function RecommendationCardLogo({
  card,
  sources,
}: {
  card: Pick<RecommendationCard, "sourceIds">;
  sources: readonly RecommendationSource[];
}) {
  const source =
    card.sourceIds.length === 1
      ? resolveRecommendationSource(sources, card.sourceIds[0])
      : undefined;

  return (
    <span className="comma-recommendation-card-logo" aria-hidden="true">
      <LinkProviderIcon source={source} />
    </span>
  );
}

function RecommendationCardHeading({
  card,
  sources,
}: {
  card: Pick<RecommendationCard, "sourceIds" | "title">;
  sources: readonly RecommendationSource[];
}) {
  return (
    <div className="comma-recommendation-card-heading">
      <RecommendationCardLogo card={card} sources={sources} />
      <h3>{recommendationCardDisplayTitle(card, sources)}</h3>
    </div>
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

function VisibleRecommendationTaskRow({
  id,
  children,
}: {
  id: string;
  children: ReactNode;
}) {
  const context = useContext(RecommendationLinkPreviewContext);
  const projection = useProductInboxSnapshot();
  const group =
    projection?.snapshot.workspaces?.find(
      (workspace) => workspace.id === context?.workspaceId
    )?.group_id ?? "";
  const summary = useTaskSummary(context?.api, group, id);
  if (
    context &&
    (!summary ||
      ["completed", "cancelled", "archived", "ready_for_review"].includes(
        summary.status
      ))
  )
    return null;
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
  const projection = useProductInboxSnapshot();
  const group =
    projection?.snapshot.workspaces?.find(
      (workspace) => workspace.id === context?.workspaceId
    )?.group_id ?? "";
  const summary = useTaskSummary(context?.api, group, id);
  const action = useArchiveAction(context?.api, group, id);
  if (!context) return children;
  if (summary?.status === "archived") return null;
  return (
    <TaskArchiveMenu inline action={action}>
      {children}
    </TaskArchiveMenu>
  );
}
