import { uiClock, type CancelUiTimer } from "@comma/ui/clock";

/** Start after the draft commit, once the editor holds still. No layout observer.
 * `acceptedAt` is the acceptance time on the performance clock. */
export function animateSuggestionAcceptance(
  editor: HTMLElement,
  acceptedAt = uiClock.monotonic()
): () => void {
  const view = editor.ownerDocument.defaultView;
  let stop: (() => void) | undefined;
  let frame: CancelUiTimer | undefined;
  let waits = 0;
  // A draft that no longer fits the compact composer switches its layout and
  // slides the editor into place with a transform. The copy is measured once,
  // so wait (a bounded number of frames) until that slide has settled. The
  // shimmer paints on the editor itself and moves with it, so text that can
  // only shimmer starts at once.
  const text = editor.textContent ?? "";
  const copyable = !shimmerOnly(text);
  const start = () => {
    frame = undefined;
    if (copyable && view && isSliding(editor, view) && waits++ < SETTLE_FRAME_LIMIT) {
      frame = uiClock.frame(start, view);
    } else {
      stop = playSuggestionAcceptance(editor, acceptedAt);
    }
  };
  frame = uiClock.frame(start, view);
  return () => {
    frame?.();
    stop?.();
  };
}

const SETTLE_FRAME_LIMIT = 30;

/* Spring wave modeled after iOS Messages mention acceptance: each glyph scales
   from near its baseline (no vertical lift, no discrete font-weight snapping), pops quickly to ~1.22x, overshoots gently to ~0.95x,
   and settles cleanly back to 1.0x. A luminous brand-blue highlight trails the
   scale peak by ~100ms, cresting as the glyph lands back through rest size.
   Neighbors reflow continuously with the scale so inter-glyph spacing stays
   exact throughout the bounce.

   Every glyph shares one sampled profile (delayed by its visual distance in
   em), and each glyph gets one simplified horizontal reflow animation. Each
   frame, the browser only interpolates keyframes: no script runs per frame. */
const GROW = 0.22; // peak scale gain on the spring crest (1.22x)
const SPRING_CYCLES = 2.5; // half-cycles over the glyph envelope: pop -> squash -> settle
const SPRING_DAMPING = 2.3; // exponential decay tuned for ~0.95x undershoot
const GLYPH_DURATION = 540; // ms for one glyph's spring + color envelope
const STAGGER_PER_EM = 42; // ms per em of left-to-right travel on short text
const MAX_STAGGER = 260; // cap total stagger so longer lines stay crisp
const SAMPLES = 36; // ~15ms per sample (60fps density) for smooth spring keyframes
const REFLOW_STEP_MS = 10; // dense reflow sampling before RDP simplification
const SHIFT_TOLERANCE = 0.05; // px a reflow keyframe may skip
const START_DELAY = 25; // exceeds one 60Hz frame so the wave starts at t=0 on its first painted frame

// --color-bg-brand-solid is the semantic brand accent that stays legible on
// both light (#205bff) and dark (#3b7cff) surfaces; --color-brand-200 adds a
// subtle highlight glint at the crest.
const BRAND_TOKEN = "--color-bg-brand-solid";
const HIGHLIGHT_TOKEN = "--color-brand-200";

function rawSpring(u: number): number {
  if (u <= 0 || u >= 1) return 0;
  return (
    Math.sin(SPRING_CYCLES * Math.PI * u) * Math.exp(-SPRING_DAMPING * u) * (1 - u)
  );
}

const SPRING_PEAK = (() => {
  let max = 0;
  for (let i = 1; i < 400; i++) {
    const value = rawSpring(i / 400);
    if (value > max) max = value;
  }
  return max || 1;
})();

const COLOR_START = 0.04;
const COLOR_END = 0.92;
const COLOR_ALPHA = 1.55;
const COLOR_BETA = 2.95;
const COLOR_PEAK = (() => {
  const mode = COLOR_ALPHA / (COLOR_ALPHA + COLOR_BETA);
  return Math.pow(mode, COLOR_ALPHA) * Math.pow(1 - mode, COLOR_BETA);
})();

