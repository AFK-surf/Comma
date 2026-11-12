import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../../e2e/helpers/browser-auth";
import { waitForFiniteAnimations } from "../../../../e2e/helpers/motion";
import { startChatSmokeStub } from "../../../../e2e/p0/chat-stub";

const runningTasks = Array.from({ length: 3 }, (_, index) => ({
  id: `cnv_idle_motion_${index}`,
  status: "in_progress",
  title: `Idle motion task ${index}`,
}));

/** Properties the compositor animates without a style recalculation. */
const compositorProperties = ["opacity", "rotate", "scale", "transform", "translate"];

// A running Task's shine loops for as long as the Task runs. It moves on the
// compositor: a loop on any other property restyles and paints the whole page
// at every display frame, and every interaction then shares those frames.
// The test reads what each loop animates, not how much work a stretch of real
// time took, so a loaded machine gives the same result.
test("Home's running Tasks shine without restyling the page each frame", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    extraInlineTasks: runningTasks,
    includeTaskInInbox: true,
    taskStatus: "in_progress",
  });
  try {
    await page.setViewportSize({ width: 1600, height: 960 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "idle-motion@comma.local",
      token: "comma_sess_idle_motion",
    });
    await page.goto("/");
    await expect(
      page.getByTestId("home-tasks-rail").locator(".comma-shiny-text").first()
    ).toBeVisible();
    await waitForFiniteAnimations(page);

    const loops = await page.evaluate(() =>
      document
        .getAnimations()
        .filter(
          (animation) =>
            animation.playState === "running" &&
            animation.effect?.getComputedTiming().iterations === Infinity
        )
        .map((animation) => {
          const effect = animation.effect as KeyframeEffect;
          const target = effect.target;
          const properties = new Set(
            effect
              .getKeyframes()
              .flatMap((keyframe) => Object.keys(keyframe))
              .filter(
                (key) =>
                  !["composite", "computedOffset", "easing", "offset"].includes(key)
              )
          );
          return {
            name:
              animation instanceof CSSAnimation
                ? animation.animationName
                : animation.id,
            target: `${target?.getAttribute("class") ?? ""}${effect.pseudoElement ?? ""}`,
            properties: [...properties].toSorted(),
          };
        })
    );
    // The rail's shines are among the loops, so the check covers them.
    expect(
      loops.filter((loop) => loop.name === "comma-shiny-text-shine").length
    ).toBeGreaterThan(0);
    expect(
      loops.filter((loop) =>
        loop.properties.some((property) => !compositorProperties.includes(property))
      )
    ).toEqual([]);
  } finally {
    await stub.close();
  }
});

/** A published briefing with one Routines card. */
const briefing = {
  settings: {
    autoEnableNewSources: true,
    schedule: { enabled: true, hour: 8, minute: 0, timezone: "Etc/UTC" },
    sourceRevision: 1,
    sources: [
      {
        appId: "slack",
        appName: "Slack",
        connectionId: "local-slack",
        enabled: true,
        kind: "composio",
        label: "Slack",
      },
    ],
    sourcesCheckedAt: "2026-09-04T00:00:00Z",
  },
  snapshot: {
    cards: [
      {
        fallbackText: "Reply to Lin",
        id: "slack",
        items: [
          {
            action: {
              label: "Reply to Lin",
              prompt: "Lin asked you to own the handoff. Draft a reply.",
              requiresConfirmation: false,
              type: "open_task_form",
            },
            id: "reply-lin",
            parts: [{ kind: "markdown", text: "Reply to Lin about the handoff" }],
          },
        ],
        sourceIds: ["local-slack"],
        template: "text-list@1",
        title: "Slack",
      },
    ],
    generatedAt: 1,
    generation: 1,
    protocolVersion: 1,
    sourceRevision: 1,
    summary: [{ kind: "markdown", text: "Good morning.\n\nOne reply is waiting." }],
    templateCatalogVersion: 1,
    warnings: [],
  },
  state: "fresh",
};

