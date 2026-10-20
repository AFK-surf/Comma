import { expect, test, type Page } from "@playwright/test";
import { twoPagePdf } from "./fixtures/file-preview/pdf";
import { expectCompactPreviewToolbar } from "./fixtures/file-preview/toolbar";
import {
  hostedDriveRoutes,
  solidPng,
  type HostedDriveFile,
} from "./fixtures/hosted-drive";
import { readFile } from "node:fs/promises";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// The web's Drive is the Workspace's hosted Drive, read-only, served here by the chat stub. What only a device's
// node does (uploads, sync, versions, the device filter) runs against Main's node in
// apps/electron/e2e/drive-node.spec.ts.

const driveFiles: HostedDriveFile[] = [
  {
    path: "Screenshot 2026-08-29 at 10.47.png",
    bytes: solidPng(640, 400, [32, 120, 220]),
  },
  {
    path: "logo-mark.svg",
    bytes: Buffer.from(
      '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><circle cx="32" cy="32" r="28" fill="#1f6feb"/></svg>'
    ),
  },
  { path: "Openai.pdf", bytes: twoPagePdf() },
];

const stubs: { close(): Promise<void> }[] = [];
test.afterEach(async () => {
  await Promise.all(stubs.splice(0).map((stub) => stub.close()));
});

const openDrive = async (
  page: Page,
  {
    files = driveFiles,
    missing = [],
  }: { files?: readonly HostedDriveFile[]; missing?: readonly string[] } = {}
) => {
  const stub = await startChatSmokeStub({
    extraRoutes: hostedDriveRoutes(files, { missing }),
  });
  stubs.push(stub);
  await installBrowserTestSession(page, {
    apiBaseUrl: stub.baseUrl,
    email: "drive-e2e@example.com",
    token: "comma_sess_drive_e2e",
  });
  await page.goto("/#/drive");
  await expect(page.getByTestId("drive-route")).toBeVisible();
};

const screenshotRow = (page: Page) =>
  page.getByTestId("drive-file-synch:comma-drive:Screenshot 2026-08-29 at 10.47.png");

test("file timestamps stay clear of reserved actions at wide and narrow list widths", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1800, height: 1000 });
  await openDrive(page);
  const row = page.getByTestId(
    "drive-file-synch:comma-drive:Screenshot 2026-08-29 at 10.47.png"
  );
  const modified = page.getByTestId(
    "drive-file-modified-synch:comma-drive:Screenshot 2026-08-29 at 10.47.png"
  );
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

test("the web rail opens Drive, read-only, with nothing to sync or filter", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ extraRoutes: hostedDriveRoutes(driveFiles) });
  stubs.push(stub);
  await installBrowserTestSession(page, {
    apiBaseUrl: stub.baseUrl,
    email: "drive-e2e@example.com",
    token: "comma_sess_drive_e2e",
  });
  await page.goto("/#/");
  await page
    .locator('nav[aria-label="Primary"]')
    .getByRole("link", { name: "Drive" })
    .click();
  await expect(page.getByTestId("drive-route")).toBeVisible();
  // The header row is the toolbar itself.
  await expect(page.getByRole("heading", { level: 1 })).toHaveCount(0);

  // The web reads the Workspace's Drive: no device copies to pick, no folder
  // to sync, nothing to add.
  await expect(page.getByTestId("drive-filter-trigger")).toHaveCount(0);
  await expect(page.getByTestId("drive-sync-trigger")).toHaveCount(0);
  await expect(page.getByTestId("drive-transfer-toggle")).toBeVisible();
  await expect(page.getByTestId("drive-add-files")).toBeDisabled();

  await expect(page.getByTestId("drive-space-comma-drive")).toHaveAttribute(
    "data-selected",
    "true"
  );
  await expect(screenshotRow(page)).toBeVisible();
  await page
    .getByTestId("drive-file-synch:comma-drive:Openai.pdf")
    .click({ button: "right" });
  await expect(page.getByRole("menu").getByRole("menuitem")).toHaveText([
    "Ask Comma",
    "Download",
  ]);
});

