import { expect, test, type Page } from "@playwright/test";
import { writeFile } from "node:fs/promises";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

function animationState(element: Element) {
  return element.getAnimations()[0]?.playState;
}

async function installBriefing(page: Page, paragraphs = 1) {
  await page.route(
    /\/v1\/comma\/workspaces\/[^/]+\/recommendations(?:\?.*)?$/,
    async (route) => {
      await route.fulfill({
        json: {
          state: "fresh",
          settings: {
            autoEnableNewSources: true,
            schedule: { enabled: true, hour: 8, minute: 0, timezone: "Asia/Singapore" },
            sourceRevision: 1,
            sourcesCheckedAt: "2026-09-14T00:00:00Z",
            sources: [],
          },
          snapshot: {
            cards: [],
            generatedAt: Date.now(),
            generation: 1,
            protocolVersion: 1,
            sourceRevision: 1,
            summary: [
              {
                kind: "markdown",
                text:
                  "Good morning.\n\n" +
                  Array.from(
                    { length: paragraphs },
                    (_, index) =>
                      `Update ${index + 1}: Your workspace is ready. Review today's tasks and make room for focused work.`
                  ).join("\n\n"),
              },
            ],
            templateCatalogVersion: 1,
            warnings: [],
          },
        },
      });
    }
  );
}

test("window resizing reflows a long Home transcript without invalidating the whole document", async ({
  page,
}, testInfo) => {
  const text = Array.from(
    { length: 60 },
    (_, index) =>
      `## Investigation ${index + 1}\n\nThe layout should continuously reflow while resizing the window. Keep **formatted text**, a [reference](https://example.com), and inline \`code\` at their current width.\n\n- Preserve the conversation and reading position.\n- Make room for the next focused task.`
  ).join("\n\n");
  const stub = await startChatSmokeStub({
    workspaceTranscript: [
      {
        actor_type: "user",
        content: [{ type: "text", text: "Show the resize investigation" }],
        created_at: 1720000000,
        kind: "message",
        message_id: "resize-user",
      },
      {
        actor_type: "agent",
        content: [{ type: "text", text }],
        created_at: 1720000001,
        kind: "message",
        message_id: "resize-assistant",
      },
    ],
  });
  try {
    await page.setViewportSize({ width: 1600, height: 960 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-window-reflow@comma.local",
      token: "comma_sess_home_window_reflow",
    });
    await installBriefing(page, 12);
    await page.goto("/");
    const column = page.locator(".comma-home-chat .comma-chat-column");
    await expect(
      column.getByRole("heading", { name: "Investigation 60", exact: true })
    ).toHaveCount(1);
    await page.evaluate(() => document.fonts.ready);
    await page.waitForTimeout(500);
    const elementCount = await page.locator("*").count();
    const initialWidth = (await column.boundingBox())!.width;
    const cdp = await page.context().newCDPSession(page);
    const layouts: { dirty: number; total: number; milliseconds: number }[] = [];
    cdp.on("Tracing.dataCollected", ({ value }) => {
      for (const event of value) {
        if (event.name !== "Layout" || event.ph !== "X") continue;
        const layout = event as unknown as {
          args?: { beginData?: { dirtyObjects: number; totalObjects: number } };
          dur: number;
        };
        const data = layout.args?.beginData;
        if (typeof data?.dirtyObjects === "number") {
          layouts.push({
            dirty: data.dirtyObjects,
            total: data.totalObjects,
            milliseconds: layout.dur / 1000,
          });
        }
      }
    });
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
    await cdp.send("Tracing.start", {
      categories: "devtools.timeline",
      transferMode: "ReportEvents",
    });
    // Cross the former unused 1536px media query in both directions. Even
    // an empty media wrapper triggered a full document layout at each crossing.
    for (const width of [1544, 1528, 1480, 1528, 1544, 1600, 1480]) {
      await page.setViewportSize({ width, height: 960 });
      await page.evaluate(
        () => new Promise((resolve) => requestAnimationFrame(resolve))
      );
    }
    const complete = new Promise<void>((resolve) =>
      cdp.once("Tracing.tracingComplete", () => resolve())
    );
    await cdp.send("Tracing.end");
    await complete;
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: 1 });
    await cdp.detach();
    await testInfo.attach("window-reflow-layouts", {
      body: JSON.stringify({ elementCount, layouts }),
      contentType: "application/json",
    });
    // Assert browser work, not machine-specific milliseconds. The original
    // breakpoint dirtied every layout object in this long transcript.
    expect(layouts.length).toBeGreaterThan(0);
    expect(Math.max(...layouts.map((layout) => layout.dirty))).toBeLessThan(
      elementCount / 2
    );
    expect((await column.boundingBox())!.width).toBeLessThan(initialWidth - 20);
    await expect(
      column.getByRole("heading", { name: "Investigation 60", exact: true })
    ).toHaveCount(1);
  } finally {
    await stub.close();
  }
});

