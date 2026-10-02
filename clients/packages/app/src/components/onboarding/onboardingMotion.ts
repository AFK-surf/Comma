import {
  motionDistance,
  motionDuration,
  motionEasing,
  motionMessageSend,
  motionScale,
  type MessageSendMotionConfig,
} from "@comma/ui";

/**
 * The chat's send motion, a step quicker. The onboarding's composer sits at
 * the screen's foot, so each message travels most of the screen rather than
 * the chat's short hop; at the chat's pace the long settle reads as slow.
 * Same springs and damping, shorter responses.
 */
export const onboardingMessageSend: MessageSendMotionConfig = {
  ...motionMessageSend,
  widthCurve: { ...motionMessageSend.widthCurve, durationMs: 300 },
  width: { ...motionMessageSend.width, response: 0.22 },
  position: { ...motionMessageSend.position, response: 0.28 },
  height: { ...motionMessageSend.height, response: 0.24 },
};

/**
 * The onboarding's own motion, on the compositor only (transform and opacity,
 * through the Web Animations API, so every move can be retargeted): the
 * intro's mark, the thread, its cards, the light that clears it, and the
 * welcome page. The bubbles themselves fly with the chat's send motion.
 *
 * The thread stands on its composer: a change at its bottom (a card arriving
 * or leaving, a label and a gap coming with a new bubble) lays everything
 * above it out somewhere else at once. `threadTop` reads where the thread is
 * drawn before the change, a running move included; `playThreadMove` then
 * plays it back from there to its new place, as a chat makes room.
 */

const moveId = "onboarding-move";
const revealId = "onboarding-reveal";

function play(
  element: Element,
  keyframes: Keyframe[],
  timing: KeyframeAnimationOptions,
  id: string
) {
  if (typeof element.animate !== "function") return undefined;
  const animation = element.animate(keyframes, { fill: "backwards", ...timing });
  animation.id = id;
  return animation;
}

function stop(element: Element, id: string) {
  if (typeof element.getAnimations !== "function") return;
  for (const animation of element.getAnimations()) {
    if (animation.id === id) animation.cancel();
  }
}

/** Where `content` is drawn now, a running move included; that move stops there. */
export function threadTop(content: HTMLElement) {
  const top = content.getBoundingClientRect().top;
  stop(content, moveId);
  return top;
}

/**
 * Plays the thread back from `from`, where it was drawn before the change,
 * to where it now lays out. With a send, the move waits on its first frame
 * as the send motion does, and both start on the same frame.
 */
export function playThreadMove(
  content: HTMLElement,
  from: number,
  { reducedMotion, withSend }: { reducedMotion: boolean; withSend: boolean }
) {
  if (reducedMotion) return;
  const offset = from - content.getBoundingClientRect().top;
  if (Math.abs(offset) < 0.5) return;
  const animation = play(
    content,
    [{ transform: `translateY(${offset}px)` }, { transform: "none" }],
    { duration: motionDuration.onboardingSettle, easing: motionEasing.drawer },
    moveId
  );
  if (!animation || !withSend) return;
  // The send motion paints its frame zero before its clock starts, two
  // frames on (outgoingBubbleMotion.ts); the move keeps that clock.
  animation.pause();
  animation.currentTime = 0;
  requestAnimationFrame(() =>
    requestAnimationFrame(() => {
      if (animation.playState !== "paused") return;
      const startTime = document.timeline?.currentTime;
      animation.play();
      if (startTime != null) animation.startTime = startTime;
    })
  );
}

/** A card pops in under its question, as the thread makes room for it. */
export function playCardEnter(card: HTMLElement, reducedMotion: boolean) {
  play(
    card,
    [{ opacity: 0 }, { opacity: 1 }],
    { duration: motionDuration.stateChange, easing: motionEasing.smoothOut },
    revealId
  );
  if (reducedMotion) return;
  play(
    card,
    [
      {
        transform: `translateY(${motionDistance.revealItem}px) scale(${motionScale.onboardingCard})`,
      },
      { transform: "none" },
    ],
    { duration: motionDuration.dialogEnter, easing: motionEasing.surfaceSmoothOut },
    revealId
  );
}

/** A finished card leaves, faster and quieter than it came. */
export function playCardLeave(card: HTMLElement, reducedMotion: boolean) {
  stop(card, revealId);
  const timing = {
    duration: motionDuration.stateChange,
    easing: motionEasing.smoothOut,
    fill: "forwards" as const,
  };
  play(card, [{ opacity: 1 }, { opacity: 0 }], timing, revealId);
  if (reducedMotion) return;
  play(
    card,
    [{ transform: "none" }, { transform: `scale(${motionScale.onboardingCard})` }],
    timing,
    revealId
  );
}