// Home stays mounted, skipped by content-visibility, while another page
// shows. A loop inside it cannot run on the compositor there: once anything
// recalculates the hidden styles (the composer's caret, a measure), it ticks
// on the main thread at every display frame and draws nothing. So the hidden
// Home holds its loops paused, pseudo-element bands included, and mounts no
// loading skeleton of its own; when it shows again they run on.
test("a Home left for another page keeps its loops paused and its Routines as they were", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    externalActivityProvider: "wechat",
    extraInlineTasks: runningTasks,
    includeTaskInInbox: true,
    taskStatus: "in_progress",
  });
  try {
    await page.setViewportSize({ width: 1600, height: 960 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "idle-motion-hidden@comma.local",
      token: "comma_sess_idle_motion_hidden",
    });
    await page.route(
      /\/v1\/comma\/workspaces\/[^/]+\/recommendations(?:\?.*)?$/,
      (route) => route.fulfill({ json: briefing })
    );
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    const routineCard = content.getByText("Reply to Lin about the handoff");
    await expect(routineCard).toBeVisible();
    const shine = page
      .getByTestId("home-tasks-rail")
      .locator(".comma-shiny-text")
      .first();
    await expect(shine).toBeVisible();
    // The Router is thinking: its bubble breathes.
    stub.publishStreamingParticipantStatus("is thinking...");
    const thinking = content
      .getByTestId("participant-status-slot")
      .locator(".comma-chat-thinking-bubble");
    await expect(thinking).toBeVisible();
    await waitForFiniteAnimations(page);
    const routineCardElement = await routineCard.elementHandle();

    // The member drafts on Home, then opens Tasks.
    const composer = content.getByRole("textbox", { name: "AI prompt" });
    const composerElement = await composer.elementHandle();
    await composer.click();
    await page.keyboard.type("Draft for later");
    await page.getByRole("link", { name: "Tasks", exact: true }).click();
    await expect(
      page.getByRole("region", { name: "Tasks", exact: true })
    ).toBeVisible();

    const hiddenHome = await page
      .locator("[data-comma-surface-paused='true']")
      .evaluate((home, caretHost) => {
        // Recalculates the hidden styles, as the caret left in the composer does.
        void getComputedStyle(caretHost).color;
        return {
          loadingSkeleton:
            home.querySelector("[data-testid='recommendations-loading']") !== null,
          runningLoops: home
            .getAnimations({ subtree: true })
            .filter(
              (animation) =>
                animation.playState === "running" &&
                animation.effect?.getComputedTiming().iterations === Infinity
            )
            .map((animation) => {
              const effect = animation.effect as KeyframeEffect;
              const name =
                animation instanceof CSSAnimation
                  ? animation.animationName
                  : animation.id;
              return `${name} on ${effect.target?.getAttribute("class") ?? ""}${effect.pseudoElement ?? ""}`;
            }),
        };
      }, composerElement!);
    expect(hiddenHome).toEqual({ loadingSkeleton: false, runningLoops: [] });

    await page.getByRole("link", { name: "Home", exact: true }).click();
    await expect(routineCard).toBeVisible();
    // The rail shows the very card it showed: it was neither dropped nor rebuilt.
    expect(
      await routineCard.evaluate(
        (element, kept) => element === kept,
        routineCardElement
      )
    ).toBe(true);
    // Shown again, the bubble breathes on.
    expect(
      await thinking.evaluate((element) =>
        element
          .getAnimations({ subtree: true })
          .filter((animation) => animation.playState === "running")
          .map((animation) => (animation as CSSAnimation).animationName)
      )
    ).toContain("comma-chat-thinking-breathe");
  } finally {
    await stub.close();
  }
});