test("Greeting previews fold and reveal Tasks before pointer release", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ includeTaskInInbox: true });
  try {
    await page.setViewportSize({ width: 1440, height: 960 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-live-fold@comma.local",
      token: "comma_sess_home_live_fold",
    });
    await installBriefing(page);
    await page.goto("/");
    const layout = page.getByTestId("home-responsive-layout");
    const greet = page.getByTestId("home-greet-rail");
    const tasks = page.getByTestId("home-tasks-rail");
    const handle = page.getByTestId("home-greet-rail-handle");
    await expect(handle).toBeVisible();

    // This route fits Tasks beside a 260px Greeting, but not beside its initial
    // 300px width. Window chrome is measured so the route owns the same budget.
    const windowWidth = await layout.evaluate(
      (element) => window.innerWidth - element.getBoundingClientRect().width + 961
    );
    await page.setViewportSize({ width: Math.round(windowWidth), height: 960 });
    await expect(tasks).toHaveAttribute("data-folded", "true");
    await expect(greet).toHaveAttribute("data-folded", "false");
    const width = () =>
      greet.evaluate((element) => Math.round(element.getBoundingClientRect().width));
    await expect.poll(width).toBe(300);
    const box = (await handle.boundingBox())!;
    const x = box.x + box.width / 2;
    const y = box.y + 100;
    await page.mouse.move(x, y);
    await page.mouse.down();
    const cursorOverlay = page.getByTestId("home-rail-resize-cursor-overlay");
    await page.mouse.move(x - 4, y);
    await expect(cursorOverlay).toBeVisible();
    expect(
      await page.evaluate(() =>
        document.dispatchEvent(new Event("selectstart", { cancelable: true }))
      )
    ).toBe(false);

    for (const [offset, expectedWidth, folded] of [
      [-50, 250, "false"],
      [20, 320, "true"],
      [-40, 260, "false"],
    ] as const) {
      await page.mouse.move(x + offset, y, { steps: 12 });
      await expect.poll(width).toBe(expectedWidth);
      await expect(layout).toHaveAttribute("data-resizing", "greet");
      await expect(tasks).toHaveAttribute("data-folded", folded);
    }

    await page.mouse.up();
    await expect(layout).not.toHaveAttribute("data-resizing");
    await expect(cursorOverlay).toHaveCount(0);
    expect(
      await page.evaluate(() =>
        document.dispatchEvent(new Event("selectstart", { cancelable: true }))
      )
    ).toBe(true);
    await expect.poll(width).toBe(260);
    await page.getByRole("link", { name: "Inbox", exact: true }).click();
    await page.getByRole("link", { name: "Home", exact: true }).click();
    await expect.poll(width).toBe(260);
    await expect(tasks).toHaveAttribute("data-folded", "false");

    // Cancellation between pointer events and paint must flush the final width
    // and release the overlay and selection guard just like pointer release.
    const resumedBox = (await handle.boundingBox())!;
    const resumedX = resumedBox.x + resumedBox.width / 2;
    await page.mouse.move(resumedX, y);
    await page.mouse.down();
    await page.evaluate(
      ({ pointerX, pointerY }) => {
        window.dispatchEvent(
          new PointerEvent("pointermove", {
            pointerId: 1,
            pointerType: "mouse",
            buttons: 1,
            clientX: pointerX - 10,
            clientY: pointerY,
          })
        );
        window.dispatchEvent(
          new PointerEvent("pointercancel", { pointerId: 1, pointerType: "mouse" })
        );
      },
      { pointerX: resumedX, pointerY: y }
    );
    await expect.poll(width).toBe(250);
    await expect(layout).not.toHaveAttribute("data-resizing");
    await expect(cursorOverlay).toHaveCount(0);
    await page.mouse.up();
  } finally {
    await stub.close();
  }
});

