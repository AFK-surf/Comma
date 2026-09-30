import {
  type MouseEvent as ReactMouseEvent,
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useReducer,
  useRef,
  useState,
} from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { isReducedMotionEnabled, motionEasing } from "../../tokens";
import { ChevronLeftSmallIcon, ChevronRightSmallIcon, DownloadIcon } from "../icons";
import { cx } from "../utils";
import { ChatPanelImageFilmstrip } from "./ChatPanelImageFilmstrip";
import { type ChatPanelMediaDownloadAction } from "./ChatPanelMediaDownload";
import {
  ChatPanelMediaDownloadControl,
  useChatPanelMediaDownloadController,
} from "./ChatPanelMediaDownloadControl";
import { ChatPanelMediaPreview } from "./ChatPanelMediaPreview";
import { useKeyboardFocusMotion } from "./useKeyboardFocusMotion";
import { usePointerPressFeedback } from "./usePointerPressFeedback";

export interface ChatPanelImageGroupImage {
  alt: string;
  onContextMenu?: (event: ReactMouseEvent<HTMLElement>) => void;
  download?: ChatPanelMediaDownloadAction;
  src: string;
}

export interface ChatPanelImageGroupProps {
  className?: string;
  /** Groups larger than three images start stacked unless this is set. */
  defaultExpanded?: boolean;
  images: ChatPanelImageGroupImage[];
  onExpandedChange?: (expanded: boolean) => void;
  previewTitle?: string;
}

export type ChatPanelImageGroupStackSlot =
  | "0"
  | "r1"
  | "r2"
  | "l1"
  | "l2"
  | "hidden-right"
  | "hidden-left";

/** Groups with more images than this collapse into the stacked deck. */
const STACK_THRESHOLD = 3;
/** Fan depths that stay visible on each side of the front card. */
const VISIBLE_SIDE_DEPTH = 2;
/**
 * Frame-measured from the reference capture (60fps): motion spans ~19 frames
 * with ~80% of the travel in the first third — a fast throw with a long,
 * spring-like settle and no second bounce.
 */
const FLIGHT_DURATION_MS = 320;
/** Fraction of the flight when the thrown card slips under the new front. */
const FLIGHT_LAYER_SWAP_AT = 0.6;
/** Mirrors --chat-panel-image-group-flip-duration in the stylesheet. */
const FLIP_DURATION_MS = 240;
/** Depth-ordered cascade offsets while the deck unfurls or regathers. */
const FLIP_EXPAND_STAGGER_MS = 12;
const FLIP_COLLAPSE_STAGGER_MS = 8;
const FLIP_CLEANUP_BUFFER_MS = 80;

interface ImageGroupBrowseState {
  frontIndex: number;
  leftCount: number;
}

type ImageGroupBrowseAction =
  | { count: number; step: 1 | -1; type: "rotate-deck" }
  | { count: number; index: number; type: "align-preview" }
  | { count: number; step: 1 | -1; type: "navigate-preview" };

const normalizedImageIndex = (index: number, count: number): number =>
  count > 0 ? ((index % count) + count) % count : 0;

const imageGroupBrowseReducer = (
  state: ImageGroupBrowseState,
  action: ImageGroupBrowseAction
): ImageGroupBrowseState => {
  if (action.count <= 0) return { frontIndex: 0, leftCount: 0 };

  if (action.type === "rotate-deck") {
    const leftCount = Math.min(Math.max(state.leftCount, 0), action.count - 1);
    return {
      frontIndex: normalizedImageIndex(state.frontIndex + action.step, action.count),
      leftCount:
        action.step === 1
          ? Math.min(leftCount + 1, action.count - 1)
          : Math.max(leftCount - 1, 0),
    };
  }

  if (action.type === "align-preview") {
    const index = Math.min(Math.max(action.index, 0), action.count - 1);
    if (normalizedImageIndex(state.frontIndex, action.count) === index) {
      return {
        frontIndex: index,
        leftCount: Math.min(Math.max(state.leftCount, 0), action.count - 1),
      };
    }
    return { frontIndex: index, leftCount: index };
  }

  const currentIndex = normalizedImageIndex(state.frontIndex, action.count);
  const index = Math.min(Math.max(currentIndex + action.step, 0), action.count - 1);
  return { frontIndex: index, leftCount: index };
};

