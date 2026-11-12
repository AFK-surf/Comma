import { expect, type Locator } from "@playwright/test";

/** Both entry points retain Drive's compact reader chrome, not an attachment card. */
export async function expectCompactPreviewToolbar(panel: Locator, fileName: string) {
  const toolbar = panel.getByTestId("file-preview-toolbar");
  await expect(toolbar).toBeVisible();
  await expect(panel.locator(".chat-panel-file")).toHaveCount(0);
  await expect(toolbar.getByRole("heading", { level: 2 })).toHaveText(fileName);
  await expect.poll(async () => (await toolbar.boundingBox())?.height).toBe(44);
  const download = toolbar.getByRole("button", {
    name: `Download ${fileName}`,
    exact: true,
  });
  await expect(download).toBeVisible();
  await expect(download).toHaveText("");
  // A browser lists no operating-system apps, so the button downloads without a menu.
  await expect(download).not.toHaveAttribute("aria-haspopup");
  return { toolbar, download };
}
