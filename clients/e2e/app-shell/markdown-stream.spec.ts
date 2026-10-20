import { expect, test, type Page } from "@playwright/test";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../vite/comma-tailwind";
import { resolve } from "node:path";
import type { AddressInfo } from "node:net";
import { fileURLToPath } from "node:url";
import {
  createBuiltFixtureServer,
  type BuiltFixtureServer,
} from "../helpers/built-fixture";

const currentDir = fileURLToPath(new URL(".", import.meta.url));
const clientsRoot = resolve(currentDir, "../..");
const fixtureRoot = resolve(currentDir, "fixtures/markdown-stream");

let fixtureServer: BuiltFixtureServer | undefined;
let fixtureUrl = "";

test.beforeAll(async () => {
  fixtureServer = await createBuiltFixtureServer({
    cacheDir: resolve(clientsRoot, "node_modules/.vite/markdown-stream-e2e-test"),
    configFile: false,
    define: {
      "process.env.NODE_ENV": JSON.stringify("test"),
    },
    plugins: [react(), tailwindcss({ optimize: false }), localGroupSelectors()],
    optimizeDeps: {
      include: ["shiki"],
    },
    resolve: {
      alias: {
        "@comma/ui/styles.css": resolve(clientsRoot, "packages/ui/src/styles.css"),
        "@comma/ui": resolve(clientsRoot, "packages/ui/src"),
      },
    },
    root: fixtureRoot,
    server: {
      hmr: false,
      host: "127.0.0.1",
      port: 0,
    },
  });

  const address = fixtureServer.httpServer?.address();
  if (!address || typeof address === "string") {
    throw new Error("Markdown stream fixture server did not expose a TCP port.");
  }

  fixtureUrl = `http://127.0.0.1:${(address as AddressInfo).port}/`;
});

test.afterAll(async () => {
  await fixtureServer?.close();
});

test("very large user text collapses to one bounded destination without duplicating its surface", async ({
  page,
}) => {
  await page.goto(`${fixtureUrl}?fixture=outgoing-user-motion-fixture`);
  await page.getByTestId("outgoing-user-motion-fixture").scrollIntoViewIfNeeded();

  await beginOutgoingPerformanceProbe(page);
  const presentation = await captureCollapsedOutgoingUserPresentation(
    page,
    hugeOutgoingUserText
  );
  const performance = await finishOutgoingPerformanceProbe(page);

  const hugeTextCodePoints = Array.from(hugeOutgoingUserText).length;
  expect(hugeTextCodePoints).toBeGreaterThanOrEqual(20_000);
  expect(hugeTextCodePoints).toBeLessThanOrEqual(50_000);
  expect.soft(presentation.articleCount).toBe(1);
  expect.soft(presentation.bubbleCount).toBe(1);
  expect.soft(presentation.collapsed).toBe(true);
  expect.soft(presentation.collapsedHeight).toBeGreaterThanOrEqual(479);
  expect.soft(presentation.collapsedHeight).toBeLessThanOrEqual(481);
  expect
    .soft(presentation.fullContentHeight)
    .toBeGreaterThan(presentation.collapsedHeight * 2);
  expect.soft(presentation.destinationIdentityPreserved).toBe(true);
  expect.soft(presentation.destinationTextLength).toBe(hugeTextCodePoints);
  expect.soft(presentation.horizontalOverflow).toBeLessThanOrEqual(1);
  expect.soft(presentation.disclosureExpanded).toBe(false);
  expect.soft(presentation.disclosureControlsContent).toBe(true);
  expect.soft(presentation.disclosureHasCentralIcon).toBe(true);
  expect.soft(presentation.maximumFlyingBubbleCount).toBe(1);
  expect.soft(presentation.maximumRenderedTextCopies).toBe(1);
  expect.soft(presentation.animationIdentityPreserved).toBe(true);
  expect.soft(presentation.scrollTopRange).toBeLessThanOrEqual(1);
  expect.soft(presentation.composerIdentityPreserved).toBe(true);
  expect.soft(presentation.composerEmpty).toBe(true);
  expect.soft(presentation.composerReady).toBe(true);
  expect.soft(presentation.composerEnabled).toBe(true);
  expect.soft(presentation.agentFeedbackVisible).toBe(true);
  expect.soft(performance.bubbleFrames.length).toBeGreaterThan(4);
  // Sending lays out and parses only the head the collapsed bubble shows:
  // the clipped tail skips layout and its links stay plain text.
  expect.soft(presentation.tailStates).toEqual([true]);
  expect
    .soft(presentation.maximumLinkCount)
    .toBeLessThan(hugeOutgoingUserText.split("https://").length - 1);
  // A collapsed bubble never writes the expanded size, which restyles the text.
  expect.soft(presentation.expandedSizeWrites).toBe(0);
  expect.soft(performance.maximumAnimatedSurfaceHeight).toBeLessThanOrEqual(483);
  // One bounded sample table joins the width and travel curves. It must not
  // grow with the message length or create extra animated text surfaces.
  expect.soft(performance.maximumAnimationKeyframeCount).toBeLessThanOrEqual(192);
  expect.soft(performance.singleBubbleOwnsContent).toBe(true);
  expect.soft(performance.bubblePaintSamples).toBeGreaterThan(4);
  // The whole surface scales uniformly; text must not stretch relative to its bubble.
  expect.soft(performance.maximumContentDistortion).toBeLessThanOrEqual(0.02);
  expect.soft(performance.maximumRenderedTextCharacters).toBe(hugeTextCodePoints);
  expect
    .soft(performance.maximumDuplicateTextCharacters)
    .toBeLessThanOrEqual(hugeTextCodePoints);
  expect.soft(performance.maximumBubbleViewportOverflow).toBeLessThanOrEqual(1);
  expect.soft(performance.bubbleOverflowX).toBe("visible");
  expect.soft(performance.bubbleOverflowY).toBe("visible");
  expect.soft(presentation.bubbleIdentityPreserved).toBe(true);
  expect.soft(presentation.handoffEdgeDelta).toBeLessThanOrEqual(1);
});

