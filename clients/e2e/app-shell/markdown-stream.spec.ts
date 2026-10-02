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
import { parseCssColor, type CssRgbaColor } from "../helpers/css-color";

const currentDir = fileURLToPath(new URL(".", import.meta.url));
const clientsRoot = resolve(currentDir, "../..");
const fixtureRoot = resolve(currentDir, "fixtures/markdown-stream");

let fixtureServer: BuiltFixtureServer | undefined;
let fixtureUrl = "";

test.beforeAll(async () => {
  fixtureServer = await createBuiltFixtureServer({
    cacheDir: resolve(clientsRoot, "node_modules/.vite/markdown-stream-e2e"),
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
        "@comma/ui": resolve(clientsRoot, "packages/ui/src/index.ts"),
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

test("sending preserves history position through the first painted animation frame", async ({
  page,
}) => {
  await page.goto(`${fixtureUrl}?fixture=outgoing-user-motion-fixture`);
  const samples = await page.evaluate(async () => {
    const controller = window.markdownStreamFixture!;
    const root = document.querySelector<HTMLElement>(
      "[data-testid='outgoing-user-motion-fixture']"
    )!;
    Object.assign(root.style, {
      position: "fixed",
      top: "0",
      left: "0",
      margin: "0",
      height: "720px",
      width: "960px",
    });
    controller.setOutgoingHistoryEnabled(true);
    controller.setOutgoingUserText("111");
    await new Promise((finish) => setTimeout(finish, 250));
    const viewport = root.querySelector<HTMLElement>(
      "[data-slot='scroll-area-viewport']"
    )!;
    viewport.scrollTop = viewport.scrollHeight;
    await new Promise((finish) => setTimeout(finish, 100));
    const history = root.querySelector<HTMLElement>(
      "[data-message-id='turn-history-assistant-5']"
    );
    if (!history) throw new Error("The last history reply is missing.");
    const frames = [{ top: history.getBoundingClientRect().top, phase: "before" }];
    controller.startOutgoingUser();
    for (let index = 0; index < 35; index += 1) {
      await new Promise<void>((finish) =>
        requestAnimationFrame(() => {
          setTimeout(finish, 0);
        })
      );
      if (!history.isConnected) throw new Error("The history reply was replaced.");
      frames.push({
        top: history.getBoundingClientRect().top,
        phase:
          root.querySelector<HTMLElement>(
            ".comma-chat-user-bubble[data-outgoing-presentation]"
          )?.dataset.outgoingPresentation ?? "settled",
      });
    }
    return frames;
  });
  await test.info().attach("send-history-frames", {
    body: JSON.stringify(samples),
    contentType: "application/json",
  });
  expect(samples.some((sample) => sample.phase === "flying")).toBe(true);
  // History may move up to make room, but must not jump down again at launch.
  const downwardSteps = samples
    .slice(1)
    .map((sample, index) => sample.top - samples[index]!.top);
  expect(Math.max(...downwardSteps), JSON.stringify(samples)).toBeLessThanOrEqual(1);
});

for (const variant of ["route", "side-chat"] as const) {
  for (const compact of [false, true]) {
    test(`${variant} ${compact ? "compact" : "overflowing"} bubble reaches its final landing without a second upward correction`, async ({
      page,
    }) => {
      await page.goto(`${fixtureUrl}${compact ? "?compactHistory" : ""}`);
      const fixture = page.getByTestId(`delayed-activity-outgoing-${variant}-fixture`);
      await fixture.getByRole("textbox").fill("111");
      const frames = await page.evaluate(async (surfaceVariant) => {
        const controller =
          window.delayedOutgoingActivityFixture![
            surfaceVariant === "route" ? "route" : "sideChat"
          ]!;
        const root = document.querySelector<HTMLElement>(
          `[data-testid='delayed-activity-outgoing-${surfaceVariant}-fixture']`
        )!;
        Object.assign(root.style, {
          position: "fixed",
          top: "0",
          left: "0",
          margin: "0",
          height: "720px",
          width: "960px",
        });
        await new Promise((finish) => setTimeout(finish, 250));
        const viewport = root.querySelector<HTMLElement>(
          "[data-slot='scroll-area-viewport']"
        )!;
        viewport.scrollTop = viewport.scrollHeight;
        await new Promise((finish) => setTimeout(finish, 100));
        const samples: {
          phase: string;
          bottom: number;
          baseY: number;
          correction: string;
          scrollTop: number;
          time: number;
        }[] = [];
        controller.start();
        for (let index = 0; index < 220; index += 1) {
          await new Promise<void>((finish) =>
            requestAnimationFrame(() => {
              setTimeout(finish, 0);
            })
          );
          const bubble = root.querySelector<HTMLElement>(
            `[data-message-id='delayed-activity-${surfaceVariant}-pending'] .comma-chat-user-bubble`
          );
          if (!bubble) continue;
          const style = getComputedStyle(bubble);
          samples.push({
            phase: bubble.dataset.outgoingPresentation ?? "settled",
            bottom: bubble.getBoundingClientRect().bottom,
            baseY: new DOMMatrix(style.transform).m42,
            correction: style.translate,
            scrollTop: viewport.scrollTop,
            time: Number(bubble.getAnimations()[0]?.currentTime ?? 0),
          });
        }
        return samples;
      }, variant);
      await test.info().attach("bubble-landing-frames", {
        body: JSON.stringify(frames),
        contentType: "application/json",
      });
      const final = frames.at(-1)!;
      expect(final.phase).toBe("settled");
      const flight = frames.filter((frame) => frame.phase === "flying");
      expect(
        Math.max(
          ...flight.map((frame) => Math.abs(frame.bottom - frame.baseY - final.bottom))
        ),
        JSON.stringify(frames)
      ).toBeLessThanOrEqual(2);
      const late = frames.filter(
        (frame) => frame.phase === "flying" && Math.abs(frame.baseY) <= 1
      );
      expect(late.length).toBeGreaterThan(0);
      expect(
        Math.max(...late.map((frame) => Math.abs(frame.bottom - final.bottom))),
        JSON.stringify(frames)
      ).toBeLessThanOrEqual(2);
    });
  }
}

for (const delay of [120, 1400]) {
  test(`consecutive send after ${delay}ms reaches its final landing`, async ({
    page,
  }) => {
    await page.goto(`${fixtureUrl}?fixture=outgoing-user-motion-fixture`);
    const frames = await page.evaluate(async (sendDelay) => {
      const controller = window.markdownStreamFixture!;
      const root = document.querySelector<HTMLElement>(
        "[data-testid='outgoing-user-motion-fixture']"
      )!;
      controller.setOutgoingHistoryEnabled(true);
      controller.setOutgoingUserText("111");
      Object.assign(root.style, {
        position: "fixed",
        top: "0",
        left: "0",
        margin: "0",
        height: "720px",
        width: "960px",
      });
      await new Promise((finish) => setTimeout(finish, 250));
      const viewport = root.querySelector<HTMLElement>(
        "[data-slot='scroll-area-viewport']"
      )!;
      viewport.scrollTop = viewport.scrollHeight;
      await new Promise((finish) => setTimeout(finish, 100));
      const samples: {
        phase: string;
        bottom: number;
        baseY: number;
        correction: string;
        scrollTop: number;
        time: number;
      }[] = [];
      controller.startOutgoingUser();
      await new Promise((finish) => setTimeout(finish, sendDelay));
      controller.ackOutgoingUser();
      controller.setOutgoingUserText("another short message");
      await new Promise((finish) => setTimeout(finish, 50));
      controller.startOutgoingUser();
      for (let index = 0; index < 220; index += 1) {
        await new Promise<void>((finish) =>
          requestAnimationFrame(() => {
            setTimeout(finish, 0);
          })
        );
        const bubble = root.querySelector<HTMLElement>(
          "[data-message-id='outgoing-user-2-pending'] .comma-chat-user-bubble"
        );
        if (!bubble) continue;
        const style = getComputedStyle(bubble);
        samples.push({
          phase: bubble.dataset.outgoingPresentation ?? "settled",
          bottom: bubble.getBoundingClientRect().bottom,
          baseY: new DOMMatrix(style.transform).m42,
          correction: style.translate,
          scrollTop: viewport.scrollTop,
          time: Number(bubble.getAnimations()[0]?.currentTime ?? 0),
        });
      }
      return samples;
    }, delay);
    await test.info().attach("bubble-landing-frames", {
      body: JSON.stringify(frames),
      contentType: "application/json",
    });
    const final = frames.at(-1)!;
    expect(final.phase).toBe("settled");
    const flight = frames.filter((frame) => frame.phase === "flying");
    // The previous bubble can still move the layout while both flights run.
    // Retargeting is expected then; check the landing once this flight arrives.
    const landing = flight.at(-1)!;
    expect(flight.length).toBeGreaterThan(0);
    expect(Math.abs(landing.baseY)).toBeLessThanOrEqual(1);
    expect(
      Math.abs(landing.bottom - final.bottom),
      JSON.stringify(frames)
    ).toBeLessThanOrEqual(2);
  });
}

test("scrolling up during send still loads older history", async ({ page }) => {
  await page.goto(`${fixtureUrl}?extendedHistory`);
  const fixture = page.getByTestId("delayed-activity-outgoing-route-fixture");
  await fixture.evaluate((root) =>
    Object.assign((root as HTMLElement).style, {
      position: "fixed",
      top: "0",
      left: "0",
      margin: "0",
      height: "720px",
      width: "960px",
    })
  );
  await fixture.getByRole("textbox").fill("111");
  const thread = fixture.locator(".comma-chat-thread");
  const hidden = Number(await thread.getAttribute("data-comma-hidden-older-count"));
  expect(hidden).toBeGreaterThan(0);
  await fixture.getByRole("button", { name: "Send message", exact: true }).click();
  const flying = fixture.locator('[data-outgoing-presentation="flying"]');
  await expect(flying).toHaveCount(1);
  await fixture.evaluate((root) => {
    for (const animation of root.getAnimations({ subtree: true })) animation.pause();
  });
  const viewport = fixture.locator('[data-slot="scroll-area-viewport"]').first();
  await viewport.hover();
  const scrollDistance = await viewport.evaluate((element) => element.scrollHeight);
  await page.mouse.wheel(0, -scrollDistance);
  await expect
    .poll(async () =>
      Number(await thread.getAttribute("data-comma-hidden-older-count"))
    )
    .toBeLessThan(hidden);
  await expect(flying).toHaveCount(1);
});

test("history fills a resized viewport without a new message", async ({ page }) => {
  await page.goto(`${fixtureUrl}?extendedHistory`);
  const fixture = page.getByTestId("delayed-activity-outgoing-route-fixture");
  const thread = fixture.locator(".comma-chat-thread");
  await expect(thread.locator("article[data-message-id]").last()).toBeVisible();
  const hidden = Number(await thread.getAttribute("data-comma-hidden-older-count"));
  expect(hidden).toBeGreaterThan(0);
  await fixture.evaluate((root) => {
    (root as HTMLElement).style.height = "6000px";
  });
  await expect
    .poll(async () =>
      Number(await thread.getAttribute("data-comma-hidden-older-count"))
    )
    .toBeLessThan(hidden);
});

test("history fills a resized viewport after the outgoing flight ends", async ({
  page,
}) => {
  await page.goto(`${fixtureUrl}?extendedHistory`);
  const fixture = page.getByTestId("delayed-activity-outgoing-route-fixture");
  await fixture.evaluate((root) =>
    Object.assign((root as HTMLElement).style, {
      position: "fixed",
      top: "0",
      left: "0",
      margin: "0",
      height: "720px",
      width: "960px",
    })
  );
  await fixture.getByRole("textbox").fill("111");
  await fixture.getByRole("button", { name: "Send message", exact: true }).click();
  const flying = fixture.locator('[data-outgoing-presentation="flying"]');
  await expect(flying).toHaveCount(1);
  const thread = fixture.locator(".comma-chat-thread");
  const hidden = Number(await thread.getAttribute("data-comma-hidden-older-count"));
  expect(hidden).toBeGreaterThan(0);
  await fixture.evaluate((root) => {
    (root as HTMLElement).style.height = "6000px";
  });
  await expect(flying).toHaveCount(0);
  await expect
    .poll(async () =>
      Number(await thread.getAttribute("data-comma-hidden-older-count"))
    )
    .toBeLessThan(hidden);
});

test("generated files retain their metadata without inline download controls", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const main = page.getByTestId("generated-file-download-main-fixture");
  const sideChat = page.getByTestId("generated-file-download-side-chat-fixture");

  for (const surface of [main, sideChat]) {
    await expect(surface.locator(".chat-panel-file")).toContainText(
      "generated-report.pdf"
    );
    await expect(surface.getByRole("button", { name: "Download" })).toHaveCount(0);
  }
});

test("markdown stream renders complete blur and enhanced markdown blocks in a browser", async ({
  page,
}) => {
  test.setTimeout(60_000);

  await page.goto(fixtureUrl);

  const fixture = page.getByTestId("markdown-stream-fixture");
  await expect(
    fixture.getByRole("heading", { name: "Streaming Markdown Fixture" })
  ).toBeVisible();

  await setMarkdownScenarioAndObserveAnimation(page, "full");

  await expect(fixture).not.toContainText("final sentinel");

  await expect(fixture.locator("del")).toContainText("deleted text", {
    timeout: 12_000,
  });
  await expect(fixture.locator("del")).toHaveCSS(
    "text-decoration-line",
    /line-through/
  );
  await expect(fixture.locator("mark")).toContainText("highlighted text");
  await expect(fixture.locator("ins")).toContainText("inserted text");

  await expect(fixture.getByText("tsx")).toBeVisible();
  await expect(fixture.locator(".markdown-stream-code-body")).toContainText(
    "MarkdownStatus"
  );
  await fixture.locator(".markdown-stream-code-body").scrollIntoViewIfNeeded();
  await expect(
    fixture.locator(
      ".markdown-stream-code-body .code-block-render:not(.code-block-render-pending)"
    )
  ).toBeVisible({ timeout: 20_000 });

  await expect(fixture.locator(".markdown-stream-mermaid-svg svg")).toBeVisible({
    timeout: 20_000,
  });
  await expect(fixture.locator(".katex").first()).toBeVisible();
  await setMarkdownScenario(page, "final");
  await expect(fixture).toContainText("final sentinel", { timeout: 12_000 });
});

test("reduced motion does not replay already visible stream glyphs", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto(fixtureUrl);

  const fixture = page.getByTestId("markdown-stream-fixture");
  const stream = fixture.locator(".markdown-stream");
  const reducedContent = `${"Reduced motion keeps this streamed tail settled. ".repeat(
    8
  )}Reduced tail complete.`;
  await setMarkdownContent(page, reducedContent, false);
  await expect(stream).toContainText("Reduced tail complete.", { timeout: 12_000 });
  await expect
    .poll(() => stream.locator(".markdown-stream-char-glyph").count())
    .toBeGreaterThan(0);
  await expect(stream.locator(".markdown-stream-char-enter")).toHaveCount(0);

  const existingGlyphs = await stream.evaluate((root) => {
    const glyphs = root.querySelectorAll<HTMLElement>(".markdown-stream-char-glyph");
    glyphs.forEach((glyph) => {
      glyph.dataset.reducedMotionExisting = "true";
    });
    root.setAttribute("data-reduced-motion-animation-starts", "0");
    root.addEventListener("animationstart", (event) => {
      const target = event.target;
      if (
        !(target instanceof HTMLElement) ||
        target.dataset.reducedMotionExisting !== "true"
      ) {
        return;
      }
      const starts = Number(
        root.getAttribute("data-reduced-motion-animation-starts") ?? "0"
      );
      root.setAttribute("data-reduced-motion-animation-starts", String(starts + 1));
    });
    return glyphs.length;
  });
  expect(existingGlyphs).toBeGreaterThan(0);

  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.evaluate(
    () =>
      new Promise<void>((resolveAfterPaint) => {
        requestAnimationFrame(() =>
          requestAnimationFrame(() => setTimeout(resolveAfterPaint, 50))
        );
      })
  );

  expect(
    await stream.evaluate((root) => {
      const glyphs = Array.from(
        root.querySelectorAll<HTMLElement>('[data-reduced-motion-existing="true"]')
      );
      return {
        animatedGlyphs: glyphs.filter((glyph) =>
          glyph.classList.contains("markdown-stream-char-enter")
        ).length,
        animationStarts: Number(
          root.getAttribute("data-reduced-motion-animation-starts") ?? "0"
        ),
        allOpaque: glyphs.every(
          (glyph) => Number.parseFloat(getComputedStyle(glyph).opacity) >= 0.99
        ),
      };
    })
  ).toEqual({ animatedGlyphs: 0, animationStarts: 0, allOpaque: true });

  await page.evaluate(() => {
    document.documentElement.setAttribute("data-comma-reduced-motion", "true");
  });
  const manualReducedContent = `${"Manual reduced motion settles immediately. ".repeat(
    6
  )}Manual reduced tail complete.`;
  await setMarkdownContent(page, manualReducedContent, false);
  await expect(stream).toContainText("Manual reduced tail complete.", {
    timeout: 12_000,
  });
  await expect(stream.locator(".markdown-stream-char-enter")).toHaveCount(0);
});

test("a same-stream non-prefix retarget never collapses to near-empty Markdown", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("markdown-stream-fixture");

  await setMarkdownScenario(page, "retarget-a");
  await expect(fixture).toContainText("RETARGET_A_READY", { timeout: 12_000 });
  const oldReadableCharacters = await fixture.evaluate(
    (element) => element.textContent?.trim().length ?? 0
  );
  expect(oldReadableCharacters).toBeGreaterThan(300);

  const retarget = await page.evaluate(async () => {
    const fixtureElement = document.querySelector<HTMLElement>(
      "[data-testid='markdown-stream-fixture']"
    );
    if (!fixtureElement || !window.markdownStreamFixture) {
      throw new Error("Markdown stream retarget fixture was not ready.");
    }

    const startedAt = performance.now();
    const samples: Array<{
      elapsedMs: number;
      streamRoots: number;
      text: string;
    }> = [];
    window.markdownStreamFixture.setScenario("retarget-b");

    return await new Promise<{
      samples: Array<{ elapsedMs: number; streamRoots: number; text: string }>;
      timedOut: boolean;
    }>((resolveRetarget) => {
      const readFrame = () => {
        const text = fixtureElement.textContent?.trim() ?? "";
        const elapsedMs = performance.now() - startedAt;
        samples.push({
          elapsedMs,
          streamRoots: fixtureElement.querySelectorAll(".markdown-stream").length,
          text,
        });
        if (text.includes("RETARGET_B_READY") || elapsedMs >= 2_000) {
          resolveRetarget({
            samples,
            timedOut: !text.includes("RETARGET_B_READY"),
          });
          return;
        }
        requestAnimationFrame(readFrame);
      };
      requestAnimationFrame(readFrame);
    });
  });

  expect(retarget.timedOut).toBe(false);
  expect(retarget.samples.at(-1)?.text).toContain("RETARGET_B_READY");
  expect(
    Math.min(...retarget.samples.map((sample) => sample.text.length))
  ).toBeGreaterThan(200);
  expect(Math.max(...retarget.samples.map((sample) => sample.streamRoots))).toBe(1);
});

test("generated-media motion does not change Markdown code copy easing", async ({
  context,
  page,
}) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"], {
    origin: new URL(fixtureUrl).origin,
  });
  await page.goto(fixtureUrl);
  await setMarkdownScenario(page, "final");

  const fixture = page.getByTestId("markdown-stream-fixture");
  const codeBlock = fixture
    .locator(".markdown-stream-code-block")
    .filter({ hasText: "MarkdownStatus" })
    .first();
  const copyButton = codeBlock.locator("button.markdown-stream-control");
  const swapIcon = copyButton.locator(".t-icon-swap .t-icon").first();
  const sharedEasing = {
    timingFunctions: ["ease-in-out", "ease-in-out"],
    variable: "ease-in-out",
    filter: "none",
  };
  const readSwapEasing = () =>
    swapIcon.evaluate((element) => {
      const styles = getComputedStyle(element);
      return {
        timingFunctions: styles.transitionTimingFunction
          .split(",")
          .map((value) => value.trim()),
        variable: styles.getPropertyValue("--icon-swap-ease").trim(),
        filter: styles.filter,
      };
    });
  await expect(copyButton).toBeVisible({ timeout: 20_000 });
  await expect(copyButton).toHaveAccessibleName("Copy code");
  await expect.poll(readSwapEasing).toEqual(sharedEasing);

  await copyButton.click();

  await expect(copyButton).toHaveAccessibleName("Code copied");
  await expect.poll(readSwapEasing).toEqual(sharedEasing);
});

test("production conversation Markdown follows the resolved product theme", async ({
  page,
}) => {
  test.setTimeout(60_000);
  // This test owns the resolved palette, not button-transition timing. Disable
  // motion so content-visibility cannot leave an offscreen color transition in
  // its pending state while the underlying theme token has already changed.
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto(fixtureUrl);
  await setMarkdownScenario(page, "final");

  const product = page.getByTestId("conversation-markdown-fixture");
  await product.locator(".markdown-stream-code-body").scrollIntoViewIfNeeded();
  await expect(
    product.locator(".markdown-stream-code-body .shiki .line > span").first()
  ).toBeVisible({
    timeout: 20_000,
  });
  await expect(product.locator(".markdown-stream-mermaid-svg svg")).toBeVisible({
    timeout: 20_000,
  });

  await setMarkdownTheme(page, "Light mode");
  // A theme change can replace the asynchronous Shiki/Mermaid output after
  // the earlier visible-state checks. Observe the exact palette inputs again.
  await expect(
    product
      .locator(".shiki .line > span")
      .filter({ hasText: /^\s*type\s*$/ })
      .first()
  ).toBeAttached();
  await expect(
    product.locator(".markdown-stream-mermaid-svg .flowchart-link").first()
  ).toBeAttached();
  await expect(
    product.locator(".markdown-stream-mermaid-svg marker path").first()
  ).toBeAttached();
  const light = await readProductPalette(product);
  await expectMermaidControlPalette(product);

  await setMarkdownTheme(page, "Dark mode");
  await expect(page.locator("main")).toHaveAttribute("data-theme", "Dark mode");
  await expect
    .poll(async () => {
      try {
        return (await readProductPalette(product)).keyword;
      } catch {
        return light.keyword;
      }
    })
    .not.toBe(light.keyword);
  await expect
    .poll(async () => {
      try {
        return (await readProductPalette(product)).mermaidEdge;
      } catch {
        return light.mermaidEdge;
      }
    })
    .not.toBe(light.mermaidEdge);

  const dark = await readProductPalette(product);
  await expectMermaidControlPalette(product);
  expect(contrastRatio(dark.keyword, dark.codeSurface)).toBeGreaterThanOrEqual(3);
  expect(contrastRatio(dark.mermaidEdge, dark.diagramSurface)).toBeGreaterThanOrEqual(
    3
  );
  expect(dark.mermaidMarker).toBe(dark.mermaidEdge);
});

