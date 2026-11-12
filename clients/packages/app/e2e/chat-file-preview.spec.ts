import { expect, test } from "@playwright/test";
import { pdfWithPages, twoPagePdf } from "./fixtures/file-preview/pdf";
import { expectCompactPreviewToolbar } from "./fixtures/file-preview/toolbar";
import type { Page } from "@playwright/test";
import { readFile } from "node:fs/promises";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

test("a chat Markdown attachment opens a shared sidebar tab without fetching document resources", async ({
  page,
}) => {
  const markdown =
    '# Local report\n\nReadable document.\n\n![remote](https://preview-invalid.example/leak)\n![local](/v1/private-file)\n\n```mermaid\ngraph TD; A[Document] --> B[Done]; click A "https://preview-invalid.example/diagram"\n```\n<script>window.previewExecuted = true</script>';
  const stub = await startChatSmokeStub({
    taskTranscript: [
      {
        actor_type: "agent",
        agent_id: "worker_file",
        message_id: "msg_preview",
        kind: "message",
        content: [
          {
            type: "file",
            file_name: "report.md",
            mime_type: "text/markdown",
            blob_ref: { uuid: "u", hash: "h", size: markdown.length },
          },
        ],
      },
    ],
  });
  const resourceRequests: string[] = [];
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "preview@comma.local",
      token: "comma_sess_preview",
    });
    // As the attachment endpoint answers: as an attachment under its own name, which a browser downloading from the
    // media URL (the stub's is this address) saves.
    await page.route("**/messages/msg_preview/attachments/0", (route) =>
      route.fulfill({
        status: 200,
        contentType: "text/markdown",
        headers: { "content-disposition": "attachment; filename*=UTF-8''report.md" },
        body: markdown,
      })
    );
    await page.route("**/preview-invalid.example/**", (route) => {
      resourceRequests.push(route.request().url());
      return route.abort();
    });
    await page.route("**/v1/private-file", (route) => {
      resourceRequests.push(route.request().url());
      return route.abort();
    });
    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    await page
      .locator(".chat-panel-file")
      .getByRole("button", { name: "Preview report.md", exact: true })
      .click();
    await expect(
      page.getByRole("tab", { name: "report.md", exact: true })
    ).toBeVisible();
    await expect(
      page
        .getByTestId("file-preview-panel")
        .getByRole("heading", { name: "Local report" })
    ).toBeVisible();
    const panel = page.getByTestId("file-preview-panel");
    const { download } = await expectCompactPreviewToolbar(panel, "report.md");
    const downloaded = page.waitForEvent("download");
    await download.click();
    const saved = await downloaded;
    expect(saved.suggestedFilename()).toBe("report.md");
    const savedPath = await saved.path();
    expect(savedPath).not.toBeNull();
    expect(await readFile(savedPath!, "utf8")).toBe(markdown);
    expect(resourceRequests).toEqual([]);
    expect(
      await page.evaluate(() => Reflect.get(window, "previewExecuted"))
    ).toBeUndefined();
    await page
      .locator(".chat-panel-file")
      .getByRole("button", { name: "Preview report.md", exact: true })
      .click();
    await expect(page.getByRole("tab", { name: "report.md", exact: true })).toHaveCount(
      1
    );
  } finally {
    await stub.close();
  }
});

