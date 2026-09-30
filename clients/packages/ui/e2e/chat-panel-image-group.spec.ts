import { expect, test, type Page } from "@playwright/test";

const stackStoryUrl =
  "/iframe.html?id=app-components-chat-panel-image-group--five-images-stack&viewMode=story";
const delayedSecondImageStoryUrl =
  "/iframe.html?id=app-components-chat-panel-image-group--delayed-second-image&viewMode=story";
const twoImagesStoryUrl =
  "/iframe.html?id=app-components-chat-panel-image-group--two-images&viewMode=story";

const openStack = async (page: Page) => {
  await page.goto(stackStoryUrl, { waitUntil: "domcontentloaded" });
  const toggle = page.getByRole("button", { name: "5 Images" });
  await expect(toggle).toBeVisible({ timeout: 20_000 });
};

const activeFrontAlt = (page: Page) =>
  page
    .locator('.chat-panel-image-group-card[data-stack-pos="0"] img')
    .getAttribute("alt");

const expectForcedColorsFocus = async (selector: string, page: Page) => {
  await page.keyboard.press("Tab");
  const control = page.locator(selector);
  await expect(control).toBeFocused();
  const focusStyle = await control.evaluate((element) => {
    const style = getComputedStyle(element);
    return {
      outlineStyle: style.outlineStyle,
      outlineWidth: Number.parseFloat(style.outlineWidth),
    };
  });
  expect(focusStyle.outlineStyle).not.toBe("none");
  expect(focusStyle.outlineWidth).toBeGreaterThan(0);
};

test("rapid direction reversal keeps the current front free of a stale flight", async ({
  page,
}) => {
  await openStack(page);

  const next = page.getByRole("button", { name: "Show next image" });
  const previous = page.getByRole("button", { name: "Show previous image" });
  const originalFront = await page
    .locator('.chat-panel-image-group-card[data-stack-pos="0"]')
    .elementHandle();
  expect(originalFront).not.toBeNull();
  await next.evaluate((button) => (button as HTMLButtonElement).click());
  await expect.poll(() => originalFront?.getAttribute("data-flying")).toBe("true");
  await previous.evaluate((button) => (button as HTMLButtonElement).click());

  // Read synchronously after React's click/layout-effect work. Polling here
  // would let the old 320 ms flight finish and hide the race this protects.
  const reversedFront = await originalFront?.evaluate((element) => ({
    alt: element.querySelector("img")?.getAttribute("alt"),
    flying: element.dataset.flying === "true",
    runningWaapi: element
      .getAnimations()
      .some(
        (animation) =>
          !(animation instanceof CSSTransition) &&
          !(animation instanceof CSSAnimation) &&
          animation.playState === "running"
      ),
    stackPosition: element.dataset.stackPos,
  }));
  expect(reversedFront).toEqual({
    alt: "Generated editorial poster",
    flying: false,
    runningWaapi: false,
    stackPosition: "0",
  });

  expect(
    await originalFront?.evaluate((element) => {
      const frontBounds = element.getBoundingClientRect();
      const deckBounds = element.parentElement?.getBoundingClientRect();
      return (
        deckBounds != null &&
        frontBounds.left >= deckBounds.left &&
        frontBounds.right <= deckBounds.right
      );
    })
  ).toBe(true);

  await expect
    .poll(() =>
      page.locator('.chat-panel-image-group-card[data-flying="true"]').count()
    )
    .toBe(0);
  expect(await originalFront?.evaluate((element) => element.style.zIndex)).toBe("");
});

test("rotate then expand and collapse interrupts the prior card flight", async ({
  page,
}) => {
  await openStack(page);

  const next = page.getByRole("button", { name: "Show next image" });
  const outgoing = await page
    .locator('.chat-panel-image-group-card[data-stack-pos="0"]')
    .elementHandle();
  expect(outgoing).not.toBeNull();
  await next.evaluate((button) => (button as HTMLButtonElement).click());
  await expect.poll(() => outgoing?.getAttribute("data-flying")).toBe("true");
  await page
    .locator('.chat-panel-image-group-toggle[aria-expanded="false"]')
    .evaluate((button) => (button as HTMLButtonElement).click());

  const toggle = page.locator(".chat-panel-image-group-toggle");
  const expandedFlightState = await page
    .locator(".chat-panel-image-group")
    .evaluate((group) => ({
      expanded: group
        .querySelector(".chat-panel-image-group-toggle")
        ?.getAttribute("aria-expanded"),
      flyingCards: group.querySelectorAll(
        '.chat-panel-image-group-card[data-flying="true"]'
      ).length,
      runningWaapi: Array.from(
        group.querySelectorAll<HTMLElement>(".chat-panel-image-group-card")
      ).some((card) =>
        card
          .getAnimations()
          .some(
            (animation) =>
              !(animation instanceof CSSTransition) &&
              !(animation instanceof CSSAnimation) &&
              animation.playState === "running"
          )
      ),
    }));
  expect(expandedFlightState).toEqual({
    expanded: "true",
    flyingCards: 0,
    runningWaapi: false,
  });
  await expect
    .poll(() =>
      page.locator(".chat-panel-image-group-card").evaluateAll((cards) =>
        cards.every((card) => {
          const bounds = card.getBoundingClientRect();
          const deckBounds = card.parentElement?.getBoundingClientRect();
          return (
            deckBounds != null &&
            bounds.left >= deckBounds.left &&
            bounds.right <= deckBounds.right
          );
        })
      )
    )
    .toBe(true);

  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-expanded", "false");
  await expect(
    page.locator('.chat-panel-image-group-card[data-flying="true"]')
  ).toHaveCount(0);

  await expect(
    page.locator('.chat-panel-image-group-card[data-stack-pos="0"] img')
  ).toHaveAttribute("alt", "Harbor sample photo");
  await expect
    .poll(() =>
      page.locator(".chat-panel-image-group").evaluate((group) => {
        const wrapper = group.querySelector<HTMLElement>(
          ".chat-panel-image-group-cards"
        );
        const cards = Array.from(
          group.querySelectorAll<HTMLElement>(".chat-panel-image-group-card")
        );
        return {
          heightAnimating: wrapper?.dataset.heightAnimating === "true",
          inlineHeight: wrapper?.style.height ?? "",
          transientCards: cards.filter(
            (card) =>
              card.dataset.flip === "true" ||
              card.dataset.flying === "true" ||
              Boolean(
                card.style.transform ||
                card.style.opacity ||
                card.style.zIndex ||
                card.style.transitionDelay
              )
          ).length,
        };
      })
    )
    .toEqual({ heightAnimating: false, inlineHeight: "", transientCards: 0 });
});