test("a previewed file becomes a tab of the shell's one right sidebar", async ({
  page,
}) => {
  await openDrive(page);

  const pdfRow = page.getByTestId("drive-file-synch:comma-drive:Openai.pdf");
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
  await expect(
    page.getByTestId("drive-preview-panel").getByText("Page 1 of 2", { exact: true })
  ).toBeVisible();

  const screenshot = screenshotRow(page);
  await screenshot.click();
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
  await expect(metadata).toContainText("Drive");
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
  await screenshot
    .getByRole("checkbox", { name: /Select Screenshot/ })
    .click({ force: true });
  await expect(screenshot).toHaveAttribute("data-selected", "true");
  await expect(page.getByRole("tab")).toHaveCount(2);

  // The close affordance arms on tab hover (pointer-events gate in CSS).
  await previewTab.hover();
  await page.getByRole("button", { name: "Close Openai.pdf" }).click();
  await expect(page.getByRole("tab", { name: "Openai.pdf" })).toHaveCount(0);
  await expect(screenshotTab).toHaveAttribute("aria-selected", "true");
  await expect(sidebar).toHaveAttribute("data-open", "true");

  await screenshotTab.hover();
  await page.getByRole("button", { name: `Close ${fileName}` }).click();
  await expect(sidebar).toHaveAttribute("data-open", "false");
  await expect(page.getByTestId("chat-sidebar-toggle")).toHaveAttribute(
    "aria-expanded",
    "false"
  );
  await expect.poll(async () => (await sidebar.boundingBox())?.width ?? 0).toBe(0);

  // With the selection spent, a click opens the file again.
  await page.getByTestId("drive-clear-selection").click();
  await pdfRow.click();
  await expect(sidebar).toHaveAttribute("data-open", "true");
  await expect(previewTab).toHaveAttribute("aria-selected", "true");
});