test("a 480px readable summary travels continuously to the current-turn top anchor", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.getByTestId("outgoing-user-motion-fixture").scrollIntoViewIfNeeded();

  const presentation = await captureCollapsedOutgoingUserPresentation(
    page,
    hugeOutgoingUserText,
    true
  );

  expect(presentation.collapsedHeight).toBeGreaterThanOrEqual(479);
  expect(presentation.collapsedHeight).toBeLessThanOrEqual(481);
  expect(presentation.trajectorySampleCount).toBeGreaterThan(25);
  // The flight starts moving on the frame after its paused frame zero paints.
  expect.soft(presentation.startFrames).toBeLessThanOrEqual(3);
  expect.soft(presentation.longestStationaryAwayMs).toBeLessThanOrEqual(100);
  expect.soft(presentation.maximumLateFrameJump).toBeLessThanOrEqual(4);
  expect.soft(presentation.handoffEdgeDelta).toBeLessThanOrEqual(1);
});

test("continuous upward wheel input stays monotonic through diagonal and fine movement", async ({
  page,
}, testInfo) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("conversation-turn-fixture");
  await fixture.scrollIntoViewIfNeeded();
  await setConversationStage(page, "sent");
  const viewport = fixture.locator('[data-slot="scroll-area-viewport"]');
  await expect
    .poll(() =>
      viewport.evaluate((element) =>
        Math.abs(element.scrollHeight - element.clientHeight - element.scrollTop)
      )
    )
    .toBeLessThanOrEqual(1);
  const before = await viewport.evaluate((element) => element.scrollTop);
  expect(before).toBeGreaterThan(200);
  const bounds = (await viewport.boundingBox())!;
  await page.mouse.move(bounds.x + 10, bounds.y + bounds.height / 2);
  const probe = await viewport.evaluateHandle((element) => {
    const samples = [element.scrollTop];
    let frame = 0;
    const sample = () => {
      samples.push(element.scrollTop);
      frame = requestAnimationFrame(sample);
    };
    frame = requestAnimationFrame(sample);
    return { samples, stop: () => cancelAnimationFrame(frame) };
  });

  // Eight subpixel inputs must accumulate instead of disappearing at each write.
  for (let index = 0; index < 8; index += 1) {
    await page.mouse.wheel(0, -0.25);
  }
  await expect
    .poll(() => viewport.evaluate((element) => element.scrollTop))
    .toBeCloseTo(before - 2, 0);
  const deltas = [
    [80, -40],
    [0, -36],
    [-50, -28],
    [40, -16],
    [0, -8],
    [0, -4],
    [0, -2],
    [0, -1],
  ];
  let expected = before - 2;
  for (const [deltaX, deltaY] of deltas) {
    await page.mouse.wheel(deltaX!, deltaY!);
    expected += deltaY!;
    await expect
      .poll(() => viewport.evaluate((element) => element.scrollTop))
      .toBeCloseTo(expected, 0);
  }
  await page.waitForTimeout(1_100);
  const result = await probe.evaluate(({ samples, stop }) => {
    stop();
    return {
      samples,
      maxReverse: Math.max(
        0,
        ...samples.slice(1).map((top, index) => top - samples[index]!)
      ),
    };
  });
  await probe.dispose();
  await testInfo.attach("scroll-gesture-samples", {
    body: JSON.stringify({ before, expected, deltas, ...result }, null, 2),
    contentType: "application/json",
  });
  await fixture.screenshot({ path: testInfo.outputPath("scroll-after-gesture.png") });
  expect(result.samples.at(-1)).toBeCloseTo(expected, 0);
  expect(result.maxReverse).toBeLessThanOrEqual(1);
});

