import { expect, test, type Page, useFixture } from "./support/page";
import { fixtureMount } from "./support/fixture";
import { stepUntilSettled, testClock } from "./support/virtual-time";
import { gradientShimmerMotion } from "../../packages/ui/src/components/ai-activity/useGradientShimmer";

useFixture(
  fixtureMount(new URL("./fixtures/ai-activity/src/main.tsx", import.meta.url))
);
const fixtureUrl = "http://fixture.test/";

/** The shimmer's background sweep. */
function findSweep(element: Element) {
  return element.getAnimations().find((candidate) => {
    const effect = candidate.effect;
    return (
      effect instanceof KeyframeEffect &&
      effect.getKeyframes().some((frame) => Object.hasOwn(frame, "backgroundPosition"))
    );
  });
}

async function readShimmerFallback(page: Page) {
  const shimmer = page
    .getByTestId("ai-activity-fixture")
    .locator('[data-slot="ai-activity"]')
    .first()
    .locator('[data-shimmer="true"]');
  await expect(shimmer).toHaveText("Thinking");
  return shimmer.evaluate((element) => {
    const style = getComputedStyle(element);
    const transparent = new Set(["transparent", "rgba(0, 0, 0, 0)"]);
    const textFillIsTransparent = transparent.has(style.webkitTextFillColor);
    const foregroundIsTransparent = transparent.has(style.color);
    const animations = element.getAnimations();
    return {
      animationCount: animations.length,
      animationDetails: animations.map((animation) => {
        const effect = animation.effect;
        return {
          constructor: animation.constructor.name,
          duration:
            effect instanceof KeyframeEffect
              ? Number(effect.getTiming().duration)
              : undefined,
          easing:
            effect instanceof KeyframeEffect ? effect.getTiming().easing : undefined,
          keyframeProperties:
            effect instanceof KeyframeEffect
              ? effect.getKeyframes().flatMap((frame) => Object.keys(frame))
              : [],
          playState: animation.playState,
        };
      }),
      backgroundImage: style.backgroundImage,
      color: style.color,
      forcedColors: matchMedia("(forced-colors: active)").matches,
      opacity: Number.parseFloat(style.opacity),
      readable:
        style.visibility === "visible" &&
        Number.parseFloat(style.opacity) > 0 &&
        (!textFillIsTransparent || style.backgroundImage !== "none") &&
        !foregroundIsTransparent,
      rootReducedMotion: document.documentElement.getAttribute(
        "data-comma-reduced-motion"
      ),
      textFillColor: style.webkitTextFillColor,
      visibility: style.visibility,
    };
  });
}

test("AI activity keeps keyboard focus visible and collapsed details inert", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiActivityFixture));

  const fixture = page.getByTestId("ai-activity-fixture");
  const activity = fixture.locator('[data-slot="ai-activity"]').first();
  const disclosure = activity.getByRole("button", { name: "Thinking" });
  const text = activity.locator(".comma-ai-activity-text");
  const panelShell = activity.locator(".comma-ai-activity-panel-shell");
  const summaryShell = activity.locator(".comma-ai-activity-summary-shell");

  await expect(disclosure).toBeVisible();
  await expect(text.locator(".comma-ai-activity-text-layer")).toHaveCount(1);
  const shimmer = text.locator('[data-shimmer="true"]');
  await expect(shimmer).toHaveText("Thinking");
  const initialShimmerTime = await shimmer.evaluate((element) => {
    const animation = element
      .getAnimations()
      .find((candidate) => candidate.effect instanceof KeyframeEffect);
    return {
      currentTime: Number(animation?.currentTime ?? 0),
      playState: animation?.playState,
    };
  });
  expect(initialShimmerTime.playState).toBe("running");
  // Observe animation progress instead of assuming a frame paints within 50 ms.
  await expect
    .poll(() =>
      shimmer.evaluate((element) =>
        Number(
          element
            .getAnimations()
            .find((candidate) => candidate.effect instanceof KeyframeEffect)
            ?.currentTime ?? 0
        )
      )
    )
    .toBeGreaterThan(initialShimmerTime.currentTime);
  await expect(panelShell).toHaveAttribute("inert", "");

  await page.keyboard.press("Tab");
  await expect(disclosure).toBeFocused();
  await expect(disclosure).toHaveAttribute("data-focus-visible", "true");
  await expect
    .poll(() => summaryShell.evaluate((element) => getComputedStyle(element).boxShadow))
    .not.toBe("none");

  await page.keyboard.press("Enter");
  await expect(disclosure).toHaveAttribute("aria-expanded", "true");
  await expect(panelShell).not.toHaveAttribute("inert", "");

  await page.keyboard.press("Tab");
  const worker = activity.getByRole("button", { name: "Worker, working" });
  await expect(worker).toBeFocused();
  await expect(page.getByRole("tooltip")).toContainText(
    "Compress 1.mp4 and report back."
  );

  await page.evaluate(() => window.aiActivityFixture?.finish());

  const completedDisclosure = fixture.getByRole("button", {
    name: "Worked for 17 seconds",
  });
  await expect(completedDisclosure).toHaveAttribute("aria-expanded", "false");
  await expect(completedDisclosure).toBeFocused();
  await expect(panelShell).toHaveAttribute("inert", "");
  await expect
    .poll(() =>
      panelShell
        .locator(".collapse-content-wrapper")
        .evaluate((element) => getComputedStyle(element).filter)
    )
    .toBe("none");
  await expect(
    fixture.getByRole("heading", { name: "Compression complete" })
  ).toBeVisible();
  await expect(fixture.locator("code")).toHaveText("1-compressed.mp4");
  const fontSizes = await fixture.evaluate((element) => ({
    activity: getComputedStyle(element.querySelector(".comma-ai-activity")!).fontSize,
    markdown: getComputedStyle(element.querySelector(".markdown-renderer")!).fontSize,
  }));
  expect(fontSizes.activity).toBe(fontSizes.markdown);

  await page.keyboard.press("Tab");
  await expect(page.getByTestId("after-activity")).toBeFocused();
});

