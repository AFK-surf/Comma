import { useCommaMessages } from "@comma/i18n/react";
import { ChevronDownSmallIcon, isReducedMotionEnabled } from "@comma/ui";
import { useId, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { animateOutgoingBubble } from "../../../motion/outgoingBubbleMotion";
import { getMessagePlatformBubbleStyle } from "../../../MessagePlatformBadge";
import type { OutgoingPresentation } from "../../outgoing/outgoingPresentation";
import {
  measureUserBubble,
  observeUserBubble,
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
    "id" | "motionConfig" | "playbackRate" | "sourceFrame"
  >;
};

export function UserMessageBubble({
  content: mentionContent,
  onAnchorOutgoingTurn,
  onOutgoingAnimationComplete,
  outgoingPresentation,
  platform,
  text,
}: {
  /** Mention- and URL-aware content; plain text renders when absent. */
  content?: ReactNode | undefined;
  onAnchorOutgoingTurn?: ((turnKey: string) => void) | undefined;
  onOutgoingAnimationComplete?: ((launchId: number) => void) | undefined;
  outgoingPresentation?: UserBubbleOutgoingPresentation | undefined;
  platform?: string | undefined;
  text: string;
}) {
  const messagesApi = useCommaMessages();
  const contentId = useId();
  const slotElementRef = useRef<HTMLDivElement | null>(null);
  const bubbleElementRef = useRef<HTMLDivElement | null>(null);
  const contentElementRef = useRef<HTMLDivElement | null>(null);
  const remProbeRef = useRef<HTMLDivElement | null>(null);
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

  useLayoutEffect(() => {
    onAnchorOutgoingTurnRef.current = onAnchorOutgoingTurn;
    onOutgoingAnimationCompleteRef.current = onOutgoingAnimationComplete;
  }, [onAnchorOutgoingTurn, onOutgoingAnimationComplete]);

  useLayoutEffect(() => {
    const bubble = bubbleElementRef.current;
    const content = contentElementRef.current;
    if (!bubble || !content) return;

    const measure = () => {
      const nextOverflowing = measureUserBubble(bubble, content);
      setOverflowing((current) =>
        current === nextOverflowing ? current : nextOverflowing
      );
      if (!nextOverflowing) setExpanded(false);
      setMeasuredText(text);
    };
    return observeUserBubble(content, remProbeRef.current, measure);
  }, [text]);

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
      onAnchorOutgoingTurnRef.current?.(outgoingTurnKey);
      // Commit flight setup before this measurement frame paints. Painting the
      // anchored full-height turn first makes history jump back when flight
      // setup collapses the slot and restores the previous tail reserve.
      setPreparedOutgoingLaunchId(outgoingLaunchId);
      return;
    }

    const target = bubble.getBoundingClientRect();
    if (target.width <= 0 || target.height <= 0) {
      onOutgoingAnimationCompleteRef.current?.(outgoingLaunchId);
      return;
    }

    const presentation = animateOutgoingBubble({
      bubble,
      content,
      slot,
      source: outgoingSourceFrame,
      config: outgoingMotionConfig,
      playbackRate: outgoingPlaybackRate,
      reducedMotion: isReducedMotionEnabled(),
      onComplete: () => {
        activePresentationRef.current = undefined;
        onOutgoingAnimationCompleteRef.current?.(outgoingLaunchId);
      },
    });
    activePresentationRef.current = { ...presentation, id: outgoingLaunchId };

    return () => {
      if (activePresentationRef.current?.id === outgoingLaunchId) {
        activePresentationRef.current.cleanup();
        activePresentationRef.current = undefined;
      }
    };
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
          outgoingLaunchId !== undefined && measuredText !== text
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
          {mentionContent ?? text}
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
                onClick={() => setExpanded((current) => !current)}
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
