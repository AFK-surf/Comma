import type { ChatMessage, ConversationChannelState } from "@comma/core/chat";
import { fixtureMount } from "./support/fixture";
import { waitForSettledMotion } from "./support/motion";
import { expect, test, type Page, useFixture } from "./support/page";
import { stepUntilSettled } from "./support/virtual-time";

// The real ConversationView and its Thread, on the test clock.
useFixture(
  fixtureMount(new URL("./fixtures/response-handoff/src/main.tsx", import.meta.url)),
  {
    // Highlighting runs in the page, not a worker each page would load.
    pageInit: () => {
      Reflect.deleteProperty(window, "Worker");
    },
    // The highlighter's languages and themes load before the tests.
    warmUp: [
      async (page) => {
        await openSurface(page);
        const code =
          "```ts\nconst a = 1\n```\n\n```js\nconst b = 2\n```\n\n```\nplain\n```";
        for (const colorScheme of ["light", "dark"] as const) {
          await page.emulateMedia({ colorScheme });
          await show(page, {
            messages: [message(`warm-${colorScheme}`, "assistant", code)],
          });
          await expect(page.locator(".shiki .line > span").first()).toBeVisible();
        }
      },
    ],
  }
);
const fixtureUrl = "http://fixture.test/";

test("channel activity preserves the normal thinking position with and without history", async ({
  page,
}) => {
  for (const history of [false, true]) {
    await openSurface(page);
    const messages = history
      ? [message("existing-question", "user", "Please check my schedule")]
      : [];
    await show(page, {
      messages,
      participantStatus: {
        conversationId: "handoff",
        participantId: "router",
        state: "active",
        status: "is thinking...",
        updatedAt: 1,
      },
    });
    const slot = page.getByTestId("participant-status-slot");
    await expect(slot).toBeInViewport({ ratio: 1 });
    if (!history) {
      const empty = page.getByTestId("chat-empty");
      await expect(empty).toBeInViewport({ ratio: 1 });
      const emptyBounds = await empty.boundingBox();
      const statusBounds = await slot.boundingBox();
      expect(statusBounds!.y).toBeGreaterThanOrEqual(
        emptyBounds!.y + emptyBounds!.height
      );
    }
    const normalPosition = await slot.boundingBox();
    for (const workingProvider of ["wechat", "telegram", "signal"] as const) {
      await show(page, {
        messages,
        participantStatus: {
          conversationId: "handoff",
          participantId: "router",
          state: "active",
          status: "is thinking...",
          updatedAt: 2,
          workingProvider,
        },
      });
      await expect(
        slot.locator(`[data-working-provider="${workingProvider}"]`)
      ).toBeInViewport({ ratio: 1 });
      const channelPosition = await slot.boundingBox();
      expect(channelPosition!.x).toBeCloseTo(normalPosition!.x, 0);
      expect(channelPosition!.y).toBeCloseTo(normalPosition!.y, 0);
      await page.waitForTimeout(800);
    }
  }
});

test("Salix slash commands insert editable text and send only on confirmation", async ({
  page,
}) => {
  await openSurface(page);
  const editor = page.getByRole("textbox");
  await editor.fill("/");
  for (const command of ["status", "compact", "help", "ls", "cat"]) {
    await expect(
      page.getByRole("option", { name: new RegExp(`^/${command}\\b`) })
    ).toBeVisible();
  }
  const statusRow = page.getByRole("option", { name: /^\/status\b/ });
  await waitForSettledMotion(page.locator(".comma-ai-input-menu"));
  const spacing = await statusRow.evaluate((row) => {
    const [label, description] = Array.from(row.children);
    const style = getComputedStyle(row);
    return {
      gap:
        description!.getBoundingClientRect().left -
        label!.getBoundingClientRect().right,
      token: Number.parseFloat(style.getPropertyValue("--spacing-xs")),
    };
  });
  expect(spacing.token).toBe(4);
  expect(spacing.gap).toBeCloseTo(spacing.token, 1);
  await editor.fill("/status");
  await expect(
    page.getByRole("option", { name: "/status", exact: false })
  ).toBeVisible();
  await editor.press("Enter");
  await expect(editor).toHaveText("<salix-command>status</salix-command>");
  expect(
    await page.evaluate(
      () => (window as unknown as { lastSentText?: string }).lastSentText
    )
  ).toBeUndefined();
  await editor.press("Enter");
  await expect
    .poll(() =>
      page.evaluate(() => (window as unknown as { lastSentText?: string }).lastSentText)
    )
    .toBe("<salix-command>status</salix-command>");
  await expect(
    page.locator('[data-message-id="sent-0"] .comma-chat-user-bubble')
  ).toHaveText("/status");

  await editor.fill("/cat");
  await page.getByRole("option", { name: "/cat", exact: false }).click();
  await expect(editor).toHaveText("<salix-command>cat /path/to/file</salix-command>");
  await expect(editor.locator("[data-ai-input-token]")).toHaveCount(0);
  await editor.fill("<salix-command>cat /notes.md</salix-command>");
  await expect(editor).toHaveText("<salix-command>cat /notes.md</salix-command>");
});

test("Salix sent commands display like skills after history reload", async ({
  page,
}) => {
  await openSurface(page);
  await show(page, {
    messages: [
      message("saved-command", "user", "<salix-command>compact</salix-command>"),
    ],
  });
  const bubble = page.locator(
    '[data-message-id="saved-command"] .comma-chat-user-bubble'
  );
  await expect(bubble).toHaveText("/compact");
});

test("Salix slash commands are not advertised in Task conversations", async ({
  page,
}) => {
  await openSurface(page);
  await show(page, {
    conversation: {
      id: "task-slash",
      group_id: "group",
      kind: "agent_task",
      title: "Task",
      status: "active",
      updated_at: 1,
    },
  });
  await page.getByRole("textbox").fill("/status");
  await expect(page.getByRole("listbox")).toBeVisible();
  await expect(page.getByRole("option", { name: "/status", exact: false })).toHaveCount(
    0
  );
});

const user = message("user-1", "user", "Please explain how the reply should appear.");
const owner = {
  conversationId: "handoff",
  participantId: "router",
  state: "active" as const,
  status: "is thinking...",
  updatedAt: 1,
};
const draft = {
  conversationId: "handoff",
  draftId: "draft-1",
  responseKey: "response-1",
  sourceMessageIds: [user.messageId],
  status: "streaming" as const,
  text: "",
};

