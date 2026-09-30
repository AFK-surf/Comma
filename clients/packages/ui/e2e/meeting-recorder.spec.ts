import { expect, test } from "@playwright/test";

for (const immediate of [false, true]) {
  test(`recorder animates real card height through ${immediate ? "immediate" : "starting"} capture and saving`, async ({
    page,
  }) => {
    // Sample the rendered surface along each real height animation. Previously
    // only the background scaled: the card/hit area jumped straight to its end size.
    await page.addInitScript(() => {
      const samples: {
        phase: string;
        from: number;
        to: number;
        heights: number[];
        surfaces: number[];
        duration: number;
      }[] = [];
      Object.assign(window, { recorderResizeSamples: samples });
      const animate = Element.prototype.animate;
      Element.prototype.animate = function (frames, options) {
        const animation = animate.call(this, frames, options);
        if (
          this.matches('[data-slot="meeting-recorder"]') &&
          Array.isArray(frames) &&
          frames[0]?.height
        ) {
          const duration = Number(animation.effect!.getTiming().duration);
          animation.pause();
          const heights: number[] = [];
          const surfaces: number[] = [];
          for (const time of [0, duration / 2, duration]) {
            animation.currentTime = time;
            heights.push(this.getBoundingClientRect().height);
            surfaces.push(
              this.querySelector(".comma-recorder-surface")!.getBoundingClientRect()
                .height
            );
          }
          samples.push({
            phase: this.getAttribute("data-phase")!,
            from: Number.parseFloat(String(frames[0].height)),
            to: Number.parseFloat(String(frames[1]!.height)),
            heights,
            surfaces,
            duration,
          });
          animation.currentTime = 0;
          animation.play();
        }
        return animation;
      };
    });
    await page.goto(
      `/iframe.html?id=app-components-meeting-recorder--${immediate ? "interactive-immediate" : "interactive"}&viewMode=story`
    );
    const card = page.getByTestId("meeting-recorder-demo");
    await card.getByRole("button", { name: "Start recording" }).click();
    await expect(card).toHaveAttribute("data-phase", "recording");
    if (immediate) {
      await card.getByRole("button", { name: "Pause recording" }).click();
      await expect(card).toHaveAttribute("data-phase", "paused");
    }
    await card.getByRole("button", { name: "Stop", exact: true }).click();
    await expect(card).toHaveAttribute("data-phase", "saving");
    const samples = await page.evaluate(
      () =>
        (
          window as unknown as {
            recorderResizeSamples: {
              phase: string;
              from: number;
              to: number;
              heights: number[];
              surfaces: number[];
              duration: number;
            }[];
          }
        ).recorderResizeSamples
    );
    const phases = immediate
      ? ["recording", "saving"]
      : ["starting", "recording", "saving"];
    for (const phase of phases) {
      const sample = samples.find((entry) => entry.phase === phase)!;
      expect(sample, `${phase} has a real window transition`).toBeDefined();
      expect(sample.duration).toBe(180);
      expect(sample.heights[0]).toBeCloseTo(sample.from, 1);
      expect(sample.heights[2]).toBeCloseTo(sample.to, 1);
      expect(sample.heights[1]).toBeGreaterThan(Math.min(sample.from, sample.to));
      expect(sample.heights[1]).toBeLessThan(Math.max(sample.from, sample.to));
      expect(sample.surfaces).toEqual(sample.heights);
    }
    if (immediate)
      expect(samples.some((entry) => entry.phase === "starting")).toBe(false);
  });
}