test("AI activity disclosure does not scale while expanding details", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiActivityFixture));

  const activity = page
    .getByTestId("ai-activity-fixture")
    .locator('[data-slot="ai-activity"]')
    .first();
  const disclosure = activity.getByRole("button", { name: "Thinking" });
  await page.evaluate(() => document.fonts.ready);
  const bounds = await disclosure.boundingBox();
  if (bounds == null) throw new Error("Thinking disclosure is not measurable.");

  const beforePress = await disclosure.evaluate((element) => {
    const rect = element.getBoundingClientRect();
    return {
      height: rect.height,
      left: rect.left,
      scale: getComputedStyle(element).scale,
      top: rect.top,
      transform: getComputedStyle(element).transform,
      width: rect.width,
    };
  });

  await page.mouse.move(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
  await page.mouse.down();
  await disclosure.evaluate(() => testClock().advanceFrames(2));
  const duringPress = await disclosure.evaluate((element) => {
    const rect = element.getBoundingClientRect();
    return {
      height: rect.height,
      left: rect.left,
      scale: getComputedStyle(element).scale,
      top: rect.top,
      transform: getComputedStyle(element).transform,
      width: rect.width,
    };
  });
  await page.mouse.up();

  expect(duringPress.transform).toBe("none");
  expect(["none", "1"]).toContain(duringPress.scale);
  expect(duringPress.height).toBeCloseTo(beforePress.height, 2);
  expect(duringPress.left).toBeCloseTo(beforePress.left, 2);
  expect(duringPress.top).toBeCloseTo(beforePress.top, 2);
  expect(duringPress.width).toBeCloseTo(beforePress.width, 2);
  await expect(disclosure).toHaveAttribute("aria-expanded", "true");
});

test("AI activity reveals Thought history downward from the summary edge", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiActivityFixture));
  await page.evaluate(() => document.fonts.ready);

  const activity = page.getByTestId("origin-activity");
  const disclosure = activity.getByRole("button", {
    name: "Thought for 7 seconds",
  });

  const samples = await disclosure.evaluate(async (triggerElement) => {
    if (!(triggerElement instanceof HTMLElement)) {
      throw new Error("Thought disclosure is not an HTML element.");
    }
    const activityRoot = triggerElement.closest<HTMLElement>(
      '[data-slot="ai-activity"]'
    );
    const summary = activityRoot?.querySelector<HTMLElement>(
      ".comma-ai-activity-summary-shell"
    );
    const shell = activityRoot?.querySelector<HTMLElement>(
      ".comma-ai-activity-panel-shell"
    );
    const wrapper = activityRoot?.querySelector<HTMLElement>(
      ".collapse-content-wrapper"
    );
    const content = activityRoot?.querySelector<HTMLElement>(".collapse-content");
    const firstRow = activityRoot?.querySelector<HTMLElement>(
      ".comma-ai-activity-event"
    );
    if (!activityRoot || !summary || !shell || !wrapper || !content || !firstRow) {
      throw new Error("Thought disclosure geometry is unavailable.");
    }

    const frames: Array<{
      contentClipPath: string;
      contentFilter: string;
      contentLeft: number;
      contentTop: number;
      contentTransform: string;
      contentWidth: number;
      firstRowBottom: number;
      firstRowTop: number;
      shellBottom: number;
      shellClipPath: string;
      shellHeight: number;
      shellOverflow: string;
      shellTop: number;
      summaryBottom: number;
      wrapperClipPath: string;
      wrapperFilter: string;
      wrapperOpacity: number;
      wrapperTransform: string;
    }> = [];
    const recordFrame = () => {
      const summaryRect = summary.getBoundingClientRect();
      const shellRect = shell.getBoundingClientRect();
      const contentRect = content.getBoundingClientRect();
      const firstRowRect = firstRow.getBoundingClientRect();
      const wrapperStyle = getComputedStyle(wrapper);
      const contentStyle = getComputedStyle(content);
      const shellStyle = getComputedStyle(shell);
      frames.push({
        contentClipPath: contentStyle.clipPath,
        contentFilter: contentStyle.filter,
        contentLeft: contentRect.left,
        contentTop: contentRect.top,
        contentTransform: contentStyle.transform,
        contentWidth: contentRect.width,
        firstRowBottom: firstRowRect.bottom,
        firstRowTop: firstRowRect.top,
        shellBottom: shellRect.bottom,
        shellClipPath: shellStyle.clipPath,
        shellHeight: shellRect.height,
        shellOverflow: shellStyle.overflow,
        shellTop: shellRect.top,
        summaryBottom: summaryRect.bottom,
        wrapperClipPath: wrapperStyle.clipPath,
        wrapperFilter: wrapperStyle.filter,
        wrapperOpacity: Number.parseFloat(wrapperStyle.opacity),
        wrapperTransform: wrapperStyle.transform,
      });
    };

    recordFrame();
    triggerElement.click();
    const startedAt = performance.now();
    await stepUntilSettled(
      new Promise<void>((resolveFrames) => {
        const sampleFrame = () => {
          recordFrame();
          if (performance.now() - startedAt >= 320) {
            resolveFrames();
            return;
          }
          requestAnimationFrame(sampleFrame);
        };
        requestAnimationFrame(sampleFrame);
      })
    );
    return frames;
  });

  expect(samples.length).toBeGreaterThan(2);
  const initial = samples[0]!;
  const final = samples.at(-1)!;
  expect(final.shellHeight).toBeGreaterThan(initial.shellHeight);

  for (const [index, sample] of samples.entries()) {
    expect(sample.shellTop, `shell top at frame ${index}`).toBeCloseTo(
      initial.shellTop,
      1
    );
    expect(sample.summaryBottom, `summary bottom at frame ${index}`).toBeCloseTo(
      initial.summaryBottom,
      1
    );
    expect(sample.shellTop, `summary edge at frame ${index}`).toBeCloseTo(
      sample.summaryBottom,
      1
    );
    expect(sample.contentTop, `content top at frame ${index}`).toBeCloseTo(
      initial.contentTop,
      1
    );
    expect(sample.contentLeft, `content left at frame ${index}`).toBeCloseTo(
      initial.contentLeft,
      1
    );
    expect(sample.contentWidth, `content width at frame ${index}`).toBeCloseTo(
      initial.contentWidth,
      1
    );
    expect(sample.wrapperOpacity, `wrapper opacity at frame ${index}`).toBe(1);
    expect(sample.wrapperTransform, `wrapper transform at frame ${index}`).toBe("none");
    expect(sample.wrapperFilter, `wrapper filter at frame ${index}`).toBe("none");
    expect(sample.wrapperClipPath, `wrapper clip path at frame ${index}`).toBe("none");
    expect(sample.contentTransform, `content transform at frame ${index}`).toBe("none");
    expect(sample.contentFilter, `content filter at frame ${index}`).toBe("none");
    expect(sample.contentClipPath, `content clip path at frame ${index}`).toBe("none");
    expect(sample.shellClipPath, `shell clip path at frame ${index}`).toBe("none");
    expect(sample.shellOverflow, `shell overflow at frame ${index}`).toBe("clip");
    if (index > 0) {
      expect(
        sample.shellBottom,
        `shell bottom must move downward at frame ${index}`
      ).toBeGreaterThanOrEqual(samples[index - 1]!.shellBottom - 0.1);
    }

    const visibleFirstRowHeight = Math.max(
      0,
      Math.min(sample.shellBottom, sample.firstRowBottom) -
        Math.max(sample.shellTop, sample.firstRowTop)
    );
    if (visibleFirstRowHeight > 0) {
      expect(
        Math.max(sample.shellTop, sample.firstRowTop),
        `first visible row starts at its block-start at frame ${index}`
      ).toBeCloseTo(sample.firstRowTop, 1);
    }
  }

  await expect(disclosure).toHaveAttribute("aria-expanded", "true");
});

