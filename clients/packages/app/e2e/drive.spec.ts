import { expect, test, type Page } from "@playwright/test";
import { twoPagePdf } from "./fixtures/file-preview/pdf";
import { expectCompactPreviewToolbar } from "./fixtures/file-preview/toolbar";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

const openDrive = async (page: Page) => {
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "drive-e2e@example.com",
    token: "comma_sess_drive_e2e",
  });
  await page.goto("/#/drive");
  await expect(page.getByTestId("drive-route")).toBeVisible();
};

test("file timestamps stay clear of reserved actions at wide and narrow list widths", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1800, height: 1000 });
  await openDrive(page);
  const row = page.getByTestId("drive-file-drive-file-screenshot");
  const modified = page.getByTestId("drive-file-modified-drive-file-screenshot");
  const download = row.getByRole("button", { name: /^Download / });
  const more = row.getByRole("button", { name: /^More actions/ });
  const list = row.locator("xpath=ancestor::section[1]");
  const fullTimestamp = await modified.locator(".sr-only").textContent();
  expect(fullTimestamp).toBeTruthy();

  for (const width of [900, 700]) {
    const listBox = (await list.boundingBox())!;
    await page.setViewportSize({
      width: Math.round(page.viewportSize()!.width + width - listBox.width),
      height: 1000,
    });
    await expect
      .poll(async () => (await list.boundingBox())!.width)
      .toBeCloseTo(width, 0);
    await page.mouse.move(0, 0);
    await expect(download).toHaveCSS("opacity", "0");
    const before = await modified.boundingBox();
    const actionBefore = await download.boundingBox();
    await row.hover();
    await expect(download).toHaveCSS("opacity", "1");
    expect(await modified.boundingBox()).toEqual(before);
    expect(await download.boundingBox()).toEqual(actionBefore);
    const textBounds = await modified.evaluate((element) => {
      const text = [...element.querySelectorAll("[aria-hidden]")].find(
        (child) => getComputedStyle(child).display !== "none"
      )!;
      const range = document.createRange();
      range.selectNodeContents(text);
      const bounds = range.getBoundingClientRect();
      return { right: bounds.right, text: text.textContent };
    });
    expect(textBounds.right).toBeLessThanOrEqual(actionBefore!.x - 8);
    expect(
      width === 900
        ? textBounds.text === fullTimestamp
        : textBounds.text !== fullTimestamp
    ).toBe(true);
    const header = (await page.getByTestId("drive-sort-modified").boundingBox())!;
    expect(header.x).toBeCloseTo(before!.x, 0);
    const actions = (await more.boundingBox())!;
    expect(actions.x + actions.width - actionBefore!.x).toBe(56);
    await modified.hover();
    await expect(page.getByRole("tooltip")).toHaveText(fullTimestamp!);
    await page.mouse.move(0, 0);
    await download.focus();
    await expect(download).toBeFocused();
    await expect(download).toHaveCSS("opacity", "1");
    await page.keyboard.press("Tab");
    await expect(more).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(page.getByRole("menu")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.getByTestId("drive-preview-panel")).toHaveCount(0);
  }
});