/**
 * The deck is a cyclic browse with a history boundary: `leftCount` cards
 * already flipped past sit fanned on the LEFT of the front card, the rest
 * wait fanned on the RIGHT (the default state is everything on the right).
 * Each side shows up to two depths; deeper cards park hidden at that side's
 * deepest angle, so rotation never runs out of cards in either direction.
 */
export const stackSlotForDistance = (
  index: number,
  frontIndex: number,
  count: number,
  leftCount = 0
): ChatPanelImageGroupStackSlot => {
  if (count <= 0) return "hidden-right";
  const distance = (((index - frontIndex) % count) + count) % count;
  if (distance === 0) return "0";
  const rightSpan = count - 1 - Math.min(Math.max(leftCount, 0), count - 1);
  if (distance <= rightSpan) {
    return distance <= VISIBLE_SIDE_DEPTH
      ? (`r${distance}` as ChatPanelImageGroupStackSlot)
      : "hidden-right";
  }
  const leftDepth = count - distance;
  return leftDepth <= VISIBLE_SIDE_DEPTH
    ? (`l${leftDepth}` as ChatPanelImageGroupStackSlot)
    : "hidden-left";
};

const stackDepthForSlot = (slot: ChatPanelImageGroupStackSlot): number => {
  if (slot === "0") return 3;
  if (slot === "r1" || slot === "l1") return 2;
  if (slot === "r2" || slot === "l2") return 1;
  return 0;
};

interface LayoutBox {
  height: number;
  left: number;
  top: number;
  width: number;
}

const layoutBoxOf = (element: HTMLElement): LayoutBox => ({
  height: element.offsetHeight,
  left: element.offsetLeft,
  top: element.offsetTop,
  width: element.offsetWidth,
});

/** Decomposes a computed 2D matrix into the translate/rotate/scale it encodes. */
const decomposeTransform = (value: string) => {
  const identity = { rotation: 0, scale: 1, x: 0, y: 0 };
  if (!value || value === "none") return identity;
  const match = /matrix\(([^)]+)\)/.exec(value);
  if (!match?.[1]) return identity;
  const [a = 1, b = 0, , , e = 0, f = 0] = match[1].split(",").map(Number);
  return {
    rotation: (Math.atan2(b, a) * 180) / Math.PI,
    scale: Math.hypot(a, b),
    x: e,
    y: f,
  };
};

interface CapturedCard {
  box: LayoutBox;
  depth: number;
  opacity: number;
  rotation: number;
  scale: number;
  x: number;
  y: number;
}

interface PendingFlip {
  cards: Map<number, CapturedCard>;
  wrapperHeight: number;
  wrapperLeft: number;
  wrapperTop: number;
}

interface PendingFlight {
  element: HTMLButtonElement;
  fromOpacity: string;
  fromTransform: string;
  step: 1 | -1;
}

/**
 * Stacked deck for user-uploaded images: more than three images collapse into
 * a rotated card fan with an "N Images" pill and hover chevrons on both
 * edges. Browsing is a cyclic two-pile flip-through — the left chevron sends
 * the front card onto the left history fan and reveals the next image, the
 * right chevron returns it to the right fan — so the deck never runs out in
 * either direction. Expanding lays the images out as a plain wrapping row.
 * Files never take part in this layout — callers render them separately —
 * and the component carries no entry animation of its own, so
 * outgoing-message flights (the text bubble animation) leave it untouched.
 *
 * The 3:4 card crop is purely visual (`object-fit: cover` on the preview):
 * `src` keeps the source dimensions unless a native transport bound requires
 * a smaller encoded variant, and the preview modal shows those same bytes
 * complete via `object-fit: contain`. The card's CSS dimensions never request
 * a smaller bitmap, and agent attachment bytes follow a separate upload path.
 */