test("AI activity shows eight history rows before scrolling", async ({ page }) => {
  await page.goto(fixtureUrl);

  const history = page.getByTestId("long-history");
  const viewport = history.locator('[data-slot="scroll-area-viewport"]');
  const rows = history.locator(".comma-ai-activity-event");

  await expect(rows).toHaveCount(9);
  await expect(viewport).toBeVisible();

  for (const rootFontSize of [14.4, 16, 17.6]) {
    await page.evaluate((fontSize) => {
      document.documentElement.style.fontSize = `${fontSize}px`;
    }, rootFontSize);

    const geometry = await viewport.evaluate((element) => {
      const firstRow = element.querySelector<HTMLElement>(".comma-ai-activity-event");
      const list = element.querySelector<HTMLElement>(".comma-ai-activity-events");
      const listStyles = getComputedStyle(list!);

      return {
        clientHeight: element.clientHeight,
        expectedHeight:
          Number.parseFloat(getComputedStyle(firstRow!).lineHeight) * 8 +
          Number.parseFloat(listStyles.rowGap) * 7,
        scrollHeight: element.scrollHeight,
      };
    });

    expect(geometry.clientHeight).toBeCloseTo(geometry.expectedHeight, 0);
    expect(geometry.scrollHeight).toBeGreaterThan(geometry.clientHeight);
  }
});

test("AI activity keeps text readable throughout the crossfade", async ({ page }) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiActivityFixture));
  const minimumOpacity = await page.evaluate(async () => {
    const activity = document.querySelector<HTMLElement>(
      '[data-testid="rapid-activity"]'
    )!;
    window.aiActivityFixture!.burst();
    for (let frame = 0; frame < 60; frame += 1) {
      await testClock().advanceFrames(1);
      const layers = [
        ...activity.querySelectorAll<HTMLElement>(".comma-ai-activity-text-layer"),
      ];
      const fades = layers
        .flatMap((layer) => layer.getAnimations())
        .filter(
          (animation) =>
            animation instanceof CSSTransition &&
            animation.transitionProperty === "opacity"
        );
      if (fades.length !== 2) continue;
      for (const fade of fades) fade.pause();
      const duration = Math.max(
        ...fades.map((fade) => Number(fade.effect!.getTiming().duration))
      );
      let minimum = 1;
      // Sample both production transitions at the same time, independent of refresh rate.
      for (let time = 0; time <= duration; time += 1) {
        for (const fade of fades) fade.currentTime = time;
        minimum = Math.min(
          minimum,
          Math.max(...layers.map((layer) => Number(getComputedStyle(layer).opacity)))
        );
      }
      return minimum;
    }
    throw new Error("The activity crossfade did not start.");
  });
  expect(minimumOpacity).toBeGreaterThan(0.45);
});