test("a saved recording reveal enters its folder, flashes without selecting, and consumes the jump", async ({
  page,
}) => {
  await openDrive(page);
  const dir = await mkdtemp(join(tmpdir(), "comma-recording-reveal-"));
  await mkdir(join(dir, "recording"));
  await writeFile(join(dir, "recording", "take.wav"), "recording preview fixture");
  try {
    await page.getByTestId("drive-folder-input").setInputFiles(dir);
    await expect(page.getByTestId(`drive-folder-${basename(dir)}`)).toBeVisible();
    await page.getByTestId("drive-transfer-close").click();
    // Begin elsewhere so a successful reveal must restore space and folder.
    await page.getByTestId("drive-space-space-recordings").click();
    const reveal = async (sequence: string) => {
      const query = new URLSearchParams({
        space: "space-folder-a",
        path: `${basename(dir)}/recording/take.wav`,
        reveal: `press-${sequence}`,
      });
      await page.evaluate((hash) => {
        window.history.pushState(window.history.state, "", `#${hash}`);
      }, `/drive?${query}`);
    };
    await reveal("1");
    const row = page
      .locator('[data-testid^="drive-file-drive-file-local-"]')
      .filter({ hasText: "take.wav" });
    await expect(row).toBeVisible();
    await expect(row).toHaveAttribute("data-reveal-highlight", "true");
    await expect(page.getByTestId("drive-breadcrumb-current")).toHaveText("recording");
    await expect(page.getByTestId("drive-space-space-folder-a")).toHaveAttribute(
      "data-selected",
      "true"
    );
    await expect(page.getByTestId("drive-selection-bar")).toHaveCount(0);
    await expect(page.getByTestId("drive-preview-panel")).toHaveCount(0);
    await expect(page).toHaveURL(/#\/drive$/);
    // A second explicit press replays; unrelated renders do not.
    await row.evaluate((element) => element.removeAttribute("data-reveal-highlight"));
    await reveal("2");
    await expect(row).toHaveAttribute("data-reveal-highlight", "true");
    await expect(page).toHaveURL(/#\/drive$/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("a missing recording reveal announces the failure and consumes the jump", async ({
  page,
}) => {
  await openDrive(page);
  const query = new URLSearchParams({
    space: "space-folder-a",
    path: "recording/deleted.wav",
    reveal: "missing",
  });
  await page.evaluate((hash) => {
    window.history.pushState(window.history.state, "", `#${hash}`);
  }, `/drive?${query}`);
  await expect(page.getByTestId("recording-reveal-failed")).toContainText(
    "Recording could not be found in Drive."
  );
  await expect(page.locator('[data-reveal-highlight="true"]')).toHaveCount(0);
  await expect(page).toHaveURL(/#\/drive$/);
});

test("the web rail has no Drive entry while the drive route still renders", async ({
  page,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "drive-e2e@example.com",
    token: "comma_sess_drive_e2e",
  });
  await page.goto("/#/");

  // Drive needs the Electron host's synchronicity node, so the web rail
  // leaves it out.
  const primaryNavLinks = page.locator('nav[aria-label="Primary"] a');
  await expect(primaryNavLinks).toHaveText(["Home", "Inbox", "Tasks", "Plugins"]);

  await page.goto("/#/drive");
  await expect(page.getByTestId("drive-route")).toBeVisible();
  // The header row is the toolbar itself.
  await expect(page.getByRole("heading", { level: 1 })).toHaveCount(0);

  // The panel chrome from the design: device + policy selects, Transfer, Add files.
  // One filter button, like the Inbox rail's, reads unfiltered at the defaults.
  await expect(page.getByTestId("drive-filter-trigger")).toHaveAttribute(
    "data-filtered",
    "false"
  );
  await expect(page.getByTestId("drive-transfer-toggle")).toBeVisible();
  await expect(page.getByTestId("drive-add-files")).toBeVisible();

  // The first space is selected and lists its files.
  await expect(page.getByTestId("drive-space-space-folder-a")).toHaveAttribute(
    "data-selected",
    "true"
  );
  await expect(page.getByTestId("drive-file-drive-file-screenshot")).toBeVisible();
  await expect(page.getByTestId("drive-file-drive-file-openai-pdf")).toBeVisible();
});

test("a previewed file becomes a tab of the shell's one right sidebar", async ({
  page,
}) => {
  await openDrive(page);

  const pdfRow = page.getByTestId("drive-file-drive-file-openai-pdf");
  await pdfRow.click();

  // The preview belongs to the shared sidebar, so the shell still has exactly
  // one right-sidebar toggle and one sidebar element.
  const sidebar = page.getByTestId("chat-sidebar");
  await expect(sidebar).toHaveAttribute("data-open", "true");
  await expect(page.getByTestId("chat-sidebar-toggle")).toHaveCount(1);
  await expect(page.locator('[data-slot="right-sidebar"]')).toHaveCount(1);

  const previewTab = page.getByRole("tab", { name: "Openai.pdf" });
  await expect(previewTab).toBeVisible();
  await expect(previewTab).toHaveAttribute("aria-selected", "true");
  // Fixture files from other devices have no local bytes yet.
  await expect(
    page.getByText("This file isn't synced on this device yet.")
  ).toBeVisible();
  await expect(
    page.getByTestId("drive-preview-panel").getByText("Folder A", { exact: true })
  ).toBeVisible();

  const screenshotRow = page.getByTestId("drive-file-drive-file-screenshot");
  await screenshotRow.click();
  const screenshotTab = page.getByRole("tab", {
    name: "Screenshot 2026-08-29 at 10.47.png",
  });
  await expect(screenshotTab).toHaveAttribute("aria-selected", "true");
  await expect(
    page.locator(
      '[data-testid="drive-preview-panel"] img[alt="Screenshot 2026-08-29 at 10.47.png"]'
    )
  ).toBeVisible();

  const preview = page.getByTestId("drive-preview-panel");
  const fileName = "Screenshot 2026-08-29 at 10.47.png";
  const { download } = await expectCompactPreviewToolbar(preview, fileName);
  await expect(preview.getByTestId("drive-preview-copy")).toBeVisible();
  const image = preview.getByRole("img", { name: fileName, exact: true });
  await expect
    .poll(() => image.evaluate((element: HTMLImageElement) => element.naturalWidth))
    .toBeGreaterThan(0);
  const mediaBounds = (await preview
    .getByTestId("file-preview-content")
    .boundingBox())!;
  const imageBounds = (await image.boundingBox())!;
  expect(
    Math.abs(
      imageBounds.x + imageBounds.width / 2 - (mediaBounds.x + mediaBounds.width / 2)
    )
  ).toBeLessThanOrEqual(1);
  expect(
    Math.abs(
      imageBounds.y + imageBounds.height / 2 - (mediaBounds.y + mediaBounds.height / 2)
    )
  ).toBeLessThanOrEqual(1);
  const metadata = preview.locator("dl");
  await expect(metadata.locator("dt")).toHaveCount(6);
  await expect(metadata).toContainText("Folder A");
  await expect(metadata).toContainText("This Mac");
  await expect(metadata).toContainText(fileName);
  const metadataBounds = (await metadata.boundingBox())!;
  const panelBounds = (await preview.boundingBox())!;
  expect(metadataBounds.y).toBeGreaterThanOrEqual(
    mediaBounds.y + mediaBounds.height - 1
  );
  expect(metadataBounds.y + metadataBounds.height).toBeCloseTo(
    panelBounds.y + panelBounds.height,
    0
  );
  const viewedBytes = await image.evaluate(async (element: HTMLImageElement) =>
    Array.from(new Uint8Array(await (await fetch(element.src)).arrayBuffer()))
  );
  const downloaded = page.waitForEvent("download");
  await download.click();
  const saved = await downloaded;
  expect(saved.suggestedFilename()).toBe(fileName);
  const savedPath = await saved.path();
  expect(savedPath).not.toBeNull();
  expect(await readFile(savedPath!)).toEqual(Buffer.from(viewedBytes));

  // Re-opening a file focuses its existing tab instead of adding a second one.
  await pdfRow.click();
  await expect(previewTab).toHaveAttribute("aria-selected", "true");
  await expect(page.getByRole("tab")).toHaveCount(2);

  // The checkbox cell is carved out of the open gesture: no new tab, row selected.
  await screenshotRow
    .getByRole("checkbox", { name: /Select Screenshot/ })
    .click({ force: true });
  await expect(screenshotRow).toHaveAttribute("data-selected", "true");
  await expect(page.getByRole("tab")).toHaveCount(2);

  // The close affordance arms on tab hover (pointer-events gate in CSS).
  await previewTab.hover();
  await page.getByRole("button", { name: "Close Openai.pdf" }).click();
  await expect(page.getByRole("tab", { name: "Openai.pdf" })).toHaveCount(0);
  await expect(screenshotTab).toHaveAttribute("aria-selected", "true");
});

test("a click joins the selection under way instead of opening the file", async ({
  page,
}) => {
  await openDrive(page);
  const pdfRow = page.getByTestId("drive-file-drive-file-openai-pdf");
  const pngRow = page.getByTestId("drive-file-drive-file-screenshot");
  const svgRow = page.getByTestId("drive-file-drive-file-logo-svg");

  // With nothing checked, a click is still the open gesture.
  await pdfRow.click();
  await expect(page.getByRole("tab", { name: "Openai.pdf" })).toHaveAttribute(
    "aria-selected",
    "true"
  );

  // Once one file is checked, the next row's click checks it too: picking
  // several is never interrupted by a preview, so no second tab opens.
  await pngRow.getByRole("checkbox").click({ force: true });
  const bar = page.getByTestId("drive-selection-bar");
  await expect(bar).toContainText("1 selected");
  await svgRow.click();
  await expect(bar).toContainText("2 selected");
  await expect(svgRow).toHaveAttribute("data-selected", "true");
  await expect(page.getByRole("tab")).toHaveCount(1);

  // The same press takes a row back out, and the last one ends the selection.
  await svgRow.click();
  await expect(bar).toContainText("1 selected");
  await expect(svgRow).not.toHaveAttribute("data-selected", "true");
  await pngRow.click();
  await expect(bar).toHaveCount(0);

  // With the selection spent, a click opens files again.
  await svgRow.click();
  await expect(page.getByRole("tab", { name: "logo-mark.svg" })).toHaveAttribute(
    "aria-selected",
    "true"
  );
});

test.describe("clipboard", () => {
  test.use({ permissions: ["clipboard-read", "clipboard-write"] });

  test("the preview's copy button puts the image on the clipboard and says so", async ({
    page,
  }) => {
    await openDrive(page);
    await page.getByTestId("drive-file-drive-file-screenshot").click();
    await expect(
      page.locator(
        '[data-testid="drive-preview-panel"] img[alt="Screenshot 2026-08-29 at 10.47.png"]'
      )
    ).toBeVisible();

    await page.getByTestId("drive-preview-copy").click();
    await expect(page.getByTestId("comma-drive-preview-copy")).toContainText(
      "Image copied"
    );
    await expect(page.getByTestId("comma-drive-preview-copy")).toContainText(
      "is on the clipboard"
    );
    await expect(
      page.evaluate(async () =>
        (await navigator.clipboard.read()).flatMap((item) => item.types)
      )
    ).resolves.toContain("image/png");
  });
});

test("the versions badge explains the split and settles it on one copy", async ({
  page,
}) => {
  await openDrive(page);

  // The badge is the way in: it opens the file and the panel that says what
  // "3 versions" actually means.
  await page.getByTestId("drive-file-versions-drive-file-openai-pdf").click();
  const versions = page.getByTestId("drive-versions-panel");
  await expect(versions).toBeVisible();
  await expect(versions).toContainText("This file has 3 versions");
  await expect(versions).toContainText(
    "Keep one, and the others are removed everywhere."
  );

  // One row per device that holds a copy, with the shown one marked.
  const rows = page.locator('[data-testid^="drive-version-drive-file-openai-pdf-"]');
  await expect(rows).toHaveCount(3);
  await expect(rows.nth(0)).toContainText("MacBook Pro 16");
  await expect(rows.nth(0)).toContainText("Showing now");
  await expect(rows.nth(0)).toHaveAttribute("data-selected", "true");
  await expect(rows.nth(2)).toContainText("Studio NAS");

  // The commit lives on the selected row, so it always names the copy beside
  // it: exactly one in the panel, and it follows the selection.
  const keep = page.getByTestId("drive-versions-keep");
  await expect(keep).toHaveCount(1);
  await expect(rows.nth(0).getByTestId("drive-versions-keep")).toBeVisible();

  await rows.nth(2).click();
  await expect(rows.nth(2)).toHaveAttribute("data-selected", "true");
  await expect(rows.nth(2).getByTestId("drive-versions-keep")).toBeVisible();
  await keep.click();

  await expect(
    page.getByTestId("comma-drive-version-drive-file-openai-pdf")
  ).toContainText("Kept the version from Studio NAS");
  await expect(versions).toBeHidden();
  await expect(
    page.getByTestId("drive-file-versions-drive-file-openai-pdf")
  ).toHaveCount(0);
  // The listing and the preview both follow the copy that was kept.
  await expect(page.getByTestId("drive-file-drive-file-openai-pdf")).toContainText(
    "1.9 MB"
  );
  await expect(page.getByTestId("drive-preview-panel")).toContainText("Studio NAS");
});

test("file rows offer download, keep offline, and delete", async ({ page }) => {
  await openDrive(page);

  const pdfRow = page.getByTestId("drive-file-drive-file-openai-pdf");
  await pdfRow.click({ button: "right" });
  const menu = page.getByRole("menu");
  await expect(menu).toBeVisible();
  await expect(menu.getByRole("menuitem")).toHaveText([
    "Ask Comma",
    "Download",
    "Keep Offline",
    "Delete",
  ]);
  await expect(menu.getByRole("menuitem", { name: "Delete" })).toHaveAttribute(
    "data-tone",
    "destructive"
  );

  // Keep Offline on a file this Mac never held brings its bytes here, pins
  // it, and the row says so; the menu then offers to undo it.
  await menu.getByRole("menuitem", { name: "Keep Offline" }).click();
  await expect(
    page.getByTestId("comma-drive-keep-offline-drive-file-openai-pdf")
  ).toContainText("“Openai.pdf” stays on this Mac");
  await expect(
    page.getByTestId("drive-file-pinned-drive-file-openai-pdf")
  ).toBeVisible();
  await pdfRow.click({ button: "right" });
  await expect(
    page.getByRole("menuitem", { name: "Stop Keeping Offline" })
  ).toBeVisible();
  await page.keyboard.press("Escape");

  // Download from the menu is the row's download.
  const downloadPromise = page.waitForEvent("download");
  await pdfRow.click({ button: "right" });
  await page.getByRole("menuitem", { name: "Download" }).click();
  expect((await downloadPromise).suggestedFilename()).toBe("Openai.pdf");

  // Delete leaves the space on every device, so it asks first; Escape keeps
  // the file, and only the sheet's Delete removes it.
  await pdfRow.click({ button: "right" });
  await page.getByRole("menuitem", { name: "Delete" }).click();
  const deleteDialog = page.getByRole("dialog", { name: "Delete “Openai.pdf”?" });
  await expect(deleteDialog).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(deleteDialog).toBeHidden();
  await expect(pdfRow).toHaveCount(1);
  await pdfRow.click({ button: "right" });
  await page.getByRole("menuitem", { name: "Delete" }).click();
  await deleteDialog.getByRole("button", { name: "Delete" }).click();
  await expect(pdfRow).toHaveCount(0);
  await expect(page.getByTestId("comma-drive-delete")).toContainText(
    "“Openai.pdf” was removed from the space."
  );

  // With several rows selected, a selected row's menu is the selection bar's
  // actions plus Keep Offline, on the whole selection.
  const pngRow = page.getByTestId("drive-file-drive-file-screenshot");
  const svgRow = page.getByTestId("drive-file-drive-file-logo-svg");
  await pngRow.getByRole("checkbox").click({ force: true });
  await svgRow.getByRole("checkbox").click({ force: true });
  const selectionBar = page.getByTestId("drive-selection-bar");
  await expect(selectionBar).toContainText("2 selected");
  await pngRow.click({ button: "right" });
  await expect(page.getByRole("menu").getByRole("menuitem")).toHaveText([
    "Ask Comma",
    "Download all",
    "Keep Offline",
    "Delete",
  ]);

  // Keep Offline pins the whole selection, and the menu then offers to undo
  // it because every selected file is now pinned.
  await page.getByRole("menuitem", { name: "Keep Offline" }).click();
  await expect(page.getByTestId("comma-drive-keep-offline-selection")).toContainText(
    "2 files stay on this Mac"
  );
  await expect(
    page.getByTestId("drive-file-pinned-drive-file-screenshot")
  ).toBeVisible();
  await expect(page.getByTestId("drive-file-pinned-drive-file-logo-svg")).toBeVisible();
  await pngRow.click({ button: "right" });
  await page.getByRole("menuitem", { name: "Stop Keeping Offline" }).click();
  await expect(page.getByTestId("comma-drive-keep-offline-selection")).toContainText(
    "2 files may be cleared"
  );
  await expect(page.getByTestId("drive-file-pinned-drive-file-screenshot")).toHaveCount(
    0
  );
  await pngRow.click({ button: "right" });
  const batch: Promise<unknown>[] = [
    page.waitForEvent("download"),
    page.waitForEvent("download"),
  ];
  await page.getByRole("menuitem", { name: "Download all" }).click();
  await Promise.all(batch);
  await expect(page.getByTestId("comma-drive-download-all")).toContainText(
    "2 files were downloaded."
  );
  await expect(page.getByTestId("drive-selection-bar")).toHaveCount(0);
});

test("deleting a space is confirmed by typing its name", async ({ page }) => {
  await openDrive(page);

  const shared = page.getByTestId("drive-space-space-shared");
  await shared.click({ button: "right" });
  await page.getByRole("menuitem", { name: "Delete" }).click();
  const dialog = page.getByRole("dialog", { name: "Delete “Shared”?" });
  await expect(dialog).toBeVisible();
  // A replica-only space: no origin path to name.
  await expect(dialog).toContainText("This Mac stops replicating “Shared”.");
  const confirm = dialog.getByRole("button", { name: "Delete" });
  await expect(confirm).toBeDisabled();

  // Escape leaves everything as it was.
  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();
  await expect(shared).toHaveCount(1);

  await shared.click({ button: "right" });
  await page.getByRole("menuitem", { name: "Delete" }).click();
  await dialog.getByRole("textbox").fill("Share");
  await expect(confirm).toBeDisabled();
  await dialog.getByRole("textbox").fill("Shared");
  await expect(confirm).toBeEnabled();
  await confirm.click();
  await expect(dialog).toBeHidden();
  await expect(shared).toHaveCount(0);
  await expect(page.getByTestId("comma-drive-stop-sharing")).toContainText(
    "“Shared” is no longer shared from this Mac."
  );
});

test("transfer panel shows empty states, uploads land in the space, downloads toast", async ({
  page,
}) => {
  await openDrive(page);

  await page.getByTestId("drive-transfer-toggle").click();
  const panel = page.getByTestId("drive-transfer-panel");
  await expect(panel).toBeVisible();
  await expect(panel.getByTestId("drive-transfer-tab-upload")).toHaveText("Upload 0/0");
  await expect(panel.getByText("No files uploaded yet")).toBeVisible();
  await panel.getByTestId("drive-transfer-tab-download").click();
  await expect(panel.getByText("No files downloaded yet")).toBeVisible();
  // The panel stays mounted through its exit and flips `visibility` at the
  // end, so "closed" is hidden, not gone.
  await panel.getByTestId("drive-transfer-close").click();
  await expect(panel).toBeHidden();
  await expect(panel).toHaveAttribute("data-open", "false");

  // Upload through Add files; the picked bytes become a real row in the space.
  await page.getByTestId("drive-add-files").click();
  await page.getByRole("menuitem", { name: "Upload files" }).click();
  await page
    .locator('input[type="file"]')
    .first()
    .setInputFiles({
      buffer: Buffer.from("drive e2e upload payload"),
      mimeType: "text/plain",
      name: "notes.txt",
    });
  await expect(page.getByTestId("drive-transfer-panel")).toBeVisible();
  await expect(page.getByTestId("drive-transfer-tab-upload")).toHaveText("Upload 1/1");
  const uploadRow = page.locator('[data-testid^="drive-transfer-"][data-status]');
  await expect(uploadRow.first()).toHaveAttribute("data-status", "success");
  await expect(page.getByTestId(/^drive-file-drive-file-local-/)).toHaveText(
    /notes\.txt/
  );

  // Downloading a synced file completes through the browser adapter and toasts.
  const downloadPromise = page.waitForEvent("download");
  await page
    .getByTestId("drive-file-drive-file-screenshot")
    .getByRole("button", { name: /Download Screenshot/ })
    .click();
  const download = await downloadPromise;
  expect(download.suggestedFilename()).toBe("Screenshot 2026-08-29 at 10.47.png");
  await expect(
    page.locator('[data-testid^="comma-drive-download-"]', {
      hasText: "Download complete",
    })
  ).toBeVisible();
  // The single-file outcome replaces progress in the same notification.
  await expect(
    page.locator('[data-testid^="comma-drive-download-drive-transfer-"]')
  ).toHaveCount(1);
  await expect(page.getByText("Downloading…", { exact: true })).toHaveCount(0);
  await page.getByTestId("drive-transfer-tab-download").click();
  await expect(page.getByTestId("drive-transfer-tab-download")).toHaveText(
    "Download 1/1"
  );
  // The body's animated height tracks its content after the tab swap.
  const bodyHeightMatchesContent = () =>
    page.getByTestId("drive-transfer-panel").evaluate((panelElement) => {
      const wrapper = panelElement.querySelector<HTMLElement>("div.overflow-hidden");
      const content = wrapper?.firstElementChild;
      if (!wrapper || !content) return false;
      return wrapper.style.height === `${content.getBoundingClientRect().height}px`;
    });
  await expect.poll(bodyHeightMatchesContent).toBe(true);

  // A file that is not synced on this device fails with a retryable row.
  await page
    .getByTestId("drive-file-drive-file-openai-pdf")
    .getByRole("button", { name: /Download Openai/ })
    .click();
  await expect(
    page.locator('[data-testid^="comma-drive-download-"]', {
      hasText: "Download failed",
    })
  ).toBeVisible();
  await expect(page.getByTestId("drive-transfer-tab-download")).toHaveText(
    "Download 1/2"
  );
  const failedRow = page
    .locator('[data-testid^="drive-transfer-"][data-status="error"]')
    .first();
  await expect(failedRow).toContainText("Not synced on this device yet");
  await expect(failedRow.getByRole("button", { name: "Retry" })).toBeVisible();

  // X is "done with these": the next open starts from an empty panel.
  await page.getByTestId("drive-transfer-close").click();
  await expect(page.getByTestId("drive-transfer-panel")).toBeHidden();
  await page.getByTestId("drive-transfer-toggle").click();
  await expect(page.getByTestId("drive-transfer-panel")).toBeVisible();
  await expect(page.getByTestId("drive-transfer-tab-upload")).toHaveText("Upload 0/0");
  await expect(page.getByTestId("drive-transfer-tab-download")).toHaveText(
    "Download 0/0"
  );
  await expect(page.getByText("No files uploaded yet")).toBeVisible();
});

test("a transfer list longer than the panel scrolls inside it", async ({ page }) => {
  await openDrive(page);

  // Sixteen rows is well past the panel's cap, so the panel has to stop
  // growing and hand the overflow to its own viewport rather than running
  // past its rounded edge.
  await page.getByTestId("drive-add-files").click();
  await page.getByRole("menuitem", { name: "Upload files" }).click();
  await page
    .locator('input[type="file"]')
    .first()
    .setInputFiles(
      Array.from({ length: 16 }, (_unused, index) => ({
        buffer: Buffer.from(`payload ${index}`),
        mimeType: "text/plain",
        name: `bulk-${index}.txt`,
      }))
    );
  await expect(page.getByTestId("drive-transfer-tab-upload")).toHaveText(
    "Upload 16/16"
  );

  const viewport = page
    .getByTestId("drive-transfer-panel")
    .locator('[data-slot="scroll-area-viewport"]');
  const geometry = await viewport.evaluate((node) => ({
    clientHeight: node.clientHeight,
    panelMaxHeight: getComputedStyle(node.closest("section")!).maxHeight,
    panelHeight: node.closest("section")?.getBoundingClientRect().height ?? 0,
    scrollHeight: node.scrollHeight,
  }));
  // The panel's translate transition can report 500.0000305 for a 500px box.
  // Allow sub-millipixel measurement noise, not an extra layout pixel.
  expect(geometry.panelMaxHeight).toBe("500px");
  expect(geometry.panelHeight).toBeLessThanOrEqual(500.001);
  expect(geometry.scrollHeight).toBeGreaterThan(geometry.clientHeight);

  // And it really scrolls, rather than being clipped at a fixed offset.
  await viewport.evaluate((node) => node.scrollTo(0, node.scrollHeight));
  expect(await viewport.evaluate((node) => node.scrollTop)).toBeGreaterThan(0);

  // The empty tab holds the tall tab's height, so the tabs row and the close
  // button never move out from under the pointer. It does not inherit its
  // scroll length, though: there is nothing there to scroll through.
  const panel = page.getByTestId("drive-transfer-panel");
  const panelHeight = () =>
    panel.evaluate((node) => node.getBoundingClientRect().height);
  // The height animates, so settle on it before reading it as the baseline.
  await expect.poll(panelHeight).toBeCloseTo(500, 3);
  await page.getByTestId("drive-transfer-tab-download").click();
  await expect(page.getByTestId("drive-transfer-tab-download")).toHaveText(
    "Download 0/0"
  );
  expect(await panelHeight()).toBeCloseTo(500, 3);
  expect(await viewport.evaluate((node) => node.scrollHeight - node.clientHeight)).toBe(
    0
  );
});

test("the filter menu pins the listing's device and version policy", async ({
  page,
}) => {
  await openDrive(page);

  // First level: what can be filtered, each entry showing its current value.
  const trigger = page.getByTestId("drive-filter-trigger");
  await trigger.click();
  const versionEntry = page.getByRole("menuitem", { name: "Version" });
  await expect(versionEntry).toContainText("Newest version");
  await versionEntry.hover();
  const versionPanel = page.getByTestId("drive-version-policy-select");
  await expect(versionPanel).toBeVisible();
  await versionPanel.getByRole("menuitemradio", { name: "Strict" }).click();
  await expect(trigger).toHaveAttribute("data-filtered", "true");
  await page.keyboard.press("Escape");

  // Pinning another origin filters the listing to that device's files.
  await page.getByTestId("drive-space-space-recordings").click();
  await expect(page.getByTestId("drive-file-drive-file-sound")).toBeVisible();
  await expect(page.getByTestId("drive-file-drive-file-session-take")).toBeVisible();

  await trigger.click();
  const deviceEntry = page.getByRole("menuitem", { name: "Device" });
  await expect(deviceEntry).toContainText("This Mac");
  await deviceEntry.hover();
  const devicePanel = page.getByTestId("drive-device-select");
  await expect(devicePanel).toBeVisible();
  await devicePanel.getByRole("menuitemradio", { name: "Studio NAS" }).click();
  await page.keyboard.press("Escape");
  await expect(page.getByTestId("drive-file-drive-file-sound")).toHaveCount(0);
  await expect(page.getByTestId("drive-file-drive-file-session-take")).toBeVisible();

  // A space with nothing to show renders the empty-folder state, whose call
  // to action opens the same picker as Add files.
  await page.getByTestId("drive-space-space-folder-a").click();
  await expect(page.getByText("Folder is empty")).toBeVisible();
  const fileChooser = page.waitForEvent("filechooser");
  await page.getByRole("button", { name: "Upload files" }).click();
  expect((await fileChooser).isMultiple()).toBe(true);
});

test("the header sorts the listing and select-all drives the selection bar", async ({
  page,
}) => {
  await openDrive(page);
  const rows = page.locator('[data-testid^="drive-file-drive-file-"]');

  // Name ascending is the resting sort.
  await expect(page.getByTestId("drive-sort-name")).toHaveAttribute(
    "data-sort-direction",
    "asc"
  );
  // Case-insensitive natural order: "logo-mark" < "Openai" < "Screenshot".
  await expect(rows.first()).toHaveAttribute(
    "data-testid",
    "drive-file-drive-file-logo-svg"
  );

  // Size ascending: the inline SVG (a few hundred bytes) is the smallest
  // fixture; the demo PNG is stored uncompressed and the PDF is 2.2 MB.
  await page.getByTestId("drive-sort-size").click();
  await expect(rows.first()).toHaveAttribute(
    "data-testid",
    "drive-file-drive-file-logo-svg"
  );
  await page.getByTestId("drive-sort-size").click();
  await expect(page.getByTestId("drive-sort-size")).toHaveAttribute(
    "data-sort-direction",
    "desc"
  );
  await expect(rows.first()).toHaveAttribute(
    "data-testid",
    "drive-file-drive-file-openai-pdf"
  );

  await page.getByRole("checkbox", { name: "Select all files" }).click({ force: true });
  const bar = page.getByTestId("drive-selection-bar");
  await expect(bar).toBeVisible();
  await expect(bar).toContainText("3 selected");
  await expect(page.getByTestId("drive-file-drive-file-openai-pdf")).toHaveAttribute(
    "data-selected",
    "true"
  );

  await bar.getByTestId("drive-clear-selection").click();
  await expect(bar).toHaveCount(0);

  // Download all: every selected file gets a transfer row, the toasts fold
  // into one summary, and the selection is spent once the batch starts.
  await page.getByRole("checkbox", { name: "Select all files" }).click({ force: true });
  const downloads: Promise<unknown>[] = [
    page.waitForEvent("download"),
    page.waitForEvent("download"),
  ];
  await page.getByTestId("drive-download-selected").click();
  await Promise.all(downloads);
  const completed = page.getByTestId("comma-drive-download-all");
  await expect(completed).toBeVisible();
  await expect(completed).toContainText("Download complete");
  await expect(completed).toContainText("2 files were downloaded; 1 could not be.");
  await expect(
    page.locator('[data-testid^="comma-drive-download-drive-transfer-"]')
  ).toHaveCount(1);
  await expect(page.getByTestId("drive-transfer-panel")).toBeVisible();
  await expect(page.getByTestId("drive-transfer-tab-download")).toHaveText(
    "Download 2/3"
  );
  // Completion is the settled state: the indefinite progress card must leave
  // the same notification surface, rather than remain beside the result.
  await expect(page.getByTestId("comma-drive-download-all-progress")).toHaveCount(0);
  await expect(page.getByText("Downloading 3 files…", { exact: true })).toHaveCount(0);
  await expect(completed).toBeVisible();
  // Updating the existing card retains its stack position. Expand the real
  // stack before closing it; a separate failed-file notification is still in front.
  await page.locator('[data-sonner-toast][data-front="true"]').hover();
  await expect(
    completed.locator("xpath=ancestor::li[@data-sonner-toast]")
  ).toHaveAttribute("data-expanded", "true");
  await page
    .getByTestId("comma-drive-download-all")
    .getByRole("button", { name: "Dismiss notification" })
    .click();
  await expect(page.getByTestId("comma-drive-download-all")).toHaveCount(0);
  await expect(bar).toHaveCount(0);
  await page.getByTestId("drive-transfer-close").click();

  await page.getByRole("checkbox", { name: "Select all files" }).click({ force: true });
  await page.getByTestId("drive-delete-selected").click();
  // The selection is confirmed as a list, so "3 files" is never a guess.
  const deleteDialog = page.getByRole("dialog", { name: "Delete 3 files?" });
  await expect(
    deleteDialog.getByTestId("drive-delete-files").getByRole("listitem")
  ).toHaveCount(3);
  await deleteDialog.getByRole("button", { name: "Delete" }).click();
  await expect(rows).toHaveCount(0);
  await expect(page.getByText("Folder is empty")).toBeVisible();
});

test("Ask Comma attaches the synced selection to the Comma assistant chat", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "drive-ask-comma@comma.local",
      token: "comma_sess_drive_ask_comma",
    });
    await page.goto("/#/drive");
    await expect(page.getByTestId("drive-route")).toBeVisible();

    await page
      .getByRole("checkbox", { name: "Select all files" })
      .click({ force: true });
    await expect(page.getByTestId("drive-selection-bar")).toContainText("3 selected");
    await page.getByTestId("drive-ask-comma-agent").click();

    // The synced screenshot and SVG ride along; the unsynced PDF is reported,
    // not lost silently.
    await expect(page).toHaveURL(/#\/$/);
    const content = page.getByRole("region", { name: "Content" });
    await expect(
      content.getByRole("button", { name: "Remove Screenshot 2026-08-29 at 10.47.png" })
    ).toBeVisible();
    await expect(
      content.getByRole("button", { name: "Remove logo-mark.svg" })
    ).toBeVisible();
    await expect(page.getByTestId("comma-drive-ask-comma-skipped")).toContainText(
      "1 files were left out"
    );

    // The same action on one row, from its own menu, attaches just that file:
    // the draft already holds one copy from the selection, so a second lands.
    const removeSvg = page
      .getByRole("region", { name: "Content" })
      .getByRole("button", { name: "Remove logo-mark.svg" });
    await expect(removeSvg).toHaveCount(1);
    await page.goto("/#/drive");
    await expect(page.getByTestId("drive-route")).toBeVisible();
    await page.getByTestId("drive-file-drive-file-logo-svg").click({ button: "right" });
    await page.getByRole("menuitem", { name: "Ask Comma" }).click();
    await expect(page).toHaveURL(/#\/$/);
    await expect(removeSvg).toHaveCount(2);
  } finally {
    await stub.close();
  }
});