// Touch stays in Playwright: on Linux, touch emulation turned off again leaves
// a page without (hover: hover), which the Vitest browser project relies on.
test("coarse pointers keep the code expansion control visible", async ({ browser }) => {
  const context = await browser.newContext({
    hasTouch: true,
    viewport: { height: 800, width: 1280 },
  });
  const page = await context.newPage();

  try {
    await page.goto(fixtureUrl);
    const code = Array.from(
      { length: 37 },
      (_, index) => `const touchLine${index} = ${index}`
    ).join("\n");
    await page.waitForFunction(() => Boolean(window.markdownStreamFixture));
    await page.evaluate((content) => {
      window.markdownStreamFixture?.setContent(content, true);
    }, `\`\`\`ts\n${code}\n\`\`\``);

    expect(
      await page.evaluate(
        () =>
          matchMedia("(hover: none)").matches || matchMedia("(pointer: coarse)").matches
      )
    ).toBe(true);
    const expand = page
      .getByTestId("markdown-stream-layout-fixture")
      .getByRole("button", { name: "Expand (37 lines)" });
    await expect(expand).toHaveCSS("opacity", "1");
    await expect(expand).toHaveCSS("pointer-events", "auto");
  } finally {
    await context.close();
  }
});

async function setConversationStage(
  page: Page,
  stage: "history" | "sent" | "draft" | "draft-grown" | "final"
) {
  await page.waitForFunction(() => Boolean(window.markdownStreamFixture));
  await page.evaluate((nextStage) => {
    window.markdownStreamFixture?.setConversationStage(nextStage);
  }, stage);
}

