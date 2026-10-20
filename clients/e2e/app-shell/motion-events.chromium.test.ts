import { expect, test, useFixture } from "./support/page";
import { fixtureMount } from "./support/fixture";
import { testClock } from "./support/virtual-time";

// The test runtime's motion events (packages/ui/src/runtime/test/testing.ts):
// a page receives the animation events a browser sends, on page time.
useFixture(
  fixtureMount(
    new URL("./fixtures/focus-ring/src/main.ts", import.meta.url),
    `<style>
      @keyframes appear { from { opacity: 0 } to { opacity: 1 } }
      .appearing { animation: appear 200ms linear }
      @media (prefers-reduced-motion: reduce) { .appearing { animation-duration: 0s } }
    </style>
    <div id="target"></div>`
  )
);
const fixtureUrl = "http://fixture.test/";

for (const reducedMotion of ["reduce", "no-preference"] as const) {
  test(`an animation sends one start and one end: ${reducedMotion}`, async ({
    page,
  }) => {
    await page.emulateMedia({ reducedMotion });
    await page.goto(fixtureUrl);
    await page.evaluate(() => {
      const target = document.getElementById("target")!;
      const events: string[] = [];
      for (const type of ["animationstart", "animationend"])
        target.addEventListener(type, (event) =>
          events.push(`${type} ${(event as AnimationEvent).animationName}`)
        );
      Object.assign(window, { animationEvents: events });
      target.className = "appearing";
    });
    const events = () =>
      page.evaluate(
        () => (window as unknown as { animationEvents: string[] }).animationEvents
      );
    await testClock().advanceFrames(1);
    expect(await events()).toEqual(
      reducedMotion === "reduce"
        ? ["animationstart appear", "animationend appear"]
        : ["animationstart appear"]
    );
    await testClock().advance(400);
    expect(await events()).toEqual(["animationstart appear", "animationend appear"]);
  });
}