test("meeting recorder walks detected → recording → paused → saved", async ({
  page,
}) => {
  await page.goto("/?path=/story/app-components-meeting-recorder--interactive");

  const preview = page.locator("#storybook-preview-iframe").contentFrame();
  const card = preview.getByTestId("meeting-recorder-demo");
  await expect(card).toHaveAttribute("data-phase", "detected");
  await expect(card).toContainText("Meeting detected");
  await expect(card.getByRole("button", { name: "Show in Drive" })).toHaveCount(0);
  await expect(card.getByRole("button", { name: "Open file" })).toHaveCount(0);

  await card.getByRole("button", { name: "Start recording" }).click();
  await expect(card).toHaveAttribute("data-phase", "recording");
  const timer = card.getByRole("timer");
  await expect(timer).toBeVisible();
  await expect(card.getByRole("button", { name: "Choose microphone" })).toBeEnabled();

  const expectRecorderColors = async (paused: boolean) => {
    await expect
      .poll(() =>
        card.evaluate((element, isPaused) => {
          const targets = [
            [
              '[data-slot="meeting-recorder-static-logo"]',
              isPaused
                ? "--color-ai-input-panel-icon-disabled"
                : "--color-text-primary",
            ],
            [
              "[role=timer]",
              isPaused ? "--color-text-disabled" : "--color-text-secondary",
            ],
          ] as const;
          return targets.every(([selector, token]) => {
            const target = element.querySelector(selector)!;
            const style = getComputedStyle(target);
            const probe = document.createElement("span");
            probe.style.color = `var(${token})`;
            element.append(probe);
            const expected = getComputedStyle(probe).color;
            probe.remove();
            const colorIndex = style.transitionProperty.split(", ").indexOf("color");
            return (
              style.color === expected &&
              style.transitionDuration.split(", ")[colorIndex] === "0.05s"
            );
          });
        }, paused)
      )
      .toBe(true);
  };

  // Pausing freezes the clock and dims the logo and timer with a 50ms color transition.
  await card.getByRole("button", { name: "Pause recording" }).click();
  await expect(card).toHaveAttribute("data-phase", "paused");
  await expectRecorderColors(true);
  const frozen = await timer.textContent();
  await page.waitForTimeout(1_200);
  expect(await timer.textContent()).toBe(frozen);
  await expect(card.getByRole("img", { name: "Live audio level" })).toHaveCount(0);

  await card.getByRole("button", { name: "Resume recording" }).click();
  await expect(card).toHaveAttribute("data-phase", "recording");
  await expectRecorderColors(false);

  await card.getByRole("button", { name: "Stop", exact: true }).click();
  await expect(card).toHaveAttribute("data-phase", "saved");
  await expect(card).toContainText("comma-recording-2026-08-26T21-38-46.wav");

  const reveal = card.getByRole("button", { name: "Show in Drive" });
  const open = card.getByRole("button", { name: "Open file" });
  await reveal.click();
  await expect(reveal).toHaveAttribute("data-pending", "true");
  await expect(open).toBeDisabled();
  await expect(preview.getByText("Preview: Show in Drive completed.")).toBeVisible();
  await expect(card).toHaveAttribute("data-phase", "saved");
  await open.click();
  await expect(open).toHaveAttribute("data-pending", "true");
  await expect(reveal).toBeDisabled();
  await expect(preview.getByText("Preview: Open file completed.")).toBeVisible();
  await expect(card).toContainText("comma-recording-2026-08-26T21-38-46.wav");

  await card.getByRole("button", { name: "Dismiss" }).click();
  await expect(card).toHaveAttribute("data-phase", "detected");
});

test("saved recording file actions fit long names and narrow windows", async ({
  page,
}) => {
  await page.setViewportSize({ width: 360, height: 800 });
  await page.goto(
    "/iframe.html?id=app-components-meeting-recorder--saved-long-file-name&viewMode=story"
  );
  const card = page.locator('[data-slot="meeting-recorder"]');
  await expect(card.getByRole("button", { name: "Show in Drive" })).toBeVisible();
  await expect(card.getByRole("button", { name: "Open file" })).toBeVisible();
  const geometry = await card.evaluate((element) => {
    const cardBounds = element.getBoundingClientRect();
    const actions = Array.from(element.querySelectorAll("button")).map((button) =>
      button.getBoundingClientRect()
    );
    return {
      contentFits: element.scrollWidth <= element.clientWidth,
      cardFits: cardBounds.left >= 0 && cardBounds.right <= window.innerWidth,
      actionsFit: actions.every(
        (action) => action.left >= cardBounds.left && action.right <= cardBounds.right
      ),
    };
  });
  expect(geometry).toEqual({ contentFits: true, cardFits: true, actionsFit: true });
});

test("a file action failure leaves the saved recording available", async ({ page }) => {
  await page.goto("/?path=/story/app-components-meeting-recorder--saved-action-error");
  const preview = page.locator("#storybook-preview-iframe").contentFrame();
  const card = preview.locator('[data-slot="meeting-recorder"]');
  await expect(card).toHaveAttribute("data-phase", "saved");
  await expect(card.getByRole("alert")).toContainText("Try again.");
  await expect(card.getByRole("button", { name: "Show in Drive" })).toBeEnabled();
  await expect(card.getByRole("button", { name: "Open file" })).toBeEnabled();
});