test("AI activity keeps rapid same-phase updates readable and exits without blur", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiActivityFixture));

  const sample = await page.evaluate(async () => {
    const activity = document.querySelector<HTMLElement>(
      '[data-testid="rapid-activity"]'
    );
    if (!activity || !window.aiActivityFixture) {
      throw new Error("Rapid activity fixture is unavailable.");
    }

    const initialLayer = activity.querySelector<HTMLElement>(
      '.comma-ai-activity-text-layer:not([aria-hidden="true"])'
    );
    let publicShimmerSamples = 0;
    let filteredLayerSamples = 0;
    let incomingBelowSamples = 0;
    let maxLayers = 0;
    let maxOutgoingBlurPx = 0;
    let minReadableOpacity = 1;
    let observedEnterDurationMs = 0;
    let observedExitDurationMs = 0;
    let opposedRollSamples = 0;
    let outgoingAboveSamples = 0;
    let outgoingExitSamples = 0;
    let outgoingShimmerSamples = 0;
    let samePhaseExitSamples = 0;
    let samePhaseIdentityChangeSamples = 0;
    let samplesWithoutText = 0;

    window.aiActivityFixture.burst();

    await stepUntilSettled(
      new Promise<void>((resolveSample) => {
        const startedAt = performance.now();
        const readFrame = () => {
          const layers = [
            ...activity.querySelectorAll<HTMLElement>(".comma-ai-activity-text-layer"),
          ];
          const current = layers.find(
            (layer) => layer.getAttribute("aria-hidden") !== "true"
          );
          const currentText = current?.innerText.trim() ?? "";
          const currentStyle = current ? getComputedStyle(current) : null;
          const currentTranslateY = currentStyle
            ? new DOMMatrixReadOnly(currentStyle.transform).m42
            : 0;
          const readableOpacity = Math.max(
            0,
            ...layers
              .filter((layer) => layer.innerText.trim())
              .map((layer) => Number.parseFloat(getComputedStyle(layer).opacity))
          );
          const outgoing = layers.filter(
            (layer) =>
              layer.getAttribute("aria-hidden") === "true" &&
              layer.dataset.motion === "exit"
          );

          maxLayers = Math.max(maxLayers, layers.length);
          minReadableOpacity = Math.min(minReadableOpacity, readableOpacity);
          if (!layers.some((layer) => layer.innerText.trim())) samplesWithoutText += 1;
          if (
            currentText !== "Running tests" &&
            current != null &&
            current !== initialLayer
          ) {
            samePhaseIdentityChangeSamples += 1;
          }
          if (current?.querySelector('[data-shimmer="true"]')) {
            publicShimmerSamples += 1;
          }
          if (currentTranslateY > 0.05) incomingBelowSamples += 1;
          if (currentStyle) {
            observedEnterDurationMs = Math.max(
              observedEnterDurationMs,
              ...currentStyle.transitionDuration.split(",").map((duration) => {
                const value = Number.parseFloat(duration);
                return duration.trim().endsWith("ms") ? value : value * 1000;
              })
            );
          }
          for (const layer of layers) {
            if (getComputedStyle(layer).filter !== "none") filteredLayerSamples += 1;
          }
          outgoingExitSamples += outgoing.length;
          for (const layer of outgoing) {
            if (
              layer.dataset.motionKey?.includes("rapid-thinking:") &&
              current?.dataset.motionKey?.includes("rapid-thinking:")
            ) {
              samePhaseExitSamples += 1;
            }
            const filter = getComputedStyle(layer).filter;
            const outgoingStyle = getComputedStyle(layer);
            const outgoingTranslateY = new DOMMatrixReadOnly(outgoingStyle.transform)
              .m42;
            observedExitDurationMs = Math.max(
              observedExitDurationMs,
              ...outgoingStyle.transitionDuration.split(",").map((duration) => {
                const value = Number.parseFloat(duration);
                return duration.trim().endsWith("ms") ? value : value * 1000;
              })
            );
            if (outgoingTranslateY < -0.05) outgoingAboveSamples += 1;
            if (outgoingTranslateY < -0.05 && currentTranslateY > 0.05) {
              opposedRollSamples += 1;
            }
            maxOutgoingBlurPx = Math.max(
              maxOutgoingBlurPx,
              0,
              ...Array.from(filter.matchAll(/blur\(([\d.]+)px\)/g), (match) =>
                Number.parseFloat(match[1] ?? "0")
              )
            );
          }
          outgoingShimmerSamples += layers.filter(
            (layer) =>
              layer.getAttribute("aria-hidden") === "true" &&
              layer.querySelector('[data-shimmer="true"]')
          ).length;

          if (performance.now() - startedAt >= 900) {
            resolveSample();
            return;
          }
          requestAnimationFrame(readFrame);
        };
        requestAnimationFrame(readFrame);
      })
    );

    return {
      publicShimmerSamples,
      filteredLayerSamples,
      finalText: activity.innerText.trim(),
      incomingBelowSamples,
      maxLayers,
      maxOutgoingBlurPx,
      minReadableOpacity,
      observedEnterDurationMs,
      observedExitDurationMs,
      opposedRollSamples,
      outgoingAboveSamples,
      outgoingExitSamples,
      outgoingShimmerSamples,
      samePhaseExitSamples,
      samePhaseIdentityChangeSamples,
      samplesWithoutText,
    };
  });

  expect(sample.maxLayers).toBeLessThanOrEqual(2);
  expect(sample.samplesWithoutText).toBe(0);
  expect(sample.minReadableOpacity).toBeGreaterThan(0.45);
  expect(sample.samePhaseIdentityChangeSamples).toBeGreaterThan(0);
  expect(sample.samePhaseExitSamples).toBeGreaterThan(0);
  expect(sample.incomingBelowSamples).toBeGreaterThan(0);
  expect(sample.outgoingAboveSamples).toBeGreaterThan(0);
  expect(sample.opposedRollSamples).toBeGreaterThan(0);
  expect(sample.observedEnterDurationMs).toBeLessThan(200);
  expect(sample.observedExitDurationMs).toBeLessThan(sample.observedEnterDurationMs);
  expect(sample.publicShimmerSamples).toBe(0);
  expect(sample.outgoingShimmerSamples).toBe(0);
  expect(sample.outgoingExitSamples).toBeGreaterThan(0);
  expect(sample.filteredLayerSamples).toBe(0);
  expect(sample.maxOutgoingBlurPx).toBe(0);
  expect(sample.finalText).toBe("Running tests");
});