// Opt-in hardware profiling: the normal suite has no recorder dependency.
for (const [inputLayout, inputText] of [
  ["single line", "One more question"],
  ["wrapped text", "这段文字要从输入框的原始换行开始，平滑过渡到消息气泡。".repeat(7)],
] as const) {
  test(`route: sending morphs one round bubble from the composer without a flash or a second landing (${inputLayout})`, async ({
    page,
  }, info) => {
    await openSurface(page);
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await show(page, {
      messages: [
        message("previous-reply", "assistant", "Previous context. ".repeat(160)),
      ],
    });
    const composer = page.locator(".comma-chat-composer");
    await composer.getByRole("textbox").fill(inputText);
    await composer.getByRole("button", { name: /Send/ }).click({ trial: true });
    await waitForSettledMotion(composer);
    const source = await composer.boundingBox();
    expect(source).not.toBeNull();
    const sourceAppearance = await composer.evaluate((element) => {
      const editor = element.querySelector<HTMLElement>('[role="textbox"]')!;
      const editorStyle = getComputedStyle(editor);
      const text = document.createTreeWalker(editor, NodeFilter.SHOW_TEXT).nextNode()!;
      const range = document.createRange();
      range.setStart(text, 0);
      range.setEnd(text, 1);
      const glyph = range.getBoundingClientRect();
      return {
        background: getComputedStyle(element).backgroundColor,
        color: editorStyle.color,
        textLeft: glyph.left,
        textTop: glyph.top,
        textWidth:
          editor.getBoundingClientRect().width -
          parseFloat(editorStyle.paddingLeft) -
          parseFloat(editorStyle.paddingRight),
      };
    });
    const capture = await page.evaluateHandle(() => {
      const samples: {
        time: number;
        flying: boolean;
        tailVisible: boolean;
        visible: boolean;
        left: number;
        top: number;
        width: number;
        height: number;
        scaleX: number;
        scaleY: number;
        cornerX: number;
        cornerY: number;
        progress: number;
        duration: number;
        easing: string;
        background: string;
        color: string;
        textLeft: number;
        textTop: number;
        textWidth: number;
        textOpacity: number;
        layoutCorrectionTop: number;
        plannedTargetBottom: number;
        bottom: number;
        slotHeight: number;
        turnHeight: number;
      }[] = [];
      let frame = 0;
      const captureFrame = () => {
        const bubble = document.querySelector<HTMLElement>(
          '[data-message-id="sent-1"] .comma-chat-user-bubble'
        );
        if (bubble) {
          const rect = bubble.getBoundingClientRect();
          const style = getComputedStyle(bubble);
          const matrix = new DOMMatrixReadOnly(style.transform);
          const animation = bubble.getAnimations()[0];
          const content = bubble.querySelector<HTMLElement>(
            ".comma-chat-user-bubble-content"
          )!;
          const text = document
            .createTreeWalker(content, NodeFilter.SHOW_TEXT)
            .nextNode()!;
          const range = document.createRange();
          range.setStart(text, 0);
          range.setEnd(text, 1);
          const glyph = range.getBoundingClientRect();
          // The painted outline may extend beyond the final layout box while
          // a round clip morphs the material. Measure that outline, not its canvas.
          const inset = style.clipPath.match(/^inset\((.*?) round ([\d.]+)px/);
          const edges = inset?.[1]?.split(/\s+/).map(parseFloat) ?? [0, 0, 0, 0];
          let [top = 0, right = top, bottom = top, left = right] = edges;
          let radius = inset ? Number(inset[2]) : parseFloat(style.borderTopLeftRadius);
          if (style.clipPath.startsWith("path(")) {
            const coordinates = style.clipPath
              .match(/-?\d*\.?\d+(?:e[+-]?\d+)?/gi)!
              .map(Number);
            left = coordinates[0]!;
            top = coordinates[8]!;
            right = rect.width / matrix.a - coordinates[15]!;
            bottom = rect.height / matrix.d - coordinates[24]!;
            radius = coordinates[2]!;
          }
          const previousPointerEvents = bubble.style.pointerEvents;
          bubble.style.pointerEvents = "auto";
          const tailVisible =
            document
              .elementFromPoint(
                rect.right - 10.5 * matrix.a,
                rect.bottom + 4 * matrix.d
              )
              ?.closest(".comma-chat-user-bubble") === bubble;
          bubble.style.pointerEvents = previousPointerEvents;
          samples.push({
            time: performance.now(),
            flying: bubble.dataset.outgoingPresentation === "flying",
            tailVisible,
            visible: style.visibility !== "hidden" && parseFloat(style.opacity) > 0,
            left: rect.left + left * matrix.a,
            top: rect.top + top * matrix.d,
            width: rect.width - (left + right) * matrix.a,
            height: rect.height - (top + bottom) * matrix.d,
            scaleX: matrix.a,
            scaleY: matrix.d,
            cornerX: radius * matrix.a,
            cornerY: radius * matrix.d,
            progress: Number(animation?.currentTime ?? 0),
            duration: Number(animation?.effect?.getTiming().duration ?? 0),
            easing: animation?.effect?.getTiming().easing ?? "",
            // A flight paints its material on its ::before plane, so a
            // translucent material is not painted twice.
            background:
              bubble.dataset.outgoingPresentation === "flying"
                ? getComputedStyle(bubble, "::before").backgroundColor
                : style.backgroundColor,
            color: getComputedStyle(content).color,
            textLeft: glyph.left,
            textTop: glyph.top,
            textWidth: parseFloat(getComputedStyle(content).width),
            textOpacity: parseFloat(getComputedStyle(content).opacity),
            layoutCorrectionTop: parseFloat(style.translate.split(" ")[1] ?? "0") || 0,
            plannedTargetBottom:
              parseFloat(bubble.style.top) + parseFloat(bubble.style.height),
            bottom: rect.bottom - bottom * matrix.d,
            slotHeight:
              bubble
                .closest<HTMLElement>(".comma-chat-user-bubble-slot")
                ?.getBoundingClientRect().height ?? 0,
            turnHeight:
              bubble
                .closest<HTMLElement>(".comma-chat-turn-shell")
                ?.getBoundingClientRect().height ?? 0,
          });
        }
        frame = requestAnimationFrame(captureFrame);
      };
      frame = requestAnimationFrame(captureFrame);
      return {
        hasFlown() {
          return samples.some((sample) => sample.flying && sample.visible);
        },
        finish() {
          cancelAnimationFrame(frame);
          return samples;
        },
      };
    });
    await composer.getByRole("button", { name: /Send/ }).click();
    await expect(page.locator('[data-message-id="sent-1"]')).toBeVisible();
    await expect
      .poll(() => capture.evaluate((recording) => recording.hasFlown()))
      .toBe(true);
    await expect(page.locator('[data-outgoing-presentation="flying"]')).toHaveCount(0);
    await page.waitForTimeout(400);
    const samples = await capture.evaluate((recording) => recording.finish());
    await info.attach("send-geometry", {
      body: JSON.stringify({ source, sourceAppearance, samples }),
      contentType: "application/json",
    });
    const visible = samples.filter((sample) => sample.visible);
    const first = visible[0]!;
    const last = visible.at(-1)!;
    expect(
      first.flying,
      "the first painted bubble must already belong to the flight"
    ).toBe(true);
    expect(Math.abs(first.width - source!.width)).toBeLessThan(5);
    expect(
      Math.abs(first.height - source!.height),
      "initial clip keeps the input height"
    ).toBeLessThan(1);
    expect(first.slotHeight).toBeLessThan(last.slotHeight);
    expect(first.turnHeight - 40).toBeLessThan((last.turnHeight - 40) * 0.5);
    expect(
      new Set(
        visible
          .filter((sample) => sample.flying)
          .map((sample) => Math.round(sample.turnHeight))
      ).size
    ).toBeGreaterThan(5);
    expect(Math.abs(first.left - source!.x)).toBeLessThan(5);
    expect(Math.abs(first.top - source!.y)).toBeLessThan(5);
    expect
      .soft(first.background, "first paint keeps the composer's material")
      .toBe(sourceAppearance.background);
    expect
      .soft(first.color, "first paint keeps the input text color")
      .toBe(sourceAppearance.color);
    expect.soft(Math.abs(first.textLeft - sourceAppearance.textLeft)).toBeLessThan(1);
    expect.soft(Math.abs(first.textTop - sourceAppearance.textTop)).toBeLessThan(1);
    expect
      .soft(
        Math.abs(first.textWidth - last.textWidth),
        "first paint already uses the final text layout"
      )
      .toBeLessThan(1);
    const moving = visible.filter((sample) => sample.flying && sample.duration > 0);
    expect(moving[0]!.easing, "interpolate the three sampled spring curves").toBe(
      "linear"
    );
    expect(moving[0]!.duration, "include the configured surface pulse").toBeGreaterThan(
      850
    );
    expect(moving[0]!.duration).toBeLessThan(950);
    expect
      .soft(moving.length, "the send must remain legible over more than a few frames")
      .toBeGreaterThan(22);
    const travelProgress = (sample: (typeof moving)[number]) =>
      (source!.y + source!.height - (sample.bottom - sample.layoutCorrectionTop)) /
      (source!.y + source!.height - sample.plannedTargetBottom);
    const midFlight = moving.filter((sample) => {
      const progress = travelProgress(sample);
      return progress > 0.1 && progress < 0.9;
    });
    expect(
      midFlight.at(-1)!.time - midFlight[0]!.time,
      "most of the travel must not be compressed into a few frames"
    ).toBeGreaterThan(140);
    for (const sample of midFlight) {
      expect(
        sample.tailVisible,
        "the tail remains inside the painted flight outline"
      ).toBe(true);
      expect(sample.background, "the moving bubble keeps a visible material").not.toBe(
        "rgba(0, 0, 0, 0)"
      );
    }
    const widthLeads: number[] = [];
    for (const sample of moving) {
      expect(
        Math.abs(sample.cornerX - sample.cornerY),
        "corners must stay circular"
      ).toBeLessThan(0.5);
      const widthProgress =
        (source!.width - sample.width / sample.scaleX) / (source!.width - last.width);
      // Clearing a wrapped input also shrinks the composer and moves the
      // viewport. Compare the shared base motion here; the landing checks
      // below include that live layout correction.
      const positionProgress = travelProgress(sample);
      widthLeads.push(widthProgress - positionProgress);
      const positionRebound =
        (positionProgress - 1) *
        Math.abs(source!.y + source!.height - sample.plannedTargetBottom);
      expect(
        positionRebound,
        "position rebound stays below eight pixels"
      ).toBeLessThanOrEqual(8.3);
      expect(
        widthProgress - positionProgress,
        "width leads the travel only slightly"
      ).toBeLessThan(0.45);
    }
    expect(
      Math.max(...widthLeads),
      "width contracts ahead of position"
    ).toBeGreaterThan(0.1);
    const narrowest = moving.reduce((a, b) => (a.width < b.width ? a : b));
    const rebound = last.width - narrowest.width;
    expect(rebound, "width visibly rebounds into its final size").toBeGreaterThan(0.5);
    expect(
      rebound,
      "compression stays within the configured thirty percent"
    ).toBeLessThanOrEqual(0.5 + last.width * 0.3);
    const targetWidth = last.textWidth;
    for (const sample of moving) {
      expect(
        Math.abs(sample.textWidth - targetWidth),
        "one final text layout throughout the flight"
      ).toBeLessThan(0.5);
      expect(
        Math.abs(sample.scaleX - sample.scaleY),
        "text and bubble scale uniformly"
      ).toBeLessThan(0.001);
    }
    expect(Math.min(...moving.map((sample) => sample.scaleX))).toBeLessThan(0.72);
    expect(Math.max(...moving.map((sample) => sample.scaleX))).toBeLessThan(1.01);
    expect(
      moving.every((sample) => sample.textOpacity === 1),
      "text never fades out"
    ).toBe(true);
    const afterRebound = moving.filter((sample) => sample.time >= narrowest.time);
    expect(
      Math.max(...afterRebound.map((sample) => sample.textWidth)) -
        Math.min(...afterRebound.map((sample) => sample.textWidth)),
      "the rebound must not rewrap text"
    ).toBeLessThan(1);
    const landing = moving.at(-1)!;
    expect(
      Math.abs(landing.top - last.top),
      "no position jump at handoff"
    ).toBeLessThan(1);
    for (const sample of visible.filter((candidate) => !candidate.flying)) {
      expect(
        Math.abs(sample.top - last.top),
        "no second push after landing"
      ).toBeLessThan(1);
    }
  });
}

test("route: visible time separators restart consecutive bubble tail groups", async ({
  page,
}) => {
  await openSurface(page);
  await page.setViewportSize({ width: 800, height: 1200 });
  const startedAt = Date.UTC(2026, 8, 29, 7, 58);
  const messages = [
    ...(
      [
        ["tail-user-one", "First question", 0],
        ["tail-user-two", "One more detail", 59_999],
        ["tail-user-three", "One minute later", 60_000],
        ["tail-user-four", "Several minutes later", 360_000],
      ] as const
    ).map(([id, text, offset]) => ({
      ...message(id, "user", text),
      createdAt: startedAt + offset,
      platformSource: "wechat" as const,
    })),
    message("tail-router-one", "assistant", "First reply"),
    message(
      "tail-router-two",
      "assistant",
      "Last reply.\n\n```ts\nconst ready = true;\n```"
    ),
  ];
  await show(page, { messages });
  await expect(page.getByTestId(/^chat-conversation-time-/)).toHaveCount(3);
  const userTails = ["tail-user-two", "tail-user-three", "tail-user-four"].map((id) => [
    id,
    "right",
  ]);
  const tails = () =>
    page
      .locator("article[data-bubble-tail]")
      .evaluateAll((rows) =>
        rows.map((row) => [
          row.getAttribute("data-message-id"),
          row.getAttribute("data-bubble-tail"),
        ])
      );
  await expect.poll(tails).toEqual([...userTails, ["tail-router-two", "left"]]);
  // A message from another platform names its source.
  await expect(
    page.locator('[data-message-id="tail-user-four"] [data-platform="wechat"]')
  ).toHaveCount(1);
  const replyBubbles = page.locator(
    '[data-message-id="tail-router-two"] .markdown-stream-bubble'
  );
  const lastBubble = replyBubbles.last();
  await expect
    .poll(() =>
      lastBubble.evaluate((node) => getComputedStyle(node, "::before").content)
    )
    .toBe('""');
  // Only the reply's last bubble carries the tail.
  await expect(replyBubbles).toHaveCount(2);
  expect(
    await replyBubbles
      .first()
      .evaluate((node) => getComputedStyle(node, "::before").content)
  ).toBe("none");
  const userBubbleLocator = page.locator(
    `[data-message-id="${userTails[0]![0]}"] .comma-chat-user-bubble`
  );
  // WeChat's light bubble needs its dark ink on every surface.
  await expect(userBubbleLocator).toHaveCSS("color", "rgb(8, 45, 7)");
  const userBubble = await userBubbleLocator.boundingBox();
  expect(userBubble).not.toBeNull();
  // Platform bubbles carry their own colour, so match the tail against it.
  const tailColor = await userBubbleLocator.evaluate((element) => {
    const background = getComputedStyle(element).backgroundColor;
    const painted =
      background === "rgba(0, 0, 0, 0)"
        ? getComputedStyle(element, "::before").backgroundColor
        : background;
    return painted.match(/\d+/g)!.slice(0, 3).map(Number);
  });
  // Verify painted pixels below the body, where a clipped tail disappears.
  const tailImage = await page.screenshot({
    clip: {
      x: userBubble!.x + userBubble!.width - 24,
      y: userBubble!.y + userBubble!.height,
      width: 24,
      height: 7,
    },
  });
  const paintedTailPixels = await page.evaluate(
    async ([dataURL, color]) => {
      const image = new Image();
      image.src = dataURL;
      await image.decode();
      const canvas = document.createElement("canvas");
      canvas.width = image.width;
      canvas.height = image.height;
      const context = canvas.getContext("2d")!;
      context.drawImage(image, 0, 0);
      const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
      let tailPixels = 0;
      for (let i = 0; i < pixels.length; i += 4) {
        if (color.every((channel, c) => Math.abs(pixels[i + c]! - channel) <= 24))
          tailPixels++;
      }
      return tailPixels;
    },
    [`data:image/png;base64,${tailImage.toString()}`, tailColor] as const
  );
  expect(paintedTailPixels).toBeGreaterThan(10);
  await show(page, {
    messages: [
      ...messages,
      message("tail-router-three", "assistant", "Final addition"),
    ],
  });
  await expect.poll(tails).toEqual([...userTails, ["tail-router-three", "left"]]);
});

test("route: router replies omit identity and connect above the first bubble", async ({
  page,
}) => {
  await openSurface(page);
  const root = message("compact-root", "user", "Explain the layout.");
  const reply = {
    ...message("compact-reply", "assistant", "First block.\n\nSecond block."),
    actorRole: "router" as const,
    replyToMessageId: root.messageId,
    threadRootMessageId: root.messageId,
  };
  const continuation = {
    ...reply,
    messageId: "compact-continuation",
    text: "More detail.",
  };
  await show(page, { messages: [root, reply, continuation] });
  const row = page.locator('article[data-message-id="compact-reply"]');
  await expect(row).toContainText("First block.");
  await expect(page.locator(".comma-chat-assistant-source-label")).toHaveCount(0);
  await expect(
    page.locator("article > .comma-chat-assistant-source-avatar")
  ).toHaveCount(0);
  for (const width of [800, 600]) {
    await page.setViewportSize({ width, height: 720 });
    await expect
      .poll(() =>
        page.locator('path[data-reply-source="compact-reply"]').evaluate((node) => {
          const path = node as unknown as SVGPathElement;
          const origin = path.ownerSVGElement!.getBoundingClientRect();
          const end = path.getPointAtLength(path.getTotalLength());
          const bubble = document
            .querySelector('[data-message-id="compact-reply"] .markdown-stream-bubble')!
            .getBoundingClientRect();
          return Math.max(
            Math.abs(origin.x + end.x - bubble.left - 13),
            Math.abs(origin.y + end.y - bubble.top + 8)
          );
        })
      )
      .toBeLessThan(1);
  }
  await show(page, {
    messages: [root, reply, continuation],
    conversation: {
      id: "handoff",
      group_id: "group",
      kind: "agent_task",
      title: "Task discussion",
      status: "completed",
    },
  });
  await expect(row.locator(".comma-chat-assistant-source-label")).toHaveText("Router");
  await expect(page.locator("article > .comma-chat-assistant-router-mark")).toHaveCount(
    1
  );
});

test("route: consecutive replies retain completed DOM and opacity", async ({
  page,
}, info) => {
  await openSurface(page);
  const first = message(
    "assistant-1",
    "assistant",
    "This first reply stays fully readable while the next answer streams."
  );
  await show(page, {
    messages: [user],
    assistantDraft: { ...draft, text: first.text },
  });
  const firstRow = page.getByTestId("chat-assistant-draft");
  const firstNode = await firstRow.elementHandle();
  await page.waitForTimeout(450);
  await show(page, { messages: [user, first] });
  expect(
    await page
      .locator('[data-message-id="assistant-1"]')
      .evaluate((node, before) => node === before, firstNode)
  ).toBe(true);
  const secondUser = message("user-2", "user", "Continue with a second response.");
  const messages = [user, first, secondUser];
  await show(page, { messages, awaitingReply: true, locallyAwaitingReply: true });
  // Let the normal new-turn anchor settle, then read both replies together.
  // New streaming must respect this deliberate scroll back to the first row.
  await page.waitForTimeout(300);
  const viewport = page.locator('[data-slot="scroll-area-viewport"]').first();
  await viewport.hover();
  await page.mouse.wheel(0, -600);
  await page.waitForTimeout(300);
  await expect(page.locator('[data-message-id="assistant-1"]')).toBeInViewport();
  const observer = await observeBody(page.locator('[data-message-id="assistant-1"]'));
  const secondDraft = {
    ...draft,
    draftId: "draft-2",
    responseKey: "response-2",
    sourceMessageIds: [secondUser.messageId],
    text: "Second",
  };
  for (const text of [
    "Second",
    "Second reply",
    "Second reply grows without repainting the earlier answer.",
  ]) {
    await show(page, { messages, assistantDraft: { ...secondDraft, text } });
    await page.waitForTimeout(150);
  }
  const secondNode = await page.getByTestId("chat-assistant-draft").elementHandle();
  const second = message(
    "assistant-2",
    "assistant",
    "Second reply grows without repainting the earlier answer."
  );
  await show(page, { messages: [...messages, second] });
  expect(
    await page
      .locator('[data-message-id="assistant-2"]')
      .evaluate((node, before) => node === before, secondNode)
  ).toBe(true);
  await page.waitForTimeout(250);
  const observed = await observer.evaluate((p) => p.stop());
  expect(observed).toMatchObject({
    maxMovement: 0,
    hidden: 0,
    remounted: 0,
    transforms: [],
    minOpacity: 1,
  });
  expect(
    await page
      .locator('[data-message-id="assistant-1"]')
      .evaluate((node, before) => node === before, firstNode)
  ).toBe(true);
  await info.attach("completed-row-across-second-turn", {
    body: JSON.stringify(observed),
    contentType: "application/json",
  });
  await observer.dispose();
});

test("route: a collapsed tailed user bubble keeps its rounded bottom corners", async ({
  page,
}) => {
  await openSurface(page);
  const text = Array.from({ length: 40 }, (_, index) => `Line ${index}`).join("\n\n");
  await show(page, {
    messages: [
      message("collapsed-user", "user", text),
      message("collapsed-assistant", "assistant", "Done."),
    ],
  });
  const row = page.locator('[data-message-id="collapsed-user"]');
  await expect(row).toHaveAttribute("data-bubble-tail", "right");
  const bubble = row.locator(".comma-chat-user-bubble");
  await expect(bubble).toHaveAttribute("data-overflowing", "true");
  const box = (await bubble.boundingBox())!;
  const color = await bubble.evaluate((node) =>
    getComputedStyle(node, "::before")
      .backgroundColor.match(/\d+/g)!
      .slice(0, 3)
      .map(Number)
  );
  // The 20px radius leaves each 4px corner square outside the bubble. The
  // fade paints solid bubble colour there when it does not follow the radius.
  for (const x of [box.x, box.x + box.width - 4]) {
    const corner = await page.screenshot({
      clip: { x, y: box.y + box.height - 4, width: 4, height: 4 },
    });
    const painted = await page.evaluate(
      async ([dataURL, bubbleColor]) => {
        const image = new Image();
        image.src = dataURL;
        await image.decode();
        const canvas = document.createElement("canvas");
        canvas.width = image.width;
        canvas.height = image.height;
        const context = canvas.getContext("2d")!;
        context.drawImage(image, 0, 0);
        const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
        let count = 0;
        for (let i = 0; i < pixels.length; i += 4) {
          if (
            bubbleColor.every((channel, c) => Math.abs(pixels[i + c]! - channel) <= 24)
          )
            count++;
        }
        return count;
      },
      [`data:image/png;base64,${corner.toString()}`, color] as const
    );
    expect(painted).toBe(0);
  }
});

test("route: short messages keep a minimum bubble width and centered text", async ({
  page,
}) => {
  await openSurface(page);
  await show(page, {
    messages: [
      message("short-user", "user", "1"),
      message("short-assistant", "assistant", "1"),
    ],
  });
  for (const id of ["short-user", "short-assistant"]) {
    const bubble = page
      .locator(`[data-message-id="${id}"]`)
      .locator(".comma-chat-user-bubble, .markdown-stream-bubble");
    await expect(bubble).toBeVisible();
    const geometry = await bubble.evaluate((node) => {
      const box = node.getBoundingClientRect();
      const text = document.createTreeWalker(node, NodeFilter.SHOW_TEXT).nextNode()!;
      const range = document.createRange();
      range.selectNodeContents(text);
      const glyph = range.getBoundingClientRect();
      return {
        width: box.width,
        height: box.height,
        centerOffset: Math.abs((glyph.left + glyph.right - box.left - box.right) / 2),
      };
    });
    expect(geometry.width).toBeCloseTo(50, 0);
    expect(geometry.height).toBeCloseTo(40, 0);
    expect(geometry.centerOffset).toBeLessThan(1);
  }
});

for (const historySize of [0, 40]) {
  test(`route: sending while participants think preserves the existing bottom reserve (${historySize} history pairs)`, async ({
    page,
  }) => {
    await openSurface(page);
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await show(page, {
      messages: [
        ...Array.from({ length: historySize }, (_, index) => [
          message(`older-user-${index}`, "user", `Earlier question ${index}`),
          message(
            `older-reply-${index}`,
            "assistant",
            `Earlier answer ${index}. `.repeat(8)
          ),
        ]).flat(),
        message("context", "assistant", "Previous context. ".repeat(100)),
        user,
      ],
      participantStatuses: [
        owner,
        { ...owner, participantId: "worker", actorRole: "worker", name: "Worker" },
      ],
    });
    const composer = page.locator(".comma-chat-composer");
    for (let attempt = 0; attempt < 2; attempt++) {
      await composer.getByRole("textbox").fill("A message while thinking.");
      const probe = await page.evaluateHandle(() => {
        const samples: {
          minimum: number;
          padding: number;
          tailHeight: number;
          previousY: number;
          columnAnimations: number;
          destinationY: number | undefined;
        }[] = [];
        let frame = 0;
        const sample = () => {
          const turn = document.querySelector<HTMLElement>(
            '.comma-chat-turn-shell[data-chat-latest-turn="true"]'
          );
          if (turn) {
            const style = getComputedStyle(turn);
            samples.push({
              destinationY: Number.parseFloat(
                turn.querySelector<HTMLElement>('[data-outgoing-presentation="flying"]')
                  ?.style.top ?? "NaN"
              ),
              minimum: parseFloat(style.minHeight),
              padding: parseFloat(style.paddingBottom),
              tailHeight:
                turn.closest(".comma-chat-column")!.getBoundingClientRect().bottom -
                document
                  .querySelector('article[data-message-id="user-1"]')!
                  .getBoundingClientRect().top,
              previousY: document
                .querySelector('article[data-message-id="user-1"]')!
                .getBoundingClientRect().top,
              columnAnimations: turn.closest(".comma-chat-column")!.getAnimations()
                .length,
            });
          }
          frame = requestAnimationFrame(sample);
        };
        sample();
        return {
          async finish() {
            await new Promise((resolve) => setTimeout(resolve, 1200));
            cancelAnimationFrame(frame);
            return samples;
          },
        };
      });
      await composer.getByRole("button", { name: /Send/ }).click();
      const samples = await stepUntilSettled(
        probe.evaluate((capture) => capture.finish())
      );
      expect(samples.length).toBeGreaterThan(5);
      const destinations = samples.flatMap((sample) =>
        !Number.isFinite(sample.destinationY) ? [] : [sample.destinationY!]
      );
      expect(destinations.length).toBeGreaterThan(5);
      const landed = await page
        .locator(
          '.comma-chat-turn-shell[data-chat-latest-turn="true"] .comma-chat-user-bubble-slot'
        )
        .last()
        .boundingBox();
      expect(
        Math.abs(destinations.at(-1)! - landed!.y),
        "the fixed flight endpoint matches the final layout without a second push"
      ).toBeLessThan(1);
      expect(
        Math.max(...destinations) - Math.min(...destinations),
        "the landing position stays fixed throughout the flight"
      ).toBeLessThan(1);
      expect(samples.every((sample) => sample.columnAnimations === 0)).toBe(true);
      expect(
        Math.max(
          ...samples.map((sample) => Math.abs(sample.previousY - samples[0]!.previousY))
        )
      ).toBeLessThan(250);
      expect(
        Math.min(...samples.map((sample) => sample.tailHeight))
      ).toBeGreaterThanOrEqual(samples[0]!.tailHeight - 1);
      expect(
        new Set(
          samples
            .filter((sample) => sample.minimum > 0 && sample.minimum < 200)
            .map((sample) => Math.round(sample.minimum))
        ).size
      ).toBeGreaterThan(3);
      await expect(page.getByTestId("participant-status-slot")).toHaveAttribute(
        "data-active",
        "true"
      );
    }
  });
}

test("route: hovering a reply preview fades other chains and follows ancestors and branches", async ({
  page,
}) => {
  await openSurface(page);
  await show(page, { messages: replyHighlightMessages() });
  const row = (id: string) => page.locator(`article[data-message-id="${id}"]`);
  const preview = page.locator('[data-reply-preview-target="chain-A"]');
  await expect(preview).toBeInViewport();
  const fade = await observeReplyChain(page, "chain-C", "chain-B");
  await preview.hover();
  for (const id of ["chain-A", "chain-C", "chain-E", "chain-F"])
    await expect(row(id)).toHaveCSS("opacity", "1");
  for (const id of ["chain-B", "chain-D", "chain-independent"])
    await expect(row(id)).toHaveCSS("opacity", "0.25");
  await expect(page.locator('path[data-reply-source="chain-D"]')).toHaveCSS(
    "opacity",
    "0.25"
  );
  await expect(page.locator('path[data-reply-source="chain-E"]')).toHaveCSS(
    "opacity",
    "1"
  );
  const entering = await stepUntilSettled(
    fade.evaluate((capture) => capture.finish(200))
  );
  expect(
    entering.samples.some((sample) => sample.opacity > 0.25 && sample.opacity < 1)
  ).toBe(true);

  // A different preview swaps the entire chain without changing layout.
  await page.locator('[data-reply-preview-target="chain-B"]').hover();
  await expect(row("chain-B")).toHaveCSS("opacity", "1");
  await expect(row("chain-A")).toHaveCSS("opacity", "0.25");
  const leaving = await observeReplyChain(page, "chain-B", "chain-A");
  await page.mouse.move(1, 1);
  await expect(row("chain-A")).toHaveCSS("opacity", "1");
  const exiting = await stepUntilSettled(
    leaving.evaluate((capture) => capture.finish(200))
  );
  expect(
    exiting.samples.some((sample) => sample.opacity > 0.25 && sample.opacity < 1)
  ).toBe(true);
  await expect(page.locator("[data-reply-chain-state]")).toHaveCount(0);

  // A touch contact must not leave a synthetic hover highlight behind.
  await preview.dispatchEvent("pointerover", { pointerType: "touch" });
  await expect(page.locator("[data-reply-chain-state]")).toHaveCount(0);
});

for (const offscreen of [false, true]) {
  test(`route: clicked reply chain stays highlighted until arrival plus 200 ms (${offscreen ? "smooth offscreen" : "visible reduced motion"})`, async ({
    page,
  }) => {
    await page.emulateMedia({
      reducedMotion: offscreen ? "no-preference" : "reduce",
    });
    await openSurface(page);
    await show(page, { messages: replyNavigationMessages(offscreen) });
    const target = page.locator('article[data-message-id="navigation-B"]');
    const preview = page.locator('[data-reply-preview-target="navigation-B"]');
    if (offscreen) {
      // The thread has rendered the messages before the key reaches it.
      await expect(
        page.locator('article[data-message-id="navigation-D"]')
      ).toBeAttached();
      await page.getByRole("log").press("End");
      await expect(target).not.toBeInViewport();
    } else {
      await expect(target).toBeInViewport({ ratio: 1 });
    }
    await expect(preview).toBeInViewport();
    const observation = await observeReplyChain(page, "navigation-B", "navigation-A");
    await preview.click();
    await expect(target).toBeFocused();
    const result = await stepUntilSettled(
      observation.evaluate((capture) => capture.finish(1400))
    );
    const arrival = offscreen ? result.arrivedAt : result.clickedAt;
    expect(arrival).toBeGreaterThan(0);
    const held = result.samples.filter(
      (sample) => sample.time >= arrival && sample.time < arrival + 190
    );
    expect(held.length).toBeGreaterThan(0);
    expect(held.every((sample) => sample.active)).toBe(true);
    const released = result.samples.find(
      (sample) => sample.time > arrival && !sample.active
    );
    expect(released).toBeDefined();
    expect(released!.time - arrival).toBeGreaterThanOrEqual(195);
    expect(released!.time - arrival).toBeLessThan(350);
    if (offscreen) {
      expect(
        result.samples.some(
          (sample) =>
            sample.time > released!.time && sample.opacity > 0.25 && sample.opacity < 1
        )
      ).toBe(true);
    }
    await expect(page.locator("[data-reply-chain-state]")).toHaveCount(0);
    await expect(page.locator("[data-reveal-highlight]")).toHaveCount(0);
  });
}

test("route: a visible reply target aligns to the top inset without flashing or trimming history", async ({
  page,
}) => {
  await openSurface(page);
  await show(page, { messages: replyNavigationMessages(false) });
  await page.evaluate(() => document.fonts.ready.then(() => undefined));
  const target = page.locator('article[data-message-id="navigation-B"]');
  const preview = page.locator('[data-reply-preview-target="navigation-B"]');
  await expect(preview).toBeInViewport();
  await expect(target).toBeInViewport({ ratio: 1 });
  const observation = await observeReplyNavigation(page, "navigation-B");
  await preview.click();
  await expect(target).toBeFocused();
  const samples = await stepUntilSettled(
    observation.evaluate((capture) => capture.finish())
  );
  const remainingScroll = await page
    .getByRole("log")
    .evaluate((node) => node.scrollHeight - node.clientHeight - node.scrollTop);
  expect(
    Math.min(Math.abs(samples.at(-1)!.topInsetOffset), Math.abs(remainingScroll))
  ).toBeLessThan(2);
  expect(new Set(samples.map((sample) => sample.firstMessage)).size).toBe(1);
  expect(samples.every((sample) => !sample.highlighted)).toBe(true);
  await expect(target).toHaveCSS("outline-style", "none");
});

test("route: an offscreen reply target scrolls smoothly to the reading area and stays there", async ({
  page,
}) => {
  await openSurface(page);
  await show(page, { messages: replyNavigationMessages(true) });
  const target = page.locator('article[data-message-id="navigation-B"]');
  const preview = page.locator('[data-reply-preview-target="navigation-B"]');
  const viewport = page.getByRole("log");
  await viewport.hover();
  await page.mouse.wheel(0, 10000);
  await expect(preview).toBeInViewport();
  await expect(target).not.toBeInViewport();
  const observation = await observeReplyNavigation(page, "navigation-B");
  await preview.click();
  await expect(target).toBeFocused();
  const samples = await stepUntilSettled(
    observation.evaluate((capture) => capture.finish())
  );
  const first = samples[0]!;
  const last = samples.at(-1)!;
  expect(Math.abs(last.topInsetOffset)).toBeLessThan(2);
  expect(new Set(samples.map((sample) => sample.firstMessage)).size).toBe(1);
  const intermediates = samples.filter(
    (sample) => sample.y > first.y + 2 && sample.y < last.y - 2
  );
  expect(new Set(intermediates.map((sample) => sample.y)).size).toBeGreaterThan(2);
  expect(samples.slice(-8).every((sample) => Math.abs(sample.y - last.y) < 1)).toBe(
    true
  );
  await expect(target).toBeInViewport({ ratio: 1 });
});

test("route: reply navigation respects reduced motion and holds position when a reply arrives", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await openSurface(page);
  const messages = replyNavigationMessages(true);
  await show(page, { messages });
  const target = page.locator('article[data-message-id="navigation-B"]');
  const preview = page.locator('[data-reply-preview-target="navigation-B"]');
  // The thread has rendered the messages before the key reaches it.
  await expect(page.locator('article[data-message-id="navigation-D"]')).toBeAttached();
  await page.getByRole("log").press("End");
  await expect(preview).toBeInViewport();
  const observation = await observeReplyNavigation(page, "navigation-B");
  await preview.click();
  const samples = await stepUntilSettled(
    observation.evaluate((capture) => capture.finish())
  );
  const last = samples.at(-1)!;
  expect(Math.abs(last.topInsetOffset)).toBeLessThan(2);
  expect(
    new Set(samples.map((sample) => Math.round(sample.y))).size
  ).toBeLessThanOrEqual(2);
  const settled = await observeReplyNavigation(page, "navigation-B");
  await show(page, {
    messages: [
      ...messages,
      message("navigation-new-reply", "assistant", "New update. ".repeat(80)),
    ],
  });
  await expect(page.locator('[data-message-id="navigation-new-reply"]')).toHaveCount(1);
  const afterReply = await stepUntilSettled(
    settled.evaluate((capture) => capture.finish())
  );
  expect(afterReply.every((sample) => Math.abs(sample.y - last.y) < 1)).toBe(true);
  await expect(target).toBeFocused();
});

