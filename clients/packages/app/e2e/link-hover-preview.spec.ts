import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeWorkspace, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

/**
 * Chat message links share the briefing's rich hover previews: hovering a
 * link whose shape the server can read (here a Slack permalink) upgrades the
 * plain anchor to the per-kind card, lazily fetched through the workspace
 * link-preview endpoint. While a context menu is open, a logical suspension
 * keeps those cards closed without changing native pointer targeting.
 */

const slackHref = "https://comma-local.slack.com/archives/C01234567/p1787900000000200";
const githubHref = "https://github.com/AFK-surf/Comma/pull/845";

const slackPreview = {
  kind: "slack_message",
  href: slackHref,
  channel: { id: "C01234567", name: "release" },
  author: { name: "dana", avatarUrl: null },
  text: "Are we go for the 0.9 release? Milo and I are waiting on your decision.",
  postedAt: 1_787_900_000_000,
};

test("hovering a rich chat link shows the Slack preview card", async ({ page }) => {
  const stub = await startChatSmokeStub({
    assistantReply: `请看 [deploy update](${slackHref}) 这条消息。`,
  });
  let previewRequests = 0;

  try {
    await page.route("**/recommendations/link-preview**", async (route) => {
      previewRequests += 1;
      const url = new URL(route.request().url());
      expect(url.pathname).toContain(`/v1/comma/workspaces/${chatSmokeWorkspace.id}/`);
      expect(url.searchParams.get("href")).toBe(slackHref);
      await route.fulfill({ json: slackPreview });
    });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "comma-link-preview@comma.local",
      token: "comma_sess_link_preview",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const prompt = content.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("看下 slack");
    await content.getByRole("button", { name: "Send" }).click();

    const link = content.getByRole("link", { name: "deploy update" });
    await expect(link).toBeVisible();

    // react-aria hover interactions (tooltips, hover cards) ignore synthetic
    // hovers until the page has seen a pointer press; the Send click above
    // established pointer modality. The preview is fetched lazily on first
    // hover, never on render.
    expect(previewRequests).toBe(0);

    // The decorator only wraps links once the stream is final, so the first
    // hover can land while the turn is still settling; retry from rest until
    // the card answers. Repeat hovers hit the preview cache, not the network.
    const card = page.getByTestId("recommendation-link-card");
    await expect(async () => {
      await prompt.hover();
      await link.hover();
      await expect(card).toBeVisible({ timeout: 1500 });
    }).toPass();
    await expect(card).toHaveAttribute("data-kind", "slack_message");
    await expect(card).toContainText("#release");
    await expect(card).toContainText("Are we go for the 0.9 release?");
    await expect(card).toContainText("dana");
    expect(previewRequests).toBe(1);
  } finally {
    await stub.close();
  }
});

test("a rich link opens on the card's skeleton and settles into the card", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    assistantReply: `请看 [deploy update](${slackHref}) 这条消息。`,
  });
  let releasePreview!: () => void;
  const heldPreview = new Promise<void>((resolve) => {
    releasePreview = resolve;
  });

  try {
    await page.route("**/recommendations/link-preview**", async (route) => {
      await heldPreview;
      await route.fulfill({ json: slackPreview });
    });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "comma-link-preview-skeleton@comma.local",
      token: "comma_sess_link_preview_skeleton",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const prompt = content.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("看下 slack");
    await content.getByRole("button", { name: "Send" }).click();

    const link = content.getByRole("link", { name: "deploy update" });
    await expect(link).toBeVisible();

    const skeleton = page.getByTestId("recommendation-link-card-skeleton");
    await expect(async () => {
      await prompt.hover();
      await link.hover();
      await expect(skeleton).toBeVisible({ timeout: 1500 });
    }).toPass();

    // The placeholder is the card it is about to become: same width, and the
    // bars sweep on the app's shared loading shine.
    const hoverCard = page.getByRole("tooltip");
    await expect(hoverCard).toHaveClass(/comma-recommendation-rich-link-hover-card/);
    await expect(skeleton.locator('[data-bar="title"]')).toHaveCSS(
      "animation-name",
      "comma-recommendation-link-card-shine"
    );
    await expect(page.getByTestId("recommendation-link-card")).toHaveCount(0);

    releasePreview();

    const card = page.getByTestId("recommendation-link-card");
    await expect(card).toBeVisible();
    await expect(card).toContainText("Are we go for the 0.9 release?");
    await expect(skeleton).toHaveCount(0);
    // The card settles over the skeleton through a short blur-fade instead of
    // a hard cut.
    await expect(card).toHaveCSS("transition-property", "opacity, filter, transform");
    await expect(card).toHaveCSS("transition-duration", "0.15s, 0.15s, 0.15s");
  } finally {
    await stub.close();
  }
});

