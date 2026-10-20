import { expect, test } from "@playwright/test";
import { spacing } from "../src/tokens/spacing";

test("status indicator snaps Shadow DOM motion with reduced motion", async ({
  page,
}) => {
  await page.goto("/?path=/story/app-components-status-indicator--default");

  await page.getByRole("button", { name: /motion/i }).click();
  await page.getByRole("option", { name: "Reduced motion" }).click();

  const preview = page.locator("#storybook-preview-iframe").contentFrame();
  await expect(preview.locator("html")).toHaveAttribute(
    "data-comma-reduced-motion",
    "true"
  );

  const indicator = preview.locator("status-indicator");
  await expect(indicator).toBeVisible();

  const resultPromise = indicator.evaluate((element) => {
    const root = element.shadowRoot;
    const items = root?.querySelectorAll<HTMLElement>('[role="radio"]');
    const reducedStyle = root?.querySelector<HTMLStyleElement>(
      "style[data-comma-reduced-motion]"
    );
    const first = items?.[0];
    const last = items?.[3];
    if (!root || !items || items.length !== 4 || !first || !last || !reducedStyle) {
      throw new Error("Status indicator Shadow DOM did not initialize");
    }

    const firstWidthBefore = Number.parseFloat(first.style.width);
    const lastWidthBefore = Number.parseFloat(last.style.width);

    return new Promise<{
      firstCheckedAfter: string | null;
      firstWidthAfter: number;
      firstWidthBefore: number;
      lastCheckedAfter: string | null;
      lastWidthAfter: number;
      lastWidthBefore: number;
      reducedStyleText: string | null;
    }>((resolve) => {
      const observer = new MutationObserver(() => {
        if (last.getAttribute("aria-checked") !== "true") {
          return;
        }
        observer.disconnect();
        resolve({
          firstCheckedAfter: first.getAttribute("aria-checked"),
          firstWidthAfter: Number.parseFloat(first.style.width),
          firstWidthBefore,
          lastCheckedAfter: last.getAttribute("aria-checked"),
          lastWidthAfter: Number.parseFloat(last.style.width),
          lastWidthBefore,
          reducedStyleText: reducedStyle.textContent,
        });
      });
      observer.observe(root, {
        attributeFilter: ["aria-checked"],
        attributes: true,
        subtree: true,
      });
    });
  });

  const valueControl = page.getByLabel("value");
  await expect(valueControl).toHaveValue("in-progress");
  await valueControl.selectOption("cancel");
  const result = await resultPromise;

  expect(result.reducedStyleText).toContain("animation: none");
  expect(result.firstCheckedAfter).toBe("false");
  expect(result.lastCheckedAfter).toBe("true");
  expect(result.firstWidthAfter).toBeLessThan(result.firstWidthBefore);
  expect(result.lastWidthAfter).toBeGreaterThan(result.lastWidthBefore);
});

test("status indicator tooltip follows the hovered or focused segment", async ({
  page,
}) => {
  // The Desktop Chrome device reports Windows; the shortcut glyph is macOS only.
  await page.addInitScript(() => {
    Object.defineProperty(Navigator.prototype, "platform", { get: () => "MacIntel" });
  });
  await page.goto("/?path=/story/app-components-status-indicator--keyboard-shortcuts");

  const preview = page.locator("#storybook-preview-iframe").contentFrame();
  const indicator = preview.locator("status-indicator");
  await expect(indicator).toBeVisible();
  await expect(indicator.locator('[role="radio"]')).toHaveCount(4);

  const doneStatus = indicator.locator('[role="radio"]').nth(2);
  // Prime React Aria's pointer modality before entering the Shadow DOM trigger.
  await page.mouse.move(1, 1);
  await doneStatus.hover();
  const tooltip = preview.getByRole("tooltip");
  await expect(tooltip).toBeVisible();
  await expect(tooltip).toContainText("Done");
  await expect(tooltip.getByLabel("Keyboard shortcut: ⌥ 3")).toBeVisible();

  const tooltipFollows = async (status: typeof doneStatus) => {
    const [statusBox, tooltipBox] = await Promise.all([
      status.boundingBox(),
      tooltip.boundingBox(),
    ]);
    if (!statusBox || !tooltipBox) return false;
    const statusCenter = statusBox.x + statusBox.width / 2;
    const tooltipCenter = tooltipBox.x + tooltipBox.width / 2;
    const verticalGap = statusBox.y - (tooltipBox.y + tooltipBox.height);
    // The tooltip sits one `xs` step above the segment, the gap every Tooltip
    // in the product keeps.
    return (
      tooltipBox.y + tooltipBox.height <= statusBox.y &&
      Math.abs(tooltipCenter - statusCenter) <= 2 &&
      Math.abs(verticalGap - spacing.xs) <= 1
    );
  };
  await expect.poll(() => tooltipFollows(doneStatus)).toBe(true);

  const rebuiltDoneSegment = await indicator.evaluate((element) => {
    const previousDone = element.shadowRoot?.querySelector(
      '[role="radio"][data-index="2"]'
    );
    const statuses = Reflect.get(element, "statuses") as Array<Record<string, unknown>>;
    Reflect.set(
      element,
      "statuses",
      statuses.map((status) => ({ ...status }))
    );
    return previousDone?.isConnected === false;
  });
  expect(rebuiltDoneSegment).toBe(true);
  await expect.poll(() => tooltipFollows(doneStatus)).toBe(true);

  // Once a segment has keyboard focus, leaving it with the pointer must keep
  // the tooltip anchored to that segment rather than falling back to the host.
  await doneStatus.focus();
  await page.mouse.move(1, 1);
  await expect(tooltip).toContainText("Done");
  await expect.poll(() => tooltipFollows(doneStatus)).toBe(true);

  const inProgressStatus = indicator.locator('[role="radio"]').first();
  await inProgressStatus.focus();
  await expect(tooltip).toContainText("In progress");
  await expect(tooltip.getByLabel("Keyboard shortcut: ⌥ 1")).toBeVisible();
  await expect.poll(() => tooltipFollows(inProgressStatus)).toBe(true);

  await inProgressStatus.blur();
  await expect(tooltip).toBeHidden();
});