export const ChatPanelImageGroup = ({
  className,
  defaultExpanded = false,
  images,
  onExpandedChange,
  previewTitle,
}: ChatPanelImageGroupProps) => {
  const messages = useCommaMessages();
  const cardsId = useId();
  const [expanded, setExpanded] = useState(defaultExpanded);
  const [browseState, dispatchBrowse] = useReducer(imageGroupBrowseReducer, {
    frontIndex: 0,
    leftCount: 0,
  });
  const [previewOpen, setPreviewOpen] = useState(false);
  const [previewInstantMotion, setPreviewInstantMotion] = useState(false);
  const cardsRef = useRef<HTMLDivElement | null>(null);
  const cardElementsRef = useRef<(HTMLButtonElement | null)[]>([]);
  const previewReturnFocusRef = useRef<HTMLElement | null>(null);
  const pendingFlightRef = useRef<PendingFlight | null>(null);
  const activeFlightsRef = useRef(
    new Map<
      HTMLButtonElement,
      { animation: Animation; timer: ReturnType<typeof setTimeout> }
    >()
  );
  const pendingFlipRef = useRef<PendingFlip | null>(null);
  const flipCleanupRef = useRef<(() => void) | null>(null);
  const keyboardFocusMotion = useKeyboardFocusMotion();
  const pressFeedback = usePointerPressFeedback<HTMLButtonElement>();

  const count = images.length;
  const stackable = count > STACK_THRESHOLD;
  const isExpanded = stackable ? expanded : true;
  const front = normalizedImageIndex(browseState.frontIndex, count);
  const frontImage = images[front];
  const leftCount = Math.min(
    Math.max(browseState.leftCount, 0),
    Math.max(count - 1, 0)
  );
  const previewDownloadController = useChatPanelMediaDownloadController({
    action: frontImage?.download,
    kind: "image",
    source: frontImage?.src ?? "",
  });

  const navigatePreview = useCallback(
    (step: 1 | -1) => {
      dispatchBrowse({ count, step, type: "navigate-preview" });
    },
    [count]
  );

  useEffect(() => {
    if (!previewOpen) return;
    previewReturnFocusRef.current =
      cardElementsRef.current[front] ?? previewReturnFocusRef.current;
  }, [front, previewOpen]);

  useEffect(() => {
    if (previewOpen) return;
    previewReturnFocusRef.current?.focus();
  }, [previewOpen]);

  useEffect(
    () => () => {
      for (const [, flight] of activeFlightsRef.current) {
        clearTimeout(flight.timer);
        flight.animation.cancel();
      }
      activeFlightsRef.current.clear();
      flipCleanupRef.current?.();
    },
    []
  );

  const retireActiveFlights = () => {
    pendingFlightRef.current = null;
    const flights = activeFlightsRef.current;
    for (const [element, flight] of flights) {
      // Delete first: the animation's cancel handler must not be allowed to
      // clean a replacement flight that reuses the same card.
      flights.delete(element);
      clearTimeout(flight.timer);
      flight.animation.cancel();
      delete element.dataset.flying;
      element.style.removeProperty("z-index");
    }
  };

  // Throws the outgoing front card onto its side pile, matching the
  // frame-measured reference: it swings well past the fan slot staying fully
  // opaque and on top, then a long soft settle pulls it back into the tight
  // fan position while it slips under the new front.
  useLayoutEffect(() => {
    const pending = pendingFlightRef.current;
    pendingFlightRef.current = null;
    if (!pending) return;
    const { element, fromOpacity, fromTransform, step } = pending;
    if (element.offsetWidth === 0 || typeof element.animate !== "function") return;

    const flights = activeFlightsRef.current;

    // Suppress the slot transition BEFORE reading the settled style — with a
    // transition freshly started, the computed transform still reports the
    // pre-flip value at progress zero.
    element.dataset.flying = "true";
    element.style.zIndex = "6";
    const settledStyle = getComputedStyle(element);
    const to =
      settledStyle.transform === "none" ? "translateX(0px)" : settledStyle.transform;
    const side = step === 1 ? -1 : 1;
    const apex = `translateX(${Math.round(element.offsetWidth * 0.7 * side)}px) rotate(${9 * side}deg) scale(0.96)`;
    const animation = element.animate(
      [
        {
          easing: motionEasing.drawer,
          opacity: fromOpacity,
          transform: fromTransform === "none" ? "translateX(0px)" : fromTransform,
        },
        {
          easing: motionEasing.softInOut,
          offset: 0.4,
          opacity: "1",
          transform: apex,
        },
        { opacity: settledStyle.opacity, transform: to },
      ],
      { duration: FLIGHT_DURATION_MS }
    );
    const timer = setTimeout(() => {
      element.style.removeProperty("z-index");
    }, FLIGHT_DURATION_MS * FLIGHT_LAYER_SWAP_AT);
    const record = { animation, timer };
    flights.set(element, record);
    const settle = () => {
      if (flights.get(element) !== record) return;
      flights.delete(element);
      clearTimeout(timer);
      delete element.dataset.flying;
      element.style.removeProperty("z-index");
    };
    animation.addEventListener("finish", settle);
    animation.addEventListener("cancel", settle);
  }, [front]);

  // FLIP pass for expand/collapse: every card is pinned at its captured
  // visual transform, then released so CSS transitions carry it into the new
  // layout while the wrapper height glides between the two footprints.
  useLayoutEffect(() => {
    const flip = pendingFlipRef.current;
    pendingFlipRef.current = null;
    if (!flip) return;
    const wrapper = cardsRef.current;
    if (!wrapper) return;

    flipCleanupRef.current?.();
    const wrapperRect = wrapper.getBoundingClientRect();
    if (wrapperRect.width === 0 && wrapperRect.height === 0) return;
    const wrapperDx = flip.wrapperLeft - wrapperRect.left;
    const wrapperDy = flip.wrapperTop - wrapperRect.top;
    const targetHeight = wrapper.offsetHeight;

    // Cascade order follows deck depth: unfurling leads with the front card,
    // regathering mirrors the path so the deepest cards tuck in first.
    const staggerStep = isExpanded ? FLIP_EXPAND_STAGGER_MS : FLIP_COLLAPSE_STAGGER_MS;
    const maxOrder = stackDepthForSlot("0");
    let longestDelay = 0;

    const pinnedCards: HTMLButtonElement[] = [];
    for (let index = 0; index < count; index += 1) {
      const element = cardElementsRef.current[index];
      const captured = flip.cards.get(index);
      if (!element || !captured || element.offsetWidth === 0) continue;
      const box = layoutBoxOf(element);
      const scale = (captured.scale * captured.box.width) / box.width;
      const dx =
        captured.box.left +
        captured.box.width / 2 +
        captured.x +
        wrapperDx -
        (box.left + box.width / 2);
      const dy =
        captured.box.top +
        captured.box.height / 2 +
        captured.y +
        wrapperDy -
        (box.top + box.height / 2);
      const order = maxOrder - captured.depth;
      const delay = (isExpanded ? order : maxOrder - order) * staggerStep;
      longestDelay = Math.max(longestDelay, delay);
      element.dataset.flip = "true";
      element.style.transform = `translate(${dx}px, ${dy}px) rotate(${captured.rotation}deg) scale(${scale})`;
      element.style.opacity = String(captured.opacity);
      element.style.zIndex = String(10 + captured.depth);
      element.style.transitionDelay = `${delay}ms, ${delay}ms, 0ms`;
      pinnedCards.push(element);
    }

    wrapper.style.height = `${flip.wrapperHeight}px`;
    void wrapper.offsetHeight;
    wrapper.dataset.heightAnimating = "true";

    const releaseFrame = requestAnimationFrame(() => {
      for (const element of pinnedCards) {
        delete element.dataset.flip;
        element.style.removeProperty("transform");
        element.style.removeProperty("opacity");
      }
      wrapper.style.height = `${targetHeight}px`;
    });
    const settleTimer = setTimeout(
      () => {
        flipCleanupRef.current?.();
      },
      FLIP_DURATION_MS + longestDelay + FLIP_CLEANUP_BUFFER_MS
    );

    flipCleanupRef.current = () => {
      flipCleanupRef.current = null;
      cancelAnimationFrame(releaseFrame);
      clearTimeout(settleTimer);
      for (const element of pinnedCards) {
        delete element.dataset.flip;
        element.style.removeProperty("transform");
        element.style.removeProperty("opacity");
        element.style.removeProperty("z-index");
        element.style.removeProperty("transition-delay");
      }
      delete wrapper.dataset.heightAnimating;
      wrapper.style.removeProperty("height");
    };
  }, [count, isExpanded]);

  if (count === 0) return null;

  const resolvedPreviewTitle = previewTitle ?? messages.chat_image_group_preview();

  // The left button pushes the front card onto the LEFT history pile and
  // reveals the next card; the right button returns it to the RIGHT pile and
  // brings the previous one back. Every card only ever moves one slot in the
  // click's direction, so plain CSS transitions carry the whole rotation.
  const rotate = (step: 1 | -1) => {
    retireActiveFlights();
    const outgoing = cardElementsRef.current[front];
    if (outgoing && !isReducedMotionEnabled()) {
      const style = getComputedStyle(outgoing);
      pendingFlightRef.current = {
        element: outgoing,
        fromOpacity: style.opacity,
        fromTransform: style.transform,
        step,
      };
    }
    dispatchBrowse({ count, step, type: "rotate-deck" });
  };

  const toggleExpanded = () => {
    const wrapper = cardsRef.current;
    if (wrapper && !isReducedMotionEnabled()) {
      const wrapperRect = wrapper.getBoundingClientRect();
      const cards = new Map<number, CapturedCard>();
      for (let index = 0; index < count; index += 1) {
        const element = cardElementsRef.current[index];
        if (!element) continue;
        const style = getComputedStyle(element);
        // The deck exists on one side of the toggle either way; its slot
        // depth keeps the paint order stable while cards are in flight.
        const slot = stackSlotForDistance(index, front, count, leftCount);
        cards.set(index, {
          box: layoutBoxOf(element),
          depth: stackDepthForSlot(slot),
          opacity: Number(style.opacity),
          ...decomposeTransform(style.transform),
        });
      }
      pendingFlipRef.current = {
        cards,
        wrapperHeight: wrapperRect.height,
        wrapperLeft: wrapperRect.left,
        wrapperTop: wrapperRect.top,
      };
    }
    // The FLIP snapshot above already captured the current animated pose. Stop
    // WAAPI from continuing to own transform/opacity while the layout pass
    // pins and releases that snapshot into the next state.
    retireActiveFlights();
    const next = !isExpanded;
    setExpanded(next);
    onExpandedChange?.(next);
  };

  const openPreview =
    (index: number) => (event: ReactMouseEvent<HTMLButtonElement>) => {
      previewReturnFocusRef.current = event.currentTarget;
      dispatchBrowse({ count, index, type: "align-preview" });
      setPreviewInstantMotion(event.detail === 0);
      setPreviewOpen(true);
    };

  return (
    <>
      <figure
        aria-label={messages.chat_image_group_label({ count: String(count) })}
        className={cx("chat-panel-image-group", className)}
      >
        {stackable ? (
          <button
            aria-controls={cardsId}
            aria-expanded={isExpanded}
            aria-label={
              isExpanded
                ? messages.chat_image_group_hide()
                : messages.chat_image_group_expand({ count: String(count) })
            }
            className="chat-panel-image-group-toggle"
            {...pressFeedback}
            onClick={toggleExpanded}
            type="button"
          >
            <span aria-hidden className="chat-panel-image-group-toggle-label">
              <span className="chat-panel-image-group-toggle-text" data-label="expand">
                {messages.chat_image_group_expand({ count: String(count) })}
              </span>
              <span className="chat-panel-image-group-toggle-text" data-label="hide">
                {messages.chat_image_group_hide()}
              </span>
            </span>
          </button>
        ) : null}
        <div
          className="chat-panel-image-group-cards"
          data-expanded={isExpanded ? "true" : "false"}
          id={cardsId}
          ref={cardsRef}
          {...keyboardFocusMotion}
        >
          {images.map((image, index) => {
            const slot = isExpanded
              ? undefined
              : stackSlotForDistance(index, front, count, leftCount);
            const interactive = isExpanded || slot === "0";
            // Parked fan cards stay in layout for FLIP, but they must not keep
            // decoded bitmaps (or compositor layers) while opacity is 0.
            const paintsImage = slot !== "hidden-right" && slot !== "hidden-left";
            return (
              <button
                aria-hidden={interactive ? undefined : true}
                className="chat-panel-image-group-card"
                data-stack-pos={slot}
                inert={interactive ? undefined : true}
                key={index}
                {...pressFeedback}
                data-media-context-menu={image.onContextMenu ? "true" : undefined}
                onContextMenu={image.onContextMenu}
                onClick={openPreview(index)}
                ref={(element) => {
                  cardElementsRef.current[index] = element;
                }}
                type="button"
              >
                {paintsImage ? (
                  <img
                    alt={image.alt}
                    className="chat-panel-image-group-card-content"
                    decoding="async"
                    loading={isExpanded ? "lazy" : "eager"}
                    src={image.src}
                  />
                ) : null}
              </button>
            );
          })}
          {stackable && !isExpanded ? (
            <>
              <button
                aria-label={messages.chat_image_group_next()}
                className="chat-panel-image-group-advance"
                data-side="start"
                {...pressFeedback}
                onClick={() => rotate(1)}
                type="button"
              >
                <ChevronLeftSmallIcon className="size-2xl" />
              </button>
              <button
                aria-label={messages.chat_image_group_previous()}
                className="chat-panel-image-group-advance"
                data-side="end"
                {...pressFeedback}
                onClick={() => rotate(-1)}
                type="button"
              >
                <ChevronRightSmallIcon className="size-2xl" />
              </button>
            </>
          ) : null}
        </div>
        <span aria-live="polite" className="sr-only">
          {stackable && !isExpanded && frontImage
            ? messages.chat_image_group_position({
                alt: frontImage.alt,
                count: String(count),
                position: String(front + 1),
              })
            : ""}
        </span>
      </figure>
      {previewOpen ? (
        <ChatPanelMediaPreview
          actions={
            frontImage?.download ? (
              <ChatPanelMediaDownloadControl
                buttonClassName="chat-panel-media-preview-action"
                controller={previewDownloadController}
                feedbackPlacement="below"
                icon={<DownloadIcon className="size-2xl" />}
                kind="image"
              />
            ) : undefined
          }
          instantMotion={previewInstantMotion}
          isOpen={previewOpen}
          onOpenChange={setPreviewOpen}
          returnFocusRef={previewReturnFocusRef}
          title={resolvedPreviewTitle}
          variant="filmstrip"
        >
          <ChatPanelImageFilmstrip
            images={images}
            index={front}
            onNavigate={navigatePreview}
          />
        </ChatPanelMediaPreview>
      ) : null}
    </>
  );
};