async function captureCollapsedOutgoingUserPresentation(
  page: Page,
  text: string,
  withHistory = false
) {
  await page.waitForFunction(() => Boolean(window.markdownStreamFixture));
  return page.evaluate(
    async ({ messageText, withHistory: includeHistory }) => {
      const controller = window.markdownStreamFixture;
      const root = document.querySelector<HTMLElement>(
        "[data-testid='outgoing-user-motion-fixture']"
      );
      const composer = root?.querySelector<HTMLElement>(
        "[data-testid='outgoing-user-composer']"
      );
      const viewport = root?.querySelector<HTMLElement>(
        "[data-slot='scroll-area-viewport']"
      );
      if (!controller || !root || !composer || !viewport) {
        throw new Error("Collapsed outgoing presentation fixture was not ready.");
      }
      const collapsedOutgoingRoot = root;

      Object.assign(root.style, {
        background: "var(--color-bg-primary)",
        height: includeHistory ? "640px" : "720px",
        left: "32px",
        margin: "0",
        position: "fixed",
        top: "32px",
        width: "960px",
        zIndex: "100",
      });
      controller.resetOutgoingUser();
      controller.setOutgoingHistoryEnabled(includeHistory);
      controller.setOutgoingUserText(messageText);
      await nextFrame(2);
      viewport.scrollTop = 0;
      composer.dataset.largeOutgoingIdentity = "preserved";
      // Writes of the expanded size restyle the whole text; a collapsed
      // bubble has no use for it.
      const expandedSize = "--comma-chat-user-bubble-expanded-block-size";
      let expandedSizeWrites = 0;
      const styleObserver = new MutationObserver((records) => {
        for (const record of records) {
          if (
            (record.target as HTMLElement).style.getPropertyValue(expandedSize) ||
            record.oldValue?.includes(expandedSize)
          )
            expandedSizeWrites += 1;
        }
      });
      styleObserver.observe(root, {
        attributeFilter: ["style"],
        attributeOldValue: true,
        subtree: true,
      });
      const tailStates: boolean[] = [];
      const recordTail = (event: Event) => {
        if ((event.target as Element).matches(".comma-chat-user-bubble-tail"))
          tailStates.push((event as Event & { skipped: boolean }).skipped);
      };
      document.addEventListener("contentvisibilityautostatechange", recordTail, true);
      controller.startOutgoingUser();

      let destination: HTMLElement | null = null;
      let bubble: HTMLElement | null = null;
      let disclosure: HTMLButtonElement | null = null;
      let animation: Animation | null = null;
      let maximumFlyingBubbleCount = 0;
      let maximumRenderedTextCopies = 0;
      let maximumLinkCount = 0;
      for (let attempt = 0; attempt < 120; attempt += 1) {
        await nextFrame();
        destination = root.querySelector<HTMLElement>(
          '[data-message-id="outgoing-user-pending"]'
        );
        bubble =
          destination?.querySelector<HTMLElement>(".comma-chat-user-bubble") ?? null;
        disclosure =
          destination?.querySelector<HTMLButtonElement>(
            "button[aria-expanded][aria-controls]"
          ) ?? null;
        animation = bubble?.getAnimations()[0] ?? null;
        if (
          destination &&
          bubble?.dataset.outgoingPresentation === "flying" &&
          disclosure &&
          animation
        ) {
          break;
        }
      }
      if (!destination || !bubble || !disclosure || !animation) {
        throw new Error(
          `Very large outgoing message did not collapse: destination=${Boolean(destination)} bubble=${Boolean(bubble)} disclosure=${Boolean(disclosure)} presentation=${bubble?.dataset.outgoingPresentation ?? "missing"} animations=${bubble?.getAnimations().length ?? 0}.`
        );
      }

      const controlsId = disclosure.getAttribute("aria-controls");
      const content = controlsId ? document.getElementById(controlsId) : null;
      const input = composer.querySelector<HTMLInputElement>("input");
      if (!content || !input) {
        throw new Error("Collapsed outgoing content or reusable composer was missing.");
      }
      const contentText = content.textContent;

      const destinationNode = destination;
      const bubbleNode = bubble;
      const animationNode = animation;
      let animationIdentityPreserved = true;
      destination.dataset.largeOutgoingIdentity = "preserved";
      bubble.dataset.largeOutgoingBubbleIdentity = "preserved";
      // The test drives the flight's clock. Once the flight starts, its
      // animations pause and advance one 60 Hz frame per rendered frame, so
      // the trajectory is the same however fast the machine renders.
      // The paused frame zero paints, then the flight starts moving.
      let startFrames = 0;
      while (startFrames < 120 && animation.playState !== "running") {
        await nextFrame();
        startFrames += 1;
      }
      const driven = document
        .getAnimations()
        .filter((candidate) => candidate.playState === "running");
      const origins = driven.map((candidate) => Number(candidate.currentTime ?? 0));
      for (const candidate of driven) candidate.pause();
      const flightEnd = Number(animation.effect?.getComputedTiming().endTime ?? 0);
      let driving = true;
      let clock = 0;
      const tick = async () => {
        clock += 1000 / 60;
        if (driving && origins[driven.indexOf(animationNode)]! + clock >= flightEnd) {
          // The flight has reached its end: finish it and resume the rest.
          // (play() would rewind a finished animation to its start.)
          driving = false;
          for (const candidate of driven) {
            if (Number.isFinite(candidate.effect?.getComputedTiming().endTime))
              candidate.finish();
            else candidate.play();
          }
        } else if (driving) {
          driven.forEach((candidate, index) => {
            candidate.currentTime = origins[index]! + clock;
          });
        }
        await nextFrame();
      };
      const trajectory: Array<{
        bottom: number;
        elapsedMs: number;
        top: number;
      }> = [];
      const scrollSamples = [viewport.scrollTop];
      let lastFlyingFrame: ReturnType<typeof plainRect> | null = null;
      sampleVisibleSurface();
      for (let index = 0; index < 18; index += 1) {
        await tick();
        sampleVisibleSurface();
        scrollSamples.push(viewport.scrollTop);
      }

      controller.ackOutgoingUser();
      // The clock waits for the acknowledgement to commit.
      for (
        let attempt = 0;
        attempt < 1000 &&
        destinationNode.dataset.messageId !== "outgoing-user-canonical";
        attempt += 1
      ) {
        await new Promise((resolveTask) => setTimeout(resolveTask, 0));
      }
      for (let attempt = 0; attempt < 120; attempt += 1) {
        sampleVisibleSurface();
        const currentBubble = destinationNode.querySelector<HTMLElement>(
          ".comma-chat-user-bubble"
        );
        if (currentBubble?.dataset.outgoingPresentation !== "flying") break;
        await tick();
        scrollSamples.push(viewport.scrollTop);
      }
      styleObserver.disconnect();
      document.removeEventListener(
        "contentvisibilityautostatechange",
        recordTail,
        true
      );
      if (destinationNode.querySelector('[data-outgoing-presentation="flying"]')) {
        throw new Error("Very large outgoing spring did not complete.");
      }
      await nextFrame(2);
      const canonical = root.querySelector<HTMLElement>(
        '[data-message-id="outgoing-user-canonical"]'
      );
      const canonicalBubble = canonical?.querySelector<HTMLElement>(
        ".comma-chat-user-bubble"
      );
      const canonicalDisclosure = canonical?.querySelector<HTMLButtonElement>(
        "button[aria-expanded][aria-controls]"
      );
      const feedback = root.querySelector<HTMLElement>(
        "[data-testid='outgoing-agent-feedback']"
      );
      if (
        !canonical ||
        !canonicalBubble ||
        !canonicalDisclosure ||
        !feedback ||
        !lastFlyingFrame
      ) {
        throw new Error("Collapsed outgoing message did not survive ACK.");
      }
      const feedbackFrame = feedback.getBoundingClientRect();
      const viewportFrame = viewport.getBoundingClientRect();
      const canonicalBubbleFrame = plainRect(canonicalBubble.getBoundingClientRect());
      trajectory.push({
        bottom: canonicalBubbleFrame.bottom,
        elapsedMs: clock,
        top: canonicalBubbleFrame.top,
      });
      const trajectorySteps = trajectory.slice(1).map((sample, index) => {
        const previous = trajectory[index]!;
        return {
          elapsedMs: sample.elapsedMs,
          magnitude: Math.max(
            Math.abs(sample.bottom - previous.bottom),
            Math.abs(sample.top - previous.top)
          ),
        };
      });
      let currentStationaryAwayMs = 0;
      let longestStationaryAwayMs = 0;
      for (let index = 1; index < trajectory.length; index += 1) {
        const previous = trajectory[index - 1]!;
        const sample = trajectory[index]!;
        const step = trajectorySteps[index - 1]?.magnitude ?? 0;
        const awayFromFinal = Math.abs(sample.top - canonicalBubbleFrame.top) > 8;
        if (awayFromFinal && step < 0.5) {
          currentStationaryAwayMs += sample.elapsedMs - previous.elapsedMs;
          longestStationaryAwayMs = Math.max(
            longestStationaryAwayMs,
            currentStationaryAwayMs
          );
        } else {
          currentStationaryAwayMs = 0;
        }
      }

      return {
        agentFeedbackVisible:
          feedbackFrame.top >= viewportFrame.top - 1 &&
          feedbackFrame.bottom <= viewportFrame.bottom + 1,
        articleCount: root.querySelectorAll(".comma-chat-message-user").length,
        bubbleCount: root.querySelectorAll(
          ".comma-chat-message-user .comma-chat-user-bubble"
        ).length,
        bubbleIdentityPreserved:
          canonicalBubble === bubbleNode &&
          canonicalBubble.dataset.largeOutgoingBubbleIdentity === "preserved",
        collapsed: canonicalDisclosure.getAttribute("aria-expanded") === "false",
        collapsedHeight: canonicalBubble.getBoundingClientRect().height,
        composerEmpty: composer.dataset.empty === "true",
        composerEnabled: !input.disabled,
        composerIdentityPreserved:
          root.querySelector("[data-testid='outgoing-user-composer']") === composer &&
          composer.dataset.largeOutgoingIdentity === "preserved",
        composerReady: composer.dataset.ready === "true",
        destinationIdentityPreserved:
          canonical === destinationNode &&
          canonical.dataset.largeOutgoingIdentity === "preserved",
        destinationTextLength: Array.from(content.textContent ?? "").length,
        disclosureControlsContent:
          canonicalDisclosure.getAttribute("aria-controls") === content.id,
        disclosureExpanded:
          canonicalDisclosure.getAttribute("aria-expanded") === "true",
        disclosureHasCentralIcon: Boolean(
          canonicalDisclosure.querySelector("[data-comma-icon][aria-hidden='true']")
        ),
        fullContentHeight: content.scrollHeight,
        handoffEdgeDelta: frameDelta(lastFlyingFrame, canonicalBubbleFrame),
        horizontalOverflow: Math.max(
          0,
          canonicalBubble.scrollWidth - canonicalBubble.clientWidth
        ),
        animationIdentityPreserved,
        expandedSizeWrites,
        maximumLinkCount,
        startFrames,
        tailStates,
        maximumFlyingBubbleCount,
        maximumRenderedTextCopies,
        longestStationaryAwayMs,
        maximumLateFrameJump: Math.max(
          0,
          ...trajectorySteps
            .filter((sample) => sample.elapsedMs >= 500)
            .map((sample) => sample.magnitude)
        ),
        scrollTopRange: Math.max(...scrollSamples) - Math.min(...scrollSamples),
        trajectorySampleCount: trajectory.length,
        viewportHeight: viewportFrame.height,
      };

      function sampleVisibleSurface() {
        const outgoingArticle =
          collapsedOutgoingRoot.querySelector<HTMLElement>(
            '[data-message-id="outgoing-user-pending"]'
          ) ??
          collapsedOutgoingRoot.querySelector<HTMLElement>(
            '[data-message-id="outgoing-user-canonical"]'
          );
        const visibleSurface = outgoingArticle?.querySelector<HTMLElement>(
          ".comma-chat-user-bubble"
        );
        if (!visibleSurface) return;
        const allBubbles = [
          ...collapsedOutgoingRoot.querySelectorAll<HTMLElement>(
            ".comma-chat-user-bubble"
          ),
        ];
        maximumFlyingBubbleCount = Math.max(
          maximumFlyingBubbleCount,
          collapsedOutgoingRoot.querySelectorAll(
            '.comma-chat-user-bubble[data-outgoing-presentation="flying"]'
          ).length
        );
        maximumRenderedTextCopies = Math.max(
          maximumRenderedTextCopies,
          allBubbles.filter(
            (candidate) =>
              candidate.querySelector(".comma-chat-user-bubble-content")
                ?.textContent === contentText
          ).length
        );
        if (visibleSurface.dataset.outgoingPresentation === "flying") {
          lastFlyingFrame = plainRect(visibleSurface.getBoundingClientRect());
          // While the test drives the clock, nothing restarts the flight.
          animationIdentityPreserved &&=
            visibleSurface === bubbleNode &&
            visibleSurface.getAnimations()[0] === animationNode &&
            (!driving || animationNode.playState === "paused");
          maximumLinkCount = Math.max(
            maximumLinkCount,
            visibleSurface.querySelectorAll(".comma-chat-user-bubble-content a").length
          );
        }
        const frame = visibleSurface.getBoundingClientRect();
        trajectory.push({
          bottom: frame.bottom,
          elapsedMs: clock,
          top: frame.top,
        });
      }

      // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
      function plainRect(rect: DOMRect) {
        return {
          bottom: rect.bottom,
          left: rect.left,
          right: rect.right,
          top: rect.top,
        };
      }

      // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
      function frameDelta(
        first: Pick<DOMRect, "bottom" | "left" | "right" | "top">,
        second: Pick<DOMRect, "bottom" | "left" | "right" | "top">
      ) {
        return Math.max(
          Math.abs(first.bottom - second.bottom),
          Math.abs(first.left - second.left),
          Math.abs(first.right - second.right),
          Math.abs(first.top - second.top)
        );
      }

      // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
      async function nextFrame(count = 1) {
        for (let index = 0; index < count; index += 1) {
          await new Promise<void>((resolveFrame) =>
            requestAnimationFrame(() => resolveFrame())
          );
        }
      }
    },
    { messageText: text, withHistory }
  );
}