test("shared Markdown keeps its own ramp; a turn's reply and user message share one", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const typography = await page.evaluate(() => {
    const compactProbe = document.createElement("div");
    compactProbe.style.fontSize = "var(--text-sm)";
    compactProbe.style.lineHeight = "calc(var(--text-sm) + var(--spacing-md))";
    const replyProbe = document.createElement("div");
    replyProbe.style.fontSize = "var(--text-sm)";
    replyProbe.style.lineHeight = "var(--text-sm--line-height)";
    document.body.append(compactProbe, replyProbe);
    const compactStyles = getComputedStyle(compactProbe);
    const replyStyles = getComputedStyle(replyProbe);
    const resolved = {
      compact: {
        fontSize: compactStyles.fontSize,
        lineHeight: compactStyles.lineHeight,
      },
      reply: {
        fontSize: replyStyles.fontSize,
        lineHeight: replyStyles.lineHeight,
      },
    };
    compactProbe.remove();
    replyProbe.remove();

    return resolved;
  });

  const sharedMarkdown = page
    .getByTestId("markdown-stream-fixture")
    .locator(".markdown-stream")
    .first();
  await expect(sharedMarkdown).toHaveCSS("font-size", typography.compact.fontSize);
  await expect(sharedMarkdown).toHaveCSS("line-height", typography.compact.lineHeight);

  for (const testId of [
    "conversation-default-fixture",
    "conversation-markdown-fixture",
  ]) {
    const conversation = page.getByTestId(testId);
    const assistantMarkdown = conversation.locator(".markdown-stream").first();
    const userMessage = conversation.locator(".comma-chat-user-bubble").first();

    await expect(assistantMarkdown).toBeVisible();
    await expect(userMessage).toBeVisible();
    // A reply reads at the conversation's own small ramp: the same size as the
    // shared Markdown default, but on the type scale's line height rather than
    // the shared renderer's composed one.
    await expect(assistantMarkdown).toHaveCSS("font-size", typography.reply.fontSize);
    await expect(assistantMarkdown).toHaveCSS(
      "line-height",
      typography.reply.lineHeight
    );
    // The user bubble sits on that same ramp: both halves of one turn read at
    // one size. It used to be a step larger (text-regular), which is the drift
    // this now pins shut.
    await expect(userMessage).toHaveCSS("font-size", typography.reply.fontSize);
    await expect(userMessage).toHaveCSS("line-height", typography.reply.lineHeight);
    if (testId === "conversation-default-fixture") {
      // The readable-width cap lives on the slot as min(500px, 100cqi - 42px):
      // container query units resolve against the always-definite column, so
      // the computed value is a length. A percentage cap on the bubble would
      // resolve against the shrink-to-fit slot and collapse short messages.
      await expect(
        userMessage.locator(
          "xpath=ancestor::*[contains(@class, 'comma-chat-user-bubble-slot')]"
        )
      ).toHaveCSS("max-width", "500px");
      await expect(userMessage).toHaveCSS("max-width", "100%");
    }
  }

  const sideChat = page.getByTestId("conversation-markdown-fixture");
  await expect(sideChat).toHaveAttribute("data-variant", "side-chat");
  await expect(sideChat.locator(".comma-chat-user-bubble").first()).toHaveCSS(
    "padding",
    "10px 13px"
  );
  // calc(100cqi - 42px) resolves against the side-chat column container, so
  // the computed cap excludes the avatar gutter and 42px breathing room.
  const sideChatSlotCap = await sideChat
    .locator(".comma-chat-user-bubble-slot")
    .first()
    .evaluate((slot) => {
      const column = slot.closest(".comma-chat-column");
      if (!column) throw new Error("Expected the side-chat bubble column.");
      return {
        capPx: Number.parseFloat(getComputedStyle(slot).maxWidth),
        columnWidth: column.getBoundingClientRect().width,
        gutter: Number.parseFloat(getComputedStyle(column).paddingInlineStart),
      };
    });
  expect(
    Math.abs(
      sideChatSlotCap.capPx -
        (sideChatSlotCap.columnWidth - sideChatSlotCap.gutter - 42)
    )
  ).toBeLessThanOrEqual(1);
  await expect(sideChat.locator(".comma-chat-user-bubble").first()).toHaveCSS(
    "max-width",
    "100%"
  );
});

test("conversation timestamps mark minute intervals above their first user message", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const fixture = page.getByTestId("conversation-timestamp-fixture");
  const column = fixture.locator(".comma-chat-column");
  const timestamps = fixture.locator(".comma-chat-conversation-timestamp");
  const firstTimestamp = fixture.getByTestId(
    "chat-conversation-time-timestamp-user-start"
  );

  await expect(timestamps).toHaveCount(2);
  await expect(firstTimestamp).toContainText(/^Today /);
  await expect(
    fixture.getByTestId("chat-conversation-time-timestamp-user-within")
  ).toHaveCount(0);

  const geometry = await fixture.evaluate((root) => {
    const columnElement = root.querySelector<HTMLElement>(".comma-chat-column");
    const firstUser = root.querySelector<HTMLElement>(
      '[data-message-id="timestamp-user-start"]'
    );
    const firstTime = root.querySelector<HTMLElement>(
      '[data-testid="chat-conversation-time-timestamp-user-start"]'
    );
    const secondUser = root.querySelector<HTMLElement>(
      '[data-message-id="timestamp-user-next"]'
    );
    const secondTime = root.querySelector<HTMLElement>(
      '[data-testid="chat-conversation-time-timestamp-user-next"]'
    );
    if (!columnElement || !firstUser || !firstTime || !secondUser || !secondTime) {
      throw new Error("Expected timestamp fixture geometry.");
    }

    const columnBox = columnElement.getBoundingClientRect();
    const firstTimeBox = firstTime.getBoundingClientRect();
    const turnStyles = getComputedStyle(firstUser.parentElement!);
    return {
      centerDelta: Math.abs(
        firstTimeBox.left +
          firstTimeBox.width / 2 -
          (columnBox.left + columnBox.width / 2)
      ),
      columnGap: turnStyles.columnGap,
      firstPrecedesUser: firstTime.nextElementSibling === firstUser,
      rowGap: turnStyles.rowGap,
      secondPrecedesUser: secondTime.nextElementSibling === secondUser,
      timestampToUser: Math.round(
        firstUser.getBoundingClientRect().top - firstTimeBox.bottom
      ),
    };
  });

  expect(geometry.centerDelta).toBeLessThanOrEqual(1);
  expect(geometry.columnGap).toBe("20px");
  expect(geometry.firstPrecedesUser).toBe(true);
  // The turn's rows share its own 8px rhythm; the timestamp labels the turn
  // rather than being one of its rows, so it keeps the wider 16px separation.
  expect(geometry.rowGap).toBe("8px");
  expect(geometry.timestampToUser).toBe(16);
  expect(geometry.secondPrecedesUser).toBe(true);
  await expect(firstTimestamp).toHaveCSS("text-align", "center");
  await expect(column).toBeVisible();
});

test("a sent user bubble keeps one morph owner and survives an immediate ACK", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("outgoing-user-motion-fixture");
  await fixture.scrollIntoViewIfNeeded();

  const motion = await captureOutgoingUserMotion(page, "full");
  expect(motion.ackPreservedDestination).toBe(true);
  expect(motion.animationIdentityPreserved).toBe(true);
  expect(motion.observerBubbleIdentityPreserved).toBe(true);
  expect(motion.keyframeZeroOffset).toBe(0);
  expect(motion.observerAnimationCurrentTime).toBeLessThanOrEqual(1);
  expect(motion.destinationVisibleAfterFlight).toBe(true);
  expect(motion.maximumBubbleCount).toBe(1);
  expect(motion.maximumRenderedTextCopies).toBe(1);
  expect(motion.visibleBubbleIdentityPreserved).toBe(true);
  expect(motion.flightUsedTopLayer).toBe(true);
  expect(motion.popoverMode).toBe("manual");
  expect(motion.animationDurations).toHaveLength(1);
  expect(motion.animationDurations[0]).toBeGreaterThan(850);
  expect(motion.animationDurations[0]).toBeLessThan(950);
  // The shape travels and morphs; its material changes on the plane behind it.
  expect(motion.animatedProperties).toEqual(["clipPath", "transform"]);
  expect(motion.materialProperties).toEqual(["backgroundColor"]);
  expect(motion.filters).toEqual(["none"]);
  expect(motion.bubbleOverflow).toEqual(["visible", "visible"]);
  expect(motion.frames.length).toBeGreaterThan(4);

  const last = motion.frames.at(-1)!;
  const verticalTravel = motion.sourceSurface.bottom - motion.destinationFrame.bottom;
  const horizontalTravel = Math.abs(
    motion.destinationFrame.right - motion.sourceSurface.right
  );
  expect(verticalTravel).toBeGreaterThan(180);
  expect(horizontalTravel).toBeGreaterThan(10);
  expect(
    Math.abs(motion.keyframeZeroFrame.bottom - motion.sourceSurface.bottom)
  ).toBeLessThan(verticalTravel * 0.1);
  expect(
    Math.abs(motion.keyframeZeroFrame.right - motion.sourceSurface.right)
  ).toBeLessThan(8);
  expect(Math.abs(last.bubbleBottom - motion.destinationFrame.bottom)).toBeLessThan(1);
  expect(Math.abs(last.bubbleRight - motion.destinationFrame.right)).toBeLessThan(1);
  expect(motion.handoffEdgeDelta).toBeLessThanOrEqual(1);
  // Position and width rebound independently of the uniform whole-bubble pulse.
  expect(
    Math.min(...motion.frames.map((frame) => frame.bubbleBottom))
  ).toBeGreaterThanOrEqual(motion.destinationFrame.bottom - 8);
  expect(
    motion.frames.every(
      (frame) =>
        Math.abs(
          frame.bubbleHeight / frame.bubbleScale - motion.destinationFrame.height
        ) < 1
    )
  ).toBe(true);

  expect(motion.composerIdentityPreserved).toBe(true);
  expect(motion.composerReadyAfterSend).toBe(true);
  expect(motion.composerEmptyAfterSend).toBe(true);
  expect(motion.composerInputEnabledAfterSend).toBe(true);
  expect(Math.abs(motion.composerBefore.left - motion.composerAfter.left)).toBeLessThan(
    0.1
  );
  expect(Math.abs(motion.composerBefore.top - motion.composerAfter.top)).toBeLessThan(
    0.1
  );
  expect(
    Math.abs(motion.composerBefore.width - motion.composerAfter.width)
  ).toBeLessThan(0.1);
  expect(
    Math.abs(motion.composerBefore.height - motion.composerAfter.height)
  ).toBeLessThan(0.1);
});

test("long mixed-script user text stays inside its bubble throughout send and settlement", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("outgoing-user-motion-fixture");
  await fixture.scrollIntoViewIfNeeded();
  await page.waitForFunction(() => Boolean(window.markdownStreamFixture));
  await page.evaluate((text) => {
    window.markdownStreamFixture?.setOutgoingUserText(text);
  }, longOutgoingUserText);

  const motion = await captureOutgoingUserMotion(page, "full");

  expect.soft(motion.maximumFlightCopyOverflowX).toBeLessThanOrEqual(1);
  expect.soft(motion.maximumFlightCopyOverflowY).toBeLessThanOrEqual(1);
  expect.soft(motion.settledCopyOverflowX).toBeLessThanOrEqual(1);
  expect.soft(motion.settledCopyOverflowY).toBeLessThanOrEqual(1);
  expect.soft(motion.settledTextOverflowLeft).toBeLessThanOrEqual(1);
  expect.soft(motion.settledTextOverflowRight).toBeLessThanOrEqual(1);
  expect.soft(motion.settledTextOverflowTop).toBeLessThanOrEqual(1);
  expect.soft(motion.settledTextOverflowBottom).toBeLessThanOrEqual(1);
  expect.soft(motion.settledBubbleOverflowLeft).toBeLessThanOrEqual(1);
  expect.soft(motion.settledBubbleOverflowRight).toBeLessThanOrEqual(1);
});

test("a root font-size change re-measures the 480px disclosure of a settled bubble", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("outgoing-user-motion-fixture");
  await fixture.scrollIntoViewIfNeeded();
  await page.waitForFunction(() => Boolean(window.markdownStreamFixture));

  // One long wrapping paragraph: the bubble fills its width cap at every
  // font size (so the width-change signal stays silent), sits below the
  // 480px collapse threshold at the default root font size, and grows past
  // it in the block axis alone once the root font scales the line boxes.
  const text = "word ".repeat(200).trim();
  await page.evaluate((messageText) => {
    window.markdownStreamFixture?.resetOutgoingUser();
    window.markdownStreamFixture?.setOutgoingUserText(messageText);
    window.markdownStreamFixture?.startOutgoingUser();
  }, text);
  const bubble = fixture.locator(".comma-chat-user-bubble").last();
  await expect(bubble).toBeVisible();
  await page.waitForTimeout(1000);
  await page.evaluate(() => window.markdownStreamFixture?.ackOutgoingUser());

  await expect(bubble).not.toHaveAttribute("data-overflowing", "true");
  await expect(bubble.getByRole("button", { name: "Show full message" })).toHaveCount(
    0
  );

  try {
    await page.evaluate(() => {
      document.documentElement.style.fontSize = "21px";
    });
    // The clamped bubble box does not resize when only the root font grows;
    // the 1rem probe is what must trigger the overflow re-measure.
    await expect(bubble).toHaveAttribute("data-overflowing", "true");
    await expect(
      bubble.getByRole("button", { name: "Show full message" })
    ).toBeVisible();
  } finally {
    await page.evaluate(() => {
      document.documentElement.style.removeProperty("font-size");
    });
  }
});

test(
  "very large user text collapses to one bounded destination without duplicating its surface",
  { tag: "@frame-budget" },
  async ({ page }) => {
    test.setTimeout(60_000);
    await page.goto(`${fixtureUrl}?fixture=outgoing-user-motion-fixture`);
    await page.getByTestId("outgoing-user-motion-fixture").scrollIntoViewIfNeeded();

    await beginOutgoingPerformanceProbe(page);
    const presentation = await captureCollapsedOutgoingUserPresentation(
      page,
      hugeOutgoingUserText
    );
    const performance = await finishOutgoingPerformanceProbe(page);
    const frameGaps = performance.rafTimestamps
      .slice(1)
      .map((timestamp, index) => timestamp - performance.rafTimestamps[index]!);

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
    // Allow 0.5ms of timing tolerance around the 50ms frame-gap target.
    expect.soft(Math.max(0, ...frameGaps)).toBeLessThanOrEqual(50.5);
    expect.soft(performance.longTasks).toHaveLength(0);
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
  }
);

test(
  "a 480px readable summary travels continuously to the current-turn top anchor",
  { tag: "@frame-budget" },
  async ({ page }) => {
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
    expect.soft(presentation.longestStationaryAwayMs).toBeLessThanOrEqual(100);
    expect.soft(presentation.maximumLateFrameJump).toBeLessThanOrEqual(4);
    expect.soft(presentation.handoffEdgeDelta).toBeLessThanOrEqual(1);
  }
);

for (const variant of ["route", "side-chat"] as const) {
  test(`a delayed Participant status preserves the ${variant} anchor and 480px bubble handoff`, async ({
    page,
  }) => {
    test.setTimeout(30_000);
    await page.goto(fixtureUrl);
    await page
      .getByTestId(`delayed-activity-outgoing-${variant}-fixture`)
      .scrollIntoViewIfNeeded();

    const capture = await captureDelayedOutgoingActivityHandoff(page, variant);
    await test.info().attach(`${variant}-delayed-activity-frames.json`, {
      body: Buffer.from(JSON.stringify(capture, null, 2)),
      contentType: "application/json",
    });
    const violations: string[] = [];
    if (!capture.initialActivityAbsent) {
      violations.push("Activity existed before send");
    }
    if (!capture.preSendOverflowed || !capture.preSendAtBottom) {
      violations.push(
        `history was not overflowed and bottom-aligned before send (scrollTop=${capture.preSendScrollTop}, scrollHeight=${capture.preSendScrollHeight}, viewport=${capture.preSendViewportHeight})`
      );
    }
    if (capture.activityAppearedBefore800Ms) {
      violations.push("Activity appeared before the owning 800ms delay window");
    }
    if (!capture.activityAppeared) {
      violations.push("Activity never appeared");
    }
    if (
      capture.activityAppearedAtMs === null ||
      capture.activityAppearedAtMs < 800 ||
      capture.activityAppearedAtMs > 1_200
    ) {
      violations.push(
        `Activity delay ${capture.activityAppearedAtMs ?? "missing"}ms was outside 800–1200ms`
      );
    }
    if (capture.observedAfterActivityMs < 500) {
      violations.push(
        `only observed ${capture.observedAfterActivityMs}ms after Activity appeared`
      );
    }
    if (!capture.animationStarted || capture.animationEndedAtMs === null) {
      violations.push("the outgoing spring start/end was not observed");
    }
    if (!capture.bubbleIdentityPreserved) {
      violations.push("the user bubble DOM owner changed");
    }
    if (!capture.slotIdentityPreserved) {
      violations.push("the user bubble slot DOM owner changed");
    }
    if (!capture.turnAnchorIdentityPreserved) {
      violations.push("the user turn anchor DOM owner changed");
    }
    if (!capture.participantStatusAfterMessages) {
      violations.push("Participant status was not after the pending message");
    }
    if (
      capture.participantIds.some(
        (participantId) => participantId !== `delayed-activity-${variant}-participant`
      )
    ) {
      violations.push("Participant status did not retain its exact participant id");
    }
    if (capture.maximumBubbleCount !== 1) {
      violations.push(`rendered ${capture.maximumBubbleCount} user bubbles`);
    }
    if (capture.collapsedBubbleHeight < 479 || capture.collapsedBubbleHeight > 481) {
      violations.push(
        `readable summary height was ${capture.collapsedBubbleHeight}px instead of 480px`
      );
    }
    // Compare the painted edges. Compositor translation can retarget a flight
    // without changing the layout origin captured at launch.
    const handoffDelta =
      capture.lastFlyingToSettledSampleDelta ?? Number.POSITIVE_INFINITY;
    if (handoffDelta > 1) {
      violations.push(`spring-to-settled handoff moved ${handoffDelta}px`);
    }
    if (variant === "side-chat") {
      // Activity adds content below the user bubble. Tail following may move
      // its screen position, but must not move it within the transcript.
      if (capture.postAnimationContentTopRange > 1) {
        violations.push(
          `bubble moved within the transcript by ${capture.postAnimationContentTopRange}px`
        );
      }
      if (capture.settledTailGap > 1) {
        violations.push(
          `Side Chat stopped following its tail by ${capture.settledTailGap}px`
        );
      }
    }
    if (variant === "route" && capture.postAnimationTopRange > 1) {
      violations.push(
        `settled bubble top relocated ${capture.postAnimationTopRange}px`
      );
    }
    if (variant === "route" && capture.postAnimationBottomRange > 1) {
      violations.push(
        `settled bubble bottom relocated ${capture.postAnimationBottomRange}px`
      );
    }
    if (variant === "route" && capture.longestStationaryAwayMs > 100) {
      violations.push(
        `bubble stayed stationary away from its final rect for ${capture.longestStationaryAwayMs}ms`
      );
    }

    const diagnosticSummary = {
      ...capture,
      samples: `${capture.samples.length} frames attached as JSON`,
    };
    expect(
      violations,
      `${variant} delayed Activity phase data:\n${JSON.stringify(diagnosticSummary, null, 2)}`
    ).toEqual([]);
  });
}

test("a rapid normal send followed by tall text keeps one spring owner and one collapsed destination", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.getByTestId("outgoing-user-motion-fixture").scrollIntoViewIfNeeded();

  const rapid = await captureRapidNormalThenCollapsedOutgoing(page);

  expect(rapid.firstBubbleIdentityPreserved).toBe(true);
  expect(rapid.firstAnimationIdentityPreserved).toBe(true);
  expect(rapid.firstDestinationVisibleAfterFlight).toBe(true);
  expect(rapid.secondArticleCount).toBe(1);
  expect(rapid.secondBubbleCount).toBe(1);
  expect(rapid.secondCollapsed).toBe(true);
  expect(rapid.secondCollapsedHeight).toBeGreaterThanOrEqual(479);
  expect(rapid.secondCollapsedHeight).toBeLessThanOrEqual(481);
  expect(rapid.secondTextLength).toBe(Array.from(tallOutgoingUserText).length);
  expect(rapid.maximumFlyingBubbleCount).toBe(2);
  expect(rapid.maximumBubbleMultiplicity).toBe(1);
  expect(rapid.maximumRenderedBubbleTextCharacters).toBe(
    Array.from(rapidNormalOutgoingUserText).length +
      Array.from(tallOutgoingUserText).length
  );
  expect(rapid.secondBubbleStarted).toBe(true);
  expect(rapid.secondBubbleMaximumHeight).toBeGreaterThanOrEqual(479);
  expect(rapid.secondBubbleMaximumHeight).toBeLessThanOrEqual(483);
  expect(rapid.secondBubbleMaximumKeyframeCount).toBeLessThanOrEqual(192);
  expect(rapid.secondDestinationIdentityPreserved).toBe(true);
  expect(
    rapid.agentFeedbackVisible,
    `feedback geometry samples: ${JSON.stringify(rapid.feedbackGeometrySamples)}`
  ).toBe(true);
  expect(rapid.feedbackReadinessFrames).toBeLessThanOrEqual(3);
});

