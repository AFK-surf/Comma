// Lands the finite CSS motion a surface was running when it was hidden.
//
// AppLayout keeps Home mounted under another page and skips it with
// `content-visibility: hidden`. Chromium then stops updating the animations
// inside it, but still schedules the next frame from the state it last
// computed for them. A transition caught mid-flight by the hide, such as the
// send button's when the member opens another page right after typing, or a
// pressed card that opens one, therefore never reaches its end. One that runs on
// the main thread asks for a frame at every display frame until Home shows
// again, and each of those frames samples every other animation on the page:
// the visible page's composited loops restyle at display rate. Finishing the
// motion puts it where it was going while no one can see it. Loops never end;
// commaSurfacePause.css holds them paused.
//
// Only the style's own motion lands here: CSS transitions and CSS animations.
// An animation a script started (`Element.animate`) belongs to that script,
// which waits for its end to go on. The send flight
// (chat/motion/outgoingBubbleMotion.ts) settles its bubble when it lands: it
// reads the bubble's layout, hands the row back to the transcript and can
// start new motion. Finished from here, that work would run inside the hidden
// surface, and the motion it starts there would stay after this one pass.
export function finishHiddenSurfaceMotion(surface: Element) {
  // The document's list, not the surface's subtree list: that one forces the
  // skipped subtree's styles.
  for (const animation of surface.ownerDocument.getAnimations()) {
    if (!(animation instanceof CSSTransition || animation instanceof CSSAnimation))
      continue;
    const effect = animation.effect as KeyframeEffect | null;
    const target = effect?.target;
    if (!target || !surface.contains(target)) continue;
    // The play state follows the clock, not Chromium's last update: a
    // transition that ran out after a skipped frame reads "finished" and still
    // asks for frames. Only idle and paused animations ask for none.
    if (animation.playState === "idle" || animation.playState === "paused") continue;
    if (effect!.getComputedTiming().endTime === Infinity) continue;
    animation.finish();
  }
}