for (const reducedMotion of [false, true]) {
  test(`route: a reply near the mounted history boundary gains enough context for its top inset (${reducedMotion ? "reduced" : "smooth"})`, async ({
    page,
  }) => {
    await page.emulateMedia({
      reducedMotion: reducedMotion ? "reduce" : "no-preference",
    });
    await openSurface(page);
    const messages = Array.from({ length: 20 }, (_, index) => [
      message(`boundary-user-${index}`, "user", `Question ${index}`),
      message(
        `boundary-reply-${index}`,
        "assistant",
        index >= 16 ? "Later context. ".repeat(150) : "A short answer."
      ),
    ]).flat();
    messages.push(
      {
        ...message("boundary-line", "assistant", "Reply to the first message."),
        replyToMessageId: "boundary-user-14",
        threadRootMessageId: "boundary-user-14",
      },
      {
        ...message("boundary-preview", "assistant", "Reply to the second message."),
        replyToMessageId: "boundary-user-15",
        threadRootMessageId: "boundary-user-15",
      }
    );
    await show(page, { messages });
    // The thread has rendered the messages before the key reaches it.
    await expect(
      page.locator(`article[data-message-id="${messages.at(-1)!.messageId}"]`)
    ).toBeAttached();
    await page.getByRole("log").press("End");
    const target = page.locator('article[data-message-id="boundary-user-15"]');
    await expect(target).toHaveCount(1);
    await expect(target).not.toBeInViewport();
    const observation = await observeReplyNavigation(page, "boundary-user-15");
    await page.locator('[data-reply-preview-target="boundary-user-15"]').click();
    const samples = await stepUntilSettled(
      observation.evaluate((capture) => capture.finish())
    );
    expect(Math.abs(samples.at(-1)!.topInsetOffset)).toBeLessThan(2);
    await expect(target).toBeFocused();
  });
}

