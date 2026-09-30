import { expect, test, type Page } from "@playwright/test";

const story =
  "/iframe.html?id=app-components-chat-message-send-motion--spring-playground&viewMode=story";
const channels = ["width", "position", "height"] as const;

test("slow replay uses one playback rate for the bubble, text and input chrome", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto(story);
  await expect(page.getByTestId("message-send-playground")).toBeVisible({
    timeout: 30_000,
  });
  for (const rate of [0.25, 0.5, 0.75, 1]) {
    await page
      .getByRole("button", {
        name: rate === 1 ? "Replay send" : `Replay ${rate}×`,
        exact: true,
      })
      .click();
    const bubble = page.locator(
      '.comma-chat-user-bubble[data-outgoing-presentation="flying"]'
    );
    await expect(bubble).toHaveCount(1);
    await page.waitForFunction(
      () =>
        document
          .querySelector('.comma-chat-user-bubble[data-outgoing-presentation="flying"]')
          ?.getAnimations()[0]?.playState === "running"
    );
    const timing = await bubble.evaluate((element) => ({
      rates: element
        .getAnimations({ subtree: true })
        .map((animation) => animation.playbackRate),
      duration: Number(element.getAnimations()[0]!.effect!.getTiming().duration),
    }));
    expect(timing.rates.length).toBeGreaterThanOrEqual(2);
    expect(timing.rates.every((value) => value === rate)).toBe(true);
    expect(timing.duration).toBeGreaterThan(850);
    expect(timing.duration).toBeLessThan(950);
    await expect(page.getByTestId("motion-total-duration")).toHaveText(
      `Replay: ${Math.round(timing.duration / rate)} ms (${rate}×)`
    );
    await expect(bubble).toHaveCount(0);
    await expect(page.locator(".comma-chat-user-bubble")).toHaveCount(1);
  }
});

test("a quarter-speed replay survives the normal four-second launch expiry", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto(story);
  await setControl(page, "Position Delay (ms)", 750);
  await page.getByRole("button", { name: "Replay 0.25×", exact: true }).click();
  const bubble = page.locator(
    '.comma-chat-user-bubble[data-outgoing-presentation="flying"]'
  );
  await expect(bubble).toHaveCount(1);
  // This must pass the real expiry timer; seeking WAAPI would not exercise it.
  await page.waitForTimeout(4_200);
  await expect(bubble).toHaveCount(1);
  await expect(bubble).toHaveCount(0);
  await expect(page.locator(".comma-chat-user-bubble")).toHaveCount(1);
});

async function setControl(page: Page, name: string, value: number) {
  const input = page.getByRole("textbox", { name, exact: true });
  await input.fill(String(value));
  await input.press("Enter");
}

async function readConfig(page: Page) {
  return JSON.parse((await page.getByTestId("motion-config").textContent())!);
}

test("width supports editable Bézier timing and preserves the Spring configuration", async ({
  page,
}) => {
  await page.goto(story);
  await expect(page.getByTestId("message-send-playground")).toBeVisible({
    timeout: 30_000,
  });
  const initial = await readConfig(page);
  expect(initial.widthCurve.mode).toBe("spring");
  await page.getByRole("button", { name: "Bézier", exact: true }).click();
  const curve = page.locator('path[data-spring-curve="width"]');
  const before = await curve.getAttribute("d");
  await setControl(page, "Width X1", 0.6);
  await setControl(page, "Width Duration (ms)", 600);
  await setControl(page, "Width Delay (ms)", 80);
  await expect(curve).not.toHaveAttribute("d", before!);
  const edited = await readConfig(page);
  expect(edited.widthCurve).toMatchObject({ x1: 0.6, durationMs: 600 });
  expect(edited.position).toEqual(initial.position);
  expect(edited.height).toEqual(initial.height);
  await page.getByRole("button", { name: "Spring", exact: true }).click();
  expect((await readConfig(page)).width).toEqual({ ...initial.width, delayMs: 80 });
  await expect(
    page.getByRole("textbox", { name: "Width Response (s)", exact: true })
  ).toBeVisible();
  await page.getByRole("button", { name: "Bézier", exact: true }).click();
  expect((await readConfig(page)).widthCurve).toEqual(edited.widthCurve);
});