test("Home rail seams resize, fold below 240 and expand from the indicator", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ includeTaskInInbox: true });
  try {
    await page.setViewportSize({ width: 1680, height: 960 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-resize@comma.local",
      token: "comma_sess_home_resize",
    });
    await installBriefing(page, 12);
    await page.goto("/");
    await expect(
      page.getByRole("heading", { name: /^Good (morning|afternoon|evening)/ })
    ).toBeVisible();
    for (const name of ["greet", "tasks"] as const) {
      const rail = page.getByTestId(`home-${name}-rail`);
      const handle = page.getByTestId(`home-${name}-rail-handle`);
      const width = async () => Math.round((await rail.boundingBox())?.width ?? 0);
      await expect(rail).toHaveAttribute("data-folded", "false");
      // Both rails start at 300px and can be resized down to 240px.
      await expect.poll(width).toBe(300);
      await handle.focus();
      await page.keyboard.press("Home");
      await expect.poll(width).toBe(240);
      const box = (await handle.boundingBox())!;
      const x = box.x + box.width / 2;
      const y = box.y + 100; // The whole seam, not only the centered indicator.
      const direction = name === "greet" ? 1 : -1;
      await page.mouse.move(x, y);
      const tooltip = page.getByTestId(`home-${name}-rail-tooltip`);
      await expect(tooltip).toBeVisible();
      await expect(tooltip).toContainText("Click to collapse");
      await expect(tooltip).toContainText("Drag to resize");
      const initialTooltip = (await tooltip.boundingBox())!;
      await page.mouse.move(x, y + 150, { steps: 12 });
      await expect
        .poll(async () =>
          Math.round((await tooltip.boundingBox())!.y - initialTooltip.y)
        )
        .toBe(150);
      await expect
        .poll(() =>
          handle.evaluate((element) => getComputedStyle(element, "::before").opacity)
        )
        .toBe("1");
      await expect
        .poll(() =>
          handle.evaluate((element) => getComputedStyle(element, "::after").opacity)
        )
        .toBe("1");
      // Both pseudo-elements share an exact center, including the 1px seam.
      await expect
        .poll(() =>
          handle.evaluate((element) => {
            const centers = ["::before", "::after"].map((pseudo) => {
              const style = getComputedStyle(element, pseudo);
              const transform = new DOMMatrixReadOnly(style.transform);
              return {
                x: parseFloat(style.left) + parseFloat(style.width) / 2 + transform.m41,
                y: parseFloat(style.top) + parseFloat(style.height) / 2 + transform.m42,
              };
            });
            return Math.max(
              Math.abs(centers[0]!.x - centers[1]!.x),
              Math.abs(centers[0]!.y - centers[1]!.y)
            );
          })
        )
        .toBeLessThan(0.01);
      await page.mouse.move(x, y);
      // Include both gesture boundaries: inherited cursor/selection changes
      // previously restyled the entire Home tree on pointer down and release.
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Emulation.setCPUThrottlingRate", { rate: 4 });
      const styleRecalculations: number[] = [];
      const homeElementCount = await page
        .getByTestId("home-responsive-layout")
        .locator("*")
        .count();
      await page.evaluate(
        () =>
          new Promise((resolve) =>
            requestAnimationFrame(() => requestAnimationFrame(resolve))
          )
      );
      cdp.on("Tracing.dataCollected", ({ value }) => {
        for (const event of value) {
          const args: unknown = event.args;
          if (
            event.name === "UpdateLayoutTree" &&
            typeof args === "object" &&
            args !== null &&
            "elementCount" in args &&
            typeof args.elementCount === "number" &&
            args.elementCount > 0
          ) {
            styleRecalculations.push(args.elementCount);
          }
        }
      });
      await cdp.send("Tracing.start", {
        categories: "devtools.timeline",
        transferMode: "ReportEvents",
      });
      await page.mouse.down();
      await expect(tooltip).toHaveCount(0);
      await page.mouse.move(x + direction * 100, y, { steps: 24 });
      await expect.poll(width).toBe(340);
      await page.mouse.up();
      await page.evaluate(
        () =>
          new Promise((resolve) =>
            requestAnimationFrame(() => requestAnimationFrame(resolve))
          )
      );
      const complete = new Promise<void>((resolve) =>
        cdp.once("Tracing.tracingComplete", () => resolve())
      );
      await cdp.send("Tracing.end");
      await complete;
      await cdp.send("Emulation.setCPUThrottlingRate", { rate: 1 });
      await cdp.detach();
      // A panel drag must not restyle most of Home at its boundaries or updates.
      expect(styleRecalculations.length).toBeGreaterThan(0);
      expect(Math.max(...styleRecalculations)).toBeLessThan(homeElementCount / 2);
      await expect(rail).toHaveAttribute("data-folded", "false");
      await page.waitForTimeout(300);
      const grown = (await handle.boundingBox())!;
      await page.mouse.move(grown.x + grown.width / 2, y);
      await page.mouse.down();
      await page.mouse.move(x, y, { steps: 24 });
      await expect.poll(width).toBe(240);
      await expect(rail).toHaveAttribute("data-folded", "false");
      await page.mouse.move(x - direction * 8, y, { steps: 4 });
      // Collapse happens before releasing the pointer.
      await expect(rail).toHaveAttribute("data-folded", "true");
      await page.mouse.up();
      await expect(handle).toHaveAttribute("aria-expanded", "false");
      await page.waitForTimeout(300);
      await handle.focus();
      await handle.hover();
      await expect
        .poll(() =>
          handle.evaluate((element) => getComputedStyle(element, "::before").display)
        )
        .toBe("none");
      await expect
        .poll(() =>
          handle.evaluate((element) => getComputedStyle(element, "::after").opacity)
        )
        .toBe("1");
      await expect(tooltip).toHaveText("Click to expand");
      await handle.click();
      await expect(rail).toHaveAttribute("data-folded", "false");
      await expect.poll(width).toBe(240);
      await handle.focus();
      await page.keyboard.press(name === "greet" ? "ArrowRight" : "ArrowLeft");
      await expect.poll(width).toBe(256);
      await page.keyboard.press("Home");
      await expect.poll(width).toBe(240);
      // Each key step applies before the next event. A layout transition here
      // makes repeated keys calculate from a width that has not arrived yet.
      for (const expectedWidth of [256, 272, 288]) {
        await page.keyboard.press(name === "greet" ? "ArrowRight" : "ArrowLeft");
        expect(await width()).toBe(expectedWidth);
      }
      await page.keyboard.press("Home");
      expect(await width()).toBe(240);
      // A burst can end before the next paint. The final width must survive
      // pointer release, without a delayed update from the preceding frame.
      const seam = (await handle.boundingBox())!;
      const startX = seam.x + seam.width / 2;
      await page.mouse.move(startX, y);
      await page.mouse.down();
      await page.evaluate(
        ({ pointerX, pointerY, sign }) => {
          for (const offset of [16, 32, 48]) {
            window.dispatchEvent(
              new PointerEvent("pointermove", {
                pointerId: 1,
                pointerType: "mouse",
                buttons: 1,
                clientX: pointerX + sign * offset,
                clientY: pointerY,
              })
            );
          }
          window.dispatchEvent(
            new PointerEvent("pointerup", {
              pointerId: 1,
              pointerType: "mouse",
              button: 0,
              clientX: pointerX + sign * 48,
              clientY: pointerY,
            })
          );
        },
        { pointerX: startX, pointerY: y, sign: direction }
      );
      await page.mouse.up();
      await expect.poll(width).toBe(288);
      await handle.focus();
      await page.keyboard.press("Home");
      await expect.poll(width).toBe(240);
      // A plain click on the full-height seam still collapses the entire rail.
      await handle.click({ position: { x: 8, y: 100 } });
      await expect(rail).toHaveAttribute("data-folded", "true");
      await handle.click();
      await expect(rail).toHaveAttribute("data-folded", "false");
    }
    // Route changes must not replace user-selected widths with the defaults.
    await page.getByRole("link", { name: "Inbox", exact: true }).click();
    await page.getByRole("link", { name: "Home", exact: true }).click();
    for (const name of ["greet", "tasks"] as const) {
      await expect
        .poll(async () =>
          Math.round(
            (await page.getByTestId(`home-${name}-rail`).boundingBox())?.width ?? 0
          )
        )
        .toBe(240);
    }
    await page.setViewportSize({ width: 950, height: 960 });
    await expect(page.getByTestId("home-tasks-rail")).toHaveAttribute(
      "data-folded",
      "true"
    );
    await expect(page.getByTestId("home-greet-rail")).toHaveAttribute(
      "data-folded",
      "false"
    );
    await page.setViewportSize({ width: 1680, height: 960 });
    await expect(page.getByTestId("home-tasks-rail")).toHaveAttribute(
      "data-folded",
      "false"
    );
  } finally {
    await stub.close();
  }
});