test("the rail's own menu makes a folder, named in a dialog", async ({ page }) => {
  await openDrive(page);

  const rail = page.getByTestId("drive-space-rail");
  const railBox = (await rail.boundingBox())!;
  // Right-click the rail's blank space, well below the last row.
  await page.mouse.click(railBox.x + 40, railBox.y + railBox.height - 40, {
    button: "right",
  });
  await expect(page.getByRole("menu").getByRole("menuitem")).toHaveText([
    "New folder",
    "Upload folder",
  ]);
  await page.getByRole("menuitem", { name: "New folder" }).click();

  const dialog = page.getByRole("dialog", { name: "New folder" });
  await expect(dialog).toBeVisible();
  const name = dialog.getByRole("textbox");
  // The suggested name is selected, so typing replaces it.
  await expect(name).toHaveValue("New folder");
  await expect(dialog).toContainText("Location: ~/Drive");
  await name.fill("Folder A");
  await expect(dialog).toContainText("A folder with this name already exists.");
  await expect(dialog.getByRole("button", { name: "Create" })).toBeDisabled();
  await name.fill("Photos");
  await name.press("Enter");
  await expect(dialog).toBeHidden();

  // The new space is selected, empty, and synced from the start.
  const created = page.locator('[data-testid^="drive-space-drive-space-local-"]');
  await expect(created).toHaveText("Photos");
  await expect(created).toHaveAttribute("data-selected", "true");
  await expect(created).toHaveAttribute("data-synced", "true");
  await expect(page.getByText("Folder is empty")).toBeVisible();
});