test("the spring panel edits each channel, exports its configuration and resets", async ({
  page,
  context,
}) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.goto(story);
  // The first source Story load compiles the real chat renderer and its dependencies.
  await expect(page.getByTestId("message-send-playground")).toBeVisible({
    timeout: 30_000,
  });
  const initial = await readConfig(page);
  await page.getByRole("button", { name: "Spring", exact: true }).click();

  for (const [index, channel] of channels.entries()) {
    const label = channel[0]!.toUpperCase() + channel.slice(1);
    const curve = page.locator(`path[data-spring-curve="${channel}"]`);
    const before = await curve.getAttribute("d");
    const previous = await readConfig(page);
    await setControl(page, `${label} Response (s)`, 0.5);
    await setControl(page, `${label} Damping ratio`, 0.65);
    await setControl(page, `${label} Initial velocity`, 2);
    await setControl(page, `${label} Delay (ms)`, 100 * (index + 1));
    await setControl(page, `${label} Rebound limit (px)`, 6);
    const edited = await readConfig(page);
    expect(edited[channel]).toEqual({
      response: 0.5,
      dampingRatio: 0.65,
      initialVelocity: 2,
      delayMs: 100 * (index + 1),
      maxOvershootPx: 6,
    });
    for (const other of channels.filter((name) => name !== channel)) {
      expect(edited[other]).toEqual(previous[other]);
    }
    await expect(curve).not.toHaveAttribute("d", before!);
  }

  await setControl(page, "Surface Compression ratio", 0.03);
  await setControl(page, "Surface Response (s)", 0.4);
  await setControl(page, "Surface Damping ratio", 0.7);
  await setControl(page, "Surface Delay (ms)", 80);
  const config = await readConfig(page);
  expect(config.surfacePulse).toEqual({
    amount: 0.03,
    response: 0.4,
    dampingRatio: 0.7,
    delayMs: 80,
  });

  await page.getByRole("button", { name: "Copy configuration", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Copied configuration" })
  ).toBeVisible();
  expect(JSON.parse(await page.evaluate(() => navigator.clipboard.readText()))).toEqual(
    await readConfig(page)
  );
  await page.getByRole("button", { name: "Reset", exact: true }).click();
  expect(await readConfig(page)).toEqual(initial);
});

test("the bubble and text scale together without visible intermediate wrapping", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto(story);
  await page.getByRole("button", { name: "Multiline", exact: true }).click();
  await page.getByRole("button", { name: "Replay send", exact: true }).click();
  const bubble = page.locator(
    '.comma-chat-user-bubble[data-outgoing-presentation="flying"]'
  );
  await expect(bubble).toHaveCount(1);
  await page.waitForFunction(
    () =>
      document
        .querySelector('.comma-chat-user-bubble[data-outgoing-presentation="flying"]')
        ?.getAnimations()[0]?.playState === "running"
  );
  const frames = await bubble.evaluate((element) => {
    const content = element.querySelector<HTMLElement>(
      ".comma-chat-user-bubble-content"
    )!;
    const animations = element.getAnimations({ subtree: true });
    for (const animation of animations) animation.pause();
    return [0, 40, 70, 90, 100, 110, 160, 250, 400, 650, 800, 900, 1000, 1200].map(
      (time) => {
        for (const animation of animations) animation.currentTime = time;
        const matrix = new DOMMatrixReadOnly(getComputedStyle(element).transform);
        const style = getComputedStyle(content);
        return {
          time,
          x: matrix.a,
          y: matrix.d,
          width: parseFloat(style.width),
          opacity: parseFloat(style.opacity),
          textScale: content.getBoundingClientRect().width / parseFloat(style.width),
        };
      }
    );
  });
  const targetWidth = frames.at(-1)!.width;
  for (const frame of frames) {
    expect(Math.abs(frame.x - frame.y)).toBeLessThan(0.001);
    expect(Math.abs(frame.textScale - frame.x)).toBeLessThan(0.001);
    expect(Math.abs(frame.width - targetWidth)).toBeLessThan(0.5);
  }
  expect(frames.every((frame) => frame.opacity === 1)).toBe(true);
  expect(Math.min(...frames.map((frame) => frame.x))).toBeLessThan(0.72);
  expect(Math.max(...frames.map((frame) => frame.x))).toBeLessThan(1.01);
  expect(frames.at(-1)!.x).toBeCloseTo(1, 3);
});