type PreviewFixture = {
  name: string;
  mime: string;
  body: string | Buffer;
  id?: string;
};
async function startPreview(page: Page, files: PreviewFixture[]) {
  const stub = await startChatSmokeStub({
    taskTranscript: files.map((file, index) => ({
      actor_type: "agent",
      agent_id: "worker_preview",
      message_id: file.id ?? `msg_file_${index}`,
      kind: "message",
      content: [
        {
          type: "file",
          file_name: file.name,
          mime_type: file.mime,
          blob_ref: { uuid: "u", hash: "h", size: Buffer.byteLength(file.body) },
        },
      ],
    })),
    // As the attachment endpoint answers: whole or the byte range asked for, as a download under the file's own name.
    // A browser saving a media file goes to its media URL, which the stub answers with this address.
    attachmentFiles: Object.fromEntries(
      files.map((file, index) => [
        `${file.id ?? `msg_file_${index}`}:0`,
        { bytes: Buffer.from(file.body), contentType: file.mime, fileName: file.name },
      ])
    ),
  });
  await installBrowserTestSession(page, {
    apiBaseUrl: stub.baseUrl,
    email: "preview-media@comma.local",
    token: "comma_sess_preview_media",
  });
  await page.goto(
    `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
  );
  return stub;
}

for (const format of ["document", "fragment"] as const) {
  test(`HTML attachment ${format} preserves styles and blocks scripts, navigation and resource requests`, async ({
    page,
  }) => {
    const document =
      '<!doctype html><html><head><style>body { background: #e8edf5; color: #16324f; } .chapter { background: #fff; border: 4px solid #167d9a; padding: 24px; } .chapter header { display: flex; justify-content: space-between; } .chapter span { background-image: url("data:image/svg+xml,<svg xmlns=\'http://www.w3.org/2000/svg\'/>"); } </style><link rel="stylesheet" href="./chapter.css"></head><body class="report"><article class="chapter"><header><h1>Styled chapter</h1><span>01</span></header><p>Inline document styles survive preview.</p></article><img src="./chapter.png"><style>@import url("https://preview-invalid.example/style.css");</style><script>window.previewExecuted=true</script>' +
      '<h1>Safe document</h1><script>parent.previewExecuted=true</script><meta http-equiv="refresh" content="0;url=https://preview-invalid.example/redirect"><img src="https://preview-invalid.example/image"><img src="/v1/private-file"><iframe src="https://preview-invalid.example/frame"></iframe></body></html>';
    const html =
      format === "document"
        ? document
        : document.replace(/<!doctype html>|<\/?(?:html|head|body)\b[^>]*>/gi, "");
    const requests: string[] = [];
    await page.route("**/chapter.{css,png}", (route) => {
      requests.push(route.request().url());
      return route.abort();
    });
    await page.route("**/preview-invalid.example/**", (route) => {
      requests.push(route.request().url());
      return route.abort();
    });
    await page.route("**/v1/private-file", (route) => {
      requests.push(route.request().url());
      return route.abort();
    });
    const stub = await startPreview(page, [
      { name: "document.html", mime: "text/html", body: html },
    ]);
    try {
      await page
        .getByRole("button", { name: "Preview document.html", exact: true })
        .click();
      const frame = page.frameLocator('[data-testid="file-preview-html"]');
      await expect(frame.getByRole("heading", { name: "Safe document" })).toBeVisible();
      await page.screenshot({ path: test.info().outputPath("html-preview.png") });
      await test.info().attach("HTML preview", {
        path: test.info().outputPath("html-preview.png"),
        contentType: "image/png",
      });
      await expect(frame.locator("body")).toHaveCSS(
        "background-color",
        "rgb(232, 237, 245)"
      );
      await expect(frame.locator(".chapter")).toHaveCSS("border-top-width", "4px");
      await expect(frame.getByRole("heading", { name: "Styled chapter" })).toHaveCSS(
        "color",
        "rgb(22, 50, 79)"
      );
      expect(
        await frame
          .locator("body")
          .evaluate(() => Reflect.get(window, "previewExecuted"))
      ).toBeUndefined();
      await expect(page.getByTestId("file-preview-html")).toHaveAttribute(
        "sandbox",
        ""
      );
      expect(
        await frame.locator("body").evaluate(() => {
          try {
            void parent.document.body;
            return false;
          } catch {
            return true;
          }
        })
      ).toBe(true);
      expect(
        await page.evaluate(() => Reflect.get(window, "previewExecuted"))
      ).toBeUndefined();
      expect(requests).toEqual([]);
    } finally {
      await stub.close();
    }
  });
}

test("the file sidebar renders a bounded PDF page and changes pages", async ({
  page,
}) => {
  const fileName =
    "Annual-report-with-supporting-attachments-and-reviewed-financial-statements-2026.pdf";
  const stub = await startPreview(page, [
    { name: fileName, mime: "application/pdf", body: twoPagePdf() },
  ]);
  try {
    await page
      .getByRole("button", { name: `Preview ${fileName}`, exact: true })
      .click();
    const panel = page.getByTestId("file-preview-panel");
    const { toolbar, download } = await expectCompactPreviewToolbar(panel, fileName);
    const title = toolbar.locator(`[title="${fileName}"]`);
    await expect(title).toBeVisible();
    // The long title yields its middle while its extension and download control survive.
    // Measure both edges in one frame while the sidebar can still animate.
    const titleParts = await title.evaluate(
      (element, downloadButton) => {
        const head = element.firstElementChild as HTMLElement;
        const tail = element.lastElementChild as HTMLElement;
        return {
          headClipped: head.scrollWidth > head.clientWidth,
          tail: tail.textContent,
          tailRight: tail.getBoundingClientRect().right,
          downloadLeft: downloadButton!.getBoundingClientRect().left,
        };
      },
      await download.elementHandle()
    );
    expect(titleParts.headClipped).toBe(true);
    expect(titleParts.tail).toMatch(/2026\.pdf$/);
    expect(titleParts.tailRight).toBeLessThanOrEqual(titleParts.downloadLeft);
    const firstPage = panel.getByRole("img", { name: "PDF page 1" });
    await expect(firstPage).toBeVisible();
    const pixels = () =>
      firstPage.evaluate((element: HTMLCanvasElement) => {
        const data = element
          .getContext("2d")!
          .getImageData(0, 0, element.width, element.height).data;
        return {
          width: element.width,
          height: element.height,
          drawn: data.some((value, index) => index % 4 !== 3 && value < 128),
        };
      });
    await expect.poll(async () => (await pixels()).drawn).toBe(true);
    // A page bitmap stays inside the decoded-image budget at any zoom.
    const drawn = await pixels();
    expect(drawn.width * drawn.height).toBeLessThanOrEqual(16_777_216);
    await page.screenshot({ path: "../output/playwright/file-preview-pdf.png" });

    // The thumbnail rail names each page; choosing one reads it.
    const showPages = panel.getByRole("button", { name: "Show page thumbnails" });
    if (await showPages.isVisible()) await showPages.click();
    const rail = panel.getByRole("navigation", { name: "Page thumbnails" });
    await expect(rail).toContainText("2 pages");
    await rail.getByRole("button", { name: "Page 2", exact: true }).click();
    await expect(
      rail.getByRole("button", { name: "Page 2", exact: true })
    ).toHaveAttribute("aria-current", "page");
    await expect(panel.getByRole("img", { name: "PDF page 2" })).toBeInViewport();

    // Zoom keeps the page being read in view.
    await panel.getByRole("button", { name: /^Zoom, \d+%$/ }).click();
    await page.getByRole("menuitemradio", { name: "200%" }).click();
    await expect(panel.getByRole("button", { name: "Zoom, 200%" })).toBeVisible();
    await expect(panel.getByRole("img", { name: "PDF page 2" })).toBeInViewport();
    await expect(
      rail.getByRole("button", { name: "Page 2", exact: true })
    ).toHaveAttribute("aria-current", "page");
  } finally {
    await stub.close();
  }
});

test("a PDF thumbnail glides the pages to the page it names and keeps it chosen on the way", async ({
  page,
}) => {
  const stub = await startPreview(page, [
    {
      name: "long.pdf",
      mime: "application/pdf",
      body: pdfWithPages(Array.from({ length: 12 }, (_, index) => `Page ${index + 1}`)),
    },
  ]);
  try {
    await page.getByRole("button", { name: "Preview long.pdf", exact: true }).click();
    const panel = page.getByTestId("file-preview-panel");
    await expect(
      panel.getByRole("img", { name: "PDF page 1", exact: true })
    ).toBeVisible();
    const showPages = panel.getByRole("button", { name: "Show page thumbnails" });
    if (await showPages.isVisible()) await showPages.click();
    const rail = panel.getByRole("navigation", { name: "Page thumbnails" });
    const target = rail.getByRole("button", { name: "Page 9", exact: true });
    await expect(target).toBeVisible();

    // Each scroll from the click on, until page 9 is at the view's top: where the pages are and which thumbnail is chosen.
    const sampling = panel.evaluate(
      (element) =>
        new Promise<Array<{ top: number; chosen: string | null }>>((resolve) => {
          // Only pages near the view are mounted: a page not there yet is not at the top.
          const pageNumbered = (number: number) =>
            element.querySelector(`[aria-label="PDF page ${number}"]`);
          const viewport = pageNumbered(1)!.closest<HTMLElement>(
            '[data-slot="scroll-area-viewport"]'
          )!;
          const offset = (number: number) => {
            const found = pageNumbered(number);
            return found
              ? found.getBoundingClientRect().top - viewport.getBoundingClientRect().top
              : Number.POSITIVE_INFINITY;
          };
          // The view starts at the top: page 1 sits at the gutter the chosen page arrives at.
          const gutter = offset(1);
          const samples: Array<{ top: number; chosen: string | null }> = [];
          const sample = () => {
            samples.push({
              top: viewport.scrollTop,
              chosen:
                element
                  .querySelector('nav [aria-current="page"]')
                  ?.getAttribute("aria-label") ?? null,
            });
            if (Math.abs(offset(9) - gutter) < 1) {
              viewport.removeEventListener("scroll", sample);
              resolve(samples);
            }
          };
          viewport.addEventListener("scroll", sample);
        })
    );
    await target.click();
    const samples = await sampling;
    const moving = samples.slice(
      samples.findIndex((frame) => frame.chosen === "Page 9")
    );
    expect(moving.every((frame) => frame.chosen === "Page 9")).toBe(true);
    // The view only moves toward the page; how many frames the glide takes is the browser's.
    const tops = moving.map((frame) => frame.top);
    expect(tops).toEqual(tops.toSorted((a, b) => a - b));
    await expect(panel.getByRole("img", { name: "PDF page 9" })).toBeInViewport();
    await expect(target).toHaveAttribute("aria-current", "page");
  } finally {
    await stub.close();
  }
});

test("Request edits sends a dragged PDF area to the Task with its screenshot and its text", async ({
  page,
}) => {
  const stub = await startPreview(page, [
    { name: "brief.pdf", mime: "application/pdf", body: twoPagePdf() },
  ]);
  try {
    await page.getByRole("button", { name: "Preview brief.pdf", exact: true }).click();
    const panel = page.getByTestId("file-preview-panel");
    const firstPage = panel.getByRole("img", { name: "PDF page 1" });
    await expect(firstPage).toBeVisible();
    const requestEdits = panel.getByRole("button", { name: "Request edits" });
    await requestEdits.click();
    await expect(requestEdits).toHaveAttribute("aria-pressed", "true");
    await expect(panel.getByText("Drag over a page to select an area")).toBeVisible();

    // "Page One" starts at x 20 on baseline 100 of a 240 x 180 pt page: 60-80 pt from the top as it shows.
    const box = (await firstPage.boundingBox())!;
    const at = (x: number, y: number) =>
      [box.x + (x / 240) * box.width, box.y + (y / 180) * box.height] as const;
    await page.mouse.move(...at(10, 50));
    await page.mouse.down();
    await page.mouse.move(...at(150, 95), { steps: 4 });
    await page.mouse.up();
    const prompt = panel.getByRole("textbox", { name: "AI prompt" });
    await expect(prompt).toBeFocused();
    await page.screenshot({
      path: "../output/playwright/file-preview-pdf-request-edits.png",
    });
    await page.keyboard.type("Make this heading blue");
    const sent = page.waitForRequest(
      (request) =>
        request.method() === "POST" &&
        /\/conversations\/[^/]+\/messages$/.test(new URL(request.url()).pathname)
    );
    await page.keyboard.press("Enter");

    const text = ((await sent).postDataJSON() as { message: { text: string } }).message
      .text;
    expect(text).toMatch(/^Make this heading blue\n/);
    expect(text).toContain("File: brief.pdf");
    expect(text).toContain("Page: 1 of 2");
    expect(text).toContain("Text in the area:\nPage One");
    await stub.waitForUploads(1);
    expect(stub.uploads.map((upload) => upload.filename)).toContain(
      "pdf-page-1-area.png"
    );
    // The chat shows the person's words and the area; the context is for the agent.
    const sentMessage = page
      .locator('[data-slot="chat-user-output"]')
      .filter({ hasText: "Make this heading blue" });
    await expect(
      sentMessage.getByRole("img", { name: "pdf-page-1-area.png" })
    ).toBeVisible();
    await expect(sentMessage).not.toContainText("pdf_region_context");
    await expect(requestEdits).toHaveAttribute("aria-pressed", "false");
    await expect(prompt).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("image attachments preview from their bytes, and MP3 and MP4 attachments play from their media URL", async ({
  page,
}) => {
  const image = await readFile(
    new URL(
      "../../ui/src/components/chat-panel/assets/generated-image-preview.png",
      import.meta.url
    )
  );
  const audio = await readFile(
    new URL(
      "../../ui/src/components/chat-panel/assets/generated-audio-preview.mp3",
      import.meta.url
    )
  );
  const video = await readFile(
    new URL("./fixtures/file-preview/sample.mp4", import.meta.url)
  );
  const stub = await startPreview(page, [
    { name: "image.png", mime: "image/png", body: image },
    { name: "audio.mp3", mime: "audio/mpeg", body: audio },
    { name: "video.mp4", mime: "video/mp4", body: video },
  ]);
  try {
    const panel = page.getByTestId("file-preview-panel");
    await page.getByRole("button", { name: "Preview image.png", exact: true }).click();
    await expect
      .poll(() =>
        panel
          .getByRole("img", { name: "image.png" })
          .evaluate((element: HTMLImageElement) => element.naturalWidth)
      )
      .toBeGreaterThan(0);
    await page.getByRole("button", { name: "Preview audio.mp3", exact: true }).click();
    await expect
      .poll(() =>
        panel
          .locator("audio")
          .evaluate((element: HTMLAudioElement) => element.readyState)
      )
      .toBeGreaterThan(0);
    const inlineVideo = page.locator(".comma-chat-inline-video video");
    await expect
      .poll(() =>
        inlineVideo.evaluate((element: HTMLVideoElement) => element.videoWidth)
      )
      .toBeGreaterThan(0);
    // The web's media element reads the attachment in ranges, never as a whole read.
    expect(await inlineVideo.getAttribute("src")).toMatch(
      /^http:\/\/127\.0\.0\.1:\d+\/v1\/.*\/messages\/msg_file_2\/attachments\/0$/
    );
  } finally {
    await stub.close();
  }
});

test("SVG Preview context menu attaches the original, copies a PNG and saves the SVG with Toast feedback", async ({
  page,
}) => {
  const svg =
    '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="red"/></svg>';
  const stub = await startPreview(page, [
    { name: "drawing.svg", mime: "image/svg+xml", body: svg },
  ]);
  try {
    await page.context().grantPermissions(["clipboard-read", "clipboard-write"]);
    await page
      .getByRole("button", { name: "Preview drawing.svg", exact: true })
      .click();
    const image = page
      .getByTestId("file-preview-panel")
      .getByRole("img", { name: "drawing.svg" });
    await image.click({ button: "right" });
    const menu = page.getByRole("menu", { name: "Image actions" });
    await expect(menu.getByRole("menuitem")).toHaveText([
      "Add to Context",
      "Copy image",
      "Save image",
    ]);
    await expect(menu.locator("svg")).toHaveCount(0);
    await expect(menu.getByRole("separator")).toHaveCount(1);
    // The original attachment, stored by reference: the shown preview is not what goes.
    const stored = page.waitForResponse((response) =>
      response.url().endsWith("/messages/msg_file_0/attachments/0/workspace-file")
    );
    await menu.getByRole("menuitem", { name: "Add to Context" }).click();
    expect((await stored).status()).toBe(201);
    expect(
      stub.storedAttachments.map(({ messageId, index }) => [messageId, index])
    ).toEqual([["msg_file_0", 0]]);
    expect(stub.uploads).toEqual([]);
    await image.click({ button: "right" });
    await menu.getByRole("menuitem", { name: "Copy image", exact: true }).click();
    await expect(page.getByTestId("image-copy")).toContainText("Image copied");
    expect(
      await page.evaluate(async () => (await navigator.clipboard.read())[0]?.types)
    ).toContain("image/png");
    await image.click({ button: "right" });
    const downloadPromise = page.waitForEvent("download");
    await menu.getByRole("menuitem", { name: "Save image", exact: true }).click();
    const download = await downloadPromise;
    expect(download.suggestedFilename()).toBe("drawing.svg");
    expect(await readFile((await download.path())!, "utf8")).toBe(svg);
    await expect(page.getByTestId("file-download")).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("Chat inline images retain their original source in messages and full-window previews", async ({
  page,
}) => {
  const png = await readFile(
    new URL(
      "../../ui/src/components/chat-panel/assets/generated-image-preview.png",
      import.meta.url
    )
  );
  const originalBytes = Array.from({ length: 4 }, (_, index) =>
    Buffer.concat([png, Buffer.from(`original-${index}`)])
  );
  const originals: number[] = [];
  const stub = await startChatSmokeStub({
    agentImage: { agentId: "worker_images", bytes: png, contentType: "image/png" },
    taskTranscript: [
      {
        actor_type: "agent",
        agent_id: "worker_images",
        message_id: "msg_menu_images",
        kind: "message",
        content: Array.from({ length: 4 }, (_, index) => ({
          type: "image",
          file_name: `image-${index}.png`,
          mime_type: "image/png",
          blob_ref: {
            kind: "blob",
            uuid: String(index + 1).repeat(32),
            hash: "b".repeat(64),
            size: png.length,
          },
        })),
      },
    ],
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "image-menu@comma.local",
      token: "comma_sess_image_menu",
    });
    await page.route("**/messages/msg_menu_images/attachments/*", (route) => {
      const index = Number(route.request().url().split("/").at(-1));
      originals.push(index);
      return route.fulfill({
        status: 200,
        contentType: "image/png",
        body: originalBytes[index]!,
      });
    });
    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const group = page.locator(
      '[data-message-id="msg_menu_images"] .comma-chat-inline-images'
    );
    const menu = page.getByRole("menu", { name: "Image actions" });
    // Add to Context names the original attachment, which the server stores by reference: nothing is read or uploaded.
    const addToContext = async (index: number) => {
      const stored = page.waitForResponse((response) =>
        response
          .url()
          .endsWith(`/messages/msg_menu_images/attachments/${index}/workspace-file`)
      );
      await menu.getByRole("menuitem", { name: "Add to Context" }).click();
      expect((await stored).status()).toBe(201);
    };
    await group.getByRole("img", { name: "image-0.png" }).click({ button: "right" });
    await addToContext(0);
    await group.getByRole("img", { name: "image-1.png" }).click({ button: "right" });
    await addToContext(1);
    await group.getByRole("img", { name: "image-2.png" }).click();
    const dialog = page.getByRole("dialog");
    await dialog.getByRole("img", { name: "image-2.png" }).click({ button: "right" });
    await addToContext(2);
    expect(
      stub.storedAttachments.map(({ messageId, index }) => [messageId, index])
    ).toEqual([
      ["msg_menu_images", 0],
      ["msg_menu_images", 1],
      ["msg_menu_images", 2],
    ]);
    expect(originals).toEqual([]);
    expect(stub.uploads).toEqual([]);
    await expect(menu).toBeHidden();
    await page.keyboard.press("Escape");
    await expect(dialog).toBeHidden();
    await group.getByRole("img", { name: "image-3.png" }).click({ button: "right" });
    const downloaded = page.waitForEvent("download");
    await menu.getByRole("menuitem", { name: "Save image", exact: true }).click();
    const file = await downloaded;
    expect(file.suggestedFilename()).toBe("image-3.png");
    expect(await readFile((await file.path())!)).toEqual(originalBytes[3]);
    expect(originals).toEqual([3]);

    await group.getByRole("img", { name: "image-3.png" }).click({ button: "right" });
    await expect(menu).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(menu).toBeHidden();

    const viewport = await page
      .locator(".comma-chat-scroll-viewport:visible")
      .boundingBox();
    expect(viewport).not.toBeNull();
    await group.getByRole("img", { name: "image-3.png" }).click({ button: "right" });
    await expect(menu).toBeVisible();
    // A real outside press reaches the modal underlay, not the obscured thread.
    await page.mouse.click(viewport!.x + 4, viewport!.y + 4);
    await expect(menu).toBeHidden();
    expect(originals).toEqual([3]);
  } finally {
    await stub.close();
  }
});

for (const [extension, mime] of [
  ["mp4", "video/mp4"],
  ["mov", "video/quicktime"],
] as const) {
  test(`${extension} Preview attaches and saves the original video and copies a paused frame`, async ({
    page,
  }) => {
    const name = `motion.${extension}`;
    const body = await readFile(
      new URL(`./fixtures/media-context-menu/${name}`, import.meta.url)
    );
    const stub = await startPreview(page, [{ name, mime, body }]);
    try {
      await page.context().grantPermissions(["clipboard-read", "clipboard-write"]);
      // main paints MP4/WebM inline; MOV keeps the isolated file preview.
      const inline = extension !== "mov";
      if (!inline) {
        await page
          .getByRole("button", { name: `Preview ${name}`, exact: true })
          .click();
      }
      const panel = inline
        ? page.locator(".comma-chat-inline-video")
        : page.getByTestId("file-preview-panel");
      const video = panel.locator("video");
      // A streamed player (`preload="metadata"`) has its metadata; the rest may wait until it plays.
      await expect
        .poll(() => video.evaluate((v) => (v as HTMLVideoElement).readyState))
        .toBeGreaterThan(0);
      await video.hover();
      // Hover slides the controls in. A press during that slide focuses the
      // button, focus-within ends the transition and moves the controls under
      // the pointer, and the release misses the button. Press once they rest.
      const controls = panel.getByRole("group", { name: "Video playback controls" });
      await expect(controls).toHaveCSS("opacity", "1");
      await expect(controls).toHaveCSS("transform", "matrix(1, 0, 0, 1, 0, 0)");
      await panel.getByRole("button", { name: "Play video", exact: true }).click();
      await expect
        .poll(() => video.evaluate((v) => (v as HTMLVideoElement).currentTime))
        .toBeGreaterThan(0.25);
      await panel.getByRole("button", { name: "Pause video", exact: true }).click();
      await video.click({ button: "right" });
      const menu = page.getByRole("menu", { name: "Video actions" });
      await expect(menu.getByRole("menuitem")).toHaveText([
        "Add to Context",
        "Copy",
        "Copy Current Frame",
        "Save",
      ]);
      await expect(
        menu.getByRole("menuitem", { name: "Copy", exact: true })
      ).toHaveAttribute("aria-disabled", "true");
      await menu
        .getByRole("menuitem", { name: "Copy Current Frame", exact: true })
        .click();
      await expect(page.getByTestId("video-frame-copy")).toBeVisible();
      expect(
        await page.evaluate(async () => {
          const image = (await navigator.clipboard.read())[0]!;
          const bitmap = await createImageBitmap(await image.getType("image/png"));
          return { width: bitmap.width, height: bitmap.height };
        })
      ).toEqual({ width: 320, height: 180 });
      expect(await video.evaluate((v) => (v as HTMLVideoElement).paused)).toBe(true);
      await video.click({ button: "right" });
      // The server stores the message's video by reference: its bytes are not read again or uploaded.
      const stored = page.waitForResponse((response) =>
        response.url().endsWith("/messages/msg_file_0/attachments/0/workspace-file")
      );
      await menu.getByRole("menuitem", { name: "Add to Context" }).click();
      expect((await stored).status()).toBe(201);
      expect(
        stub.storedAttachments.map(({ messageId, index }) => [messageId, index])
      ).toEqual([["msg_file_0", 0]]);
      expect(stub.uploads).toEqual([]);
      await expect(menu).toBeHidden();
      await video.click({ button: "right" });
      const downloadPromise = page.waitForEvent("download");
      await menu.getByRole("menuitem", { name: "Save", exact: true }).click();
      const download = await downloadPromise;
      expect(download.suggestedFilename()).toBe(name);
      expect(await readFile((await download.path())!)).toEqual(body);
      await expect(page.getByTestId("file-download")).toBeVisible();
    } finally {
      await stub.close();
    }
  });
}