test("a caret left in Home's composer waits outside the hidden Home and comes back with it", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({});
  try {
    await page.setViewportSize({ width: 1600, height: 960 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "idle-motion-caret@comma.local",
      token: "comma_sess_idle_motion_caret",
    });
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    const composer = content.getByRole("textbox", { name: "AI prompt" });
    await composer.click();
    await page.keyboard.type("Draft for later");
    await page.getByRole("link", { name: "Tasks", exact: true }).click();
    await expect(
      page.getByRole("region", { name: "Tasks", exact: true })
    ).toBeVisible();

    // A selection inside content the browser skips costs every frame of the
    // page in front in proportion to that content, so none stays in Home.
    expect(
      await page.locator("[data-comma-surface-paused='true']").evaluate((home) => {
        const selection = window.getSelection()!;
        return Array.from({ length: selection.rangeCount }, (_, index) =>
          selection.getRangeAt(index)
        ).some((range) => home.contains(range.commonAncestorContainer));
      })
    ).toBe(false);

    await page.getByRole("link", { name: "Home", exact: true }).click();
    await expect(composer).toBeVisible();
    // Home shown again, the caret is back where the member left it.
    expect(
      await composer.evaluate((element) => {
        const selection = window.getSelection()!;
        const range = selection.rangeCount > 0 ? selection.getRangeAt(0) : null;
        if (!range || !element.contains(range.startContainer)) return null;
        const before = document.createRange();
        before.selectNodeContents(element);
        before.setEnd(range.startContainer, range.startOffset);
        return { collapsed: range.collapsed, textBefore: before.toString() };
      })
    ).toEqual({ collapsed: true, textBefore: "Draft for later" });
  } finally {
    await stub.close();
  }
});

// Chromium stops updating the animations of a subtree it skips, but keeps
// scheduling frames from the state it last computed for them. A transition
// still running when Home hides (the send button's, when the member opens
// Tasks right after typing) never ends there: it asks for a main
// thread frame at every display frame, and each of those frames restyles the
// Tasks page's shines although they run on the compositor. Hiding Home
// finishes its finite motion. The test counts frames over one sweep of a
// visible shine, so the result does not depend on the machine's speed.
test("a Home left mid-transition leaves the next page's shines to the compositor", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    externalActivityProvider: "wechat",
    extraInlineTasks: runningTasks,
    includeTaskInInbox: true,
    taskStatus: "in_progress",
  });
  try {
    await page.setViewportSize({ width: 1600, height: 960 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "idle-motion-transition@comma.local",
      token: "comma_sess_idle_motion_transition",
    });
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    await expect(
      page.getByTestId("home-tasks-rail").locator(".comma-shiny-text").first()
    ).toBeVisible();
    await waitForFiniteAnimations(page);

    // Every animation runs at a hundredth of its speed, so the send button's
    // colour transition is certainly still running when Home hides.
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Animation.setPlaybackRate", { playbackRate: 0.01 });
    await content.getByRole("textbox", { name: "AI prompt" }).click();
    await page.keyboard.type("Draft for later");
    const send = content.getByRole("button", { name: "Send message", exact: true });
    expect(
      await send.evaluate((button) =>
        button.getAnimations().some((animation) => animation.playState === "running")
      )
    ).toBe(true);
    await page.getByRole("link", { name: "Tasks", exact: true }).click();
    const tasks = page.getByRole("region", { name: "Tasks", exact: true });
    await expect(tasks).toBeVisible();
    await cdp.send("Animation.setPlaybackRate", { playbackRate: 1 });

    const shine = tasks.locator(".comma-shiny-text").first();
    await expect(shine).toBeVisible();
    const sweepEnds = () =>
      shine.evaluate(
        (line) =>
          new Promise<void>((resolve) =>
            line.addEventListener("animationiteration", () => resolve(), { once: true })
          )
      );
    await sweepEnds();
    const events: { name: string }[] = [];
    cdp.on("Tracing.dataCollected", ({ value }) => {
      events.push(...(value as { name: string }[]));
    });
    await cdp.send("Tracing.start", {
      categories: "devtools.timeline,disabled-by-default-devtools.timeline.frame",
      transferMode: "ReportEvents",
    });
    await sweepEnds();
    const complete = new Promise<void>((resolve) =>
      cdp.once("Tracing.tracingComplete", () => resolve())
    );
    await cdp.send("Tracing.end");
    await complete;
    await cdp.detach();
    const count = (name: string) =>
      events.filter((event) => event.name === name).length;
    const frames = {
      drawn: count("DrawFrame"),
      mainThread: count("BeginMainThreadFrame"),
    };
    // The sweep draws its steps on the compositor; the main thread wakes for
    // the sweep's end and the test's own calls, not for each step.
    expect(frames.drawn, JSON.stringify(frames)).toBeGreaterThan(0);
    expect(frames.mainThread * 4, JSON.stringify(frames)).toBeLessThan(frames.drawn);
  } finally {
    await stub.close();
  }
});