/**
 * A page's parts arrive one after another, top first, `delay` after the
 * call; each is held unseen until its turn. By default they arrive as a
 * dialog's content does; `calm` gives each a slower, softer arrival.
 */
export function playPartsEnter(
  parts: readonly HTMLElement[],
  reducedMotion: boolean,
  {
    calm = false,
    delay = 0,
    duration = motionDuration.dialogEnter,
    stagger = 2 * motionDuration.revealStagger,
  }: { calm?: boolean; delay?: number; duration?: number; stagger?: number } = {}
) {
  parts.forEach((part, index) => {
    const timing = { delay: delay + index * stagger, duration };
    play(
      part,
      [{ opacity: 0 }, { opacity: 1 }],
      { ...timing, easing: calm ? motionEasing.calmOut : motionEasing.smoothOut },
      revealId
    );
    if (!reducedMotion) {
      play(
        part,
        [
          { transform: `translateY(${motionDistance.revealItem}px)` },
          { transform: "none" },
        ],
        {
          ...timing,
          easing: calm ? motionEasing.calmOut : motionEasing.surfaceSmoothOut,
        },
        revealId
      );
    }
  });
}

/** How long the conversation takes to step back for the Open Comma shortcut. */
export const threadRecedeMs = motionDuration.onboardingSettle;

/**
 * The conversation steps back for the Open Comma shortcut: it settles a
 * little smaller and higher as it fades, out of the way of what comes next.
 * Reduced motion fades it where it stands.
 */
export function playThreadRecede(column: HTMLElement, reducedMotion: boolean) {
  const timing = {
    duration: threadRecedeMs,
    easing: motionEasing.calmOut,
    fill: "forwards" as const,
  };
  play(column, [{ opacity: 1 }, { opacity: 0 }], timing, revealId);
  if (reducedMotion) return;
  play(
    column,
    [
      { transform: "none" },
      {
        transform: `translateY(${-motionDistance.revealItem}px) scale(${motionScale.onboardingCard})`,
      },
    ],
    timing,
    revealId
  );
}

const shakeId = "onboarding-shake";

/**
 * A wrong key: the keys shake their head, a short damped sway that settles
 * where it started. A wrong key while they still sway lets the sway finish
 * rather than jump back to rest; reduced motion has none (the note says it).
 */
export function playKeysShake(keys: HTMLElement, reducedMotion: boolean) {
  if (reducedMotion) return;
  if (
    typeof keys.getAnimations === "function" &&
    keys
      .getAnimations()
      .some(({ id, playState }) => id === shakeId && playState === "running")
  ) {
    return;
  }
  const sway = (motionDistance.revealItem * 3) / 4;
  play(
    keys,
    [0, -1, 0.7, -0.4, 0.15, 0].map((share) => ({
      transform: `translateX(${share * sway}px)`,
    })),
    {
      duration: 2 * motionDuration.dialogEnter,
      easing: motionEasing.smoothOut,
    },
    shakeId
  );
}

/**
 * The intro's timeline. The screen dims first; then, counted from the moment
 * the mark starts to arrive, the welcome follows as the mark settles, Start a
 * step after the welcome, and the mark starts thinking once it has arrived.
 * Start waits from its arrival before the onboarding begins by itself.
 */
export const introTiming = {
  dim: motionDuration.onboardingDim,
  welcome: Math.round((motionDuration.onboardingLogoEnter * 2) / 3),
  start:
    Math.round((motionDuration.onboardingLogoEnter * 2) / 3) +
    motionDuration.onboardingIntroStagger,
  thinking: motionDuration.onboardingLogoEnter,
  autoStart:
    Math.round((motionDuration.onboardingLogoEnter * 2) / 3) +
    motionDuration.onboardingIntroStagger +
    motionDuration.onboardingAutoStart,
} as const;

/** The welcome and Start arriving under the mark, slowly, one after the other. */
export function playIntroPartsEnter(
  parts: readonly HTMLElement[],
  reducedMotion: boolean
) {
  playPartsEnter(parts, reducedMotion, {
    calm: true,
    delay: introTiming.welcome,
    duration: motionDuration.onboardingIntroPartEnter,
    stagger: introTiming.start - introTiming.welcome,
  });
}

/**
 * The Comma mark arriving in the middle of the dimmed screen: an unhurried
 * rise into place as it fades in; reduced motion fades it in where it stands.
 */