test("Home folds preserve content layout and scroll through expansion and reversal", async ({
  page,
}, testInfo) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    extraInlineTasks: Array.from({ length: 24 }, (_, index) => ({
      id: `fold-task-${index}`,
      status: "active",
      title: `Review ${index + 1}: check the current workspace changes and prepare the next delivery`,
    })),
  });
  try {
    await page.setViewportSize({ width: 1680, height: 640 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-fold-layout@comma.local",
      token: "comma_sess_home_fold_layout",
    });
    await installBriefing(page, 12);
    await page.goto("/");
    await expect(
      page.getByRole("heading", { name: /^Good (morning|afternoon|evening)/ })
    ).toBeVisible();
    await expect(page.getByTestId("home-tasks-card-stack").locator("li")).toHaveCount(
      24
    );

    for (const name of ["greet", "tasks"] as const) {
      await expect
        .poll(() =>
          page
            .getByTestId(`home-${name}-rail`)
            .locator('[data-slot="scroll-area-viewport"]')
            .first()
            .evaluate((element) => element.scrollHeight - element.clientHeight)
        )
        .toBeGreaterThan(100);
    }

    // Continuous status effects belong to visible cards. Offscreen cards keep
    // their text and DOM so scrolling and keyboard navigation still work.
    const taskRail = page.getByTestId("home-tasks-rail");
    const progress = taskRail.locator(".comma-shiny-text");
    const firstProgress = progress.first();
    const lastProgress = progress.last();
    await expect.poll(() => firstProgress.evaluate(animationState)).toBe("running");
    await expect.poll(() => lastProgress.evaluate(animationState)).toBe("paused");
    const pausedPhase = await lastProgress.evaluate(async (element) => {
      const animation = element.getAnimations()[0]!;
      const before = animation.currentTime;
      await new Promise((resolve) => setTimeout(resolve, 100));
      return { before, after: animation.currentTime };
    });
    expect(pausedPhase.after).toBe(pausedPhase.before);
    const taskViewport = taskRail.locator('[data-slot="scroll-area-viewport"]').first();
    // Put a clipped card exactly on the scrollport edge. Threshold zero can
    // report this contact without another callback when its visible area grows.
    const edgeContact = await lastProgress.evaluate(async (element) => {
      const item = element.closest("li")!;
      const viewport = item.closest('[data-slot="scroll-area-viewport"]')!;
      const edge = viewport.getBoundingClientRect().top + viewport.clientHeight;
      item.style.transform = `translateY(${edge - item.getBoundingClientRect().top}px)`;
      return new Promise<{ intersects: boolean; ratio: number }>((resolve) => {
        const observer = new IntersectionObserver(([entry]) => {
          observer.disconnect();
          resolve({
            intersects: entry!.isIntersecting,
            ratio: entry!.intersectionRatio,
          });
        });
        observer.observe(item);
      });
    });
    expect(edgeContact).toEqual({ intersects: true, ratio: 0 });
    await taskViewport.evaluate((element) => {
      element.scrollTop = 40;
    });
    await expect.poll(() => lastProgress.evaluate(animationState)).toBe("running");
    await lastProgress.evaluate((element) => {
      element.closest("li")!.style.removeProperty("transform");
    });
    await taskViewport.evaluate((element) => {
      element.scrollTop = element.scrollHeight;
    });
    await expect.poll(() => lastProgress.evaluate(animationState)).toBe("running");
    await expect.poll(() => firstProgress.evaluate(animationState)).toBe("paused");
    const taskHandle = page.getByTestId("home-tasks-rail-handle");
    await taskHandle.click();
    await expect
      .poll(() =>
        progress.evaluateAll(
          (elements) =>
            elements.filter(
              (element) => element.getAnimations()[0]?.playState === "running"
            ).length
        )
      )
      .toBe(0);
    await taskRail.evaluate((element) =>
      Promise.all(element.getAnimations().map((animation) => animation.finished))
    );
    await expect(
      page.getByRole("complementary", { name: "Tasks", exact: true })
    ).toHaveCount(0);
    expect(
      await taskRail
        .getByTestId("home-task-card")
        .last()
        .evaluate((element) => {
          element.focus();
          return document.activeElement === element;
        })
    ).toBe(false);
    await taskHandle.click();
    await expect.poll(() => lastProgress.evaluate(animationState)).toBe("running");
    await taskViewport.evaluate((element) => {
      element.scrollTop = 0;
    });
    // Replacing the status page mounts a fresh stack. Its visibility behavior
    // must match the initial stack, including cards outside the scrollport.
    const statuses = taskRail.locator('status-indicator [role="radio"]');
    await statuses.nth(0).click();
    await expect(page.getByTestId("home-tasks-card-stack").locator("li")).toHaveCount(
      0
    );
    await statuses.nth(1).click();
    await expect(page.getByTestId("home-tasks-card-stack").locator("li")).toHaveCount(
      24
    );
    await expect.poll(() => firstProgress.evaluate(animationState)).toBe("running");
    await expect.poll(() => lastProgress.evaluate(animationState)).toBe("paused");

    // Freeze a real exit while a card is still visible. Pointer input must
    // not reach that card, and must work again after reversing the fold.
    const firstCard = taskRail.getByTestId("home-task-card").first();
    const inputProbe = await firstCard.evaluateHandle((element) => {
      const events: string[] = [];
      const controller = new AbortController();
      for (const type of ["pointerdown", "click", "contextmenu"]) {
        element.addEventListener(
          type,
          (event) => {
            events.push(event.type);
            event.preventDefault();
            event.stopImmediatePropagation();
          },
          { capture: true, signal: controller.signal }
        );
      }
      return { events, stop: () => controller.abort() };
    });
    await taskHandle.click();
    const layout = page.getByTestId("home-responsive-layout");
    await layout.evaluate((element) => {
      for (const animation of element.getAnimations({ subtree: true })) {
        if (animation instanceof CSSTransition) {
          animation.pause();
          // Freeze early enough to leave a clickable slice of the 300px rail.
          animation.currentTime = 24;
        }
      }
    });
    const railBox = (await taskRail.boundingBox())!;
    const cardBox = (await firstCard.boundingBox())!;
    const left = Math.max(railBox.x, cardBox.x);
    const right = Math.min(railBox.x + railBox.width, cardBox.x + cardBox.width);
    expect(right - left).toBeGreaterThan(20);
    const pointer = { x: (left + right) / 2, y: cardBox.y + cardBox.height / 2 };
    await page.mouse.click(pointer.x, pointer.y);
    await page.mouse.click(pointer.x, pointer.y, { button: "right" });
    await page.mouse.move(pointer.x, pointer.y);
    await page.mouse.down();
    await page.mouse.move(pointer.x + 8, pointer.y + 8);
    await page.mouse.up();
    expect(await inputProbe.evaluate((probe) => probe.events)).toEqual([]);
    await taskHandle.evaluate((element) => (element as HTMLButtonElement).click());
    await layout.evaluate((element) => {
      for (const animation of element.getAnimations({ subtree: true })) {
        if (animation instanceof CSSTransition && animation.playState === "paused") {
          animation.play();
        }
      }
    });
    await firstCard.click();
    expect(await inputProbe.evaluate((probe) => probe.events)).toEqual([
      "pointerdown",
      "click",
    ]);
    await inputProbe.evaluate((probe) => probe.stop());
    await inputProbe.dispose();

    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Performance.enable");
    const before = await cdp.send("Performance.getMetrics");
    const samples = [];
    for (const name of ["greet", "tasks"] as const) {
      for (const reverse of [false, true]) {
        const result = await page.evaluate(
          async ({ name: railName, reverse: interruptFold }) => {
            const rail = document.querySelector<HTMLElement>(
              `[data-testid="home-${railName}-rail"]`
            )!;
            const surface = rail.querySelector<HTMLElement>(
              ".comma-home-rail-surface"
            )!;
            const viewport = rail.querySelector<HTMLElement>(
              '[data-slot="scroll-area-viewport"]'
            )!;
            const handle = document.querySelector<HTMLButtonElement>(
              `[data-testid="home-${railName}-rail-handle"]`
            )!;
            viewport.scrollTop = 100;
            const initialScroll = viewport.scrollTop;
            const initialWidth = surface.offsetWidth;
            const frames: { time: number; contentWidth: number; railWidth: number }[] =
              [];
            const sample = async (interrupt: boolean) => {
              const start = performance.now();
              let reversed = false;
              handle.click();
              while (performance.now() - start < 350) {
                await new Promise(requestAnimationFrame);
                const elapsed = performance.now() - start;
                frames.push({
                  time: elapsed,
                  contentWidth: surface.offsetWidth,
                  railWidth: rail.getBoundingClientRect().width,
                });
                if (interrupt && !reversed && elapsed >= 48) {
                  handle.click();
                  reversed = true;
                }
              }
            };
            await sample(interruptFold);
            if (!interruptFold) await sample(false);
            return {
              initialWidth,
              initialScroll,
              frames,
              finalScroll: viewport.scrollTop,
              sameSurface: rail.querySelector(".comma-home-rail-surface") === surface,
              expanded: handle.getAttribute("aria-expanded"),
              folded: rail.dataset.folded,
            };
          },
          { name, reverse }
        );
        samples.push({ name, reverse, ...result });
      }
    }
    const after = await cdp.send("Performance.getMetrics");
    const evidencePath = testInfo.outputPath("home-fold-layout.json");
    await writeFile(
      evidencePath,
      JSON.stringify({ before: before.metrics, after: after.metrics, samples }, null, 2)
    );
    await testInfo.attach("home-fold-layout", {
      path: evidencePath,
      contentType: "application/json",
    });
    for (const sample of samples) {
      expect(sample.initialScroll).toBe(100);
      expect(sample.sameSurface).toBe(true);
      expect(sample.finalScroll).toBe(sample.initialScroll);
      expect(sample.expanded).toBe("true");
      expect(sample.folded).toBe("false");
      expect(
        sample.frames.some(
          (frame) => frame.railWidth > 1 && frame.railWidth < sample.initialWidth - 1
        )
      ).toBe(true);
      expect(new Set(sample.frames.map((frame) => frame.contentWidth))).toEqual(
        new Set([sample.initialWidth])
      );
    }
  } finally {
    await stub.close();
  }
});

