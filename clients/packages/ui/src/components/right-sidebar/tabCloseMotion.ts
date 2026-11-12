import {
  isReducedMotionEnabled,
  motionDuration,
  motionEasing,
  motionScale,
} from "../../tokens";

/**
 * A tab close the pointer asked for, measured before the tabs leave the DOM: a
 * copy of each closing tab where it was drawn, and where every other tab and
 * the add button sat.
 */
export type TabCloseMotion = {
  addButton: HTMLElement | null;
  closing: ReadonlySet<string>;
  content: HTMLElement;
  ghosts: HTMLElement[];
  positions: Map<HTMLElement, number>;
  /** The strip's scroll area, and its width before the close. */
  strip: HTMLElement;
  stripWidth: number;
  viewport: HTMLElement;
};

// Layout offsets ignore transforms, so a glide still under way from an earlier
// close measures where its tab sits, not where it is drawn mid-way.
const stripLeft = (element: HTMLElement, viewport: HTMLElement) =>
  element.offsetLeft - viewport.scrollLeft;

// The add button's move across the strip's held width, per strip.
const stripHolds = new WeakMap<HTMLElement, Animation>();

const translateXOf = (element: HTMLElement) =>
  new DOMMatrixReadOnly(getComputedStyle(element).transform).m41;

// The copy keeps the tab's look and leaves the strip's queries, the
// accessibility tree and hit testing.
const ghostOf = (item: HTMLElement, content: DOMRect, hovered: boolean) => {
  const drawn = item.getBoundingClientRect();
  const ghost = item.cloneNode(true) as HTMLElement;
  ghost.removeAttribute("data-tab-item");
  ghost.removeAttribute("data-menu-open");
  for (const tab of ghost.querySelectorAll('[role="tab"]')) {
    tab.removeAttribute("role");
    tab.removeAttribute("data-tab");
  }
  ghost.setAttribute("aria-hidden", "true");
  ghost.inert = true;
  ghost.dataset.tabClosing = hovered ? "hover" : "true";
  Object.assign(ghost.style, {
    height: `${drawn.height}px`,
    left: `${drawn.left - content.left}px`,
    maxWidth: "none",
    minWidth: "0",
    pointerEvents: "none",
    position: "absolute",
    top: `${item.offsetTop}px`,
    width: `${drawn.width}px`,
  });
  return ghost;
};

export function measureTabClose(
  viewport: HTMLElement,
  addButton: HTMLElement | null,
  closing: ReadonlySet<string>,
  hovered: boolean
): TabCloseMotion | null {
  const items = Array.from(viewport.querySelectorAll<HTMLElement>("[data-tab-item]"));
  const content = items[0]?.parentElement;
  if (!content || typeof content.animate !== "function") return null;
  const contentRect = content.getBoundingClientRect();
  const ghosts: HTMLElement[] = [];
  const positions = new Map<HTMLElement, number>();
  for (const item of items) {
    if (closing.has(item.dataset.tabItem ?? "")) {
      ghosts.push(ghostOf(item, contentRect, hovered));
    } else {
      positions.set(item, stripLeft(item, viewport));
    }
  }
  const strip = viewport.parentElement ?? viewport;
  return {
    addButton,
    closing,
    content,
    ghosts,
    positions,
    strip,
    stripWidth: strip.offsetWidth,
    viewport,
  };
}

/**
 * A strip that fits its tabs narrows with them, and the tabs gliding into the
 * closed tab's place would be clipped at its new edge. It keeps its width
 * until the glide ends; meanwhile the add button travels to where the
 * narrower strip puts it, and the strip lets go in the frame it arrives.
 */
function holdStrip(motion: TabCloseMotion) {
  const { addButton, content, strip, stripWidth } = motion;
  const shrink = stripWidth - content.offsetWidth;
  if (!addButton || shrink <= 0) return;
  const from = translateXOf(addButton);
  stripHolds.get(strip)?.cancel();
  strip.style.minWidth = `${stripWidth}px`;
  const travel = addButton.animate(
    [{ transform: `translateX(${from}px)` }, { transform: `translateX(${-shrink}px)` }],
    {
      duration: motionDuration.spatialMove,
      easing: motionEasing.smoothOut,
      fill: "forwards",
    }
  );
  stripHolds.set(strip, travel);
  travel.finished.then(
    () => {
      if (stripHolds.get(strip) !== travel) return;
      stripHolds.delete(strip);
      strip.style.removeProperty("min-width");
      travel.cancel();
    },
    () => undefined
  );
}

/**
 * Runs once the closed tabs have left the strip: each copy fades and shrinks
 * where its tab was, beneath the tabs that glide into its place. Only
 * transform and opacity move, so the compositor runs both; reduced motion
 * keeps the fade alone.
 */
export function playTabClose(motion: TabCloseMotion) {
  const reduced = isReducedMotionEnabled();
  for (const ghost of motion.ghosts) {
    // First in the strip, so the tabs drawn after it slide over it.
    motion.content.prepend(ghost);
    const remove = () => ghost.remove();
    ghost
      .animate(
        reduced
          ? [{ opacity: 1 }, { opacity: 0 }]
          : [
              { opacity: 1, transform: "scale(1)" },
              { opacity: 0, transform: `scale(${motionScale.tabClose})` },
            ],
        {
          duration: motionDuration.tabCloseFade,
          easing: motionEasing.smoothOut,
          fill: "forwards",
        }
      )
      .finished.then(remove, remove);
  }
  if (reduced) return;
  holdStrip(motion);
  for (const [element, before] of motion.positions) {
    if (!element.isConnected) continue;
    const shift = before - stripLeft(element, motion.viewport);
    if (Math.abs(shift) < 0.5) continue;
    element.animate(
      [{ transform: `translateX(${shift}px)` }, { transform: "translateX(0)" }],
      {
        // Added to a glide still under way from the previous close, so that
        // one finishes its own way instead of jumping.
        composite: "add",
        duration: motionDuration.spatialMove,
        // The tabs answer the click: they start at once and settle softly,
        // so the next close button is under the pointer early.
        easing: motionEasing.smoothOut,
      }
    );
  }
}
