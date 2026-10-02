import { memo, useEffect, useState, type CSSProperties } from "react";
import type { OnboardingPresentation } from "./onboardingSetup";

export type OnboardingLightIntensity = "intro" | "thread" | "finale" | "exit";

type Dock = { side: "bottom" | "left" | "right"; size: number };

/**
 * The blue light behind the onboarding: a veil that turns what lies behind it
 * deep blue, and light welling up from the bottom edge, brightest mid-way,
 * with two softer blooms drifting at the corners on slow, stepped,
 * low-amplitude transform-only loops. The finale deepens the top and lets the
 * light rise further.
 *
 * The light answers the setup's progress: each finished item takes it one
 * step deeper (`depth`), a deeper blue rendered once fading in over the veil
 * while the light at the bottom dims a little. Every change is an opacity or
 * transform transition on a few large layers.
 *
 * Over the product (`overlay`) the veil blurs the app and tints it through a
 * blend, so the blue reads the same over a light or a dark shell; once the
 * greeting has done that, an opaque copy of the veil covers both, so the app
 * behind stops costing a redraw of the blur. Over the desktop (`window`)
 * nothing can blur what lies behind the window: the veil dims it evenly in
 * a deep blue, so the wallpaper stays faintly visible while the bubbles and
 * cards read cleanly over any desktop; the band where the Dock sits is
 * covered by light that never moves.
 */
export const OnboardingLightField = memo(function OnboardingLightField({
  depth,
  holding = false,
  intensity,
  presentation,
}: {
  /** How deep the light is: 0 at the greeting, 1 on the welcome page. */
  depth: number;
  /**
   * A message is in flight: the drifting light holds still, so each frame
   * redraws only what flies rather than the whole field.
   */
  holding?: boolean;
  intensity: OnboardingLightIntensity;
  presentation: OnboardingPresentation;
}) {
  const dock = useDock(presentation);
  const style = {
    "--onboarding-light-depth": depth,
    ...(dock ? { "--onboarding-dock-size": `${dock.size}px` } : {}),
  } as CSSProperties;

  return (
    <div
      aria-hidden="true"
      className="comma-onboarding-light-field"
      data-dock={dock?.side}
      data-holding={holding || undefined}
      data-intensity={intensity}
      style={style}
    >
      {presentation === "overlay" ? (
        <div className="comma-onboarding-light-field__blur" />
      ) : null}
      <div className="comma-onboarding-light-field__veil" />
      {presentation === "overlay" ? (
        <div className="comma-onboarding-light-field__cover" />
      ) : null}
      <div className="comma-onboarding-light-field__deep" />
      <div className="comma-onboarding-light-field__night" />
      <div className="comma-onboarding-light-field__glow">
        <span className="comma-onboarding-light-field__bloom" data-bloom="horizon" />
        <span className="comma-onboarding-light-field__bloom" data-bloom="left" />
        <span className="comma-onboarding-light-field__bloom" data-bloom="right" />
      </div>
      {dock ? (
        <div className="comma-onboarding-light-field__floor">
          <span className="comma-onboarding-light-field__floor-deep" />
        </div>
      ) : null}
    </div>
  );
});

/**
 * Where the Dock sits under the onboarding window, from the display's work
 * area. The window covers the Dock and stays above it while Comma is active;
 * the light covers the Dock's band there. None over the product, or when the
 * Dock hides itself.
 */
function readDock(): Dock | undefined {
  const area = window.screen as Screen & { availLeft?: number; availTop?: number };
  const availLeft = area.availLeft ?? 0;
  const availTop = area.availTop ?? 0;
  const edges: readonly [Dock["side"], number][] = [
    ["bottom", window.screenY + window.innerHeight - availTop - area.availHeight],
    ["left", availLeft - window.screenX],
    ["right", window.screenX + window.innerWidth - availLeft - area.availWidth],
  ];
  const [side, size] = edges.reduce((widest, edge) =>
    edge[1] > widest[1] ? edge : widest
  );
  return size > 0 ? { side, size } : undefined;
}

function useDock(presentation: OnboardingPresentation) {
  const [dock, setDock] = useState<Dock>();
  useEffect(() => {
    if (presentation !== "window") return undefined;
    const update = () => {
      const next = readDock();
      setDock((current) =>
        current?.side === next?.side && current?.size === next?.size ? current : next
      );
    };
    update();
    // The sheet keeps its bounds when the Dock moves, resizes, or starts or
    // stops hiding itself, so no resize follows: the screen reports its new
    // work area, and a return from System Settings reads it again.
    // Chromium's Screen is an event target (the Window Management API's
    // `change`); the DOM typings here predate it.
    const screen = window.screen as Screen & EventTarget;
    window.addEventListener("resize", update);
    window.addEventListener("focus", update);
    screen.addEventListener("change", update);
    return () => {
      window.removeEventListener("resize", update);
      window.removeEventListener("focus", update);
      screen.removeEventListener("change", update);
    };
  }, [presentation]);
  return dock;
}
