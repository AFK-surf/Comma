/**
 * Shared motion tokens for direct, interruptible interface feedback.
 * Durations are expressed in milliseconds for CSS generation and JS consumers.
 */
export type MessageSendSpringConfig = {
  /** Undamped period in seconds. A larger response gives slower motion. */
  response: number;
  /** Below 1 rebounds, 1 is critical damping, above 1 settles without rebound. */
  dampingRatio: number;
  /** Normalized progress per second at release. */
  initialVelocity: number;
  delayMs: number;
  /** Soft limit on travel past the destination, in CSS pixels. */
  maxOvershootPx: number;
};

export type MessageSendMotionConfig = Record<
  "width" | "position" | "height",
  MessageSendSpringConfig
> & {
  widthCurve: {
    mode: "spring" | "bezier";
    durationMs: number;
    x1: number;
    y1: number;
    x2: number;
    y2: number;
  };
  surfacePulse: {
    response: number;
    dampingRatio: number;
    delayMs: number;
    amount: number;
  };
};

/** Independent curves share a clock, but each owns its shape and start time. */
export const motionMessageSend: MessageSendMotionConfig = {
  widthCurve: { mode: "spring", durationMs: 440, x1: 0.42, y1: 0, x2: 1, y2: 1 },
  surfacePulse: { response: 0.76, dampingRatio: 0.93, delayMs: 0, amount: 0.3 },
  width: {
    response: 0.34,
    dampingRatio: 0.86,
    initialVelocity: 3.4,
    delayMs: 0,
    maxOvershootPx: 0,
  },
  position: {
    response: 0.44,
    dampingRatio: 0.99,
    initialVelocity: 0,
    delayMs: 20,
    maxOvershootPx: 8,
  },
  height: {
    response: 0.38,
    dampingRatio: 0.96,
    initialVelocity: 0,
    delayMs: 0,
    maxOvershootPx: 4,
  },
};

export const motionDuration = {
  feedbackIn: 120,
  stateChange: 150,
  feedbackOut: 180,
  /** Icon travelling to its held press position (translate/rotate/colour). */
  pressTravel: 50,
  /** Release: back through rest, small overshoot, then settle. */
  pressRecoil: 150,
  tooltipEnter: 150,
  tooltipExit: 125,
  tooltipHandoff: 80,
  hoverCardEnter: 190,
  hoverCardExit: 140,
  iconSwap: 250,
  dialogEnter: 250,
  dialogExit: 200,
  imageFilmstrip: 400,
  revealItem: 100,
  revealStagger: 30,
  spatialMove: 200,
  replyDraw: 600,
  menuEnter: 120,
  menuExit: 80,
  /** Settling time before a pointer-driven preview handoff. */
  pointerIntent: 100,
  submenuOpenDelay: 80,
  submenuCloseDelay: 80,
  loginStageEnter: 750,
  loginStageExit: 380,
  caretBlink: 1100,
  loadingShine: 1600,
  /** Toast retimes sonner's 400ms default: strong ease-out in, faster out. */
  toastEnter: 250,
  toastExit: 200,
  /**
   * A transfer bar gliding to its next reading. Readings arrive about once a
   * second, so a linear glide just under that reads as continuous progress.
   */
  progressFill: 900,
  /**
   * A toggled corner panel (Drive transfers) shares the toast's direction but
   * is opened many times a session, so it runs shorter than a toast's arrival.
   */
  panelEnter: 150,
  panelExit: 100,
  /**
   * A state trading places with the next (a Task's Needs Review → Done): the
   * old state clears first, then the new one arrives, so the two never overlap
   * and nothing appears from nowhere. Controls that leave with the old state
   * take the exit.
   */
  stateSwapExit: 100,
  stateSwapEnter: 150,
  /**
   * A disclosure chevron turning to point where its list is headed. It leads
   * the fold it announces rather than matching it: the glyph is one small
   * rotation the eye resolves at once, so pacing it to the panel's own
   * stateChange leaves it hanging after the turn has already read.
   */
  disclosureTurn: 100,
  /**
   * A playing video's floating window. It arrives on its own, when the video
   * leaves the reader's view, so it settles in like a toast; it leaves faster,
   * because by then the video is already back in its own frame.
   */
  pictureInPictureEnter: 250,
  pictureInPictureExit: 150,
} as const;

export const motionEasing = {
  iconSwap: "ease-in-out",
  generatedMediaSwap: "cubic-bezier(0.77, 0, 0.175, 1)",
  spatialMove: "cubic-bezier(0.77, 0, 0.175, 1)",
  smoothOut: "cubic-bezier(0.16, 1, 0.3, 1)",
  surfaceSmoothOut: "cubic-bezier(0.22, 1, 0.36, 1)",
  /** iOS drawer curve: fast start, long even deceleration with no hover. */
  drawer: "cubic-bezier(0.32, 0.72, 0, 1)",
  /** Gentle symmetric in-out for travel that starts from rest mid-sequence. */
  softInOut: "cubic-bezier(0.4, 0, 0.2, 1)",
  /**
   * Press travel. Near-linear with soft ends: the glyph leaves rest at once,
   * holds an even pace, and lands without a bump. Colour rides the same curve,
   * so the darkening and the movement read as one push rather than two.
   */
  pressTravel: "cubic-bezier(0.05, 0, 0.55, 0.85)",
  /**
   * Press release. Starts from a standstill, so it must start slow — a curve
   * that dumps half its travel into the first frame reads as a flicker on
   * anything that isn't moving fast enough to blur, colour above all. Crosses
   * rest just past halfway, overshoots ~6%, settles.
   */
  pressRecoil: "cubic-bezier(0.25, 0.3, 0.25, 1.32)",
  /**
   * Accelerating exit. Every other curve here decelerates, which is right for
   * something arriving and wrong for something leaving: a dismissed surface
   * that eases out reads as hesitating. Pair with a duration shorter than the
   * matching enter.
   */
  sharpIn: "cubic-bezier(0.4, 0, 1, 1)",
} as const;