test("a space's menu renames it and the local folder follows when synced", async ({
  page,
}) => {
  await openDrive(page);

  const folderA = page.getByTestId("drive-space-space-folder-a");
  await folderA.click({ button: "right" });
  const menu = page.getByRole("menu");
  await expect(menu.getByRole("menuitem")).toHaveText(["Rename", "Delete"]);
  // The sync switch sits above the items, off by default.
  const sync = page
    .getByTestId("drive-space-sync-row-space-folder-a")
    .getByRole("switch");
  await expect(sync).not.toBeChecked();
  await menu.getByRole("menuitem", { name: "Rename" }).click();

  const dialog = page.getByRole("dialog", { name: "Rename folder" });
  await expect(dialog.getByRole("textbox")).toHaveValue("Folder A");
  await expect(dialog.getByRole("button", { name: "Rename" })).toBeDisabled();
  await dialog.getByRole("textbox").fill("Folder B");
  await dialog.getByRole("button", { name: "Rename" }).click();
  await expect(folderA).toHaveText("Folder B");
  // Not synced: no local folder to rename, so no toast about one.
  await expect(page.getByTestId("comma-drive-folder-renamed")).toHaveCount(0);

  // Switch sync on from the row's own menu: the cluster's files land here.
  await folderA.click({ button: "right" });
  await page
    .getByTestId("drive-space-sync-row-space-folder-a")
    .getByRole("switch")
    .click({ force: true });
  await expect(page.getByTestId("comma-drive-space-sync-space-folder-a")).toContainText(
    "1 files copied to this Mac"
  );
  await page.keyboard.press("Escape");
  await expect(page.getByTestId("drive-space-unsynced-space-folder-a")).toHaveCount(0);

  // Renaming a synced space renames the local folder too, and says so.
  await folderA.click({ button: "right" });
  await page.getByRole("menuitem", { name: "Rename" }).click();
  await page
    .getByRole("dialog", { name: "Rename folder" })
    .getByRole("textbox")
    .fill("Folder C");
  await page
    .getByRole("dialog", { name: "Rename folder" })
    .getByRole("button", { name: "Rename" })
    .click();
  await expect(page.getByTestId("comma-drive-folder-renamed")).toContainText(
    "the local folder was renamed too"
  );
});

