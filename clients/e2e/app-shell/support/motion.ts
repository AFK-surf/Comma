import { testClock } from "./virtual-time";
import { expect, type Locator } from "./page";

/** Wait for finite UI motion without waiting on a loading shimmer or caret. */
export async function waitForSettledMotion(locator: Locator): Promise<void> {
  await expect(locator).toBeVisible();
  // Let mount-time entry styles start their transitions before checking them.
  await testClock().advanceFrames(2);
  await expect
    .poll(() =>
      locator.evaluate(
        (element) =>
          element
            .getAnimations({ subtree: true })
            .filter(
              (animation) =>
                (animation.pending || animation.playState === "running") &&
                animation.effect?.getComputedTiming().iterations !== Infinity
            ).length
      )
    )
    .toBe(0);
}
