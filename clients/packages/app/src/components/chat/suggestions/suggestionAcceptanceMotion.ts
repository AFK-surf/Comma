/** Start after the draft commit, once the editor holds still. No layout observer.
 * `acceptedAt` is the acceptance time on the performance clock. */
export function animateSuggestionAcceptance(
  editor: HTMLElement,
  acceptedAt = editor.ownerDocument.defaultView?.performance.now() ?? 0
): () => void {
  const view = editor.ownerDocument.defaultView;
  let stop: (() => void) | undefined;
  let frame: number | undefined;
  let waits = 0;
  // A draft that no longer fits the compact composer switches its layout and
  // slides the editor into place with a transform. The copy is measured once,
  // so wait (a bounded number of frames) until that slide has settled.
  const start = () => {
    frame = undefined;
    if (view && isSliding(editor, view) && waits++ < SETTLE_FRAME_LIMIT) {
      frame = view.requestAnimationFrame(start);
    } else {
      stop = playSuggestionAcceptance(editor, acceptedAt);
    }
  };
  frame = view?.requestAnimationFrame(start);
  return () => {
    if (frame !== undefined) view?.cancelAnimationFrame(frame);
    stop?.();
  };
}

const SETTLE_FRAME_LIMIT = 30;

/* The wave, in em. A heavy, enlarged, blue crest travels once from left to
   right. Before and behind the crest, the text is at rest. The line reflows:
   each glyph sits right after the glyphs to its left, at their current
   widths.

   The crest moves at a constant speed, so every glyph goes through the same
   weight, size, and color profile, delayed by its distance from the start of
   the text. The profile is sampled once into keyframes that all glyphs share.
   The reflow is computed once into one shift animation per glyph. Each frame,
   the browser only interpolates keyframes: no style rules, custom
   properties, or script run per frame. */
const CREST_REACH = 4; // crest half-width: about eight glyphs move together
const PROFILE = 2 * CREST_REACH; // crest travel while one glyph moves
const GROW = 0.18; // size gain on the crest
const HEAVY = 300; // weight gain on the crest
// A new weight is a new font instance, and for a fallback font (CJK) also a
// new font lookup. Steps of 50 keep the font cache warm. They are too small
// to see.
const WEIGHT_STEP = 50;
const SAMPLES = 26; // profile keyframes, about one per 0.5em
const SHIFT_TOLERANCE = 0.05; // px a reflow keyframe may skip
// The crest's front edge reaches the first glyph 25ms after acceptance, so
// the glyph visibly moves by 50ms. The last glyph comes to rest 750ms after
// acceptance. Longer lines travel faster.
const START_DELAY = 25;
const DURATION = 725;

// The crest's blue: the agent chat's thinking shimmer.
const PEAK = "--color-utility-brand-400";

const bell = (z: number) =>
  0.5 + 0.5 * Math.cos(Math.PI * Math.max(-1, Math.min(1, z)));