test("line-dense text uses a blurred easing fade and expands from a stable top anchor", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.getByTestId("outgoing-user-motion-fixture").scrollIntoViewIfNeeded();

  const disclosure = await exerciseCollapsedOutgoingDisclosure(
    page,
    tallOutgoingUserText,
    false
  );

  expect(Array.from(tallOutgoingUserText)).toHaveLength(799);
  expect(disclosure.collapsedHeight).toBeGreaterThanOrEqual(479);
  expect(disclosure.collapsedHeight).toBeLessThanOrEqual(481);
  expect(disclosure.resizedCollapsedHeight).toBeGreaterThanOrEqual(479);
  expect(disclosure.resizedCollapsedHeight).toBeLessThanOrEqual(481);
  expect(disclosure.resizeTopDelta).toBeLessThanOrEqual(1);
  expect(disclosure.fullHeight).toBeGreaterThan(disclosure.collapsedHeight * 2);
  expect(disclosure.fadeBackdropFilter).toContain("blur(");
  expect(disclosure.fadeGradient).toContain("linear-gradient(");
  expect(disclosure.fadeGradientStopCount).toBeGreaterThanOrEqual(5);
  expect(disclosure.initialAccessibleName).toBe("Show full message");
  expect(disclosure.centralIconPreserved).toBe(true);
  expect(disclosure.collapsedToggleFadeCenterDeltaX).toBeLessThanOrEqual(1);
  expect(disclosure.collapsedToggleInsideFade).toBe(true);
  expect(disclosure.collapsedControlRowPosition).toBe("absolute");
  expect(disclosure.expanded).toBe(true);
  expect(disclosure.expandedAccessibleName).toBe("Collapse message");
  expect(disclosure.expandedHeight).toBeGreaterThanOrEqual(disclosure.fullHeight - 1);
  expect(disclosure.expandedLastGlyphControlOverlap).toBe(0);
  expect(disclosure.expandedControlGap).toBeGreaterThanOrEqual(0);
  expect(disclosure.expandedControlGap).toBeGreaterThanOrEqual(
    disclosure.expandedControlRowMarginTop - 1
  );
  expect(disclosure.expandedControlRowMarginTop).toBeCloseTo(disclosure.spacingXs, 1);
  expect(disclosure.expandedBottomPadding).toBeCloseTo(disclosure.spacingXs, 1);
  expect(disclosure.expandedIconWidth).toBeCloseTo(disclosure.spacing2xl, 1);
  expect(disclosure.expandedIconHeight).toBeCloseTo(disclosure.spacing2xl, 1);
  expect(disclosure.expandedIconWidth).toBeGreaterThan(disclosure.spacingXl);
  expect(disclosure.expandedControlRowHeight).toBeGreaterThanOrEqual(
    disclosure.expandedToggleHeight
  );
  expect(disclosure.expandedControlRowHeight).toBeCloseTo(
    disclosure.spacing4xl + disclosure.spacingXs * 2,
    0
  );
  expect(disclosure.expandedControlRowPosition).toBe("relative");
  expect(disclosure.expandTopDelta).toBeLessThanOrEqual(1);
  expect(disclosure.destinationIdentityPreserved).toBe(true);
  expect(disclosure.bubbleIdentityPreserved).toBe(true);
  expect(disclosure.textIdentityPreserved).toBe(true);
  expect(disclosure.toggleIdentityPreserved).toBe(true);
  expect(disclosure.toggleRowIdentityPreserved).toBe(true);
  expect(disclosure.textLength).toBe(tallOutgoingUserText.length);
  expect(disclosure.expandedSurvivedAck).toBe(true);
  expect(disclosure.expandedSurvivedFailure).toBe(true);
  expect(disclosure.collapsedAgain).toBe(true);
  expect(disclosure.recollapsedHeight).toBeGreaterThanOrEqual(479);
  expect(disclosure.recollapsedHeight).toBeLessThanOrEqual(481);
  expect(disclosure.recollapseTopDelta).toBeLessThanOrEqual(1);
  expect(disclosure.recollapsedToggleFadeCenterDeltaX).toBeLessThanOrEqual(1);
  expect(disclosure.recollapsedToggleInsideFade).toBe(true);
  expect(disclosure.recollapsedControlRowPosition).toBe("absolute");
});

test("reduced motion expands and collapses tall text without spatial transition", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.getByTestId("outgoing-user-motion-fixture").scrollIntoViewIfNeeded();
  const disclosure = await exerciseCollapsedOutgoingDisclosure(
    page,
    tallOutgoingUserText,
    true
  );

  expect(disclosure.expanded).toBe(true);
  expect(disclosure.collapsedAgain).toBe(true);
  expect(disclosure.expandSpatialAnimationProperties).toEqual([]);
  expect(disclosure.collapseSpatialAnimationProperties).toEqual([]);
  expect(disclosure.expandTopDelta).toBeLessThanOrEqual(1);
  expect(disclosure.recollapseTopDelta).toBeLessThanOrEqual(1);
});

test("a late send failure does not restart or jump the outgoing spring", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.getByTestId("outgoing-user-motion-fixture").scrollIntoViewIfNeeded();

  const handoff = await captureFailedOutgoingHandoff(page);

  expect(handoff.failureRendered).toBe(true);
  expect(handoff.destinationIdentityPreserved).toBe(true);
  expect(handoff.articleIdentityPreserved).toBe(true);
  expect(handoff.bubbleIdentityPreserved).toBe(true);
  expect(handoff.animationIdentityPreserved).toBe(true);
  expect(handoff.animationTimesMonotonic).toBe(true);
  expect.soft(handoff.visibleBubbleIdentityPreserved).toBe(true);
  expect.soft(handoff.animationRestartCount).toBe(0);
  expect.soft(handoff.maximumBubbleCount).toBe(1);
  expect.soft(handoff.maximumRenderedTextCopies).toBe(1);
  expect.soft(handoff.failedDestinationGeometryDelta).toBeLessThanOrEqual(1);
  expect.soft(handoff.failureBoundaryJump).toBeLessThanOrEqual(8);
  expect.soft(handoff.maximumPostFailureFrameJump).toBeLessThanOrEqual(8);
  expect.soft(handoff.handoffEdgeDelta).toBeLessThanOrEqual(1);
});

test("ConversationView keeps its spring owner when a plain send Promise rejects", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("conversation-view-rejected-send-fixture");
  await fixture.scrollIntoViewIfNeeded();

  const handoff = await captureConversationViewRejectedSendHandoff(page);

  expect(handoff.observerReadyBeforeReject).toBe(true);
  expect(handoff.preFailureSampleCount).toBeGreaterThan(1);
  expect(handoff.deferredRejectTriggered).toBe(true);
  expect(handoff.failureRendered).toBe(true);
  expect(handoff.failureAnimationTime).toBeGreaterThanOrEqual(150);
  expect(handoff.failureAnimationTime).toBeLessThanOrEqual(300);
  expect(handoff.bubbleFlyingAtFailure).toBe(true);
  expect(handoff.bubbleFramesAfterFailure).toBeGreaterThan(5);
  expect(handoff.animationIdentityPreserved).toBe(true);
  expect(handoff.animationTimesMonotonic).toBe(true);
  expect(handoff.animationRestartCount).toBe(0);
  expect(handoff.articleIdentityPreserved).toBe(true);
  expect(handoff.bubbleIdentityPreserved).toBe(true);
  expect(handoff.maximumBubbleCount).toBe(1);
  expect(handoff.maximumRenderedTextCopies).toBe(1);
  expect.soft(handoff.visibleBubbleIdentityPreserved).toBe(true);
  expect.soft(handoff.failedBubbleGeometryDelta).toBeLessThanOrEqual(1);
  expect
    .soft(handoff.failureBoundaryJump)
    .toBeLessThanOrEqual(handoff.maximumExpectedFailureBoundaryJump);
  expect(handoff.handoffReachedNaturalEnd).toBe(true);
  expect.soft(handoff.handoffEdgeDelta).toBeLessThanOrEqual(1);
});

test("ConversationView restores a staged quote when Electron send admission rejects", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("conversation-view-rejected-send-fixture");
  await fixture.scrollIntoViewIfNeeded();
  await page.waitForFunction(() => Boolean(window.conversationViewRejectedSendFixture));
  await page.evaluate(() =>
    window.conversationViewRejectedSendFixture?.prepareQuoteAdmission()
  );

  const source = fixture.getByText(
    "Preserve this quoted passage when admission fails.",
    { exact: true }
  );
  await source.evaluate((element) => {
    const range = document.createRange();
    range.selectNodeContents(element);
    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
  });
  await source.dispatchEvent("pointerup");
  await page.getByRole("button", { name: "Add to chat" }).click();

  const quote = fixture.locator('[data-slot="quote-attachment"]');
  await expect(quote).toHaveCount(1);
  await fixture.getByRole("button", { name: "Send message" }).click();
  await expect(quote).toHaveCount(0);

  const rejected = await page.evaluate(() =>
    window.conversationViewRejectedSendFixture?.reject()
  );
  expect(rejected).toBe(true);
  await expect(quote).toHaveCount(1);
  await expect(fixture.getByRole("textbox", { name: "AI prompt" })).toHaveText(
    "Retry this message with its quote."
  );
});

test("system reduced motion keeps the sent user bubble at its destination", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto(fixtureUrl);
  await page.getByTestId("outgoing-user-motion-fixture").scrollIntoViewIfNeeded();

  expectReducedOutgoingMotion(await captureOutgoingUserMotion(page, "system"));
});

test("Comma's manual reduced-motion setting avoids the user-bubble flight", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.getByTestId("outgoing-user-motion-fixture").scrollIntoViewIfNeeded();

  expectReducedOutgoingMotion(await captureOutgoingUserMotion(page, "manual"));
});

test("a compact new turn follows the available scroll range as its draft grows", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("conversation-turn-fixture");
  const viewport = fixture.locator('[data-slot="scroll-area-viewport"]');
  const currentUser = fixture.locator('[data-message-id="turn-user"]');

  await setConversationStage(page, "sent");
  await expect(currentUser).toBeVisible();
  const turnTopInset = await fixture
    .locator(".comma-chat-thread")
    .evaluate((thread) =>
      Number.parseFloat(
        getComputedStyle(thread).getPropertyValue("--comma-chat-thread-top-inset")
      )
    );
  expect(turnTopInset).toBeGreaterThan(0);
  const latestTurn = fixture.getByTestId("chat-latest-turn");
  await expect(latestTurn).toHaveCSS("min-height", "200px");
  await expect(latestTurn).toHaveCSS("padding-bottom", "48px");
  await expect
    .poll(() =>
      viewport.evaluate((element) =>
        Math.abs(element.scrollHeight - element.clientHeight - element.scrollTop)
      )
    )
    .toBeLessThanOrEqual(1);
  const sentUserOffset = await verticalOffset(viewport, currentUser);
  // A short turn cannot reach the top without restoring the removed
  // viewport-sized blank reserve. Longer drafts can reach the top normally.
  expect(sentUserOffset).toBeGreaterThan(turnTopInset);

  await setConversationStage(page, "draft");
  const draft = fixture.getByTestId("chat-assistant-draft");
  await expect(draft).toContainText("Streaming reply is growing in place.");
  await draft.evaluate((element) => {
    element.setAttribute("data-assistant-surface-identity", "preserved");
    element
      .querySelector(".markdown-stream")
      ?.setAttribute("data-assistant-markdown-identity", "preserved");
  });
  await expect
    .poll(async () =>
      Math.abs((await verticalOffset(viewport, currentUser)) - sentUserOffset)
    )
    .toBeLessThanOrEqual(0.01);

  const streamedReveal = await page.evaluate(async () => {
    const startedAt = performance.now();
    window.markdownStreamFixture?.setConversationStage("draft-grown");
    return await new Promise<{
      activeGlyphs: number;
      elapsedMs: number;
      text: string;
    }>((resolveReveal) => {
      const readAfterFrame = () => {
        const response = document.querySelector(
          '[data-testid="conversation-turn-fixture"] [data-testid="chat-assistant-draft"]'
        );
        const text = response?.textContent ?? "";
        const elapsedMs = performance.now() - startedAt;
        if (text.includes("Draft growth complete.") || elapsedMs >= 250) {
          resolveReveal({
            activeGlyphs:
              response?.querySelectorAll(".markdown-stream-char-enter").length ?? -1,
            elapsedMs,
            text,
          });
          return;
        }
        requestAnimationFrame(readAfterFrame);
      };
      requestAnimationFrame(readAfterFrame);
    });
  });
  expect(streamedReveal.text).toContain("Draft growth complete.");
  expect(streamedReveal.elapsedMs).toBeLessThan(250);
  expect(streamedReveal.activeGlyphs).toBeGreaterThanOrEqual(0);
  // The 32-character tail may look behind by at most 64 characters to avoid
  // splitting a word, so the animated DOM remains bounded at 96 glyphs.
  expect(streamedReveal.activeGlyphs).toBeLessThanOrEqual(96);
  await expect(draft).toContainText("Draft growth complete.");
  await expect(draft).toHaveAttribute("data-assistant-surface-identity", "preserved");
  await expect(draft.locator(".markdown-stream")).toHaveAttribute(
    "data-assistant-markdown-identity",
    "preserved"
  );
  await expect
    .poll(async () =>
      Math.abs((await verticalOffset(viewport, currentUser)) - turnTopInset)
    )
    .toBeLessThanOrEqual(1);

  const preservedResponse = fixture.locator(
    '[data-assistant-surface-identity="preserved"]'
  );
  await setConversationStage(page, "final");
  await expect(fixture.getByTestId("chat-assistant-draft")).toHaveCount(0);
  await expect(preservedResponse).toHaveAttribute("data-message-id", "turn-final");
  await expect(preservedResponse).toContainText("Canonical handoff complete.");
  await expect(preservedResponse.locator(".markdown-stream")).toHaveAttribute(
    "data-assistant-markdown-identity",
    "preserved"
  );

  await fixture.evaluate((element) => {
    element.style.height = "300px";
  });
  await expect
    .poll(async () =>
      Math.abs((await verticalOffset(viewport, currentUser)) - turnTopInset)
    )
    .toBeLessThanOrEqual(1);

  const firstWindowedUser = fixture.locator('[data-message-id="turn-history-user-1"]');
  const firstWindowedOffset = await viewport.evaluate((element) => {
    element.dispatchEvent(
      new WheelEvent("wheel", {
        bubbles: true,
        cancelable: true,
        deltaY: -120,
      })
    );
    element.scrollTop = 0;
    const anchor = document.querySelector<HTMLElement>(
      '[data-testid="conversation-turn-fixture"] [data-message-id="turn-history-user-1"]'
    );
    if (!anchor) throw new Error("The first windowed turn was unavailable.");
    const offset =
      anchor.getBoundingClientRect().top - element.getBoundingClientRect().top;
    element.dispatchEvent(new Event("scroll"));
    return offset;
  });
  await fixture.evaluate((element) => {
    element.style.height = "260px";
  });
  await expect(fixture.locator(".comma-chat-thread")).toHaveAttribute(
    "data-comma-hidden-older-count",
    "0"
  );
  await expect
    .poll(async () =>
      Math.abs(
        (await verticalOffset(viewport, firstWindowedUser)) - firstWindowedOffset
      )
    )
    .toBeLessThanOrEqual(1);
  expect(await viewport.evaluate((element) => element.scrollTop)).toBeGreaterThan(0);
});

test("a diagonal upward wheel leaves the latest turn without snapping back", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("conversation-turn-fixture");
  await fixture.scrollIntoViewIfNeeded();
  await setConversationStage(page, "sent");
  const viewport = fixture.locator('[data-slot="scroll-area-viewport"]');
  await expect
    .poll(() => viewport.evaluate((element) => element.scrollTop))
    .toBeGreaterThan(100);
  await expect
    .poll(() =>
      viewport.evaluate((element) =>
        Math.abs(element.scrollHeight - element.clientHeight - element.scrollTop)
      )
    )
    .toBeLessThanOrEqual(1);
  const before = await viewport.evaluate((element) => element.scrollTop);
  const bounds = (await viewport.boundingBox())!;
  await page.mouse.move(bounds.x + 10, bounds.y + bounds.height / 2);
  await page.mouse.wheel(80, -40);
  await expect
    .poll(() => viewport.evaluate((element) => element.scrollTop))
    .toBeLessThan(before - 20);
  // Following must remain suspended after the wheel settlement timeout.
  await page.waitForTimeout(1_100);
  expect(await viewport.evaluate((element) => element.scrollTop)).toBeLessThan(
    before - 20
  );
});

test("scrolling up after jumping to the latest reply uses its current position", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("conversation-turn-fixture");
  await fixture.scrollIntoViewIfNeeded();
  await setConversationStage(page, "draft-grown");
  await expect(fixture.getByTestId("chat-assistant-draft")).toContainText(
    "Draft growth complete."
  );
  const viewport = fixture.locator('[data-slot="scroll-area-viewport"]');
  await expect
    .poll(() => viewport.evaluate((element) => element.scrollTop))
    .toBeGreaterThan(100);

  // The browser scrolls the wheel itself, so this is driven with real input:
  // a synthetic WheelEvent moves nothing.
  const readScrollTop = () => viewport.evaluate((element) => element.scrollTop);
  const readMaxScrollTop = () =>
    viewport.evaluate((element) => element.scrollHeight - element.clientHeight);
  const bounds = (await viewport.boundingBox())!;
  await page.mouse.move(bounds.x + 10, bounds.y + bounds.height / 2);

  // Start reading history, then use the chat's own End handler to jump to the
  // reply.
  const startedAt = await readScrollTop();
  await page.mouse.wheel(0, -40);
  await expect.poll(readScrollTop).toBeLessThan(startedAt);
  await viewport.focus();
  await page.keyboard.press("End");
  await expect
    .poll(async () => Math.abs((await readMaxScrollTop()) - (await readScrollTop())))
    .toBeLessThanOrEqual(1);

  // The next wheel moves from where the jump left the reader, not from where
  // they were reading before it, and the position then holds.
  const before = await readScrollTop();
  await page.mouse.wheel(0, -40);
  await expect.poll(async () => before - (await readScrollTop())).toBeCloseTo(40, 0);
  await viewport.evaluate(
    () =>
      new Promise<void>((resolveFrame) =>
        requestAnimationFrame(() => requestAnimationFrame(() => resolveFrame()))
      )
  );
  expect(before - (await readScrollTop())).toBeCloseTo(40, 0);
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

test("side chat keeps one transcript-tail Participant status and compositor-only draft motion", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.markdownStreamFixture));

  const fixture = page.getByTestId("side-chat-motion-fixture");
  await page.evaluate(() => {
    window.markdownStreamFixture?.setSideChatMotion("waiting");
  });
  const participantStatus = fixture.getByTestId("participant-status-slot");
  await expect(participantStatus).toHaveCount(1);
  await expect(participantStatus).toHaveAttribute("data-state", "active");
  await expect(participantStatus).toContainText("Thinking");

  const burst = await page.evaluate(async () => {
    const root = document.querySelector<HTMLElement>(
      "[data-testid='side-chat-motion-fixture']"
    );
    const controller = window.markdownStreamFixture;
    if (!root || !controller) {
      throw new Error("Side Chat motion fixture was not ready.");
    }

    const chunks = Array.from(
      { length: 24 },
      (_, index) =>
        `Side Chat cumulative stream ${Array.from(
          { length: index + 1 },
          (_value, wordIndex) => `token-${wordIndex + 1}`
        ).join(" ")} BURST_TAIL_${index + 1}`
    );
    const startedAt = performance.now();
    let firstDraft: HTMLElement | null = null;
    let firstDraftAt: number | undefined;
    let maxDraftNodes = 0;
    let minimumDraftOpacity = 1;
    let sampling = true;
    const assistantEntryAnimations = new Set<Animation>();
    const progressOwnerCounts: number[] = [];
    const animationDurations: number[] = [];
    const animatedProperties = new Set<string>();
    const ignoredKeyframeFields = new Set([
      "composite",
      "computedOffset",
      "easing",
      "offset",
    ]);

    const samplingFinished = new Promise<void>((resolveSampling) => {
      const sampleFrame = () => {
        const drafts = root.querySelectorAll<HTMLElement>(
          "[data-testid='chat-assistant-draft']"
        );
        maxDraftNodes = Math.max(maxDraftNodes, drafts.length);
        progressOwnerCounts.push(
          root.querySelectorAll(".comma-chat-activity-slot[data-active='true']").length
        );
        const draft = drafts.item(0);
        if (draft) {
          if (!firstDraft) {
            firstDraft = draft;
            firstDraftAt = performance.now();
          }
          minimumDraftOpacity = Math.min(
            minimumDraftOpacity,
            Number.parseFloat(getComputedStyle(draft).opacity)
          );
          for (const animation of draft.getAnimations()) {
            assistantEntryAnimations.add(animation);
            const effect = animation.effect;
            if (!(effect instanceof KeyframeEffect)) continue;
            const duration = effect.getTiming().duration;
            if (typeof duration === "number") animationDurations.push(duration);
            for (const keyframe of effect.getKeyframes()) {
              for (const property of Object.keys(keyframe)) {
                if (!ignoredKeyframeFields.has(property)) {
                  animatedProperties.add(property);
                }
              }
            }
          }
        }

        if (sampling) {
          requestAnimationFrame(sampleFrame);
        } else {
          resolveSampling();
        }
      };
      requestAnimationFrame(sampleFrame);
    });

    // Model the production gap between visible Activity and the first provider delta.
    await new Promise<void>((resolveFirstDelta) =>
      window.setTimeout(resolveFirstDelta, 50)
    );
    for (const chunk of chunks) {
      controller.setSideChatMotion("streaming", chunk);
      await new Promise<void>((resolveDelta) => window.setTimeout(resolveDelta, 3));
    }
    await new Promise<void>((resolveFinalPaint) =>
      window.setTimeout(resolveFinalPaint, 32)
    );
    sampling = false;
    await samplingFinished;

    const currentDraft = root.querySelector<HTMLElement>(
      "[data-testid='chat-assistant-draft']"
    );
    return {
      animatedProperties: [...animatedProperties].toSorted(),
      animationDurations,
      assistantEntryAnimations: assistantEntryAnimations.size,
      elapsedMs: performance.now() - startedAt,
      firstDraftDelayMs:
        firstDraftAt === undefined ? undefined : firstDraftAt - startedAt,
      maxDraftNodes,
      minimumDraftOpacity,
      progressOwnerCounts,
      stableDraftNode: firstDraft !== null && firstDraft === currentDraft,
      text: currentDraft?.textContent ?? "",
    };
  });

  expect(burst.firstDraftDelayMs).toBeGreaterThanOrEqual(45);
  expect(burst.assistantEntryAnimations).toBe(0);
  expect(burst.animationDurations).toEqual([]);
  expect(burst.animatedProperties).toEqual([]);
  expect(burst.progressOwnerCounts.every((count) => count === 1)).toBe(true);
  expect(burst.maxDraftNodes).toBe(1);
  expect(burst.minimumDraftOpacity).toBeGreaterThanOrEqual(0.5);
  expect(burst.stableDraftNode).toBe(true);
  expect(burst.text).toContain("BURST_TAIL_24");

  await page.waitForTimeout(180);
  const transcriptTailOrder = await fixture.evaluate((root) => {
    const user = root.querySelector<HTMLElement>(".comma-chat-message-user");
    const draft = root.querySelector<HTMLElement>(
      "[data-testid='chat-assistant-draft']"
    );
    const status = root.querySelector<HTMLElement>(
      "[data-testid='participant-status-slot']"
    );
    if (!user || !draft || !status) {
      throw new Error("Side Chat transcript-tail targets were not rendered.");
    }
    return {
      afterDraft: Boolean(
        draft.compareDocumentPosition(status) & Node.DOCUMENT_POSITION_FOLLOWING
      ),
      afterMessages: Boolean(
        user.compareDocumentPosition(status) & Node.DOCUMENT_POSITION_FOLLOWING
      ),
    };
  });
  expect(transcriptTailOrder).toEqual({ afterDraft: true, afterMessages: true });

  await page.evaluate(() => {
    window.markdownStreamFixture?.setSideChatMotion("idle");
  });
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.evaluate(() => {
    window.markdownStreamFixture?.setSideChatMotion("waiting");
  });
  await expect(
    fixture.locator(".comma-chat-activity-slot[data-active='true']")
  ).toHaveCount(1);
  await page.evaluate(() => {
    window.markdownStreamFixture?.setSideChatMotion(
      "streaming",
      "Reduced motion draft appears without translation."
    );
  });
  const reducedDraft = fixture.getByTestId("chat-assistant-draft");
  await expect(reducedDraft).toContainText("Reduced motion draft appears");
  const reducedMotion = await reducedDraft.evaluate((element) => {
    const style = getComputedStyle(element);
    return {
      animationDurations: element.getAnimations().map((animation) => {
        const duration = animation.effect?.getTiming().duration;
        return typeof duration === "number" ? duration : Number.NaN;
      }),
      durationMs: Number.parseFloat(style.animationDuration) * 1_000,
      opacity: Number.parseFloat(style.opacity),
      transform: style.transform,
    };
  });
  expect(reducedMotion.durationMs).toBe(0);
  expect(reducedMotion.animationDurations.every((duration) => duration === 0)).toBe(
    true
  );
  expect(reducedMotion.opacity).toBe(1);
  expect(["none", "matrix(1, 0, 0, 1, 0, 0)"]).toContain(reducedMotion.transform);
});