test("route: a wheel gesture interrupts reply navigation and another click can resume", async ({
  page,
}) => {
  await openSurface(page);
  await show(page, { messages: replyNavigationMessages(true) });
  const preview = page.locator('[data-reply-preview-target="navigation-B"]');
  const viewport = page.getByRole("log");
  await viewport.hover();
  await page.mouse.wheel(0, 10000);
  await expect(preview).toBeInViewport();
  const startTop = await viewport.evaluate((node) => node.scrollTop);
  await preview.click();
  await expect
    .poll(() => viewport.evaluate((node) => node.scrollTop))
    .toBeLessThan(startTop - 3);
  await page.mouse.wheel(0, 120);
  const observation = await observeReplyNavigation(page, "navigation-B");
  const samples = await stepUntilSettled(
    observation.evaluate((capture) => capture.finish())
  );
  const last = samples.at(-1)!;
  expect(Math.abs(last.topInsetOffset)).toBeGreaterThan(40);
  // The browser scrolls this wheel itself, so the tick can carry the tail,
  // and the clicked preview, back under the resting pointer, where hovering
  // lights the chain again. Rest the pointer off the transcript: only the
  // cancelled reveal can clear the highlight the click started.
  await page.locator(".comma-chat-composer").getByRole("textbox").hover();
  await expect(page.locator("[data-reply-chain-state]")).toHaveCount(0);
  expect(samples.slice(-8).every((sample) => Math.abs(sample.y - last.y) < 1)).toBe(
    true
  );
  await preview.click();
  const resumed = await observeReplyNavigation(page, "navigation-B");
  const arrival = await stepUntilSettled(
    resumed.evaluate((capture) => capture.finish())
  );
  expect(Math.abs(arrival.at(-1)!.topInsetOffset)).toBeLessThan(2);
});