/** The wave at a glyph `ahead` em to the right of the crest. */
function waveAt(ahead: number) {
  const k = bell(ahead / CREST_REACH);
  const gain = k * HEAVY;
  return {
    blue: k,
    gain,
    step: Math.round(gain / WEIGHT_STEP) * WEIGHT_STEP,
    scale: 1 + k * GROW,
  };
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

// Glyphs whose advance does not change with weight: CJK ideographs, kana,
// Hangul, CJK punctuation, full-width forms, and emoji.
const FIXED_ADVANCE =
  /^(?:[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\p{Script=Bopomofo}\u3000-\u303f\uff00-\uffef]|\p{Extended_Pictographic}|\p{Emoji_Presentation})/u;

// Letters of these scripts join or form conjuncts across graphemes. A copy of
// each grapheme would draw them apart, so their text uses the editor shimmer.
const JOINING_SCRIPT =
  /[\p{Script=Arabic}\p{Script=Syriac}\p{Script=Nko}\p{Script=Mongolian}\p{Script=Adlam}\p{Script=Mandaic}\p{Script=Hanifi_Rohingya}\p{Script=Phags_Pa}\p{Script=Kannada}\p{Script=Sinhala}\p{Script=Khmer}\p{Script=Myanmar}\p{Script=Tibetan}]/u;

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
  // The wave's start on the document timeline. Animations started at this
  // time keep the schedule even when setup ends later.
  const origin = acceptedAt + START_DELAY;
  const bounds = editor.getBoundingClientRect();
  const hostBounds = host.getBoundingClientRect();
  const style = view.getComputedStyle(editor);
  const segments = Array.from(
    new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text)
  );
  range.selectNodeContents(editor);
  const textBounds = range.getBoundingClientRect();
  // Segmentation is a visual budget, not a text limit. Expanding inputs animate
  // their actual text so their own layout can change without a detached copy.
  const segmented =
    segments.length <= 64 &&
    !text.includes("\n") &&
    !JOINING_SCRIPT.test(text) &&
    textBounds.height <= parseFloat(style.lineHeight) * 1.5;
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
    // Positions are em from the left edge of the text, so the crest travels by
    // visual distance: wide emoji and narrow letters share one wave size and
    // speed, and bidi text sweeps left to right.
    // Read the editor's computed style before the copy changes the page, so
    // the reads do not force another style pass.
    const em = parseFloat(style.fontSize) || 16;
    const ink = style.color;
    const peak = style.getPropertyValue(PEAK).trim();
    const rest = parseFloat(style.fontWeight) || 400;
    const { fontStyle, fontSize, fontFamily } = style;
    const canvasFont = (weight: number) =>
      `${fontStyle} ${weight} ${fontSize} ${fontFamily}`;
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

    // Font fallback can switch faces at a weight boundary. Measure every
    // weight used by the wave; a linear estimate only works for some fonts.
    const widths = pieces.map(({ glyph }) => glyph.getBoundingClientRect().width);
    const changes = glyphs.map(() => Array<number>(HEAVY / WEIGHT_STEP + 1).fill(0));
    const context = doc.createElement("canvas").getContext("2d");
    if (context) {
      for (let step = 0; step <= HEAVY / WEIGHT_STEP; step++) {
        context.font = canvasFont(rest + step * WEIGHT_STEP);
        glyphs.forEach((piece, index) => {
          if (!FIXED_ADVANCE.test(piece.text)) {
            changes[index]![step] = context.measureText(piece.text).width;
          }
        });
      }
      changes.forEach((values) => {
        const base = values[0]!;
        values.forEach((value, index) => {
          values[index] = value - base;
        });
      });
    }

    // Glyphs at rest keep the editor's weight, size, color, and position, so
    // the first and last frames match the editable text.
    const profile = Array.from({ length: SAMPLES }, (_, index) =>
      waveAt(CREST_REACH - (index / (SAMPLES - 1)) * PROFILE)
    );
    const offset = (index: number) => index / (SAMPLES - 1);
    const weight = profile.map(({ step }, index) => ({
      offset: offset(index),
      fontWeight: String(rest + step),
      easing: "step-end",
    }));
    const shape = profile.map(({ blue, scale }, index) => ({
      offset: offset(index),
      color:
        blue > 0 && peak
          ? `color-mix(in oklab, ${peak} ${(blue * 100).toFixed(2)}%, ${ink})`
          : ink,
      scale: String(scale),
    }));
    // The crest starts with its front edge on the first glyph, so the first
    // frame is at rest and the next one already moves.
    const first = Math.min(...pieces.map(({ at }) => at));
    const spread = Math.max(...pieces.map(({ at }) => at)) - first;
    const pace = DURATION / (spread + PROFILE); // ms per em of crest travel
    const duration = PROFILE * pace;
    const delays = pieces.map(({ at }) => (at - first) * pace);
    const total = DURATION;
    // Size interpolates between profile knots; weight holds until the next
    // knot. Reflow must use those same boundaries, including both sides of
    // each weight jump, or a fallback font can overlap its neighbor.
    const playedAt = (time: number, before: boolean) => {
      const position = Math.max(0, Math.min(1, time / duration)) * (SAMPLES - 1);
      const rounded = Math.round(position);
      const onKnot = Math.abs(position - rounded) < 1e-7;
      const index = Math.min(
        SAMPLES - 2,
        Math.max(
          0,
          onKnot ? rounded - (before && rounded > 0 ? 1 : 0) : Math.floor(position)
        )
      );
      const fraction = position - index;
      const [from, to] = [profile[index]!, profile[index + 1]!];
      return {
        scale: from.scale + (to.scale - from.scale) * fraction,
        step: (position >= SAMPLES - 1 ? to.step : from.step) / WEIGHT_STEP,
      };
    };
    const order = pieces
      .map((_, index) => index)
      .toSorted((a, b) => glyphs[a]!.left - glyphs[b]!.left);
    const knots = new Set([0, total]);
    delays.forEach((delay) => {
      profile.forEach((_, index) => knots.add(delay + offset(index) * duration));
    });
    // Duplicate offsets preserve discontinuities without per-frame JS or
    // layout. Between knots all advances are linear in the animated scale.
    const times = [...knots].toSorted((a, b) => a - b).flatMap((time) => [time, time]);
    const shifts = pieces.map(() => [] as number[]);
    times.forEach((time, sample) => {
      let push = 0;
      order.forEach((index) => {
        const { scale, step } = playedAt(time - delays[index]!, sample % 2 === 0);
        const width = widths[index]! + changes[index]![step]!;
        const own = (width * (scale - 1)) / 2;
        shifts[index]!.push(push + own);
        push += width * scale - widths[index]!;
      });
    });

    // All glyphs share the parsed weight and shape keyframes; each copy only
    // changes its target and delay.
    const weightEffect = new KeyframeEffect(null, weight, { duration, fill: "both" });
    const shapeEffect = new KeyframeEffect(null, shape, { duration, fill: "both" });
    const play = (effect: KeyframeEffect) => {
      const animation = new Animation(effect, doc.timeline);
      animation.startTime = origin;
      animations.push(animation);
      return animation;
    };
    pieces.forEach(({ glyph }, index) => {
      for (const shared of [weightEffect, shapeEffect]) {
        const effect = new KeyframeEffect(shared);
        effect.target = glyph;
        effect.updateTiming({ delay: delays[index]! });
        play(effect);
      }
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