test("folding Greet reallocates constrained width to Tasks without remounting content", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    extraInlineTasks: Array.from({ length: 24 }, (_, index) => ({
      id: `linked-rail-task-${index}`,
      status: "active",
      title: index === 23 ? "Review current workspace changes" : `Task ${index + 1}`,
    })),
  });
  try {
    // This leaves both rails open, while Tasks is below its preferred width.
    await page.setViewportSize({ width: 1107, height: 640 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-linked-rails@comma.local",
      token: "comma_sess_home_linked_rails",
    });
    await installBriefing(page, 12);
    await page.goto("/");
    await expect(
      page.getByRole("heading", { name: /^Good (morning|afternoon|evening)/ })
    ).toBeVisible();
    await expect(page.getByTestId("home-greet-rail")).toHaveAttribute(
      "data-folded",
      "false"
    );
    await expect(page.getByTestId("home-tasks-rail")).toHaveAttribute(
      "data-folded",
      "false"
    );
    await expect(page.getByTestId("home-tasks-card-stack").locator("li")).toHaveCount(
      24
    );

    const result = await page.evaluate(async () => {
      const greetRail = document.querySelector<HTMLElement>(
        '[data-testid="home-greet-rail"]'
      )!;
      const greetSurface = greetRail.querySelector<HTMLElement>(
        ".comma-home-rail-surface"
      )!;
      const greetHandle = document.querySelector<HTMLButtonElement>(
        '[data-testid="home-greet-rail-handle"]'
      )!;
      const tasksRail = document.querySelector<HTMLElement>(
        '[data-testid="home-tasks-rail"]'
      )!;
      const tasksSurface = tasksRail.querySelector<HTMLElement>(
        ".comma-home-rail-surface"
      )!;
      const tasksViewport = tasksRail.querySelector<HTMLElement>(
        '.comma-home-tasks-panel[data-role="current"] [data-slot="scroll-area-viewport"]'
      )!;
      const taskList = tasksRail.querySelector<HTMLElement>(
        '[data-testid="home-tasks-card-stack"]'
      )!;
      const taskTitles = taskList.querySelectorAll<HTMLElement>(
        '[data-slot="task-card-title"]'
      );
      const taskTitle = taskTitles[taskTitles.length - 1]!;
      const readGeometry = () => ({
        greetContentWidth: greetSurface.offsetWidth,
        greetRailWidth: greetRail.getBoundingClientRect().width,
        taskTitleHeight: taskTitle.getBoundingClientRect().height,
        tasksContentWidth: tasksSurface.offsetWidth,
        tasksRailWidth: tasksRail.getBoundingClientRect().width,
      });

      tasksViewport.scrollTop = 100;
      const initialScroll = tasksViewport.scrollTop;
      const initial = readGeometry();
      const frames: ReturnType<typeof readGeometry>[] = [];
      const start = performance.now();
      greetHandle.click();
      while (performance.now() - start < 350) {
        await new Promise(requestAnimationFrame);
        frames.push(readGeometry());
      }
      const final = readGeometry();

      return {
        final,
        finalScroll: tasksViewport.scrollTop,
        frames,
        initial,
        initialScroll,
        sameDom:
          document.querySelector('[data-testid="home-greet-rail"]') === greetRail &&
          greetRail.querySelector(".comma-home-rail-surface") === greetSurface &&
          document.querySelector('[data-testid="home-tasks-rail"]') === tasksRail &&
          tasksRail.querySelector(".comma-home-rail-surface") === tasksSurface &&
          tasksRail.querySelector(
            '.comma-home-tasks-panel[data-role="current"] [data-slot="scroll-area-viewport"]'
          ) === tasksViewport &&
          tasksRail.querySelector('[data-testid="home-tasks-card-stack"]') ===
            taskList &&
          taskList.querySelectorAll('[data-slot="task-card-title"]')[
            taskTitles.length - 1
          ] === taskTitle,
      };
    });

    expect(result.initialScroll).toBe(100);
    expect(result.finalScroll).toBe(result.initialScroll);
    expect(result.sameDom).toBe(true);
    expect(result.initial.tasksContentWidth).toBeLessThan(300);
    expect(result.initial.tasksRailWidth).toBeLessThan(300);
    expect(result.final.tasksContentWidth).toBe(300);
    expect(result.final.tasksRailWidth).toBe(300);
    expect(result.final.taskTitleHeight).toBeLessThan(result.initial.taskTitleHeight);
    expect(
      result.frames.some(
        (frame) =>
          frame.greetRailWidth > 1 &&
          frame.greetRailWidth < result.initial.greetRailWidth - 1
      )
    ).toBe(true);
    expect(new Set(result.frames.map((frame) => frame.greetContentWidth))).toEqual(
      new Set([result.initial.greetContentWidth])
    );
    await expect(page.getByTestId("home-greet-rail")).toHaveAttribute(
      "data-folded",
      "true"
    );
  } finally {
    await stub.close();
  }
});

