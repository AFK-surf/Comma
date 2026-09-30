const CHAT_SCROLLBAR_OVERFLOW_EPSILON_PX = 1;

/**
 * The thread elements this component renders and therefore already knows.
 * The latest turn is the only one that keeps resizing — streamed text, the
 * activity line, task panels gaining rows — so its observer fires about once
 * a frame. Re-finding these by selector on each of those callbacks costs a
 * walk of the whole mounted transcript, which is what made scrolling near the
 * live turn stutter in proportion to how much history was mounted.
 */
type ChatThreadElements = {
  latestTurn: HTMLElement | null;
  latestTurnShell: HTMLElement | null;
  thread: HTMLElement | null;
};

export type ChatThreadGeometry = {
  /**
   * Empty space the latest turn's min-height reserve is holding open, minus
   * its fixed bottom padding: unfilled reserve must not read as overflow,
   * while the padding stays scrollable so the final response clears the
   * composer.
   */
  latestTurnReserve: number;
  latestTurnScrollHeight: number;
  threadScrollHeight: number;
  viewportClientHeight: number;
  viewportScrollHeight: number;
};

/** One layout read per resize batch; every consumer below works off it. */
export function readChatThreadGeometry(
  viewport: HTMLElement,
  { latestTurn, latestTurnShell, thread }: ChatThreadElements
): ChatThreadGeometry {
  const latestTurnScrollHeight = latestTurn?.scrollHeight ?? 0;
  const reserve =
    latestTurnShell && latestTurn
      ? latestTurnShell.clientHeight -
        latestTurnScrollHeight -
        (Number.parseFloat(getComputedStyle(latestTurnShell).paddingBottom) || 0)
      : 0;

  return {
    latestTurnReserve: Math.max(0, reserve),
    latestTurnScrollHeight,
    threadScrollHeight: thread?.scrollHeight ?? 0,
    viewportClientHeight: viewport.clientHeight,
    viewportScrollHeight: viewport.scrollHeight,
  };
}

export function hasMeaningfulChatOverflow(geometry: ChatThreadGeometry) {
  const meaningfulScrollHeight = Math.max(
    0,
    Math.max(geometry.threadScrollHeight, geometry.viewportScrollHeight) -
      geometry.latestTurnReserve
  );

  return (
    meaningfulScrollHeight - geometry.viewportClientHeight >
    CHAT_SCROLLBAR_OVERFLOW_EPSILON_PX
  );
}