export const motionScale = {
  pressed: 0.98,
  tactilePressed: 0.96,
  actionPressed: 0.94,
  tooltipEnter: 0.97,
  menuEnter: 0.98,
  menuExit: 0.99,
  commandPaletteExit: 0.96,
  revealItem: 0.97,
  loginStage: 0.9,
  /** Active verification cell; Figma 52px over the 47px rest size. */
  loginCodeActive: 1.106,
  /** Press / digit-enter feedback. Subtle enough for a 6-cell OTP row. */
  loginCodePress: 0.97,
  /** The floating video window grows from, and shrinks back to, its docked corner. */
  pictureInPicture: 0.96,
} as const;

/** Pixel distances travelled by moving surfaces during stage transitions. */
export const motionDistance = {
  menuEnter: 2,
  loginStageShift: 8,
  revealItem: 8,
  /** Directional nudge a pressed navigation arrow travels along its own axis. */
  navPressShift: 2,
} as const;

/** Rotations applied to icons whose glyph itself describes the action. */
export const motionRotate = {
  /** Sweep a pressed reload arrow turns, in its own arrow direction. */
  refreshPress: 75,
} as const;

/** Gaussian blur radii applied to surfaces entering or leaving a stage. */
export const motionBlur = {
  menuEnter: 2,
  loginStage: 8,
} as const;

/**
 * Login verification-code error reminder. Unit mass spring; `amplitude` is the
 * initial offset in px, `stagger` is the per-cell start delay in ms.
 */
export const motionLoginCodeError = {
  stiffness: 910,
  damping: 18,
  amplitude: 12,
  stagger: 8,
} as const;

/**
 * Comma mascot soft-body return spring. The mesh adds positional constraints,
 * while this unit-mass spring supplies the organic release and overshoot.
 */
export const motionMascotElastic = {
  mass: 1,
  stiffness: 130,
  damping: 8,
} as const;

/**
 * Shell rail fold: the Home rails and the app sidebar. Unit-mass spring on the
 * fold progress, 0 open to 1 shut. Just under critical damping, it covers 95%
 * of the way in about 250ms and settles without a visible overshoot.
 */
export const motionRailFold = {
  stiffness: 275,
  damping: 30,
} as const;

/**
 * Notch width preview in Settings: the shell settling after an arrow key, a
 * reset, or a release past its limits. Unit-mass spring at damping ratio 0.9,
 * about 200ms to land, so a held key reads as one continuous glide and a
 * rubber-banded edge returns without a visible bounce.
 */
export const motionNotchResize = {
  stiffness: 520,
  damping: 41,
} as const;

export const commaReducedMotionAttribute = "data-comma-reduced-motion";

const reducedMotionQuery = "(prefers-reduced-motion: reduce)";

/** Returns whether motion should be reduced by system preference or Comma setting. */
export function isReducedMotionEnabled(): boolean {
  const manuallyReduced =
    typeof document !== "undefined" &&
    document.documentElement.getAttribute(commaReducedMotionAttribute) === "true";
  const systemReduced =
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia(reducedMotionQuery).matches;

  return manuallyReduced || systemReduced;
}

/** Subscribes to both the system media query and Comma's root appearance setting. */
export function subscribeToReducedMotion(onChange: () => void): () => void {
  const mediaQuery =
    typeof window !== "undefined" && typeof window.matchMedia === "function"
      ? window.matchMedia(reducedMotionQuery)
      : null;
  mediaQuery?.addEventListener("change", onChange);

  const observer =
    typeof document !== "undefined" && typeof MutationObserver !== "undefined"
      ? new MutationObserver(onChange)
      : null;
  observer?.observe(document.documentElement, {
    attributeFilter: [commaReducedMotionAttribute],
    attributes: true,
  });

  return () => {
    mediaQuery?.removeEventListener("change", onChange);
    observer?.disconnect();
  };
}

export type MotionDurationKey = keyof typeof motionDuration;
export type MotionEasingKey = keyof typeof motionEasing;
export type MotionScaleKey = keyof typeof motionScale;
export type MotionDistanceKey = keyof typeof motionDistance;
export type MotionBlurKey = keyof typeof motionBlur;
export type MotionLoginCodeErrorKey = keyof typeof motionLoginCodeError;
export type MotionMascotElasticKey = keyof typeof motionMascotElastic;
