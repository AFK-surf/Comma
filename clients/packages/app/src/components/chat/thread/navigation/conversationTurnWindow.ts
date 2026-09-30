/**
 * Bottom-anchored turn window for an already-loaded conversation snapshot.
 *
 * Home and Task use the same window over the channel's loaded history.
 * Long logical turns have bounded render units. Paint the latest units,
 * expand upward on reader scroll, and slide to the tail while pinned.
 * This bounds mounted content, not the network history response.
 */
export const CONVERSATION_TURN_WINDOW = {
  /** First paint / while pinned to the latest turn. */
  initialTurns: 6,
  /** Older turns revealed per near-top or fill-viewport step. */
  pageTurns: 8,
  /** A logical turn can contain arbitrarily many Agent messages. */
  maxEntriesPerUnit: 4,
  /** Load older when the scrollport is this close to the top. */
  loadOlderThresholdPx: 240,
} as const;

type WindowTurn = {
  key: string;
  entries: readonly { key: string; message?: { messageId: string } | undefined }[];
};

/** Render boundaries do not change logical turns, reply ownership, or anchors. */
export function conversationWindowUnits(turns: readonly WindowTurn[]) {
  return turns.flatMap((turn, turnIndex) => {
    const units = [];
    for (
      let entryIndex = 0;
      entryIndex < turn.entries.length;
      entryIndex += CONVERSATION_TURN_WINDOW.maxEntriesPerUnit
    ) {
      units.push({
        key: entryIndex === 0 ? turn.key : `window:${turn.entries[entryIndex]!.key}`,
        turnIndex,
        entryIndex,
      });
    }
    return units;
  });
}

export function visibleConversationTurns<T extends WindowTurn>(
  turns: readonly T[],
  units: ReturnType<typeof conversationWindowUnits>,
  start: number
): T[] {
  const boundary = units[start];
  if (!boundary) return [...turns];
  const visible = turns.slice(boundary.turnIndex);
  const first = visible[0];
  if (first && boundary.entryIndex > 0) {
    visible[0] = { ...first, entries: first.entries.slice(boundary.entryIndex) };
  }
  return visible;
}

export type ConversationTurnWindowMetrics = {
  clientHeight: number;
  scrollHeight: number;
  scrollTop: number;
};

export function initialWindowStart(
  turnCount: number,
  initialTurns: number = CONVERSATION_TURN_WINDOW.initialTurns
) {
  if (turnCount <= 0) return 0;
  return Math.max(0, turnCount - initialTurns);
}

export function resolveWindowStart({
  initialTurns = CONVERSATION_TURN_WINDOW.initialTurns,
  requiredTurnKeys,
  startKey,
  turnKeys,
}: {
  initialTurns?: number;
  requiredTurnKeys?: ReadonlySet<string> | undefined;
  startKey?: string | null | undefined;
  turnKeys: readonly string[];
}) {
  let start =
    startKey === undefined || startKey === null
      ? initialWindowStart(turnKeys.length, initialTurns)
      : turnKeys.indexOf(startKey);
  if (start < 0) {
    start = initialWindowStart(turnKeys.length, initialTurns);
  }
  if (requiredTurnKeys && requiredTurnKeys.size > 0) {
    for (let index = 0; index < start; index += 1) {
      const key = turnKeys[index];
      if (key !== undefined && requiredTurnKeys.has(key)) {
        start = index;
        break;
      }
    }
  }
  return start;
}

export function expandWindowStart(
  start: number,
  pageTurns: number = CONVERSATION_TURN_WINDOW.pageTurns
) {
  const next = Math.max(0, start - pageTurns);
  return { expanded: start - next, start: next };
}

export function shouldLoadOlderTurns({
  hasOlder,
  metrics,
  pending,
  pinnedToBottom,
  thresholdPx = CONVERSATION_TURN_WINDOW.loadOlderThresholdPx,
}: {
  hasOlder: boolean;
  metrics: ConversationTurnWindowMetrics;
  pending: boolean;
  pinnedToBottom: boolean;
  thresholdPx?: number;
}) {
  if (!hasOlder || pending || pinnedToBottom) return false;
  if (metrics.clientHeight <= 0) return false;
  return metrics.scrollTop <= thresholdPx;
}

export function shouldFillTurnWindow({
  hasOlder,
  metrics,
  pending,
}: {
  hasOlder: boolean;
  metrics: ConversationTurnWindowMetrics;
  pending: boolean;
}) {
  if (!hasOlder || pending) return false;
  // jsdom and the first unmeasured frame report a 0-size scrollport. Do not
  // expand there or tests / first layout would mount the whole history.
  if (metrics.clientHeight <= 0) return false;
  return metrics.scrollHeight <= metrics.clientHeight + 1;
}

export function isPinnedToBottom(
  metrics: ConversationTurnWindowMetrics,
  epsilonPx = 1
) {
  if (metrics.clientHeight <= 0) return true;
  return metrics.scrollHeight - metrics.clientHeight - metrics.scrollTop <= epsilonPx;
}

export function shouldRearmOlderTurnLoad(
  metrics: ConversationTurnWindowMetrics,
  thresholdPx = CONVERSATION_TURN_WINDOW.loadOlderThresholdPx
) {
  return metrics.clientHeight > 0 && metrics.scrollTop > thresholdPx;
}

export function restoredScrollTop(
  previousTop: number,
  previousHeight: number,
  nextHeight: number
) {
  return previousTop + Math.max(0, nextHeight - previousHeight);
}

export function startKeyAfterSlide(
  turnKeys: readonly string[],
  currentStart: number,
  initialTurns: number = CONVERSATION_TURN_WINDOW.initialTurns
) {
  // A true slide: advance the window start one turn per appended turn, so the
  // mounted window keeps its size and only the oldest (far off-screen) turn
  // unmounts. Resetting to the tail instead would evict turns the fill logic
  // immediately re-mounts — a shrink frame that paints as the whole thread
  // flashing on send. Windows at or below the initial size stay put.
  const tailStart = initialWindowStart(turnKeys.length, initialTurns);
  const start = Math.min(tailStart, currentStart + 1);
  return turnKeys[start] ?? null;
}
