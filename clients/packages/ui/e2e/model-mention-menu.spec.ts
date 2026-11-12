import { expect, test } from "@playwright/test";
import { motionDuration } from "../src/tokens/motion";

const story = "/iframe.html?id=app-chat-model-mention-menu--preview&viewMode=story";

test("model-name queries insert with one Enter and keep keyboard navigation", async ({
  page,
}) => {
  await page.goto(story);
  const editor = page.getByRole("textbox", { name: "AI prompt" });
  await editor.fill("@gpt");
  const sol = page.getByRole("option", { name: "GPT-6 Sol", exact: true });
  const astra = page.getByRole("option", { name: "GPT-6 Astra", exact: true });
  await expect(sol).toBeVisible();
  await expect(page.getByRole("option", { name: "OpenAI" })).toHaveCount(0);
  await editor.press("ArrowDown");
  await expect(astra).toHaveAttribute("aria-selected", "true");
  await editor.press("ArrowUp");
  await expect(sol).toHaveAttribute("aria-selected", "true");
  await editor.press("Enter");
  await expect(editor.locator("[data-ai-input-token]")).toHaveText("GPT-6 Sol");
  await editor.pressSequentially(" @opus");
  await editor.press("Enter");
  await expect(editor.locator("[data-ai-input-token]").last()).toHaveText(
    "Claude Opus"
  );
});

test("stationary pointer events do not reopen a model after keyboard navigation", async ({
  page,
}) => {
  await page.goto(story);
  await page.getByRole("textbox", { name: "AI prompt" }).fill("@");
  await page.getByRole("option", { name: "OpenAI" }).click();
  const sol = page.getByRole("option", { name: "GPT-6 Sol", exact: true });
  await sol.hover();
  await expect(
    page.getByRole("combobox", { name: "GPT-6 Sol · Reasoning effort" })
  ).toBeVisible();
  const bounds = (await sol.boundingBox())!;
  await page.getByRole("combobox", { name: "OpenAI", exact: true }).press("ArrowDown");
  await sol.dispatchEvent("pointermove", {
    pointerType: "mouse",
    clientX: bounds.x + bounds.width / 2,
    clientY: bounds.y + bounds.height / 2,
    movementX: 0,
    movementY: 0,
  });
  await expect(
    page.getByRole("option", { name: "GPT-6 Astra", exact: true })
  ).toHaveAttribute("aria-selected", "true");
  await expect(page.getByRole("combobox", { name: /Reasoning effort/ })).toHaveCount(0);
});

test("crossing another model into the effort panel keeps the original model", async ({
  page,
}) => {
  await page.goto(story);
  await page.getByRole("textbox", { name: "AI prompt" }).fill("@");
  await page.getByRole("option", { name: "OpenAI" }).click();
  const sol = page.getByRole("option", { name: "GPT-6 Sol", exact: true });
  const astra = page.getByRole("option", { name: "GPT-6 Astra", exact: true });
  await sol.hover();
  const choices = page.getByRole("combobox", { name: "GPT-6 Sol · Reasoning effort" });
  await expect(choices).toBeVisible();
  await page.clock.install({ time: new Date("2026-01-01T00:00:00Z") });
  await page.clock.pauseAt(new Date("2026-01-01T00:00:00Z"));
  const row = (await astra.boundingBox())!;
  const target = (await page
    .getByRole("option", { name: "high", exact: true })
    .boundingBox())!;
  await page.mouse.move(row.x + row.width - 20, row.y + row.height / 2);
  await page.mouse.move(target.x + target.width / 2, target.y + target.height / 2, {
    steps: 4,
  });
  await page.clock.runFor(motionDuration.pointerIntent + 1);
  await expect(choices).toBeVisible();
  await expect(sol).toHaveAttribute("aria-selected", "true");
  await page.getByRole("option", { name: "high", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "AI prompt" })).toContainText(
    "GPT-6 Sol · high"
  );
});

test("effort choices stay inside the window when the composer sits at its bottom", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1000, height: 720 });
  await page.goto(
    "/iframe.html?id=app-chat-model-mention-menu--at-window-bottom&viewMode=story"
  );
  const editor = page.getByRole("textbox", { name: "AI prompt" });
  await editor.fill("@");
  await page.getByRole("option", { name: "OpenAI" }).click();
  await page.getByRole("combobox", { name: "OpenAI", exact: true }).press("ArrowRight");
  const choices = page.getByRole("combobox", { name: "GPT-6 Sol · Reasoning effort" });
  await expect(choices).toBeFocused();
  const xhigh = page.getByRole("option", { name: "xhigh", exact: true });
  await expect(xhigh).toBeInViewport({ ratio: 1 });
  await xhigh.click();
  await expect(editor).toContainText("GPT-6 Sol · xhigh");
});
