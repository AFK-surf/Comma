import { useCommaMessages } from "@comma/i18n/react";
import { ChevronDownSmallIcon } from "@comma/ui/components/icons";
import { isReducedMotionEnabled } from "@comma/ui/tokens";
import {
  useCallback,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import {
  animateOutgoingBubble,
  holdTranscript,
  settleScrollForComposerResize,
  type TranscriptHold,
} from "../../../motion/outgoingBubbleMotion";
import { getMessagePlatformBubbleStyle } from "../../../MessagePlatformBadge";
import type { OutgoingPresentation } from "../../outgoing/outgoingPresentation";
import {
  observeUserBubble,
  readUserBubble,
  revealUserBubbleTail,
  setUserBubbleExpandedSize,
  splitLongUserText,
  userBubbleOverflows,
} from "./userBubbleMeasurement";

/**
 * What the send motion reads of an outgoing presentation. A transcript row
 * passes its whole presentation; a surface without a composer (the
 * first-launch greeting) passes a launch whose source frame is empty, which
 * plays the motion's no-source path.
 */
export type UserBubbleOutgoingPresentation = Pick<OutgoingPresentation, "turnKey"> & {
  launch: Pick<
    OutgoingPresentation["launch"],
    "id" | "motionConfig" | "playbackRate" | "sourceFrame" | "transcriptAnchor"
  >;
};

export function UserMessageBubble({
  onAnchorOutgoingTurn,
  onOutgoingAnimationComplete,
  outgoingPresentation,
  platform,
  renderContent,
  text,
}: {
  onAnchorOutgoingTurn?: ((turnKey: string) => void) | undefined;
  onOutgoingAnimationComplete?: ((launchId: number) => void) | undefined;
  outgoingPresentation?: UserBubbleOutgoingPresentation | undefined;
  platform?: string | undefined;
  /** Mention- and URL-aware content for a part of `text`; plain text renders when absent. */
  renderContent?: ((text: string) => ReactNode | undefined) | undefined;
  text: string;
}) {
  const messagesApi = useCommaMessages();
  const contentId = useId();
  const slotElementRef = useRef<HTMLDivElement | null>(null);
  const bubbleElementRef = useRef<HTMLDivElement | null>(null);
  const contentElementRef = useRef<HTMLDivElement | null>(null);
  const remProbeRef = useRef<HTMLDivElement | null>(null);
  const tailElementRef = useRef<HTMLSpanElement | null>(null);
  // A deferred tail stays plain text until it can be seen: the collapsed
  // bubble clips it, and mention and link parsing would cost the send.
  const [tailRevealed, setTailRevealed] = useState(false);
  const parts = useMemo(() => splitLongUserText(text), [text]);
  const head = useMemo(
    () => renderUserText(parts ? parts.head : text, renderContent),
    [parts, renderContent, text]
  );
  const tail = useMemo(
    () =>
      parts && (tailRevealed ? renderUserText(parts.tail, renderContent) : parts.tail),
    [parts, renderContent, tailRevealed]
  );
  const revealTail = useCallback(() => {
    const revealed = revealUserBubbleTail(tailElementRef.current);
    if (revealed) setTailRevealed(true);
    return revealed;
  }, []);
  const onAnchorOutgoingTurnRef = useRef(onAnchorOutgoingTurn);
  const onOutgoingAnimationCompleteRef = useRef(onOutgoingAnimationComplete);
  const activePresentationRef = useRef<
    | {
        animation?: Animation | undefined;
        cleanup: () => void;
        id: number;
      }
    | undefined
  >(undefined);
  const [expanded, setExpanded] = useState(false);
  const [overflowing, setOverflowing] = useState(false);
  const [measuredText, setMeasuredText] = useState<string>();
  const [preparedOutgoingLaunchId, setPreparedOutgoingLaunchId] = useState<
    number | undefined
  >();
  const outgoingLaunchId = outgoingPresentation?.launch.id;
  const outgoingSourceFrame = outgoingPresentation?.launch.sourceFrame;
  const outgoingMotionConfig = outgoingPresentation?.launch.motionConfig;
  const outgoingPlaybackRate = outgoingPresentation?.launch.playbackRate;
  const outgoingTurnKey = outgoingPresentation?.turnKey;
  const outgoingTranscriptAnchor = outgoingPresentation?.launch.transcriptAnchor;
  // Where the slot sat before this send first anchored its turn, read in
  // the frame the flight launches: the anchor's scroll becomes its glide.
  const unanchoredSlotTopRef = useRef<number | undefined>(undefined);
  const transcriptHoldRef = useRef<TranscriptHold | undefined>(undefined);

  useLayoutEffect(() => {
    onAnchorOutgoingTurnRef.current = onAnchorOutgoingTurn;
    onOutgoingAnimationCompleteRef.current = onOutgoingAnimationComplete;
  }, [onAnchorOutgoingTurn, onOutgoingAnimationComplete]);

  // A flight ends only with its launch or its row. A later text, overflow or
  // delivery update of the same message lands with it instead of starting over.
  useLayoutEffect(() => {
    if (outgoingLaunchId === undefined) return undefined;
    // This commit inserts the row. Until the flight launches the transcript
    // stays where it was painted, the newest turn at the send held in place.
    const column = slotElementRef.current?.closest(".comma-chat-column");
    const reference =
      outgoingTranscriptAnchor && column
        ? column.querySelector<HTMLElement>(
            `.comma-chat-turn-shell[data-turn-key="${CSS.escape(outgoingTranscriptAnchor.turnKey)}"]`
          )
        : null;
    transcriptHoldRef.current =
      reference && outgoingTranscriptAnchor
        ? holdTranscript(reference, outgoingTranscriptAnchor.top)
        : undefined;
    return () => {
      transcriptHoldRef.current?.cancel();
      transcriptHoldRef.current = undefined;
      if (activePresentationRef.current?.id === outgoingLaunchId) {
        activePresentationRef.current.cleanup();
        activePresentationRef.current = undefined;
      }
    };
  }, [outgoingLaunchId, outgoingTranscriptAnchor]);

  useLayoutEffect(() => {
    const bubble = bubbleElementRef.current;
    const content = contentElementRef.current;
    if (!bubble || !content) return;

    const read = () => {
      const measured = readUserBubble(bubble, content);
      return () => {
        if (measured.expandedBlockSize !== undefined)
          setUserBubbleExpandedSize(content, measured.expandedBlockSize);
        let nextOverflowing = measured.overflowing;
        // The deferred tail is measured only when the head alone fits.
        if (!nextOverflowing && revealTail())
          nextOverflowing = readUserBubble(bubble, content).overflowing;
        setOverflowing((current) =>
          current === nextOverflowing ? current : nextOverflowing
        );
        if (!nextOverflowing) setExpanded(false);
        setMeasuredText(text);
      };
    };
    return observeUserBubble(content, remProbeRef.current, read);
  }, [revealTail, text]);

  useLayoutEffect(() => {
    const slot = slotElementRef.current;
    const bubble = bubbleElementRef.current;
    const content = contentElementRef.current;
    if (
      outgoingLaunchId === undefined ||
      !outgoingSourceFrame ||
      !outgoingTurnKey ||
      !slot ||
      !bubble ||
      !content
    ) {
      return;
    }
    if (activePresentationRef.current?.id === outgoingLaunchId) return;
    if (measuredText !== text) return;

    const shouldOverflow = userBubbleOverflows(bubble, content);
    // The measurement frame commits the 480px disclosure before flight setup.
    // Wait for that state before promoting the same bubble into the top layer.
    if (shouldOverflow !== overflowing) return;

    if (preparedOutgoingLaunchId !== outgoingLaunchId) {
      // The transcript has not moved for this send yet: the thread holds
      // its scroll for a flying turn (useStickToBottom heldTurnKeys).
      unanchoredSlotTopRef.current = slot.getBoundingClientRect().top;
      onAnchorOutgoingTurnRef.current?.(outgoingTurnKey);
      // Commit flight setup before this measurement frame paints, so the
      // anchored layout is never painted before its glide holds it in place.
      setPreparedOutgoingLaunchId(outgoingLaunchId);
      return;
    }

    // The prepared layout can differ from the one anchored above: deciding to scroll
    // adds the latest turn's reserve. Anchor again in it, so the flight measures where
    // it lands.
    onAnchorOutgoingTurnRef.current?.(outgoingTurnKey);
    settleScrollForComposerResize(slot);
    const target = bubble.getBoundingClientRect();
    if (target.width <= 0 || target.height <= 0) {
      // Nothing flies, so nothing waits for the transcript to be let go.
      transcriptHoldRef.current?.cancel();
      transcriptHoldRef.current = undefined;
      onOutgoingAnimationCompleteRef.current?.(outgoingLaunchId);
      return;
    }
    // The held move since the send, anchor included, or without a hold (no
    // turn to hold by, or one that ended on its own), the anchor's own move
    // of the slot.
    const anchoredSlotTop = slot.getBoundingClientRect().top;
    const transcriptShift =
      transcriptHoldRef.current?.release() ??
      (unanchoredSlotTopRef.current ?? anchoredSlotTop) - anchoredSlotTop;
    transcriptHoldRef.current = undefined;
    unanchoredSlotTopRef.current = undefined;

    const presentation = animateOutgoingBubble({
      bubble,
      content,
      slot,
      source: outgoingSourceFrame,
      config: outgoingMotionConfig,
      playbackRate: outgoingPlaybackRate,
      reducedMotion: isReducedMotionEnabled(),
      transcriptShift,
      onComplete: () => {
        activePresentationRef.current = undefined;
        onOutgoingAnimationCompleteRef.current?.(outgoingLaunchId);
      },
    });
    activePresentationRef.current = { ...presentation, id: outgoingLaunchId };
  }, [
    outgoingLaunchId,
    outgoingSourceFrame,
    outgoingMotionConfig,
    outgoingPlaybackRate,
    outgoingTurnKey,
    overflowing,
    preparedOutgoingLaunchId,
    measuredText,
    text,
  ]);

  return (
    <div className="comma-chat-user-bubble-slot" ref={slotElementRef}>
      <div
        className="comma-chat-user-bubble"
        data-expanded={overflowing ? String(expanded) : undefined}
        data-outgoing-measurement={
          outgoingLaunchId !== undefined &&
          preparedOutgoingLaunchId !== outgoingLaunchId &&
          measuredText !== text
            ? "pending"
            : undefined
        }
        data-overflowing={overflowing ? "true" : undefined}
        data-outgoing-presentation={
          outgoingLaunchId !== undefined &&
          preparedOutgoingLaunchId !== outgoingLaunchId
            ? "preparing"
            : undefined
        }
        ref={bubbleElementRef}
        style={getMessagePlatformBubbleStyle(platform)}
      >
        <div
          className="comma-chat-user-bubble-content"
          data-testid="chat-user-bubble-content"
          id={contentId}
          ref={contentElementRef}
        >
          {head}
          {parts === undefined ? null : (
            <span className="comma-chat-user-bubble-tail" ref={tailElementRef}>
              {tail}
            </span>
          )}
        </div>
        <div
          aria-hidden
          className="comma-chat-user-bubble-rem-probe"
          ref={remProbeRef}
        />
        {overflowing ? (
          <>
            <span aria-hidden className="comma-chat-user-bubble-fade" />
            <div className="comma-chat-user-bubble-toggle-row">
              <button
                aria-controls={contentId}
                aria-expanded={expanded}
                aria-label={
                  expanded
                    ? messagesApi.chat_message_collapse()
                    : messagesApi.chat_message_expand()
                }
                className="comma-chat-user-bubble-toggle"
                data-no-press-feedback
                onClick={() => {
                  const content = contentElementRef.current;
                  if (!expanded && content) {
                    revealTail();
                    setUserBubbleExpandedSize(content);
                  }
                  setExpanded((current) => !current);
                }}
                type="button"
              >
                <ChevronDownSmallIcon aria-hidden />
              </button>
            </div>
          </>
        ) : null}
      </div>
    </div>
  );
}

function renderUserText(
  text: string,
  renderContent: ((text: string) => ReactNode | undefined) | undefined
) {
  return renderContent?.(text) ?? text;
}