type OutgoingPerformanceProbe = {
  animationKeyframeCounts: number[];
  bubbleFrames: Array<{
    bottom: number;
    composerOverlapHeight: number;
    height: number;
    threadOverlapHeight: number;
    top: number;
  }>;
  bubbleOverflowX: string;
  bubbleOverflowY: string;
  bubblePaintSamples: number;
  maximumAnimationKeyframeCount: number;
  maximumAnimatedSurfaceHeight: number;
  maximumBubbleViewportOverflow: number;
  maximumDuplicateTextCharacters: number;
  maximumRenderedTextCharacters: number;
  maximumContentDistortion: number;
  singleBubbleOwnsContent: boolean;
};

type OutgoingPerformanceProbeState = Omit<
  OutgoingPerformanceProbe,
  "maximumAnimationKeyframeCount"
> & {
  rafId: number;
};

type OutgoingPerformanceProbeWindow = Window & {
  commaOutgoingPerformanceProbe?: OutgoingPerformanceProbeState | undefined;
};

async function beginOutgoingPerformanceProbe(page: Page) {
  await page.evaluate(() => {
    const probeWindow = window as OutgoingPerformanceProbeWindow;
    const previous = probeWindow.commaOutgoingPerformanceProbe;
    if (previous) cancelAnimationFrame(previous.rafId);

    const state: OutgoingPerformanceProbeState = {
      animationKeyframeCounts: [],
      bubbleFrames: [],
      bubbleOverflowX: "",
      bubbleOverflowY: "",
      bubblePaintSamples: 0,
      maximumAnimatedSurfaceHeight: 0,
      maximumBubbleViewportOverflow: 0,
      maximumDuplicateTextCharacters: 0,
      maximumRenderedTextCharacters: 0,
      maximumContentDistortion: 0,
      rafId: 0,
      singleBubbleOwnsContent: true,
    };

    const sample = () => {
      const root = document.querySelector<HTMLElement>(
        "[data-testid='outgoing-user-motion-fixture']"
      );
      const bubble = root?.querySelector<HTMLElement>(
        '.comma-chat-user-bubble[data-outgoing-presentation="flying"]'
      );
      if (bubble) {
        const frame = bubble.getBoundingClientRect();
        const bubbleStyles = getComputedStyle(bubble);
        state.maximumAnimatedSurfaceHeight = Math.max(
          state.maximumAnimatedSurfaceHeight,
          frame.height
        );
        state.bubbleOverflowX = bubbleStyles.overflowX;
        state.bubbleOverflowY = bubbleStyles.overflowY;
        const content = bubble.querySelector<HTMLElement>(
          ".comma-chat-user-bubble-content"
        );
        if (content) {
          state.bubblePaintSamples += 1;
          state.singleBubbleOwnsContent &&=
            content.parentElement === bubble &&
            bubbleStyles.clipPath.startsWith("inset(") &&
            root?.querySelectorAll(".comma-chat-user-bubble").length === 1;
          const contentFrame = content.getBoundingClientRect();
          if (content.offsetWidth > 0 && content.offsetHeight > 0) {
            state.maximumContentDistortion = Math.max(
              state.maximumContentDistortion,
              Math.abs(
                contentFrame.width / content.offsetWidth -
                  new DOMMatrixReadOnly(bubbleStyles.transform).a
              ),
              Math.abs(
                contentFrame.height / content.offsetHeight -
                  new DOMMatrixReadOnly(bubbleStyles.transform).d
              )
            );
          }
        }
        const rootFrame = root?.getBoundingClientRect();
        if (rootFrame) {
          state.maximumBubbleViewportOverflow = Math.max(
            state.maximumBubbleViewportOverflow,
            rootFrame.left - frame.left,
            frame.right - rootFrame.right,
            rootFrame.top - frame.top,
            frame.bottom - rootFrame.bottom,
            0
          );
        }
        const composerFrame = root
          ?.querySelector<HTMLElement>("[data-testid='outgoing-user-composer']")
          ?.getBoundingClientRect();
        const threadFrame = root
          ?.querySelector<HTMLElement>("[data-slot='scroll-area-viewport']")
          ?.getBoundingClientRect();
        state.bubbleFrames.push({
          bottom: frame.bottom,
          composerOverlapHeight: composerFrame
            ? intersectionLength(
                frame.top,
                frame.bottom,
                composerFrame.top,
                composerFrame.bottom
              )
            : 0,
          height: frame.height,
          threadOverlapHeight: threadFrame
            ? intersectionLength(
                frame.top,
                frame.bottom,
                threadFrame.top,
                threadFrame.bottom
              )
            : 0,
          top: frame.top,
        });
      }
      const outgoingAnimations = (root?.getAnimations({ subtree: true }) ?? []).filter(
        (animation) => {
          const effect = animation.effect;
          const target = effect instanceof KeyframeEffect ? effect.target : null;
          return (
            target instanceof HTMLElement &&
            Boolean(
              target.closest(
                "[data-message-id='outgoing-user-pending'], [data-message-id='outgoing-user-canonical']"
              )
            )
          );
        }
      );
      for (const animation of outgoingAnimations) {
        const effect = animation.effect;
        if (!(effect instanceof KeyframeEffect)) continue;
        state.animationKeyframeCounts.push(effect.getKeyframes().length);
      }
      const renderedTextCharacters = [
        ...(root?.querySelectorAll<HTMLElement>(".comma-chat-user-bubble-content") ??
          []),
      ].reduce(
        (total, element) => total + Array.from(element.textContent ?? "").length,
        0
      );
      state.maximumDuplicateTextCharacters = Math.max(
        state.maximumDuplicateTextCharacters,
        renderedTextCharacters
      );
      state.maximumRenderedTextCharacters = Math.max(
        state.maximumRenderedTextCharacters,
        renderedTextCharacters
      );
      state.rafId = requestAnimationFrame(sample);
    };

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- this helper must be serialized with page.evaluate.
    const intersectionLength = (
      firstStart: number,
      firstEnd: number,
      secondStart: number,
      secondEnd: number
    ) => Math.max(0, Math.min(firstEnd, secondEnd) - Math.max(firstStart, secondStart));

    state.rafId = requestAnimationFrame(sample);
    probeWindow.commaOutgoingPerformanceProbe = state;
  });
}