test("AI activity honors browser reduced motion during rapid updates", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiActivityFixture));

  const sample = await page.evaluate(async () => {
    const activity = document.querySelector<HTMLElement>(
      '[data-testid="rapid-activity"]'
    );
    const genericActivity = document.querySelector<HTMLElement>(
      '[data-testid="ai-activity-fixture"] [data-slot="ai-activity"]'
    );
    if (!activity || !window.aiActivityFixture) {
      throw new Error("Rapid activity fixture is unavailable.");
    }

    let animatedShimmerSamples = 0;
    let blurredSamples = 0;
    let maxLayers = 0;
    let movedSamples = 0;
    let samplesWithoutText = 0;
    let shimmerSamples = 0;
    window.aiActivityFixture.burst();

    await stepUntilSettled(
      new Promise<void>((resolveSample) => {
        const startedAt = performance.now();
        const readFrame = () => {
          const layers = [
            ...activity.querySelectorAll<HTMLElement>(".comma-ai-activity-text-layer"),
          ];
          maxLayers = Math.max(maxLayers, layers.length);
          if (!layers.some((layer) => layer.innerText.trim())) samplesWithoutText += 1;

          for (const layer of layers) {
            const layerStyle = getComputedStyle(layer);
            if (/blur\((?!0(?:\.0+)?px\))/.test(layerStyle.filter)) {
              blurredSamples += 1;
            }
            if (layerStyle.transform !== "none") movedSamples += 1;

            const shimmer = layer.querySelector<HTMLElement>('[data-shimmer="true"]');
            if (shimmer) {
              shimmerSamples += 1;
              if (getComputedStyle(shimmer).animationName !== "none") {
                animatedShimmerSamples += 1;
              }
            }
          }

          if (performance.now() - startedAt >= 600) {
            resolveSample();
            return;
          }
          requestAnimationFrame(readFrame);
        };
        requestAnimationFrame(readFrame);
      })
    );

    const genericShimmer = genericActivity?.querySelector<HTMLElement>(
      '[data-shimmer="true"]'
    );

    return {
      animatedShimmerSamples,
      blurredSamples,
      finalText: activity.innerText.trim(),
      genericShimmerAnimation: genericShimmer
        ? getComputedStyle(genericShimmer).animationName
        : undefined,
      genericShimmerColor: genericShimmer
        ? getComputedStyle(genericShimmer).color
        : undefined,
      genericShimmerPresent: genericShimmer != null,
      quaternaryColor: (() => {
        const probe = document.createElement("span");
        probe.style.color = "var(--color-text-quaternary)";
        document.body.append(probe);
        const color = getComputedStyle(probe).color;
        probe.remove();
        return color;
      })(),
      maxLayers,
      movedSamples,
      samplesWithoutText,
      shimmerSamples,
    };
  });

  expect(sample.maxLayers).toBe(1);
  expect(sample.samplesWithoutText).toBe(0);
  expect(sample.blurredSamples).toBe(0);
  expect(sample.movedSamples).toBe(0);
  expect(sample.shimmerSamples).toBe(0);
  expect(sample.animatedShimmerSamples).toBe(0);
  expect(sample.genericShimmerPresent).toBe(true);
  expect(sample.genericShimmerAnimation).toBe("none");
  expect(sample.genericShimmerColor).toBe(sample.quaternaryColor);
  expect(sample.finalText).toBe("Running tests");
});

