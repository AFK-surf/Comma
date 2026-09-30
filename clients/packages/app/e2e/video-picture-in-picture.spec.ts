import { expect, test, type Page } from "@playwright/test";
import { readFile } from "node:fs/promises";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

const paragraph =
  "Comma keeps the recording with the conversation, so the next step can build on it without another upload. ";

const text = (value: string) => ({ type: "text" as const, text: value });

/** Home's conversation with a video in the middle and enough text to scroll it away. */
const openHomeWithVideo = async (page: Page) => {
  const video = await readFile(
    new URL(
      "../../ui/src/components/chat-panel/assets/generated-video-preview.webm",
      import.meta.url
    )
  );
  const turn = (index: number) => [
    { actor_type: "user", content: [text(`Question ${index}?`)] },
    { actor_type: "agent", content: [text(paragraph.repeat(6))] },
  ];
  const transcript = [
    ...turn(1),
    { actor_type: "user", content: [text("Show me the onboarding recording.")] },
    {
      actor_type: "agent",
      agent_id: "worker_video",
      content: [
        text("Here is the onboarding recording."),
        {
          type: "file" as const,
          file_name: "onboarding.webm",
          mime_type: "video/webm",
          blob_ref: { uuid: "u", hash: "h", size: video.byteLength },
        },
      ],
      message_id: "msg_video",
    },
    ...turn(2),
    ...turn(3),
    ...turn(4),
  ].map((message, index) => ({
    kind: "message",
    message_id: `msg_${index}`,
    ...message,
    created_at: 1_720_000_000 + index,
  }));
  const stub = await startChatSmokeStub({ workspaceTranscript: transcript });
  await installBrowserTestSession(page, {
    apiBaseUrl: stub.baseUrl,
    email: "pip@comma.local",
    token: "comma_sess_pip",
  });
  await page.route("**/messages/msg_video/attachments/*", (route) =>
    route.fulfill({ status: 200, contentType: "video/webm", body: video })
  );
  await page.goto("/");
  // The bytes load once the message nears the view; scroll up to it like a
  // reader. The player then replaces its same-sized placeholder.
  const message = page.locator('[data-message-id="msg_video"]');
  await expect(message).toBeAttached();
  await page.mouse.move(640, 680);
  for (let step = 0; step < 40; step += 1) {
    const top = await message.evaluate((node) => node.getBoundingClientRect().top);
    if (top > 120) break;
    await page.mouse.wheel(0, -200);
    await page.waitForTimeout(40);
  }
  const frame = message.locator("figure.chat-panel-video");
  await expect(frame.locator("video")).toBeAttached();
  await expect(frame).toBeInViewport({ ratio: 1 });
  await expect
    .poll(() => frame.locator("video").evaluate((v: HTMLVideoElement) => v.readyState))
    .toBeGreaterThan(1);
  // One element for the whole test: it must keep playing wherever it is shown.
  await page.evaluate(() => {
    const element = document.querySelector<HTMLVideoElement>(
      '[data-message-id="msg_video"] video'
    )!;
    element.muted = true;
    Reflect.set(window, "pipVideo", element);
    Reflect.set(window, "pipPauses", 0);
    element.addEventListener("pause", () =>
      Reflect.set(window, "pipPauses", Number(Reflect.get(window, "pipPauses")) + 1)
    );
  });
  return { frame, stub };
};

const play = async (page: Page) => {
  const button = page
    .locator('[data-message-id="msg_video"]')
    .getByRole("button", { name: "Play video", exact: true });
  await button.focus();
  await page.keyboard.press("Enter");
  // A focused control keeps its message in view; release it like a reader would.
  await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
};

const playback = (page: Page) =>
  page.evaluate(() => {
    const element = Reflect.get(window, "pipVideo") as HTMLVideoElement;
    return {
      inWindow: element.closest('[data-testid="chat-panel-video-pip"]') !== null,
      inMessage: element.closest('[data-message-id="msg_video"]') !== null,
      paused: element.paused,
      pauses: Number(Reflect.get(window, "pipPauses")),
      time: element.currentTime,
    };
  });

const wheel = async (page: Page, deltaY: number, steps: number) => {
  // Over the transcript, clear of the window in the top-right corner.
  await page.mouse.move(640, 680);
  for (let step = 0; step < steps; step += 1) {
    await page.mouse.wheel(0, deltaY);
    await page.waitForTimeout(30);
  }
};