test("an open link menu blocks hover previews without intercepting another right click", async ({
  page,
}) => {
  const spacer = Array.from(
    { length: 6 },
    (_, index) => `Context line ${index + 1}.`
  ).join("\n\n");
  const stub = await startChatSmokeStub({
    assistantReply: `[deploy update](${slackHref})\n\n${spacer}\n\n[pull request](${githubHref})`,
  });
  let previewRequests = 0;

  try {
    await page.setViewportSize({ width: 1280, height: 1000 });
    await page.route("**/recommendations/link-preview**", async (route) => {
      previewRequests += 1;
      await route.fulfill({ json: slackPreview });
    });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "comma-link-menu-native-target@comma.local",
      token: "comma_sess_link_menu_native_target",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const prompt = content.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("Show both links");
    await content.getByRole("button", { name: "Send" }).click();

    const firstLink = content.getByRole("link", { name: "deploy update" });
    const secondLink = content.getByRole("link", { name: "pull request" });
    await expect(firstLink).toBeVisible();
    await expect(secondLink).toBeVisible();
    await page.context().grantPermissions(["clipboard-read", "clipboard-write"], {
      origin: new URL(page.url()).origin,
    });

    await secondLink.evaluate((link) => {
      link.dataset.pointerDownEvents = "0";
      link.addEventListener(
        "pointerdown",
        () => {
          link.dataset.pointerDownEvents = String(
            Number(link.dataset.pointerDownEvents ?? "0") + 1
          );
        },
        { once: true }
      );
    });

    const menu = page.getByRole("menu", { name: "Link menu" });
    await firstLink.click({ button: "right" });
    await expect(menu).toBeVisible();

    // The real second link receives hover, but the open menu's logical
    // suspension prevents a preview request/card from appearing over it.
    await secondLink.hover();
    await page.waitForTimeout(600);
    expect(previewRequests).toBe(0);
    await expect(page.getByTestId("recommendation-link-card")).toHaveCount(0);
    await expect(menu).toBeVisible();

    // One native right click reaches the second link (including pointerdown)
    // and moves the menu's action target without a synthetic replay.
    const secondBox = await secondLink.boundingBox();
    expect(secondBox).not.toBeNull();
    await page.mouse.click(
      secondBox!.x + secondBox!.width / 2,
      secondBox!.y + secondBox!.height / 2,
      { button: "right" }
    );
    await expect(secondLink).toHaveAttribute("data-pointer-down-events", "1");
    await expect(menu).toBeVisible();
    await menu.getByRole("menuitem", { name: "Copy Link" }).click();
    await expect
      .poll(() => page.evaluate(() => navigator.clipboard.readText()))
      .toBe(githubHref);

    // The same native event chain reaches the composer and places its caret
    // before the composer opens its edit menu.
    await prompt.fill("alpha beta gamma");
    const composerTarget = await prompt.evaluate((editor) => {
      const rect = editor.getBoundingClientRect();
      const y = rect.top + rect.height / 2;
      const caretRangeFromPoint = document.caretRangeFromPoint?.bind(document);
      if (!caretRangeFromPoint) throw new Error("caretRangeFromPoint is unavailable");

      for (let x = rect.left + 8; x < rect.right - 8; x += 4) {
        const range = caretRangeFromPoint(x, y);
        if (range && editor.contains(range.startContainer) && range.startOffset > 0) {
          return { caretOffset: range.startOffset, x, y };
        }
      }
      throw new Error("could not resolve a non-zero composer caret position");
    });
    await prompt.evaluate((editor) => {
      const selection = window.getSelection();
      const text = editor.firstChild;
      if (!selection || !text) throw new Error("composer selection is unavailable");
      selection.removeAllRanges();
      selection.collapse(text, 0);
      editor.dataset.contextMenuEvents = "0";
      editor.dataset.pointerDownEvents = "0";
      editor.addEventListener(
        "pointerdown",
        () => {
          editor.dataset.pointerDownEvents = String(
            Number(editor.dataset.pointerDownEvents ?? "0") + 1
          );
        },
        { once: true }
      );
      editor.addEventListener(
        "contextmenu",
        () => {
          editor.dataset.contextMenuEvents = String(
            Number(editor.dataset.contextMenuEvents ?? "0") + 1
          );
        },
        { once: true }
      );
    });

    await firstLink.click({ button: "right" });
    await expect(menu).toBeVisible();
    await page.mouse.click(composerTarget.x, composerTarget.y, { button: "right" });
    await expect(menu).toHaveCount(0);
    await expect(prompt).toHaveAttribute("data-pointer-down-events", "1");
    await expect(prompt).toHaveAttribute("data-context-menu-events", "1");
    await expect(page.getByRole("menu", { name: "Edit menu" })).toBeVisible();
    expect(
      await prompt.evaluate((editor) => {
        const selection = window.getSelection();
        return selection && editor.contains(selection.anchorNode)
          ? selection.anchorOffset
          : null;
      })
    ).toBe(composerTarget.caretOffset);
    await expect(page.getByTestId("recommendation-link-card")).toHaveCount(0);

    // Closing the menu releases the suspension; ordinary hover preview behavior
    // resumes on the next pointer interaction.
    await page.keyboard.press("Escape");
    await prompt.click();
    await firstLink.hover();
    await expect(page.getByTestId("recommendation-link-card")).toBeVisible();
    expect(previewRequests).toBe(1);
  } finally {
    await stub.close();
  }
});