test("AI activity shimmer uses the bounded gentle multi-stop band", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiActivityFixture));

  const shimmer = page
    .getByTestId("ai-activity-fixture")
    .locator('[data-slot="ai-activity"]')
    .first()
    .locator('[data-shimmer="true"]');
  await expect(shimmer).toHaveText("Thinking");
  await expect
    .poll(() =>
      shimmer.evaluate((element) =>
        element.getAnimations().some((animation) => {
          const effect = animation.effect;
          return (
            effect instanceof KeyframeEffect &&
            effect
              .getKeyframes()
              .some((frame) => Object.hasOwn(frame, "backgroundPosition"))
          );
        })
      )
    )
    .toBe(true);

  const sample = await shimmer.evaluate((element) => {
    const animation = element.getAnimations().find((candidate) => {
      const effect = candidate.effect;
      return (
        effect instanceof KeyframeEffect &&
        effect
          .getKeyframes()
          .some((frame) => Object.hasOwn(frame, "backgroundPosition"))
      );
    });
    if (!animation || !(animation.effect instanceof KeyframeEffect)) {
      throw new Error("The shimmer WAAPI animation is unavailable.");
    }

    const style = getComputedStyle(element);
    const effect = animation.effect;
    const timing = effect.getTiming();
    const keyframes = effect.getKeyframes();
    // The band takes the fixed brand scale, so it reads the same in both themes.
    const tokenSteps = [300, 200, 100, 50] as const;
    const probe = document.createElement("span");
    document.body.append(probe);
    const tokenColors = tokenSteps.map((step) => {
      probe.style.color = `var(--color-brand-${step})`;
      return getComputedStyle(probe).color;
    });
    probe.style.color = "var(--color-text-quaternary)";
    const quaternaryColor = getComputedStyle(probe).color;
    probe.remove();

    const spread = Number.parseFloat(
      style.getPropertyValue("--ai-activity-shimmer-spread")
    );
    const spreadMid = Number.parseFloat(
      style.getPropertyValue("--ai-activity-shimmer-spread-mid")
    );
    const fontSize = Number.parseFloat(style.fontSize);
    const expectedSpread = Math.min(
      Array.from(element.textContent ?? "").length * 5 * (fontSize / 14),
      48 * (fontSize / 14)
    );

    return {
      animationConstructor: animation.constructor.name,
      backgroundImage: style.backgroundImage,
      backgroundRepeat: style.backgroundRepeat,
      clip: style.backgroundClip,
      color: style.color,
      duration: Number(timing.duration),
      easing: timing.easing,
      expectedSpread,
      fill: timing.fill,
      keyframePositions: keyframes.map((frame) =>
        String(
          (frame as ComputedKeyframe & { backgroundPosition?: string })
            .backgroundPosition ?? ""
        )
      ),
      iterationCount: timing.iterations,
      playState: animation.playState,
      quaternaryColor,
      spread,
      spreadMid,
      textFillColor: style.webkitTextFillColor,
      tokenColors,
      tokenRawValues: tokenSteps.map((step) =>
        getComputedStyle(document.documentElement)
          .getPropertyValue(`--color-brand-${step}`)
          .trim()
      ),
    };
  });

  expect(sample.animationConstructor).toBe("Animation");
  expect(sample.duration).toBe(2_000);
  expect(sample.easing).toBe("cubic-bezier(0.76, 0, 0.24, 1)");
  expect(sample.fill).toBe("forwards");
  expect(sample.iterationCount).toBe(1);
  expect(sample.playState).toBe("running");
  expect(sample.backgroundImage).toContain("linear-gradient(105deg");
  expect(sample.backgroundRepeat).toBe("no-repeat");
  expect(sample.clip).toBe("text");
  expect(sample.color).toBe(sample.quaternaryColor);
  expect(sample.textFillColor).toBe("rgba(0, 0, 0, 0)");
  expect(sample.tokenRawValues.every(Boolean)).toBe(true);
  const colorPositions = sample.tokenColors.map((color) =>
    sample.backgroundImage.indexOf(color)
  );
  expect(colorPositions.every((position) => position >= 0)).toBe(true);
  expect(colorPositions).toEqual(colorPositions.toSorted((a, b) => a - b));
  expect(sample.spread).toBeCloseTo(sample.expectedSpread, 1);
  expect(sample.spreadMid).toBeCloseTo(sample.spread * 0.72, 1);
  expect(sample.keyframePositions).toHaveLength(2);
  expect(sample.keyframePositions[0]).not.toBe(sample.keyframePositions[1]);

  // The sweep ends, rests for its pause, then a new sweep starts: on the test
  // clock, exactly when the pause ends.
  const time = testClock();
  const initial = await shimmer.evaluate((element) => {
    const sweep = element
      .getAnimations()
      .find(
        (candidate) =>
          candidate.effect instanceof KeyframeEffect &&
          candidate.effect
            .getKeyframes()
            .some((frame) => Object.hasOwn(frame, "backgroundPosition"))
      );
    if (!sweep) throw new Error("The initial shimmer sweep is unavailable.");
    sweep.finish();
    return sweep;
  });
  await time.advance(gradientShimmerMotion.pauseMs - 1);
  const duringPause = await shimmer.evaluate(findSweep);
  expect(duringPause).toBe(initial);
  expect(duringPause?.playState).toBe("finished");

  await time.advance(1);
  const cycle = await shimmer.evaluate((element) => {
    const replacement = element
      .getAnimations()
      .find(
        (candidate) =>
          candidate.effect instanceof KeyframeEffect &&
          candidate.effect
            .getKeyframes()
            .some((frame) => Object.hasOwn(frame, "backgroundPosition"))
      );
    const style = getComputedStyle(element);
    const spread = Number.parseFloat(
      style.getPropertyValue("--ai-activity-shimmer-spread")
    );
    return {
      backgroundWidth: Number.parseFloat(style.backgroundSize),
      expectedLayerWidth: element.getBoundingClientRect().width + spread * 2,
      replacement,
      replacementDuration:
        replacement?.effect instanceof KeyframeEffect
          ? Number(replacement.effect.getTiming().duration)
          : undefined,
    };
  });
  expect(cycle.replacement).not.toBe(initial);
  expect(cycle.replacement?.playState).toBe("running");
  expect(cycle.backgroundWidth).toBeCloseTo(cycle.expectedLayerWidth, 0);
  expect(cycle.replacementDuration).toBe(gradientShimmerMotion.sweepDurationMs);

  const boundedShimmer = page
    .getByTestId("bounded-shimmer-activity")
    .locator('[data-shimmer="true"]');
  await boundedShimmer.scrollIntoViewIfNeeded();
  const bounded = await boundedShimmer.evaluate((element) => {
    const style = getComputedStyle(element);
    const fontSize = Number.parseFloat(style.fontSize);
    return {
      cap: 48 * (fontSize / 14),
      naiveSpread: Array.from(element.textContent ?? "").length * 5 * (fontSize / 14),
      spread: Number.parseFloat(style.getPropertyValue("--ai-activity-shimmer-spread")),
    };
  });
  expect(bounded.naiveSpread).toBeGreaterThan(bounded.cap);
  expect(bounded.spread).toBeCloseTo(bounded.cap, 1);
});

