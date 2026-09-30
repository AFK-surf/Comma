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
  // These browser scenarios do not claim to list native operating-system apps.
  await expect(
    toolbar.getByRole("button", { name: "Open in", exact: true })
  ).toHaveCount(0);
  await expect(toolbar.getByRole("button", { name: "Open", exact: true })).toHaveCount(
    0
  );
  await expect(
    toolbar.getByRole("button", { name: "Choose application", exact: true })
  ).toHaveCount(0);
  return { toolbar, download };
}