test("expanded Home indicators hint on region entry without renewing on content movement", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ includeTaskInInbox: true });
  try {
    await page.setViewportSize({ width: 1680, height: 960 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-region-hint@comma.local",
      token: "comma_sess_home_region_hint",
    });
    await installBriefing(page);
    await page.goto("/");
    await expect(page.getByTestId("home-tasks-rail-handle")).toBeVisible();
    await page.evaluate(() => {
      document.documentElement.dataset.commaReducedMotion = "true";
    });
    await page.clock.install({ time: new Date("2026-01-01T00:00:00Z") });
    await page.clock.pauseAt(new Date("2026-01-02T00:00:00Z"));

    for (const name of ["greet", "tasks"] as const) {
      const rail = page.getByTestId(`home-${name}-rail`);
      const handle = page.getByTestId(`home-${name}-rail-handle`);
      const opacity = () =>
        handle.evaluate((element) => getComputedStyle(element, "::after").opacity);
      await page.mouse.move(30, 350);
      await expect.poll(opacity).toBe("0");
      const box = (await rail.boundingBox())!;
      await page.mouse.move(box.x + box.width / 2, box.y + 100);
      await expect.poll(opacity).toBe("1");
      const shortHeight = await handle.evaluate(
        (element) => getComputedStyle(element, "::after").height
      );
      await page.clock.runFor(2900);
      await page.mouse.move(box.x + box.width / 2 + 10, box.y + 150);
      await expect.poll(opacity).toBe("1");
      await page.clock.runFor(100);
      await expect.poll(opacity).toBe("0");
      await page.mouse.move(box.x + box.width / 2, box.y + 200);
      await expect.poll(opacity).toBe("0");

      // Direct interaction remains available after the discovery hint expires.
      await handle.hover();
      await page.clock.runFor(3500);
      await expect.poll(opacity).toBe("1");
      expect(
        await handle.evaluate((element) =>
          parseFloat(getComputedStyle(element, "::after").height)
        )
      ).toBeGreaterThan(parseFloat(shortHeight));
      await expect(page.getByTestId(`home-${name}-rail-tooltip`)).toBeVisible();
      await page.mouse.move(30, 350);
      await expect.poll(opacity).toBe("0");

      // A new visit reveals a new hint; leaving cancels it immediately.
      await page.mouse.move(box.x + box.width / 2, box.y + 100);
      await expect.poll(opacity).toBe("1");
      await page.mouse.move(30, 350);
      await expect.poll(opacity).toBe("0");
      await rail.dispatchEvent("pointerenter", { pointerType: "touch" });
      await expect.poll(opacity).toBe("0");
    }
    await page.clock.resume();
  } finally {
    await stub.close();
  }
});

