import { expect, test, type Page, useFixture } from "./support/page";
import { fixtureMount } from "./support/fixture";
import { testClock } from "./support/virtual-time";

// The test clock's hover settling (./support/hover): content moving under a
// pointer that stays still is hovered by the next step, as the browser decides
// it, through overlays that let the pointer pass, shadow roots and frames.
useFixture(
  fixtureMount(
    new URL("./fixtures/focus-ring/src/main.ts", import.meta.url),
    `<style>
      .box { position: fixed; width: 100px; height: 100px; }
      #target { left: 0; top: 0; background: rgb(255, 0, 0); }
      #target:hover { background: rgb(0, 0, 255); }
      #overlay { left: 200px; top: 200px; pointer-events: none; }
    </style>
    <div class="box" id="target"></div>
    <div class="box" id="overlay"></div>
    <div class="box" id="host" style="left: 400px; top: 0"></div>
    <label class="box" id="label" style="left: 600px; top: 0"><input id="control" /></label>
    <iframe id="frame" style="position: fixed; left: 0; top: 400px; width: 200px; height: 200px; border: 0"
      srcdoc="<style>body{margin:0}#inner{width:100px;height:100px}</style><div id=inner></div>"></iframe>`
  )
);
const fixtureUrl = "http://fixture.test/";

const hovered = (page: Page) =>
  page.evaluate(() => {
    const host = document.getElementById("host")!;
    const frame = document.getElementById("frame") as HTMLIFrameElement;
    const roots = {
      top: document,
      shadow: host.shadowRoot,
      frame: frame.contentDocument,
    };
    return Object.fromEntries(
      Object.entries(roots).map(([name, root]) => [
        name,
        root
          ? Array.from(root.querySelectorAll(":hover"), (element) => element.id).filter(
              Boolean
            )
          : [],
      ])
    ) as { top: string[]; shadow: string[]; frame: string[] };
  });

test("content that moves under a still pointer is hovered by the next step", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.mouse.move(250, 250);
  await page.evaluate(() => {
    const target = document.getElementById("target")!;
    target.style.left = "220px";
    target.style.top = "220px";
  });
  await testClock().advanceFrames(1);
  expect((await hovered(page)).top).toContain("target");
});

test("content moved by a transition alone under a still pointer is hovered by the next step", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.mouse.move(250, 250);
  await page.evaluate(() => {
    const target = document.getElementById("target")!;
    target.style.transition = "translate 200ms linear";
    target.getBoundingClientRect();
    target.style.translate = "220px 220px";
  });
  await testClock().advance(200);
  expect((await hovered(page)).top).toContain("target");
});

test("an overlay the pointer passes through leaves the content under it hovered", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.mouse.move(250, 250);
  await testClock().advanceFrames(1);
  // The pointer-events: none overlay covers the pointer; the target moves in
  // beneath it.
  await page.evaluate(() => {
    const target = document.getElementById("target")!;
    target.style.left = "200px";
    target.style.top = "200px";
  });
  await testClock().advanceFrames(1);
  const state = await hovered(page);
  expect(state.top).toContain("target");
  expect(state.top).not.toContain("overlay");
});

test("a button in a shadow root is hovered with its host", async ({ page }) => {
  await page.goto(fixtureUrl);
  await page.evaluate(() => {
    const host = document.getElementById("host")!;
    const root = host.attachShadow({ mode: "open" });
    root.innerHTML =
      '<button id="shadow-button" style="width:100px;height:100px;margin:0;margin-top:120px">Go</button>';
  });
  await page.mouse.move(450, 50);
  await page.evaluate(() => {
    const button = document
      .getElementById("host")!
      .shadowRoot!.getElementById("shadow-button")!;
    button.style.marginTop = "0";
  });
  await testClock().advanceFrames(1);
  const state = await hovered(page);
  expect(state.top).toContain("host");
  expect(state.shadow).toContain("shadow-button");
});

test("an element in a nested frame is hovered with the frame", async ({ page }) => {
  await page.goto(fixtureUrl);
  await page.mouse.move(150, 450);
  await page.evaluate(() => {
    const frame = document.getElementById("frame") as HTMLIFrameElement;
    frame.contentDocument!.getElementById("inner")!.style.marginLeft = "100px";
  });
  await testClock().advanceFrames(1);
  const state = await hovered(page);
  expect(state.top).toContain("frame");
  expect(state.frame).toContain("inner");
});

test("a label's control is hovered with the label", async ({ page }) => {
  await page.goto(fixtureUrl);
  await page.mouse.move(650, 150);
  await page.evaluate(() => {
    document.getElementById("label")!.style.top = "100px";
  });
  await testClock().advanceFrames(1);
  const state = await hovered(page);
  expect(state.top).toContain("label");
  expect(state.top).toContain("control");
});

test("an element holding pointer capture stays hovered when the pointer leaves it", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.evaluate(() => {
    const target = document.getElementById("target")!;
    target.addEventListener("pointerdown", (event) =>
      target.setPointerCapture(event.pointerId)
    );
  });
  await page.mouse.move(50, 50);
  await page.mouse.down();
  await page.mouse.move(250, 250);
  expect((await hovered(page)).top).toContain("target");
  await page.mouse.up();
});
