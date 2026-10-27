import { readFile, readdir, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { expect, test } from "./electron-test";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

// Main, the core and the window as they ship: the window's media element reads an agent's video over the 10 MB a
// whole read allows from Main's `comma-file:` stream, in ranges, and its Download writes the whole file into Downloads
// as it arrives. Neither crosses IPC as bytes.
test(
  "an agent's video over 10 MB plays from ranged reads and saves whole",
  { tag: "@shared-app" },
  async ({ sharedElectron }) => {
    const motion = await readFile(
      resolve("packages/app/e2e/fixtures/media-context-menu/motion.mp4")
    );
    // A trailing `free` box: a valid MP4 past the old bound, whose picture is the fixture's.
    const free = Buffer.alloc(11_000_000);
    free.writeUInt32BE(free.length, 0);
    free.write("free", 4, "ascii");
    const video = Buffer.concat([motion, free]);
    const stub = await startChatSmokeStub({
      sessionEmail: "video-stream@comma.local",
      attachmentFiles: {
        "msg_big_video:0": { bytes: video, contentType: "application/octet-stream" },
      },
      taskTranscript: [
        {
          actor_type: "agent",
          agent_id: "worker_video",
          message_id: "msg_big_video",
          kind: "message",
          content: [
            {
              type: "file",
              file_name: "clip.mp4",
              mime_type: "video/mp4",
              blob_ref: { uuid: "u", hash: "h", size: video.length },
            },
          ],
        },
      ],
    });
    const { downloadsDir: downloads, mainWindow: page } = sharedElectron;
    try {
      sharedElectron.useApi(stub.server);
      await sharedElectron.signIn({
        email: "video-stream@comma.local",
        userId: stub.userId,
      });
      await page.evaluate((hash) => {
        location.hash = hash;
      }, `/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`);

      const frame = page.getByTestId("chat-attachment-video-msg_big_video-0");
      const player = frame.locator("video");
      await expect(player).toHaveAttribute("src", /^comma-file:\/\/stream\//);
      // The video's metadata, read through the ranged stream: its own event, however long the machine takes.
      const width = await player.evaluate((element) => {
        const media = element as HTMLVideoElement;
        return media.readyState >= 1
          ? media.videoWidth
          : new Promise<number>((done) =>
              media.addEventListener("loadedmetadata", () => done(media.videoWidth), {
                once: true,
              })
            );
      });
      expect(width).toBeGreaterThan(0);
      expect(stub.attachmentReads.length).toBeGreaterThan(0);
      expect(stub.attachmentReads.filter((read) => read.range === null)).toEqual([]);

      // Focus shows the controls at once (a hover slides them in, and a press during the slide misses).
      await frame.getByRole("button", { name: "Download video" }).focus();
      await page.keyboard.press("Enter");
      await expect(
        page
          .getByTestId("file-download")
          .getByText("Download complete", { exact: true })
      ).toBeVisible();
      expect(await readdir(downloads)).toEqual(["clip.mp4"]);
      expect((await readFile(join(downloads, "clip.mp4"))).equals(video)).toBe(true);
    } finally {
      // The worker's other tests share its Downloads folder.
      await rm(join(downloads, "clip.mp4"), { force: true });
      await stub.close();
    }
  }
);