test("route: a tall reply target lands at its beginning without focus bouncing", async ({
  page,
}) => {
  await openSurface(page);
  const messages = replyNavigationMessages(false).slice(0, -3);
  messages.push(
    message("navigation-B", "assistant", "Long source message. ".repeat(300)),
    {
      ...message("navigation-C", "assistant", "Reply to the user."),
      replyToMessageId: "navigation-A",
      threadRootMessageId: "navigation-A",
    },
    {
      ...message("navigation-D", "assistant", "Reply to the long message."),
      replyToMessageId: "navigation-B",
      threadRootMessageId: "navigation-B",
    }
  );
  await show(page, { messages });
  const target = page.locator('article[data-message-id="navigation-B"]');
  const preview = page.locator('[data-reply-preview-target="navigation-B"]');
  await page.getByRole("log").hover();
  await page.mouse.wheel(0, 10000);
  await expect(preview).toBeInViewport();
  await preview.click();
  const observation = await observeReplyNavigation(page, "navigation-B");
  const samples = await stepUntilSettled(
    observation.evaluate((capture) => capture.finish())
  );
  const last = samples.at(-1)!;
  expect(samples.slice(-8).every((sample) => Math.abs(sample.y - last.y) < 1)).toBe(
    true
  );
  await expect(target).toBeFocused();
  const inset = await target.evaluate(
    (node) =>
      node.querySelector(".comma-chat-assistant-response-body")!.getBoundingClientRect()
        .top - node.closest('[role="log"]')!.getBoundingClientRect().top
  );
  expect(inset).toBeGreaterThanOrEqual(23);
  expect(inset).toBeLessThanOrEqual(25);
});

test("route: restored thread lines are complete without an entrance after reload", async ({
  page,
}) => {
  const root = message("restored-root", "user", "Earlier question");
  const reply = {
    ...message("restored-reply", "assistant", "Earlier answer"),
    replyToMessageId: root.messageId,
    threadRootMessageId: root.messageId,
  };
  await openSurface(page);
  for (let pass = 0; pass < 2; pass++) {
    if (pass) await page.reload();
    await show(page, { messages: [root, reply] });
    const line = page.locator('path[data-reply-source="restored-reply"]');
    await expect(line).toHaveCSS("animation-name", "none");
    await expect(line).toHaveCSS("stroke-dashoffset", "0px");
    await expect(line).not.toHaveAttribute("data-reply-draw-enter", "true");
  }
});

test("route: thread lines draw downward once, loop on long spans, and respect reduced motion", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await openSurface(page);
  const root = message("draw-root", "user", "Explain the design.");
  const reply: ChatMessage = {
    ...message("draw-reply", "assistant", "A short reply."),
    createdAt: Date.now(),
    replyToMessageId: root.messageId,
    threadRootMessageId: root.messageId,
  };
  const column = page.locator(".comma-chat-column");
  await column.evaluate((node) => {
    (node as HTMLElement).style.transform = "translateX(-200vw)";
  });
  await show(page, {
    messages: [
      root,
      message("long-question-one", "user", "More context."),
      message("long-question-two", "user", "Another detail."),
      reply,
    ],
  });
  const line = page.locator('path[data-reply-source="draw-reply"]');
  await expect(line).toHaveAttribute("pathLength", "1");
  // Let a full entrance duration elapse while outside the viewport.
  await page.waitForTimeout(700);
  await expect(line).not.toHaveAttribute("data-reply-draw-visible", "true");
  await expect(line).toHaveCSS("stroke-dashoffset", "1px");
  await column.evaluate((node) => {
    (node as HTMLElement).style.removeProperty("transform");
  });
  await expect(line).toHaveAttribute("data-reply-draw-visible", "true");
  const liveOffsets = await stepUntilSettled(
    line.evaluate(async (node) => {
      const offsets: number[] = [];
      const started = performance.now();
      while (performance.now() - started < 650) {
        offsets.push(Number.parseFloat(getComputedStyle(node).strokeDashoffset));
        await new Promise(requestAnimationFrame);
      }
      return offsets;
    })
  );
  expect(
    liveOffsets.filter((offset) => offset > 0 && offset < 1).length
  ).toBeGreaterThan(3);
  expect(liveOffsets.at(-1)).toBe(0);
  const reveal = await line.evaluate((node) => {
    const path = node as unknown as SVGPathElement;
    const animation = path.getAnimations()[0]!;
    animation.pause();
    const offsets = [0, 300, 600].map((time) => {
      animation.currentTime = time;
      return Number.parseFloat(getComputedStyle(path).strokeDashoffset);
    });
    const length = path.getTotalLength();
    return {
      offsets,
      start: path.getPointAtLength(0).y,
      end: path.getPointAtLength(length).y,
      d: path.getAttribute("d"),
    };
  });
  expect(reveal.start).toBeLessThan(reveal.end);
  expect(reveal.offsets[0]).toBe(1);
  expect(reveal.offsets[1]).toBeGreaterThan(0);
  expect(reveal.offsets[1]).toBeLessThan(1);
  expect(reveal.offsets[2]).toBe(0);
  expect(reveal.d).not.toContain(" C ");

  // Intervening messages lengthen the connector without restarting its reveal.
  await show(page, {
    messages: [
      root,
      message("long-question-one", "user", "More context.\n".repeat(100)),
      message("long-question-two", "user", "Another detail.\n".repeat(100)),
      reply,
    ],
  });
  await expect(line).toHaveAttribute("d", / C /);
  expect(await line.evaluate((node) => node.getAnimations()[0]?.currentTime)).toBe(600);
  const bounds = await line.evaluate((node) => {
    const path = node as unknown as SVGPathElement;
    const start = path.getPointAtLength(0);
    const end = path.getPointAtLength(path.getTotalLength());
    return { startY: start.y, endY: end.y, width: path.getBBox().width };
  });
  expect(bounds.endY - bounds.startY).toBeGreaterThan(800);
  expect(bounds.width).toBeLessThanOrEqual(24);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await expect(line).toHaveCSS("animation-name", "none");
  await expect(line).toHaveCSS("stroke-dashoffset", "0px");
});

test("route: sibling and nested replies share one thread spine and sender group", async ({
  page,
}) => {
  await openSurface(page);
  const root = message("thread-A", "user", "Review the design together.");
  const reply = (id: string, parent: string, actor: string): ChatMessage => ({
    ...message(id, "assistant", `${id}: design feedback.`),
    actorId: actor,
    actorRole: "worker",
    replyToMessageId: parent,
    threadRootMessageId: root.messageId,
  });
  const messages = [
    root,
    reply("thread-B", "thread-A", "b"),
    reply("thread-C", "thread-A", "c"),
    reply("thread-D", "thread-B", "d"),
    reply("thread-E", "thread-C", "e"),
    reply("thread-F", "thread-D", "e"),
  ];
  await show(page, { messages });
  await expect(page.locator("[data-reply-preview-target]")).toHaveCount(0);
  for (const [source, target] of [
    ["thread-B", "thread-A"],
    ["thread-C", "thread-B"],
    ["thread-D", "thread-C"],
    ["thread-E", "thread-D"],
  ]) {
    await expect(page.locator(`path[data-reply-source="${source}"]`)).toHaveAttribute(
      "data-reply-target",
      target!
    );
  }
  await expect(
    page.locator('[data-message-id="thread-E"] > .comma-chat-assistant-source-avatar')
  ).toHaveCount(0);
  await expect(
    page.locator('[data-message-id="thread-F"] > .comma-chat-assistant-source-avatar')
  ).toHaveCount(1);
  await expect(
    page.locator('[data-message-id="thread-E"] .comma-chat-assistant-source-label')
  ).toHaveCount(1);
  await expect(
    page.locator('[data-message-id="thread-F"] .comma-chat-assistant-source-label')
  ).toHaveCount(0);
  const intervals = await page
    .locator(".comma-chat-reply-lines path")
    .evaluateAll((paths) =>
      paths.map((node) => {
        const box = (node as unknown as SVGPathElement).getBBox();
        return [box.y, box.y + box.height];
      })
    );
  for (let i = 1; i < intervals.length; i++)
    expect(intervals[i]![0]!).toBeGreaterThan(intervals[i - 1]![1]!);

  // The server supplies the same root when neither a direct parent nor the
  // root is in this page. Only the first visible group needs a continuation.
  await show(page, { messages: messages.slice(3) });
  const preview = page.locator('[data-reply-preview-target="thread-A"]');
  await expect(preview).toHaveCount(1);
  await expect(page.locator('path[data-reply-source="thread-E"]')).toHaveAttribute(
    "data-reply-target",
    "thread-D"
  );
  await preview.hover();
  for (const id of ["thread-D", "thread-E", "thread-F"])
    await expect(page.locator(`article[data-message-id="${id}"]`)).toHaveAttribute(
      "data-reply-chain-state",
      "active"
    );
});

