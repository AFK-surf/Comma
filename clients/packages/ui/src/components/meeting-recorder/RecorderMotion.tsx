import { Component, createRef, type ReactNode } from "react";
import { isReducedMotionEnabled, motionDuration, motionEasing } from "../../tokens";

type Pose = {
  bounds: DOMRect;
  opacity: number;
  fontSize: number;
  font: string;
  color: string;
  display: string;
  visual?: HTMLElement;
};
type Props = {
  phase: string;
  layoutKey: string;
  compact?: boolean;
  children: ReactNode;
};
type Snapshot = Map<string, Pose>;

/** Bounded FLIP snapshots: only this recorder's marked slots, never a frame loop. */
export class RecorderMotion extends Component<Props> {
  private root = createRef<HTMLDivElement>();
  private exits = createRef<HTMLDivElement>();
  private animations: Animation[] = [];
  private departing = new Map<string, HTMLElement>();

  private pose(element: HTMLElement, copy = false): Pose {
    const style = getComputedStyle(element);
    const matrix = new DOMMatrixReadOnly(
      style.transform === "none" ? undefined : style.transform
    );
    return {
      bounds: element.getBoundingClientRect(),
      opacity: Number(style.opacity),
      fontSize: Number.parseFloat(style.fontSize) * Math.hypot(matrix.a, matrix.b),
      font: style.font,
      color: style.color,
      display: style.display,
      ...(copy ? { visual: element.cloneNode(true) as HTMLElement } : {}),
    };
  }

  getSnapshotBeforeUpdate(previous: Readonly<Props>): Snapshot | null {
    // Hover geometry and presence stay in the live layout. CSS can reverse
    // these transitions without rescaling the border or cloning controls.
    if (previous.compact !== this.props.compact && previous.phase === this.props.phase)
      return null;
    // A client-side pause/resume can also expand/collapse the desktop card.
    // Let it follow hover's live CSS geometry instead of adding a second FLIP.
    if (this.livePhaseChanged(previous)) return null;
    if (previous.layoutKey === this.props.layoutKey || this.instant()) return null;
    const snapshot: Snapshot = new Map();
    const card = this.root.current?.querySelector<HTMLElement>(
      '[data-slot="meeting-recorder"]'
    );
    if (card?.getClientRects().length) snapshot.set("card", this.pose(card));
    this.root.current
      ?.querySelectorAll<HTMLElement>("[data-recorder-motion]")
      .forEach((element) => {
        if (!element.getClientRects().length) return;
        snapshot.set(
          element.dataset.recorderMotion!,
          this.pose(element, this.ownsPresence(element))
        );
      });
    // A rapid reversal resumes the retiring control's actual opacity and position.
    this.departing.forEach((element, key) => {
      if (!snapshot.has(key)) snapshot.set(key, this.pose(element, true));
    });
    return snapshot;
  }

  private instant() {
    return (
      isReducedMotionEnabled() || this.root.current?.dataset.motionInput === "keyboard"
    );
  }

  private livePhaseChanged(previous: Readonly<Props>) {
    return (
      previous.phase !== this.props.phase &&
      (previous.phase === "recording" || previous.phase === "paused") &&
      (this.props.phase === "recording" || this.props.phase === "paused")
    );
  }

  private ownsPresence(element: HTMLElement) {
    return (
      element.hasAttribute("data-recorder-presence") &&
      !element.parentElement?.closest("[data-recorder-presence]")
    );
  }

  private clear() {
    this.animations.forEach((animation) => animation.cancel());
    this.animations = [];
    this.departing.forEach((element) => element.remove());
    this.departing.clear();
  }

  private animate(
    element: HTMLElement,
    frames: Keyframe[],
    duration: number,
    easing: string,
    delay = 0
  ) {
    const animation = element.animate(frames, {
      duration,
      easing,
      delay,
      fill: "both",
    });
    this.animations.push(animation);
    // Release the filled transform so subsequent geometry is the real settled layout.
    animation.onfinish = () => animation.cancel();
    return animation;
  }

