import { expect, test } from "@playwright/test";
import { readFile } from "node:fs/promises";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// The web's media element sends no session headers, so an agent's video over the 10 MB a whole read allows plays from
// the server's media URL, in the ranges the player asks for, and the browser downloads it from there itself.
test("an agent's video over 10 MB plays on the web from its media URL and downloads whole", async ({
  page,
}) => {
  const motion = await readFile(
    new URL("./fixtures/media-context-menu/motion.mp4", import.meta.url)
  );
  // A trailing `free` box: a valid MP4 past the old bound, whose picture is the fixture's.
  const free = Buffer.alloc(11_000_000);
  free.writeUInt32BE(free.length, 0);
  free.write("free", 4, "ascii");
  const video = Buffer.concat([motion, free]);
  const stub = await startChatSmokeStub({
    attachmentFiles: {
      "msg_big_video:1": {
        bytes: video,
        contentType: "application/octet-stream",
        fileName: "clip.mp4",
      },
    },
    workspaceTranscript: [
      {
        kind: "message",
        message_id: "msg_big_video",
        actor_type: "agent",
        agent_id: "worker_video",
        created_at: 1_720_000_000,
        content: [
          { type: "text", text: "Here is the clip." },
          {
            type: "file",
            file_name: "clip.mp4",
            mime_type: "video/mp4",
            blob_ref: { uuid: "u", hash: "h", size: video.byteLength },
          },
        ],
      },
    ],
  });
  const metadataRequested = Promise.withResolvers<void>();
  const metadataHeld = Promise.withResolvers<void>();
  await page.route(
    `${stub.baseUrl}/v1/**/messages/msg_big_video/attachments/1`,
    async (route) => {
      if (route.request().method() === "GET") {
        metadataRequested.resolve();
        await metadataHeld.promise;
      }
      await route.continue();
    }
  );
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "video-stream@comma.local",
      token: "comma_sess_video_stream",
    });
    await page.goto("/", { waitUntil: "domcontentloaded" });

    const frame = page.getByTestId("chat-attachment-video-msg_big_video-0");
    const player = frame.locator("video");
    const progress = frame.getByRole("slider", { name: "Video playback position" });
    const totalTime = frame.locator("time").last();
    // The stub's media URL is the attachment's own address.
    await expect(player).toHaveAttribute(
      "src",
      new RegExp(`^${stub.baseUrl}/v1/.*/messages/msg_big_video/attachments/1$`)
    );
    await metadataRequested.promise;
    // The server has not sent any media bytes: these observations cannot race metadata.
    expect(
      await player.evaluate((element) => (element as HTMLVideoElement).readyState)
    ).toBe(0);
    expect(await totalTime.textContent()).toBe("--:--");
    expect(await progress.isDisabled()).toBe(true);
    metadataHeld.resolve();

    // The video's metadata, read through the ranged stream: its own event, however long the machine takes.
    const metadata = await player.evaluate((element) => {
      const media = element as HTMLVideoElement;
      const readMetadata = () => ({
        width: media.videoWidth,
        duration: media.duration,
      });
      return media.readyState >= 1
        ? readMetadata()
        : new Promise<ReturnType<typeof readMetadata>>((done) =>
            media.addEventListener("loadedmetadata", () => done(readMetadata()), {
              once: true,
            })
          );
    });
    expect(metadata.width).toBeGreaterThan(0);
    expect(metadata.duration).toBe(3);
    await expect(totalTime).toHaveText("00:03");
    await expect(progress).toBeEnabled();
    await expect(progress).toHaveAttribute("max", String(metadata.duration));

    // The listener is in place before the key is pressed: an evaluate left
    // pending can reach the page after the press, and miss its seek.
    await player.evaluate((element) => {
      const media = element as HTMLVideoElement & { seekedAt?: Promise<number> };
      media.seekedAt = new Promise<number>((done) =>
        media.addEventListener("seeked", () => done(media.currentTime), { once: true })
      );
    });
    await progress.press("ArrowRight");
    expect(
      await player.evaluate(
        (element) =>
          (element as HTMLVideoElement & { seekedAt: Promise<number> }).seekedAt
      )
    ).toBe(metadata.duration);
    await expect(progress).toHaveValue(String(metadata.duration));
    // Only the player read it, in ranges: nothing read the 11 MB whole.
    expect(stub.attachmentReads.length).toBeGreaterThan(0);
    expect(stub.attachmentReads.filter((read) => read.range === null)).toEqual([]);

    // Focus shows the controls at once (a hover slides them in, and a press during the slide misses).
    await frame.getByRole("button", { name: "Download video" }).focus();
    // The started feedback hides again on a timer, which can run out while the
    // test reads the 11 MB file: the page records it as it appears.
    await frame.evaluate((element) => {
      const host = element as HTMLElement & { startedShown?: Promise<void> };
      host.startedShown = new Promise<void>((done) => {
        const observer = new MutationObserver(() => {
          if (
            host.textContent?.includes(
              "Download started. Check your browser for progress."
            )
          ) {
            observer.disconnect();
            done();
          }
        });
        observer.observe(host, { characterData: true, childList: true, subtree: true });
      });
    });
    const downloading = page.waitForEvent("download");
    await page.keyboard.press("Enter");
    const download = await downloading;
    expect(download.suggestedFilename()).toBe("clip.mp4");
    await frame.evaluate(
      (element) =>
        (element as HTMLElement & { startedShown: Promise<void> }).startedShown
    );
    expect((await readFile((await download.path())!)).equals(video)).toBe(true);
    await expect(frame.getByText("Video downloaded.")).toHaveCount(0);
  } finally {
    metadataHeld.resolve();
    await page.unrouteAll({ behavior: "wait" });
    await stub.close();
  }
});