test("route: replies connect messages, quote crossings, and group each sender", async ({
  page,
}) => {
  await openSurface(page);
  const a = message("reply-A", "user", "Review the proposed design.");
  const secondUser = message("reply-A2", "user", "Also check the contrast.");
  const b = {
    ...message(
      "reply-B",
      "assistant",
      "I have a layout suggestion for the messages and input spacing."
    ),
    actorId: "worker-a",
    actorRole: "worker" as const,
  };
  const c = {
    ...message("reply-C", "assistant", "I will review the design."),
    actorId: "router",
    actorRole: "router" as const,
    replyToMessageId: a.messageId,
    threadRootMessageId: a.messageId,
  };
  const d = {
    ...message("reply-D", "assistant", "The layout is ready."),
    actorId: "worker-a",
    actorRole: "worker" as const,
    replyToMessageId: b.messageId,
    threadRootMessageId: b.messageId,
  };
  const e = { ...d, messageId: "reply-E", text: "The spacing is consistent too." };
  const f = {
    ...b,
    messageId: "reply-F",
    actorId: "worker-b",
    text: "I checked keyboard navigation.",
  };
  await show(page, { messages: [a, secondUser, b, c, d, e, f] });
  const row = (id: string) => page.locator(`article[data-message-id="${id}"]`);
  await expect(page.locator('[data-reply-source="reply-C"]')).toHaveCount(1);
  for (const width of [760, 800]) {
    await page.setViewportSize({ width, height: 720 });
    await expect
      .poll(() =>
        page.locator('[data-reply-source="reply-C"]').evaluate((element) => {
          const path = element as unknown as SVGPathElement;
          const svg = path.ownerSVGElement!;
          const bubble = svg
            .parentElement!.querySelector(
              '[data-message-id="reply-A"] .comma-chat-user-bubble'
            )!
            .getBoundingClientRect();
          const reply = svg.parentElement!.querySelector(
            '[data-message-id="reply-C"]'
          )!;
          const replyBubble = reply
            .querySelector(".markdown-stream-bubble")!
            .getBoundingClientRect();
          const origin = svg.getBoundingClientRect();
          const start = path.getPointAtLength(0);
          const end = path.getPointAtLength(path.getTotalLength());
          const beforeEnd = path.getPointAtLength(path.getTotalLength() - 6);
          const lineBounds = path.getBBox();
          // The bracket marks the user's message height and stops above
          // the Router reply's first bubble.
          return Math.max(
            Math.abs(origin.x + start.x - replyBubble.x - 37),
            Math.abs(origin.y + start.y - bubble.y - bubble.height / 2),
            Math.abs(origin.x + end.x - replyBubble.x - 13),
            Math.abs(origin.y + end.y - replyBubble.y + 8),
            Math.abs(beforeEnd.x - end.x),
            Math.abs(origin.x + lineBounds.x - replyBubble.x - 13),
            Math.max(0, lineBounds.width - 32)
          );
        })
      )
      .toBeLessThan(1);
  }
  const preview = page.locator('[data-reply-preview-target="reply-B"]');
  await expect(preview).toContainText(b.text);
  await expect(
    row(d.messageId).locator(":scope > .comma-chat-assistant-source-avatar")
  ).toHaveCount(0);
  await expect(
    row(d.messageId).locator(".comma-chat-assistant-source-label")
  ).toHaveCount(1);
  await expect(
    row(e.messageId).locator(".comma-chat-assistant-source-label")
  ).toHaveCount(0);
  await expect(
    row(e.messageId).locator(":scope > .comma-chat-assistant-source-avatar")
  ).toHaveCount(1);
  await expect(
    row(f.messageId).locator(".comma-chat-assistant-source-label")
  ).toHaveCount(1);
  await expect(
    row(f.messageId).locator(":scope > .comma-chat-assistant-source-avatar")
  ).toHaveCount(1);
  await expect(preview.locator(".comma-chat-reply-preview-avatar")).toHaveCount(0);
  const avatar = await row(e.messageId)
    .locator(":scope > .comma-chat-assistant-source-avatar")
    .boundingBox();
  const bubble = await row(e.messageId)
    .locator(".markdown-stream-bubble")
    .boundingBox();
  expect(
    Math.abs(avatar!.y + avatar!.height + 4 - bubble!.y - bubble!.height)
  ).toBeLessThan(1);
  await row(d.messageId).hover();
  const copy = await row(d.messageId)
    .getByRole("button", { name: "Copy reply" })
    .boundingBox();
  const shortBubble = await row(d.messageId)
    .locator(".markdown-stream-bubble")
    .boundingBox();
  expect(copy!.x - shortBubble!.x - shortBubble!.width).toBeGreaterThanOrEqual(0);
  expect(copy!.x - shortBubble!.x - shortBubble!.width).toBeLessThanOrEqual(13);
  await preview.click();
  await expect(row(b.messageId)).toBeFocused();
  // The target is already visible: move keyboard position without flashing.
  await expect(row(b.messageId).locator("[data-reveal-highlight]")).toHaveCount(0);

  // A target outside the mounted window must remain navigable without
  // inventing a link to the closest visible user turn.
  const history = Array.from({ length: 24 }, (_, i) => [
    message(`history-user-${i}`, "user", `Question ${i}`),
    { ...b, messageId: `history-reply-${i}`, text: `Answer ${i}. `.repeat(20) },
  ]).flat();
  const tail = {
    ...c,
    messageId: "history-tail",
    replyToMessageId: history[1]!.messageId,
    threadRootMessageId: history[1]!.messageId,
  };
  await show(page, { messages: [...history, tail] });
  await expect(row(history[1]!.messageId)).toHaveCount(0);
  await page.locator(`[data-reply-preview-target="${history[1]!.messageId}"]`).click();
  await expect(row(history[1]!.messageId)).toBeFocused();
  await expect(row(history[1]!.messageId)).toBeInViewport();
});

test("route: contained replies omit chat avatars and retain Task sender identity", async ({
  page,
}) => {
  await openSurface(page, true);
  const userMessage = (id: string, text: string) => ({
    ...message(id, "user", text),
    // Router user_chat messages use the product's "current" sender alias.
    createdBy: id === "Slack" ? "current" : "reply-user",
  });
  const reply = (id: string, target: string, text: string) => ({
    ...message(id, "assistant", text),
    actorId: "router",
    actorRole: "router" as const,
    replyToMessageId: target,
    threadRootMessageId: target,
  });
  const messages = [
    userMessage("PR", "Review my PRs."),
    userMessage("Slack", "Check my Slack messages."),
    reply("PR-reply", "PR", "Which repository should I check?"),
    userMessage("Linear", "Check my Linear issues."),
    reply("Slack-reply", "Slack", "Which Slack channel should I check?"),
    reply("Linear-reply", "Linear", "Which Linear team should I check?"),
  ];
  await show(page, { messages });
  for (const id of ["Slack", "Linear"]) {
    const preview = page.locator(`[data-reply-preview-target="${id}"]`);
    await expect(preview).toHaveCount(1);
    await expect(preview.locator(".comma-chat-reply-preview-avatar")).toHaveCount(0);
    await expect(preview).toContainText(
      id === "Slack" ? "Check my Slack messages." : "Check my Linear issues."
    );
  }
  await expect(page.locator(".comma-chat-reply-lines path")).toHaveCount(3);
  await expect
    .poll(() =>
      page.locator(".comma-chat-reply-lines path").evaluateAll((paths) => {
        const intervals = paths
          .map((path) => (path as unknown as SVGPathElement).getBBox())
          .toSorted((left, right) => left.y - right.y);
        return intervals.every(
          (bounds, index) =>
            index === 0 ||
            bounds.y > intervals[index - 1]!.y + intervals[index - 1]!.height
        );
      })
    )
    .toBe(true);
  expect(
    await page.evaluate(
      () => (window as unknown as { avatarReads: number }).avatarReads
    )
  ).toBe(0);
  await page.locator('[data-reply-preview-target="Linear"]').click();
  await expect(page.locator('article[data-message-id="Linear"]')).toBeFocused();

  // Task previews still distinguish senders and use the matching profile.
  await show(page, {
    conversation: {
      id: "handoff",
      group_id: "group",
      kind: "agent_task",
      title: "Task",
      status: "completed",
    },
    messages: messages.map((item) =>
      item.messageId === "Slack" ? { ...item, createdBy: "another-user" } : item
    ),
  });
  await expect(page.locator('[data-reply-preview-target="Slack"] img')).toHaveCount(0);
  await expect(page.locator('[data-reply-preview-target="Linear"] img')).toHaveCount(1);
  expect(
    await page.evaluate(
      () => (window as unknown as { avatarReads: number }).avatarReads
    )
  ).toBe(1);
});

test("route: sent long filename attachments align with the user bubble without overflow", async ({
  page,
}) => {
  await openSurface(page);
  const recordingName =
    "comma-recording-2026-09-08T13-12-38-785-50c17926-0b27-4f0d-9500-411c2317034e.wav";
  for (const names of [
    [recordingName],
    [recordingName, `second-${recordingName}`, "notes.txt"],
  ]) {
    await show(page, {
      messages: [
        {
          ...message("user-attachment", "user", "What was said?"),
          attachments: names.map((fileName) => ({
            blockType: "file",
            fileName,
            title: fileName,
          })),
        },
      ],
    });
    const article = page.locator(
      '.comma-chat-message-user[data-message-id="user-attachment"]'
    );
    await expect(article.locator(".comma-chat-attachment-pill")).toHaveCount(
      names.length
    );
    await expect
      .poll(() =>
        article.evaluate((element) => {
          const bounds = element.getBoundingClientRect();
          const bubble = element
            .querySelector(".comma-chat-user-bubble")!
            .getBoundingClientRect();
          const rowRights = new Map<number, number>();
          let overflow = 0;
          for (const pill of element.querySelectorAll(".comma-chat-attachment-pill")) {
            const rect = pill.getBoundingClientRect();
            overflow = Math.max(
              overflow,
              bounds.left - rect.left,
              rect.right - bounds.right
            );
            const row = Math.round(rect.top);
            rowRights.set(row, Math.max(rowRights.get(row) ?? -Infinity, rect.right));
          }
          return Math.max(
            overflow,
            ...Array.from(rowRights.values(), (right) => Math.abs(right - bubble.right))
          );
        })
      )
      .toBeLessThanOrEqual(1);
  }
});

