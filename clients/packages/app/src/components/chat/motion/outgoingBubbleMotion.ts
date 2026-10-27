import {
  motionDuration,
  motionEasing,
  motionMessageSend,
  type MessageSendMotionConfig,
} from "@comma/ui/tokens";
import { scheduleLayoutRead, uiClock, type CancelUiTimer } from "@comma/ui/clock";
import tailSVG from "../assets/message-tail.svg?raw";
import { materialKeyframes } from "./materialKeyframes";
import { createOutgoingBubbleTimeline } from "./outgoingBubbleMotionModel";

// The supplied tail uses absolute M/C coordinates. Transform the same outline
// used by the resting bubble so the final animation frame joins it exactly.
const tailCommands = tailSVG.match(/\sd="([^"]+)"/)![1]!.match(/[MCZ]|-?\d*\.?\d+/g)!;
function tailedFlightClip(
  left: number,
  top: number,
  right: number,
  bottom: number,
  radius: number,
  mirrored: boolean
) {
  // A tail on the start side (the resting bubble flips its tail's mask) flips
  // the whole outline about the shape's middle: the rounded rectangle and the
  // tail keep one winding, so they still add up to one shape.
  const x = (value: number) => (mirrored ? left + right - value : value);
  const arcSweep = mirrored ? 0 : 1;
  let coordinate = 0;
  const tail = tailCommands
    .map((token) => {
      if (/^[MCZ]$/.test(token)) {
        coordinate = 0;
        return token;
      }
      return coordinate++ % 2 === 0
        ? String(x(right - 24 + (Number(token) * 2) / 3))
        : String(bottom - 8 / 3 + (Number(token) * 2) / 3);
    })
    .join(" ");
  return `path("M ${x(left)} ${top + radius} A ${radius} ${radius} 0 0 ${arcSweep} ${x(left + radius)} ${top} H ${x(right - radius)} A ${radius} ${radius} 0 0 ${arcSweep} ${x(right)} ${top + radius} V ${bottom - radius} A ${radius} ${radius} 0 0 ${arcSweep} ${x(right - radius)} ${bottom} H ${x(left + radius)} A ${radius} ${radius} 0 0 ${arcSweep} ${x(left)} ${bottom - radius} Z ${tail}")`;
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
  return {
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

/**
 * The slot's growth, played on the compositor: where `host` and the elements
 * that keep to the slot's bottom (`data-outgoing-follow`) sit with the slot
 * collapsed and at its full height, and a move from the first to the second
 * on the height curve. The returned animations wait, paused, for the flight.
 */
function liftSlotGrowth(
  host: HTMLElement,
  slot: HTMLElement,
  height: number,
  frames: readonly { offset: number; height: number }[],
  duration: number
) {
  const followers = Array.from(
    host.querySelectorAll<HTMLElement>("[data-outgoing-follow]")
  );
  const tops = () =>
    [host, ...followers].map((element) => element.getBoundingClientRect().top);
  slot.style.height = "0px";
  const collapsed = tops();
  slot.style.height = `${height}px`;
  const full = tops();
  const hostShift = collapsed[0]! - full[0]!;
  const animations: Animation[] = [];
  const lift = (element: HTMLElement, shift: number) => {
    if (Math.abs(shift) < 0.5) return;
    const animation = element.animate(
      frames.map(({ offset, height: progress }) => ({
        offset,
        translate: `0px ${shift * (1 - Math.max(0, Math.min(1, progress)))}px`,
      })),
      { duration, easing: "linear", fill: "both" }
    );
    animation.pause();
    animation.currentTime = 0;
    animations.push(animation);
  };
  lift(host, hostShift);
  // A follower moves inside the host, so it takes what is left of its own move.
  followers.forEach((follower, index) =>
    lift(follower, collapsed[index + 1]! - full[index + 1]! - hostShift)
  );
  return animations;
}

type GlideFrame = { offset: number; height: number };

/**
 * A flight the transcript column can still move: a later send's glide carries
 * it the way it carries the flight's row, so the two meet when it lands.
 */
type CarriedFlight = {
  carry: (frames: readonly GlideFrame[], shift: number, duration: number) => Animation;
};
const flightsByColumn = new WeakMap<HTMLElement, Set<CarriedFlight>>();
const glidesByColumn = new WeakMap<HTMLElement, Set<Animation>>();
/** Each column's pre-launch holds: how many, and how far they draw it in all. */
const holdsByColumn = new WeakMap<HTMLElement, { count: number; offset: number }>();

const glideProgress = (height: number) => Math.max(0, Math.min(1, height));

/** How far running glides still draw `column` away from its layout. */
function readGlideOffset(column: HTMLElement) {
  if (!glidesByColumn.get(column)?.size) return 0;
  const translate = getComputedStyle(column).translate;
  if (!translate || translate === "none") return 0;
  return Number.parseFloat(translate.split(" ")[1] ?? "0") || 0;
}

/**
 * How far a send's glide still draws `element`'s transcript below its layout.
 * Code that turns a measured position into a scroll offset takes it back out:
 * the glide holds the transcript where it was painted, the layout has moved.
 */
export function transcriptGlideOffset(element: Element) {
  const column = element.closest<HTMLElement>(".comma-chat-column");
  return column ? readGlideOffset(column) : 0;
}

function registerGlide(column: HTMLElement, glide: Animation) {
  let glides = glidesByColumn.get(column);
  if (!glides) {
    glides = new Set();
    glidesByColumn.set(column, glides);
  }
  glides.add(glide);
  column.parentElement?.setAttribute("data-outgoing-glide", "true");
  return () => {
    glides.delete(glide);
    if (glides.size === 0) column.parentElement?.removeAttribute("data-outgoing-glide");
  };
}

/** The newest turn as a message is sent: where its layout put it then. */
export type OutgoingTranscriptAnchor = { turnKey: string; top: number };

/**
 * Where a turn's margin box starts in the layout. Sending moves the newest
 * turn's top margin to the new turn; the margin box keeps its place, so the
 * content above it does not register as a move.
 */
function turnLayoutTop(turn: HTMLElement) {
  return (
    turn.getBoundingClientRect().top -
    (Number.parseFloat(getComputedStyle(turn).marginTop) || 0) -
    transcriptGlideOffset(turn)
  );
}

export function measureOutgoingTranscriptAnchor(
  root: HTMLElement | null | undefined
): OutgoingTranscriptAnchor | undefined {
  const turn = root?.querySelector<HTMLElement>(
    '.comma-chat-turn-shell[data-chat-latest-turn="true"]'
  );
  const turnKey = turn?.dataset.turnKey;
  if (!turn || !turnKey) return undefined;
  return { turnKey, top: turnLayoutTop(turn) };
}

/**
 * Whether a sent message's row is laid out under `viewport` but its flight
 * has not launched yet (holdTranscript). Until it launches, the flight
 * anchors its turn: a follow write in between would move history first.
 */
export function transcriptHeld(viewport: Element | null | undefined) {
  const column = viewport?.querySelector<HTMLElement>(".comma-chat-column");
  return column ? (holdsByColumn.get(column)?.count ?? 0) > 0 : false;
}

export type TranscriptHold = {
  /**
   * Ends the hold. Returns how far up the layout has moved the turn since the
   * send, or nothing once the hold has ended on its own.
   */
  release: () => number | undefined;
  cancel: () => void;
};

/**
 * How long a hold may wait for its flight. A sent row is laid out and its
 * flight launches within a few frames; a window in the background runs no
 * frames, and its transcript is let go instead of waiting for the launch to
 * expire.
 */
const holdLimitMs = 500;

/**
 * Keeps the transcript where it was painted while a sent message is laid out,
 * from the commit that inserts its row until its flight launches. Whatever
 * moves the turn that was newest at the send meanwhile (the mounted window
 * sliding past an old turn, the scroll range clamping to a shorter thread)
 * is drawn back on the column after each layout, before it paints. The
 * flight then eases the whole move out as its glide. A hold that reaches
 * `holdLimitMs` ends on its own; its flight glides only the anchor's move.
 */
export function holdTranscript(
  reference: HTMLElement,
  referenceTop: number
): TranscriptHold | undefined {
  const column = reference.closest<HTMLElement>(".comma-chat-column");
  if (!column || typeof column.animate !== "function") return undefined;
  const hold = column.animate([{ translate: "0px 0px" }, { translate: "0px 0px" }], {
    duration: 1,
    fill: "both",
    composite: "add",
  });
  hold.pause();
  hold.currentTime = 0;
  const unregister = registerGlide(column, hold);
  let holds = holdsByColumn.get(column);
  if (!holds) {
    holds = { count: 0, offset: 0 };
    holdsByColumn.set(column, holds);
  }
  holds.count += 1;
  let offset = 0;
  const layoutTop = () =>
    reference.isConnected ? turnLayoutTop(reference) : undefined;
  const update = () => {
    const top = layoutTop();
    if (top === undefined) return;
    const next = referenceTop - top;
    if (Math.abs(next - offset) < 0.25) return;
    holds.offset += next - offset;
    offset = next;
    const frame = { translate: `0px ${next}px` };
    (hold.effect as KeyframeEffect | null)?.setKeyframes([frame, frame]);
  };
  update();
  // Resize observations are delivered after layout and before paint. The
  // viewport is watched too: the composer emptying grows it, and the scroll
  // offset clamps without the column changing size.
  const observer =
    typeof ResizeObserver === "undefined" ? undefined : new ResizeObserver(update);
  observer?.observe(column);
  const viewport = column.closest<HTMLElement>('[data-slot="scroll-area-viewport"]');
  if (viewport) observer?.observe(viewport);
  let ended = false;
  const end = () => {
    if (ended) return;
    ended = true;
    limit();
    observer?.disconnect();
    hold.cancel();
    unregister();
    holds.count -= 1;
    holds.offset -= offset;
  };
  const limit = uiClock.after(holdLimitMs, end);
  return {
    release: () => {
      // A hold that has ended no longer draws the transcript where it was.
      if (ended) return undefined;
      const top = layoutTop();
      end();
      return top === undefined ? undefined : referenceTop - top;
    },
    cancel: end,
  };
}

const blockSizeProperties = new Set([
  "height",
  "min-height",
  "max-height",
  "padding-top",
  "padding-bottom",
  "margin-top",
  "margin-bottom",
]);

/**
 * Moves the scroll offset now to where it would clamp once the composer
 * finishes the resize sending started: an emptied multi-line draft shrinks
 * it, and that grows the transcript's viewport. Clamped later, mid-flight,
 * the history would be pulled down against its glide. What the composer
 * still has to shrink is read from its running block-size transitions.
 */
export function settleScrollForComposerResize(slot: HTMLElement) {
  const viewport = slot.closest<HTMLElement>('[data-slot="scroll-area-viewport"]');
  const composer = slot
    .closest(".comma-chat-route")
    ?.querySelector<HTMLElement>(".comma-chat-composer");
  if (
    !viewport ||
    typeof composer?.getAnimations !== "function" ||
    typeof CSSTransition === "undefined"
  )
    return;
  let shrink = 0;
  for (const animation of composer.getAnimations({ subtree: true })) {
    if (!(animation instanceof CSSTransition) || animation.playState !== "running")
      continue;
    const property = animation.transitionProperty;
    const effect = animation.effect;
    if (!blockSizeProperties.has(property) || !(effect instanceof KeyframeEffect))
      continue;
    const target = effect.target;
    if (!target) continue;
    const key = property.replace(/-([a-z])/g, (_, letter: string) =>
      letter.toUpperCase()
    );
    const end = Number.parseFloat(String(effect.getKeyframes().at(-1)?.[key]));
    const now = Number.parseFloat(getComputedStyle(target).getPropertyValue(property));
    if (Number.isFinite(end) && Number.isFinite(now)) shrink += now - end;
  }
  if (shrink <= 0.5) return;
  const settledMax = Math.max(
    0,
    viewport.scrollHeight - (viewport.clientHeight + shrink)
  );
  if (viewport.scrollTop > settledMax) viewport.scrollTop = settledMax;
}

/**
 * The transcript's move for one send, played on the compositor. Anchoring the
 * sent turn scrolled the column up by `shift` in a single layout; drawing it
 * `shift` lower and easing that back to zero on the height curve gives the
 * history the same climb the growing slot used to give it. Glides of quick
 * successive sends add up. Their offset extends past the scroll content's
 * end only below the viewport, and the thread clips it there, so the scroll
 * range never changes. The returned glide waits, paused, for the flight.
 */
function glideColumn(
  column: HTMLElement,
  frames: readonly GlideFrame[],
  shift: number,
  duration: number
) {
  const glide = column.animate(
    frames.map(({ offset, height }) => ({
      offset,
      translate: `0px ${shift * (1 - glideProgress(height))}px`,
    })),
    { duration, easing: "linear", fill: "both", composite: "add" }
  );
  glide.pause();
  glide.currentTime = 0;
  const unregister = registerGlide(column, glide);
  const end = () => {
    // A finished glide draws its last frame, zero, so removing it moves nothing.
    glide.cancel();
    unregister();
  };
  void glide.finished.then(end, end);
  return glide;
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
  transcriptShift = 0,
  onComplete,
}: {
  bubble: HTMLElement;
  content: HTMLElement;
  slot: HTMLElement;
  source: OutgoingBubbleFrame;
  config?: MessageSendMotionConfig | undefined;
  playbackRate?: OutgoingBubblePlaybackRate | undefined;
  reducedMotion: boolean;
  /**
   * How far anchoring the sent turn moved its slot up the viewport, measured
   * by the caller around that anchor. The column glides it back.
   */
  transcriptShift?: number | undefined;
  onComplete: () => void;
}) {
  // A sent message keeps its end edge on the composer's. A bubble on its
  // row's start side (the first-launch greeting speaks from the assistant's
  // side) keeps its start edge on the source's instead: the same flight,
  // mirrored, its tail too.
  const startAligned = Boolean(bubble.closest('[data-outgoing-align="start"]'));
  const tailSide = bubble
    .closest("[data-bubble-tail]")
    ?.getAttribute("data-bubble-tail");
  const startTail = startAligned && tailSide === "left";
  const hasTail = tailSide === "right" || startTail;
  // A host that keeps its transcript's layout still while a message flies
  // (the first-launch onboarding marks it data-outgoing-lift) lays the slot
  // out at its full height at once and lifts what the slot pushes aside.
  const liftHost = slot.closest<HTMLElement>("[data-outgoing-lift]");
  const column = liftHost ? null : slot.closest<HTMLElement>(".comma-chat-column");
  // The row's resting place. An earlier send's glide may still draw the
  // column lower than its layout; the flight aims where that glide ends.
  const measured = bubble.getBoundingClientRect();
  const glideOffset = column ? readGlideOffset(column) : 0;
  const target = new DOMRect(
    measured.x,
    measured.y - glideOffset,
    measured.width,
    measured.height
  );

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
  const dx = startAligned ? start.left - target.left : start.right - target.right;
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
  let materialAnimation: Animation | undefined;
  let fadeAnimation: Animation | undefined;
  let contentAnimation: Animation | undefined;
  let chromeAnimation: Animation | undefined;
  let liftAnimations: Animation[] = [];
  // This send's glide, and the glides later sends carry this flight on.
  const glides: Animation[] = [];
  const carried: Animation[] = [];
  let startFrame: CancelUiTimer | undefined;
  let landFrame: CancelUiTimer | undefined;
  let followFrame: CancelUiTimer | undefined;
  let timer: CancelUiTimer | undefined;
  let popoverOpen = false;
  let settled = false;
  // The anchors of later sends move the row by these shifts at once; their
  // glides carry the flight through them, so following leaves them out.
  let carriedShift = 0;
  let followOffset = { x: 0, y: 0 };

  const flight: CarriedFlight = {
    carry: (frames, shift, glideDuration) => {
      carriedShift += shift;
      // The row moves up by `shift` on the glide's curve; so does its flight.
      const carry = bubble.animate(
        frames.map(({ offset, height }) => ({
          offset,
          translate: `0px ${-shift * glideProgress(height)}px`,
        })),
        { duration: glideDuration, easing: "linear", fill: "both", composite: "add" }
      );
      carry.pause();
      carry.currentTime = 0;
      carried.push(carry);
      return carry;
    },
  };

  const settle = (notify: boolean) => {
    if (settled) return;
    settled = true;
    if (startFrame !== undefined) startFrame();
    if (landFrame !== undefined) landFrame();
    if (followFrame !== undefined) followFrame();
    if (timer !== undefined) timer();
    if (column) flightsByColumn.get(column)?.delete(flight);
    // Where the flight is drawn, to hand over to the row without a jump.
    const flown = notify && !reducedMotion ? bubble.getBoundingClientRect() : undefined;
    animation?.cancel();
    materialAnimation?.cancel();
    fadeAnimation?.cancel();
    contentAnimation?.cancel();
    chromeAnimation?.cancel();
    for (const lift of liftAnimations) lift.cancel();
    for (const carry of carried) carry.cancel();
    // A carry that its flight cancelled as it landed stays cancelled.
    if (!notify)
      for (const glide of glides) if (glide.playState !== "idle") glide.finish();
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
    if (flown && typeof bubble.animate === "function") {
      // Anything that moved the row after launch, and that no glide carried
      // the flight through, is taken up on the bubble rather than in one frame.
      const rest = bubble.getBoundingClientRect();
      const offsetX = flown.left - rest.left;
      const offsetY = flown.top - rest.top;
      if (Math.abs(offsetX) > 0.5 || Math.abs(offsetY) > 0.5) {
        bubble.animate(
          [{ translate: `${offsetX}px ${offsetY}px` }, { translate: "0px 0px" }],
          {
            duration: motionDuration.spatialMove,
            easing: motionEasing.surfaceSmoothOut,
          }
        );
      }
      // A row whose text changed in flight rests at another height than the
      // one its slot held. The slot eases between the two, so the rows below
      // do not jump in one frame.
      const grown = rest.height - target.height;
      if (Math.abs(grown) > 0.5 && typeof slot.animate === "function") {
        const height = slot.getBoundingClientRect().height;
        slot.animate([{ height: `${height - grown}px` }, { height: `${height}px` }], {
          duration: motionDuration.spatialMove,
          easing: motionEasing.surfaceSmoothOut,
        });
      }
    }
    if (notify) onComplete();
  };

  bubble.dataset.outgoingPresentation = "flying";
  bubble.style.setProperty("--comma-chat-flight-tail-depth", hasTail ? "7px" : "0px");
  if (!reducedMotion) {
    slot.dataset.outgoingPresentationSlot = "true";
    // The slot keeps the row's resting size while its bubble flies above it:
    // the transcript is laid out where the message lands, once.
    slot.style.width = `${target.width}px`;
    slot.style.height = `${target.height}px`;
    if (liftHost && typeof liftHost.animate === "function") {
      liftAnimations = liftSlotGrowth(
        liftHost,
        slot,
        target.height,
        timeline.frames,
        duration
      );
    }
    if (column && typeof column.animate === "function") {
      if (Math.abs(transcriptShift) >= 0.5) {
        glides.push(glideColumn(column, timeline.frames, transcriptShift, duration));
        // Flights still in the air ride the same glide as their rows.
        for (const other of flightsByColumn.get(column) ?? [])
          glides.push(other.carry(timeline.frames, transcriptShift, duration));
      }
      let flights = flightsByColumn.get(column);
      if (!flights) {
        flights = new Set();
        flightsByColumn.set(column, flights);
      }
      flights.add(flight);
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
      transformOrigin: startAligned ? "left bottom" : "right bottom",
    });
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
    : shapeFrames.map(({ offset, width, position, height, surfaceScale }) => {
        const paintedWidth = start.width + (target.width - start.width) * width;
        const paintedHeight = start.height + (target.height - start.height) * height;
        const radiusProgress = Math.max(0, Math.min(1, width, height));
        const radius = Math.min(
          sourceRadius + (targetRadius - sourceRadius) * radiusProgress,
          paintedWidth / 2,
          paintedHeight / 2
        );
        // The painted shape grows from the anchored edge.
        const left = startAligned ? 0 : target.width - paintedWidth;
        const right = left + paintedWidth;
        return {
          offset,
          transform: `translate3d(${dx * (1 - position)}px, ${dy * (1 - position)}px, 0) scale(${surfaceScale})`,
          clipPath: hasTail
            ? tailedFlightClip(
                left,
                target.height - paintedHeight,
                right,
                target.height,
                Math.max(0, radius),
                startTail
              )
            : `inset(${target.height - paintedHeight}px ${target.width - right}px 0px ${left}px round ${Math.max(0, radius)}px)`,
        };
      });
  if (typeof bubble.animate !== "function") {
    timer = uiClock.after(duration / playbackRate, () => settle(true));
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
  if (!reducedMotion) {
    // The source's material becomes the bubble's on the plane behind the
    // shape, the flight's only material: the bubble's own background stays
    // clear, or a translucent material would show twice over its box.
    materialAnimation = bubble.animate(
      materialKeyframes(
        source.background ?? targetBackground,
        targetBackground,
        materialStart / duration,
        materialEnd / duration
      ),
      { ...timing, pseudoElement: "::before" }
    );
    materialAnimation.pause?.();
    materialAnimation.currentTime = 0;
    // A collapsed bubble's fade is drawn in the bubble's material. It comes in
    // as the source's material turns into it, trailing the change, so it
    // never shows as a band over the source's.
    const fade = bubble.querySelector<HTMLElement>(".comma-chat-user-bubble-fade");
    if (fade && typeof fade.animate === "function") {
      const stops: Keyframe[] = [
        { offset: 0, opacity: 0 },
        { offset: materialStart / duration, opacity: 0, easing: motionEasing.sharpIn },
        { offset: materialEnd / duration, opacity: 1 },
        { offset: 1, opacity: 1 },
      ];
      fadeAnimation = fade.animate(
        stops.filter((stop, index) => stop.offset !== stops[index + 1]?.offset),
        timing
      );
      fadeAnimation.pause?.();
      fadeAnimation.currentTime = 0;
    }
  }
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

  // Anything else that moves the row while it flies (the composer settling
  // to its empty height, the reader scrolling, the window resizing) moves its
  // flight the same way, read in the frame's shared layout phase and written
  // after it.
  const follow = () => {
    followFrame = undefined;
    if (settled || !column) return undefined;
    const row = slot.getBoundingClientRect();
    // A later send's hold draws the row where it was painted and carries no
    // flight, so the flight stays with the row through it.
    const layoutTop =
      row.top - readGlideOffset(column) + (holdsByColumn.get(column)?.offset ?? 0);
    // The slot is the landed bubble's box: a window resized under the flight
    // moves it across as well.
    const next = {
      x: row.left - target.left,
      y: layoutTop - target.top + carriedShift,
    };
    return () => {
      if (settled) return;
      if (
        Math.abs(next.x - followOffset.x) > 0.25 ||
        Math.abs(next.y - followOffset.y) > 0.25
      ) {
        followOffset = next;
        bubble.style.translate = `${next.x}px ${next.y}px`;
      }
      followFrame = scheduleLayoutRead(follow);
    };
  };
  if (!reducedMotion && column) followFrame = scheduleLayoutRead(follow);

  // A paused frame zero must be painted before the clock starts. Starting
  // against the commit's timeline timestamp can skip the input state when
  // the rest of the transcript takes time to render.
  startFrame = uiClock.frame(() => {
    startFrame = uiClock.frame(() => {
      startFrame = undefined;
      if (settled) return;
      const startTime = document.timeline?.currentTime;
      for (const active of [
        animation,
        materialAnimation,
        fadeAnimation,
        contentAnimation,
        chromeAnimation,
        ...liftAnimations,
        ...glides,
      ]) {
        // A flight that landed in the meantime cancelled the carry it got.
        if (!active || active.playState === "idle") continue;
        active.playbackRate = playbackRate;
        active.play?.();
        if (startTime != null) active.startTime = startTime;
      }
    });
  });

  void animation.finished.then(
    () => {
      landFrame = uiClock.frame(() => settle(true));
    },
    () => undefined
  );
  return { animation, cleanup: () => settle(false) };
}