test("nested Markdown keeps block rhythm and visible code selection", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("markdown-stream-fixture");
  await setMarkdownContent(
    page,
    [
      "> First quoted paragraph.",
      ">",
      "> - Nested list item",
      "> - Second item",
      ">",
      "> ## Nested heading",
      ">",
      "> Last quoted paragraph.",
      "",
      "- First list paragraph.",
      "",
      "  Second list paragraph.",
    ].join("\n"),
    true
  );

  const quote = fixture.locator("blockquote");
  const listParagraphs = fixture
    .locator("li")
    .filter({ hasText: "First list paragraph." })
    .locator(":scope > p");
  await expect(quote.locator(":scope > p")).toHaveCount(2);
  await expect(quote.locator(":scope > ul")).toHaveCount(1);
  await expect(quote.locator(":scope > h2")).toHaveCount(1);
  await expect(listParagraphs).toHaveCount(2);
  for (const gap of await directChildGaps(quote)) {
    expect(gap).toBeGreaterThanOrEqual(8);
  }
  expect(await siblingGap(listParagraphs)).toBeGreaterThanOrEqual(8);

  await setMarkdownScenario(page, "final");
  await fixture.locator(".markdown-stream-code-body").scrollIntoViewIfNeeded();
  await expect(fixture.locator(".shiki .line > span").first()).toBeVisible({
    timeout: 20_000,
  });
  for (const theme of ["Light mode", "Dark mode"] as const) {
    await setMarkdownTheme(page, theme);
    await expect(page.locator("main")).toHaveAttribute("data-theme", theme);
    await expect(
      fixture
        .locator(
          ".markdown-stream-code-block:not(.markdown-stream-mermaid) .shiki .line > span"
        )
        .first()
    ).toBeVisible({ timeout: 20_000 });
    await expect
      .poll(async () => {
        try {
          const selection = await readCodeSelection(fixture);
          return contrastRatio(selection.background, selection.surface);
        } catch {
          return 0;
        }
      })
      .toBeGreaterThan(1.3);
  }
});

test("long code reveals one accessible control on hover or focus without covering its final line", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("markdown-stream-layout-fixture");
  const code = Array.from(
    { length: 37 },
    (_, index) => `const highlightedLine${index} = ${index}`
  ).join("\n");

  await setMarkdownContent(page, `\`\`\`ts\n${code}\n\`\`\``, true);

  const codeBlock = fixture.locator(".markdown-stream-code-block");
  const codeBody = codeBlock.locator(".markdown-stream-code-body");
  await codeBody.scrollIntoViewIfNeeded();
  await expect(
    codeBody.locator(".code-block-render:not(.code-block-render-pending) .shiki")
  ).toBeVisible({
    timeout: 20_000,
  });
  await expect
    .poll(async () => {
      const allCodeRenders = codeBody.locator(".code-block-render");
      const total = await allCodeRenders.count();
      return (
        total > 0 &&
        (await codeBody
          .locator(".code-block-render:not(.code-block-render-pending)")
          .count()) === total
      );
    })
    .toBe(true);
  await expect(codeBody).toHaveClass(/markdown-stream-code-body-collapsed/);
  await expect(codeBody.locator(".markdown-stream-code-fade")).toBeVisible();
  expect(
    await codeBody.evaluate((element) => element.getBoundingClientRect().height)
  ).toBe(480);

  const expand = codeBody.getByRole("button", { name: "Expand (37 lines)" });
  await expect(expand).toHaveCSS("opacity", "0");
  await expect(expand).toHaveCSS("pointer-events", "none");

  await expand.focus();
  await expect(expand).toHaveCSS("opacity", "1");
  await expect(expand).toHaveCSS("pointer-events", "auto");
  await expand.evaluate((element) => (element as HTMLElement).blur());
  await page.mouse.move(1, 1);
  await expect(expand).toHaveCSS("opacity", "0");

  await codeBlock.hover({ position: { x: 8, y: 8 } });
  await expect(expand).toHaveCSS("opacity", "1");
  await expect(expand).toHaveCSS("pointer-events", "auto");
  await expand.click();

  await expect(codeBody).not.toHaveClass(/markdown-stream-code-body-collapsed/);
  await expect(codeBody.locator(".markdown-stream-code-fade")).toHaveCount(0);
  expect(
    await codeBody.evaluate((element) => element.getBoundingClientRect().height)
  ).toBeGreaterThan(480);

  const collapse = codeBody.getByRole("button", { name: "Collapse" });
  await expect(codeBody.locator(".markdown-stream-code-expand")).toHaveCount(1);
  await collapse.evaluate((element) => (element as HTMLElement).blur());
  await page.mouse.move(1, 1);
  await expect(collapse).toHaveCSS("opacity", "0");
  await codeBlock.hover({ position: { x: 8, y: 8 } });
  await expect(collapse).toHaveCSS("opacity", "1");

  const finalLine = codeBody
    .locator(".code-block-render:not(.code-block-render-pending) .shiki .line")
    .last();
  await expect(finalLine).toContainText("const highlightedLine36 = 36");
  const [collapseBox, finalLineBox, codeBodyBox, expectedBottomInset] =
    await Promise.all([
      collapse.boundingBox(),
      finalLine.boundingBox(),
      codeBody.boundingBox(),
      codeBody.evaluate((element) =>
        Number.parseFloat(getComputedStyle(element).getPropertyValue("--spacing-md"))
      ),
    ]);
  if (!collapseBox || !finalLineBox || !codeBodyBox) {
    throw new Error(
      "Expected the expanded code body, control, and final code line to be visible."
    );
  }
  expect(
    codeBodyBox.y + codeBodyBox.height - (collapseBox.y + collapseBox.height)
  ).toBeCloseTo(expectedBottomInset, 1);
  expect(collapseBox.y).toBeGreaterThanOrEqual(finalLineBox.y + finalLineBox.height);

  await collapse.click();
  await expect(codeBody).toHaveClass(/markdown-stream-code-body-collapsed/);
});

test("a wheel over highlighted code wider than its block scrolls the code sideways", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("markdown-stream-layout-fixture");
  await setMarkdownContent(
    page,
    `\`\`\`ts\nexport const wide = "${"x".repeat(600)}";\n\`\`\``,
    true
  );

  const codeBody = fixture.locator(
    ".markdown-stream-code-block .markdown-stream-code-body"
  );
  await codeBody.scrollIntoViewIfNeeded();
  // Highlighting swaps the fallback for tokens inside a `pre` whose box never
  // changes, so the overflow it brings arrives without a resize to observe.
  await expect(
    codeBody.locator(".code-block-render:not(.code-block-render-pending) .shiki")
  ).toBeVisible({ timeout: 20_000 });
  const codeViewport = codeBody.locator(
    '[data-slot="scroll-area"][data-orientation="horizontal"] > [data-slot="scroll-area-viewport"]'
  );
  expect(
    await codeViewport.evaluate((element) => element.scrollWidth - element.clientWidth)
  ).toBeGreaterThan(200);

  await codeViewport.hover();
  await expect(
    codeBody.locator('[data-slot="scroll-area"][data-orientation="horizontal"]')
  ).toHaveAttribute("data-has-overflow-x", "true");
  await page.mouse.wheel(0, 120);
  await expect
    .poll(() => codeViewport.evaluate((element) => element.scrollLeft))
    .toBeGreaterThan(0);
});

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
    await setMarkdownContent(page, `\`\`\`ts\n${code}\n\`\`\``, true);

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

test("reduced motion removes code expansion control transitions", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto(fixtureUrl);
  const code = Array.from(
    { length: 37 },
    (_, index) => `const reducedMotionLine${index} = ${index}`
  ).join("\n");

  await setMarkdownContent(page, `\`\`\`ts\n${code}\n\`\`\``, true);

  const expand = page
    .getByTestId("markdown-stream-layout-fixture")
    .getByRole("button", { name: "Expand (37 lines)" });
  await expect(expand).toHaveCSS("transition-duration", "0s");
});

test("a streaming Shiki update that crosses 480px becomes collapsible", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("markdown-stream-layout-fixture");
  const shortCode = Array.from(
    { length: 8 },
    (_, index) => `const initialLine${index} = ${index}`
  ).join("\n");
  const longCode = Array.from(
    { length: 37 },
    (_, index) => `const streamedLine${index} = ${index}`
  ).join("\n");

  await setMarkdownContent(page, `\`\`\`ts\n${shortCode}`, false);
  const codeBody = fixture.locator(".markdown-stream-code-body");
  await codeBody.scrollIntoViewIfNeeded();
  const renderedCode = codeBody.locator(
    ".code-block-render:not(.code-block-render-pending) .shiki"
  );
  await expect(renderedCode).toContainText("const initialLine7 = 7", {
    timeout: 20_000,
  });
  await expect(codeBody.getByRole("button", { name: /Expand/ })).toHaveCount(0);

  await setMarkdownContent(page, `\`\`\`ts\n${longCode}`, false);
  await expect(renderedCode).toContainText("const streamedLine31 = 31", {
    timeout: 20_000,
  });
  await expect(renderedCode).not.toContainText("const streamedLine32 = 32");
  await expect(codeBody).toHaveClass(/markdown-stream-code-body-collapsed/);
  const expand = codeBody.getByRole("button", { name: "Expand (37 lines)" });
  await expect(expand).toHaveAttribute("aria-expanded", "false");
  await expand.focus();
  await expand.press("Enter");
  await expect(renderedCode).toContainText("const streamedLine36 = 36", {
    timeout: 20_000,
  });
});

test("stream completion preserves thematic-break spacing", async ({ page }) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("markdown-stream-layout-fixture");
  const content = [
    `Before the break. ${"Settled text ".repeat(12)}`,
    "",
    "---",
    "",
    `After the break. ${"Actively streaming text ".repeat(12)}`,
  ].join("\n");

  await setMarkdownContent(page, content, false);
  // The unified document keeps one scheduling host and three stable root slots
  // throughout streaming and completion. Finalization changes neither structure.
  await expect(fixture.locator(".markdown-renderer")).toHaveCount(1);
  await expect(fixture.locator(".markdown-renderer > .node-slot")).toHaveCount(3);
  await expect(fixture.locator("hr")).toBeVisible();
  await settleRenderedMarkdownLayout(fixture);
  // Read both rectangles in one browser task so scroll anchoring cannot split them.
  const streamingGap = await thematicBreakGap(fixture);

  await setMarkdownContent(page, content, true);
  await expect(fixture.locator(".markdown-renderer")).toHaveCount(1);
  await expect(fixture.locator(".markdown-renderer > .node-slot")).toHaveCount(3);
  await expect(fixture.locator("hr")).toBeVisible();
  await settleRenderedMarkdownLayout(fixture);
  const finalGap = await thematicBreakGap(fixture);

  expect(Math.abs(streamingGap - finalGap)).toBeLessThanOrEqual(1);
});

// Read geometry only after the fixture is visible and each root slot has real
// content. The document host now contains all three blocks, so its combined
// height is not a per-block visibility measurement.
async function settleRenderedMarkdownLayout(fixture: ReturnType<Page["locator"]>) {
  await fixture.scrollIntoViewIfNeeded();
  await expect
    .poll(() =>
      fixture.evaluate((root) =>
        Array.from(root.querySelectorAll(".node-slot > .node-content")).every(
          (renderer) => {
            const box = renderer.getBoundingClientRect();
            return box.height > 0 && box.height < 300;
          }
        )
      )
    )
    .toBe(true);
}

test("stream completion preserves block identity and thematic-break spacing", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  const fixture = page.getByTestId("markdown-stream-layout-fixture");
  const content = [
    `Before the break. ${"Settled text ".repeat(12)}`,
    "",
    "---",
    "",
    `After the break. ${"Actively streaming text ".repeat(12)}`,
  ].join("\n");

  await setMarkdownContent(page, content, false);
  await expect(fixture).toHaveAttribute("data-final", "false");
  const thematicBreak = fixture.locator("hr");
  await expect(thematicBreak).toBeVisible();
  await thematicBreak.evaluate((element) => {
    element.setAttribute("data-stream-node-identity", "preserved");
    element.parentElement?.setAttribute("data-stream-renderer-identity", "preserved");
  });
  const streamingGap = await thematicBreakGap(fixture);

  await setMarkdownContent(page, content, true);
  await expect(fixture).toHaveAttribute("data-final", "true");
  await expect(thematicBreak).toHaveAttribute("data-stream-node-identity", "preserved");
  await expect(thematicBreak.locator("..")).toHaveAttribute(
    "data-stream-renderer-identity",
    "preserved"
  );
  const finalGap = await thematicBreakGap(fixture);

  expect(Math.abs(streamingGap - finalGap)).toBeLessThanOrEqual(1);
});

async function setMarkdownScenario(
  page: Page,
  scenario: "intro" | "full" | "final" | "retarget-a" | "retarget-b"
) {
  await page.waitForFunction(() => Boolean(window.markdownStreamFixture));
  await page.evaluate((nextScenario) => {
    window.markdownStreamFixture?.setScenario(nextScenario);
  }, scenario);
}

async function setConversationStage(
  page: Page,
  stage: "history" | "sent" | "draft" | "draft-grown" | "final"
) {
  await page.waitForFunction(() => Boolean(window.markdownStreamFixture));
  await page.evaluate((nextStage) => {
    window.markdownStreamFixture?.setConversationStage(nextStage);
  }, stage);
}

type OutgoingMotionCapture = Awaited<ReturnType<typeof captureOutgoingUserMotion>>;