test("cyclic browsing stays stable across a complete traversal", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await openStack(page);

  const next = page.getByRole("button", { name: "Show next image" });
  for (const expectedAlt of [
    "Harbor sample photo",
    "Forest sample photo",
    "Desert sample photo",
    "Night sample photo",
    "Generated editorial poster",
    "Harbor sample photo",
  ]) {
    await next.evaluate((button) => (button as HTMLButtonElement).click());
    await expect.poll(() => activeFrontAlt(page)).toBe(expectedAlt);
  }

  await expect(
    page.locator('.chat-panel-image-group-card[data-stack-pos="0"]')
  ).toHaveCount(1);
  await expect(page.locator(".chat-panel-image-group-card:not([inert])")).toHaveCount(
    1
  );
  await expect(
    page.locator('.chat-panel-image-group-card[data-flying="true"]')
  ).toHaveCount(0);
});

test("preview navigation moves one connected filmstrip and aligns the stack", async ({
  page,
}) => {
  await openStack(page);
  await page.locator('.chat-panel-image-group-card[data-stack-pos="0"]').click();

  const dialog = page.getByRole("dialog", { name: "Preview image" });
  const filmstrip = dialog.locator(".chat-panel-image-filmstrip");
  await expect(filmstrip).toHaveAttribute("data-ready", "true");
  await expect(
    dialog.getByRole("button", { name: "Show previous image" })
  ).toHaveAttribute("aria-disabled", "true");

  await dialog
    .getByRole("button", { name: "Show next image" })
    .evaluate((button) => (button as HTMLButtonElement).click());

  await expect(filmstrip).toHaveAttribute("data-active-index", "1");
  await expect(
    page.locator('.chat-panel-image-group-card[data-stack-pos="0"] img')
  ).toHaveAttribute("alt", "Harbor sample photo");

  const motion = await filmstrip.evaluate((stage) => {
    const clip = stage.querySelector<HTMLElement>('[data-filmstrip-layer="clip"]');
    const strip = stage.querySelector<HTMLElement>('[data-filmstrip-layer="strip"]');
    const clipAnimation = clip
      ?.getAnimations()
      .find((animation) =>
        (animation.effect as KeyframeEffect | null)
          ?.getKeyframes()
          .some((frame) => Object.hasOwn(frame, "clipPath"))
      );
    const stripAnimation = strip
      ?.getAnimations()
      .find((animation) =>
        (animation.effect as KeyframeEffect | null)
          ?.getKeyframes()
          .some((frame) => Object.hasOwn(frame, "transform"))
      );
    const clipTiming = (clipAnimation?.effect as KeyframeEffect | null)?.getTiming();
    const stripTiming = (stripAnimation?.effect as KeyframeEffect | null)?.getTiming();
    return {
      clipDuration: clipTiming?.duration,
      clipEasing: clipTiming?.easing,
      mode: (stage as HTMLElement).dataset.motion,
      stripDuration: stripTiming?.duration,
      stripEasing: stripTiming?.easing,
    };
  });
  expect(motion).toEqual({
    clipDuration: 400,
    clipEasing: "cubic-bezier(0.5, 0, 0, 1)",
    mode: "spatial",
    stripDuration: 400,
    stripEasing: "cubic-bezier(0.5, 0, 0, 1)",
  });

  await expect.poll(() => filmstrip.getAttribute("data-motion")).toBeNull();
  await expect(
    filmstrip.locator('.chat-panel-image-filmstrip-slide:not([aria-hidden="true"])')
  ).toHaveAttribute("alt", "Harbor sample photo");
  expect(
    await filmstrip.evaluate((stage) =>
      Array.from(
        stage.querySelectorAll<HTMLElement>(
          '[data-filmstrip-layer="clip"], [data-filmstrip-layer="strip"]'
        )
      ).reduce((total, layer) => total + layer.getAnimations().length, 0)
    )
  ).toBe(0);
});