test("local sync starts from a folder picker and marks what is left out", async ({
  page,
}) => {
  await openDrive(page);

  // Off by default: every space carries the cloud-off mark.
  const trigger = page.getByTestId("drive-sync-trigger");
  await expect(trigger).toHaveAttribute("data-sync-enabled", "false");
  await expect(page.locator('[data-testid^="drive-space-unsynced-"]')).toHaveCount(3);

  await trigger.click();
  const panel = page.getByTestId("drive-sync-panel");
  await expect(panel).toContainText("Sync is off");
  await expect(panel).toContainText("~/Drive");
  // Opening the history hands the screen over to it, so the panel closes.
  await panel.getByRole("button", { name: "View" }).click();
  const empty = page.getByTestId("drive-sync-history-empty");
  await expect(empty).toBeVisible();
  await expect(panel).toBeHidden();
  // Wait for the dialog entrance animation before comparing tab geometry.
  await empty.evaluate(async (element) => {
    const animations: Animation[] = [];
    for (let node: Element | null = element; node; node = node.parentElement) {
      animations.push(...node.getAnimations());
    }
    await Promise.all(animations.map((animation) => animation.finished));
  });
  const allIcon = await empty.locator("svg").boundingBox();
  const allText = await empty.locator("p").boundingBox();
  expect(allIcon).not.toBeNull();
  expect(allText).not.toBeNull();
  await page.getByTestId("drive-sync-history-tab-failures").click();
  await expect(empty).toHaveText("Nothing has failed to sync.");
  await expect(page.getByTestId("drive-sync-history-retry-all")).toBeDisabled();
  await expect
    .poll(async () => {
      const icon = await empty.locator("svg").boundingBox();
      const text = await empty.locator("p").boundingBox();
      return icon && text
        ? {
            iconX: icon.x,
            iconY: icon.y,
            textCenterX: text.x + text.width / 2,
            textY: text.y,
          }
        : null;
    })
    .toEqual({
      iconX: allIcon!.x,
      iconY: allIcon!.y,
      textCenterX: allText!.x + allText!.width / 2,
      textY: allText!.y,
    });
  await page.keyboard.press("Escape");

  await trigger.click();
  await page.getByTestId("drive-sync-panel").getByRole("switch").click({ force: true });

  const picker = page.getByRole("dialog", { name: "Choose folders to sync" });
  await expect(picker).toBeVisible();
  await expect(picker).toContainText("Free on this Mac: 324 GB");
  // Leave Shared out.
  await picker
    .getByTestId("drive-sync-pick-space-shared")
    .getByRole("checkbox")
    .click({ force: true });
  await picker.getByRole("button", { name: "Start syncing" }).click();
  await expect(picker).toBeHidden();
  // Sync runs on its own from here, so a toast is what says it started.
  await expect(page.getByTestId("comma-drive-sync-started")).toContainText(
    "2 folders have local sync enabled: ~/Drive"
  );

  await expect(trigger).toHaveAttribute("data-sync-enabled", "true");
  await expect(page.locator('[data-testid^="drive-space-unsynced-"]')).toHaveCount(1);
  await expect(page.getByTestId("drive-space-unsynced-space-shared")).toBeVisible();

  // The history now lists what moved: a line per synced folder, plus a line
  // per file it brought down.
  await trigger.click();
  await page
    .getByTestId("drive-sync-panel")
    .getByRole("button", { name: "View" })
    .click();
  const history = page.getByTestId("drive-sync-history-dialog");
  await expect(history).toBeVisible();
  const rows = history.getByTestId("drive-sync-history-rows").getByRole("row");
  await expect(rows.filter({ hasText: "Cluster → this Mac" }).first()).toBeVisible();
  await expect(rows.filter({ hasText: "Folder added" })).toHaveCount(2);
  await expect(rows.filter({ hasText: "File added" }).first()).toBeVisible();

  // sound.wav exists here and on the cluster in different versions, so sync
  // left it alone and the failures tab is where that shows up.
  await history.getByTestId("drive-sync-history-tab-failures").click();
  await expect(
    history.getByTestId("drive-sync-history-rows").getByRole("row")
  ).toHaveCount(1);
  await expect(history).toContainText("your copy was kept");

  // Retrying takes the cluster's version, which settles the record.
  await history.getByTestId("drive-sync-history-retry-all").click();
  await expect(history.getByTestId("drive-sync-history-empty")).toBeVisible();
  await expect(history.getByTestId("drive-sync-history-retry-all")).toBeDisabled();

  // The panel's own close control, not the dialog's default one. It sits in
  // the dialog's corner, outside the content column.
  await page.getByTestId("drive-sync-history-close").click();
  await expect(history).toBeHidden();
});

