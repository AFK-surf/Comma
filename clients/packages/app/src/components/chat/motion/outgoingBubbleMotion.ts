import {
  motionDuration,
  motionEasing,
  motionMessageSend,
  type MessageSendMotionConfig,
} from "@comma/ui";
import tailSVG from "../assets/message-tail.svg?raw";
import { createOutgoingBubbleTimeline } from "./outgoingBubbleMotionModel";

// The supplied tail uses absolute M/C coordinates. Transform the same outline
// used by the resting bubble so the final animation frame joins it exactly.
const tailCommands = tailSVG.match(/\sd="([^"]+)"/)![1]!.match(/[MCZ]|-?\d*\.?\d+/g)!;
function tailedFlightClip(
  left: number,
  top: number,
  right: number,
  bottom: number,
  radius: number
) {
  let coordinate = 0;
  const tail = tailCommands
    .map((token) => {
      if (/^[MCZ]$/.test(token)) {
        coordinate = 0;
        return token;
      }
      const origin = coordinate++ % 2 === 0 ? right - 24 : bottom - 8 / 3;
      return String(origin + (Number(token) * 2) / 3);
    })
    .join(" ");
  return `path("M ${left} ${top + radius} A ${radius} ${radius} 0 0 1 ${left + radius} ${top} H ${right - radius} A ${radius} ${radius} 0 0 1 ${right} ${top + radius} V ${bottom - radius} A ${radius} ${radius} 0 0 1 ${right - radius} ${bottom} H ${left + radius} A ${radius} ${radius} 0 0 1 ${left} ${bottom - radius} Z ${tail}")`;
}

const textStyleProperties = [
  "fontFamily",
  "fontSize",
  "fontWeight",
  "fontStyle",
  "letterSpacing",
  "lineHeight",
  "color",
] as const;
type OutgoingTextStyle = Pick<
  CSSStyleDeclaration,
  (typeof textStyleProperties)[number]
>;

export type OutgoingBubbleFrame = {
  bottom: number;
  height: number;
  left: number;
  right: number;
  top: number;
  width: number;
  radius?: number;
  textLeft?: number;
  textTop?: number;
  textWidth?: number;
  textStyle?: OutgoingTextStyle;
  background?: string;
  chrome?: HTMLElement | undefined;
  tailAnchor?:
    | { element: HTMLElement; edge: "top" | "bottom"; height: number }
    | undefined;
};

function firstGlyph(root: HTMLElement) {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  // Rich-editor mentions can prefix text with empty positioning nodes.
  for (let index = 0; index < 64; index += 1) {
    const node = walker.nextNode();
    if (!node) break;
    if (!node.textContent?.length) continue;
    const range = document.createRange();
    range.setStart(node, 0);
    range.setEnd(node, 1);
    const rect = range.getBoundingClientRect?.();
    if (rect && rect.width > 0 && rect.height > 0) return rect;
  }
  return undefined;
}

function readTextStyle(style: CSSStyleDeclaration): OutgoingTextStyle {
  return Object.fromEntries(
    textStyleProperties.map((property) => [property, style[property]])
  ) as OutgoingTextStyle;
}

function captureComposerChrome(
  element: HTMLElement,
  rect: DOMRect,
  style: CSSStyleDeclaration
) {
  const chrome = document.createElement("div");
  chrome.className = "comma-chat-outgoing-composer-chrome";
  chrome.setAttribute("aria-hidden", "true");
  chrome.inert = true;
  Object.assign(chrome.style, {
    width: `${rect.width}px`,
    height: `${rect.height}px`,
    border: style.border,
    borderRadius: style.borderRadius,
    boxShadow: style.boxShadow,
  });
  // Only chrome is copied, never the draft. One bounded snapshot per send;
  // the message's single content node owns its text throughout the morph.
  for (const button of Array.from(element.querySelectorAll("button")).slice(0, 16)) {
    const box = button.getBoundingClientRect();
    if (box.width <= 0 || box.height <= 0) continue;
    const buttonStyle = getComputedStyle(button);
    const copy = button.cloneNode(true) as HTMLButtonElement;
    for (const node of [copy, ...copy.querySelectorAll("[id], [data-testid]")]) {
      node.removeAttribute("id");
      node.removeAttribute("data-testid");
    }
    Object.assign(copy.style, {
      position: "absolute",
      inset: "auto",
      margin: "0",
      left: `${box.left - rect.left - (parseFloat(style.borderLeftWidth) || 0)}px`,
      top: `${box.top - rect.top - (parseFloat(style.borderTopWidth) || 0)}px`,
      width: `${box.width}px`,
      height: `${box.height}px`,
      minWidth: "0",
      maxWidth: "none",
      background: buttonStyle.background,
      border: buttonStyle.border,
      borderRadius: buttonStyle.borderRadius,
      boxShadow: buttonStyle.boxShadow,
      color: buttonStyle.color,
      opacity: buttonStyle.opacity,
      padding: buttonStyle.padding,
      transform: "none",
      transition: "none",
    });
    chrome.append(copy);
  }
  return chrome.childElementCount > 0 || parseFloat(style.borderTopWidth) > 0
    ? chrome
    : undefined;
}