export function playLogoEnter(logo: HTMLElement, reducedMotion: boolean) {
  const timing = {
    duration: motionDuration.onboardingLogoEnter,
    easing: motionEasing.calmOut,
  };
  play(logo, [{ opacity: 0 }, { opacity: 1 }], timing, revealId);
  if (reducedMotion) return;
  play(
    logo,
    [
      {
        transform: `translateY(${motionDistance.revealItem}px) scale(${motionScale.onboardingLogo})`,
      },
      { transform: "none" },
    ],
    timing,
    revealId
  );
}

/** How long the welcome and Start take to leave once Start is pressed. */
export const introLeaveMs = motionDuration.stateChange;

/** The welcome and Start leave at once, faster and quieter than they came. */
export function playIntroLeave(parts: readonly HTMLElement[], reducedMotion: boolean) {
  for (const part of parts) {
    stop(part, revealId);
    const timing = {
      duration: introLeaveMs,
      easing: motionEasing.smoothOut,
      fill: "forwards" as const,
    };
    play(part, [{ opacity: 1 }, { opacity: 0 }], timing, revealId);
    if (!reducedMotion) {
      play(
        part,
        [
          { transform: "none" },
          { transform: `translateY(${-motionDistance.revealItem / 2}px)` },
        ],
        timing,
        revealId
      );
    }
  }
}

/** Skip setup during the intro: what is on show leaves at once. */
export function playIntroSkip(intro: HTMLElement) {
  play(
    intro,
    [{ opacity: 1 }, { opacity: 0 }],
    { duration: introLeaveMs, easing: motionEasing.smoothOut, fill: "forwards" },
    revealId
  );
}

/**
 * Stops the thinking of `mark` (the logo's own SVG) on its resting frame and
 * says how long that takes: at once between two turns, or once the turn under
 * way has finished, hurried to end within `withinMs`. Every turn ends on the
 * frame it started from, so the mark rests whole.
 */
export function stopLogoThinking(mark: Element, withinMs: number) {
  if (typeof mark.getAnimations !== "function") return 0;
  // A mark that never started thinking is already at rest.
  const animations = mark
    .getAnimations({ subtree: true })
    .filter((animation) => animation.playState === "running");
  let remaining = 0;
  for (const animation of animations) {
    const effect = animation.effect;
    const timing = effect?.getComputedTiming();
    const cycle = Number(timing?.duration);
    const progress = timing?.progress;
    // A turn's motion ends at its second-last keyframe; the rest is the hold.
    const keyframes =
      effect && "getKeyframes" in effect
        ? (effect as KeyframeEffect).getKeyframes()
        : [];
    const held = Number(keyframes.at(-2)?.computedOffset ?? 0);
    if (Number.isFinite(cycle) && progress != null && progress < held) {
      remaining = Math.max(remaining, (held - progress) * cycle);
    }
  }
  const rate = Math.max(1, remaining / withinMs);
  const settleMs = remaining / rate;
  for (const animation of animations) {
    if (settleMs === 0) {
      animation.pause();
      continue;
    }
    const restAt = Number(animation.currentTime) + remaining;
    animation.updatePlaybackRate(rate);
    window.setTimeout(() => {
      animation.pause();
      animation.currentTime = restAt;
    }, settleMs);
  }
  return settleMs;
}

const travelId = "onboarding-travel";

/**
 * The mark moving from where it was drawn (`from`) to where it now lays out,
 * at the head of the conversation: up and smaller in one even move. Reduced
 * motion fades it in at its new place instead. Returns how long it takes.
 */
export function playLogoTravel(
  logo: HTMLElement,
  from: DOMRect,
  reducedMotion: boolean
) {
  stop(logo, revealId);
  stop(logo, travelId);
  if (reducedMotion) {
    play(
      logo,
      [{ opacity: 0 }, { opacity: 1 }],
      { duration: motionDuration.dialogEnter, easing: motionEasing.smoothOut },
      travelId
    );
    return motionDuration.dialogEnter;
  }
  const to = logo.getBoundingClientRect();
  const dx = from.left + from.width / 2 - (to.left + to.width / 2);
  const dy = from.top + from.height / 2 - (to.top + to.height / 2);
  const scale = Number.parseFloat(getComputedStyle(logo).scale) || 1;
  play(
    logo,
    [
      { translate: `${dx}px ${dy}px`, scale: String((from.width / to.width) * scale) },
      { translate: "0px 0px", scale: String(scale) },
    ],
    { duration: motionDuration.onboardingLogoTravel, easing: motionEasing.softInOut },
    travelId
  );
  return motionDuration.onboardingLogoTravel;
}

