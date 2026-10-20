import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";
import { hostedDriveRoutes } from "./fixtures/hosted-drive";

/**
 * The composer's "@" menu lists Drive: the newest files, "View more" into the
 * browse panel (search, sections per folder), and a pick that lands as an
 * attachment. Runs on the Workspace's hosted Drive the web reads, with more
 * than one folder and more than five files.
 */
const folders: Record<string, string[]> = {
  handoff: ["home-v4.fig", "rail-spec.pdf", "tokens.json", "icons.zip"],
  "drafts/q3": ["q3-plan.md", "budget.xlsx", "okrs.docx"],
};

test("mentions Drive files through @ and attaches the chosen one", async ({ page }) => {
  const files = Object.entries(folders).flatMap(([folder, names]) =>
    names.map((name, index) => ({
      path: `${folder}/${name}`,
      bytes: Buffer.from(`${name}\n`),
      modifiedAt: 1_788_000_000 + index,
    }))
  );
  const stub = await startChatSmokeStub({
    holdAssistantReply: true,
    extraRoutes: hostedDriveRoutes(files),
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "composer-drive-mention@comma.local",
      token: "comma_sess_composer_drive_mention",
    });
    await page.goto("/#/");
    const content = page.getByRole("region", { name: "Content" });
    const prompt = content.getByRole("textbox", { name: "AI prompt" });
    await prompt.click();
    await page.keyboard.type("Summarize @");

    const list = page.getByRole("listbox", { name: "Mentions" });
    await expect(list).toBeVisible();
    // Section order is part of the surface. This workspace has no Task, Routine
    // or Plugin rows, so exactly "Add" and "Drive" render, and Add comes first.
    const sectionLabels = await list
      .getByRole("group")
      .evaluateAll((groups) =>
        groups.map((group) => group.firstElementChild?.textContent ?? "")
      );
    expect(sectionLabels).toEqual(["Add", "Drive"]);
    const drive = list.getByRole("group").filter({ hasText: "Drive" });
    // Seven files exist; the menu shows five and the door to the rest.
    await expect(drive.getByRole("option")).toHaveCount(6);
    const viewMore = drive.getByRole("option", { name: "View more" });
    await expect(viewMore).toBeVisible();

    // ArrowRight on "View more" steps into the panel with its search focused.
    for (let step = 0; step < 6; step += 1) await page.keyboard.press("ArrowDown");
    await expect(viewMore).toHaveAttribute("aria-selected", "true");
    await page.keyboard.press("ArrowRight");
    const panel = page.getByRole("dialog", { name: "Drive" });
    const search = panel.getByRole("combobox", { name: "Drive" });
    await expect(search).toBeFocused();
    await expect(panel.getByRole("option")).toHaveCount(7);
    await expect(panel.getByText(/drafts \/ q3$/)).toBeVisible();

    await page.keyboard.type("q3");
    await expect(panel.getByRole("option")).toHaveCount(3);
    await expect(panel.getByRole("option", { name: /q3-plan/ })).toHaveAttribute(
      "aria-selected",
      "true"
    );
    await page.keyboard.type("zz");
    await expect(page.getByTestId("ai-input-menu-browse-no-results")).toHaveText(
      "No results found"
    );

    // Escape steps back to the list with the trigger intact; the chevron does too.
    await page.keyboard.press("Escape");
    await expect(list).toBeVisible();
    await expect(prompt).toHaveText("Summarize @");
    await viewMore.click();
    await expect(search).toBeFocused();
    await panel.getByRole("button", { name: "Back" }).click();
    await expect(list).toBeVisible();
    await expect(prompt).toBeFocused();

    // Picking a file attaches it and leaves no trigger text behind.
    await viewMore.click();
    await panel.getByRole("option", { name: /rail-spec\.pdf/ }).click();
    await expect(
      content.getByLabel("Attachments").getByText("rail-spec.pdf")
    ).toBeVisible();
    await expect(list).toBeHidden();
    await expect(prompt).toHaveText("Summarize ");
  } finally {
    await stub.close();
  }
});