test("a delayed neighbouring image does not block the current preview", async ({
  page,
}) => {
  let releaseDelayedImage!: () => void;
  let markDelayedRequestSeen!: () => void;
  const delayedImageGate = new Promise<void>((resolve) => {
    releaseDelayedImage = resolve;
  });
  const delayedRequestSeen = new Promise<void>((resolve) => {
    markDelayedRequestSeen = resolve;
  });
  await page.route("**/*filmstrip-delay*", async (route) => {
    markDelayedRequestSeen();
    await delayedImageGate;
    await route.fulfill({
      body: `<svg xmlns="http://www.w3.org/2000/svg" width="800" height="500"><rect width="800" height="500" fill="#3d4460"/></svg>`,
      contentType: "image/svg+xml",
    });
  });

  await page.goto(delayedSecondImageStoryUrl, { waitUntil: "domcontentloaded" });
  await delayedRequestSeen;
  const cards = page.locator(".chat-panel-image-group-card");
  await expect(cards).toHaveCount(3);
  await cards.first().click();

  const dialog = page.getByRole("dialog", { name: "Preview image" });
  const filmstrip = dialog.locator(".chat-panel-image-filmstrip");
  const frame = filmstrip.locator('[data-filmstrip-layer="clip"]');
  try {
    await expect(filmstrip).toHaveAttribute("data-ready", "true");
    await expect(frame).toHaveCSS("opacity", "1");
    await expect(
      filmstrip.locator('.chat-panel-image-filmstrip-slide:not([aria-hidden="true"])')
    ).toHaveAttribute("alt", "Ready sample photo");
    await expect(
      filmstrip.locator('.chat-panel-image-filmstrip-slide[alt="Ready sample photo"]')
    ).toHaveJSProperty("complete", true);
    await expect(
      filmstrip.locator('.chat-panel-image-filmstrip-slide[alt="Delayed sample photo"]')
    ).toHaveJSProperty("complete", false);
  } finally {
    releaseDelayedImage();
  }
  const delayedSlide = filmstrip.locator(
    '.chat-panel-image-filmstrip-slide[alt="Delayed sample photo"]'
  );
  await expect
    .poll(() =>
      delayedSlide.evaluate((image) => (image as HTMLImageElement).naturalWidth)
    )
    .toBeGreaterThan(0);
  const next = dialog.getByRole("button", { name: "Show next image" });
  await next.click();
  await expect(filmstrip).toHaveAttribute("data-active-index", "1");
  await expect.poll(() => filmstrip.getAttribute("data-motion")).toBeNull();
  await expect(
    filmstrip.locator('.chat-panel-image-filmstrip-slide:not([aria-hidden="true"])')
  ).toHaveAttribute("alt", "Loaded sample photo");
  await next.click();
  await expect(filmstrip).toHaveAttribute("data-active-index", "2");
  await expect.poll(() => filmstrip.getAttribute("data-motion")).toBeNull();
  await expect(
    filmstrip.locator('.chat-panel-image-filmstrip-slide:not([aria-hidden="true"])')
  ).toHaveAttribute("alt", "Delayed sample photo");
});