test("a playing chat video continues in a draggable window that stays until the reader ends it", async ({
  page,
}) => {
  const { frame, stub } = await openHomeWithVideo(page);
  try {
    const inline = (await frame.boundingBox())!;
    await play(page);
    const floating = page.getByTestId("chat-panel-video-pip");
    await expect(floating).toHaveCount(0);

    await wheel(page, 300, 12);
    await expect(floating).toBeVisible();
    const first = await playback(page);
    expect(first).toMatchObject({ inWindow: true, paused: false, pauses: 0 });
    await expect
      .poll(async () => (await playback(page)).time)
      .toBeGreaterThan(first.time);

    // Measure the settled window, not its entrance.
    await expect
      .poll(() => floating.evaluate((element) => element.getAnimations().length))
      .toBe(0);
    const outlet = (await page.getByTestId("comma-route-outlet").boundingBox())!;
    const start = (await floating.boundingBox())!;
    const grab = { x: start.x + start.width / 2, y: start.y + start.height / 2 };
    await page.mouse.move(grab.x, grab.y);
    await page.mouse.down();
    await page.mouse.move(grab.x - 260, grab.y + 280, { steps: 10 });
    await page.mouse.up();
    const dropped = (await floating.boundingBox())!;
    expect(dropped.x).toBeCloseTo(start.x - 260, 0);
    expect(dropped.y).toBeCloseTo(start.y + 280, 0);
    expect(dropped.x).toBeGreaterThanOrEqual(outlet.x);
    expect(dropped.y + dropped.height).toBeLessThanOrEqual(outlet.y + outlet.height);

    // Scrolling back keeps the window; the frame says where the video plays,
    // at the size it had with the video in it.
    await wheel(page, -300, 14);
    await expect(frame.getByText("Playing in picture in picture")).toBeInViewport();
    await expect(floating).toBeVisible();
    expect(await playback(page)).toMatchObject({ inWindow: true, paused: false });
    const away = (await frame.boundingBox())!;
    expect(away.width).toBeCloseTo(inline.width, 0);
    expect(away.height).toBeCloseTo(inline.height, 0);

    await frame.getByRole("button", { name: "Play here", exact: true }).click();
    await expect(floating).toHaveCount(0);
    expect(await playback(page)).toMatchObject({
      inMessage: true,
      paused: false,
      pauses: 0,
    });
  } finally {
    await stub.close();
  }
});

test("leaving Home keeps the video in the window, and Jump to message returns to it", async ({
  page,
}) => {
  const { frame, stub } = await openHomeWithVideo(page);
  try {
    await play(page);
    await page.evaluate(() => {
      location.hash = "#/drive";
    });
    const floating = page.getByTestId("chat-panel-video-pip");
    await expect(floating).toBeVisible();
    expect(await playback(page)).toMatchObject({ inWindow: true, pauses: 0 });

    // Coming back to Home some other way keeps the window.
    await page.getByRole("link", { name: "Home", exact: true }).click();
    await expect(page).toHaveURL(/#\/$/);
    await expect(floating).toBeVisible();
    await page.evaluate(() => {
      location.hash = "#/drive";
    });

    await floating.hover();
    await floating
      .getByRole("button", { name: "Jump to message", exact: true })
      .click();
    await expect(page).toHaveURL(/#\/$/);
    await expect(floating).toHaveCount(0);
    await expect(frame).toBeInViewport({ ratio: 1 });
    expect(await playback(page)).toMatchObject({
      inMessage: true,
      paused: false,
      pauses: 0,
    });
  } finally {
    await stub.close();
  }
});

test("Close stops the video, and Full window opens at the message", async ({
  page,
}) => {
  const { frame, stub } = await openHomeWithVideo(page);
  try {
    await play(page);
    await wheel(page, 300, 12);
    const floating = page.getByTestId("chat-panel-video-pip");
    await floating.hover();
    await floating.getByRole("button", { name: "Close", exact: true }).click();
    await expect(floating).toHaveCount(0);
    expect(await playback(page)).toMatchObject({ inMessage: true, paused: true });
    await wheel(page, 300, 4);
    await expect(floating).toHaveCount(0);

    await wheel(page, -300, 14);
    await play(page);
    await wheel(page, 300, 12);
    await floating.hover();
    await floating.getByRole("button", { name: "Full window", exact: true }).click();
    const preview = page.getByRole("dialog", { name: "onboarding.webm" });
    await expect(preview).toBeVisible();
    await expect(floating).toHaveCount(0);
    await preview.getByRole("button", { name: "Close preview", exact: true }).click();
    await expect(preview).toHaveCount(0);
    await expect(frame).toBeInViewport();
    await expect(frame.getByRole("button", { name: "Full window" })).toBeFocused();
  } finally {
    await stub.close();
  }
});