  componentDidUpdate(
    previous: Readonly<Props>,
    _state: unknown,
    snapshot: Snapshot | null
  ) {
    if (this.instant() || this.livePhaseChanged(previous)) {
      this.clear();
      return;
    }
    if (
      !snapshot ||
      !this.root.current ||
      typeof this.root.current.animate !== "function"
    )
      return;
    this.clear();
    const phaseChanged = previous.phase !== this.props.phase;
    const card = this.root.current.querySelector<HTMLElement>(
      '[data-slot="meeting-recorder"]'
    );
    const resizeDuration = Number.parseFloat(
      getComputedStyle(this.root.current).getPropertyValue("--resize-dur")
    );
    const previousCard = snapshot.get("card");
    if (phaseChanged && card && previousCard) {
      // Resolve the new phase's intrinsic layout once. A phase can also leave
      // compact mode; finish its old geometry lanes but retain color feedback.
      card.getAnimations({ subtree: true }).forEach((animation) => {
        if (
          animation instanceof CSSTransition &&
          /^(height|width|padding|gap|font-size|line-height|min-width|margin|grid-template)/.test(
            animation.transitionProperty
          )
        )
          animation.finish();
      });
      const height = card.getBoundingClientRect().height;
      if (previousCard.bounds.height !== height) {
        this.animate(
          card,
          [{ height: `${previousCard.bounds.height}px` }, { height: `${height}px` }],
          resizeDuration,
          motionEasing.surfaceSmoothOut
        );
      }
    }
    const rootBounds = this.root.current.getBoundingClientRect();
    const visible = new Set<string>();
    const replaced = new Set<string>();
    // Batch all geometry reads before the first animation or exiting visual is written.
    const targets = Array.from(
      this.root.current.querySelectorAll<HTMLElement>("[data-recorder-motion]")
    )
      .filter((element) => element.getClientRects().length)
      .map((element) => ({
        element,
        key: element.dataset.recorderMotion!,
        after: this.pose(element),
      }));
    for (const { element, key, after } of targets) {
      visible.add(key);
      // The surface follows the real card height; never stretch its border/shadow.
      if (key === "surface") continue;
      const before = snapshot.get(key);
      const textChanged =
        key === "title" &&
        before?.visual &&
        before.visual.textContent !== element.textContent;
      if (textChanged) {
        replaced.add(key);
        this.animate(
          element,
          [{ opacity: 0 }, { opacity: after.opacity }],
          motionDuration.stateChange,
          motionEasing.iconSwap
        );
      }
      if (!before) {
        if (this.ownsPresence(element)) {
          this.animate(
            element,
            [{ opacity: 0 }, { opacity: after.opacity }],
            motionDuration.stateChange,
            motionEasing.smoothOut,
            motionDuration.revealStagger
          );
        }
        continue;
      }
      // Its children own geometry; the split stop button fades as one surface.
      if (key === "stop") continue;
      const surface = key === "stop-surface";
      const scale = surface
        ? ` scale(${before.bounds.width / after.bounds.width}, ${before.bounds.height / after.bounds.height})`
        : key === "logo"
          ? ` scale(${before.bounds.width / after.bounds.width})`
          : key === "title" || key === "timer"
            ? ` scale(${before.fontSize / after.fontSize})`
            : "";
      const dx =
        key === "timer"
          ? before.bounds.right - after.bounds.right
          : before.bounds.left - after.bounds.left;
      const dy = before.bounds.top - after.bounds.top;
      if (dx || dy || scale) {
        this.animate(
          element,
          [
            { transform: `translate(${dx}px, ${dy}px)${scale}` },
            { transform: "translate(0, 0) scale(1)" },
          ],
          resizeDuration,
          motionEasing.surfaceSmoothOut
        );
      }
      if (!textChanged && before.opacity !== after.opacity) {
        this.animate(
          element,
          [{ opacity: before.opacity }, { opacity: after.opacity }],
          motionDuration.stateChange,
          motionEasing.smoothOut
        );
      }
    }
    snapshot.forEach((before, key) => {
      if (
        (visible.has(key) && !replaced.has(key)) ||
        !before.visual ||
        before.opacity === 0
      )
        return;
      const visual = before.visual;
      // An inert paint-only copy lets the real control leave layout and focus immediately.
      // Central glyphs use raw paths, so removing DOM ids cannot break SVG mask references.
      for (const node of [visual, ...visual.querySelectorAll<HTMLElement>("*")]) {
        node.removeAttribute("id");
        node.removeAttribute("data-recorder-motion");
        node.removeAttribute("data-testid");
        node.removeAttribute("data-recorder-presence");
      }
      visual.inert = true;
      visual.setAttribute("aria-hidden", "true");
      visual.dataset.recorderExit = key;
      Object.assign(visual.style, {
        position: "absolute",
        left: `${before.bounds.left - rootBounds.left}px`,
        top: `${before.bounds.top - rootBounds.top}px`,
        width: `${before.bounds.width}px`,
        height: `${before.bounds.height}px`,
        margin: "0",
        display: before.display,
        font: before.font,
        color: before.color,
        pointerEvents: "none",
        transform: "none",
        transition: "none",
      });
      this.exits.current?.append(visual);
      this.departing.set(key, visual);
      const animation = this.animate(
        visual,
        [{ opacity: before.opacity }, { opacity: 0 }],
        motionDuration.stateSwapExit,
        motionEasing.smoothOut
      );
      animation.onfinish = () => {
        animation.cancel();
        visual.remove();
        if (this.departing.get(key) === visual) this.departing.delete(key);
      };
    });
  }

  componentWillUnmount() {
    this.clear();
  }

  render() {
    return (
      <div
        ref={this.root}
        className="comma-recorder-motion t-resize"
        data-compact={this.props.compact || undefined}
        onKeyDownCapture={() => {
          if (this.root.current) this.root.current.dataset.motionInput = "keyboard";
        }}
        onPointerEnter={() => {
          if (this.root.current) this.root.current.dataset.motionInput = "pointer";
        }}
        onPointerDownCapture={() => {
          if (this.root.current) this.root.current.dataset.motionInput = "pointer";
        }}
      >
        {this.props.children}
        <div ref={this.exits} className="comma-recorder-exits" aria-hidden inert />
      </div>
    );
  }
}