/** Phase-lagged luminous blue envelope: peaks at u≈0.34 (~105ms after scale). */
function colorEnvelope(u: number): number {
  if (u <= COLOR_START || u >= COLOR_END) return 0;
  const x = (u - COLOR_START) / (COLOR_END - COLOR_START);
  return (Math.pow(x, COLOR_ALPHA) * Math.pow(1 - x, COLOR_BETA)) / COLOR_PEAK;
}

/** One glyph's scale and blue intensity at normalized local progress `u` in [0, 1]. */
function profileAt(u: number): { scale: number; blue: number } {
  const clamped = Math.max(0, Math.min(1, u));
  return {
    scale: 1 + (GROW * rawSpring(clamped)) / SPRING_PEAK,
    blue: colorEnvelope(clamped),
  };
}

function colorAt(blue: number, ink: string, brand: string, highlight: string): string {
  if (blue <= 0.002 || !brand) return ink;
  const brandMix = Math.min(1, blue * 1.15);
  const glintRaw = Math.max(0, (blue - 0.45) / 0.55);
  const glint = glintRaw * glintRaw * 0.45;
  const crest =
    glint > 0.005 && highlight
      ? `color-mix(in oklab, ${highlight} ${(glint * 100).toFixed(1)}%, ${brand})`
      : brand;
  return `color-mix(in oklab, ${crest} ${(brandMix * 100).toFixed(1)}%, ${ink})`;
}

/** The samples to keep so that straight lines between them stay within
 * `tolerance` of every sample (Ramer-Douglas-Peucker). */
function keyframesWithin(
  values: number[],
  times: number[],
  tolerance: number
): number[] {
  const keep = new Set([0, values.length - 1]);
  const spans: [number, number][] = [[0, values.length - 1]];
  for (let span = spans.pop(); span; span = spans.pop()) {
    const [first, last] = span;
    let farthest = -1;
    let distance = tolerance;
    for (let index = first + 1; index < last; index++) {
      const line =
        values[first]! +
        ((values[last]! - values[first]!) * (times[index]! - times[first]!)) /
          (times[last]! - times[first]! || 1);
      if (Math.abs(values[index]! - line) > distance) {
        distance = Math.abs(values[index]! - line);
        farthest = index;
      }
    }
    if (farthest >= 0) {
      keep.add(farthest);
      spans.push([first, farthest], [farthest, last]);
    }
  }
  return [...keep].toSorted((a, b) => a - b);
}

// Letters of these scripts join or form conjuncts across graphemes. A copy of
// each grapheme would draw them apart, so their text uses the editor shimmer.
const JOINING_SCRIPT =
  /[\p{Script=Arabic}\p{Script=Syriac}\p{Script=Nko}\p{Script=Mongolian}\p{Script=Adlam}\p{Script=Mandaic}\p{Script=Hanifi_Rohingya}\p{Script=Phags_Pa}\p{Script=Kannada}\p{Script=Sinhala}\p{Script=Khmer}\p{Script=Myanmar}\p{Script=Tibetan}]/u;

// Segmentation is a visual budget, not a text limit: longer, multi-line and
// joining-script text animates its actual text with the editor shimmer.
const MAX_COPIED_GLYPHS = 64;

function shimmerOnly(text: string): boolean {
  if (text.includes("\n") || JOINING_SCRIPT.test(text)) return true;
  let count = 0;
  for (const _ of new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(
    text
  ))
    if (++count > MAX_COPIED_GLYPHS) return true;
  return false;
}

function isSliding(editor: HTMLElement, view: Window): boolean {
  const { transform } = view.getComputedStyle(editor);
  return (
    Boolean(transform) &&
    transform !== "none" &&
    transform !== "matrix(1, 0, 0, 1, 0, 0)"
  );
}

