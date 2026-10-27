import { type Locator } from "@playwright/test";
import { electron, expect, test } from "./electron-test";
import { setElectronWindowBounds } from "./electron-operations";
import { mkdir, mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { closeElectronTestApp } from "./close-electron-test-app";

const picture = (element: Element) => {
  const v = element as HTMLVideoElement;
  const c = document.createElement("canvas");
  c.width = v.videoWidth;
  c.height = v.videoHeight;
  c.getContext("2d")!.drawImage(v, 0, 0);
  return c.toDataURL();
};

test(
  "attachment downloads carry canonical filenames through the native save operation",
  { tag: "@shared-app" },
  async ({ sharedElectron }) => {
    const cases = [
      {
        file_name: "Release v2.1 - bundle.zip",
        path: "/artifacts/Release v2.1 - bundle.zip",
        expected: "Release v2.1 - bundle.zip",
      },
      {
        file_name: "release-bundle.zip — source and checksums v2.1",
        path: "/artifacts/release-bundle.zip",
        expected: "release-bundle.zip",
      },
      {
        file_name: "release-bundle.zip - source and README.md",
        path: "/artifacts/release-bundle.zip",
        expected: "release-bundle.zip",
      },
      {
        file_name: "Release notes",
        path: "/artifacts/archive.zip",
        expected: "Release notes",
      },
      {
        file_name: "Release v2.1 - renamed.zip",
        path: "/artifacts/archive.zip",
        expected: "Release v2.1 - renamed.zip",
      },
      { file_name: undefined, path: "/artifacts/README", expected: "README" },
      { file_name: undefined, path: undefined, expected: "attachment" },
    ];
    const bytes = Buffer.from("Original attachment bytes\n");
    const stub = await startChatSmokeStub({
      sessionEmail: "filenames@comma.local",
      attachmentFiles: Object.fromEntries(
        cases.map((_entry, index) => [
          `msg_filename_${index}:0`,
          { bytes, contentType: "application/octet-stream" },
        ])
      ),
      taskTranscript: cases.map(({ file_name, path }, index) => ({
        actor_type: "agent",
        agent_id: "worker_filename",
        message_id: `msg_filename_${index}`,
        kind: "message",
        content: [
          {
            type: "file",
            file_name,
            path,
            title: "Display description",
            blob_ref: { uuid: "u", hash: "h", size: bytes.length },
          },
        ],
      })),
    });
    // The shared app's Downloads folder, given at its launch.
    const { downloadsDir: downloads, mainWindow: page } = sharedElectron;
    try {
      sharedElectron.useApi(stub.server);
      await sharedElectron.signIn({
        email: "filenames@comma.local",
        userId: stub.userId,
      });
      await page.evaluate((hash) => {
        location.hash = hash;
      }, `/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`);
      for (const [index, entry] of cases.entries()) {
        const card = page.getByTestId(`chat-attachment-file-msg_filename_${index}-0`);
        await card.getByRole("button", { name: /^Preview / }).click();
        await page
          .getByTestId("file-preview-panel")
          .getByRole("button", { name: /^Download / })
          .click();
        const notification = page.getByTestId("file-download");
        await expect(
          notification.getByText("Download complete", { exact: true })
        ).toBeVisible();
        expect(await readdir(downloads)).toEqual([entry.expected]);
        expect(await readFile(join(downloads, entry.expected))).toEqual(bytes);
        // Two cases save under one name: each starts from an empty folder.
        await rm(join(downloads, entry.expected));
        await notification
          .getByRole("button", { name: "Dismiss notification" })
          .click();
        await expect(notification).toBeHidden();
        // Close the preview so the next case starts from the full-width chat:
        // with the sidebar open, a narrow attachment card's "Open in" button
        // covers the middle of its Preview trigger.
        const sidebar = page.getByTestId("chat-sidebar");
        const tab = await sidebar
          .getByRole("tab", { selected: true })
          .getAttribute("title");
        await sidebar
          .getByRole("button", { name: `Close ${tab}`, exact: true })
          .press("Enter");
        await expect(page.getByTestId("file-preview-panel")).toBeHidden();
      }
    } finally {
      await stub.close();
    }
  }
);

// Real AppKit clipboard + original attachment transport + composer attachments by reference.
// The old menus had no video actions; the assertion compares the copied frame
// with the paused picture and with a different later picture, not only its MIME.
test(
  "media menus attach originals, copy images and video files, freeze frames, and save originals",
  { tag: "@mac" },
  async ({ browserName: _browserName }, testInfo) => {
    test.skip(process.platform !== "darwin", "File clipboard integration uses AppKit.");
    const root = await mkdtemp(join(tmpdir(), "comma-media-menu-"));
    const downloads = join(root, "Downloads");
    await mkdir(downloads);
    const png = await readFile(
      resolve(
        "packages/ui/src/components/chat-panel/assets/generated-image-preview.png"
      )
    );
    const poster = await readFile(
      resolve("packages/ui/src/components/chat-panel/assets/generated-video-poster.png")
    );
    const images = [png, poster, png, poster];
    const svg = Buffer.from(
      '<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180"><rect width="320" height="180" rx="24" fill="#2563eb"/><circle cx="160" cy="90" r="50" fill="#facc15"/></svg>'
    );
    const files = [
      {
        name: "drawing-with-a-long-filename.svg",
        bytes: svg,
        contentType: "image/svg+xml",
      },
    ];
    for (const [ext, contentType] of [
      ["mp4", "video/mp4"],
      ["webm", "video/webm"],
      ["mov", "video/quicktime"],
    ] as const) {
      files.push({
        name: `motion.${ext}`,
        bytes: await readFile(
          resolve(`packages/app/e2e/fixtures/media-context-menu/motion.${ext}`)
        ),
        contentType,
      });
    }
    const attachmentFiles = Object.fromEntries(
      files.map((file, i) => [`msg_media_${i}:0`, file])
    );
    for (let i = 0; i < 4; i++)
      attachmentFiles[`msg_images:${i}`] = {
        name: `image-${i}.png`,
        bytes: images[i]!,
        contentType: "image/png",
      };
    const stub = await startChatSmokeStub({
      sessionEmail: "media@comma.local",
      agentImage: {
        agentId: "worker_media",
        bytes: png,
        contentType: "image/png",
        byUuid: Object.fromEntries(
          images.map((bytes, i) => [String(i + 1).repeat(32), bytes])
        ),
      },
      attachmentFiles,
      taskTranscript: [
        {
          actor_type: "agent",
          agent_id: "worker_media",
          message_id: "msg_images",
          kind: "message",
          content: Array.from({ length: 4 }, (_, i) => ({
            type: "image",
            file_name: `image-${i}.png`,
            mime_type: "image/png",
            blob_ref: {
              kind: "blob",
              uuid: String(i + 1).repeat(32),
              hash: "b".repeat(64),
              size: images[i]!.length,
            },
          })),
        },
        ...files.map((file, i) => ({
          actor_type: "agent",
          agent_id: "worker_media",
          message_id: `msg_media_${i}`,
          kind: "message",
          content: [
            {
              type: "file",
              file_name: file.name,
              mime_type: file.contentType,
              blob_ref: { uuid: "u", hash: "h", size: file.bytes.length },
            },
          ],
        })),
      ],
    });
    recordElectronOnboardingCompleted(`${root}/profile`, [stub.userId]);
    const { ELECTRON_RUN_AS_NODE: _runAsNode, ...env } = process.env;
    const appDir = resolve("apps/electron");
    const app = await electron.launch({
      args: [join(appDir, ".vite/build/main.js"), `--user-data-dir=${root}/profile`],
      cwd: appDir,
      env: {
        ...env,
        NODE_ENV: "test",
        COMMA_API_BASE_URL: stub.baseUrl,
        COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "comma_sess_media",
        COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "media@comma.local",
      },
      recordVideo: {
        dir: testInfo.outputPath("video"),
        size: { width: 1280, height: 800 },
      },
      // The app's Downloads folder is the test's from its start.
      main: {
        arg: downloads,
        beforeApp: ({ app: nativeApp }, path) => nativeApp.setPath("downloads", path),
      },
    });
    const page = await findElectronWindowByNativeRole(app, "main-window");
    const videoRecording = page.video();
    const hold = () =>
      page.waitForTimeout(process.env.COMMA_PLAYWRIGHT_RECORD_ALL === "1" ? 700 : 0);
    try {
      await page.waitForLoadState("domcontentloaded");
      await setElectronWindowBounds(app, page, { width: 1280, height: 800 });
      // Each action raises a Toast; the stack stays above menus, so a lingering
      // one can cover the next menu item. Assertions only read Toasts.
      await page.addStyleTag({
        content:
          '[data-slot="toast-host"], [data-slot="toast-host"] * { pointer-events: none !important; }',
      });
      await page.evaluate((hash) => {
        location.hash = hash;
      }, `/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`);
      const menu = page.getByRole("menu");
      // A Toast stays five seconds of real time, and on a busy runner the checks
      // after an action can outlast it. Watched from before the action, the
      // Toast is seen as it appears, or as a Toast of the same id changes.
      const watchToast = async (testId: string) => {
        await page.evaluate((id) => {
          const shown = new Promise<void>((done) => {
            const selector = `[data-slot="toast-host"] [data-testid="${id}"]`;
            const observer = new MutationObserver((records) => {
              const seen = records.some((record) => {
                const target =
                  record.target instanceof Element
                    ? record.target
                    : record.target.parentElement;
                if (target?.closest(selector)) return true;
                return [...record.addedNodes].some(
                  (node) =>
                    node instanceof Element &&
                    (node.matches(selector) || node.querySelector(selector) !== null)
                );
              });
              if (!seen) return;
              observer.disconnect();
              done();
            });
            observer.observe(document.body, {
              attributes: true,
              characterData: true,
              childList: true,
              subtree: true,
            });
          });
          Object.assign(window, { commaToastShown: shown });
        }, testId);
        return () =>
          page.evaluate(
            () =>
              (window as unknown as { commaToastShown: Promise<void> }).commaToastShown
          );
      };
      const waitForCopiedImage = async () => {
        await expect
          .poll(() => app.evaluate(({ clipboard }) => clipboard.has("image/png")))
          .toBe(true);
      };
      const act = async (media: Locator, action: string) => {
        if (action === "Copy" || action === "Copy image") {
          await app.evaluate(({ clipboard }) => clipboard.clear());
        }
        await media.click({ button: "right" });
        await expect(menu).toBeVisible();
        await hold();
        await menu.getByRole("menuitem", { name: action, exact: true }).click();
        await expect(menu).toBeHidden();
        if (action === "Copy image") await waitForCopiedImage();
        if (action === "Copy") {
          await expect
            .poll(() => app.evaluate(({ clipboard }) => clipboard.has("text/uri-list")))
            .toBe(true);
        }
        await hold();
      };
      // The server stored the message's image by reference; the composer shows the stored file, the original.
      const assertAttachment = async (index: number) => {
        const name = `image-${index}.png`;
        const thumbnail = page
          .getByTestId("image-attachment")
          .getByRole("img", { name, exact: true });
        await expect(thumbnail).toHaveAttribute("src", /^blob:/);
        expect(stub.storedAttachments).toContainEqual(
          expect.objectContaining({ messageId: "msg_images", index })
        );
        const matchesOriginal = await thumbnail.evaluate(async (element, base64) => {
          const actual = element as HTMLImageElement;
          const original = new Image();
          original.src = `data:image/png;base64,${base64}`;
          await Promise.all([actual.decode(), original.decode()]);
          if (
            actual.naturalWidth !== original.naturalWidth ||
            actual.naturalHeight !== original.naturalHeight
          )
            return false;
          const canvas = document.createElement("canvas");
          canvas.width = original.naturalWidth;
          canvas.height = original.naturalHeight;
          const context = canvas.getContext("2d")!;
          context.drawImage(original, 0, 0);
          const expected = canvas.toDataURL();
          context.clearRect(0, 0, canvas.width, canvas.height);
          context.drawImage(actual, 0, 0);
          return canvas.toDataURL() === expected;
        }, images[index]!.toString("base64"));
        expect(matchesOriginal).toBe(true);
        await hold();
      };
      const group = page.locator(
        '[data-message-id="msg_images"] .comma-chat-inline-images'
      );
      await expect(group).toBeVisible();
      // Native test windows start inactive. Activate before opening a focus-owned menu.
      await page.bringToFront();
      await expect.poll(() => page.evaluate(() => document.hasFocus())).toBe(true);
      // Wait for the displayed asset before its load can move the menu anchor.
      await group
        .getByRole("img", { name: "image-0.png" })
        .evaluate((image) => (image as HTMLImageElement).decode());
      await act(group.getByRole("img", { name: "image-0.png" }), "Add to Context");
      await assertAttachment(0);
      await act(group.getByRole("img", { name: "image-1.png" }), "Add to Context");
      await assertAttachment(1);
      const imageCopied = await watchToast("image-copy");
      await act(group.getByRole("img", { name: "image-1.png" }), "Copy image");
      await imageCopied();
      expect(await app.evaluate(({ clipboard }) => clipboard.has("image/png"))).toBe(
        true
      );
      await group.getByRole("img", { name: "image-2.png" }).click();
      const dialog = page.getByRole("dialog");
      await act(dialog.getByRole("img", { name: "image-2.png" }), "Add to Context");
      // The full window closes once the file it added shows in the composer, as a reader would.
      await assertAttachment(2);
      await page.keyboard.press("Escape");
      await expect(dialog).toBeHidden();
      await act(group.getByRole("img", { name: "image-3.png" }), "Save image");
      // The save makes the file, then writes it: until then there is no
      // file, or a part of one.
      await expect
        .poll(() => readFile(join(downloads, "image-3.png")).catch(() => null))
        .toEqual(images[3]);

      for (const [position, file] of files.entries()) {
        const isVideo = file.contentType.startsWith("video/");
        const inline =
          file.contentType === "video/mp4" || file.contentType === "video/webm";
        if (!inline) {
          await page
            .getByRole("button", { name: `Preview ${file.name}`, exact: true })
            .click();
        }
        const panel = inline
          ? page
              .locator(".comma-chat-inline-video")
              .filter({ has: page.getByLabel(file.name, { exact: true }) })
          : page.getByTestId("file-preview-panel");
        const media = isVideo
          ? panel.locator("video")
          : panel.getByRole("img", { name: file.name });
        await expect(media).toBeVisible();
        if (!isVideo) {
          const card = page.locator(".chat-panel-file").filter({ hasText: file.name });
          await expect(card.locator(".chat-panel-file-name")).toHaveAttribute(
            "title",
            file.name
          );
          await expect
            .poll(() =>
              card.evaluate((element) => {
                const actions = element.querySelector(".chat-panel-file-actions")!;
                const buttons = Array.from(actions.querySelectorAll("button"));
                const first = buttons[0]!.getBoundingClientRect();
                const last = buttons.at(-1)!.getBoundingClientRect();
                const name = element.querySelector<HTMLElement>(
                  ".chat-panel-file-name"
                )!;
                return {
                  sameRow: Math.abs(first.y - last.y) < 1,
                  nameTruncated: name.scrollWidth > name.clientWidth,
                  noOverlap:
                    name.getBoundingClientRect().right <=
                    actions.getBoundingClientRect().left,
                  noOverflow: element.scrollWidth <= element.clientWidth,
                };
              })
            )
            .toEqual({
              sameRow: true,
              nameTruncated: true,
              noOverlap: true,
              noOverflow: true,
            });
          await card.screenshot({ path: testInfo.outputPath("file-card-narrow.png") });
        }
        await media.click({ button: "right" });
        await expect(menu.getByRole("menuitem")).toHaveText(
          isVideo
            ? ["Add to Context", "Copy", "Copy Current Frame", "Save"]
            : ["Add to Context", "Copy image", "Save image"]
        );
        await expect(menu.locator("svg")).toHaveCount(0);
        await expect(menu.getByRole("separator")).toHaveCount(1);
        await hold();
        await menu.getByRole("menuitem", { name: "Add to Context" }).click();
        await expect(menu).toBeHidden();
        // The message's file goes by reference: the server stores the same blob, and nothing is uploaded. The
        // composer's row leaves Uploading once the server answered.
        const row = page
          .locator('[data-slot="file-attachment"]')
          .filter({ hasText: file.name });
        await expect(row).toBeVisible();
        await expect(row).not.toContainText(/Uploading|Upload failed/);
        expect(stub.storedAttachments).toContainEqual(
          expect.objectContaining({ messageId: `msg_media_${position}`, index: 0 })
        );
        expect(stub.uploads).toEqual([]);
        if (isVideo) {
          // A streamed player (`preload="metadata"`) has its metadata; the rest may wait until it plays.
          await expect
            .poll(() => media.evaluate((v) => (v as HTMLVideoElement).readyState))
            .toBeGreaterThan(0);
          await panel.getByRole("button", { name: "Play video", exact: true }).click();
          await expect
            .poll(() => media.evaluate((v) => (v as HTMLVideoElement).currentTime))
            .toBeGreaterThan(0.5);
          await panel.getByRole("button", { name: "Pause video", exact: true }).click();
          const paused = await media.evaluate(picture);
          await media.click({ button: "right" });
          await hold();
          // Move after the menu opens: Copy Current Frame must retain the right-click picture.
          await media.evaluate(async (element) => {
            const v = element as HTMLVideoElement;
            await new Promise<void>((done) => {
              v.addEventListener("seeked", () => done(), { once: true });
              v.currentTime = 2.5;
            });
          });
          expect(await media.evaluate(picture)).not.toBe(paused);
          // A previous Toast can still be visible. Observe this clipboard write.
          await app.evaluate(({ clipboard }) => clipboard.clear());
          const frameCopied = await watchToast("video-frame-copy");
          await menu
            .getByRole("menuitem", { name: "Copy Current Frame", exact: true })
            .click();
          await waitForCopiedImage();
          await frameCopied();
          const copied = await app.evaluate(async ({ clipboard }) => {
            const [item] = await clipboard.read();
            const image = await item!.getType("image/png");
            return `data:image/png;base64,${Buffer.from(await image.arrayBuffer()).toString("base64")}`;
          });
          const samePixels = await page.evaluate(
            async ([a, b]) => {
              // oxlint-disable-next-line unicorn/consistent-function-scoping -- Runs inside the browser evaluation context.
              const pixels = async (src: string) => {
                const img = new Image();
                img.src = src;
                await img.decode();
                const c = document.createElement("canvas");
                c.width = img.width;
                c.height = img.height;
                const ctx = c.getContext("2d")!;
                ctx.drawImage(img, 0, 0);
                return Array.from(ctx.getImageData(0, 0, c.width, c.height).data);
              };
              return (
                JSON.stringify(await pixels(a!)) === JSON.stringify(await pixels(b!))
              );
            },
            [paused, copied]
          );
          expect(samePixels).toBe(true);
          await expect(menu).toBeHidden();
          await hold();
          const fileCopied = await watchToast("video-file-copy");
          await act(media, "Copy");
          await fileCopied();
          const fileURL = await app.evaluate(async ({ clipboard }) => {
            const [item] = await clipboard.read();
            // An RFC 2483 list: one file URL here.
            const list = await item!.getType("text/uri-list");
            return (await list.text()).trim();
          });
          expect(await readFile(fileURLToPath(fileURL))).toEqual(file.bytes);
        } else {
          const copiedImage = await watchToast("image-copy");
          await act(media, "Copy image");
          await copiedImage();
          expect(
            await app.evaluate(async ({ clipboard, nativeImage }) => {
              const [item] = await clipboard.read();
              const image = await item!.getType("image/png");
              return nativeImage
                .createFromBuffer(Buffer.from(await image.arrayBuffer()))
                .getSize();
            })
          ).toEqual({ width: 320, height: 180 });
        }
        const before = await readdir(downloads);
        const downloaded = await watchToast("file-download");
        await act(media, isVideo ? "Save" : "Save image");
        await downloaded();
        // The one new file, once it has its whole content.
        await expect
          .poll(async () => {
            const saved = (await readdir(downloads)).filter(
              (name) => !before.includes(name)
            );
            return saved.length === 1 ? readFile(join(downloads, saved[0]!)) : saved;
          })
          .toEqual(file.bytes);
        await hold();
      }
    } finally {
      await closeElectronTestApp(app);
      if (videoRecording)
        await videoRecording.saveAs(testInfo.outputPath("media-context-menu.webm"));
      await stub.close();
      await rm(root, { recursive: true, force: true });
    }
  }
);