test("route: a first reply keeps working feedback until the owner stops", async ({
  page,
}) => {
  await openSurface(page);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  const first = message("assistant-first", "assistant", "I will check the code now.");
  const base = { messages: [user, first], participantStatus: owner };
  await show(page, base);
  const body = page.locator('[data-message-id="assistant-first"]');
  const slot = page.getByTestId("participant-status-slot");
  await expect(body).toBeVisible();
  await expect(slot).toBeVisible();
  await expect(slot).toHaveAttribute("data-active", "true");
  await expect(slot).toContainText("Working");
  await expect(slot.locator(".comma-chat-activity-avatars")).toHaveCount(0);
  await expect(
    slot.locator(".comma-chat-thinking-bubble [data-slot='comma-logo-animation']")
  ).toHaveCount(1);
  const thinking = slot.locator(".comma-chat-thinking-bubble");
  await expect(thinking).toHaveCSS("height", "40px");
  await expect
    .poll(() =>
      thinking.evaluate((node) => getComputedStyle(node, "::before").animationName)
    )
    .toBe("comma-chat-thinking-breathe");
  await page.emulateMedia({ reducedMotion: "reduce" });
  await expect
    .poll(() =>
      thinking.evaluate((node) => getComputedStyle(node, "::before").animationName)
    )
    .toBe("none");
  await page.emulateMedia({ reducedMotion: "no-preference" });

  expect((await slot.boundingBox())!.y).toBeGreaterThanOrEqual(
    (await body.boundingBox())!.y + (await body.boundingBox())!.height
  );
  await expect(slot.locator('[data-slot="comma-logo-animation"]')).toHaveCount(1);

  // A replacement snapshot can have no source-bound Activity after reply.
  await show(page, { ...base, participantStatus: { ...owner, updatedAt: 2 } });
  await expect(slot).toBeVisible();
  // A later background Loop wake belongs to the Agent, not this chat reply.
  await show(page, {
    ...base,
    participantStatus: { ...owner, loopWake: true, updatedAt: 3 },
  });
  await expect(slot).toHaveAttribute("data-active", "false");
  await expect(body).toBeVisible();
  await show(page, { ...base, participantStatus: { ...owner, updatedAt: 4 } });
  await expect(slot).toBeVisible();
  await show(page, {
    ...base,
    assistantDraft: { ...draft, draftId: "draft-next", text: "The result is" },
  });
  await expect(page.getByTestId("chat-assistant-draft")).toBeVisible();
  await expect(slot).toBeHidden();
  await expect(body).toBeVisible();

  await show(page, {
    messages: [
      ...base.messages,
      message("assistant-final", "assistant", "The code is correct."),
    ],
    participantStatus: { ...owner, state: "stopped", updatedAt: 5 },
  });
  await expect(page.locator('[data-message-id="assistant-final"]')).toBeVisible();
  await expect(slot).toBeHidden();
  await expect(body).toBeVisible();
});

for (const first of [
  "First readable sentence.",
  "## First heading",
  "```js\nconst ready = true;\n```\n",
]) {
  test(`route: first ${first.startsWith("```") ? "code" : first.startsWith("#") ? "heading" : "text"} replaces waiting without a completion jump`, async ({
    page,
  }, info) => {
    await openSurface(page);
    const base = { messages: [user], participantStatus: owner };
    await show(page, { ...base, awaitingReply: true, locallyAwaitingReply: true });
    const slot = page.getByTestId("participant-status-slot");
    await expect(slot).toHaveAttribute("data-active", "true");
    const initialMark = await slot
      .locator('[data-slot="comma-logo-animation"]')
      .elementHandle();
    const waitingTop = await rowTop(slot, false);
    await show(page, { ...base, assistantDraft: draft });
    await expect(page.getByTestId("chat-assistant-draft")).toHaveCount(0);
    expect(
      await slot
        .locator('[data-slot="comma-logo-animation"]')
        .evaluate((e, before) => e === before, initialMark)
    ).toBe(true);
    await page.waitForTimeout(350);
    await show(page, { ...base, assistantDraft: { ...draft, text: first } });
    const body = page.getByTestId("chat-assistant-draft");
    await expect(body).toBeVisible();
    await expect(slot).toBeHidden();
    expect(await rowTop(body, false)).toBe(waitingTop);
    const initialCodeWeight = first.startsWith("```")
      ? await body
          .locator("pre")
          .evaluate((element) => getComputedStyle(element).fontWeight)
      : null;
    const initialCodeFont = first.startsWith("```")
      ? await body
          .locator("pre > code")
          .evaluate((element) => getComputedStyle(element).fontFamily)
      : null;
    const observer = await observeBody(body);
    await page.waitForTimeout(400);
    await show(page, {
      ...base,
      assistantDraft: { ...draft, text: first, status: "completed" },
      participantStatus: { ...owner, state: "stopped" },
    });
    await page.waitForTimeout(200);
    const final = message("assistant-1", "assistant", first);
    await show(page, {
      messages: [user, final],
      participantStatus: { ...owner, state: "stopped" },
    });
    await expect(page.locator('[data-message-id="assistant-1"]')).toBeVisible();
    await show(page, {
      messages: [user, final],
      participantStatus: { ...owner, state: "stopped", updatedAt: 99 },
      awaitingReply: true,
      locallyAwaitingReply: true,
    });
    await page.waitForTimeout(350);
    await expect(slot).toBeHidden();
    if (initialCodeFont !== null) {
      await expect(page.locator('[data-message-id="assistant-1"] pre')).not.toHaveClass(
        /shiki-fallback/
      );
      expect(
        await page
          .locator('[data-message-id="assistant-1"] pre > code')
          .evaluate((element) => getComputedStyle(element).fontFamily)
      ).toBe(initialCodeFont);
    }
    if (initialCodeWeight !== null) {
      await expect(page.locator('[data-message-id="assistant-1"] pre')).not.toHaveClass(
        /shiki-fallback/
      );
      expect(
        await page
          .locator('[data-message-id="assistant-1"] pre')
          .evaluate((element) => getComputedStyle(element).fontWeight)
      ).toBe(initialCodeWeight);
    }
    const observed = await observer.evaluate((p) => p.stop());
    await info.attach("body-continuity", {
      body: JSON.stringify(observed),
      contentType: "application/json",
    });
    if (observed.maxMovement !== 0) {
      console.warn("Body continuity geometry", JSON.stringify(observed));
    }
    expect(observed).toMatchObject({
      maxMovement: 0,
      hidden: 0,
      remounted: 0,
      transforms: [],
      activeStatus: 0,
    });
    await observer.dispose();
  });
}

for (const phase of ["waiting", "after-reply", "task-participants"] as const) {
  test(`route: thinking container ${phase} holds brief gaps and always reserves its height`, async ({
    page,
  }) => {
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await openSurface(page);
    const messages =
      phase === "after-reply"
        ? [user, message("settled-reply", "assistant", "A completed response.")]
        : [user];
    const status = (active: boolean) =>
      show(page, {
        messages,
        ...(phase === "task-participants"
          ? {
              participantStatuses: active
                ? [
                    owner,
                    {
                      ...owner,
                      participantId: "worker",
                      actorRole: "worker",
                      name: "Worker",
                    },
                  ]
                : [],
            }
          : { participantStatus: active ? owner : undefined }),
      });
    await status(true);
    const slot = page.getByTestId("participant-status-slot");
    await expect(slot).toHaveCSS("height", "40px");
    // The status shows before it pauses: a gap holds only what was shown.
    await expect(slot).toHaveAttribute("data-active", "true");
    if (phase === "task-participants") {
      await expect(
        slot.locator(".comma-chat-activity-avatars .comma-chat-activity-avatar")
      ).toHaveCount(2);
      await expect(slot.locator(".comma-chat-thinking-logo")).toHaveCount(0);
      const avatars = await slot.locator(".comma-chat-activity-avatars").boundingBox();
      const bubble = await slot.locator(".comma-chat-thinking-bubble").boundingBox();
      expect(bubble!.x).toBeGreaterThan(avatars!.x + avatars!.width);
    }
    await status(false);
    await expect(slot).toHaveAttribute("data-active", "true");
    await status(true);
    await expect(slot).toHaveCSS("height", "40px");
    const sample = () =>
      stepUntilSettled(
        slot.evaluate(async (node) => {
          const values: number[] = [];
          const start = performance.now();
          while (performance.now() - start < 450) {
            values.push(node.getBoundingClientRect().height);
            await new Promise(requestAnimationFrame);
          }
          return values;
        })
      );
    await status(false);
    const collapse = await sample();
    expect(new Set(collapse)).toEqual(new Set([40]));
    await expect(slot).toBeHidden();
    await expect(slot).toHaveCSS("transition-duration", "0s");
    await status(true);
    const expand = await sample();
    expect(new Set(expand)).toEqual(new Set([40]));
    await expect(slot).toBeVisible();
  });
}

test("route: reply drawing starts with streaming text and survives completion", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await openSurface(page);
  await show(page, { messages: [user], assistantDraft: draft });
  await expect(page.locator(".comma-chat-reply-lines path")).toHaveCount(0);
  await show(page, {
    messages: [user],
    assistantDraft: { ...draft, text: "First words" },
  });
  const line = page.locator(`path[data-reply-source="${draft.draftId}"]`);
  await expect(line).toHaveAttribute("data-reply-draw-visible", "true");
  const original = await line.elementHandle();
  const offset = await line.evaluate((node) =>
    Number.parseFloat(getComputedStyle(node).strokeDashoffset)
  );
  expect(offset).toBeGreaterThan(0);
  await show(page, {
    messages: [user],
    assistantDraft: { ...draft, text: "First words and more streamed words." },
  });
  expect(await line.evaluate((node, before) => node === before, original)).toBe(true);
  const final = {
    ...message("stream-final", "assistant", "First words and more streamed words."),
    replyToMessageId: user.messageId,
    threadRootMessageId: user.messageId,
  };
  await show(page, { messages: [user, final] });
  const completed = page.locator('path[data-reply-source="stream-final"]');
  expect(await completed.evaluate((node, before) => node === before, original)).toBe(
    true
  );
});

test("route: notices follow visible content and a new turn gets fresh waiting", async ({
  page,
}) => {
  await openSurface(page);
  const final = message("assistant-1", "assistant", "The readable answer stays here.");
  const base = { messages: [user, final] };
  await show(page, base);
  const body = page.locator('[data-message-id="assistant-1"]');
  await expect(body).toBeVisible();
  await expect(body).toHaveCSS("transform", /^(none|matrix\(1, 0, 0, 1, 0, 0\))$/);
  const position = await rowTop(body, false);
  await show(page, {
    ...base,
    // The longest issue copy, so the notice wraps.
    participantStatus: {
      ...owner,
      issue: "input_round_budget_parked",
      state: "error",
      status:
        "The request could not finish. Please review the received answer before continuing. ".repeat(
          3
        ),
    },
  });
  const slot = page.getByTestId("participant-status-slot");
  await expect(slot).toHaveAttribute("data-state", "error");
  await expect(slot.getByRole("alert")).toContainText("too many steps");
  await expect(slot).not.toContainText("could not finish");
  expect((await slot.boundingBox())!.y).toBeGreaterThanOrEqual(
    (await body.boundingBox())!.y + (await body.boundingBox())!.height
  );
  expect(await rowTop(body, false)).toBe(position);
  await show(page, { ...base, awaitingReply: true, awaitingTimedOut: true });
  await expect(slot).toHaveAttribute("data-state", "waiting");
  expect(await rowTop(body, false)).toBe(position);
  expect((await slot.boundingBox())!.y).toBeGreaterThanOrEqual(
    (await body.boundingBox())!.y + (await body.boundingBox())!.height
  );
  await show(page, {
    messages: [...base.messages, message("user-2", "user", "Continue in a new turn.")],
    awaitingReply: true,
    locallyAwaitingReply: true,
  });
  await expect(
    page.getByTestId("chat-current-turn").getByTestId("participant-status-slot")
  ).toHaveAttribute("data-active", "true");
  await expect(
    page.getByTestId("chat-current-turn").getByText("Thinking", { exact: true })
  ).toBeVisible();
});