test("exact Participant active status uses the WAAPI shimmer", async ({ page }) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiActivityFixture));

  const fixture = page.getByTestId("main-process-step-fixture");
  // Offscreen activity intentionally pauses its shimmer.
  await fixture.scrollIntoViewIfNeeded();
  const activeSteps = [
    ["active-thinking", "Thinking"],
    ["active-execution", "Thinking"],
  ] as const;

  for (const [stage, summary] of activeSteps) {
    await page.evaluate(
      (nextStage) => window.aiActivityFixture?.setMainProcessStep(nextStage),
      stage
    );
    const visibleSummary = fixture.locator(
      '.comma-ai-activity-text-layer:not([aria-hidden="true"]) .comma-ai-activity-text-summary'
    );
    await expect(visibleSummary).toHaveText(summary);
    await expect(visibleSummary).not.toContainText("is executing a tool");
    await expect(visibleSummary).toHaveAttribute("data-shimmer", "true");
    await expect
      .poll(() =>
        visibleSummary.evaluate((element) =>
          element.getAnimations().some((animation) => {
            const effect = animation.effect;
            return (
              effect instanceof KeyframeEffect &&
              effect
                .getKeyframes()
                .some((frame) => Object.hasOwn(frame, "backgroundPosition")) &&
              animation.playState === "running"
            );
          })
        )
      )
      .toBe(true);

    const sample = await visibleSummary.evaluate((element) => {
      const animation = element.getAnimations().find((candidate) => {
        const effect = candidate.effect;
        return (
          effect instanceof KeyframeEffect &&
          effect
            .getKeyframes()
            .some((frame) => Object.hasOwn(frame, "backgroundPosition"))
        );
      });
      if (!animation || !(animation.effect instanceof KeyframeEffect)) {
        throw new Error("The Participant status shimmer is unavailable.");
      }
      const timing = animation.effect.getTiming();
      return {
        backgroundImage: getComputedStyle(element).backgroundImage,
        duration: Number(timing.duration),
        easing: timing.easing,
        fill: timing.fill,
        iterations: timing.iterations,
        playState: animation.playState,
      };
    });
    expect(sample.backgroundImage).toContain("linear-gradient(105deg");
    expect(sample.duration).toBe(2_000);
    expect(sample.easing).toBe("cubic-bezier(0.76, 0, 0.24, 1)");
    expect(sample.fill).toBe("forwards");
    expect(sample.iterations).toBe(1);
    expect(sample.playState).toBe("running");
  }

  await page.evaluate(() => window.aiActivityFixture?.setMainProcessStep("error"));
  // The fixture's status carries no issue code: the generic line, never its text.
  await expect(fixture).toContainText("Something went wrong. Try sending again.");
  await expect(fixture).not.toContainText("task.create");
  await expect(fixture.locator('[data-slot="ai-activity"]')).toHaveAttribute(
    "data-status",
    "failed"
  );
  await expect(fixture.locator('[data-shimmer="true"]')).toHaveCount(0);

  await page.evaluate(() => window.aiActivityFixture?.setMainProcessStep("stopped"));
  await expect(fixture.getByTestId("participant-status-slot")).toHaveAttribute(
    "data-active",
    "false"
  );
  await expect(fixture.locator(".comma-chat-activity-row")).toHaveAttribute(
    "aria-hidden",
    "true"
  );
  await expect(fixture.locator('[data-shimmer="true"]')).toHaveCount(0);
});
test("projected main-process shimmer becomes static readable text with reduced motion", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiActivityFixture));

  const fixture = page.getByTestId("main-process-step-fixture");
  const activeStages = ["active-thinking", "active-execution"] as const;
  for (const stage of activeStages) {
    await page.evaluate(
      (nextStage) => window.aiActivityFixture?.setMainProcessStep(nextStage),
      stage
    );
    const visibleSummary = fixture.locator(
      '.comma-ai-activity-text-layer:not([aria-hidden="true"]) .comma-ai-activity-text-summary'
    );
    await expect(visibleSummary).toHaveAttribute("data-shimmer", "true");
    const fallback = await visibleSummary.evaluate((element) => {
      const style = getComputedStyle(element);
      return {
        animationCount: element.getAnimations().length,
        backgroundImage: style.backgroundImage,
        opacity: Number.parseFloat(style.opacity),
        textFillColor: style.webkitTextFillColor,
        visibility: style.visibility,
      };
    });
    expect(fallback.animationCount).toBe(0);
    expect(fallback.backgroundImage).toBe("none");
    expect(fallback.opacity).toBe(1);
    expect(fallback.textFillColor).not.toBe("rgba(0, 0, 0, 0)");
    expect(fallback.visibility).toBe("visible");
  }

  await page.evaluate(() => window.aiActivityFixture?.setMainProcessStep("stopped"));
  await expect(fixture.locator('[data-shimmer="true"]')).toHaveCount(0);
});

test("AI activity shimmer pauses during scroll and while offscreen", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiActivityFixture));

  const shimmer = page
    .getByTestId("ai-activity-fixture")
    .locator('[data-slot="ai-activity"]')
    .first()
    .locator('[data-shimmer="true"]');
  const readPlayState = () =>
    shimmer.evaluate(
      (element) =>
        element.getAnimations().find((animation) => animation.effect)?.playState
    );
  await expect.poll(readPlayState).toBe("running");

  const readCurrentTime = () =>
    shimmer.evaluate((element) =>
      Number(element.getAnimations().find((animation) => animation.effect)?.currentTime)
    );

  const time = testClock();
  // A scroll pauses the sweep at once; it resumes once scrolling has been
  // idle for the scroll pause. A running sweep would move in between.
  await page.evaluate(() => window.dispatchEvent(new Event("scroll")));
  expect(await readPlayState()).toBe("paused");
  const pausedAt = await readCurrentTime();
  await time.advance(gradientShimmerMotion.scrollIdleMs - 1);
  expect(await readPlayState()).toBe("paused");
  expect(await readCurrentTime()).toBe(pausedAt);
  await time.advance(1);
  expect(await readPlayState()).toBe("running");
  await time.advanceFrames(2);
  expect(await readCurrentTime()).toBeGreaterThan(pausedAt);

  await page.evaluate(() => {
    const spacer = document.createElement("div");
    spacer.dataset.testid = "offscreen-scroll-spacer";
    spacer.style.blockSize = "1200px";
    spacer.setAttribute("aria-hidden", "true");
    document.body.append(spacer);
  });
  const scrollGeometry = await page.evaluate(() => {
    window.scrollTo(0, document.documentElement.scrollHeight);
    return {
      scrollHeight: document.documentElement.scrollHeight,
      scrollY: window.scrollY,
      viewportHeight: window.innerHeight,
    };
  });
  expect(scrollGeometry.scrollHeight).toBeGreaterThan(scrollGeometry.viewportHeight);
  expect(scrollGeometry.scrollY).toBeGreaterThan(0);
  // Past the scroll pause, the offscreen sweep stays paused.
  await time.advance(gradientShimmerMotion.scrollIdleMs);
  expect(await readPlayState()).toBe("paused");
  const offscreenAt = await readCurrentTime();
  await time.advance(gradientShimmerMotion.scrollIdleMs);
  expect(await readPlayState()).toBe("paused");
  expect(await readCurrentTime()).toBe(offscreenAt);

  await page.evaluate(() => window.scrollTo(0, 0));
  await time.advance(gradientShimmerMotion.scrollIdleMs);
  expect(await readPlayState()).toBe("running");
});