test("meeting recorder shows eight expanded states and one interactive compact state", async ({
  page,
}) => {
  await page.goto("/?path=/story/app-components-meeting-recorder--states");

  const preview = page.locator("#storybook-preview-iframe").contentFrame();
  const cards = preview.locator('[data-slot="meeting-recorder"]');
  await expect(cards).toHaveCount(9);

  const compact = preview.locator('[data-slot="meeting-recorder"][data-compact]');
  await expect(compact).toHaveCount(1);
  await expect
    .poll(() => compact.evaluate((el) => el.getBoundingClientRect().width))
    .toBe(227);
  expect(
    await cards.evaluateAll((elements) =>
      elements
        .filter((el) => !el.hasAttribute("data-compact"))
        .map((el) => el.getBoundingClientRect().width)
    )
  ).toEqual(Array(8).fill(370));
  const smallCard = cards.nth(4);
  await smallCard.hover();
  await expect
    .poll(() => smallCard.evaluate((el) => el.getBoundingClientRect().width))
    .toBe(370);
});

type InitialRecorderPlacement = {
  placement: string;
  x: number;
  y: number;
  width: number;
  height: number;
  viewportWidth: number;
  viewportHeight: number;
};

test("recorder placement is stable from its first painted frame", async ({ page }) => {
  // Observe paint from before React mounts. Waiting for visibility alone used to
  // miss the short left/top transition from CSS anchors to center coordinates.
  await page.addInitScript(() => {
    const samples: InitialRecorderPlacement[] = [];
    Object.assign(window, { recorderInitialPlacement: samples });
    const observed = new WeakSet<Element>();
    const sample = () => {
      for (const element of document.querySelectorAll(".comma-draggable-recorder")) {
        if (observed.has(element)) continue;
        observed.add(element);
        const bounds = element.getBoundingClientRect();
        samples.push({
          placement: element.getAttribute("data-placement")!,
          x: bounds.x,
          y: bounds.y,
          width: bounds.width,
          height: bounds.height,
          viewportWidth: innerWidth,
          viewportHeight: innerHeight,
        });
      }
      requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
  });
  await page.goto(
    "/iframe.html?id=app-components-meeting-recorder--placement&viewMode=story"
  );
  await page
    .getByTestId("meeting-recorder-demo")
    .getByRole("button", { name: "Start recording" })
    .click();
  const samples = await page
    .waitForFunction(() => {
      const entries = (
        window as typeof window & {
          recorderInitialPlacement: InitialRecorderPlacement[];
        }
      ).recorderInitialPlacement;
      return entries.length === 2 ? entries : false;
    })
    .then((handle) => handle.jsonValue());
  if (!samples)
    throw new Error("Both recorder placements must paint before assertions.");
  const desktop = samples.find((entry) => entry.placement === "top-center")!;
  const client = samples.find((entry) => entry.placement === "bottom-left")!;
  expect(desktop.y).toBeCloseTo(32, 0);
  expect(desktop.x + desktop.width / 2).toBeCloseTo(desktop.viewportWidth / 2, 0);
  expect(client.x).toBeCloseTo(24, 0);
  expect(client.y + client.height).toBeCloseTo(client.viewportHeight - 24, 0);
});

test("desktop recorder starts top centre, separate from the client block", async ({
  page,
}) => {
  await page.goto("/?path=/story/app-components-meeting-recorder--placement");

  const preview = page.locator("#storybook-preview-iframe").contentFrame();
  const card = preview.locator('[data-slot="meeting-recorder"]');
  await expect(card).toBeVisible();

  const geometry = await card.evaluate((element) => {
    const box = element.getBoundingClientRect();
    return {
      centreOffset: Math.round(box.left + box.width / 2 - window.innerWidth / 2),
      top: Math.round(box.top),
    };
  });
  expect(geometry.top).toBe(32);
  expect(Math.abs(geometry.centreOffset)).toBeLessThanOrEqual(1);
});

test("microphone selection is checked, keyboard-dismissible, and discard never enters saving", async ({
  page,
}) => {
  await page.goto(
    "/iframe.html?id=app-components-meeting-recorder--interactive&viewMode=story"
  );
  const card = page.getByTestId("meeting-recorder-demo");
  await card.getByRole("button", { name: "Start recording" }).click();
  await expect(card).toHaveAttribute("data-phase", "recording");
  const trigger = card.getByRole("button", { name: "Choose microphone" });
  await expect(card.locator(".comma-recorder-microphone button")).toHaveCount(1);
  // Clicking the microphone glyph opens the same menu as the chevron.
  await trigger.locator("svg").first().click();
  await expect(
    page.getByRole("menuitemradio", { name: /System default/ })
  ).toHaveAttribute("aria-checked", "true");
  await page
    .getByRole("menuitemradio", { name: "MacBook Pro Microphone", exact: true })
    .click();
  await page.mouse.move(0, 0);
  await card.hover();
  await trigger.locator("svg").last().click();
  await expect(
    page.getByRole("menuitemradio", { name: "MacBook Pro Microphone", exact: true })
  ).toHaveAttribute("aria-checked", "true");
  await page.keyboard.press("Escape");
  await expect(card).toBeFocused();
  await page.mouse.move(0, 0);
  await card.hover();
  await card.getByRole("button", { name: "Stop options" }).click();
  await page.getByRole("menuitem", { name: "Discard and stop" }).click();
  await expect(card).toHaveAttribute("data-phase", "detected");
  await expect(page.getByText("Recording saved", { exact: true })).toHaveCount(0);
});

test("recorder logos stay static and recording shares the saving shimmer", async ({
  page,
}) => {
  await page.goto(
    "/iframe.html?id=app-components-meeting-recorder--states&viewMode=story"
  );
  const cards = page.locator('[data-slot="meeting-recorder"]');
  await expect(cards).toHaveCount(9);
  await expect(cards.locator('[data-slot="meeting-recorder-static-logo"]')).toHaveCount(
    9
  );
  const animations = await cards
    .first()
    .locator('[data-slot="meeting-recorder-static-logo"]')
    .evaluate((el) => el.getAnimations({ subtree: true }).length);
  expect(animations).toBe(0);
  await expect(cards.locator(".comma-logo-animation")).toHaveCount(0);
  const recording = page
    .locator('[data-phase="recording"] [data-slot="meeting-recorder-title"]')
    .first();
  const saving = page.locator(
    '[data-phase="saving"] [data-slot="meeting-recorder-title"]'
  );
  await expect(recording).toHaveCSS("animation-name", "comma-shiny-text-shine");
  await expect(saving).toHaveCSS("animation-name", "comma-shiny-text-shine");
  await page.emulateMedia({ reducedMotion: "reduce" });
  await expect(recording).toHaveCSS("animation-name", "none");
  await expect(saving).toHaveCSS("animation-name", "none");
});

test("unhovered recording matches 227 × 42 and reverses expansion from its current size", async ({
  page,
}) => {
  await page.goto(
    "/iframe.html?id=app-components-meeting-recorder--recording-unhovered&viewMode=story"
  );
  const card = page.locator('[data-slot="meeting-recorder"]');
  const surface = card.locator(".comma-recorder-surface");
  await expect(card).toHaveAttribute("data-compact", "true");
  await expect
    .poll(async () => {
      const bounds = await card.boundingBox();
      return [bounds?.width, bounds?.height];
    })
    .toEqual([227, 42]);
  await expect(card.getByRole("timer")).toHaveText("00:26");
  const alignment = await card.evaluate((element) => {
    const bounds = element.getBoundingClientRect();
    const title = element
      .querySelector(".comma-recorder-title")!
      .getBoundingClientRect();
    const timer = element
      .querySelector(".comma-recorder-timer")!
      .getBoundingClientRect();
    return {
      title: title.top + title.height / 2,
      timer: timer.top + timer.height / 2,
      card: bounds.top + bounds.height / 2,
    };
  });
  expect(Math.abs(alignment.title - alignment.timer)).toBeLessThan(0.5);
  expect(Math.abs(alignment.title - alignment.card)).toBeLessThan(0.5);
  await expect(card.getByRole("button", { name: "Stop", exact: true })).toBeVisible();
  await expect(card.getByRole("button", { name: "Choose microphone" })).toBeHidden();
  await card.hover();
  await expect(card).not.toHaveAttribute("data-compact");
  const midway = await surface.evaluate((element) => {
    const animation = element
      .parentElement!.parentElement!.getAnimations()
      .find(
        (candidate) => (candidate as CSSTransition).transitionProperty === "width"
      )!;
    animation.pause();
    animation.currentTime = 60;
    return element.getBoundingClientRect().width;
  });
  expect(midway).toBeGreaterThan(227);
  expect(midway).toBeLessThan(370);
  await page.mouse.move(0, 0);
  await expect(card).toHaveAttribute("data-compact", "true");
  const reversed = await surface.evaluate((element) => {
    const animation = element
      .parentElement!.parentElement!.getAnimations()
      .find(
        (candidate) => (candidate as CSSTransition).transitionProperty === "width"
      )!;
    animation.pause();
    animation.currentTime = 0;
    const width = element.getBoundingClientRect().width;
    animation.finish();
    return width;
  });
  expect(Math.abs(reversed - midway)).toBeLessThan(1);
  await expect
    .poll(() => surface.evaluate((element) => element.getBoundingClientRect().width))
    .toBe(227);
});

test("menus stay expanded until Escape, then collapse with focus on the card", async ({
  page,
}) => {
  await page.goto(
    "/iframe.html?id=app-components-meeting-recorder--recording-unhovered&viewMode=story"
  );
  const card = page.locator('[data-slot="meeting-recorder"]');
  await expect(card).toHaveAttribute("data-compact", "true");
  await card.hover();
  const trigger = card.getByRole("button", { name: "Choose microphone" });
  await trigger.click();
  const menu = page.getByRole("menu", { name: "Choose microphone" });
  await menu.hover();
  await expect(card).not.toHaveAttribute("data-compact");
  await expect(menu.getByRole("separator")).toHaveCount(1);
  await page.keyboard.press("Escape");
  await expect(card).toBeFocused();
  await expect(card).toHaveAttribute("data-compact", "true");
  // Restoring focus after a menu closes must not paint Chromium's default
  // outline around the card and its temporarily overflowing controls.
  await expect(card).toHaveCSS("outline-style", "none");
  await page.keyboard.press("ArrowRight");
  await expect(card).not.toHaveAttribute("data-compact");
  await expect(card.getByRole("button", { name: "Pause recording" })).toBeVisible();
  await card.hover();
  await page.mouse.move(10, 500);
  await expect(card).toHaveAttribute("data-compact", "true");
});

test("menu selection and dismissal return directly to the compact recorder", async ({
  page,
}) => {
  await page.goto(
    "/iframe.html?id=app-components-meeting-recorder--recording-unhovered&viewMode=story"
  );
  const card = page.locator('[data-slot="meeting-recorder"]');
  await expect(card).toHaveAttribute("data-compact", "true");
  await card.hover();
  await card.getByRole("button", { name: "Choose microphone" }).click();
  await page
    .getByRole("menuitemradio", { name: "MacBook Pro Microphone", exact: true })
    .click();
  await expect(page.getByRole("menu")).toHaveCount(0);
  await expect(card).toHaveAttribute("data-compact", "true");

  await card.hover();
  await card.getByRole("button", { name: "Stop options" }).click();
  await page.getByRole("menuitem", { name: "Discard and stop" }).hover();
  await expect(card).not.toHaveAttribute("data-compact");
  await page.mouse.click(10, 500);
  await expect(page.getByRole("menu")).toHaveCount(0);
  await expect(card).toHaveAttribute("data-compact", "true");
  // Closing from the trigger also collapses, even with the pointer on the card.
  await card.hover();
  const stopMenu = card.getByRole("button", { name: "Stop options" });
  const triggerBounds = await stopMenu.boundingBox();
  await stopMenu.click();
  await page.mouse.click(
    triggerBounds!.x + triggerBounds!.width / 2,
    triggerBounds!.y + triggerBounds!.height / 2
  );
  await expect(card).toHaveAttribute("data-compact", "true");
});

test("touch devices keep recording controls expanded", async ({ browser, baseURL }) => {
  const context = await browser.newContext({
    ...(baseURL ? { baseURL } : {}),
    hasTouch: true,
    isMobile: true,
    viewport: { width: 360, height: 800 },
  });
  const page = await context.newPage();
  await page.goto(
    "/iframe.html?id=app-components-meeting-recorder--recording-unhovered&viewMode=story"
  );
  const card = page.locator('[data-slot="meeting-recorder"]');
  await expect(card.getByRole("button", { name: "Choose microphone" })).toBeVisible();
  await expect(card).not.toHaveAttribute("data-compact");
  await context.close();
});

test("hover controls fade in and out, retaining opacity through a reversal", async ({
  page,
}) => {
  await page.goto(
    "/iframe.html?id=app-components-meeting-recorder--recording-unhovered&viewMode=story"
  );
  const card = page.locator('[data-slot="meeting-recorder"]');
  const microphone = card.locator(".comma-recorder-microphone");
  // Source Storybook can still be compiling after its HTML document loads.
  // Use the existing test deadline for fixture readiness, then assert motion.
  await card.waitFor({ state: "visible" });
  await expect(card).toHaveAttribute("data-compact", "true");
  await expect(microphone).toHaveCSS("opacity", "0");
  // Hover uses CSS transitions, including a shortened transition on reversal.
  // Pause each transition at its state change before a driver round trip can miss it.
  await card.evaluate((element) => {
    const microphoneElement = element.querySelector(".comma-recorder-microphone")!;
    const observer = new MutationObserver(() => {
      const fade = microphoneElement
        .getAnimations()
        .find(
          (animation) => (animation as CSSTransition).transitionProperty === "opacity"
        );
      if (!fade) throw new Error("Recorder opacity transition did not start");
      fade.pause();
      fade.currentTime = 0;
    });
    observer.observe(element, { attributes: true, attributeFilter: ["data-compact"] });
  });
  await card.hover();
  const entering = await microphone.evaluate((element) => {
    const fade = element
      .getAnimations()
      .find(
        (animation) => (animation as CSSTransition).transitionProperty === "opacity"
      )!;
    fade.pause();
    fade.currentTime = 75;
    return Number(getComputedStyle(element).opacity);
  });
  expect(entering).toBeGreaterThan(0);
  expect(entering).toBeLessThan(1);
  await page.mouse.move(0, 0);
  await expect(card).toHaveAttribute("data-compact", "true");
  const leaving = await microphone.evaluate((element) => {
    const fade = element
      .getAnimations()
      .find(
        (animation) => (animation as CSSTransition).transitionProperty === "opacity"
      )!;
    fade.pause();
    fade.currentTime = 0;
    return {
      opacity: Number(getComputedStyle(element).opacity),
      inert: (element as HTMLElement).inert,
      hidden: element.getAttribute("aria-hidden"),
    };
  });
  expect(leaving.inert).toBe(true);
  expect(leaving.hidden).toBe("true");
  expect(Math.abs(leaving.opacity - entering)).toBeLessThan(0.01);
  await expect(page.getByRole("button", { name: "Choose microphone" })).toHaveCount(0);
  await card.hover();
  const resumed = await microphone.evaluate((element) => {
    const fade = element
      .getAnimations()
      .find(
        (animation) => (animation as CSSTransition).transitionProperty === "opacity"
      )!;
    fade.pause();
    fade.currentTime = 0;
    const opacity = Number(getComputedStyle(element).opacity);
    element.getAnimations().forEach((animation) => animation.finish());
    return opacity;
  });
  expect(Math.abs(resumed - leaving.opacity)).toBeLessThan(0.01);
  await expect(microphone).toHaveCSS("opacity", "1");
  await expect(card.getByRole("button", { name: "Choose microphone" })).toBeVisible();
  await expect(page.locator("[data-recorder-exit]")).toHaveCount(0);
});

test("hover resizes the actual card without stretching its border and obeys reduced motion", async ({
  page,
}) => {
  await page.goto(
    "/iframe.html?id=app-components-meeting-recorder--recording-unhovered&viewMode=story"
  );
  const card = page.locator('[data-slot="meeting-recorder"]');
  await expect(card).toHaveAttribute("data-compact", "true");
  await expect
    .poll(() => card.evaluate((el) => el.getBoundingClientRect().width))
    .toBe(227);
  await card.hover();
  const widths = [];
  for (const time of [30, 60, 120, 180]) {
    const frame = await card.evaluate((el, frameTime) => {
      const root = el.parentElement!;
      root.getAnimations({ subtree: true }).forEach((animation) => {
        if (animation instanceof CSSTransition) {
          animation.pause();
          animation.currentTime = frameTime;
        }
      });
      const surface = el.querySelector(".comma-recorder-surface")!;
      return {
        root: root.getBoundingClientRect().width,
        card: el.getBoundingClientRect().width,
        surface: surface.getBoundingClientRect().width,
        radius: getComputedStyle(surface).borderRadius,
        transform: getComputedStyle(surface).transform,
        duration: getComputedStyle(root).transitionDuration,
        stopHeight: el
          .querySelector(".comma-recorder-stop-main")!
          .getBoundingClientRect().height,
        labelOverflow: getComputedStyle(el.querySelector(".comma-recorder-stop-label")!)
          .overflow,
      };
    }, time);
    expect(frame.root).toBe(frame.card);
    expect(frame.card).toBe(frame.surface);
    expect(frame.transform).toBe("none");
    expect(frame.duration).toBe("0.18s, 0.18s");
    expect(frame.labelOverflow).toBe("visible");
    if (time < 180) {
      expect(frame.stopHeight).toBeGreaterThan(24);
      expect(frame.stopHeight).toBeLessThan(32);
    } else {
      expect(frame.stopHeight).toBe(32);
    }
    expect(frame.radius).toBe("16px");
    widths.push(frame.card);
  }
  expect(widths[0]).toBeGreaterThan(227);
  expect(widths[1]).toBeGreaterThan(widths[0]!);
  expect(widths[2]).toBeGreaterThan(widths[1]!);
  expect(widths[3]).toBe(370);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.mouse.move(0, 0);
  await expect
    .poll(() => card.evaluate((el) => el.getBoundingClientRect().width))
    .toBe(227);
  await card.hover();
  expect(await card.evaluate((el) => el.getBoundingClientRect().width)).toBe(370);
  expect(
    await card.evaluate(
      (el) =>
        el
          .parentElement!.getAnimations({ subtree: true })
          .filter((animation) => animation instanceof CSSTransition).length
    )
  ).toBe(0);
});

test("recorder buttons shrink toward their centre while pressed", async ({ page }) => {
  await page.goto(
    "/iframe.html?id=app-components-meeting-recorder--recording&viewMode=story"
  );
  const card = page.locator('[data-slot="meeting-recorder"]');
  for (const name of ["Pause recording", "Stop"]) {
    const button = card.getByRole("button", { name, exact: true });
    await button.hover();
    const before = (await button.boundingBox())!;
    await page.mouse.down();
    await expect
      .poll(async () => (await button.boundingBox())!.width)
      .toBeLessThan(before.width - 0.2);
    const pressed = (await button.boundingBox())!;
    expect(
      Math.abs(pressed.x + pressed.width / 2 - before.x - before.width / 2)
    ).toBeLessThan(0.1);
    expect(
      Math.abs(pressed.y + pressed.height / 2 - before.y - before.height / 2)
    ).toBeLessThan(0.1);
    await page.mouse.up();
    await expect
      .poll(async () => (await button.boundingBox())!.width)
      .toBeCloseTo(before.width, 1);
  }
});

test("placement shares desktop controls with the draggable client block and separates completion Toast", async ({
  page,
}) => {
  await page.goto(
    "/iframe.html?id=app-components-meeting-recorder--placement&viewMode=story"
  );
  const card = page.getByTestId("meeting-recorder-demo");
  const block = page.locator('[data-slot="meeting-recording-block"]');
  await expect(block).toHaveCount(0);
  await card.getByRole("button", { name: "Start recording" }).click();
  await expect(block).toBeVisible();
  expect(await block.evaluate((el) => el.getBoundingClientRect().width)).toBe(240);
  expect(await block.evaluate((el) => el.getBoundingClientRect().height)).toBe(104);
  expect((await block.boundingBox())!.x).toBe(24);
  const pauseWidth = (await block
    .getByRole("button", { name: "Pause", exact: true })
    .boundingBox())!.width;
  const stopWidth = (await block
    .getByRole("button", { name: "Stop recording" })
    .boundingBox())!.width;
  await block.getByRole("button", { name: "Pause", exact: true }).click();
  await expect(card).toHaveAttribute("data-phase", "paused");
  await expect
    .poll(
      async () =>
        (await block
          .getByRole("button", { name: "Resume", exact: true })
          .boundingBox())!.width
    )
    .toBeCloseTo(pauseWidth, 1);
  await expect
    .poll(
      async () =>
        (await block.getByRole("button", { name: "Stop recording" }).boundingBox())!
          .width
    )
    .toBeCloseTo(stopWidth, 1);
  expect(
    await block.evaluate((element) => {
      const bounds = element.getBoundingClientRect();
      return Array.from(element.querySelectorAll("button")).every((button) => {
        const rect = button.getBoundingClientRect();
        return (
          rect.left >= bounds.left + 8 &&
          rect.right <= bounds.right - 8 &&
          Array.from(button.children).every((child) => {
            const content = child.getBoundingClientRect();
            return content.left >= rect.left && content.right <= rect.right;
          })
        );
      });
    })
  ).toBe(true);
  await card.getByRole("button", { name: "Resume recording" }).click();
  await expect(block).not.toHaveAttribute("data-paused");
  await block.locator("[data-recorder-drag-handle]").hover();
  await page.mouse.down();
  await page.mouse.move(1, 1, { steps: 10 });
  await page.mouse.up();
  await expect.poll(async () => Math.round((await block.boundingBox())!.x)).toBe(8);
  await expect.poll(async () => Math.round((await block.boundingBox())!.y)).toBe(8);
  await block.getByRole("button", { name: "Stop recording" }).click();
  await expect(card).toHaveAttribute("data-phase", "saving");
  await expect(block).toHaveCount(0);
  await expect(card).toHaveCount(0);
  const saved = page.getByTestId("meeting-recording-saved-preview");
  await expect(saved).toBeVisible();
  const toastBox = (await saved.boundingBox())!;
  expect(toastBox.x).toBeGreaterThan(page.viewportSize()!.width / 2);
  expect(toastBox.y).toBeGreaterThan(page.viewportSize()!.height / 2);
});

test("desktop hover keeps the recorder centered before and after dragging", async ({
  page,
}) => {
  await page.goto(
    "/iframe.html?id=app-components-meeting-recorder--placement&viewMode=story"
  );
  const card = page.getByTestId("meeting-recorder-demo");
  await page.getByRole("button", { name: "Join meeting after launch" }).click();
  const center = async () => {
    const bounds = (await card.boundingBox())!;
    return { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 };
  };
  const verifyHoverCenter = async () => {
    await page.mouse.move(0, 0);
    await expect.poll(async () => (await card.boundingBox())!.width).toBe(227);
    const before = await center();
    await card.hover();
    await expect.poll(async () => (await card.boundingBox())!.width).toBe(370);
    await expect
      .poll(async () => Math.abs((await center()).x - before.x))
      .toBeLessThan(1);
    await expect
      .poll(async () => Math.abs((await center()).y - before.y))
      .toBeLessThan(1);
    await page.mouse.move(0, 0);
    await expect.poll(async () => (await card.boundingBox())!.width).toBe(227);
    expect(Math.abs((await center()).x - before.x)).toBeLessThan(1);
    expect(Math.abs((await center()).y - before.y)).toBeLessThan(1);
  };
  await verifyHoverCenter();
  await card.locator(".comma-recorder-copy").hover();
  await expect.poll(async () => (await card.boundingBox())!.width).toBe(370);
  await page.mouse.down();
  await page.mouse.move(500, 300, { steps: 10 });
  await page.mouse.up();
  await verifyHoverCenter();
});

test("client pause and resume resize the desktop recorder along the same path as hover", async ({
  page,
}) => {
  await page.goto(
    "/iframe.html?id=app-components-meeting-recorder--placement&viewMode=story"
  );
  const card = page.getByTestId("meeting-recorder-demo");
  const block = page.locator('[data-slot="meeting-recording-block"]');
  await page.getByRole("button", { name: "Join meeting after launch" }).click();
  await expect(card).toHaveAttribute("data-compact", "true");
  await expect.poll(async () => (await card.boundingBox())!.width).toBe(227);
  await card.evaluate(async (element) => {
    const root = element.parentElement!;
    await Promise.all(
      root
        .getAnimations({ subtree: true })
        .filter((animation) => animation.effect?.getTiming().iterations !== Infinity)
        .map((animation) => animation.finished.catch(() => undefined))
    );
    const samples: number[][][] = [];
    Object.assign(window, { recorderLiveResizeSamples: samples });
    new MutationObserver(() => {
      // Freeze and sample the actual visible geometry at identical points in
      // each transition. The old phase FLIP finished the child CSS transitions
      // early and then translated them from a different origin than hover.
      const animations = root
        .getAnimations({ subtree: true })
        .filter((animation) => animation.effect?.getTiming().iterations !== Infinity);
      animations.forEach((animation) => animation.pause());
      const nodes = [
        element,
        ...["logo", "timer", "stop-icon"].map(
          (slot) => element.querySelector(`[data-recorder-motion="${slot}"]`)!
        ),
      ];
      samples.push(
        [0, 90, 180].map((time) => {
          animations.forEach((animation) => {
            animation.currentTime = time;
          });
          return nodes.flatMap((node) => {
            const { x, y, width, height } = node.getBoundingClientRect();
            return [x, y, width, height];
          });
        })
      );
      animations.forEach((animation) => animation.finish());
    }).observe(element, { attributes: true, attributeFilter: ["data-compact"] });
  });
  await card.hover();
  await expect(card).not.toHaveAttribute("data-compact");
  await page.mouse.move(0, 0);
  await expect(card).toHaveAttribute("data-compact", "true");
  await block.getByRole("button", { name: "Pause", exact: true }).click();
  await expect(card).toHaveAttribute("data-phase", "paused");
  await block.getByRole("button", { name: "Resume", exact: true }).click();
  await expect(card).toHaveAttribute("data-compact", "true");
  const samples = await page.evaluate(
    () =>
      (window as unknown as { recorderLiveResizeSamples: number[][][] })
        .recorderLiveResizeSamples
  );
  expect(samples).toHaveLength(4);
  for (const [hover, external] of [
    [0, 2],
    [1, 3],
  ]) {
    samples[hover!]!.forEach((frame, index) =>
      frame.forEach((value, coordinate) => {
        expect(samples[external!]![index]![coordinate]).toBeCloseTo(value, 0);
      })
    );
  }
});