test("a neighbouring image finishing does not interrupt active filmstrip motion", async ({
  page,
}) => {
  let releaseDelayedImage!: () => void;
  let markDelayedRequestSeen!: () => void;
  const delayedImageGate = new Promise<void>((resolve) => {
    releaseDelayedImage = resolve;
  });
  const delayedRequestSeen = new Promise<void>((resolve) => {
    markDelayedRequestSeen = resolve;
  });
  await page.route("**/*filmstrip-delay*", async (route) => {
    markDelayedRequestSeen();
    await delayedImageGate;
    await route.fulfill({
      body: `<svg xmlns="http://www.w3.org/2000/svg" width="800" height="500"><rect width="800" height="500" fill="#3d4460"/></svg>`,
      contentType: "image/svg+xml",
    });
  });

  await page.goto(delayedSecondImageStoryUrl, { waitUntil: "domcontentloaded" });
  await delayedRequestSeen;
  await page.locator(".chat-panel-image-group-card").first().click();

  const dialog = page.getByRole("dialog", { name: "Preview image" });
  const filmstrip = dialog.locator(".chat-panel-image-filmstrip");
  await expect(filmstrip).toHaveAttribute("data-ready", "true");
  await dialog
    .getByRole("button", { name: "Show next image" })
    .evaluate((button) => (button as HTMLButtonElement).click());

  let interruptedPose!: { clipPath: string; transform: string };
  try {
    interruptedPose = await filmstrip.evaluate(async (stage) => {
      const frame = stage.querySelector<HTMLElement>('[data-filmstrip-layer="clip"]');
      const strip = stage.querySelector<HTMLElement>('[data-filmstrip-layer="strip"]');
      const animations = [
        frame
          ?.getAnimations()
          .find((animation) =>
            (animation.effect as KeyframeEffect | null)
              ?.getKeyframes()
              .some((keyframe) => Object.hasOwn(keyframe, "clipPath"))
          ),
        strip
          ?.getAnimations()
          .find((animation) =>
            (animation.effect as KeyframeEffect | null)
              ?.getKeyframes()
              .some((keyframe) => Object.hasOwn(keyframe, "transform"))
          ),
      ];
      if (!frame || !strip || animations.some((animation) => !animation)) {
        throw new Error("Expected both connected filmstrip animations.");
      }
      for (const animation of animations) {
        animation!.pause();
        const duration = Number(
          (animation!.effect as KeyframeEffect | null)?.getTiming().duration
        );
        animation!.currentTime = duration / 4;
      }
      await new Promise<void>((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
      );
      return {
        clipPath: getComputedStyle(frame).clipPath,
        transform: getComputedStyle(strip).transform,
      };
    });
  } finally {
    releaseDelayedImage();
  }

  const delayedSlide = filmstrip.locator(
    '.chat-panel-image-filmstrip-slide[alt="Delayed sample photo"]'
  );
  await expect
    .poll(() =>
      delayedSlide.evaluate((image) => (image as HTMLImageElement).naturalWidth)
    )
    .toBeGreaterThan(0);
  expect(
    await filmstrip.evaluate((stage) => {
      const frame = stage.querySelector<HTMLElement>('[data-filmstrip-layer="clip"]');
      const strip = stage.querySelector<HTMLElement>('[data-filmstrip-layer="strip"]');
      const connectedAnimations = [
        ...(frame?.getAnimations() ?? []),
        ...(strip?.getAnimations() ?? []),
      ].filter((animation) =>
        (animation.effect as KeyframeEffect | null)
          ?.getKeyframes()
          .some(
            (keyframe) =>
              Object.hasOwn(keyframe, "clipPath") ||
              Object.hasOwn(keyframe, "transform")
          )
      );
      return {
        animationCount: connectedAnimations.length,
        clipPath: frame ? getComputedStyle(frame).clipPath : "",
        motion: (stage as HTMLElement).dataset.motion,
        transform: strip ? getComputedStyle(strip).transform : "",
      };
    })
  ).toEqual({
    animationCount: 2,
    ...interruptedPose,
    motion: "spatial",
  });

  await filmstrip.evaluate((stage) => {
    for (const layer of stage.querySelectorAll<HTMLElement>(
      '[data-filmstrip-layer="clip"], [data-filmstrip-layer="strip"]'
    )) {
      for (const animation of layer.getAnimations()) {
        if (
          (animation.effect as KeyframeEffect | null)
            ?.getKeyframes()
            .some(
              (keyframe) =>
                Object.hasOwn(keyframe, "clipPath") ||
                Object.hasOwn(keyframe, "transform")
            )
        ) {
          animation.finish();
        }
      }
    }
  });
  await expect.poll(() => filmstrip.getAttribute("data-motion")).toBeNull();
  await expect(filmstrip).toHaveAttribute("data-active-index", "1");
  await expect(
    filmstrip.locator('.chat-panel-image-filmstrip-slide:not([aria-hidden="true"])')
  ).toHaveAttribute("alt", "Loaded sample photo");
});

test("preview chrome has no indicator and uses white controls with black icons", async ({
  page,
}) => {
  await openStack(page);
  await page.locator('.chat-panel-image-group-card[data-stack-pos="0"]').click();

  const dialog = page.getByRole("dialog", { name: "Preview image" });
  const filmstrip = dialog.locator(".chat-panel-image-filmstrip");
  await expect(filmstrip).toHaveAttribute("data-ready", "true");
  await expect(dialog.locator(".chat-panel-image-filmstrip-counter")).toHaveCount(0);

  await dialog
    .getByRole("button", { name: "Show next image" })
    .evaluate((button) => (button as HTMLButtonElement).click());
  await expect.poll(() => filmstrip.getAttribute("data-motion")).toBeNull();

  const controls = dialog.locator(
    ".chat-panel-media-preview-action, .chat-panel-media-preview-close, .chat-panel-image-filmstrip-navigation:not([aria-disabled='true'])"
  );
  await expect(controls).toHaveCount(4);
  expect(
    await controls.evaluateAll((elements) =>
      elements.map((element) => {
        const style = getComputedStyle(element);
        return {
          background: style.backgroundColor,
          color: style.color,
        };
      })
    )
  ).toEqual([
    { background: "rgb(255, 255, 255)", color: "rgb(0, 0, 0)" },
    { background: "rgb(255, 255, 255)", color: "rgb(0, 0, 0)" },
    { background: "rgb(255, 255, 255)", color: "rgb(0, 0, 0)" },
    { background: "rgb(255, 255, 255)", color: "rgb(0, 0, 0)" },
  ]);

  const expectedControlMetrics = await page.evaluate(() => {
    const rootStyle = getComputedStyle(document.documentElement);
    return {
      controlSize: rootStyle.getPropertyValue("--spacing-5xl").trim(),
      iconSize: rootStyle.getPropertyValue("--spacing-2xl").trim(),
      padding: rootStyle.getPropertyValue("--spacing-none").trim(),
    };
  });
  const controlMetrics = await controls.evaluateAll((elements) =>
    elements.map((element) => {
      const icon = element.querySelector<SVGElement>("[data-comma-icon]");
      if (!icon) throw new Error("Expected a Central Icon in every preview control.");
      const controlStyle = getComputedStyle(element);
      const iconStyle = getComputedStyle(icon);
      return {
        height: controlStyle.height,
        iconHeight: iconStyle.height,
        iconWidth: iconStyle.width,
        padding: controlStyle.padding,
        width: controlStyle.width,
      };
    })
  );
  for (const metrics of controlMetrics) {
    expect(metrics).toEqual({
      height: expectedControlMetrics.controlSize,
      iconHeight: expectedControlMetrics.iconSize,
      iconWidth: expectedControlMetrics.iconSize,
      padding: expectedControlMetrics.padding,
      width: expectedControlMetrics.controlSize,
    });
  }

  const downloadButton = dialog.getByRole("button", { name: "Download image" });
  const restingShadow = await downloadButton.evaluate(
    (button) => getComputedStyle(button).boxShadow
  );
  await page.keyboard.press("Tab");
  await expect(downloadButton).toBeFocused();
  expect(
    await downloadButton.evaluate((button) => getComputedStyle(button).boxShadow)
  ).not.toBe(restingShadow);

  await filmstrip
    .locator('.chat-panel-image-filmstrip-slide:not([aria-hidden="true"])')
    .click();
  await expect(dialog).toBeVisible();
  await page
    .locator('.chat-panel-media-preview-modal[data-variant="filmstrip"]')
    .click({ position: { x: 8, y: 8 } });
  await expect(dialog).toBeHidden();
});

test("preview download saves the currently active image", async ({ page }) => {
  await openStack(page);
  await page.locator('.chat-panel-image-group-card[data-stack-pos="0"]').click();

  const dialog = page.getByRole("dialog", { name: "Preview image" });
  const filmstrip = dialog.locator(".chat-panel-image-filmstrip");
  await expect(filmstrip).toHaveAttribute("data-ready", "true");
  await dialog
    .getByRole("button", { name: "Show next image" })
    .evaluate((button) => (button as HTMLButtonElement).click());
  await expect.poll(() => filmstrip.getAttribute("data-motion")).toBeNull();
  await expect(
    filmstrip.locator('.chat-panel-image-filmstrip-slide:not([aria-hidden="true"])')
  ).toHaveAttribute("alt", "Harbor sample photo");

  const downloadPromise = page.waitForEvent("download");
  await dialog.getByRole("button", { name: "Download image" }).click();
  const download = await downloadPromise;
  expect(download.suggestedFilename()).toBe("harbor-sample-photo.svg");
});

test("rapid preview navigation retargets from the visible pose", async ({ page }) => {
  await openStack(page);
  await page.locator('.chat-panel-image-group-card[data-stack-pos="0"]').click();

  const dialog = page.getByRole("dialog", { name: "Preview image" });
  const filmstrip = dialog.locator(".chat-panel-image-filmstrip");
  const next = dialog.getByRole("button", { name: "Show next image" });
  await expect(filmstrip).toHaveAttribute("data-ready", "true");

  await next.evaluate((button) => (button as HTMLButtonElement).click());
  await filmstrip.locator('[data-filmstrip-layer="clip"]').evaluate(async (clip) => {
    const animation = clip
      .getAnimations()
      .find((candidate) =>
        (candidate.effect as KeyframeEffect | null)
          ?.getKeyframes()
          .some((frame) => Object.hasOwn(frame, "clipPath"))
      );
    if (!animation) throw new Error("Expected an active clip-path animation.");
    animation.pause();
    const duration = Number(
      (animation.effect as KeyframeEffect | null)?.getTiming().duration
    );
    animation.currentTime = duration / 4;
    await new Promise<void>((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
    );
  });
  await next.evaluate((button) => (button as HTMLButtonElement).click());

  const retargetTiming = await filmstrip
    .locator('[data-filmstrip-layer="clip"]')
    .evaluate((clip) => {
      const animation = clip
        .getAnimations()
        .find((candidate) =>
          (candidate.effect as KeyframeEffect | null)
            ?.getKeyframes()
            .some((frame) => Object.hasOwn(frame, "clipPath"))
        );
      return (animation?.effect as KeyframeEffect | null)?.getTiming();
    });
  expect(retargetTiming?.duration).toBe(400);
  expect(retargetTiming?.easing).toBe("cubic-bezier(0.05, 0.7, 0.1, 1)");

  await expect(filmstrip).toHaveAttribute("data-active-index", "2");
  await expect(
    page.locator('.chat-panel-image-group-card[data-stack-pos="0"] img')
  ).toHaveAttribute("alt", "Forest sample photo");
  await expect.poll(() => filmstrip.getAttribute("data-motion")).toBeNull();
});

test("the last two preview slides overlap only while moving in either direction", async ({
  page,
}) => {
  await openStack(page);
  await page.locator('.chat-panel-image-group-card[data-stack-pos="0"]').click();

  const dialog = page.getByRole("dialog", { name: "Preview image" });
  const filmstrip = dialog.locator(".chat-panel-image-filmstrip");
  const next = dialog.getByRole("button", { name: "Show next image" });
  await expect(filmstrip).toHaveAttribute("data-ready", "true");

  for (let index = 1; index < 4; index += 1) {
    await next.evaluate((button) => (button as HTMLButtonElement).click());
    await expect.poll(() => filmstrip.getAttribute("data-motion")).toBeNull();
  }

  const sampleMidpointAndFinish = async () => {
    await expect
      .poll(() =>
        filmstrip.evaluate((stage) =>
          Array.from(
            stage.querySelectorAll<HTMLElement>(
              '[data-filmstrip-layer="clip"], [data-filmstrip-layer="strip"]'
            )
          ).reduce((total, layer) => total + layer.getAnimations().length, 0)
        )
      )
      .toBe(2);

    return filmstrip.evaluate(async (stage) => {
      const frame = stage.querySelector<HTMLElement>('[data-filmstrip-layer="clip"]');
      const strip = stage.querySelector<HTMLElement>('[data-filmstrip-layer="strip"]');
      const animations = [
        frame
          ?.getAnimations()
          .find((animation) =>
            (animation.effect as KeyframeEffect | null)
              ?.getKeyframes()
              .some((keyframe) => Object.hasOwn(keyframe, "clipPath"))
          ),
        strip
          ?.getAnimations()
          .find((animation) =>
            (animation.effect as KeyframeEffect | null)
              ?.getKeyframes()
              .some((keyframe) => Object.hasOwn(keyframe, "transform"))
          ),
      ].filter((animation): animation is Animation => animation !== undefined);

      for (const animation of animations) {
        animation.pause();
        const duration = Number(
          (animation.effect as KeyframeEffect | null)?.getTiming().duration
        );
        animation.currentTime = duration / 2;
      }
      await new Promise<void>((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
      );

      const slides = Array.from(
        stage.querySelectorAll<HTMLElement>(".chat-panel-image-filmstrip-slide")
      );
      const previous = slides.at(-2)?.getBoundingClientRect();
      const last = slides.at(-1)?.getBoundingClientRect();
      const result = {
        motion: (stage as HTMLElement).dataset.motion,
        overlap: previous && last ? previous.right - last.left : null,
        seamOverlap: (stage as HTMLElement).dataset.seamOverlap,
      };
      for (const animation of animations) animation.finish();
      return result;
    });
  };

  const expectSettledLogicalSeam = async () => {
    await expect.poll(() => filmstrip.getAttribute("data-motion")).toBeNull();
    const settled = await filmstrip.evaluate((stage) => {
      const slides = Array.from(
        stage.querySelectorAll<HTMLElement>(".chat-panel-image-filmstrip-slide")
      );
      const previous = slides.at(-2)?.getBoundingClientRect();
      const last = slides.at(-1)?.getBoundingClientRect();
      return {
        overlap: previous && last ? previous.right - last.left : null,
        seamOverlap: (stage as HTMLElement).dataset.seamOverlap,
      };
    });
    expect(settled).toEqual({ overlap: 0, seamOverlap: undefined });
  };

  await next.evaluate((button) => (button as HTMLButtonElement).click());
  expect(await sampleMidpointAndFinish()).toEqual({
    motion: "spatial",
    overlap: 1,
    seamOverlap: "true",
  });
  await expectSettledLogicalSeam();

  await dialog
    .getByRole("button", { name: "Show previous image" })
    .evaluate((button) => (button as HTMLButtonElement).click());
  expect(await sampleMidpointAndFinish()).toEqual({
    motion: "spatial",
    overlap: 1,
    seamOverlap: "true",
  });
  await expectSettledLogicalSeam();
});

test("reduced motion fades through without translating the strip", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await openStack(page);
  await page.locator('.chat-panel-image-group-card[data-stack-pos="0"]').click();

  const dialog = page.getByRole("dialog", { name: "Preview image" });
  const filmstrip = dialog.locator(".chat-panel-image-filmstrip");
  await expect(filmstrip).toHaveAttribute("data-ready", "true");
  await dialog
    .getByRole("button", { name: "Show next image" })
    .evaluate((button) => (button as HTMLButtonElement).click());

  const reducedMotion = await filmstrip.evaluate(
    (stage) =>
      new Promise<{
        frameAnimations: number;
        mode: string | undefined;
        stripAnimations: number;
      }>((resolve) => {
        requestAnimationFrame(() => {
          const frame = stage.querySelector<HTMLElement>(
            '[data-filmstrip-layer="clip"]'
          );
          const strip = stage.querySelector<HTMLElement>(
            '[data-filmstrip-layer="strip"]'
          );
          resolve({
            frameAnimations: frame?.getAnimations().length ?? 0,
            mode: (stage as HTMLElement).dataset.motion,
            stripAnimations: strip?.getAnimations().length ?? 0,
          });
        });
      })
  );
  expect(reducedMotion.mode).toBe("fade");
  expect(reducedMotion.frameAnimations).toBeGreaterThan(0);
  expect(reducedMotion.stripAnimations).toBe(0);

  await expect(filmstrip).toHaveAttribute("data-active-index", "1");
  await expect(
    page.locator('.chat-panel-image-group-card[data-stack-pos="0"] img')
  ).toHaveAttribute("alt", "Harbor sample photo");
  await expect.poll(() => filmstrip.getAttribute("data-motion")).toBeNull();
  expect(
    await filmstrip.evaluate((stage) => {
      const frame = stage.querySelector<HTMLElement>('[data-filmstrip-layer="clip"]');
      const strip = stage.querySelector<HTMLElement>('[data-filmstrip-layer="strip"]');
      return {
        frameAnimations: frame?.getAnimations().length ?? 0,
        opacity: frame ? getComputedStyle(frame).opacity : null,
        stripAnimations: strip?.getAnimations().length ?? 0,
      };
    })
  ).toEqual({ frameAnimations: 0, opacity: "1", stripAnimations: 0 });
});

test("reduced motion retargets from the visible fade opacity", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await openStack(page);
  await page.locator('.chat-panel-image-group-card[data-stack-pos="0"]').click();

  const dialog = page.getByRole("dialog", { name: "Preview image" });
  const filmstrip = dialog.locator(".chat-panel-image-filmstrip");
  const frame = filmstrip.locator('[data-filmstrip-layer="clip"]');
  const next = dialog.getByRole("button", { name: "Show next image" });
  await expect(filmstrip).toHaveAttribute("data-ready", "true");
  await expect(frame).toHaveCSS("opacity", "1");

  await next.evaluate((button) => (button as HTMLButtonElement).click());
  const continuity = await frame.evaluate(async (element) => {
    const interruptedAnimation = element
      .getAnimations()
      .find((candidate) =>
        (candidate.effect as KeyframeEffect | null)
          ?.getKeyframes()
          .some((keyframe) => Object.hasOwn(keyframe, "opacity"))
      );
    if (!interruptedAnimation) {
      throw new Error("Expected an active reduced-motion fade.");
    }
    interruptedAnimation.pause();
    const duration = Number(
      (interruptedAnimation.effect as KeyframeEffect | null)?.getTiming().duration
    );
    interruptedAnimation.currentTime = duration / 2;
    await new Promise<void>((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
    );
    const interruptedOpacity = Number(getComputedStyle(element).opacity);

    const stage = element.closest<HTMLElement>(".chat-panel-image-filmstrip");
    const nextButton = stage?.querySelector<HTMLButtonElement>(
      '.chat-panel-image-filmstrip-navigation[data-side="end"]'
    );
    if (!nextButton) throw new Error("Expected the next image control.");
    nextButton.click();
    await Promise.resolve();

    const retargetAnimation = element
      .getAnimations()
      .find((candidate) =>
        (candidate.effect as KeyframeEffect | null)
          ?.getKeyframes()
          .some((keyframe) => Object.hasOwn(keyframe, "opacity"))
      );
    if (!retargetAnimation) {
      throw new Error("Expected a retargeted reduced-motion fade.");
    }
    retargetAnimation.pause();
    retargetAnimation.currentTime = 0;
    await new Promise<void>((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
    );
    const keyframes = (
      retargetAnimation.effect as KeyframeEffect | null
    )?.getKeyframes();
    const result = {
      computedStartOpacity: Number(getComputedStyle(element).opacity),
      interruptedOpacity,
      retargetFromOpacity: Number(keyframes?.at(0)?.opacity),
      retargetToOpacity: Number(keyframes?.at(-1)?.opacity),
    };
    retargetAnimation.play();
    return result;
  });
  expect(continuity.interruptedOpacity).toBeGreaterThan(0);
  expect(continuity.interruptedOpacity).toBeLessThan(1);
  expect(continuity.retargetFromOpacity).toBeCloseTo(continuity.interruptedOpacity, 2);
  expect(continuity.computedStartOpacity).toBeCloseTo(continuity.interruptedOpacity, 2);
  expect(continuity.retargetToOpacity).toBe(0);

  await expect(filmstrip).toHaveAttribute("data-active-index", "2");
  await expect(
    page.locator('.chat-panel-image-group-card[data-stack-pos="0"] img')
  ).toHaveAttribute("alt", "Forest sample photo");
  await expect.poll(() => filmstrip.getAttribute("data-motion")).toBeNull();
  await expect(frame).toHaveCSS("opacity", "1");
  expect(await frame.evaluate((element) => element.getAnimations().length)).toBe(0);
});

test("reduced motion reversal settles visual and active image together", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await openStack(page);
  await page.locator('.chat-panel-image-group-card[data-stack-pos="0"]').click();

  const dialog = page.getByRole("dialog", { name: "Preview image" });
  const filmstrip = dialog.locator(".chat-panel-image-filmstrip");
  const frame = filmstrip.locator('[data-filmstrip-layer="clip"]');
  const next = dialog.getByRole("button", { name: "Show next image" });
  const previous = dialog.getByRole("button", { name: "Show previous image" });
  await expect(filmstrip).toHaveAttribute("data-ready", "true");

  const initialGeometry = await filmstrip.evaluate((stage) => {
    const clip = stage.querySelector<HTMLElement>('[data-filmstrip-layer="clip"]');
    const strip = stage.querySelector<HTMLElement>('[data-filmstrip-layer="strip"]');
    return {
      clipPath: clip ? getComputedStyle(clip).clipPath : "",
      transform: strip ? getComputedStyle(strip).transform : "",
    };
  });

  await next.evaluate((button) => (button as HTMLButtonElement).click());
  const interruptedOpacity = await frame.evaluate(async (element) => {
    const fade = element
      .getAnimations()
      .find(
        (candidate) =>
          !(candidate instanceof CSSAnimation) &&
          !(candidate instanceof CSSTransition) &&
          (candidate.effect as KeyframeEffect | null)
            ?.getKeyframes()
            .some((keyframe) => Object.hasOwn(keyframe, "opacity"))
      );
    if (!fade) throw new Error("Expected an active reduced-motion fade.");

    fade.pause();
    const duration = Number(
      (fade.effect as KeyframeEffect | null)?.getTiming().duration
    );
    fade.currentTime = duration / 2;
    await new Promise<void>((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
    );
    return Number(getComputedStyle(element).opacity);
  });
  expect(interruptedOpacity).toBeGreaterThan(0);
  expect(interruptedOpacity).toBeLessThan(1);

  await page.keyboard.press("ArrowLeft");

  await expect(filmstrip).toHaveAttribute("data-active-index", "0");
  await frame.evaluate(async (element) => {
    for (let phase = 0; phase < 4; phase += 1) {
      const fade = element
        .getAnimations()
        .find(
          (candidate) =>
            !(candidate instanceof CSSAnimation) &&
            !(candidate instanceof CSSTransition) &&
            (candidate.effect as KeyframeEffect | null)
              ?.getKeyframes()
              .some((keyframe) => Object.hasOwn(keyframe, "opacity"))
        );
      if (!fade) break;
      fade.finish();
      await Promise.resolve();
    }
  });
  await expect.poll(() => filmstrip.getAttribute("data-motion")).toBeNull();
  await expect(previous).toHaveAttribute("aria-disabled", "true");
  await expect(next).not.toHaveAttribute("aria-disabled", "true");
  const exposedSlide = filmstrip.locator(
    '.chat-panel-image-filmstrip-slide:not([aria-hidden="true"])'
  );
  await expect(exposedSlide).toHaveCount(1);
  await expect(exposedSlide).toHaveAttribute("alt", "Generated editorial poster");
  await expect(filmstrip.locator("output")).toHaveText(
    "Image 1 of 5: Generated editorial poster"
  );
  await expect(
    page.locator('.chat-panel-image-group-card[data-stack-pos="0"] img')
  ).toHaveAttribute("alt", "Generated editorial poster");

  const settled = await filmstrip.evaluate((stage) => {
    const clip = stage.querySelector<HTMLElement>('[data-filmstrip-layer="clip"]');
    const strip = stage.querySelector<HTMLElement>('[data-filmstrip-layer="strip"]');
    if (!clip || !strip) throw new Error("Expected both filmstrip layers.");
    const bounds = clip.getBoundingClientRect();
    const visualSlide = document
      .elementsFromPoint(bounds.left + bounds.width / 2, bounds.top + bounds.height / 2)
      .find((element) => element.matches(".chat-panel-image-filmstrip-slide"));
    return {
      animationCount: clip.getAnimations().length + strip.getAnimations().length,
      geometry: {
        clipPath: getComputedStyle(clip).clipPath,
        transform: getComputedStyle(strip).transform,
      },
      opacity: getComputedStyle(clip).opacity,
      visualAlt: visualSlide?.getAttribute("alt") ?? null,
    };
  });
  expect(settled).toEqual({
    animationCount: 0,
    geometry: initialGeometry,
    opacity: "1",
    visualAlt: "Generated editorial poster",
  });

  const downloadPromise = page.waitForEvent("download");
  await dialog.getByRole("button", { name: "Download image" }).click();
  expect((await downloadPromise).suggestedFilename()).toBe(
    "generated-editorial-poster.png"
  );
});

test("a two-image group stays tiled after navigating its preview", async ({ page }) => {
  await page.goto(twoImagesStoryUrl, { waitUntil: "domcontentloaded" });
  const cards = page.locator(".chat-panel-image-group-card");
  await expect(cards).toHaveCount(2);
  await cards.first().click();

  const dialog = page.getByRole("dialog", { name: "Preview image" });
  const filmstrip = dialog.locator(".chat-panel-image-filmstrip");
  await expect(filmstrip).toHaveAttribute("data-ready", "true");
  await dialog.getByRole("button", { name: "Show next image" }).click();
  await expect(
    filmstrip.locator('.chat-panel-image-filmstrip-slide:not([aria-hidden="true"])')
  ).toHaveAttribute("alt", "Desert sample photo");
  await dialog.getByRole("button", { name: "Close preview" }).click();
  await expect(dialog).toBeHidden();

  await expect(page.locator(".chat-panel-image-group-toggle")).toHaveCount(0);
  await expect(page.locator(".chat-panel-image-group-advance")).toHaveCount(0);
  await expect(
    page.locator(".chat-panel-image-group-card[data-stack-pos]")
  ).toHaveCount(0);
  await expect(page.locator(".chat-panel-image-group-card:not([inert])")).toHaveCount(
    2
  );
});

test("reaching a strip end keeps focus in the dialog and Escape still closes", async ({
  page,
}) => {
  await page.goto(twoImagesStoryUrl, { waitUntil: "domcontentloaded" });
  const cards = page.locator(".chat-panel-image-group-card");
  await expect(cards).toHaveCount(2);
  await cards.first().click();

  const dialog = page.getByRole("dialog", { name: "Preview image" });
  const filmstrip = dialog.locator(".chat-panel-image-filmstrip");
  const next = dialog.getByRole("button", { name: "Show next image" });
  const previous = dialog.getByRole("button", { name: "Show previous image" });
  await expect(filmstrip).toHaveAttribute("data-ready", "true");

  // A real pointer press, so the control the viewer just used holds focus as
  // it turns unusable. Natively disabling it here blurred it to the body,
  // stranding focus outside the dialog with Escape dead.
  await next.click();
  await expect(previous).toBeFocused();
  await expect(next).toHaveAttribute("aria-disabled", "true");
  await expect(next).toBeVisible();

  await previous.click();
  await expect(next).toBeFocused();
  await expect(previous).toHaveAttribute("aria-disabled", "true");

  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();
});

test("forced-colors mode keeps every image-group control visibly focused", async ({
  page,
}) => {
  await page.emulateMedia({ forcedColors: "active" });
  await openStack(page);

  await expectForcedColorsFocus(".chat-panel-image-group-toggle", page);
  await expectForcedColorsFocus(
    '.chat-panel-image-group-card[data-stack-pos="0"]',
    page
  );
  await expectForcedColorsFocus(
    '.chat-panel-image-group-advance[data-side="start"]',
    page
  );
  await expectForcedColorsFocus(
    '.chat-panel-image-group-advance[data-side="end"]',
    page
  );
});