test("Add files offers a folder pick; the folder becomes a row, entered by single click and left by breadcrumb", async ({
  page,
}) => {
  await openDrive(page);

  await page.getByTestId("drive-add-files").click();
  await expect(page.getByRole("menu").getByRole("menuitem")).toHaveText([
    "Upload folder",
    "Upload files",
  ]);
  await page.getByRole("menuitem", { name: "Upload folder" }).click();

  // A directory pick hands back every file inside with its path in the folder.
  const dir = await mkdtemp(join(tmpdir(), "comma-drive-e2e-"));
  await mkdir(join(dir, "clips", "raw"), { recursive: true });
  await writeFile(join(dir, "clips", "raw", "take-1.txt"), "a");
  await writeFile(join(dir, "clips", "cover.txt"), "b");
  try {
    await page.getByTestId("drive-folder-input").setInputFiles(dir);
    // The picked folder's name is the top-level folder row.
    const folderName = basename(dir);
    const folderRow = page.getByTestId(`drive-folder-${folderName}`);
    await expect(folderRow).toBeVisible();
    await expect(folderRow).toContainText("2 items");
    await expect(page.getByTestId("drive-breadcrumb-current")).toHaveText("Folder A");

    // A folder's checkbox selects everything under it, and reads back as
    // all / some / none of its contents.
    await folderRow.getByRole("checkbox").click({ force: true });
    await expect(page.getByTestId("drive-selection-bar")).toContainText("2 selected");
    await expect(folderRow).toHaveAttribute("data-selected", "true");
    await expect(page.getByTestId("drive-breadcrumb-current")).toHaveText("Folder A");
    // The upload opened the transfer panel over the bar's corner; close it first.
    await page.getByTestId("drive-transfer-close").click();
    await page.getByTestId("drive-clear-selection").click();
    await expect(folderRow).not.toHaveAttribute("data-selected", "true");

    // One click steps in; the breadcrumb grows and files at that level show.
    await folderRow.click();
    await expect(page.getByTestId("drive-breadcrumb-current")).toHaveText(folderName);
    await page.getByTestId("drive-folder-clips").click();
    await expect(page.getByTestId("drive-breadcrumb-current")).toHaveText("clips");
    await expect(page.getByTestId("drive-folder-raw")).toBeVisible();
    await expect(page.getByTestId(/^drive-file-drive-file-local-/)).toHaveText(
      /cover\.txt/
    );

    // The breadcrumb walks back without touching the app's route.
    await page
      .getByTestId("drive-breadcrumb")
      .getByRole("button", { name: "Folder A" })
      .click();
    await expect(page.getByTestId("drive-breadcrumb-current")).toHaveText("Folder A");
    await expect(folderRow).toBeVisible();
    await expect(page).toHaveURL(/#\/drive$/);
  } finally {
    await rm(dir, { force: true, recursive: true });
  }
});

test("dropping files on the list uploads them into the open folder", async ({
  page,
}) => {
  await openDrive(page);
  const pane = page.getByTestId("drive-file-pane");
  const overlay = pane.getByTestId("ai-input-drop-overlay");
  const transfer = await page.evaluateHandle(() => {
    const dataTransfer = new DataTransfer();
    dataTransfer.items.add(
      new File(["dropped payload"], "dropped.txt", { type: "text/plain" })
    );
    return dataTransfer;
  });

  // The overlay follows the drag in and out, counting nested enter/leave pairs.
  await pane.dispatchEvent("dragenter", { dataTransfer: transfer });
  await expect(overlay).toHaveAttribute("data-drop-active", "true");
  await expect(overlay).toContainText("Drop files here");
  await expect(overlay).toContainText("Folder A");
  await pane.dispatchEvent("dragleave", { dataTransfer: transfer });
  await expect(overlay).not.toHaveAttribute("data-drop-active", "true");

  await pane.dispatchEvent("dragenter", { dataTransfer: transfer });
  await pane.dispatchEvent("drop", { dataTransfer: transfer });
  await expect(overlay).not.toHaveAttribute("data-drop-active", "true");
  await expect(page.getByTestId("drive-transfer-panel")).toBeVisible();
  await expect(page.getByTestId("drive-transfer-tab-upload")).toHaveText("Upload 1/1");
  await expect(page.getByTestId(/^drive-file-drive-file-local-/)).toHaveText(
    /dropped\.txt/
  );
});

test("reopening the transfer panel after a dismissal starts at the new height", async ({
  page,
}) => {
  await openDrive(page);
  await page.getByTestId("drive-add-files").click();
  await page.getByRole("menuitem", { name: "Upload files" }).click();
  await page
    .locator('input[type="file"]')
    .first()
    .setInputFiles([
      { buffer: Buffer.from("one"), mimeType: "text/plain", name: "one.txt" },
      { buffer: Buffer.from("two"), mimeType: "text/plain", name: "two.txt" },
      { buffer: Buffer.from("three"), mimeType: "text/plain", name: "three.txt" },
    ]);
  const panel = page.getByTestId("drive-transfer-panel");
  const body = panel.getByTestId("drive-transfer-body");
  await expect(panel.getByTestId("drive-transfer-tab-upload")).toHaveText("Upload 3/3");
  const rowsHeight = await body.evaluate(
    (element) => element.getBoundingClientRect().height
  );

  // Close marks the finished rows for removal; the next open drops them. The
  // panel must come back at the empty pane's height from its first frame,
  // not at the rows' height and then shrink.
  await panel.getByTestId("drive-transfer-close").click();
  await expect(panel).toBeHidden();
  const frames = await page.evaluate(async () => {
    document
      .querySelector<HTMLElement>('[data-testid="drive-transfer-toggle"]')
      ?.click();
    const bodyElement = document.querySelector<HTMLElement>(
      '[data-testid="drive-transfer-body"]'
    );
    const heights: number[] = [];
    for (let frame = 0; frame < 4; frame += 1) {
      await new Promise((resolve) => requestAnimationFrame(resolve));
      heights.push(bodyElement ? bodyElement.getBoundingClientRect().height : -1);
    }
    return heights;
  });
  await expect(panel).toBeVisible();
  await expect(panel.getByTestId("drive-transfer-tab-upload")).toHaveText("Upload 0/0");
  const emptyHeight = await body.evaluate(
    (element) => element.getBoundingClientRect().height
  );
  expect(emptyHeight).toBeLessThan(rowsHeight);
  for (const height of frames) expect(height).toBe(emptyHeight);
});

test("dragging the right sidebar hides the folder rail only while the selection bar needs its width", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1800, height: 1000 });
  await openDrive(page);
  const sidebar = page.getByTestId("chat-sidebar");
  if ((await sidebar.getAttribute("data-open")) !== "true") {
    await page
      .getByRole("button", { name: "Toggle chat sidebar", exact: true })
      .click();
  }
  const handle = sidebar.getByRole("separator", { name: "Resize chat sidebar" });
  await expect(handle).toBeVisible();
  await handle.hover();
  const rail = page.getByTestId("drive-space-rail");
  await expect(rail).toBeVisible();
  await page.getByRole("checkbox", { name: "Select all files" }).click({ force: true });
  const bar = page.getByTestId("drive-selection-bar");
  await expect(bar).toBeVisible();
  const routeBox = (await page.getByTestId("drive-route").boundingBox())!;
  const railBox = (await rail.boundingBox())!;
  const barBox = (await bar.boundingBox())!;
  const handleBox = (await handle.boundingBox())!;
  const drag = async (x: number) => {
    // Locator hover waits for the moving sidebar handle to settle.
    await handle.hover();
    const box = (await handle.boundingBox())!;
    await page.mouse.down();
    await page.mouse.move(x, box.y + box.height / 2, { steps: 12 });
    await page.mouse.up();
  };
  // Observe the fold commit before a delayed transition event can arrive
  // after the animation finishes, then inspect the real transition halfway.
  await page.locator(".comma-drive-space-rail-slot").evaluate((slot) => {
    const observer = new MutationObserver(() => {
      if (slot.getAttribute("data-folded") !== "true") return;
      observer.disconnect();
      const railElement = slot.querySelector("nav")!;
      const animations = [...slot.getAnimations(), ...railElement.getAnimations()];
      const times = animations.map((animation) => animation.currentTime);
      for (const animation of animations) {
        const duration = Number(animation.effect?.getTiming().duration);
        if (duration > 0) animation.currentTime = duration / 2;
      }
      slot.setAttribute(
        "data-motion-sample",
        JSON.stringify({
          width: slot.getBoundingClientRect().width,
          contentWidth: railElement.getBoundingClientRect().width,
          opacity: Number(getComputedStyle(railElement).opacity),
          transform: getComputedStyle(railElement).transform,
        })
      );
      animations.forEach((animation, index) => {
        animation.currentTime = times[index]!;
      });
    });
    observer.observe(slot, { attributes: true, attributeFilter: ["data-folded"] });
  });
  // Cross the measured fit boundary without changing the outer viewport.
  await drag(routeBox.x + railBox.width + barBox.width - 40);
  await expect(rail).toBeHidden();
  const sample = JSON.parse(
    (await page
      .locator(".comma-drive-space-rail-slot")
      .getAttribute("data-motion-sample"))!
  );
  expect(sample.width).toBeGreaterThan(0);
  expect(sample.width).toBeLessThan(railBox.width);
  expect(sample.opacity).toBeGreaterThan(0);
  expect(sample.opacity).toBeLessThan(1);
  expect(sample.contentWidth).toBeGreaterThan(railBox.width * 0.97);
  expect(sample.transform).not.toBe("none");
  await expect(bar).toContainText("3 selected");
  await expect
    .poll(async () => {
      const pane = (await page.getByTestId("drive-file-pane").boundingBox())!;
      const toolbar = (await bar.boundingBox())!;
      return toolbar.x >= pane.x && toolbar.x + toolbar.width <= pane.x + pane.width;
    })
    .toBe(true);
  // The recovered list width must not cause a hide/show feedback loop.
  expect(
    await page.evaluate(async () => {
      for (let frame = 0; frame < 6; frame++) {
        await new Promise(requestAnimationFrame);
        if (
          document
            .querySelector(".comma-drive-space-rail-slot")
            ?.getAttribute("data-folded") !== "true"
        )
          return false;
      }
      return true;
    })
  ).toBe(true);
  await drag(handleBox.x + handleBox.width / 2);
  await expect(rail).toBeVisible();
  await expect(bar).toContainText("3 selected");
  await drag(routeBox.x + railBox.width + barBox.width - 40);
  await expect(rail).toBeHidden();
  await page.getByTestId("drive-clear-selection").click();
  await expect(bar).toHaveCount(0);
  await expect(rail).toBeVisible();
  for (const preference of ["system", "app"]) {
    await page.emulateMedia({
      reducedMotion: preference === "system" ? "reduce" : "no-preference",
    });
    if (preference === "app") {
      // Change the persisted preference through the provider's storage input.
      // Mutating its output attribute can be overwritten by a pending media
      // change and makes the next iteration's readiness check pass too early.
      await page.evaluate(() => {
        const key = "comma.client-settings";
        const settings = JSON.parse(localStorage.getItem(key) ?? "{}");
        localStorage.setItem(
          key,
          JSON.stringify({
            ...settings,
            appearance: { ...settings.appearance, reducedMotion: true },
          })
        );
        window.dispatchEvent(new StorageEvent("storage", { key }));
      });
    }
    await expect(page.locator("html")).toHaveAttribute(
      "data-comma-reduced-motion",
      "true"
    );
    await page
      .getByRole("checkbox", { name: "Select all files" })
      .click({ force: true });
    await expect(rail).toBeHidden();
    await expect(page.locator(".comma-drive-space-rail-slot")).toHaveCSS(
      "transition-duration",
      "0s"
    );
    await expect(rail).toHaveCSS("transform", "none");
    await page.getByTestId("drive-clear-selection").click();
    await expect(rail).toBeVisible();
  }
});

