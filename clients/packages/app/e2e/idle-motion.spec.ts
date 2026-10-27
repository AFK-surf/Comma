import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { waitForFiniteAnimations } from "../../../e2e/helpers/motion";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

const runningTasks = Array.from({ length: 3 }, (_, index) => ({
  id: `cnv_idle_motion_${index}`,
  status: "in_progress",
  title: `Idle motion task ${index}`,
}));

/** Properties the compositor animates without a style recalculation. */
const compositorProperties = ["opacity", "rotate", "scale", "transform", "translate"];

// A running Task's shine loops for as long as the Task runs. It moves on the
// compositor: a loop on any other property restyles and paints the whole page
// at every display frame, and every interaction then shares those frames.
// The test reads what each loop animates, not how much work a stretch of real
// time took, so a loaded machine gives the same result.
test("Home's running Tasks shine without restyling the page each frame", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    extraInlineTasks: runningTasks,
    includeTaskInInbox: true,
    taskStatus: "in_progress",
  });
  try {
    await page.setViewportSize({ width: 1600, height: 960 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "idle-motion@comma.local",
      token: "comma_sess_idle_motion",
    });
    await page.goto("/");
    await expect(
      page.getByTestId("home-tasks-rail").locator(".comma-shiny-text").first()
    ).toBeVisible();
    await waitForFiniteAnimations(page);

    const loops = await page.evaluate(() =>
      document
        .getAnimations()
        .filter(
          (animation) =>
            animation.playState === "running" &&
            animation.effect?.getComputedTiming().iterations === Infinity
        )
        .map((animation) => {
          const effect = animation.effect as KeyframeEffect;
          const target = effect.target;
          const properties = new Set(
            effect
              .getKeyframes()
              .flatMap((keyframe) => Object.keys(keyframe))
              .filter(
                (key) =>
                  !["composite", "computedOffset", "easing", "offset"].includes(key)
              )
          );
          return {
            name:
              animation instanceof CSSAnimation
                ? animation.animationName
                : animation.id,
            target: `${target?.getAttribute("class") ?? ""}${effect.pseudoElement ?? ""}`,
            properties: [...properties].toSorted(),
          };
        })
    );
    // The rail's shines are among the loops, so the check covers them.
    expect(
      loops.filter((loop) => loop.name === "comma-shiny-text-shine").length
    ).toBeGreaterThan(0);
    expect(
      loops.filter((loop) =>
        loop.properties.some((property) => !compositorProperties.includes(property))
      )
    ).toEqual([]);
  } finally {
    await stub.close();
  }
});