for (const surface of ["main", "side"] as const) {
  test(`${surface} chat replays the actual bubble with independent width, height and position delays`, async ({
    page,
  }) => {
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.goto(story);
    if (surface === "side") {
      await page.getByRole("button", { name: "Preview side chat" }).click();
    }
    await setControl(page, "Surface Compression ratio", 0);
    await setControl(page, "Width Delay (ms)", 0);
    await setControl(page, "Height Delay (ms)", 300);
    await setControl(page, "Position Delay (ms)", 650);
    // Explicit line breaks produce a different input height and bubble height.
    await page.getByRole("button", { name: "Multiline", exact: true }).click();
    const composer = page.locator(".comma-chat-composer");
    await expect(composer).toBeInViewport();
    const source = await composer.boundingBox();
    const preview = page.getByRole("region", { name: "Conversation", exact: true });
    const box = await preview.boundingBox();
    expect(source!.y).toBeGreaterThan(box!.y + box!.height / 2);
    expect(source!.y + source!.height).toBeLessThanOrEqual(box!.y + box!.height);
    await page.getByRole("button", { name: "Replay send", exact: true }).click();
    const bubble = page.locator(
      '.comma-chat-user-bubble[data-outgoing-presentation="flying"]'
    );
    await expect(bubble).toHaveCount(1);
    await page.waitForFunction(() =>
      document
        .querySelector('.comma-chat-user-bubble[data-outgoing-presentation="flying"]')
        ?.getAnimations()
        .some((animation) => animation.playState === "running")
    );
    const samples = await bubble.evaluate((element) => {
      const animations = element.getAnimations({ subtree: true });
      const primary = element.getAnimations()[0]!;
      for (const animation of animations) animation.pause();
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
      svg.style.cssText = "position:fixed;width:0;height:0;visibility:hidden";
      svg.append(path);
      document.body.append(svg);
      const sample = (time: number) => {
        for (const animation of animations) animation.currentTime = time;
        const style = getComputedStyle(element);
        // Measure the first closed subpath: the bubble body. The separate
        // tail extends below it and is not part of the composer's height.
        const outline = style.clipPath.match(/^path\("([^"]+)"\)$/)?.[1];
        const body = outline?.match(/^[^zZ]*[zZ]/)?.[0];
        if (!body) throw new Error(`Expected a closed bubble path: ${style.clipPath}`);
        path.setAttribute("d", body);
        const bounds = path.getBBox();
        const transform = new DOMMatrixReadOnly(style.transform);
        return {
          width: bounds.width * transform.a,
          height: bounds.height * transform.d,
          x: transform.m41,
          y: transform.m42,
        };
      };
      const frames = [0, 150, 450, 850].map(sample);
      svg.remove();
      for (const animation of animations) {
        animation.currentTime = Number(primary.effect!.getTiming().duration) - 20;
        animation.play();
      }
      return frames;
    });
    const [start, width, height, position] = samples;
    expect(Math.abs(start!.width - source!.width)).toBeLessThan(1);
    expect(Math.abs(start!.height - source!.height)).toBeLessThan(1);
    expect(start!.width - width!.width).toBeGreaterThan(5);
    expect(Math.abs(width!.height - start!.height)).toBeLessThan(0.5);
    expect(Math.abs(width!.y - start!.y)).toBeLessThan(0.5);
    expect(Math.abs(height!.height - start!.height)).toBeGreaterThan(3);
    expect(Math.abs(height!.y - start!.y)).toBeLessThan(0.5);
    expect(Math.abs(position!.y - start!.y)).toBeGreaterThan(5);
    await expect(bubble).toHaveCount(0);
    await expect(page.locator(".comma-chat-user-bubble")).toHaveCount(1);
  });
}