async function finishOutgoingPerformanceProbe(
  page: Page
): Promise<OutgoingPerformanceProbe> {
  return page.evaluate(() => {
    const probeWindow = window as OutgoingPerformanceProbeWindow;
    const state = probeWindow.commaOutgoingPerformanceProbe;
    if (!state) {
      throw new Error("The outgoing performance probe was not started.");
    }
    cancelAnimationFrame(state.rafId);
    delete probeWindow.commaOutgoingPerformanceProbe;
    return {
      animationKeyframeCounts: state.animationKeyframeCounts,
      bubbleFrames: state.bubbleFrames,
      bubbleOverflowX: state.bubbleOverflowX,
      bubbleOverflowY: state.bubbleOverflowY,
      bubblePaintSamples: state.bubblePaintSamples,
      maximumAnimationKeyframeCount: Math.max(0, ...state.animationKeyframeCounts),
      maximumAnimatedSurfaceHeight: state.maximumAnimatedSurfaceHeight,
      maximumBubbleViewportOverflow: state.maximumBubbleViewportOverflow,
      maximumDuplicateTextCharacters: state.maximumDuplicateTextCharacters,
      maximumRenderedTextCharacters: state.maximumRenderedTextCharacters,
      maximumContentDistortion: state.maximumContentDistortion,
      singleBubbleOwnsContent: state.singleBubbleOwnsContent,
    };
  });
}

const hugeOutgoingUserText = Array.from({ length: 48 }, (_, index) =>
  [
    `第 ${index + 1} 段：大段混合 CJK 内容在发送、飞行、回摆和落位时都不能与输入框互相裁剪，也不能造成明显掉帧。`,
    `/Users/example/Library/Application Support/Comma/conversations/${index}/${"UnbrokenPathSegment".repeat(10)}`,
    `https://example.com/chat/${index}?payload=${"0123456789ABCDEF".repeat(8)}`,
  ].join(" ")
).join("\n");