export function measureOutgoingBubbleSource(element: HTMLElement | null | undefined) {
  const rect = element?.getBoundingClientRect();
  const style = element ? getComputedStyle(element) : undefined;
  const editor = element?.querySelector<HTMLElement>('[role="textbox"]');
  const editorRect = editor?.getBoundingClientRect();
  const editorStyle = editor ? getComputedStyle(editor) : undefined;
  const glyph = editor ? firstGlyph(editor) : undefined;
  const latest = element
    ?.closest(".comma-chat-route")
    ?.querySelector<HTMLElement>(
      '.comma-chat-turn-shell[data-chat-latest-turn="true"]'
    );
  const preceding = latest?.previousElementSibling;
  const anchor =
    preceding instanceof HTMLElement && preceding.matches(".comma-chat-turn-shell")
      ? preceding
      : latest;
  const edge = anchor === latest ? ("top" as const) : ("bottom" as const);
  return {
    tailAnchor:
      latest && anchor
        ? {
            element: anchor,
            edge,
            height:
              latest.closest(".comma-chat-column")!.getBoundingClientRect().bottom -
              anchor.getBoundingClientRect()[edge],
          }
        : undefined,
    bottom: rect?.bottom ?? 0,
    height: rect?.height ?? 0,
    left: rect?.left ?? 0,
    right: rect?.right ?? 0,
    top: rect?.top ?? 0,
    width: rect?.width ?? 0,
    ...(element && rect && style
      ? {
          background: style.backgroundColor,
          chrome: captureComposerChrome(element, rect, style),
        }
      : {}),
    radius: Math.min(
      parseFloat(style?.borderTopLeftRadius ?? "0") || 0,
      (rect?.height ?? 0) / 2,
      (rect?.width ?? 0) / 2
    ),
    ...(editorRect && editorStyle
      ? {
          textLeft:
            glyph?.left ?? editorRect.left + (parseFloat(editorStyle.paddingLeft) || 0),
          textTop:
            glyph?.top ?? editorRect.top + (parseFloat(editorStyle.paddingTop) || 0),
          textWidth:
            editorRect.width -
            (parseFloat(editorStyle.paddingLeft) || 0) -
            (parseFloat(editorStyle.paddingRight) || 0),
          textStyle: readTextStyle(editorStyle),
        }
      : {}),
  };
}

/** One live message surface: a rounded outline morph plus a uniform bubble/text pulse. */
export type OutgoingBubblePlaybackRate = 0.25 | 0.5 | 0.75 | 1;