/** One bounded visual copy. The editable DOM and its selection stay untouched. */
function playSuggestionAcceptance(
  editor: HTMLElement,
  acceptedAt: number
): (() => void) | undefined {
  const doc = editor.ownerDocument;
  const view = doc.defaultView;
  const text = editor.textContent ?? "";
  const source = editor.firstChild;
  const host = editor.offsetParent;
  const reducedMotion = view?.matchMedia("(prefers-reduced-motion: reduce)");
  if (
    !view ||
    doc.activeElement !== editor ||
    reducedMotion?.matches ||
    !text ||
    !(host instanceof HTMLElement) ||
    source?.nodeType !== 3 ||
    source.textContent !== text
  )
    return;

  const range = doc.createRange();
  if (
    typeof range.getBoundingClientRect !== "function" ||
    typeof editor.animate !== "function"
  )
    return;
  // The wave's start on the document timeline: on the key's schedule, or now
  // when setup ended later, so a late start plays the whole wave instead of
  // jumping into its middle.
  const origin = Math.max(
    acceptedAt + START_DELAY,
    Number(doc.timeline.currentTime ?? 0)
  );
  const bounds = editor.getBoundingClientRect();
  const hostBounds = host.getBoundingClientRect();
  const style = view.getComputedStyle(editor);
  const segments = Array.from(
    new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text)
  );
  range.selectNodeContents(editor);
  const textBounds = range.getBoundingClientRect();
  // Expanding inputs animate their actual text so their own layout can change
  // without a detached copy.
  const segmented =
    !shimmerOnly(text) && textBounds.height <= parseFloat(style.lineHeight) * 1.5;
  let overlay: HTMLDivElement | undefined;
  const animations: Animation[] = [];
  let final: Animation | undefined;
  if (segmented) {
    const glyphs = segments.map(({ segment, index }) => {
      range.setStart(source, index);
      range.setEnd(source, index + segment.length);
      const rect = range.getBoundingClientRect();
      return {
        text: segment,
        left: rect.left - bounds.left,
        right: rect.right,
        width: rect.width,
        center: rect.left + rect.width / 2,
        top: rect.top - bounds.top,
        height: rect.height,
      };
    });
    // Positions are em from the left edge of the text, so the wave travels by
    // visual distance: wide emoji and narrow letters share one pace, and bidi
    // text sweeps left to right.
    const em = parseFloat(style.fontSize) || 16;
    const ink = style.color;
    const brand = style.getPropertyValue(BRAND_TOKEN).trim();
    const highlight = style.getPropertyValue(HIGHLIGHT_TOKEN).trim();
    const start = Math.min(...glyphs.map((glyph) => glyph.left + bounds.left));
    overlay = doc.createElement("div");
    overlay.className = "comma-suggestion-acceptance";
    overlay.setAttribute("aria-hidden", "true");
    Object.assign(overlay.style, {
      left: `${bounds.left - hostBounds.left - host.clientLeft + host.scrollLeft}px`,
      top: `${bounds.top - hostBounds.top - host.clientTop + host.scrollTop}px`,
      width: `${bounds.width}px`,
      height: `${bounds.height}px`,
      font: style.font,
      letterSpacing: style.letterSpacing,
      color: ink,
    });
    const pieces = glyphs.map((piece) => {
      const glyph = doc.createElement("span");
      glyph.className = "comma-suggestion-acceptance-glyph";
      glyph.textContent = piece.text;
      Object.assign(glyph.style, {
        left: `${piece.left}px`,
        top: `${piece.top}px`,
        lineHeight: `${piece.height}px`,
      });
      return { glyph, at: (piece.center - start) / em };
    });
    overlay.append(...pieces.map(({ glyph }) => glyph));
    host.append(overlay);
    editor.dataset.suggestionAccepting = "true";

    const widths = pieces.map(({ glyph }) => glyph.getBoundingClientRect().width);

    // Glyphs at rest keep the editor's exact size, weight, color, and position,
    // so the first and last frames match the editable text.
    const profile = Array.from({ length: SAMPLES }, (_, index) =>
      profileAt(index / (SAMPLES - 1))
    );
    const offset = (index: number) => index / (SAMPLES - 1);
    const shape = profile.map(({ blue, scale }, index) => ({
      offset: offset(index),
      color: colorAt(blue, ink, brand, highlight),
      scale: scale.toFixed(4),
    }));

    const first = Math.min(...pieces.map(({ at }) => at));
    const spread = Math.max(...pieces.map(({ at }) => at)) - first;
    const stagger = Math.min(spread * STAGGER_PER_EM, MAX_STAGGER);
    const pace = spread > 0 ? stagger / spread : 0;
    const duration = GLYPH_DURATION;
    const delays = pieces.map(({ at }) => (at - first) * pace);
    const total = stagger + duration;

    // Linear interpolation between profile knots matches the Web Animations
    // engine's scale interpolation so reflow keeps inter-glyph gaps constant.
    const scaleAt = (localTime: number) => {
      if (localTime <= 0 || localTime >= duration) return 1;
      const position = (localTime / duration) * (SAMPLES - 1);
      const index = Math.min(SAMPLES - 2, Math.floor(position));
      const fraction = position - index;
      const from = profile[index]!.scale;
      const to = profile[index + 1]!.scale;
      return from + (to - from) * fraction;
    };

    const order = pieces
      .map((_, index) => index)
      .toSorted((a, b) => glyphs[a]!.left - glyphs[b]!.left);
    const steps = Math.max(2, Math.ceil(total / REFLOW_STEP_MS));
    const times = Array.from(
      { length: steps + 1 },
      (_, index) => (index / steps) * total
    );
    const shifts = pieces.map(() => [] as number[]);
    times.forEach((time) => {
      let push = 0;
      order.forEach((index) => {
        const scale = scaleAt(time - delays[index]!);
        const width = widths[index]!;
        const gain = width * (scale - 1);
        shifts[index]!.push(push + gain / 2);
        push += gain;
      });
    });

    const shapeEffect = new KeyframeEffect(null, shape, { duration, fill: "both" });
    const play = (effect: KeyframeEffect) => {
      const animation = new Animation(effect, doc.timeline);
      animation.startTime = origin;
      animations.push(animation);
      return animation;
    };
    pieces.forEach(({ glyph }, index) => {
      const effect = new KeyframeEffect(shapeEffect);
      effect.target = glyph;
      effect.updateTiming({ delay: delays[index]! });
      play(effect);

      const values = shifts[index]!;
      const shift = play(
        new KeyframeEffect(
          glyph,
          keyframesWithin(values, times, SHIFT_TOLERANCE).map((step) => ({
            offset: Math.min(1, times[step]! / total),
            translate: `${values[step]!.toFixed(2)}px`,
          })),
          { duration: total, fill: "both" }
        )
      );
      // Every shift ends with the wave.
      final ??= shift;
    });
  } else {
    // The band crosses the text, not the empty width of a wide editor, on the
    // glyph wave's schedule.
    editor.style.setProperty(
      "--comma-suggestion-text-end",
      `${textBounds.right - bounds.left}px`
    );
    editor.dataset.suggestionShimmer = "true";
    for (const animation of editor.getAnimations()) animation.startTime = origin;
  }

  const cancel = () => {
    delete editor.dataset.suggestionAccepting;
    delete editor.dataset.suggestionShimmer;
    editor.style.removeProperty("--comma-suggestion-text-end");
    for (const animation of animations) animation.cancel();
    overlay?.remove();
    final?.removeEventListener("finish", cancel);
    editor.removeEventListener("animationend", onEnd);
    editor.removeEventListener("beforeinput", cancel);
    editor.removeEventListener("keydown", cancel);
    editor.removeEventListener("blur", cancel);
    doc.removeEventListener("pointerdown", cancel, true);
    doc.removeEventListener("scroll", cancel, true);
    view.removeEventListener("resize", cancel);
    reducedMotion?.removeEventListener("change", cancel);
  };
  const onEnd = (event: Event) => {
    if ((event as AnimationEvent).animationName === "comma-suggestion-shimmer")
      cancel();
  };
  if (final) final.addEventListener("finish", cancel);
  else editor.addEventListener("animationend", onEnd);
  editor.addEventListener("beforeinput", cancel);
  editor.addEventListener("keydown", cancel);
  editor.addEventListener("blur", cancel);
  doc.addEventListener("pointerdown", cancel, true);
  doc.addEventListener("scroll", cancel, true);
  view.addEventListener("resize", cancel);
  reducedMotion?.addEventListener("change", cancel);
  return cancel;
}
