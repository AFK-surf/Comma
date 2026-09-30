import { expect, test } from "@playwright/test";
import { spacing } from "../src/tokens/spacing";

test("status indicator uses the quaternary hover surface", async ({ page }) => {
  await page.goto("/?path=/story/app-components-status-indicator--default");

  const preview = page.locator("#storybook-preview-iframe").contentFrame();
  const indicator = preview.locator("status-indicator");
  const unselectedStatus = indicator.locator('[role="radio"]').nth(1);
  await expect(indicator).toBeVisible();
  await expect(unselectedStatus).toHaveAttribute("aria-checked", "false");

  await unselectedStatus.hover();
  await expect
    .poll(() =>
      indicator.evaluate((element) => {
        const status = element.shadowRoot?.querySelector<HTMLElement>(
          '[role="radio"][aria-checked="false"]'
        );
        if (!status) throw new Error("Missing unselected status");
        const probe = document.createElement("span");
        probe.style.background = "var(--color-bg-quaternary)";
        document.body.append(probe);
        const expected = getComputedStyle(probe).backgroundColor;
        probe.remove();
        const hoverSurface = getComputedStyle(status, "::after");
        return {
          matchesQuaternary: hoverSurface.backgroundColor === expected,
          opacity: hoverSurface.opacity,
        };
      })
    )
    .toEqual({
      matchesQuaternary: true,
      opacity: "1",
    });
});

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
    const last = items?.[4];
    if (!root || !items || items.length !== 5 || !first || !last || !reducedStyle) {
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
  await expect(valueControl).toHaveValue("backlog");
  await valueControl.selectOption("cancel");
  const result = await resultPromise;

  expect(result.reducedStyleText).toContain("animation: none");
  expect(result.firstCheckedAfter).toBe("false");
  expect(result.lastCheckedAfter).toBe("true");
  expect(result.firstWidthAfter).toBeLessThan(result.firstWidthBefore);
  expect(result.lastWidthAfter).toBeGreaterThan(result.lastWidthBefore);
});

test("status indicator exposes Option shortcuts without moving focus", async ({
  page,
}) => {
  await page.goto("/?path=/story/app-components-status-indicator--keyboard-shortcuts");

  const preview = page.locator("#storybook-preview-iframe").contentFrame();
  const indicator = preview.locator("status-indicator");
  const focusTarget = preview.getByRole("textbox", {
    name: "Shortcut focus target",
  });
  await expect(indicator).toBeVisible();
  await expect(indicator.locator('[role="radio"]')).toHaveCount(5);

  const shortcutLabels = await indicator
    .locator('[role="radio"]')
    .evaluateAll((statuses) =>
      statuses.map((status) => status.getAttribute("aria-keyshortcuts"))
    );
  expect(shortcutLabels).toEqual(["Alt+1", "Alt+2", "Alt+3", "Alt+4", "Alt+5"]);

  await focusTarget.focus();
  await page.keyboard.press("Alt+3");
  await expect
    .poll(() => indicator.evaluate((element) => Reflect.get(element, "value")))
    .toBe("needs-review");
  await expect(preview.getByTestId("home-task-card")).toContainText(
    "Review the launch checklist"
  );
  await expect(focusTarget).toBeFocused();

  const doneStatus = indicator.locator('[role="radio"]').nth(3);
  // Prime React Aria's pointer modality before entering the Shadow DOM trigger.
  await page.mouse.move(1, 1);
  await doneStatus.hover();
  const tooltip = preview.getByRole("tooltip");
  await expect(tooltip).toBeVisible();
  await expect(tooltip).toContainText("Done");
  await expect(tooltip.getByLabel("Keyboard shortcut: ⌥ 4")).toBeVisible();

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
      '[role="radio"][data-index="3"]'
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

  const backlogStatus = indicator.locator('[role="radio"]').first();
  await backlogStatus.focus();
  await expect(tooltip).toContainText("Backlog");
  await expect(tooltip.getByLabel("Keyboard shortcut: ⌥ 1")).toBeVisible();
  await expect.poll(() => tooltipFollows(backlogStatus)).toBe(true);

  await backlogStatus.blur();
  await expect(tooltip).toBeHidden();
});
