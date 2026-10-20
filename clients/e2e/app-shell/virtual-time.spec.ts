import { expect, test } from "@playwright/test";
import { installVirtualTime } from "../helpers/virtual-time";

const html = `<!doctype html><style>
  #transition { width: 0; transition: width 1000ms linear; }
  #keyframes { animation: grow 1000ms linear forwards; }
  @keyframes grow { from { width: 0 } to { width: 1000px } }
</style><div id="transition"></div><div id="keyframes"></div><div id="waapi"></div>`;

test("virtual time stops and steps timers, frames and animations together", async ({
  page,
}) => {
  const time = await installVirtualTime(page);
  await page.route("http://virtual-time.test/", (route) =>
    route.fulfill({ contentType: "text/html", body: html })
  );
  await page.goto("http://virtual-time.test/");
  await page.evaluate(() => {
    const state = { frames: 0, frameTime: 0, ticks: 0, events: [] as string[] };
    Reflect.set(window, "state", state);
    const frame = (now: number) => {
      state.frames++;
      state.frameTime = now;
      if (now !== document.timeline.currentTime) state.events.push("timeline");
      requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
    setInterval(() => state.ticks++, 10);
    const waapi = document.querySelector<HTMLElement>("#waapi")!;
    waapi
      .animate([{ width: "0px" }, { width: "1000px" }], {
        duration: 1000,
        fill: "forwards",
      })
      .finished.then(() => state.events.push("finished"));
    // Started on the document timeline, as motion code does.
    const started = waapi.animate([{ opacity: 0 }, { opacity: 1 }], 1000);
    started.startTime = Number(document.timeline.currentTime) - 100;
    Reflect.set(window, "started", started);
    // Half speed: a step moves it by half the step.
    waapi.animate([{ height: "0px" }, { height: "1000px" }], {
      duration: 1000,
      fill: "forwards",
    }).playbackRate = 0.5;
    const transition = document.querySelector<HTMLElement>("#transition")!;
    transition.addEventListener("transitionend", () =>
      state.events.push("transitionend")
    );
    transition.getBoundingClientRect();
    transition.style.width = "1000px";
    Reflect.set(window, "origin", performance.now());
  });
  const read = () =>
    page.evaluate(() => {
      const state = Reflect.get(window, "state");
      const [transition = 0, keyframes = 0, waapi = 0] = [
        "transition",
        "keyframes",
        "waapi",
      ].map((id) =>
        Math.round(parseFloat(getComputedStyle(document.getElementById(id)!).width))
      );
      return {
        elapsed: performance.now() - Number(Reflect.get(window, "origin")),
        frames: state.frames,
        ticks: state.ticks,
        transition,
        keyframes,
        waapi,
        slow: Math.round(
          parseFloat(getComputedStyle(document.getElementById("waapi")!).height)
        ),
        events: [...state.events],
        started: Math.round(Number(Reflect.get(window, "started").currentTime)),
      };
    });

  const still = await read();
  // The browser renders real frames for a screenshot; page time stays still.
  await page.screenshot();
  expect(await read()).toEqual(still);
  expect(still).toMatchObject({
    elapsed: 0,
    frames: 0,
    ticks: 0,
    transition: 0,
    started: 100,
  });

  await time.advance(160);
  const stepped = await read();
  expect(stepped.elapsed).toBe(160);
  expect(stepped.ticks).toBe(16);
  expect(stepped.frames).toBe(10);
  // The animations move with the frames, so they reach the last frame's time.
  for (const value of [stepped.transition, stepped.keyframes, stepped.waapi]) {
    expect(value).toBeGreaterThan(130);
    expect(value).toBeLessThanOrEqual(160);
  }
  expect(stepped.transition).toBe(stepped.waapi);
  expect(stepped.started).toBe(stepped.waapi + 100);
  expect(stepped.slow).toBe(Math.round(stepped.waapi / 2));

  await time.advance(900);
  const ended = await read();
  expect(ended).toMatchObject({ transition: 1000, keyframes: 1000, waapi: 1000 });
  expect(ended.slow).toBeLessThan(1000);
  // The step rendered the frame that ended them, so their events have run.
  expect(ended.events.toSorted()).toEqual(["finished", "transitionend"]);

  // Released, the page runs on real time again.
  await time.release();
  await page.evaluate(() => {
    const transition = document.querySelector<HTMLElement>("#transition")!;
    transition.style.transitionDuration = "50ms";
    transition.style.width = "0px";
  });
  await expect.poll(async () => (await read()).transition).toBe(0);
});