async function exerciseCollapsedOutgoingDisclosure(
  page: Page,
  text: string,
  reducedMotion: boolean
) {
  await page.waitForFunction(() => Boolean(window.markdownStreamFixture));
  return page.evaluate(
    async ({ messageText, shouldReduceMotion }) => {
      const controller = window.markdownStreamFixture;
      const root = document.querySelector<HTMLElement>(
        "[data-testid='outgoing-user-motion-fixture']"
      );
      if (!controller || !root) {
        throw new Error("Collapsed outgoing disclosure fixture was not ready.");
      }

      Object.assign(root.style, {
        background: "var(--color-bg-primary)",
        height: "720px",
        left: "32px",
        margin: "0",
        position: "fixed",
        top: "32px",
        width: "960px",
        zIndex: "100",
      });
      if (shouldReduceMotion) {
        document.documentElement.setAttribute("data-comma-reduced-motion", "true");
      } else {
        document.documentElement.removeAttribute("data-comma-reduced-motion");
      }
      controller.resetOutgoingUser();
      controller.setOutgoingUserText(messageText);
      await nextFrame(2);
      controller.startOutgoingUser();

      let article: HTMLElement | null = null;
      let bubble: HTMLElement | null = null;
      let disclosure: HTMLButtonElement | null = null;
      for (let attempt = 0; attempt < 120; attempt += 1) {
        await nextFrame();
        article = root.querySelector<HTMLElement>(
          '[data-message-id="outgoing-user-pending"]'
        );
        bubble = article?.querySelector<HTMLElement>(".comma-chat-user-bubble") ?? null;
        disclosure =
          article?.querySelector<HTMLButtonElement>(
            "button[aria-expanded][aria-controls]"
          ) ?? null;
        if (article && bubble && disclosure) break;
      }
      if (!article || !bubble || !disclosure) {
        throw new Error("Tall outgoing message did not expose its disclosure.");
      }

      // Disclosure owns a separate max-block-size transition. Let the send
      // spring release the same real bubble first so its transform cannot be
      // misclassified as disclosure motion or distort the 480px layout rect.
      let observedOutgoingSpring = false;
      for (let attempt = 0; attempt < 120; attempt += 1) {
        if (bubble.dataset.outgoingPresentation === "flying") {
          observedOutgoingSpring = true;
        } else if (observedOutgoingSpring) {
          break;
        }
        await nextFrame();
      }
      if (!observedOutgoingSpring) {
        throw new Error("Tall outgoing spring never started on its real bubble.");
      }
      if (bubble.dataset.outgoingPresentation === "flying") {
        throw new Error("Tall outgoing spring did not release its real bubble.");
      }

      const controlsId = disclosure.getAttribute("aria-controls");
      const content = controlsId ? document.getElementById(controlsId) : null;
      const fade = bubble.querySelector<HTMLElement>(".comma-chat-user-bubble-fade");
      const icon = disclosure.querySelector<HTMLElement>("[data-comma-icon]");
      const toggleRow = disclosure.closest<HTMLElement>(
        ".comma-chat-user-bubble-toggle-row"
      );
      if (!content || !fade || !icon || !toggleRow) {
        throw new Error(
          "Collapsed bubble content, fade, control row, or Central icon was missing."
        );
      }

      article.dataset.collapsedArticleIdentity = "preserved";
      bubble.dataset.collapsedBubbleIdentity = "preserved";
      content.dataset.collapsedTextIdentity = "preserved";
      const articleNode = article;
      const bubbleNode = bubble;
      const contentNode = content;
      const disclosureNode = disclosure;
      const toggleRowNode = toggleRow;
      const collapsedFrame = bubble.getBoundingClientRect();
      const fadeStyles = getComputedStyle(fade);
      const fadeGradient =
        fadeStyles.backgroundImage !== "none"
          ? fadeStyles.backgroundImage
          : fadeStyles.maskImage !== "none"
            ? fadeStyles.maskImage
            : fadeStyles.webkitMaskImage;
      const initialAccessibleName =
        disclosure.getAttribute("aria-label") ?? disclosure.textContent?.trim() ?? "";

      root.style.width = "720px";
      await nextFrame(3);
      const resizedCollapsedFrame = bubble.getBoundingClientRect();
      const collapsedFadeFrame = fade.getBoundingClientRect();
      const collapsedToggleFrame = disclosure.getBoundingClientRect();
      const collapsedControlRowPosition = getComputedStyle(toggleRow).position;
      const fullHeight = content.scrollHeight;

      disclosure.click();
      void bubble.offsetHeight;
      const expandSpatialAnimationProperties = spatialAnimationProperties(bubble);
      await waitForDisclosureState(disclosure, true, () => {
        return content.getBoundingClientRect().height >= fullHeight - 1;
      });
      const expandedFrame = bubble.getBoundingClientRect();
      const expandedContentFrame = content.getBoundingClientRect();
      const expandedToggleFrame = disclosure.getBoundingClientRect();
      const expandedLastGlyphFrame = lastGlyphRect(content);
      const expandedControlRowStyles = getComputedStyle(toggleRow);
      const expandedControlRowMarginTop = Number.parseFloat(
        expandedControlRowStyles.marginTop
      );
      const expandedControlRowPosition = expandedControlRowStyles.position;
      const expandedBubbleStyles = getComputedStyle(bubble);
      const expandedBottomPadding = Number.parseFloat(
        expandedBubbleStyles.paddingBottom
      );
      const expandedIconFrame = icon.getBoundingClientRect();
      const rootStyles = getComputedStyle(document.documentElement);
      const spacingXs = Number.parseFloat(rootStyles.getPropertyValue("--spacing-xs"));
      const spacingXl = Number.parseFloat(rootStyles.getPropertyValue("--spacing-xl"));
      const spacing2xl = Number.parseFloat(
        rootStyles.getPropertyValue("--spacing-2xl")
      );
      const spacing4xl = Number.parseFloat(
        rootStyles.getPropertyValue("--spacing-4xl")
      );
      const expandedAccessibleName =
        disclosure.getAttribute("aria-label") ?? disclosure.textContent?.trim() ?? "";

      controller.ackOutgoingUser();
      await nextFrame(2);
      const canonicalArticle = root.querySelector<HTMLElement>(
        '[data-message-id="outgoing-user-canonical"]'
      );
      const expandedSurvivedAck =
        canonicalArticle === articleNode &&
        canonicalArticle?.querySelector(".comma-chat-user-bubble") === bubbleNode &&
        disclosure.getAttribute("aria-expanded") === "true";

      controller.failOutgoingUser();
      await nextFrame(2);
      const failedArticle = root.querySelector<HTMLElement>(
        '[data-message-id="outgoing-user-pending"]'
      );
      const expandedSurvivedFailure =
        failedArticle === articleNode &&
        failedArticle?.querySelector(".comma-chat-user-bubble") === bubbleNode &&
        disclosure.getAttribute("aria-expanded") === "true";

      disclosure.click();
      void bubble.offsetHeight;
      const collapseSpatialAnimationProperties = spatialAnimationProperties(bubble);
      await waitForDisclosureState(disclosure, false, () => {
        return bubble!.getBoundingClientRect().height <= 481;
      });
      const recollapsedFrame = bubble.getBoundingClientRect();
      const recollapsedFadeFrame = fade.getBoundingClientRect();
      const recollapsedToggleFrame = disclosure.getBoundingClientRect();
      const recollapsedControlRowPosition = getComputedStyle(toggleRow).position;

      const result = {
        bubbleIdentityPreserved:
          bubbleNode.dataset.collapsedBubbleIdentity === "preserved" &&
          articleNode.querySelector(".comma-chat-user-bubble") === bubbleNode,
        centralIconPreserved:
          icon.hasAttribute("data-comma-icon") &&
          icon.getAttribute("aria-hidden") === "true",
        collapseSpatialAnimationProperties,
        collapsedAgain: disclosure.getAttribute("aria-expanded") === "false",
        collapsedHeight: collapsedFrame.height,
        collapsedToggleFadeCenterDeltaX: centerDeltaX(
          collapsedToggleFrame,
          collapsedFadeFrame
        ),
        collapsedToggleInsideFade: containsRect(
          collapsedFadeFrame,
          collapsedToggleFrame
        ),
        collapsedControlRowPosition,
        destinationIdentityPreserved:
          articleNode.dataset.collapsedArticleIdentity === "preserved" &&
          failedArticle === articleNode,
        expandSpatialAnimationProperties,
        expandTopDelta: Math.abs(expandedFrame.top - resizedCollapsedFrame.top),
        expanded: expandedFrame.height >= fullHeight - 1,
        expandedAccessibleName,
        expandedBottomPadding,
        expandedControlGap: expandedToggleFrame.top - expandedLastGlyphFrame.bottom,
        expandedControlRowHeight: expandedFrame.bottom - expandedContentFrame.bottom,
        expandedControlRowMarginTop,
        expandedControlRowPosition,
        expandedHeight: expandedFrame.height,
        expandedIconHeight: expandedIconFrame.height,
        expandedIconWidth: expandedIconFrame.width,
        expandedLastGlyphControlOverlap: intersectionArea(
          expandedLastGlyphFrame,
          expandedToggleFrame
        ),
        expandedSurvivedAck,
        expandedSurvivedFailure,
        expandedToggleHeight: expandedToggleFrame.height,
        fadeBackdropFilter:
          fadeStyles.backdropFilter !== "none"
            ? fadeStyles.backdropFilter
            : fadeStyles.getPropertyValue("-webkit-backdrop-filter"),
        fadeGradient,
        fadeGradientStopCount: gradientStopCount(fadeGradient),
        fullHeight,
        initialAccessibleName,
        recollapseTopDelta: Math.abs(recollapsedFrame.top - resizedCollapsedFrame.top),
        recollapsedHeight: recollapsedFrame.height,
        recollapsedControlRowPosition,
        recollapsedToggleFadeCenterDeltaX: centerDeltaX(
          recollapsedToggleFrame,
          recollapsedFadeFrame
        ),
        recollapsedToggleInsideFade: containsRect(
          recollapsedFadeFrame,
          recollapsedToggleFrame
        ),
        resizeTopDelta: Math.abs(resizedCollapsedFrame.top - collapsedFrame.top),
        resizedCollapsedHeight: resizedCollapsedFrame.height,
        spacing2xl,
        spacing4xl,
        spacingXl,
        spacingXs,
        textIdentityPreserved:
          contentNode.dataset.collapsedTextIdentity === "preserved" &&
          bubbleNode.contains(contentNode),
        textLength: contentNode.textContent?.length ?? 0,
        toggleIdentityPreserved:
          disclosureNode ===
            articleNode.querySelector("button[aria-expanded][aria-controls]") &&
          disclosureNode.isConnected,
        toggleRowIdentityPreserved:
          toggleRowNode ===
            articleNode.querySelector(".comma-chat-user-bubble-toggle-row") &&
          toggleRowNode.contains(disclosureNode) &&
          toggleRowNode.isConnected,
      };
      document.documentElement.removeAttribute("data-comma-reduced-motion");
      return result;

      // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
      function spatialAnimationProperties(element: HTMLElement) {
        const spatialProperties = new Set([
          "blockSize",
          "clipPath",
          "height",
          "insetBlockEnd",
          "insetBlockStart",
          "maxBlockSize",
          "maxHeight",
          "scale",
          "transform",
          "translate",
        ]);
        const observed = new Set<string>();
        for (const animation of element.getAnimations({ subtree: true })) {
          const effect = animation.effect;
          if (!(effect instanceof KeyframeEffect)) continue;
          for (const keyframe of effect.getKeyframes()) {
            for (const property of Object.keys(keyframe)) {
              if (spatialProperties.has(property)) observed.add(property);
            }
          }
        }
        return [...observed].toSorted();
      }

      // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
      function gradientStopCount(value: string) {
        return (
          value.match(
            /(?:rgba?\(|hsla?\(|oklch\(|color\(|#[\da-f]{3,8}\b|transparent\b)/gi
          )?.length ?? 0
        );
      }

      // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
      function lastGlyphRect(element: HTMLElement) {
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
        let glyphNode: Text | null = null;
        let glyphOffset = -1;
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const value = node.textContent ?? "";
          for (let index = value.length - 1; index >= 0; index -= 1) {
            if (!/\s/u.test(value[index]!)) {
              glyphNode = node as Text;
              glyphOffset = index;
              break;
            }
          }
        }
        if (!glyphNode || glyphOffset < 0) {
          throw new Error("Expanded outgoing content had no final glyph rect.");
        }
        if (
          glyphOffset > 0 &&
          /[\uDC00-\uDFFF]/u.test(glyphNode.data[glyphOffset]!) &&
          /[\uD800-\uDBFF]/u.test(glyphNode.data[glyphOffset - 1]!)
        ) {
          glyphOffset -= 1;
        }
        const glyphLength =
          (glyphNode.data.codePointAt(glyphOffset) ?? 0) > 0xffff ? 2 : 1;
        const range = document.createRange();
        range.setStart(glyphNode, glyphOffset);
        range.setEnd(glyphNode, glyphOffset + glyphLength);
        return range.getBoundingClientRect();
      }

      // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
      function centerDeltaX(first: DOMRect, second: DOMRect) {
        return Math.abs(
          first.left + first.width / 2 - (second.left + second.width / 2)
        );
      }

      // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
      function containsRect(container: DOMRect, item: DOMRect) {
        return (
          item.left >= container.left - 1 &&
          item.right <= container.right + 1 &&
          item.top >= container.top - 1 &&
          item.bottom <= container.bottom + 1
        );
      }

      // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
      function intersectionArea(first: DOMRect, second: DOMRect) {
        return (
          Math.max(
            0,
            Math.min(first.right, second.right) - Math.max(first.left, second.left)
          ) *
          Math.max(
            0,
            Math.min(first.bottom, second.bottom) - Math.max(first.top, second.top)
          )
        );
      }

      async function waitForDisclosureState(
        button: HTMLButtonElement,
        expanded: boolean,
        geometryReady: () => boolean
      ) {
        for (let attempt = 0; attempt < 180; attempt += 1) {
          await nextFrame();
          if (
            button.getAttribute("aria-expanded") === String(expanded) &&
            geometryReady()
          ) {
            return;
          }
        }
        throw new Error(
          `Collapsed outgoing disclosure did not reach expanded=${expanded}.`
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
    { messageText: text, shouldReduceMotion: reducedMotion }
  );
}

async function captureFailedOutgoingHandoff(page: Page) {
  await page.waitForFunction(() => Boolean(window.markdownStreamFixture));
  return page.evaluate(async () => {
    const controller = window.markdownStreamFixture;
    const root = document.querySelector<HTMLElement>(
      "[data-testid='outgoing-user-motion-fixture']"
    );
    if (!controller || !root) {
      throw new Error("Outgoing user motion fixture was not ready.");
    }

    Object.assign(root.style, {
      background: "var(--color-bg-primary)",
      left: "32px",
      margin: "0",
      position: "fixed",
      top: "32px",
      width: "960px",
      zIndex: "100",
    });
    controller.resetOutgoingUser();
    await nextFrame(2);
    controller.startOutgoingUser();

    let destination: HTMLElement | null = null;
    let bubble: HTMLElement | null = null;
    let animation: Animation | null = null;
    for (let attempt = 0; attempt < 40; attempt += 1) {
      await nextFrame();
      destination = root.querySelector<HTMLElement>(
        '[data-message-id="outgoing-user-pending"]'
      );
      bubble =
        destination?.querySelector<HTMLElement>(
          '.comma-chat-user-bubble[data-outgoing-presentation="flying"]'
        ) ?? null;
      animation = bubble?.getAnimations()[0] ?? null;
      if (animation && bubble && destination) break;
    }
    if (!destination || !bubble || !animation) {
      throw new Error("The real outgoing user bubble did not start in Chromium.");
    }

    const destinationNode = destination;
    const bubbleNode = bubble;
    const initialAnimation = animation;
    // Frame zero is deliberately paused. Lock the clock when playback starts;
    // later ACKs and failures must preserve that clock and the same object.
    let initialStartTime = initialAnimation.startTime;
    const initialTargetFrame = targetRectFromFlightStyles(bubble);
    const duration = Number(initialAnimation.effect?.getTiming().duration);
    const failureAt = duration * 0.82;
    let lastCurrentTime = 0;
    for (let attempt = 0; attempt < 120; attempt += 1) {
      await nextFrame();
      const currentTime = Number(initialAnimation.currentTime ?? 0);
      lastCurrentTime = currentTime;
      if (currentTime >= failureAt) break;
    }
    if (lastCurrentTime < failureAt) {
      throw new Error("Outgoing spring settled before the failure injection point.");
    }

    const preFailureBubbleFrame = bubble.getBoundingClientRect();
    const positions: Array<{ bottom: number; failed: boolean; right: number }> = [
      {
        bottom: preFailureBubbleFrame.bottom,
        failed: false,
        right: preFailureBubbleFrame.right,
      },
    ];
    let failureRendered = false;
    let failedTargetFrame: ReturnType<typeof targetRectFromFlightStyles> | undefined;
    let animationIdentityPreserved = true;
    let animationTimesMonotonic = true;
    let articleIdentityPreserved = true;
    let bubbleIdentityPreserved = true;
    let previousAnimationTime = Number(initialAnimation.currentTime ?? 0);
    let lastFlyingFrame: DOMRect | undefined;
    let finalBubbleFrame: DOMRect | undefined;
    let maximumBubbleCount = 1;
    let maximumRenderedTextCopies = 1;
    controller.failOutgoingUser();

    for (let attempt = 0; attempt < 260; attempt += 1) {
      await nextFrame();
      const currentDestination = root.querySelector<HTMLElement>(
        '[data-message-id="outgoing-user-pending"]'
      );
      const currentBubble = currentDestination?.querySelector<HTMLElement>(
        ".comma-chat-user-bubble"
      );
      articleIdentityPreserved &&= currentDestination === destinationNode;
      bubbleIdentityPreserved &&= currentBubble === bubbleNode;
      const currentBubbles = [
        ...root.querySelectorAll<HTMLElement>(".comma-chat-user-bubble"),
      ];
      maximumBubbleCount = Math.max(maximumBubbleCount, currentBubbles.length);
      maximumRenderedTextCopies = Math.max(
        maximumRenderedTextCopies,
        currentBubbles.filter(
          (candidate) => candidate.textContent === bubbleNode.textContent
        ).length
      );
      const failedRow = currentDestination?.querySelector(
        "[data-testid='chat-failed-row']"
      );
      if (failedRow && !failureRendered && currentBubble) {
        failureRendered = true;
        failedTargetFrame =
          currentBubble.dataset.outgoingPresentation === "flying"
            ? targetRectFromFlightStyles(currentBubble)
            : plainRect(currentBubble.getBoundingClientRect());
      }

      if (currentBubble?.dataset.outgoingPresentation === "flying") {
        const currentAnimation = currentBubble.getAnimations()[0];
        initialStartTime ??= initialAnimation.startTime;
        animationIdentityPreserved &&=
          currentAnimation === initialAnimation &&
          initialAnimation.startTime === initialStartTime;
        const currentTime = Number(initialAnimation.currentTime ?? 0);
        animationTimesMonotonic &&= currentTime + 0.1 >= previousAnimationTime;
        previousAnimationTime = currentTime;
        lastFlyingFrame = currentBubble.getBoundingClientRect();
        positions.push({
          bottom: lastFlyingFrame.bottom,
          failed: Boolean(failedRow),
          right: lastFlyingFrame.right,
        });
        continue;
      }

      if (failureRendered && currentBubble) {
        finalBubbleFrame = currentBubble.getBoundingClientRect();
        positions.push({
          bottom: finalBubbleFrame.bottom,
          failed: true,
          right: finalBubbleFrame.right,
        });
        break;
      }
    }

    if (!lastFlyingFrame || !finalBubbleFrame) {
      throw new Error(
        "Failed outgoing spring did not complete its presentation handoff."
      );
    }

    const failureSampleIndex = positions.findIndex((position) => position.failed);
    const failureSample = positions[failureSampleIndex];
    const preFailureSample = positions[failureSampleIndex - 1];

    return {
      animationIdentityPreserved,
      animationRestartCount: animationIdentityPreserved ? 0 : 1,
      animationTimesMonotonic,
      articleIdentityPreserved,
      bubbleIdentityPreserved,
      destinationIdentityPreserved:
        root.querySelector('[data-message-id="outgoing-user-pending"]') ===
        destinationNode,
      failedDestinationGeometryDelta: failedTargetFrame
        ? frameDelta(initialTargetFrame, failedTargetFrame)
        : Number.POSITIVE_INFINITY,
      failureBoundaryJump:
        failureSample && preFailureSample
          ? Math.hypot(
              failureSample.right - preFailureSample.right,
              failureSample.bottom - preFailureSample.bottom
            )
          : Number.POSITIVE_INFINITY,
      failureRendered,
      handoffEdgeDelta: frameDelta(lastFlyingFrame, finalBubbleFrame),
      maximumBubbleCount,
      maximumPostFailureFrameJump: positions
        .filter((position) => position.failed)
        .slice(1)
        .reduce((maximum, frame, index) => {
          const failedPositions = positions.filter((position) => position.failed);
          const previous = failedPositions[index]!;
          return Math.max(
            maximum,
            Math.hypot(frame.right - previous.right, frame.bottom - previous.bottom)
          );
        }, 0),
      maximumRenderedTextCopies,
      visibleBubbleIdentityPreserved:
        root.querySelector(
          '[data-message-id="outgoing-user-pending"] .comma-chat-user-bubble'
        ) === bubbleNode,
    };

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
    function plainRect(rect: DOMRect) {
      return {
        bottom: rect.bottom,
        height: rect.height,
        left: rect.left,
        right: rect.right,
        top: rect.top,
        width: rect.width,
      };
    }

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
    function targetRectFromFlightStyles(element: HTMLElement) {
      const left = Number.parseFloat(element.style.left);
      const top = Number.parseFloat(element.style.top);
      const width = Number.parseFloat(element.style.width);
      const height = Number.parseFloat(element.style.height);
      return {
        bottom: top + height,
        height,
        left,
        right: left + width,
        top,
        width,
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
  });
}

async function captureConversationViewRejectedSendHandoff(page: Page) {
  const fixture = page.getByTestId("conversation-view-rejected-send-fixture");
  const sendButton = fixture.getByRole("button", { name: "Send message" });
  await expect(sendButton).toBeEnabled();
  await page.waitForFunction(() => Boolean(window.conversationViewRejectedSendFixture));

  return fixture.evaluate(async (root) => {
    const messageSelector =
      '[data-message-id="pending:conversation-view-plain-rejection"]';
    const presentationReady = new Promise<{
      animation: Animation;
      article: HTMLElement;
      bubble: HTMLElement;
    }>((resolvePresentation, rejectPresentation) => {
      let resolved = false;
      const timeout = window.setTimeout(() => {
        observer.disconnect();
        rejectPresentation(
          new Error("Observer did not capture the rejected-send presentation.")
        );
      }, 2_000);
      const inspect = () => {
        if (resolved) return;
        const article = root.querySelector<HTMLElement>(messageSelector);
        const bubble = article?.querySelector<HTMLElement>(
          '.comma-chat-user-bubble[data-outgoing-presentation="flying"]'
        );
        const animation = bubble?.getAnimations()[0];
        if (!article || !bubble || !animation) return;
        resolved = true;
        window.clearTimeout(timeout);
        observer.disconnect();
        resolvePresentation({ animation, article, bubble });
      };
      const observer = new MutationObserver(inspect);
      observer.observe(root, {
        attributes: true,
        childList: true,
        subtree: true,
      });
      inspect();
    });
    const sendButtonElement = root.querySelector<HTMLButtonElement>(
      'button[aria-label="Send message"]'
    );
    if (!sendButtonElement) {
      throw new Error("ConversationView send button was not available.");
    }
    sendButtonElement.click();
    const { animation, article, bubble } = await presentationReady;

    const articleNode = article;
    const bubbleNode = bubble;
    const animationNode = animation;
    const animationDuration = Number(animation.effect?.getTiming().duration);
    let initialStartTime = animation.startTime;
    let lastAnimationTime = Number(animation.currentTime ?? 0);
    const initialTargetFrame = targetRectFromFlightStyles(bubble);
    const shapeSamples: Array<{ bottom: number; failed: boolean; right: number }> = [];
    let failureRendered = false;
    let failureSampleIndex = -1;
    let failureAnimationTime = Number.POSITIVE_INFINITY;
    let failedTargetFrame: ReturnType<typeof targetRectFromFlightStyles> | undefined;
    let bubbleFlyingAtFailure = false;
    let bubbleFramesAfterFailure = 0;
    let animationIdentityPreserved = true;
    let animationTimesMonotonic = true;
    let animationRestartCount = 0;
    let articleIdentityPreserved = true;
    let bubbleIdentityPreserved = true;
    let lastFlyingFrame: DOMRect | undefined;
    let lastFlyingAnimationTime = 0;
    let finalBubbleFrame: DOMRect | undefined;
    let maximumBubbleCount = 1;
    let maximumRenderedTextCopies = 1;

    for (let attempt = 0; attempt < 60; attempt += 1) {
      await nextFrame();
      const currentArticle = root.querySelector<HTMLElement>(messageSelector);
      const currentBubble = currentArticle?.querySelector<HTMLElement>(
        ".comma-chat-user-bubble"
      );
      articleIdentityPreserved &&= currentArticle === articleNode;
      bubbleIdentityPreserved &&= currentBubble === bubbleNode;
      if (currentBubble?.dataset.outgoingPresentation !== "flying") {
        throw new Error("Outgoing spring ended before deferred failure was released.");
      }
      const currentAnimation = currentBubble.getAnimations()[0];
      if (currentAnimation && currentAnimation !== animationNode) {
        animationRestartCount += 1;
      }
      initialStartTime ??= animationNode.startTime;
      animationIdentityPreserved &&=
        currentAnimation === animationNode &&
        animationNode.startTime === initialStartTime;
      const currentTime = Number(animationNode.currentTime ?? 0);
      animationTimesMonotonic &&= currentTime + 0.1 >= lastAnimationTime;
      lastAnimationTime = currentTime;
      lastFlyingFrame = currentBubble.getBoundingClientRect();
      lastFlyingAnimationTime = currentTime;
      shapeSamples.push({
        bottom: lastFlyingFrame.bottom,
        failed: false,
        right: lastFlyingFrame.right,
      });
      if (currentTime >= 200 && shapeSamples.length >= 2) break;
    }
    const preFailureSampleCount = shapeSamples.length;
    if (lastFlyingAnimationTime < 200 || preFailureSampleCount < 2) {
      throw new Error("Deferred failure was not preceded by stable spring samples.");
    }
    const deferredRejectTriggered =
      window.conversationViewRejectedSendFixture?.reject() ?? false;
    if (!deferredRejectTriggered) {
      throw new Error("Deferred plain Promise rejection was not armed.");
    }

    // The side-chat fixture can publish Activity just after 1s while Chromium
    // samples requestAnimationFrame near 120Hz. Keep enough frames to observe
    // the full 520ms stability window after that publication.
    for (let attempt = 0; attempt < 210; attempt += 1) {
      await nextFrame();
      const currentArticle = root.querySelector<HTMLElement>(messageSelector);
      const currentBubble = currentArticle?.querySelector<HTMLElement>(
        ".comma-chat-user-bubble"
      );
      articleIdentityPreserved &&= currentArticle === articleNode;
      bubbleIdentityPreserved &&= currentBubble === bubbleNode;
      const currentBubbles = [
        ...root.querySelectorAll<HTMLElement>(".comma-chat-user-bubble"),
      ];
      maximumBubbleCount = Math.max(maximumBubbleCount, currentBubbles.length);
      maximumRenderedTextCopies = Math.max(
        maximumRenderedTextCopies,
        currentBubbles.filter(
          (candidate) => candidate.textContent === bubbleNode.textContent
        ).length
      );

      const currentlyFailed = Boolean(
        currentArticle?.querySelector("[data-testid='chat-failed-row']")
      );
      if (currentlyFailed && !failureRendered) {
        failureRendered = true;
        failureAnimationTime = Number(animationNode.currentTime ?? 0);
        bubbleFlyingAtFailure =
          currentBubble?.dataset.outgoingPresentation === "flying";
        if (currentBubble) {
          failedTargetFrame = bubbleFlyingAtFailure
            ? targetRectFromFlightStyles(currentBubble)
            : plainRect(currentBubble.getBoundingClientRect());
        }
      }

      if (currentBubble?.dataset.outgoingPresentation === "flying") {
        const currentAnimation = currentBubble.getAnimations()[0];
        if (currentAnimation && currentAnimation !== animationNode) {
          animationRestartCount += 1;
        }
        initialStartTime ??= animationNode.startTime;
        animationIdentityPreserved &&=
          currentAnimation === animationNode &&
          animationNode.startTime === initialStartTime;
        const currentTime = Number(animationNode.currentTime ?? 0);
        animationTimesMonotonic &&= currentTime + 0.1 >= lastAnimationTime;
        lastAnimationTime = currentTime;
        lastFlyingFrame = currentBubble.getBoundingClientRect();
        lastFlyingAnimationTime = currentTime;
        shapeSamples.push({
          bottom: lastFlyingFrame.bottom,
          failed: currentlyFailed,
          right: lastFlyingFrame.right,
        });
        if (currentlyFailed) {
          bubbleFramesAfterFailure += 1;
          if (failureSampleIndex < 0) {
            failureSampleIndex = shapeSamples.length - 1;
          }
        }
        continue;
      }

      if (!failureRendered) {
        throw new Error(
          "Plain Promise rejection ended the outgoing presentation before failure rendered."
        );
      }
      finalBubbleFrame = currentBubble?.getBoundingClientRect();
      break;
    }

    if (!lastFlyingFrame || !finalBubbleFrame || !failedTargetFrame) {
      throw new Error(
        "ConversationView rejected send did not complete its natural handoff."
      );
    }

    const recentPreFailureStart = Math.max(1, failureSampleIndex - 5);
    const recentPreFailureSteps = shapeSamples
      .slice(recentPreFailureStart, failureSampleIndex)
      .map((sample, index) => {
        const previous = shapeSamples[recentPreFailureStart + index - 1]!;
        return Math.hypot(
          sample.right - previous.right,
          sample.bottom - previous.bottom
        );
      });
    const failureSample = shapeSamples[failureSampleIndex];
    const preFailureSample = shapeSamples[failureSampleIndex - 1];
    const failureBoundaryJump =
      failureSample && preFailureSample
        ? Math.hypot(
            failureSample.right - preFailureSample.right,
            failureSample.bottom - preFailureSample.bottom
          )
        : Number.POSITIVE_INFINITY;
    const maximumExpectedFailureBoundaryJump = Math.max(
      12,
      Math.max(0, ...recentPreFailureSteps) * 1.75
    );

    return {
      animationIdentityPreserved,
      animationRestartCount,
      animationTimesMonotonic,
      articleIdentityPreserved,
      bubbleIdentityPreserved,
      bubbleFlyingAtFailure,
      bubbleFramesAfterFailure,
      deferredRejectTriggered,
      failedBubbleGeometryDelta: frameDelta(initialTargetFrame, failedTargetFrame),
      failureAnimationTime,
      failureBoundaryJump,
      failureRendered,
      handoffEdgeDelta: frameDelta(lastFlyingFrame, finalBubbleFrame),
      handoffReachedNaturalEnd:
        Number.isFinite(animationDuration) &&
        lastFlyingAnimationTime >= animationDuration - 34,
      maximumBubbleCount,
      maximumExpectedFailureBoundaryJump,
      maximumRenderedTextCopies,
      observerReadyBeforeReject: true,
      preFailureSampleCount,
      visibleBubbleIdentityPreserved:
        root.querySelector(`${messageSelector} .comma-chat-user-bubble`) === bubbleNode,
    };

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
    function plainRect(rect: DOMRect) {
      return {
        bottom: rect.bottom,
        height: rect.height,
        left: rect.left,
        right: rect.right,
        top: rect.top,
        width: rect.width,
      };
    }

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
    function targetRectFromFlightStyles(element: HTMLElement) {
      const left = Number.parseFloat(element.style.left);
      const top = Number.parseFloat(element.style.top);
      const width = Number.parseFloat(element.style.width);
      const height = Number.parseFloat(element.style.height);
      return {
        bottom: top + height,
        height,
        left,
        right: left + width,
        top,
        width,
      };
    }

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
    async function nextFrame(count = 1) {
      for (let index = 0; index < count; index += 1) {
        await new Promise<void>((resolveFrame) =>
          requestAnimationFrame(() => resolveFrame())
        );
      }
    }
  });
}

async function captureOutgoingUserMotion(
  page: Page,
  mode: "full" | "manual" | "system"
) {
  await page.waitForFunction(() => Boolean(window.markdownStreamFixture));
  return page.evaluate(async (motionMode) => {
    const controller = window.markdownStreamFixture;
    const root = document.querySelector<HTMLElement>(
      "[data-testid='outgoing-user-motion-fixture']"
    );
    const composer = root?.querySelector<HTMLElement>(
      "[data-testid='outgoing-user-composer']"
    );
    const sourceSurface = root?.querySelector<HTMLElement>(
      "[data-testid='outgoing-user-composer-surface']"
    );
    if (!controller || !root || !composer || !sourceSurface) {
      throw new Error("Outgoing user motion fixture was not ready.");
    }

    // Keep this one fixture in a viewport-local coordinate space. The full
    // markdown harness is intentionally very tall, and document scroll
    // anchoring must not become an extra motion input for this component test.
    Object.assign(root.style, {
      background: "var(--color-bg-primary)",
      left: "32px",
      margin: "0",
      position: "fixed",
      top: "32px",
      width: "960px",
      zIndex: "100",
    });

    if (motionMode === "manual") {
      document.documentElement.setAttribute("data-comma-reduced-motion", "true");
    } else {
      document.documentElement.removeAttribute("data-comma-reduced-motion");
    }
    controller.resetOutgoingUser();
    await new Promise<void>((resolveFrame) =>
      requestAnimationFrame(() => requestAnimationFrame(() => resolveFrame()))
    );

    composer.dataset.fixtureIdentity = "preserved";
    const composerNode = composer;
    const composerBefore = plainRect(composer.getBoundingClientRect());
    const sourceSurfaceFrame = plainRect(sourceSurface.getBoundingClientRect());
    const captureStartedAt = performance.now();
    const presentationReady = new Promise<{
      animation: Animation;
      bubble: HTMLElement;
      destination: HTMLElement;
      keyframeZeroFrame: ReturnType<typeof plainRect>;
      keyframeZeroOffset: number;
      observerAnimationCurrentTime: number;
    }>((resolvePresentation, rejectPresentation) => {
      let resolved = false;
      const timeout = window.setTimeout(() => {
        observer.disconnect();
        rejectPresentation(
          new Error("MutationObserver did not capture the outgoing presentation.")
        );
      }, 2_000);
      const inspect = () => {
        if (resolved) return;
        const destination = root.querySelector<HTMLElement>(
          '[data-message-id="outgoing-user-pending"]'
        );
        const bubble = destination?.querySelector<HTMLElement>(
          '.comma-chat-user-bubble[data-outgoing-presentation="flying"]'
        );
        const animation = bubble?.getAnimations()[0];
        const effect = animation?.effect;
        if (
          !destination ||
          !bubble ||
          !animation ||
          !(effect instanceof KeyframeEffect)
        ) {
          return;
        }
        const keyframeZero = effect.getKeyframes()[0];
        if (!keyframeZero) return;
        const targetFrame =
          motionMode === "full"
            ? targetRectFromFlightStyles(bubble)
            : plainRect(bubble.getBoundingClientRect());
        const origin = getComputedStyle(bubble)
          .transformOrigin.split(" ")
          .map((value) => Number.parseFloat(value));
        const keyframeZeroFrame = rectAtTransform(
          targetFrame,
          String(keyframeZero.transform ?? "none"),
          origin[0] ?? targetFrame.width / 2,
          origin[1] ?? targetFrame.height / 2
        );
        resolved = true;
        window.clearTimeout(timeout);
        observer.disconnect();
        resolvePresentation({
          animation,
          bubble,
          destination,
          keyframeZeroFrame,
          keyframeZeroOffset: Number(keyframeZero.computedOffset),
          observerAnimationCurrentTime: Number(animation.currentTime ?? 0),
        });
      };
      const observer = new MutationObserver(inspect);
      observer.observe(root, {
        attributes: true,
        childList: true,
        subtree: true,
      });
      inspect();
    });
    controller.startOutgoingUser();
    const observedPresentation = await presentationReady;
    const { animation, bubble, destination } = observedPresentation;

    destination.dataset.outgoingDestinationIdentity = "preserved";
    const destinationNode = destination;
    const bubbleNode = bubble;
    const animationNode = animation;
    let initialAnimationStartTime = animation.startTime;
    const destinationFrame =
      motionMode === "full"
        ? targetRectFromFlightStyles(bubble)
        : plainRect(bubble.getBoundingClientRect());
    const flightUsedTopLayer = motionMode === "full" && bubble.matches(":popover-open");
    const popoverMode = bubble.getAttribute("popover");
    const springSource = bubble.dataset.springSource ?? "";
    const bubbleOriginParts = getComputedStyle(bubble)
      .transformOrigin.split(" ")
      .map((value) => Number.parseFloat(value));
    const animations = [animation];
    const animationDurations = animations.map((currentAnimation) => {
      const duration = currentAnimation.effect?.getTiming().duration;
      return typeof duration === "number" ? duration : Number.NaN;
    });
    const ignoredKeyframeFields = new Set([
      "composite",
      "computedOffset",
      "easing",
      "offset",
    ]);
    const animatedProperties = new Set<string>();
    for (const currentAnimation of animations) {
      const effect = currentAnimation.effect;
      if (!(effect instanceof KeyframeEffect)) continue;
      for (const keyframe of effect.getKeyframes()) {
        for (const property of Object.keys(keyframe)) {
          if (!ignoredKeyframeFields.has(property)) {
            animatedProperties.add(property);
          }
        }
      }
    }
    // The material changes on its own plane behind the shape (the bubble's
    // ::before), so a translucent material never shows twice over the box.
    const materialProperties = new Set<string>();
    for (const currentAnimation of bubble.getAnimations({ subtree: true })) {
      const effect = currentAnimation.effect;
      if (!(effect instanceof KeyframeEffect) || effect.pseudoElement !== "::before") {
        continue;
      }
      for (const keyframe of effect.getKeyframes()) {
        for (const property of Object.keys(keyframe)) {
          if (!ignoredKeyframeFields.has(property)) materialProperties.add(property);
        }
      }
    }
    const bubbleStyles = getComputedStyle(bubble);
    const bubbleOverflow = [bubbleStyles.overflowX, bubbleStyles.overflowY];

    // ACK on the first observable animation frame. The pending and canonical
    // messages share clientRequestId, so their destination element must survive.
    controller.ackOutgoingUser();
    let canonicalDestination: HTMLElement | null = null;
    for (let attempt = 0; attempt < 10; attempt += 1) {
      await nextFrame();
      canonicalDestination = root.querySelector<HTMLElement>(
        '[data-message-id="outgoing-user-canonical"]'
      );
      if (canonicalDestination) break;
    }

    const frames: Array<{
      bubbleBottom: number;
      bubbleHeight: number;
      bubbleScale: number;
      bubbleRight: number;
      elapsedMs: number;
    }> = [];
    const filters = new Set<string>();
    let maximumBubbleCount = 0;
    let maximumRenderedTextCopies = 0;
    let maximumFlightCopyOverflowX = 0;
    let maximumFlightCopyOverflowY = 0;
    let animationIdentityPreserved = true;
    let animationTimeMonotonic = true;
    let previousAnimationTime = Number(animation.currentTime ?? 0);
    let lastFlyingFrame: ReturnType<typeof plainRect> | null = null;
    for (let attempt = 0; attempt < 160; attempt += 1) {
      const currentBubbles = root.querySelectorAll<HTMLElement>(
        ".comma-chat-user-bubble"
      );
      maximumBubbleCount = Math.max(maximumBubbleCount, currentBubbles.length);
      maximumRenderedTextCopies = Math.max(
        maximumRenderedTextCopies,
        [...currentBubbles].filter(
          (candidate) => candidate.textContent === bubbleNode.textContent
        ).length
      );
      const currentBubble = destinationNode.querySelector<HTMLElement>(
        ".comma-chat-user-bubble"
      );
      if (!currentBubble) {
        throw new Error("The outgoing message replaced its real bubble node.");
      }
      if (currentBubble.dataset.outgoingPresentation !== "flying") {
        if (frames.length > 0) break;
        await nextFrame();
        continue;
      }
      const currentAnimation = currentBubble.getAnimations()[0];
      initialAnimationStartTime ??= animationNode.startTime;
      animationIdentityPreserved &&=
        currentBubble === bubbleNode &&
        currentAnimation === animationNode &&
        animationNode.startTime === initialAnimationStartTime;
      const currentAnimationTime = Number(animationNode.currentTime ?? 0);
      animationTimeMonotonic &&= currentAnimationTime + 0.1 >= previousAnimationTime;
      previousAnimationTime = currentAnimationTime;
      const bubbleFrame = currentBubble.getBoundingClientRect();
      lastFlyingFrame = plainRect(bubbleFrame);
      filters.add(getComputedStyle(currentBubble).filter);
      maximumFlightCopyOverflowX = Math.max(
        maximumFlightCopyOverflowX,
        currentBubble.scrollWidth - currentBubble.clientWidth
      );
      maximumFlightCopyOverflowY = Math.max(
        maximumFlightCopyOverflowY,
        currentBubble.scrollHeight - currentBubble.clientHeight
      );
      frames.push({
        bubbleBottom: bubbleFrame.bottom,
        bubbleHeight: bubbleFrame.height,
        bubbleScale: new DOMMatrixReadOnly(getComputedStyle(currentBubble).transform).a,
        bubbleRight: bubbleFrame.right,
        elapsedMs: performance.now() - captureStartedAt,
      });
      await nextFrame();
    }

    const finalDestination = root.querySelector<HTMLElement>(
      '[data-message-id="outgoing-user-canonical"]'
    );
    const composerAfterNode = root.querySelector<HTMLElement>(
      "[data-testid='outgoing-user-composer']"
    );
    if (!finalDestination || !composerAfterNode) {
      throw new Error("Outgoing fixture did not settle to its canonical message.");
    }
    const settledBubble = finalDestination.querySelector<HTMLElement>(
      ".comma-chat-user-bubble"
    );
    if (!settledBubble) {
      throw new Error("Outgoing fixture lost its settled user bubble.");
    }
    const settledBubbleFrame = settledBubble.getBoundingClientRect();
    const fixtureFrame = root.getBoundingClientRect();
    const settledTextRange = document.createRange();
    settledTextRange.selectNodeContents(settledBubble);
    const settledTextFrame = settledTextRange.getBoundingClientRect();
    const composerAfter = plainRect(composerAfterNode.getBoundingClientRect());
    const composerInput = composerAfterNode.querySelector<HTMLInputElement>("input");
    if (!composerInput) {
      throw new Error("Reusable outgoing composer input disappeared.");
    }
    const result = {
      ackPreservedDestination:
        canonicalDestination === destinationNode &&
        destinationNode.dataset.outgoingDestinationIdentity === "preserved",
      animatedProperties: [...animatedProperties].toSorted(),
      animationDurations,
      animationIdentityPreserved,
      materialProperties: [...materialProperties].toSorted(),
      animationTimeMonotonic,
      bubbleOrigin: {
        x: bubbleOriginParts[0] ?? Number.NaN,
        y: bubbleOriginParts[1] ?? Number.NaN,
      },
      bubbleOverflow,
      composerAfter,
      composerBefore,
      composerEmptyAfterSend: composerAfterNode.dataset.empty === "true",
      composerIdentityPreserved:
        composerAfterNode === composerNode &&
        composerAfterNode.dataset.fixtureIdentity === "preserved",
      composerInputEnabledAfterSend: !composerInput.disabled,
      composerReadyAfterSend: composerAfterNode.dataset.ready === "true",
      destinationFrame,
      destinationVisibleAfterFlight:
        Number.parseFloat(getComputedStyle(finalDestination).opacity) === 1,
      elapsedMs: performance.now() - captureStartedAt,
      filters: [...filters].toSorted(),
      finalDestinationFrame: plainRect(
        finalDestination
          .querySelector<HTMLElement>(".comma-chat-user-bubble")!
          .getBoundingClientRect()
      ),
      flightUsedTopLayer,
      frames,
      handoffEdgeDelta: lastFlyingFrame
        ? frameDelta(lastFlyingFrame, settledBubbleFrame)
        : Number.POSITIVE_INFINITY,
      maximumBubbleCount,
      maximumFlightCopyOverflowX,
      maximumFlightCopyOverflowY,
      maximumRenderedTextCopies,
      keyframeZeroFrame: observedPresentation.keyframeZeroFrame,
      keyframeZeroOffset: observedPresentation.keyframeZeroOffset,
      observerAnimationCurrentTime: observedPresentation.observerAnimationCurrentTime,
      observerBubbleIdentityPreserved: bubbleNode === settledBubble,
      popoverMode,
      sourceSurface: sourceSurfaceFrame,
      springSource,
      settledBubbleOverflowLeft: Math.max(
        0,
        fixtureFrame.left - settledBubbleFrame.left
      ),
      settledBubbleOverflowRight: Math.max(
        0,
        settledBubbleFrame.right - fixtureFrame.right
      ),
      settledCopyOverflowX: settledBubble.scrollWidth - settledBubble.clientWidth,
      settledCopyOverflowY: settledBubble.scrollHeight - settledBubble.clientHeight,
      settledTextOverflowBottom: Math.max(
        0,
        settledTextFrame.bottom - settledBubbleFrame.bottom
      ),
      settledTextOverflowLeft: Math.max(
        0,
        settledBubbleFrame.left - settledTextFrame.left
      ),
      settledTextOverflowRight: Math.max(
        0,
        settledTextFrame.right - settledBubbleFrame.right
      ),
      settledTextOverflowTop: Math.max(
        0,
        settledBubbleFrame.top - settledTextFrame.top
      ),
      visibleBubbleIdentityPreserved: settledBubble === bubbleNode,
    };
    document.documentElement.removeAttribute("data-comma-reduced-motion");
    return result;

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- this helper must be serialized with page.evaluate.
    function plainRect(rect: DOMRect) {
      return {
        bottom: rect.bottom,
        height: rect.height,
        left: rect.left,
        right: rect.right,
        top: rect.top,
        width: rect.width,
      };
    }

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
    function targetRectFromFlightStyles(element: HTMLElement) {
      const left = Number.parseFloat(element.style.left);
      const top = Number.parseFloat(element.style.top);
      const width = Number.parseFloat(element.style.width);
      const height = Number.parseFloat(element.style.height);
      return {
        bottom: top + height,
        height,
        left,
        right: left + width,
        top,
        width,
      };
    }

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
    function rectAtTransform(
      target: ReturnType<typeof plainRect>,
      transform: string,
      originX: number,
      originY: number
    ) {
      const matrix =
        transform === "none"
          ? new DOMMatrixReadOnly()
          : new DOMMatrixReadOnly(transform);
      const corners = [
        [0, 0],
        [target.width, 0],
        [target.width, target.height],
        [0, target.height],
      ].map(([x = 0, y = 0]) => {
        const transformed = new DOMPoint(x - originX, y - originY).matrixTransform(
          matrix
        );
        return {
          x: target.left + originX + transformed.x,
          y: target.top + originY + transformed.y,
        };
      });
      const left = Math.min(...corners.map((corner) => corner.x));
      const right = Math.max(...corners.map((corner) => corner.x));
      const top = Math.min(...corners.map((corner) => corner.y));
      const bottom = Math.max(...corners.map((corner) => corner.y));
      return {
        bottom,
        height: bottom - top,
        left,
        right,
        top,
        width: right - left,
      };
    }

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
    function frameDelta(
      first: ReturnType<typeof plainRect>,
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
  }, mode);
}

async function captureRapidNormalThenCollapsedOutgoing(page: Page) {
  await page.waitForFunction(() => Boolean(window.markdownStreamFixture));
  return page.evaluate(
    async ({ firstText, secondText }) => {
      const controller = window.markdownStreamFixture;
      const root = document.querySelector<HTMLElement>(
        "[data-testid='outgoing-user-motion-fixture']"
      );
      const viewport = root?.querySelector<HTMLElement>(
        "[data-slot='scroll-area-viewport']"
      );
      if (!controller || !root || !viewport) {
        throw new Error("Rapid outgoing fixture was not ready.");
      }
      const rapidFixtureRoot = root;

      Object.assign(root.style, {
        background: "var(--color-bg-primary)",
        height: "720px",
        left: "32px",
        margin: "0",
        position: "fixed",
        top: "32px",
        width: "960px",
        zIndex: "100",
      });
      controller.resetOutgoingUser();
      controller.setOutgoingUserText(firstText);
      await nextFrame(2);
      controller.startOutgoingUser();

      let firstArticle: HTMLElement | null = null;
      let firstBubble: HTMLElement | null = null;
      let firstAnimation: Animation | null = null;
      for (let attempt = 0; attempt < 60; attempt += 1) {
        await nextFrame();
        firstArticle = root.querySelector<HTMLElement>(
          '[data-message-id="outgoing-user-pending"]'
        );
        firstBubble =
          firstArticle?.querySelector<HTMLElement>(
            '.comma-chat-user-bubble[data-outgoing-presentation="flying"]'
          ) ?? null;
        firstAnimation = firstBubble?.getAnimations()[0] ?? null;
        if (firstArticle && firstBubble && firstAnimation) break;
      }
      if (!firstArticle || !firstBubble || !firstAnimation) {
        throw new Error("The first normal outgoing spring did not start.");
      }

      const firstArticleNode = firstArticle;
      const firstBubbleNode = firstBubble;
      const firstAnimationNode = firstAnimation;
      let firstAnimationStartTime = firstAnimation.startTime;
      firstBubble.dataset.rapidNormalIdentity = "preserved";

      controller.setOutgoingUserText(secondText);
      await nextFrame();
      controller.startOutgoingUser();

      let maximumFlyingBubbleCount = 0;
      let maximumBubbleMultiplicity = 0;
      let maximumRenderedBubbleTextCharacters = 0;
      let secondBubbleMaximumHeight = 0;
      let secondBubbleMaximumKeyframeCount = 0;
      let secondArticle: HTMLElement | null = null;
      let secondBubble: HTMLElement | null = null;
      let secondDisclosure: HTMLButtonElement | null = null;
      let secondAnimation: Animation | null = null;
      let firstAnimationIdentityPreserved = true;
      for (let attempt = 0; attempt < 120; attempt += 1) {
        await nextFrame();
        sampleBubbles();
        secondArticle = root.querySelector<HTMLElement>(
          '[data-message-id="outgoing-user-2-pending"]'
        );
        secondBubble =
          secondArticle?.querySelector<HTMLElement>(".comma-chat-user-bubble") ?? null;
        secondDisclosure =
          secondArticle?.querySelector<HTMLButtonElement>(
            "button[aria-expanded][aria-controls]"
          ) ?? null;
        secondAnimation = secondBubble?.getAnimations()[0] ?? null;
        if (secondArticle && secondBubble && secondDisclosure && secondAnimation) break;
      }
      if (!secondArticle || !secondBubble || !secondDisclosure || !secondAnimation) {
        throw new Error("The rapid tall outgoing destination did not collapse.");
      }
      const secondBubbleNode = secondBubble;
      const secondAnimationNode = secondAnimation;
      secondArticle.dataset.rapidTallIdentity = "preserved";

      for (let attempt = 0; attempt < 120; attempt += 1) {
        if (!root.querySelector('[data-outgoing-presentation="flying"]')) break;
        await nextFrame();
        sampleBubbles();
      }
      if (root.querySelector('[data-outgoing-presentation="flying"]')) {
        throw new Error("The rapid outgoing springs did not complete.");
      }

      const firstDestination = root.querySelector<HTMLElement>(
        '[data-message-id="outgoing-user-pending"]'
      );
      const controlsId = secondDisclosure.getAttribute("aria-controls");
      const secondContent = controlsId ? document.getElementById(controlsId) : null;
      const feedback = root.querySelector<HTMLElement>(
        "[data-testid='outgoing-agent-feedback']"
      );
      if (!firstDestination || !secondContent || !feedback) {
        throw new Error("Rapid outgoing destinations or feedback were not preserved.");
      }
      const feedbackGeometrySamples: Array<{
        feedbackBottom: number;
        feedbackTop: number;
        scrollHeight: number;
        scrollTop: number;
        viewportBottom: number;
        viewportTop: number;
        visible: boolean;
      }> = [];
      let consecutiveVisibleFeedbackFrames = 0;
      for (let attempt = 0; attempt < 4; attempt += 1) {
        const feedbackFrame = feedback.getBoundingClientRect();
        const viewportFrame = viewport.getBoundingClientRect();
        const visible =
          feedbackFrame.top >= viewportFrame.top - 1 &&
          feedbackFrame.bottom <= viewportFrame.bottom + 1;
        feedbackGeometrySamples.push({
          feedbackBottom: feedbackFrame.bottom,
          feedbackTop: feedbackFrame.top,
          scrollHeight: viewport.scrollHeight,
          scrollTop: viewport.scrollTop,
          viewportBottom: viewportFrame.bottom,
          viewportTop: viewportFrame.top,
          visible,
        });
        consecutiveVisibleFeedbackFrames = visible
          ? consecutiveVisibleFeedbackFrames + 1
          : 0;
        if (consecutiveVisibleFeedbackFrames >= 2) break;
        await nextFrame();
      }

      return {
        agentFeedbackVisible: consecutiveVisibleFeedbackFrames >= 2,
        feedbackGeometrySamples,
        feedbackReadinessFrames: feedbackGeometrySamples.length - 1,
        firstAnimationIdentityPreserved,
        firstDestinationVisibleAfterFlight:
          Number.parseFloat(getComputedStyle(firstDestination).opacity) === 1,
        firstBubbleIdentityPreserved:
          firstDestination === firstArticleNode &&
          firstDestination.querySelector(".comma-chat-user-bubble") ===
            firstBubbleNode &&
          firstBubbleNode.dataset.rapidNormalIdentity === "preserved",
        maximumBubbleMultiplicity,
        maximumFlyingBubbleCount,
        maximumRenderedBubbleTextCharacters,
        secondArticleCount: root.querySelectorAll(
          '[data-message-id="outgoing-user-2-pending"]'
        ).length,
        secondBubbleCount: secondArticle.querySelectorAll(".comma-chat-user-bubble")
          .length,
        secondCollapsed: secondDisclosure.getAttribute("aria-expanded") === "false",
        secondCollapsedHeight: secondBubble.getBoundingClientRect().height,
        secondDestinationIdentityPreserved:
          root.querySelector('[data-message-id="outgoing-user-2-pending"]') ===
            secondArticle &&
          secondArticle.dataset.rapidTallIdentity === "preserved" &&
          secondArticle.querySelector(".comma-chat-user-bubble") === secondBubbleNode,
        secondBubbleMaximumHeight,
        secondBubbleMaximumKeyframeCount,
        secondBubbleStarted:
          secondBubbleNode !== firstBubbleNode &&
          secondAnimationNode !== firstAnimationNode,
        secondTextLength: Array.from(secondContent.textContent ?? "").length,
      };

      function sampleBubbles() {
        const flyingBubbles = [
          ...rapidFixtureRoot.querySelectorAll<HTMLElement>(
            '.comma-chat-user-bubble[data-outgoing-presentation="flying"]'
          ),
        ];
        maximumFlyingBubbleCount = Math.max(
          maximumFlyingBubbleCount,
          flyingBubbles.length
        );
        const bubblesByArticle = new Map<Element, number>();
        for (const currentBubble of flyingBubbles) {
          const currentArticle = currentBubble.closest(".comma-chat-message-user");
          if (currentArticle) {
            bubblesByArticle.set(
              currentArticle,
              (bubblesByArticle.get(currentArticle) ?? 0) + 1
            );
          }
          if (currentBubble === firstBubbleNode) {
            firstAnimationStartTime ??= firstAnimationNode.startTime;
            firstAnimationIdentityPreserved &&=
              currentBubble.getAnimations()[0] === firstAnimationNode &&
              firstAnimationNode.startTime === firstAnimationStartTime;
          }
          if (currentBubble === secondBubble) {
            secondBubbleMaximumHeight = Math.max(
              secondBubbleMaximumHeight,
              currentBubble.getBoundingClientRect().height
            );
            for (const currentAnimation of currentBubble.getAnimations()) {
              const effect = currentAnimation.effect;
              if (!(effect instanceof KeyframeEffect)) continue;
              secondBubbleMaximumKeyframeCount = Math.max(
                secondBubbleMaximumKeyframeCount,
                effect.getKeyframes().length
              );
            }
          }
        }
        maximumBubbleMultiplicity = Math.max(
          maximumBubbleMultiplicity,
          0,
          ...bubblesByArticle.values()
        );
        maximumRenderedBubbleTextCharacters = Math.max(
          maximumRenderedBubbleTextCharacters,
          [
            ...rapidFixtureRoot.querySelectorAll<HTMLElement>(
              ".comma-chat-user-bubble-content"
            ),
          ].reduce(
            (total, content) => total + Array.from(content.textContent ?? "").length,
            0
          )
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
    {
      firstText: rapidNormalOutgoingUserText,
      secondText: tallOutgoingUserText,
    }
  );
}

async function captureDelayedOutgoingActivityHandoff(
  page: Page,
  variant: "route" | "side-chat"
) {
  await page.waitForFunction((requestedVariant) => {
    const fixture = window.delayedOutgoingActivityFixture;
    return Boolean(
      requestedVariant === "side-chat" ? fixture?.sideChat : fixture?.route
    );
  }, variant);

  return page.evaluate(async (requestedVariant) => {
    type Frame = {
      activity: ReturnType<typeof frame> | null;
      animationCount: number;
      animationCurrentTime: number | null;
      animationDuration: number | null;
      bubble: ReturnType<typeof frame> | null;
      bubbleCount: number;
      bubbleFixedTarget: ReturnType<typeof frameFromValues> | null;
      bubblePresentation: string | null;
      bubbleTransform: string | null;
      elapsedMs: number;
      phase: string;
      participantId: string | null;
      sameBubble: boolean;
      sameSlot: boolean;
      sameTurnAnchor: boolean;
      scrollHeight: number;
      scrollTop: number;
      slot: ReturnType<typeof frame> | null;
      statusAfterMessage: boolean;
      turnAnchor: ReturnType<typeof frame> | null;
      turnKey: string | null;
      viewportClientHeight: number;
    };

    const fixtureController =
      requestedVariant === "side-chat"
        ? window.delayedOutgoingActivityFixture?.sideChat
        : window.delayedOutgoingActivityFixture?.route;
    const root = document.querySelector<HTMLElement>(
      `[data-testid='delayed-activity-outgoing-${requestedVariant}-fixture']`
    );
    if (!fixtureController || !root) {
      throw new Error(`Delayed ${requestedVariant} Activity fixture was not ready.`);
    }
    const delayedRoot = root;
    Object.assign(delayedRoot.style, {
      background: "var(--color-bg-primary)",
      height: "720px",
      left: "32px",
      margin: "0",
      position: "fixed",
      top: "32px",
      width: "960px",
      zIndex: "100",
    });

    fixtureController.reset();
    await nextFrame(3);
    const viewport = delayedRoot.querySelector<HTMLElement>(
      "[data-slot='scroll-area-viewport']"
    );
    if (!viewport) {
      throw new Error(`Delayed ${requestedVariant} ScrollArea was not ready.`);
    }
    const scrollViewport = viewport;
    scrollViewport.scrollTop = Math.max(
      0,
      scrollViewport.scrollHeight - scrollViewport.clientHeight
    );
    await nextFrame(2);
    scrollViewport.scrollTop = Math.max(
      0,
      scrollViewport.scrollHeight - scrollViewport.clientHeight
    );
    await nextFrame();
    const preSendScrollTop = scrollViewport.scrollTop;
    const preSendScrollHeight = scrollViewport.scrollHeight;
    const preSendViewportHeight = scrollViewport.clientHeight;

    const samples: Frame[] = [];
    let sendStarted = false;
    let sendStartedAt = performance.now();
    let firstBubble: HTMLElement | null = null;
    let firstSlot: HTMLElement | null = null;
    let firstTurnAnchor: HTMLElement | null = null;
    let bubbleIdentityPreserved = true;
    let slotIdentityPreserved = true;
    let turnAnchorIdentityPreserved = true;
    let maximumBubbleCount = 0;
    let animationStarted = false;
    let animationEndedAtMs: number | null = null;
    let activityAppearedAtMs: number | null = null;
    let lastFlyingRect: ReturnType<typeof frame> | null = null;
    let lastFlyingAnimationCurrentTime: number | null = null;
    let lastFlyingAnimationDuration: number | null = null;
    let lastFlyingTransform: string | null = null;
    let fixedTargetRect: ReturnType<typeof frameFromValues> | null = null;
    let firstSettledRect: ReturnType<typeof frame> | null = null;

    sample("pre-send");
    fixtureController.start();
    sendStartedAt = performance.now();
    sendStarted = true;

    // Chromium can schedule requestAnimationFrame near 120Hz, so a fixed frame
    // count does not guarantee the 520ms post-Activity observation window.
    const samplingDeadline = performance.now() + 3_000;
    while (performance.now() < samplingDeadline) {
      await nextFrame();
      sample();
      const elapsedAfterActivity =
        activityAppearedAtMs === null
          ? 0
          : (samples.at(-1)?.elapsedMs ?? 0) - activityAppearedAtMs;
      if (activityAppearedAtMs !== null && elapsedAfterActivity >= 520) break;
    }

    const lastSample = samples.at(-1);
    if (!lastSample) {
      throw new Error(`Delayed ${requestedVariant} Activity emitted no samples.`);
    }
    const finalRect = lastSample.bubble;
    if (!finalRect) {
      throw new Error(`Delayed ${requestedVariant} user bubble disappeared.`);
    }
    const bubbleSamples = samples.filter(
      (sampledFrame): sampledFrame is Frame & { bubble: ReturnType<typeof frame> } =>
        sampledFrame.bubble !== null && sampledFrame.elapsedMs >= 0
    );
    const postAnimationSamples =
      animationEndedAtMs === null
        ? []
        : bubbleSamples.filter(
            (sampledFrame) => sampledFrame.elapsedMs >= animationEndedAtMs! - 1
          );
    const postAnimationTops = postAnimationSamples.map(
      (sampledFrame) => sampledFrame.bubble.top
    );
    const postAnimationBottoms = postAnimationSamples.map(
      (sampledFrame) => sampledFrame.bubble.bottom
    );
    let longestStationaryAwayMs = 0;
    let stationaryAnchor: (typeof bubbleSamples)[number] | null = null;
    for (const sampledFrame of bubbleSamples) {
      const distanceFromFinal = rectDelta(sampledFrame.bubble, finalRect);
      if (distanceFromFinal <= 1) {
        stationaryAnchor = null;
        continue;
      }
      if (
        !stationaryAnchor ||
        rectDelta(stationaryAnchor.bubble, sampledFrame.bubble) > 0.5
      ) {
        stationaryAnchor = sampledFrame;
        continue;
      }
      longestStationaryAwayMs = Math.max(
        longestStationaryAwayMs,
        sampledFrame.elapsedMs - stationaryAnchor.elapsedMs
      );
    }

    const phaseSummary = Object.fromEntries(
      [...new Set(samples.map((sampledFrame) => sampledFrame.phase))].map(
        (phaseName) => {
          const phaseSamples = samples.filter(
            (sampledFrame) => sampledFrame.phase === phaseName
          );
          const phaseBubbleSamples = phaseSamples.filter(
            (
              sampledFrame
            ): sampledFrame is Frame & { bubble: ReturnType<typeof frame> } =>
              sampledFrame.bubble !== null
          );
          return [
            phaseName,
            {
              bubbleBottomRange:
                phaseBubbleSamples.length === 0
                  ? 0
                  : range(
                      phaseBubbleSamples.map(
                        (sampledFrame) => sampledFrame.bubble.bottom
                      )
                    ),
              bubbleTopRange:
                phaseBubbleSamples.length === 0
                  ? 0
                  : range(
                      phaseBubbleSamples.map((sampledFrame) => sampledFrame.bubble.top)
                    ),
              firstElapsedMs: phaseSamples[0]?.elapsedMs ?? null,
              firstBubble: phaseBubbleSamples[0]?.bubble ?? null,
              firstFixedTarget:
                phaseSamples.find((sampledFrame) => sampledFrame.bubbleFixedTarget)
                  ?.bubbleFixedTarget ?? null,
              firstScrollHeight: phaseSamples[0]?.scrollHeight ?? null,
              firstScrollTop: phaseSamples[0]?.scrollTop ?? null,
              firstSlot: phaseSamples.find((sampledFrame) => sampledFrame.slot)?.slot,
              firstTurnAnchor: phaseSamples.find(
                (sampledFrame) => sampledFrame.turnAnchor
              )?.turnAnchor,
              lastBubble: phaseBubbleSamples.at(-1)?.bubble ?? null,
              lastFixedTarget:
                phaseSamples.findLast((sampledFrame) => sampledFrame.bubbleFixedTarget)
                  ?.bubbleFixedTarget ?? null,
              lastElapsedMs: phaseSamples.at(-1)?.elapsedMs ?? null,
              lastScrollHeight: phaseSamples.at(-1)?.scrollHeight ?? null,
              lastScrollTop: phaseSamples.at(-1)?.scrollTop ?? null,
              lastSlot: phaseSamples.findLast((sampledFrame) => sampledFrame.slot)
                ?.slot,
              lastTurnAnchor: phaseSamples.findLast(
                (sampledFrame) => sampledFrame.turnAnchor
              )?.turnAnchor,
              participantIds: [
                ...new Set(
                  phaseSamples.map((sampledFrame) => sampledFrame.participantId)
                ),
              ],
              samples: phaseSamples.length,
              scrollHeightRange: range(
                phaseSamples.map((sampledFrame) => sampledFrame.scrollHeight)
              ),
              scrollTopRange: range(
                phaseSamples.map((sampledFrame) => sampledFrame.scrollTop)
              ),
              slotTopRange: range(
                phaseSamples.flatMap((sampledFrame) =>
                  sampledFrame.slot ? [sampledFrame.slot.top] : []
                )
              ),
              turnAnchorTopRange: range(
                phaseSamples.flatMap((sampledFrame) =>
                  sampledFrame.turnAnchor ? [sampledFrame.turnAnchor.top] : []
                )
              ),
              viewportBlockSizes: [
                ...new Set(
                  phaseSamples.map((sampledFrame) => sampledFrame.viewportClientHeight)
                ),
              ],
            },
          ];
        }
      )
    );
    const activityOwnerSamples = samples.filter(
      (sampledFrame) => sampledFrame.activity !== null
    );

    return {
      activityAppeared: activityAppearedAtMs !== null,
      activityAppearedAtMs: rounded(activityAppearedAtMs),
      activityAppearedBefore800Ms: samples.some(
        (sampledFrame) =>
          sampledFrame.activity !== null &&
          sampledFrame.elapsedMs >= 0 &&
          sampledFrame.elapsedMs < 800
      ),
      participantStatusAfterMessages:
        activityOwnerSamples.length > 0 &&
        activityOwnerSamples.every((sampledFrame) => sampledFrame.statusAfterMessage),
      animationEndedAtMs: rounded(animationEndedAtMs),
      animationStarted,
      bubbleIdentityPreserved,
      collapsedBubbleHeight: rounded(finalRect.height) ?? 0,
      fixedTargetRect,
      handoffEdgeDelta:
        fixedTargetRect && firstSettledRect
          ? (rounded(rectDelta(fixedTargetRect, firstSettledRect)) ??
            Number.POSITIVE_INFINITY)
          : Number.POSITIVE_INFINITY,
      initialActivityAbsent: samples[0]?.activity === null,
      longestStationaryAwayMs: rounded(longestStationaryAwayMs) ?? 0,
      lastFlyingAnimationCurrentTime: rounded(lastFlyingAnimationCurrentTime),
      lastFlyingAnimationDuration: rounded(lastFlyingAnimationDuration),
      lastFlyingRemainingMs:
        lastFlyingAnimationCurrentTime === null || lastFlyingAnimationDuration === null
          ? null
          : (rounded(lastFlyingAnimationDuration - lastFlyingAnimationCurrentTime) ??
            null),
      lastFlyingToSettledSampleDelta:
        lastFlyingRect && firstSettledRect
          ? (rounded(rectDelta(lastFlyingRect, firstSettledRect)) ?? null)
          : null,
      lastFlyingTransform,
      maximumBubbleCount,
      observedAfterActivityMs:
        activityAppearedAtMs === null
          ? 0
          : (rounded(lastSample.elapsedMs - activityAppearedAtMs) ?? 0),
      phaseSummary,
      participantIds: [
        ...new Set(
          activityOwnerSamples.map((sampledFrame) => sampledFrame.participantId)
        ),
      ],
      postAnimationContentTopRange:
        rounded(
          range(
            postAnimationSamples.map(
              (sampledFrame) => sampledFrame.bubble.top + sampledFrame.scrollTop
            )
          )
        ) ?? 0,
      settledTailGap: Math.abs(
        lastSample.scrollHeight - lastSample.viewportClientHeight - lastSample.scrollTop
      ),
      postAnimationBottomRange: rounded(range(postAnimationBottoms)) ?? 0,
      postAnimationTopRange: rounded(range(postAnimationTops)) ?? 0,
      preSendAtBottom:
        Math.abs(preSendScrollHeight - preSendViewportHeight - preSendScrollTop) <= 1,
      preSendOverflowed: preSendScrollHeight > preSendViewportHeight + 1,
      preSendScrollHeight,
      preSendScrollTop: rounded(preSendScrollTop) ?? preSendScrollTop,
      preSendViewportHeight,
      samples,
      slotIdentityPreserved,
      turnAnchorIdentityPreserved,
      variant: requestedVariant,
    };

    function sample(forcedPhase?: string) {
      const elapsedMs = sendStarted ? performance.now() - sendStartedAt : -1;
      const article = delayedRoot.querySelector<HTMLElement>(
        `[data-message-id='delayed-activity-${requestedVariant}-pending']`
      );
      const bubble = article?.querySelector<HTMLElement>(".comma-chat-user-bubble");
      const slot = article?.querySelector<HTMLElement>(".comma-chat-user-bubble-slot");
      const turnAnchor = article?.closest<HTMLElement>(
        "[data-chat-turn-anchor][data-turn-key]"
      );
      const activity = delayedRoot.querySelector<HTMLElement>(
        ".comma-chat-activity-slot[data-active='true']"
      );
      if (bubble && !firstBubble) firstBubble = bubble;
      if (slot && !firstSlot) firstSlot = slot;
      if (turnAnchor && !firstTurnAnchor) firstTurnAnchor = turnAnchor;
      if (bubble && firstBubble && bubble !== firstBubble) {
        bubbleIdentityPreserved = false;
      }
      if (slot && firstSlot && slot !== firstSlot) slotIdentityPreserved = false;
      if (turnAnchor && firstTurnAnchor && turnAnchor !== firstTurnAnchor) {
        turnAnchorIdentityPreserved = false;
      }
      const presentation = bubble?.dataset.outgoingPresentation ?? null;
      const currentAnimation = bubble?.getAnimations()[0];
      const animationDuration = currentAnimation
        ? Number(currentAnimation.effect?.getTiming().duration)
        : null;
      const fixedTarget = bubble ? flightTarget(bubble) : null;
      if (presentation === "flying") {
        animationStarted = true;
        if (bubble) {
          lastFlyingRect = frame(bubble);
          lastFlyingAnimationCurrentTime =
            typeof currentAnimation?.currentTime === "number"
              ? currentAnimation.currentTime
              : null;
          lastFlyingAnimationDuration = animationDuration;
          lastFlyingTransform = getComputedStyle(bubble).transform;
          fixedTargetRect ??= fixedTarget;
        }
      } else if (animationStarted && animationEndedAtMs === null && bubble) {
        animationEndedAtMs = elapsedMs;
        firstSettledRect = frame(bubble);
      }
      if (activity && activityAppearedAtMs === null) {
        activityAppearedAtMs = elapsedMs;
      }
      const bubbleCount =
        article?.querySelectorAll(":scope .comma-chat-user-bubble").length ?? 0;
      maximumBubbleCount = Math.max(maximumBubbleCount, bubbleCount);
      const phase =
        forcedPhase ??
        (!bubble
          ? "waiting-bubble"
          : presentation === "flying"
            ? activity
              ? "flying-with-activity"
              : "flying-before-activity"
            : activity
              ? "settled-with-activity"
              : animationStarted
                ? "settled-before-activity"
                : "destination-before-flight");
      samples.push({
        activity: activity ? frame(activity) : null,
        animationCount: bubble?.getAnimations().length ?? 0,
        animationCurrentTime:
          typeof currentAnimation?.currentTime === "number"
            ? currentAnimation.currentTime
            : null,
        animationDuration,
        bubble: bubble ? frame(bubble) : null,
        bubbleCount,
        bubbleFixedTarget: fixedTarget,
        bubblePresentation: presentation,
        bubbleTransform: bubble ? getComputedStyle(bubble).transform : null,
        elapsedMs: rounded(elapsedMs) ?? elapsedMs,
        phase,
        participantId: delayedRoot.dataset.participantId || null,
        sameBubble: !bubble || !firstBubble || bubble === firstBubble,
        sameSlot: !slot || !firstSlot || slot === firstSlot,
        sameTurnAnchor:
          !turnAnchor || !firstTurnAnchor || turnAnchor === firstTurnAnchor,
        scrollHeight: scrollViewport.scrollHeight,
        scrollTop: rounded(scrollViewport.scrollTop) ?? scrollViewport.scrollTop,
        slot: slot ? frame(slot) : null,
        statusAfterMessage:
          !activity ||
          !article ||
          Boolean(
            article.compareDocumentPosition(activity) & Node.DOCUMENT_POSITION_FOLLOWING
          ),
        turnAnchor: turnAnchor ? frame(turnAnchor) : null,
        turnKey: turnAnchor?.dataset.turnKey ?? null,
        viewportClientHeight: scrollViewport.clientHeight,
      });
    }

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
    function frame(element: Element) {
      const rect = element.getBoundingClientRect();
      return {
        bottom: rounded(rect.bottom) ?? rect.bottom,
        height: rounded(rect.height) ?? rect.height,
        left: rounded(rect.left) ?? rect.left,
        right: rounded(rect.right) ?? rect.right,
        top: rounded(rect.top) ?? rect.top,
        width: rounded(rect.width) ?? rect.width,
      };
    }

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
    function flightTarget(element: HTMLElement) {
      if (element.dataset.outgoingPresentation !== "flying") return null;
      const left = Number.parseFloat(element.style.left);
      const top = Number.parseFloat(element.style.top);
      const width = Number.parseFloat(element.style.width);
      const height = Number.parseFloat(element.style.height);
      return [left, top, width, height].every(Number.isFinite)
        ? frameFromValues(left, top, width, height)
        : null;
    }

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
    function frameFromValues(left: number, top: number, width: number, height: number) {
      return {
        bottom: rounded(top + height) ?? top + height,
        height: rounded(height) ?? height,
        left: rounded(left) ?? left,
        right: rounded(left + width) ?? left + width,
        top: rounded(top) ?? top,
        width: rounded(width) ?? width,
      };
    }

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
    function rectDelta(
      first: ReturnType<typeof frame>,
      second: ReturnType<typeof frame>
    ) {
      return Math.max(
        Math.abs(first.bottom - second.bottom),
        Math.abs(first.left - second.left),
        Math.abs(first.right - second.right),
        Math.abs(first.top - second.top)
      );
    }

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
    function range(values: readonly number[]) {
      return values.length === 0 ? 0 : Math.max(...values) - Math.min(...values);
    }

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
    function rounded(value: number | null) {
      return value === null ? null : Number(value.toFixed(2));
    }

    // oxlint-disable-next-line unicorn/consistent-function-scoping -- serialized into the browser context.
    async function nextFrame(count = 1) {
      for (let index = 0; index < count; index += 1) {
        await new Promise<void>((resolveFrame) =>
          requestAnimationFrame(() => resolveFrame())
        );
      }
    }
  }, variant);
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
      controller.startOutgoingUser();

      let destination: HTMLElement | null = null;
      let bubble: HTMLElement | null = null;
      let disclosure: HTMLButtonElement | null = null;
      let animation: Animation | null = null;
      let maximumFlyingBubbleCount = 0;
      let maximumRenderedTextCopies = 0;
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
      let animationStartTime = animation.startTime;
      let animationIdentityPreserved = true;
      destination.dataset.largeOutgoingIdentity = "preserved";
      bubble.dataset.largeOutgoingBubbleIdentity = "preserved";
      const motionStartedAt = performance.now();
      const trajectory: Array<{
        bottom: number;
        elapsedMs: number;
        top: number;
      }> = [];
      const scrollSamples = [viewport.scrollTop];
      let lastFlyingFrame: ReturnType<typeof plainRect> | null = null;
      for (let index = 0; index < 18; index += 1) {
        await nextFrame();
        sampleVisibleSurface();
        scrollSamples.push(viewport.scrollTop);
      }

      controller.ackOutgoingUser();
      for (let attempt = 0; attempt < 120; attempt += 1) {
        sampleVisibleSurface();
        const currentBubble = destinationNode.querySelector<HTMLElement>(
          ".comma-chat-user-bubble"
        );
        if (currentBubble?.dataset.outgoingPresentation !== "flying") break;
        await nextFrame();
        scrollSamples.push(viewport.scrollTop);
      }
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
        elapsedMs: performance.now() - motionStartedAt,
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
          animationStartTime ??= animationNode.startTime;
          animationIdentityPreserved &&=
            visibleSurface === bubbleNode &&
            visibleSurface.getAnimations()[0] === animationNode &&
            animationNode.startTime === animationStartTime;
        }
        const frame = visibleSurface.getBoundingClientRect();
        trajectory.push({
          bottom: frame.bottom,
          elapsedMs: performance.now() - motionStartedAt,
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
  longTasks: number[];
  maximumAnimationKeyframeCount: number;
  maximumAnimatedSurfaceHeight: number;
  maximumBubbleViewportOverflow: number;
  maximumDuplicateTextCharacters: number;
  maximumRenderedTextCharacters: number;
  maximumContentDistortion: number;
  rafTimestamps: number[];
  singleBubbleOwnsContent: boolean;
};

type OutgoingPerformanceProbeState = Omit<
  OutgoingPerformanceProbe,
  "maximumAnimationKeyframeCount"
> & {
  observer?: PerformanceObserver | undefined;
  rafId: number;
};

type OutgoingPerformanceProbeWindow = Window & {
  commaOutgoingPerformanceProbe?: OutgoingPerformanceProbeState | undefined;
};

async function beginOutgoingPerformanceProbe(page: Page) {
  await page.evaluate(() => {
    const probeWindow = window as OutgoingPerformanceProbeWindow;
    const previous = probeWindow.commaOutgoingPerformanceProbe;
    if (previous) {
      cancelAnimationFrame(previous.rafId);
      previous.observer?.disconnect();
    }

    const state: OutgoingPerformanceProbeState = {
      animationKeyframeCounts: [],
      bubbleFrames: [],
      bubbleOverflowX: "",
      bubbleOverflowY: "",
      bubblePaintSamples: 0,
      longTasks: [],
      maximumAnimatedSurfaceHeight: 0,
      maximumBubbleViewportOverflow: 0,
      maximumDuplicateTextCharacters: 0,
      maximumRenderedTextCharacters: 0,
      maximumContentDistortion: 0,
      rafId: 0,
      rafTimestamps: [],
      singleBubbleOwnsContent: true,
    };
    if (PerformanceObserver.supportedEntryTypes.includes("longtask")) {
      state.observer = new PerformanceObserver((list) => {
        state.longTasks.push(
          ...list.getEntries().map((entry) => Number(entry.duration.toFixed(2)))
        );
      });
      state.observer.observe({ type: "longtask" });
    }

    const sample = (timestamp: number) => {
      state.rafTimestamps.push(timestamp);
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
    if (state.observer) {
      state.longTasks.push(
        ...state.observer
          .takeRecords()
          .map((entry) => Number(entry.duration.toFixed(2)))
      );
      state.observer.disconnect();
    }
    delete probeWindow.commaOutgoingPerformanceProbe;
    return {
      animationKeyframeCounts: state.animationKeyframeCounts,
      bubbleFrames: state.bubbleFrames,
      bubbleOverflowX: state.bubbleOverflowX,
      bubbleOverflowY: state.bubbleOverflowY,
      bubblePaintSamples: state.bubblePaintSamples,
      longTasks: state.longTasks,
      maximumAnimationKeyframeCount: Math.max(0, ...state.animationKeyframeCounts),
      maximumAnimatedSurfaceHeight: state.maximumAnimatedSurfaceHeight,
      maximumBubbleViewportOverflow: state.maximumBubbleViewportOverflow,
      maximumDuplicateTextCharacters: state.maximumDuplicateTextCharacters,
      maximumRenderedTextCharacters: state.maximumRenderedTextCharacters,
      maximumContentDistortion: state.maximumContentDistortion,
      rafTimestamps: state.rafTimestamps,
      singleBubbleOwnsContent: state.singleBubbleOwnsContent,
    };
  });
}

const longOutgoingUserText = [
  "实现位置与序列帧验证：混合CJK内容必须在飞行、回摆和落位后始终留在同一个气泡内。",
  "/Users/zanwei.guo/.codex/worktrees/8bec/comma/clients/packages/app/src/components/chat/ConversationThread.tsx:1156/ThisSegmentHasNoNaturalBreakOpportunityAndMustStillRemainInsideTheBubbleContainer",
  "https://example.com/conversations/user-bubble-animation?continuity=ThisQueryValueHasNoNaturalBreakOpportunityAndMustNeverEscapeTheRenderedBubbleContainer",
].join("\n");

const rapidNormalOutgoingUserText = "First normal message keeps its spring owner.";

const hugeOutgoingUserText = Array.from({ length: 48 }, (_, index) =>
  [
    `第 ${index + 1} 段：大段混合 CJK 内容在发送、飞行、回摆和落位时都不能与输入框互相裁剪，也不能造成明显掉帧。`,
    `/Users/example/Library/Application Support/Comma/conversations/${index}/${"UnbrokenPathSegment".repeat(10)}`,
    `https://example.com/chat/${index}?payload=${"0123456789ABCDEF".repeat(8)}`,
  ].join(" ")
).join("\n");

const tallOutgoingUserText = Array.from({ length: 400 }, () => "行").join("\n");

function expectReducedOutgoingMotion(motion: OutgoingMotionCapture) {
  expect(motion.ackPreservedDestination).toBe(true);
  expect(motion.destinationVisibleAfterFlight).toBe(true);
  expect(motion.visibleBubbleIdentityPreserved).toBe(true);
  expect(motion.animationIdentityPreserved).toBe(true);
  expect(motion.animationTimeMonotonic).toBe(true);
  expect(motion.maximumBubbleCount).toBe(1);
  expect(motion.maximumRenderedTextCopies).toBe(1);
  expect(motion.flightUsedTopLayer).toBe(false);
  expect(motion.popoverMode).toBeNull();
  expect(motion.animationDurations).toHaveLength(1);
  expect(Math.max(...motion.animationDurations)).toBeLessThanOrEqual(150);
  expect(motion.elapsedMs).toBeLessThan(400);
  expect(motion.animatedProperties).toEqual(["opacity", "transform"]);
  expect(motion.filters).toEqual(["none"]);
  expect(
    Math.max(
      ...motion.frames.map((frame) =>
        Math.abs(frame.bubbleBottom - motion.destinationFrame.bottom)
      )
    )
  ).toBeLessThan(0.5);
  expect(
    Math.max(
      ...motion.frames.map((frame) =>
        Math.abs(frame.bubbleRight - motion.destinationFrame.right)
      )
    )
  ).toBeLessThan(0.5);
  expect(motion.handoffEdgeDelta).toBeLessThanOrEqual(1);
  expect(motion.composerIdentityPreserved).toBe(true);
  expect(motion.composerInputEnabledAfterSend).toBe(true);
  expect(motion.composerReadyAfterSend).toBe(true);
}

async function verticalOffset(
  viewport: ReturnType<Page["locator"]>,
  item: ReturnType<Page["locator"]>
) {
  const [viewportBox, itemBox] = await Promise.all([
    viewport.boundingBox(),
    item.boundingBox(),
  ]);
  if (!viewportBox || !itemBox) {
    throw new Error("Conversation turn geometry is unavailable.");
  }
  return itemBox.y - viewportBox.y;
}

async function setMarkdownScenarioAndObserveAnimation(
  page: Page,
  scenario: "intro" | "full" | "final" | "retarget-a" | "retarget-b"
) {
  await page.waitForFunction(() => Boolean(window.markdownStreamFixture));
  const animationObserved = await page.evaluate(
    (nextScenario) =>
      new Promise<boolean>((accept, reject) => {
        const fixture = document.querySelector(
          "[data-testid='markdown-stream-fixture']"
        );
        if (!fixture) {
          reject(new Error("Markdown stream fixture was not mounted."));
          return;
        }

        const existingAnimatedElements = new Set(
          fixture.querySelectorAll(".markdown-stream-char-enter")
        );
        let timeout = 0;
        const observer = new MutationObserver(() => {
          const animationStarted = [
            ...fixture.querySelectorAll(".markdown-stream-char-enter"),
          ].some((element) => !existingAnimatedElements.has(element));
          if (!animationStarted) return;
          window.clearTimeout(timeout);
          observer.disconnect();
          accept(true);
        });

        observer.observe(fixture, {
          attributeFilter: ["class"],
          attributes: true,
          childList: true,
          subtree: true,
        });
        timeout = window.setTimeout(() => {
          observer.disconnect();
          reject(new Error("Markdown blur animation was not observed."));
        }, 2_000);
        window.markdownStreamFixture?.setScenario(nextScenario);
      }),
    scenario
  );
  expect(animationObserved).toBe(true);
}

async function setMarkdownContent(page: Page, content: string, final: boolean) {
  await page.waitForFunction(() => Boolean(window.markdownStreamFixture));
  await page.evaluate(
    ({ nextContent, nextFinal }) => {
      window.markdownStreamFixture?.setContent(nextContent, nextFinal);
    },
    { nextContent: content, nextFinal: final }
  );
}

async function setMarkdownTheme(page: Page, theme: "Dark mode" | "Light mode") {
  await page.waitForFunction(() => Boolean(window.markdownStreamFixture));
  await page.evaluate((nextTheme) => {
    window.markdownStreamFixture?.setTheme(nextTheme);
  }, theme);
}

async function readProductPalette(product: ReturnType<Page["getByTestId"]>): Promise<{
  codeSurface: string;
  diagramSurface: string;
  keyword: string;
  mermaidEdge: string;
  mermaidMarker: string;
}> {
  return product.evaluate((root) => {
    const codeFigure = root.querySelector<HTMLElement>(
      ".markdown-stream-code-block:not(.markdown-stream-mermaid)"
    );
    const keyword = [...root.querySelectorAll<HTMLElement>(".shiki .line > span")].find(
      (span) => span.textContent?.trim() === "type"
    );
    const diagramSurface = root.querySelector<HTMLElement>(".markdown-stream-mermaid");
    const mermaidEdge = root.querySelector<SVGElement>(
      ".markdown-stream-mermaid-svg .flowchart-link"
    );
    const mermaidMarker = root.querySelector<SVGElement>(
      ".markdown-stream-mermaid-svg marker path"
    );

    if (!codeFigure || !keyword || !diagramSurface || !mermaidEdge || !mermaidMarker) {
      throw new Error("Product Markdown palette was not ready.");
    }

    return {
      codeSurface: getComputedStyle(codeFigure).backgroundColor,
      diagramSurface: getComputedStyle(diagramSurface).backgroundColor,
      keyword: getComputedStyle(keyword).color,
      mermaidEdge: getComputedStyle(mermaidEdge).stroke,
      mermaidMarker: getComputedStyle(mermaidMarker).fill,
    };
  });
}

async function readCodeSelection(
  fixture: ReturnType<Page["getByTestId"]>
): Promise<{ background: string; surface: string }> {
  return fixture.evaluate((root) => {
    const codeFigure = root.querySelector<HTMLElement>(
      ".markdown-stream-code-block:not(.markdown-stream-mermaid)"
    );
    const token = codeFigure?.querySelector<HTMLElement>(".shiki .line > span");
    if (!codeFigure || !token) {
      throw new Error("Highlighted code was not ready.");
    }
    return {
      background: getComputedStyle(token, "::selection").backgroundColor,
      surface: getComputedStyle(codeFigure).backgroundColor,
    };
  });
}

async function expectMermaidControlPalette(product: ReturnType<Page["getByTestId"]>) {
  await expect
    .poll(async () => {
      const controls = await readMermaidControlPalette(product);
      return {
        activeBackgroundDiffers:
          controls.activeBackground !== controls.inactiveBackground,
        activeColorDiffers: controls.activeColor !== controls.inactiveColor,
        inactiveBackground: controls.inactiveBackground,
        inactiveColorSettled: controls.inactiveColor === controls.secondary,
      };
    })
    .toEqual({
      activeBackgroundDiffers: true,
      activeColorDiffers: true,
      inactiveBackground: "rgba(0, 0, 0, 0)",
      inactiveColorSettled: true,
    });
}

async function readMermaidControlPalette(product: ReturnType<Page["getByTestId"]>) {
  return product.evaluate((root) => {
    const preview = [...root.querySelectorAll<HTMLButtonElement>("button")].find(
      (button) => button.textContent?.trim() === "Preview"
    );
    const source = [...root.querySelectorAll<HTMLButtonElement>("button")].find(
      (button) => button.textContent?.trim() === "Source"
    );
    if (!preview || !source) {
      throw new Error("Mermaid controls were not ready.");
    }

    const secondaryProbe = document.createElement("span");
    secondaryProbe.style.color = "var(--color-text-secondary)";
    root.append(secondaryProbe);
    const secondary = getComputedStyle(secondaryProbe).color;
    secondaryProbe.remove();

    return {
      activeBackground: getComputedStyle(preview).backgroundColor,
      activeColor: getComputedStyle(preview).color,
      inactiveBackground: getComputedStyle(source).backgroundColor,
      inactiveColor: getComputedStyle(source).color,
      secondary,
    };
  });
}

async function siblingGap(paragraphs: ReturnType<Page["locator"]>): Promise<number> {
  return paragraphs.evaluateAll((elements) => {
    if (elements.length !== 2) throw new Error("Expected two sibling paragraphs.");
    return (
      elements[1]!.getBoundingClientRect().top -
      elements[0]!.getBoundingClientRect().bottom
    );
  });
}

async function directChildGaps(
  container: ReturnType<Page["locator"]>
): Promise<number[]> {
  return container.locator(":scope > *").evaluateAll((elements) =>
    elements.slice(1).map((element, index) => {
      const before = elements[index]!.getBoundingClientRect();
      return element.getBoundingClientRect().top - before.bottom;
    })
  );
}

async function thematicBreakGap(fixture: ReturnType<Page["locator"]>) {
  return fixture.evaluate((root) => {
    const thematicBreak = root.querySelector("hr");
    const paragraphs = root.querySelectorAll("p");
    const followingParagraph = paragraphs.item(paragraphs.length - 1);
    if (!thematicBreak || !followingParagraph) {
      throw new Error("Expected a thematic break followed by a paragraph.");
    }

    const beforeBox = thematicBreak.getBoundingClientRect();
    const afterBox = followingParagraph.getBoundingClientRect();
    return afterBox.top - beforeBox.bottom;
  });
}

function contrastRatio(foreground: string, background: string): number {
  const foregroundLuminance = relativeLuminance(parseCssColor(foreground));
  const backgroundLuminance = relativeLuminance(parseCssColor(background));
  const lighter = Math.max(foregroundLuminance, backgroundLuminance);
  const darker = Math.min(foregroundLuminance, backgroundLuminance);
  return (lighter + 0.05) / (darker + 0.05);
}

function relativeLuminance({ b: blue, g: green, r: red }: CssRgbaColor) {
  return (
    0.2126 * linearizedRgbChannel(red) +
    0.7152 * linearizedRgbChannel(green) +
    0.0722 * linearizedRgbChannel(blue)
  );
}

function linearizedRgbChannel(value: number) {
  const normalized = value / 255;
  return normalized <= 0.04045
    ? normalized / 12.92
    : ((normalized + 0.055) / 1.055) ** 2.4;
}

test("attributed replies keep the assistant reading type and the activity line its own gap", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const fixture = page.getByTestId("actor-attribution-fixture");
  await expect(fixture.locator(".comma-chat-assistant-source-label")).toHaveCount(2);

  const reading = await fixture.evaluate((root) => {
    const bodyOf = (messageId: string) => {
      const article = root.querySelector<HTMLElement>(
        `[data-message-id="${messageId}"]`
      );
      const stream = article?.querySelector<HTMLElement>(".markdown-renderer");
      if (!article || !stream) {
        throw new Error(`Missing rendered body for ${messageId}.`);
      }
      const style = getComputedStyle(stream);
      return { fontSize: style.fontSize, lineHeight: style.lineHeight };
    };
    const worker = root.querySelector<HTMLElement>(
      '[data-message-id="actor-attribution-worker"]'
    );
    const slot = root.querySelector<HTMLElement>(
      '[data-testid="participant-status-slot"]'
    );
    if (!worker || !slot) {
      throw new Error("Missing attributed reply or activity slot.");
    }
    return {
      plain: bodyOf("actor-attribution-plain"),
      router: bodyOf("actor-attribution-router"),
      worker: bodyOf("actor-attribution-worker"),
      workerToActivity: Math.round(
        slot.getBoundingClientRect().top - worker.getBoundingClientRect().bottom
      ),
    };
  });

  // One reading ramp across the thread: attribution does not come with its own
  // type, and the Router reply reads at the same size as the Worker's.
  expect(reading.plain).toEqual({ fontSize: "13px", lineHeight: "20px" });
  expect(reading.router).toEqual(reading.plain);
  expect(reading.worker).toEqual(reading.plain);
  // The activity line reports on the content above it rather than being one of
  // the turn's rows, so — like the timestamp — it keeps the wider 16px gap.
  expect(reading.workerToActivity).toBe(16);
});

test("inline code reads on its own token against a hairline chip in both themes", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  await page.waitForFunction(() => Boolean(window.markdownStreamFixture));
  await page.evaluate(() => {
    window.markdownStreamFixture?.setContent("Run `inlineCode()` to start.", true);
  });

  const product = page.getByTestId("markdown-stream-fixture");
  const inlineCode = product.locator(".markdown-stream-inline-code").first();
  await expect(inlineCode).toBeVisible();

  const readInlineCode = () =>
    inlineCode.evaluate((element) => {
      const prose = element.parentElement;
      if (!prose) throw new Error("Inline code is not inside prose.");
      const style = getComputedStyle(element);
      return {
        background: style.backgroundColor,
        borderColor: style.borderTopColor,
        // The rule asks for the 0.5px hairline token; Chromium reports the used
        // width, which it snaps up to a whole device pixel, so compare against
        // the declared token rather than the resolved length.
        borderToken: getComputedStyle(document.documentElement).getPropertyValue(
          "--border-width-0-5"
        ),
        borderStyle: style.borderTopStyle,
        color: style.color,
        paddingBlock: style.paddingTop,
        proseColor: getComputedStyle(prose).color,
      };
    });

  await setMarkdownTheme(page, "Light mode");
  const light = await readInlineCode();
  // The chip is a hairline on the prose baseline rather than a padded block,
  // and its text carries its own token instead of inheriting the prose color.
  expect(light.borderToken.trim()).toBe("0.5px");
  expect(light.borderStyle).toBe("solid");
  expect(light.borderColor).not.toBe(light.background);
  expect(light.paddingBlock).toBe("0px");
  expect(light.color).not.toBe(light.proseColor);
  expect(contrastRatio(light.color, light.background)).toBeGreaterThanOrEqual(4.5);

  await setMarkdownTheme(page, "Dark mode");
  await expect.poll(async () => (await readInlineCode()).color).not.toBe(light.color);
  const dark = await readInlineCode();
  expect(dark.borderStyle).toBe("solid");
  expect(dark.color).not.toBe(dark.proseColor);
  expect(contrastRatio(dark.color, dark.background)).toBeGreaterThanOrEqual(4.5);
});

test("the send failure and the model failure print the same notice card", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.evaluate(() => document.fonts.ready);
  const fixture = page.getByTestId("notice-parity-fixture");
  // The send-failure row arrives on a 200ms translate. A rect read while that
  // transform is still a fraction of a pixel from rest carries the float
  // rounding into the height (43.99994 for 44), so the cards are read once it
  // has landed.
  await fixture
    .locator('[data-testid="chat-failed-row"]')
    .evaluate((row) =>
      Promise.all(row.getAnimations().map((animation) => animation.finished))
    );

  const readNoticeCard = (selector: string) =>
    fixture.locator(selector).evaluate((card) => {
      const style = getComputedStyle(card);
      const icon = card.querySelector<SVGElement>(".comma-chat-notice-card-icon");
      if (!icon) throw new Error("The notice card has no status icon.");
      const iconRect = icon.getBoundingClientRect();
      const cardRect = card.getBoundingClientRect();
      const actions = card.querySelector<HTMLElement>(
        ".comma-chat-notice-card-actions"
      );
      const copy = card.querySelector<HTMLElement>(".comma-chat-notice-card-copy");
      const actionsRect = actions?.getBoundingClientRect();
      const copyRect = copy?.getBoundingClientRect();
      return {
        actions:
          actions && actionsRect && copyRect
            ? {
                bottomInset: cardRect.bottom - actionsRect.bottom,
                copyGap: actionsRect.top - copyRect.bottom,
                labels: Array.from(actions.querySelectorAll("button"), (button) =>
                  button.textContent?.trim()
                ),
              }
            : null,
        frame: {
          alignItems: style.alignItems,
          background: style.backgroundColor,
          borderColor: style.borderTopColor,
          borderRadius: style.borderStartStartRadius,
          borderWidth: style.borderTopWidth,
          boxShadow: style.boxShadow,
          color: style.color,
          fontSize: style.fontSize,
          gap: style.columnGap,
          iconColor: getComputedStyle(icon).color,
          iconSize: `${iconRect.width}x${iconRect.height}`,
          letterSpacing: style.letterSpacing,
          lineHeight: style.lineHeight,
          minHeight: style.minHeight,
          overflow: style.overflow,
          paddingBlock: `${style.paddingBlockStart} ${style.paddingBlockEnd}`,
          paddingInline: `${style.paddingInlineStart} ${style.paddingInlineEnd}`,
          width: cardRect.width,
        },
        height: cardRect.height,
      };
    });

  const sendFailure = await readNoticeCard('[data-testid="chat-failed-row"]');
  const modelFailure = await readNoticeCard(
    '.comma-ai-activity[data-status="failed"] .comma-ai-activity-summary-shell'
  );
  const activitySlot = fixture.getByTestId("participant-status-slot");

  // The frame stays shared even though the send failure now stacks an actions
  // row beneath its copy and the model failure remains a single row.
  expect(modelFailure.frame).toEqual(sendFailure.frame);
  expect(modelFailure.height).toBeCloseTo(44, 1);
  expect(sendFailure.height).toBeCloseTo(68, 1);
  expect(sendFailure.height).toBeGreaterThan(modelFailure.height);
  expect(modelFailure.actions).toBeNull();
  expect(sendFailure.actions).toMatchObject({ labels: ["Discard", "Retry"] });
  expect(sendFailure.actions?.copyGap).toBeCloseTo(2, 1);
  expect(sendFailure.actions?.bottomInset).toBeCloseTo(9, 1);

  // Avatars communicate active participants. Once the row becomes a failure
  // notice, the notice owns the full column and its slot owns the full card.
  await expect(fixture.locator(".comma-chat-activity-avatars")).toHaveCount(0);
  const singleLineGeometry = await activitySlot.evaluate((slot) => {
    const card = slot.querySelector<HTMLElement>(".comma-chat-notice-card");
    if (!card) throw new Error("The activity slot has no notice card.");
    const slotRect = slot.getBoundingClientRect();
    const cardRect = card.getBoundingClientRect();
    return {
      cardBottom: cardRect.bottom,
      cardHeight: cardRect.height,
      cardTop: cardRect.top,
      slotBottom: slotRect.bottom,
      slotHeight: slotRect.height,
      slotTop: slotRect.top,
    };
  });
  expect(singleLineGeometry.slotHeight).toBeCloseTo(44, 1);
  expect(singleLineGeometry.slotTop).toBeLessThanOrEqual(singleLineGeometry.cardTop);
  expect(singleLineGeometry.slotBottom).toBeGreaterThanOrEqual(
    singleLineGeometry.cardBottom
  );

  // A narrow conversation makes the model failure wrap. The error slot grows
  // with it instead of clipping or letting the card overlap the next row.
  await fixture.evaluate((element) => {
    element.style.width = "320px";
  });
  const wrappedGeometry = await activitySlot.evaluate((slot) => {
    const card = slot.querySelector<HTMLElement>(".comma-chat-notice-card");
    if (!card) throw new Error("The activity slot has no notice card.");
    const slotRect = slot.getBoundingClientRect();
    const cardRect = card.getBoundingClientRect();
    return {
      cardBottom: cardRect.bottom,
      cardHeight: cardRect.height,
      slotBottom: slotRect.bottom,
      slotHeight: slotRect.height,
    };
  });
  expect(wrappedGeometry.cardHeight).toBeGreaterThan(44);
  expect(wrappedGeometry.slotHeight).toBeCloseTo(wrappedGeometry.cardHeight, 1);
  expect(wrappedGeometry.slotBottom).toBeGreaterThanOrEqual(wrappedGeometry.cardBottom);
});