/** The mark leaving the middle for reduced motion: it fades where it stands. */
export function playLogoFade(logo: HTMLElement) {
  stop(logo, revealId);
  play(
    logo,
    [{ opacity: 1 }, { opacity: 0 }],
    { duration: introLeaveMs, easing: motionEasing.smoothOut, fill: "forwards" },
    travelId
  );
}

/**
 * The light that sweeps up into the welcome page, as parts of the screen's
 * height: the band's reach, and where its core runs in it, below its leading
 * glow and above its tail.
 */
export const sweepBand = { reach: 0.36, core: 0.11 } as const;

const sweepEasing = motionEasing.lightSweep;

/** One coordinate of a cubic bezier from (0, 0) to (1, 1) through `a` and `b`. */
const bezier = (a: number, b: number, t: number) =>
  3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t;

/** The share of a cubic-bezier easing's time it takes to cover `progress`. */
function easedTime(easing: string, progress: number) {
  const [x1 = 0, y1 = 0, x2 = 1, y2 = 1] = (easing.match(/-?[\d.]+/g) ?? []).map(
    Number
  );
  let low = 0;
  let high = 1;
  for (let step = 0; step < 32; step += 1) {
    const mid = (low + high) / 2;
    if (bezier(y1, y2, mid) < progress) low = mid;
    else high = mid;
  }
  return bezier(x1, x2, (low + high) / 2);
}

/**
 * How long the light takes to clear the screen: its core starts a reach
 * below the bottom edge and leaves past the top one.
 */
export const sweepClearMs = Math.round(
  motionDuration.onboardingSweep *
    easedTime(sweepEasing, (1 + sweepBand.core) / (1 + sweepBand.reach))
);

/** Reduced motion clears the screen under a quick white flash instead. */
export const flashMs = motionDuration.dialogEnter + motionDuration.dialogExit;
export const flashClearMs = motionDuration.stateChange;

/** A straight rise, from `from` to `to` pixels down the screen. */
const rise = (from: number, to: number) => [
  { transform: `translateY(${from}px)` },
  { transform: `translateY(${to}px)` },
];

/**
 * The light sweeping up the screen: one pre-rendered band rises from below
 * the bottom edge to past the top, and the conversation is cleared right
 * behind its core. What is cleared is cut by `stage`, whose bottom edge
 * rises with the core while `content` is held where it stands: three
 * transforms on one clock, so the cut never leaves the core. Skip setup,
 * outside the stage, fades out over the moment the core crosses it.
 */
export function playSweep({
  band,
  content,
  screen,
  skip,
  stage,
}: {
  band: HTMLElement;
  stage: HTMLElement;
  content: HTMLElement;
  /** The screen: the onboarding's own box. */
  screen: { height: number; top: number };
  skip: HTMLElement | null;
}) {
  const { height } = screen;
  const reach = sweepBand.reach * height;
  const core = sweepBand.core * height;
  const timing = {
    duration: motionDuration.onboardingSweep,
    easing: sweepEasing,
    fill: "forwards" as const,
  };
  play(band, rise(height, -reach), timing, revealId);
  play(stage, rise(core, core - reach - height), timing, revealId);
  play(content, rise(-core, height + reach - core), timing, revealId);
  if (!skip) return;
  // When the core crosses `y`, down from the screen's top.
  const crossing = (y: number) =>
    motionDuration.onboardingSweep *
    easedTime(sweepEasing, (height + core - y) / (height + reach));
  const box = skip.getBoundingClientRect();
  const from = crossing(box.bottom - screen.top);
  play(
    skip,
    [{ opacity: 1 }, { opacity: 0 }],
    {
      delay: from,
      duration: Math.max(1, crossing(box.top - screen.top) - from),
      easing: "linear",
      fill: "both",
    },
    revealId
  );
}

/**
 * Reduced motion: a quick white flash, the conversation and Skip setup
 * fading under it.
 */
export function playFlash({
  flash,
  skip,
  stage,
}: {
  flash: HTMLElement;
  skip: HTMLElement | null;
  stage: HTMLElement;
}) {
  play(
    flash,
    [{ opacity: 0 }, { opacity: 1, offset: 0.35 }, { opacity: 0 }],
    { duration: flashMs, easing: motionEasing.smoothOut, fill: "both" },
    revealId
  );
  for (const cleared of skip ? [stage, skip] : [stage]) {
    play(
      cleared,
      [{ opacity: 1 }, { opacity: 0 }],
      { duration: flashClearMs, easing: motionEasing.smoothOut, fill: "forwards" },
      revealId
    );
  }
}