test("collapsed Home indicators follow window mouse activity and one-second idle", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  try {
    await page.setViewportSize({ width: 1680, height: 960 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "home-indicators@comma.local",
      token: "comma_sess_home_indicators",
    });
    await page.goto("/");
    const handles = [
      page.getByTestId("home-greet-rail-handle"),
      page.getByTestId("home-tasks-rail-handle"),
    ];
    await expect(handles[0]!).toBeVisible();
    await page.evaluate(() => {
      document.documentElement.dataset.commaReducedMotion = "true";
    });
    // Use one explicit clock origin; host and browser clocks can differ in CI.
    const clockStart = new Date("2026-01-01T00:00:00Z");
    await page.clock.install({ time: clockStart });
    await page.clock.pauseAt(new Date("2026-01-02T00:00:00Z"));

    const opacity = async (value: string) => {
      for (const handle of handles) {
        await expect
          .poll(() =>
            handle.evaluate((element) => getComputedStyle(element, "::after").opacity)
          )
          .toBe(value);
      }
    };

    for (const handle of handles) {
      await handle.click();
      await expect(handle).toHaveAttribute("aria-expanded", "false");
      // Collapse itself reveals the indicator, without approaching its new edge.
      await expect
        .poll(() =>
          handle.evaluate((element) => getComputedStyle(element, "::after").opacity)
        )
        .toBe("1");
    }
    await page.clock.runFor(1000);
    await opacity("0");

    // The app sidebar is outside Home. Its mouse activity reveals both edges.
    await page.mouse.move(30, 350);
    await opacity("1");
    await page.clock.runFor(900);
    await opacity("1");
    await page.mouse.move(31, 351);
    await page.clock.runFor(900);
    await opacity("1");
    await page.clock.runFor(100);
    await opacity("0");

    // Neither a stationary hover nor touch movement defeats the idle timeout.
    await handles[0]!.hover();
    await opacity("1");
    await page.clock.runFor(1000);
    await opacity("0");
    await page.dispatchEvent("body", "pointermove", { pointerType: "touch" });
    await opacity("0");

    // Keyboard users keep a visible affordance after the mouse timer expires.
    await page.keyboard.press("Tab");
    await handles[0]!.focus();
    await page.clock.runFor(1000);
    await expect
      .poll(() =>
        handles[0]!.evaluate((element) => getComputedStyle(element, "::after").opacity)
      )
      .toBe("1");
    await page.keyboard.press("Enter");
    await expect(handles[0]!).toHaveAttribute("aria-expanded", "true");
    await expect(handles[0]!).not.toHaveAttribute("data-mouse-active");
    await page.clock.resume();

    // Persisted collapsed rails get the same initial reveal after a reload.
    await page.reload();
    await expect(handles[1]!).toHaveAttribute("aria-expanded", "false");
    await expect(handles[1]!).toHaveAttribute("data-mouse-active", "true");
    await expect(handles[1]!).toHaveAttribute("data-mouse-active", "false");
  } finally {
    await stub.close();
  }
});