test("AI activity shimmer stays readable without motion or authored colors", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiActivityFixture));
  const osReduced = await readShimmerFallback(page);
  expect(osReduced.animationCount).toBe(0);
  expect(osReduced.readable).toBe(true);

  // A fresh page without the OS preference.
  await page.emulateMedia({ reducedMotion: "no-preference" });
  const manualPage = page;
  await manualPage.goto(`${fixtureUrl}?manualReducedMotion=1`);
  await manualPage.waitForFunction(() => Boolean(window.aiActivityFixture));
  const manualReduced = await readShimmerFallback(manualPage);
  expect(manualReduced.rootReducedMotion).toBe("true");
  expect(manualReduced.animationCount).toBe(0);
  expect(manualReduced.readable).toBe(true);

  const forcedColorsPage = page;
  await forcedColorsPage.emulateMedia({ forcedColors: "active" });
  await forcedColorsPage.goto(fixtureUrl);
  await forcedColorsPage.waitForFunction(() => Boolean(window.aiActivityFixture));
  const forcedColors = await readShimmerFallback(forcedColorsPage);
  expect(forcedColors.forcedColors).toBe(true);
  expect(forcedColors.animationCount).toBe(0);
  expect(forcedColors.backgroundImage).toBe("none");
  expect(forcedColors.textFillColor).not.toBe("rgba(0, 0, 0, 0)");
  expect(forcedColors.visibility).toBe("visible");
  expect(forcedColors.opacity).toBe(1);
  expect(forcedColors.readable).toBe(true);
});

test("failed activity card wears the chat notice frame at every copy length", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.aiActivityFixture));
  await page.evaluate(() => document.fonts.ready);

  const readCard = (testId: string) =>
    page
      .getByTestId(testId)
      .locator(".comma-ai-activity-summary-shell")
      .evaluate((shell) => {
        const column = shell.closest<HTMLElement>(
          '[data-testid="failed-card-fixture"]'
        );
        const icon = shell.querySelector<SVGElement>(".comma-chat-notice-card-icon");
        const copy = shell.querySelector<HTMLElement>(":scope > span");
        if (!column || !icon || !copy) {
          throw new Error("Failed card geometry is unavailable.");
        }
        const style = getComputedStyle(shell);
        const shellRect = shell.getBoundingClientRect();
        const iconRect = icon.getBoundingClientRect();
        const copyRect = copy.getBoundingClientRect();
        return {
          borderRadius: style.borderStartStartRadius,
          columnWidth: column.getBoundingClientRect().width,
          copyLines: Math.round(copyRect.height / Number.parseFloat(style.lineHeight)),
          height: shellRect.height,
          // Positive when the icon sits below the card's own centre line.
          iconCentreOffset:
            (iconRect.top + iconRect.bottom) / 2 -
            (shellRect.top + shellRect.bottom) / 2,
          iconCopyInlineGap: copyRect.left - iconRect.right,
          iconSize: iconRect.height,
          itemGap: Number.parseFloat(style.columnGap),
          width: shellRect.width,
        };
      });

  // Short copy: the card is the notice frame the send-failure row wears — the
  // full column at the 44px single-line height, not a chip around the words.
  const short = await readCard("failed-short-activity");
  expect(short.copyLines).toBe(1);
  expect(short.height).toBeCloseTo(44, 1);
  expect(short.width).toBeCloseTo(short.columnWidth, 1);
  expect(short.borderRadius).toBe("12px");
  expect(short.iconSize).toBeCloseTo(20, 1);
  expect(short.itemGap).toBeCloseTo(12, 1);

  // Copy that still fits the 744px chat column keeps the card identical: the
  // frame is set by the row, never by how much the activity had to say.
  const medium = await readCard("failed-medium-activity");
  expect(medium.columnWidth).toBeCloseTo(744, 1);
  expect(medium.copyLines).toBe(1);
  expect(medium.height).toBeCloseTo(short.height, 1);
  expect(medium.width).toBeCloseTo(medium.columnWidth, 1);

  // Only copy wider than the column wraps, and it wraps inside the card: the
  // card grows in height and still never exceeds the column.
  const oversized = await readCard("failed-oversized-activity");
  expect(oversized.copyLines).toBeGreaterThan(1);
  expect(oversized.width).toBeCloseTo(oversized.columnWidth, 1);
  expect(oversized.height).toBeGreaterThan(short.height);
  // The icon keeps its gap and stays centred on the card, as it does in the
  // send-failure row. If the shell itself wrapped, the copy would drop below
  // the icon and both invariants would fail.
  expect(oversized.iconCopyInlineGap).toBeCloseTo(oversized.itemGap, 1);
  expect(Math.abs(oversized.iconCentreOffset)).toBeLessThanOrEqual(0.5);
});