test("Drive opens PDF, Markdown, HTML and media through the same file reader as chat", async ({
  page,
}) => {
  await openDrive(page);
  const attempts: string[] = [];
  await page.route("**/preview-invalid.example/**", (route) => {
    attempts.push(route.request().url());
    return route.abort();
  });
  await page.getByTestId("drive-add-files").click();
  await page.getByRole("menuitem", { name: "Upload files" }).click();
  await page
    .locator('input[type="file"]')
    .first()
    .setInputFiles([
      { name: "shared-reader.pdf", mimeType: "application/pdf", buffer: twoPagePdf() },
      {
        name: "shared-reader.md",
        mimeType: "text/markdown",
        buffer: Buffer.from(
          "# Shared Markdown reader\n![blocked](https://preview-invalid.example/image)"
        ),
      },
      {
        name: "shared-reader.html",
        mimeType: "text/html",
        buffer: Buffer.from(
          '<h1>Shared HTML reader</h1><script>parent.drivePreviewExecuted=true</script><img src="https://preview-invalid.example/html">'
        ),
      },
      {
        name: "shared-reader.mp3",
        mimeType: "audio/mpeg",
        buffer: await readFile(
          new URL(
            "../../ui/src/components/chat-panel/assets/generated-audio-preview.mp3",
            import.meta.url
          )
        ),
      },
      {
        name: "shared-reader.mp4",
        mimeType: "video/mp4",
        buffer: await readFile(
          new URL("./fixtures/file-preview/sample.mp4", import.meta.url)
        ),
      },
    ]);
  await page.getByTestId("drive-transfer-close").click();
  const select = (name: string) =>
    page
      .getByTestId(/^drive-file-drive-file-local-/)
      .filter({ hasText: name })
      .click();
  const panel = page.getByTestId("drive-preview-panel");
  await select("shared-reader.pdf");
  await expectCompactPreviewToolbar(panel, "shared-reader.pdf");
  await expect(panel.getByText("Page 1 of 2", { exact: true })).toBeVisible();
  await panel.getByRole("button", { name: "Next page", exact: true }).click();
  await expect(panel.getByText("Page 2 of 2", { exact: true })).toBeVisible();
  await select("shared-reader.md");
  await expect(
    panel.getByRole("heading", { name: "Shared Markdown reader" })
  ).toBeVisible();
  await select("shared-reader.html");
  await expect(
    panel
      .frameLocator('[data-testid="file-preview-html"]')
      .getByRole("heading", { name: "Shared HTML reader" })
  ).toBeVisible();
  expect(
    await page.evaluate(() => Reflect.get(window, "drivePreviewExecuted"))
  ).toBeUndefined();
  expect(attempts).toEqual([]);
  await select("shared-reader.mp3");
  await expect
    .poll(() =>
      panel.locator("audio").evaluate((element: HTMLAudioElement) => element.readyState)
    )
    .toBeGreaterThan(0);
  await select("shared-reader.mp4");
  await expect
    .poll(() =>
      panel.locator("video").evaluate((element: HTMLVideoElement) => element.videoWidth)
    )
    .toBeGreaterThan(0);
});