export function animateOutgoingBubble({
  bubble,
  content,
  slot,
  source,
  config = motionMessageSend,
  playbackRate = 1,
  reducedMotion,
  onComplete,
}: {
  bubble: HTMLElement;
  content: HTMLElement;
  slot: HTMLElement;
  source: OutgoingBubbleFrame;
  config?: MessageSendMotionConfig | undefined;
  playbackRate?: OutgoingBubblePlaybackRate | undefined;
  reducedMotion: boolean;
  onComplete: () => void;
}) {
  const hasTail = Boolean(bubble.closest('[data-bubble-tail="right"]'));
  const target = bubble.getBoundingClientRect();
  const viewport = slot.closest<HTMLElement>('[data-slot="scroll-area-viewport"]');
  // A preceding flight can still release its own reserve. Only a stable
  // layout gives this flight a final anchor to project during slot expansion.
  const otherFlight = slot
    .closest(".comma-chat-column")
    ?.querySelector('[data-outgoing-presentation="flying"]');
  const targetScrollTop = otherFlight ? undefined : viewport?.scrollTop;
  const turn = slot.closest<HTMLElement>(
    '.comma-chat-turn-shell[data-chat-outgoing-turn="true"]'
  );
  const layoutOwner = turn ?? slot;
  const targetLayoutHeight = layoutOwner.getBoundingClientRect().height;

  const style = getComputedStyle(bubble);
  // Tailed bubbles paint their material on a masked pseudo-element, leaving
  // the outer background transparent. The flight still needs that material.
  const targetBackground =
    style.getPropertyValue("--comma-chat-user-bubble-background").trim() ||
    style.backgroundColor;
  const targetTextStyle = readTextStyle(getComputedStyle(content));
  const targetTextWidth = content.getBoundingClientRect().width;
  const targetRadius = parseFloat(style.borderTopLeftRadius) || 17;
  const paddingLeft = parseFloat(style.paddingLeft) || 0;
  const paddingTop = parseFloat(style.paddingTop) || 0;
  const hasSource = source.width > 0 && source.height > 0;
  const start = hasSource ? source : target;
  const sourceRadius = Math.min(
    source.radius ?? start.height / 2,
    start.height / 2,
    start.width / 2
  );
  const dx = start.right - target.right;
  const dy = start.bottom - target.bottom;
  const timeline = createOutgoingBubbleTimeline(config, {
    width: target.width - start.width,
    position: Math.hypot(dx, dy),
    height: target.height - start.height,
  });
  const duration = reducedMotion ? motionDuration.stateChange : timeline.durationMs;
  const materialStart = Math.min(
    ...Object.values(timeline.channels).map((channel) => channel.delayMs),
    timeline.config.surfacePulse.delayMs
  );
  const materialEnd = Math.min(duration, materialStart + motionDuration.stateChange);
  let animation: Animation | undefined;
  let contentAnimation: Animation | undefined;
  let chromeAnimation: Animation | undefined;
  let slotAnimation: Animation | undefined;
  let turnAnimation: Animation | undefined;
  let startFrame: number | undefined;
  let frame: number | undefined;
  let timer: number | undefined;
  let popoverOpen = false;
  let settled = false;
  let updateReserve: (() => void) | undefined;
  let reserve: HTMLElement | undefined;

  const settle = (notify: boolean) => {
    if (settled) return;
    settled = true;
    if (frame !== undefined) cancelAnimationFrame(frame);
    if (startFrame !== undefined) cancelAnimationFrame(startFrame);
    if (timer !== undefined) clearTimeout(timer);
    animation?.cancel();
    contentAnimation?.cancel();
    chromeAnimation?.cancel();
    slotAnimation?.cancel();
    turnAnimation?.cancel();
    reserve?.remove();
    source.chrome?.remove();
    if (popoverOpen && bubble.matches(":popover-open")) bubble.hidePopover();
    bubble.removeAttribute("popover");
    bubble.removeAttribute("data-outgoing-presentation");
    for (const property of [
      "height",
      "inset",
      "left",
      "margin",
      "max-width",
      "position",
      "top",
      "transform",
      "transform-origin",
      "translate",
      "width",
      "z-index",
      "clip-path",
      "--comma-chat-flight-width",
      "--comma-chat-flight-height",
      "--comma-chat-flight-tail-depth",
    ])
      bubble.style.removeProperty(property);
    slot.removeAttribute("data-outgoing-presentation-slot");
    slot.style.removeProperty("height");
    slot.style.removeProperty("width");
    content.style.removeProperty("will-change");
    content.style.removeProperty("width");
    for (const property of textStyleProperties) content.style[property] = "";
    if (notify) onComplete();
  };

  bubble.dataset.outgoingPresentation = "flying";
  bubble.style.setProperty("--comma-chat-flight-tail-depth", hasTail ? "7px" : "0px");
  if (!reducedMotion) {
    if (turn && typeof turn.animate === "function") {
      const turnStyle = getComputedStyle(turn);
      const minimumHeight = parseFloat(turnStyle.minHeight) || 0;
      const bottomPadding = parseFloat(turnStyle.paddingBottom) || 0;
      // The latest turn reserves room for the reply outside the bubble slot.
      // Grow that reserve on the same clock, or it masks the slot's expansion.
      turnAnimation = turn.animate(
        timeline.frames.map(({ offset, height }) => {
          const progress = Math.max(0, Math.min(1, height));
          return {
            offset,
            minHeight: `${minimumHeight * progress}px`,
            paddingBottom: `${bottomPadding * progress}px`,
          };
        }),
        { duration, easing: "linear", fill: "both" }
      );
      turnAnimation.pause();
      turnAnimation.currentTime = 0;
    }
    slot.dataset.outgoingPresentationSlot = "true";
    slot.style.width = `${target.width}px`;
    slot.style.height = `${target.height}px`;
    if (typeof slot.animate === "function") {
      slotAnimation = slot.animate(
        timeline.frames.map(({ offset, height }) => ({
          offset,
          height: `${target.height * Math.max(0, Math.min(1, height))}px`,
        })),
        { duration, easing: "linear", fill: "both" }
      );
      slotAnimation.pause();
      slotAnimation.currentTime = 0;
    }
    bubble.setAttribute("popover", "manual");
    try {
      bubble.showPopover();
      popoverOpen = true;
    } catch {
      // Fixed positioning also supports DOM environments without the top layer.
    }
    Object.assign(bubble.style, {
      position: "fixed",
      inset: "auto",
      left: `${target.left}px`,
      top: `${target.top}px`,
      width: `${target.width}px`,
      height: `${target.height}px`,
      maxWidth: "none",
      margin: "0",
      zIndex: "8",
      transformOrigin: "right bottom",
    });
    const previous = source.tailAnchor;
    const column = slot.closest<HTMLElement>(".comma-chat-column");
    if (column && turn && previous?.element.isConnected) {
      reserve = document.createElement("div");
      reserve.dataset.outgoingReserve = "true";
      reserve.setAttribute("aria-hidden", "true");
      Object.assign(reserve.style, {
        flex: "none",
        height: "0px",
        marginTop: `${-(parseFloat(getComputedStyle(column).rowGap) || 0)}px`,
        pointerEvents: "none",
      });
      column.append(reserve);
      const tail = reserve;
      // Transfer existing tail space to the growing turn without locking history.
      updateReserve = () => {
        if (!previous.element.isConnected) return;
        const naturalHeight =
          column.getBoundingClientRect().bottom -
          previous.element.getBoundingClientRect()[previous.edge] -
          tail.getBoundingClientRect().height;
        tail.style.height = `${Math.max(0, previous.height - naturalHeight)}px`;
      };
      updateReserve();
    }
    // A larger material plane is clipped into the changing rounded rectangle.
    // Its dimensions are fixed for the flight and never reflow the transcript.
    bubble.style.setProperty(
      "--comma-chat-flight-width",
      `${Math.max(start.width, target.width) + timeline.config.width.maxOvershootPx}px`
    );
    bubble.style.setProperty(
      "--comma-chat-flight-height",
      `${Math.max(start.height, target.height) + timeline.config.height.maxOvershootPx}px`
    );
  }

  const shapeFrames = timeline.frames;
  const keyframes: Keyframe[] = reducedMotion
    ? [
        { offset: 0, opacity: 0, transform: "none" },
        { offset: 1, opacity: 1, transform: "none" },
      ]
    : [
        ...shapeFrames.map(({ offset, width, position, height, surfaceScale }) => {
          const paintedWidth = start.width + (target.width - start.width) * width;
          const paintedHeight = start.height + (target.height - start.height) * height;
          const radiusProgress = Math.max(0, Math.min(1, width, height));
          const radius = Math.min(
            sourceRadius + (targetRadius - sourceRadius) * radiusProgress,
            paintedWidth / 2,
            paintedHeight / 2
          );
          return {
            offset,
            transform: `translate3d(${dx * (1 - position)}px, ${dy * (1 - position)}px, 0) scale(${surfaceScale})`,
            clipPath: hasTail
              ? tailedFlightClip(
                  target.width - paintedWidth,
                  target.height - paintedHeight,
                  target.width,
                  target.height,
                  Math.max(0, radius)
                )
              : `inset(${target.height - paintedHeight}px 0px 0px ${target.width - paintedWidth}px round ${Math.max(0, radius)}px)`,
          };
        }),
        { offset: 0, backgroundColor: source.background ?? targetBackground },
        {
          offset: materialStart / duration,
          backgroundColor: source.background ?? targetBackground,
        },
        { offset: materialEnd / duration, backgroundColor: targetBackground },
        { offset: 1, backgroundColor: targetBackground },
      ];
  keyframes.sort((a, b) => Number(a.offset) - Number(b.offset));
  if (typeof bubble.animate !== "function") {
    timer = window.setTimeout(() => settle(true), duration / playbackRate);
    return { cleanup: () => settle(false) };
  }
  const timing = {
    duration,
    easing: "linear",
    fill: "both" as const,
  };
  animation = bubble.animate(keyframes, timing);
  animation.pause?.();
  animation.currentTime = 0;
  if (!reducedMotion && typeof content.animate === "function") {
    // Use the final text layout from frame zero. The input-sized rounded clip
    // contains overflow while the whole surface travels and scales.
    Object.assign(content.style, targetTextStyle, { width: `${targetTextWidth}px` });
    const glyph = firstGlyph(content);
    const textX =
      (source.textLeft ?? start.left + paddingLeft) -
      (glyph?.left ?? target.left + paddingLeft + dx);
    const textY =
      (source.textTop ?? start.top + paddingTop) -
      (glyph?.top ?? target.top + paddingTop + dy);
    content.style.willChange = "transform";
    const sourceColor = source.textStyle?.color ?? targetTextStyle.color;
    const colorChange =
      (materialStart + (materialEnd - materialStart) * 0.8) / duration;
    const contentFrames: Keyframe[] = [
      ...shapeFrames.map(({ offset, width, height }) => ({
        offset,
        transform: `translate3d(${textX * (1 - width)}px, ${textY * (1 - height)}px, 0)`,
      })),
      // Keep text readable as the input material becomes the blue user bubble.
      { offset: 0, color: sourceColor },
      { offset: colorChange, color: sourceColor },
      { offset: colorChange, color: targetTextStyle.color },
      { offset: 1, color: targetTextStyle.color },
    ];
    contentFrames.sort((a, b) => Number(a.offset) - Number(b.offset));
    contentAnimation = content.animate(contentFrames, timing);
    contentAnimation.pause?.();
    contentAnimation.currentTime = 0;
    if (source.chrome) {
      bubble.append(source.chrome);
      chromeAnimation = source.chrome.animate([{ opacity: 1 }, { opacity: 0 }], {
        duration: motionDuration.stateChange,
        delay: materialStart,
        easing: motionEasing.softInOut,
        fill: "both",
      });
      chromeAnimation.pause?.();
      chromeAnimation.currentTime = 0;
    }
  }

  // A paused frame zero must be painted before the clock starts. Starting
  // against the commit's timeline timestamp can skip the input state when
  // the rest of the transcript takes time to render.
  startFrame = requestAnimationFrame(() => {
    startFrame = requestAnimationFrame(() => {
      if (settled) return;
      const startTime = document.timeline?.currentTime;
      for (const active of [
        animation,
        contentAnimation,
        chromeAnimation,
        slotAnimation,
        turnAnimation,
      ]) {
        if (!active) continue;
        active.playbackRate = playbackRate;
        active.play?.();
        if (startTime != null) active.startTime = startTime;
      }
    });
  });

  // Resolve the final slot edge without its animated height. History, errors,
  // and viewport changes can move it independently of the height spring.
  // Retarget from the current correction on the same playback clock.
  const bottomAligned = Boolean(
    slot.closest('.comma-chat-route[data-variant="side-chat"]')
  );
  let correction = 0;
  let correctionFrom = 0;
  let correctionTarget = 0;
  let correctionStartedAt = 0;
  const maintainReserve = () => {
    if (settled) return;
    updateReserve?.();
    if (viewport) {
      const elapsed = Number(animation.currentTime ?? 0);
      const channel = timeline.channels.position;
      const remainingProgress = channel.at(duration - correctionStartedAt);
      const correctionProgress =
        remainingProgress > 0
          ? Math.min(1, channel.at(elapsed - correctionStartedAt) / remainingProgress)
          : 1;
      correction =
        correctionFrom + (correctionTarget - correctionFrom) * correctionProgress;
      const slotBox = slot.getBoundingClientRect();
      // Slot expansion temporarily clamps the already-measured route anchor
      // to a smaller scroll range. Remove that predictable displacement before
      // retargeting, or a second spring chases our own layout and lands late.
      const anchorClamp =
        bottomAligned || targetScrollTop === undefined
          ? 0
          : Math.max(
              -Math.max(
                0,
                targetLayoutHeight - layoutOwner.getBoundingClientRect().height
              ),
              Math.min(
                targetScrollTop,
                Math.max(0, viewport.scrollHeight - viewport.clientHeight)
              ) - targetScrollTop
            );
      const destinationBottom = bottomAligned
        ? slotBox.bottom
        : slotBox.top + target.height + anchorClamp;
      const displacement = destinationBottom - target.bottom;
      if (Math.abs(displacement - correctionTarget) > 0.5) {
        correctionFrom = correction;
        correctionTarget = displacement;
        correctionStartedAt = elapsed;
      }
      bubble.style.translate = `0px ${correction}px`;
    }
    frame = requestAnimationFrame(maintainReserve);
  };
  if (!reducedMotion) frame = requestAnimationFrame(maintainReserve);
  void animation.finished.then(
    () => {
      frame = requestAnimationFrame(() => settle(true));
    },
    () => undefined
  );
  return { animation, cleanup: () => settle(false) };
}