test("a click joins the selection under way instead of opening the file", async ({
  page,
}) => {
  await openDrive(page);
  const pdfRow = page.getByTestId("drive-file-synch:comma-drive:Openai.pdf");
  const pngRow = page.getByTestId(
    "drive-file-synch:comma-drive:Screenshot 2026-08-29 at 10.47.png"
  );
  const svgRow = page.getByTestId("drive-file-synch:comma-drive:logo-mark.svg");

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
    await page
      .getByTestId("drive-file-synch:comma-drive:Screenshot 2026-08-29 at 10.47.png")
      .click();
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

// What a transfer does (failures, retries, dismissal) is the core's: packages/core/test/drive-transfers.test.ts.
test("transfer panel shows empty states, and a download toasts once and lands in its tab", async ({
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

  // Downloading a file completes through the browser adapter and toasts.
  await page.getByTestId("drive-transfer-toggle").click();
  await expect(panel).toBeVisible();
  const downloadPromise = page.waitForEvent("download");
  await screenshotRow(page)
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
  await expect(page.locator('[data-testid^="comma-drive-download-"]')).toHaveCount(1);
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
});

test("a transfer list longer than the panel scrolls inside it", async ({ page }) => {
  await openDrive(page, {
    files: Array.from({ length: 16 }, (_unused, index) => ({
      path: `bulk-${String(index).padStart(2, "0")}.txt`,
      bytes: Buffer.from(`payload ${index}`),
    })),
  });

  // Sixteen rows is well past the panel's cap, so the panel has to stop
  // growing and hand the overflow to its own viewport rather than running
  // past its rounded edge.
  await page.getByRole("checkbox", { name: "Select all files" }).click({ force: true });
  // Download all opens the panel on its rows.
  await page.getByTestId("drive-download-selected").click();
  await page.getByTestId("drive-transfer-tab-download").click();
  await expect(page.getByTestId("drive-transfer-tab-download")).toHaveText(
    "Download 16/16"
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
  await page.getByTestId("drive-transfer-tab-upload").click();
  await expect(page.getByTestId("drive-transfer-tab-upload")).toHaveText("Upload 0/0");
  expect(await panelHeight()).toBeCloseTo(500, 3);
  expect(await viewport.evaluate((node) => node.scrollHeight - node.clientHeight)).toBe(
    0
  );
});

test("Ask Comma attaches the readable selection to the Comma assistant chat", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    extraRoutes: hostedDriveRoutes(driveFiles, { missing: ["Openai.pdf"] }),
  });
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

    // The screenshot and SVG ride along; the PDF the server no longer has is
    // reported, not lost silently.
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
    await page
      .getByTestId("drive-file-synch:comma-drive:logo-mark.svg")
      .click({ button: "right" });
    await page.getByRole("menuitem", { name: "Ask Comma" }).click();
    await expect(page).toHaveURL(/#\/$/);
    await expect(removeSvg).toHaveCount(2);
  } finally {
    await stub.close();
  }
});

test("a folder of the Drive is a row, entered by single click and left by breadcrumb", async ({
  page,
}) => {
  await openDrive(page, {
    files: [
      ...driveFiles,
      { path: "clips/raw/take-1.txt", bytes: Buffer.from("a") },
      { path: "clips/cover.txt", bytes: Buffer.from("b") },
    ],
  });
  const folderRow = page.getByTestId("drive-folder-clips");
  await expect(folderRow).toBeVisible();
  await expect(folderRow).toContainText("2 items");
  await expect(page.getByTestId("drive-breadcrumb-current")).toHaveText("Drive");

  // A folder's checkbox selects everything under it, and reads back as
  // all / some / none of its contents.
  await folderRow.getByRole("checkbox").click({ force: true });
  await expect(page.getByTestId("drive-selection-bar")).toContainText("2 selected");
  await expect(folderRow).toHaveAttribute("data-selected", "true");
  await expect(page.getByTestId("drive-breadcrumb-current")).toHaveText("Drive");
  await page.getByTestId("drive-clear-selection").click();
  await expect(folderRow).not.toHaveAttribute("data-selected", "true");

  // One click steps in; the breadcrumb grows and files at that level show.
  await folderRow.click();
  await expect(page.getByTestId("drive-breadcrumb-current")).toHaveText("clips");
  await expect(page.getByTestId("drive-folder-raw")).toBeVisible();
  await expect(
    page.getByTestId("drive-file-synch:comma-drive:clips/cover.txt")
  ).toBeVisible();

  // The breadcrumb walks back without touching the app's route.
  await page
    .getByTestId("drive-breadcrumb")
    .getByRole("button", { name: "Drive" })
    .click();
  await expect(page.getByTestId("drive-breadcrumb-current")).toHaveText("Drive");
  await expect(folderRow).toBeVisible();
  await expect(page).toHaveURL(/#\/drive$/);
});

test("reopening the transfer panel after a dismissal starts at the new height", async ({
  page,
}) => {
  await openDrive(page);
  await page.getByRole("checkbox", { name: "Select all files" }).click({ force: true });
  await page.getByTestId("drive-download-selected").click();
  const panel = page.getByTestId("drive-transfer-panel");
  const body = panel.getByTestId("drive-transfer-body");
  await panel.getByTestId("drive-transfer-tab-download").click();
  await expect(panel.getByTestId("drive-transfer-tab-download")).toHaveText(
    "Download 3/3"
  );
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
  await expect(panel.getByTestId("drive-transfer-tab-download")).toHaveText(
    "Download 0/0"
  );
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
      .getByTestId("comma-window-bar")
      .getByRole("button", { name: "New tab", exact: true })
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
  await openDrive(page, {
    files: [
      { path: "shared-reader.pdf", bytes: twoPagePdf() },
      {
        path: "shared-reader.md",
        bytes: Buffer.from(
          "# Shared Markdown reader\n![blocked](https://preview-invalid.example/image)"
        ),
      },
      {
        path: "shared-reader.html",
        bytes: Buffer.from(
          '<h1>Shared HTML reader</h1><script>parent.drivePreviewExecuted=true</script><img src="https://preview-invalid.example/html">'
        ),
      },
      {
        path: "shared-reader.mp3",
        bytes: await readFile(
          new URL(
            "../../ui/src/components/chat-panel/assets/generated-audio-preview.mp3",
            import.meta.url
          )
        ),
      },
      {
        path: "shared-reader.mp4",
        bytes: await readFile(
          new URL("./fixtures/file-preview/sample.mp4", import.meta.url)
        ),
      },
    ],
  });
  const attempts: string[] = [];
  await page.route("**/preview-invalid.example/**", (route) => {
    attempts.push(route.request().url());
    return route.abort();
  });
  const select = (name: string) =>
    page.getByTestId(`drive-file-synch:comma-drive:${name}`).click();
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