for (const reducedMotion of ["no-preference", "reduce"] as const)
  test(`route: completion preserves a reader's long-reply scroll position (${reducedMotion})`, async ({
    page,
  }) => {
    await page.emulateMedia({ reducedMotion });
    await openSurface(page);
    const text = Array.from(
      { length: 45 },
      (_, i) =>
        `Paragraph ${i + 1}. The reader is inspecting this completed part of the reply.`
    ).join("\n\n");
    await show(page, {
      messages: [user],
      assistantDraft: { ...draft, text },
      participantStatus: owner,
    });
    const body = page.getByTestId("chat-assistant-draft");
    await expect(body).toContainText("Paragraph 45.");
    const viewport = page.locator('[data-slot="scroll-area-viewport"]').first();
    await viewport.hover();
    await page.mouse.wheel(0, 800);
    await page.waitForTimeout(150);
    await page.mouse.wheel(0, -250);
    await page.waitForTimeout(200);
    const before = await viewport.evaluate((e) => e.scrollTop);
    expect(before).toBeGreaterThan(0);
    const y = (await body.boundingBox())!.y;
    await show(page, {
      messages: [user, message("assistant-1", "assistant", text)],
      participantStatus: { ...owner, state: "stopped" },
    });
    await page.waitForTimeout(300);
    expect(await viewport.evaluate((e) => e.scrollTop)).toBe(before);
    expect(
      (await page.locator('[data-message-id="assistant-1"]').boundingBox())!.y
    ).toBe(y);
  });

function replyHighlightMessages(): ChatMessage[] {
  return [
    message("chain-A", "user", "Review the message design."),
    message("chain-B", "user", "Check my Slack messages."),
    {
      ...message("chain-C", "assistant", "Worker checks the design."),
      actorId: "worker-a",
      actorRole: "worker",
      replyToMessageId: "chain-A",
      threadRootMessageId: "chain-A",
    },
    {
      ...message("chain-D", "assistant", "Router checks Slack."),
      actorId: "router",
      actorRole: "router",
      replyToMessageId: "chain-B",
      threadRootMessageId: "chain-B",
    },
    {
      ...message("chain-E", "assistant", "Another worker follows the design review."),
      actorId: "worker-b",
      actorRole: "worker",
      replyToMessageId: "chain-C",
      threadRootMessageId: "chain-A",
    },
    {
      ...message("chain-F", "assistant", "Router adds another design detail."),
      actorId: "router",
      actorRole: "router",
      replyToMessageId: "chain-A",
      threadRootMessageId: "chain-A",
    },
    message("chain-independent", "assistant", "An independent update."),
  ];
}

async function observeReplyChain(page: Page, targetId: string, unrelatedId: string) {
  return page.evaluateHandle(
    ({ targetId: observedId, unrelatedId: dimmedId }) => {
      const column = document.querySelector<HTMLElement>(".comma-chat-column")!;
      const viewport = column.closest<HTMLElement>('[role="log"]')!;
      const target = column.querySelector<HTMLElement>(
        `article[data-message-id="${observedId}"]`
      )!;
      const unrelated = column.querySelector<HTMLElement>(
        `article[data-message-id="${dimmedId}"]`
      )!;
      const samples: { time: number; active: boolean; opacity: number }[] = [];
      let clickedAt = 0;
      let arrivedAt = 0;
      let frame = 0;
      const click = () => {
        clickedAt = performance.now();
      };
      const arrived = () => {
        const box = target.getBoundingClientRect();
        const view = viewport.getBoundingClientRect();
        if (clickedAt && !arrivedAt && Math.abs(box.y - view.y - 24) < 2)
          arrivedAt = performance.now();
      };
      const sample = () => {
        samples.push({
          time: performance.now(),
          active: column.hasAttribute("data-reply-chain-highlight"),
          opacity: Number(getComputedStyle(unrelated).opacity),
        });
        frame = requestAnimationFrame(sample);
      };
      column.addEventListener("click", click, true);
      viewport.addEventListener("scrollend", arrived);
      sample();
      return {
        async finish(duration: number) {
          await new Promise((resolve) => setTimeout(resolve, duration));
          cancelAnimationFrame(frame);
          column.removeEventListener("click", click, true);
          viewport.removeEventListener("scrollend", arrived);
          return { samples, clickedAt, arrivedAt };
        },
      };
    },
    { targetId, unrelatedId }
  );
}

function replyNavigationMessages(longReply: boolean) {
  const preceding = Array.from({ length: 8 }, (_, index) => [
    message(`navigation-history-user-${index}`, "user", `Earlier question ${index}`),
    message(
      `navigation-history-reply-${index}`,
      "assistant",
      "Earlier context. ".repeat(30)
    ),
  ]).flat();
  return [
    ...preceding,
    message("navigation-A", "user", "Check my PRs."),
    message("navigation-B", "user", "Check my Slack messages."),
    {
      ...message(
        "navigation-C",
        "assistant",
        longReply ? "Review details. ".repeat(500) : "Which repository?"
      ),
      replyToMessageId: "navigation-A",
      threadRootMessageId: "navigation-A",
    },
    {
      ...message("navigation-D", "assistant", "Which Slack channel?"),
      replyToMessageId: "navigation-B",
      threadRootMessageId: "navigation-B",
    },
  ];
}

async function observeReplyNavigation(page: Page, messageId: string) {
  return page.evaluateHandle((id) => {
    const viewport = document.querySelector<HTMLElement>('[role="log"]')!;
    const target = viewport.querySelector<HTMLElement>(
      `article[data-message-id="${id}"]`
    )!;
    const samples: Array<{
      y: number;
      topInsetOffset: number;
      firstMessage: string | undefined;
      highlighted: boolean;
    }> = [];
    let frame = 0;
    const sample = () => {
      const box = target.getBoundingClientRect();
      const view = viewport.getBoundingClientRect();
      samples.push({
        y: box.y,
        topInsetOffset: box.y - view.y - 24,
        firstMessage: viewport.querySelector<HTMLElement>("article[data-message-id]")
          ?.dataset.messageId,
        highlighted:
          target.hasAttribute("data-reveal-highlight") ||
          !!target.querySelector("[data-reveal-highlight]"),
      });
      frame = requestAnimationFrame(sample);
    };
    sample();
    return {
      async finish() {
        // Cover native smooth scrolling plus late focus/layout reconciliation.
        await new Promise((resolve) => setTimeout(resolve, 1100));
        cancelAnimationFrame(frame);
        return samples;
      },
    };
  }, messageId);
}

test("a cold conversation keeps loading local to its history until data arrives", async ({
  page,
}) => {
  await openSurface(page);
  await page.evaluate(() => {
    (
      window as unknown as {
        setHandoffState: (state: Partial<ConversationChannelState>) => void;
      }
    ).setHandoffState({ conversation: undefined, status: "loading" });
  });
  await expect(page.getByTestId("chat-title-loading")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Chat", exact: true })).toHaveCount(0);
  const loading = page.getByRole("status", { name: "Loading…", exact: true });
  await expect(loading).toHaveAttribute("aria-busy", "true");
  await expect(loading.locator('[data-slot="comma-logo-animation"]')).toBeVisible();
  await expect(page.getByText("Loading…", { exact: true })).toHaveCount(0);
  await show(page, {});
  await expect(page.getByRole("heading", { name: "Reply handoff" })).toBeVisible();
  await expect(page.getByTestId("chat-title-loading")).toHaveCount(0);
  await expect(loading).toHaveCount(0);
});

async function rowTop(row: ReturnType<Page["locator"]>, relativeToTurn: boolean) {
  return row.evaluate(
    (node, relative) =>
      node.getBoundingClientRect().y -
      (relative ? node.closest(".comma-chat-turn")!.getBoundingClientRect().y : 0),
    relativeToTurn
  );
}

async function openSurface(page: Page, profile = false) {
  await page.setViewportSize({ width: 800, height: 720 });
  await page.goto(`${fixtureUrl}${profile ? "?profile=1" : ""}`);
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          typeof (window as unknown as { setHandoffState?: unknown }).setHandoffState
      )
    )
    .toBe("function");
}
async function show(page: Page, state: Partial<ConversationChannelState>) {
  await page.evaluate(
    (serialized) =>
      (
        window as unknown as { setHandoffState: (next: unknown) => void }
      ).setHandoffState(JSON.parse(serialized)),
    JSON.stringify(state)
  );
}
function message(messageId: string, role: string, text: string): ChatMessage {
  return {
    messageId,
    role,
    text,
    parts: [{ kind: "markdown", text }],
    attachments: [],
    blocksKey: undefined,
    refs: [],
    clientRequestId: undefined,
    createdAt: 1,
    createdBy: undefined,
    delivery: "sent",
    error: undefined,
    source: "server",
    status: "completed",
  };
}
async function observeBody(body: ReturnType<Page["locator"]>) {
  return body.evaluateHandle((article) => {
    const top = () => article.getBoundingClientRect().y;
    const startY = top();
    let raf = 0,
      samples = 0,
      maxMovement = 0,
      hidden = 0,
      remounted = 0,
      activeStatus = 0,
      minOpacity = 1;
    const transforms = new Set<string>();
    const geometryChanges: Array<Record<string, unknown>> = [];
    let lastTop: number | undefined;
    const sample = () => {
      samples++;
      if (!article.isConnected) remounted++;
      const box = article.getBoundingClientRect();
      const currentTop = top();
      if (currentTop !== lastTop && geometryChanges.length < 16) {
        const turn = article.closest(".comma-chat-turn");
        const viewport = article.closest('[data-slot="scroll-area-viewport"]');
        const code = article.querySelector(".markdown-stream-code-block");
        geometryChanges.push({
          sample: samples,
          article: box.toJSON(),
          turn: turn?.getBoundingClientRect().toJSON(),
          viewport: viewport?.getBoundingClientRect().toJSON(),
          scrollTop: viewport?.scrollTop,
          scrollHeight: viewport?.scrollHeight,
          code: code?.getBoundingClientRect().toJSON(),
          fonts: document.fonts.status,
          codeElements: Array.from(
            article.querySelectorAll(
              ".code-block-content, .code-block-render, pre, pre code, pre .line, pre .markdown-stream-char-slot"
            )
          )
            .slice(0, 12)
            .map((element) => {
              const style = getComputedStyle(element);
              return {
                tag: element.tagName,
                className: element.className,
                box: element.getBoundingClientRect().toJSON(),
                font: style.font,
                fontFamily: style.fontFamily,
                fontSize: style.fontSize,
                fontWeight: style.fontWeight,
                fontStyle: style.fontStyle,
                lineHeight: style.lineHeight,
                display: style.display,
                overflow: style.overflow,
                padding: style.padding,
                border: style.border,
                verticalAlign: style.verticalAlign,
              };
            }),
        });
        lastTop = currentTop;
      }
      maxMovement = Math.max(maxMovement, Math.abs(currentTop - startY));
      const style = getComputedStyle(article);
      if (!box.height || style.opacity === "0") hidden++;
      minOpacity = Math.min(minOpacity, Number(style.opacity));
      if (style.transform !== "none") transforms.add(style.transform);
      if (
        article
          .closest('[data-testid="chat-current-turn"]')
          ?.querySelector('[data-testid="participant-status-slot"][data-active="true"]')
      )
        activeStatus++;
    };
    const tick = () => {
      sample();
      raf = requestAnimationFrame(tick);
    };
    tick();
    return {
      stop() {
        cancelAnimationFrame(raf);
        sample();
        return {
          samples,
          maxMovement,
          hidden,
          remounted,
          activeStatus,
          minOpacity,
          transforms: [...transforms],
          geometryChanges,
        };
      },
    };
  });
}
