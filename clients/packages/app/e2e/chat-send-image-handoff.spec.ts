import { expect, test, type Page } from "@playwright/test";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

type HandoffRecord = { frame: number | null; kind: string; src?: string | null };

/**
 * Records, from the send on, every image group placeholder and every image
 * the sent message mounts, each stamped with the document timeline's time.
 * That time moves only between rendering updates, so a placeholder that is
 * added and removed at one time was never painted.
 */
async function watchHandoff(page: Page) {
  await page.evaluate(() => {
    const records: HandoffRecord[] = [];
    const record = (kind: string, src?: string | null) =>
      records.push({
        frame: document.timeline.currentTime as number | null,
        kind,
        ...(src === undefined ? {} : { src }),
      });
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        for (const node of mutation.addedNodes) {
          if (!(node instanceof Element)) continue;
          if (
            node.matches("[data-comma-image-group-placeholder]") ||
            node.querySelector("[data-comma-image-group-placeholder]")
          ) {
            record("placeholder-added");
          }
          const images = node.matches("img")
            ? [node]
            : [...node.querySelectorAll("img")];
          for (const image of images) {
            if (image.closest('[data-slot="chat-user-output"]'))
              record("message-image", image.getAttribute("src"));
          }
        }
        for (const node of mutation.removedNodes) {
          if (!(node instanceof Element)) continue;
          if (
            node.matches("[data-comma-image-group-placeholder]") ||
            node.querySelector("[data-comma-image-group-placeholder]")
          ) {
            record("placeholder-removed");
          }
        }
      }
    });
    observer.observe(document.body, { childList: true, subtree: true });
    (
      window as unknown as { commaSendImageHandoff: HandoffRecord[] }
    ).commaSendImageHandoff = records;
  });
  return () =>
    page.evaluate(
      () =>
        (window as unknown as { commaSendImageHandoff: HandoffRecord[] })
          .commaSendImageHandoff
    );
}

test("a sent image keeps the thumbnail it was staged with: no second read, no placeholder frame", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({});
  const png = await readFile(
    resolve("packages/ui/src/components/chat-panel/assets/generated-image-preview.png")
  );
  const groupFileReads: string[] = [];
  page.on("response", (response) => {
    const url = new URL(response.url());
    if (url.pathname.endsWith("/files") && url.searchParams.has("path"))
      groupFileReads.push(url.searchParams.get("path")!);
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "send-image@comma.local",
      token: "comma_sess_send_image",
    });
    await page.goto("/");
    const outlet = page.getByTestId("comma-route-outlet");
    const composer = outlet.locator(".comma-chat-composer");
    const prompt = composer.getByRole("textbox", { name: "AI prompt" });
    await expect(prompt).toBeVisible();

    await outlet
      .locator('input[type="file"]')
      .setInputFiles([{ buffer: png, mimeType: "image/png", name: "photo.png" }]);
    await stub.waitForUploads(1);
    const tile = composer.getByTestId("image-attachment");
    const thumbnail = tile.locator('[data-state="ready"] img');
    await expect(thumbnail).toBeVisible();
    const thumbnailSrc = await thumbnail.getAttribute("src");
    expect(thumbnailSrc).toMatch(/^blob:/);
    // The staged thumbnail is the only read of this image.
    expect(groupFileReads).toEqual([]);

    await prompt.fill("Look at this");
    const readHandoff = await watchHandoff(page);
    await composer.getByRole("button", { name: /^Send/ }).click();

    const messageImage = page.locator('[data-slot="chat-user-output"] img').first();
    await expect(messageImage).toBeVisible();
    await expect(messageImage).toHaveAttribute("src", thumbnailSrc!);
    // The server's copy of the message replaces the pending one: still the same image.
    await stub.waitForMessageBodies(1);
    await expect(
      page.locator('[data-slot="chat-user-output"][data-source="server"] img').first()
    ).toHaveAttribute("src", thumbnailSrc!);
    expect(groupFileReads).toEqual([]);

    const handoff = await readHandoff();
    const mounted = handoff.filter((entry) => entry.kind === "message-image");
    expect(mounted.length).toBeGreaterThan(0);
    expect(new Set(mounted.map((entry) => entry.src))).toEqual(new Set([thumbnailSrc]));
    const placeholderFrames = handoff
      .filter((entry) => entry.kind.startsWith("placeholder"))
      .map((entry) => `${entry.kind}@${entry.frame}`);
    // Every placeholder left in the rendering update it arrived in, or never came.
    const added = handoff.filter((entry) => entry.kind === "placeholder-added");
    const removed = handoff.filter((entry) => entry.kind === "placeholder-removed");
    expect(
      removed.map((entry) => entry.frame),
      placeholderFrames.join(", ")
    ).toEqual(added.map((entry) => entry.frame));
  } finally {
    await stub.close();
  }
});
