import { waitForSettledMotion } from "../helpers/motion";
import { expect, test, type Locator, type Page } from "@playwright/test";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../vite/comma-tailwind";
import type { AddressInfo } from "node:net";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createBuiltFixtureServer,
  type BuiltFixtureServer,
} from "../helpers/built-fixture";

const currentDir = fileURLToPath(new URL(".", import.meta.url));
const clientsRoot = resolve(currentDir, "../..");
const fixtureRoot = resolve(currentDir, "fixtures/menu");

let fixtureServer: BuiltFixtureServer | undefined;
let fixtureUrl = "";
const defaultActiveBackgroundClass = /(?:^|\s)bg-quaternary(?:\s|$)/;

test.beforeAll(async () => {
  fixtureServer = await createBuiltFixtureServer({
    cacheDir: resolve(clientsRoot, "node_modules/.vite/menu-e2e"),
    configFile: false,
    define: {
      "process.env.NODE_ENV": JSON.stringify("test"),
      // React Aria renders every row under NODE_ENV=test unless told to virtualize.
      "process.env.VIRT_ON": JSON.stringify("1"),
    },
    plugins: [react(), tailwindcss({ optimize: false }), localGroupSelectors()],
    resolve: {
      alias: {
        "@comma/ui/styles.css": resolve(clientsRoot, "packages/ui/src/styles.css"),
        "@comma/ui": resolve(clientsRoot, "packages/ui/src/index.ts"),
      },
    },
    root: fixtureRoot,
    server: {
      hmr: false,
      host: "127.0.0.1",
      port: 0,
    },
  });

  const address = fixtureServer.httpServer?.address();
  if (!address || typeof address === "string") {
    throw new Error("Menu fixture server did not expose a TCP port.");
  }

  fixtureUrl = `http://127.0.0.1:${(address as AddressInfo).port}/`;
});

test.afterAll(async () => {
  await fixtureServer?.close();
});

test("tooltip motion follows pointer and keyboard intent in the browser", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const primaryTarget = page.getByRole("button", {
    name: "Primary tooltip target",
  });
  const neutralArea = page.getByTestId("tooltip-neutral-area");

  await primaryTarget.click();
  await neutralArea.hover();
  await expect(page.getByRole("tooltip")).toHaveCount(0);

  await primaryTarget.hover();
  const pointerTooltip = page.getByRole("tooltip", { name: "Primary tip" });
  await expect(pointerTooltip).toBeVisible();
  expect(await pointerTooltip.getAttribute("data-instant")).toBeNull();
  expect((await getTooltipMotionSnapshot(pointerTooltip)).allDurationsZero).toBe(false);

  await page.goto(fixtureUrl);

  const keyboardTarget = page.getByRole("button", {
    name: "Primary tooltip target",
  });
  // Navigation can finish before React renders the first focusable control.
  // Reset pointer intent, then exercise the real first Tab after it mounts.
  await neutralArea.hover();
  await expect(keyboardTarget).toBeVisible();
  await page.keyboard.press("Tab");
  await expect(keyboardTarget).toBeFocused();

  const keyboardTooltip = page.getByRole("tooltip", { name: "Primary tip" });
  await expect(keyboardTooltip).toBeVisible();
  await expect(keyboardTooltip).toHaveAttribute("data-instant", "true");
  expect((await getTooltipMotionSnapshot(keyboardTooltip)).allDurationsZero).toBe(true);
});

test("menu supports destructive hover and keyboard action flow in the browser", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const trigger = page.getByRole("button", { name: "Open task actions" });
  const menu = page.getByRole("menu", { name: "Task actions" });
  const renameItem = page.getByRole("menuitem", { name: "Rename task" });
  const disabledItem = page.getByRole("menuitem", {
    name: "Archive unavailable",
  });
  const deleteItem = page.getByRole("menuitem", { name: "Delete" });
  const deleteContent = deleteItem.locator('[data-slot="menu-item-content"]');

  await expect(menu).toBeHidden();
  await expect(page.getByTestId("last-action")).toHaveText("Last action: none");

  await trigger.click();
  await expect(menu).toBeVisible();
  await expect(disabledItem).toHaveAttribute("aria-disabled", "true");
  await expect(page.getByRole("separator")).toBeVisible();

  await deleteItem.hover();
  await expect(deleteContent).toHaveCSS("background-color", "rgb(254, 243, 242)");

  await page.keyboard.press("Escape");
  await expect(menu).toBeHidden();
  await expect(trigger).toBeFocused();

  await trigger.press("Enter");
  await expect(menu).toBeVisible();
  await expect(renameItem).toBeFocused();

  await page.keyboard.press("ArrowDown");
  await expect(deleteItem).toBeFocused();

  await page.keyboard.press("Enter");
  await expect(page.getByTestId("last-action")).toHaveText("Last action: delete");
  await expect(menu).toBeHidden();
  await expect(trigger).toBeFocused();
});

test("selection action bar rests above the selection and flips near the top edge", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  await selectFixtureText(page, "selection-source", "center");

  const bar = page.locator('[data-slot="selection-action-bar"]');
  await expect(bar).toBeVisible();
  await expect(bar).toHaveAttribute("data-placement", "top");
  await expect(bar).toHaveAttribute("data-visible", "true");
  await expect(bar.getByRole("button", { name: "Add to chat" })).toBeVisible();
  await expect(bar.locator("kbd")).toHaveText(["⌘", "L"]);
  // A wide symbol and a narrow letter must occupy the same keycap, so the
  // shortcut reads as one unit rather than two mismatched chips.
  const keycaps = await bar.locator("kbd").evaluateAll((nodes) =>
    nodes.map((node) => {
      const rect = node.getBoundingClientRect();
      return { height: Math.round(rect.height), width: Math.round(rect.width) };
    })
  );
  expect(keycaps).toHaveLength(2);
  expect(keycaps[0]).toEqual(keycaps[1]);
  expect(keycaps[0]!.width).toBe(keycaps[0]!.height);

  // The label sits a step further from its keycaps than the keycaps sit from
  // each other, so the shortcut reads as one group rather than a third word.
  const action = bar.getByRole("button", { name: "Add to chat" });
  await expect(action).toHaveCSS("column-gap", "4px");
  await expect(bar.locator('[data-slot="selection-action-bar-keys"]')).toHaveCSS(
    "column-gap",
    "2px"
  );

  // Read the resting placement the bar committed to, so the assertion does
  // not race its enter transition.
  // Compare the current selection and committed placement in the same frame.
  // The earlier selection rect can become stale while the page finishes layout.
  await expect
    .poll(() => selectionBarGeometry(bar))
    .toMatchObject({
      topClearance: 8,
      centered: true,
    });

  await bar.getByRole("button", { name: "Add to chat" }).click();
  await expect(page.getByTestId("selection-quoted")).toContainText("圆橡皮");
  await expect(bar).toBeHidden();

  // A selection scrolled hard against the viewport top has no room above it.
  await selectFixtureText(page, "selection-source-top", "start");

  await expect(bar).toBeVisible();
  await expect(bar).toHaveAttribute("data-placement", "bottom");
  await expect
    .poll(() => selectionBarGeometry(bar))
    .toMatchObject({
      bottomClearance: 8,
    });
});

test("selection action bar arrives along the direction the selection was drawn", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const bar = page.locator('[data-slot="selection-action-bar"]');
  const travel = () =>
    bar.evaluate((element) =>
      getComputedStyle(element)
        .getPropertyValue("--comma-selection-action-bar-travel")
        .trim()
    );

  await selectFixtureText(page, "selection-source", "center");
  await expect(bar).toHaveAttribute("data-direction", "forward");
  // A left-to-right sweep hands the bar in from the left, so it starts at a
  // negative offset and settles at zero.
  const forwardTravel = Number.parseFloat(await travel());
  expect(forwardTravel).toBe(-1);

  await selectFixtureText(page, "selection-source", "center", { backward: true });
  await expect(bar).toHaveAttribute("data-direction", "backward");
  expect(Number.parseFloat(await travel())).toBe(-forwardTravel);

  // Whatever the sign, both directions settle at the same resting transform.
  await expect(bar).toHaveAttribute("data-visible", "true");
  await expect
    .poll(() => bar.evaluate((element) => getComputedStyle(element).transform))
    .toBe("matrix(1, 0, 0, 1, 0, 0)");
});

test("long dropdown preserves wheel progress when edge hover falls back to scrolling", async ({
  page,
}) => {
  await page.setViewportSize({ width: 900, height: 500 });
  await page.goto(fixtureUrl);

  const fixture = page.getByRole("region", {
    name: "Long dropdown scroll fallback fixture",
  });
  const trigger = fixture.locator('[data-slot="dropdown-trigger"]');

  await trigger.click();

  const popover = page.locator('[data-slot="dropdown-popover"]');
  const scrollViewport = popover.locator('[data-slot="scroll-area-viewport"]');
  const scrollDownFade = popover.locator('[data-slot="dropdown-scroll-down"]');

  await expect(popover).toBeVisible();
  await expect(scrollDownFade).toBeAttached();
  await expect
    .poll(() =>
      scrollDownFade.evaluate((element) => getComputedStyle(element).pointerEvents)
    )
    .toBe("none");
  await expect
    .poll(() =>
      scrollViewport.evaluate((viewport) => ({
        clientHeight: viewport.clientHeight,
        scrollHeight: viewport.scrollHeight,
      }))
    )
    .toMatchObject({ clientHeight: 177, scrollHeight: 728 });

  // The popover is still arriving. A hover on a moving element is retried,
  // and a retry scrolls its target to another edge of the window; on this
  // scrollable fixture page that moves the popover to the top of the viewport,
  // where it has no room above to reveal into.
  await waitForSettledMotion(popover);
  await scrollViewport.hover();
  await page.mouse.wheel(0, 200);
  await expect
    .poll(() => scrollViewport.evaluate((viewport) => viewport.scrollTop))
    .toBe(200);

  const beforeHover = await getDropdownScrollSnapshot(scrollViewport);
  expect(beforeHover.firstVisibleOption).toBe("Option 6");

  const popoverBox = await popover.boundingBox();
  if (!popoverBox) {
    throw new Error("Dropdown popover geometry was unavailable.");
  }
  await page.mouse.move(
    popoverBox.x + popoverBox.width / 2,
    popoverBox.y + popoverBox.height - 8
  );
  await expect(popover).toHaveAttribute("data-content-expanded", "true");
  await expect(popover).toHaveAttribute("data-scroll-fallback", "true");
  await expect(popover).not.toHaveAttribute("data-content-fully-expanded");
  await expect
    .poll(() => scrollViewport.evaluate((viewport) => viewport.clientHeight))
    .toBeGreaterThan(177);

  await expect
    .poll(() => getDropdownScrollSnapshot(scrollViewport))
    .toEqual(beforeHover);
});

test("long virtualized dropdown opens on its checked option and mounts only rows in view", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const fixture = page.getByRole("region", { name: "Virtualized dropdown fixture" });
  const trigger = fixture.locator('[data-slot="dropdown-trigger"]');
  const popover = page.locator('[data-slot="dropdown-popover"]');
  const viewport = popover.locator('[data-slot="scroll-area-viewport"]');
  const checked = popover.getByRole("option", { name: "Family 280", exact: true });
  const triggerTop = await trigger.evaluate(
    (element) => element.getBoundingClientRect().top
  );

  await trigger.click();

  // Clamped at the viewport top, the list scrolls rather than hiding the
  // checked option 280 rows below it.
  await expect(checked).toBeFocused();
  await expect
    .poll(() => checked.evaluate((element) => element.getBoundingClientRect().top))
    .toBeCloseTo(triggerTop, 0);
  expect(await popover.getByRole("option").count()).toBeLessThan(60);
  await expect(checked.locator('[data-slot="dropdown-option-label"]')).toHaveCSS(
    "font-family",
    "serif"
  );

  // Rows mount as they scroll into view, with their own face.
  await viewport.evaluate((element) => {
    element.scrollTop = 0;
  });
  const first = popover.getByRole("option", { name: "Family 1", exact: true });
  await expect(first).toBeInViewport();
  await expect(first.locator('[data-slot="dropdown-option-label"]')).toHaveCSS(
    "font-family",
    "monospace"
  );

  // Keyboard focus travels to rows that were never mounted.
  await checked.focus();
  await page.keyboard.press("End");
  const last = popover.getByRole("option", { name: "Family 300", exact: true });
  await expect(last).toBeFocused();
  await expect(last).toBeInViewport();
  await page.keyboard.press("Enter");
  await expect(trigger).toHaveText("Family 300");
});

test("connected submenus preserve one active path and close after group exit", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const trigger = page.getByRole("button", { name: "Open connected filters" });
  const rootMenu = page.getByRole("menu", { name: "Open connected filters" });
  const statusItem = page.getByRole("menuitem", { name: "Status" });
  const workerItem = page.getByRole("menuitem", { name: "Worker" });
  const statusContent = statusItem.locator('[data-slot="menu-item-content"]');
  const workerContent = workerItem.locator('[data-slot="menu-item-content"]');
  const statusMenu = page.getByRole("dialog", { name: "Status" });
  const workerMenu = page.getByRole("dialog", { name: "Worker" });

  await trigger.click();
  const statusBounds = await statusItem.boundingBox();
  if (!statusBounds) {
    throw new Error("Status menu item geometry was unavailable.");
  }
  await page.mouse.move(
    statusBounds.x + statusBounds.width / 2,
    statusBounds.y + statusBounds.height / 2
  );
  await expect(statusMenu).toBeVisible();
  await expect(statusContent).toHaveClass(defaultActiveBackgroundClass);

  const workerBounds = await workerItem.boundingBox();
  if (!workerBounds) {
    throw new Error("Worker menu item geometry was unavailable.");
  }

  const backlogBounds = await page
    .getByRole("menuitem", { name: "Backlog" })
    .boundingBox();
  if (!backlogBounds) {
    throw new Error("Status option geometry was unavailable.");
  }
  await page.mouse.move(
    backlogBounds.x + backlogBounds.width / 2,
    backlogBounds.y + backlogBounds.height / 2
  );

  await expect(statusItem).toHaveAttribute("aria-expanded", "true");
  await expect(statusContent).toHaveClass(defaultActiveBackgroundClass);

  const statusMenuBounds = await statusMenu.boundingBox();
  if (!statusMenuBounds) {
    throw new Error("Connected menu geometry was unavailable.");
  }
  expect(
    Math.abs(statusMenuBounds.x + statusMenuBounds.width - statusBounds.x)
  ).toBeLessThanOrEqual(1);

  await page.mouse.move(
    workerBounds.x + workerBounds.width / 2,
    workerBounds.y + workerBounds.height / 2
  );

  await expect(statusMenu).toBeHidden();
  await expect(workerMenu).toBeVisible();
  await expect(statusItem).toHaveAttribute("aria-expanded", "false");
  await expect(workerItem).toHaveAttribute("aria-expanded", "true");
  await expect(statusContent).not.toHaveClass(defaultActiveBackgroundClass);
  await expect(workerContent).toHaveClass(defaultActiveBackgroundClass);

  const codexItem = page.getByRole("menuitem", { name: "Codex" });
  const codexBounds = await codexItem.boundingBox();
  if (!codexBounds) {
    throw new Error("Worker option geometry was unavailable.");
  }
  await page.mouse.move(
    codexBounds.x + codexBounds.width / 2,
    codexBounds.y + codexBounds.height / 2
  );
  await expect(codexItem).toBeFocused();

  await page.mouse.move(10, 10);

  await expect(workerMenu).toBeHidden();
  await expect(workerItem).toHaveAttribute("aria-expanded", "false");
  await expect(workerContent).not.toHaveClass(defaultActiveBackgroundClass);
  await expect(rootMenu).toBeVisible();
  await expect(workerItem).toBeFocused();

  await page.keyboard.press("ArrowDown");
  await expect(statusItem).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(rootMenu).toBeHidden();
  await expect(trigger).toBeFocused();
});

test("connected submenu keyboard navigation preserves focus and active path", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const trigger = page.getByRole("button", { name: "Open connected filters" });
  const rootMenu = page.getByRole("menu", { name: "Open connected filters" });
  const statusItem = page.getByRole("menuitem", { name: "Status" });
  const workerItem = page.getByRole("menuitem", { name: "Worker" });
  const statusContent = statusItem.locator('[data-slot="menu-item-content"]');
  const statusMenu = page.getByRole("dialog", { name: "Status" });
  const workerMenu = page.getByRole("dialog", { name: "Worker" });

  await trigger.press("Enter");
  await expect(statusItem).toBeFocused();

  await page.keyboard.press("ArrowRight");

  await expect(statusMenu).toBeVisible();
  await expect(page.getByRole("menuitem", { name: "Backlog" })).toBeFocused();
  await expect(statusContent).toHaveClass(defaultActiveBackgroundClass);

  await page.keyboard.press("ArrowLeft");

  await expect(statusMenu).toBeHidden();
  await page.evaluate(
    () =>
      new Promise<void>((done) =>
        requestAnimationFrame(() => requestAnimationFrame(() => done()))
      )
  );
  await expect(statusItem).toBeFocused();

  await page.keyboard.press("ArrowDown");
  await expect(workerItem).toBeFocused();
  await page.keyboard.press("ArrowRight");
  await expect(workerMenu).toBeVisible();
  await expect(page.getByRole("menuitem", { name: "Codex" })).toBeFocused();

  await page.keyboard.press("Escape");
  await expect(workerMenu).toBeHidden();
  await expect(workerItem).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(rootMenu).toBeHidden();
  await expect(trigger).toBeFocused();
});

test("task list pointer context menu exits in place without locking the app", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const row = page.getByLabel("Keyboard task row");
  const menu = page.getByRole("menu", { name: "Keyboard task actions" });
  const renameItem = page.getByRole("menuitem", {
    name: "Rename keyboard task",
  });

  await expect(menu).toBeHidden();
  await expect(page.getByTestId("last-task-action")).toHaveText(
    "Last task action: none"
  );

  await page.evaluate(() =>
    document.documentElement.style.setProperty("--motion-duration-menu-exit", "1000ms")
  );
  await row.click({ button: "right" });
  await expect(menu).toBeVisible();
  const contextPopover = menu.locator("xpath=ancestor::*[@data-slot='menu-popover']");
  await expect(contextPopover).toHaveAttribute("data-animation", "anchor");
  await expect
    .poll(() =>
      page.evaluate(() => ({
        appIsInert: (document.querySelector("#root") as HTMLElement | null)?.inert,
        documentOverflow: getComputedStyle(document.documentElement).overflow,
      }))
    )
    .toEqual({ appIsInert: false, documentOverflow: "visible" });
  await waitForSettledMotion(contextPopover);
  const openPopoverBounds = await contextPopover.boundingBox();
  expect(openPopoverBounds).not.toBeNull();
  const renameItemBounds = await renameItem.boundingBox();
  expect(renameItemBounds).not.toBeNull();
  await page.mouse.click(
    renameItemBounds!.x + renameItemBounds!.width / 2,
    renameItemBounds!.y + renameItemBounds!.height / 2
  );
  const exitingPopover = page.locator('[data-slot="menu-popover"][data-exiting]');
  await expect(exitingPopover).toHaveCount(1);
  const exitingPopoverBounds = await exitingPopover.boundingBox();
  expect(exitingPopoverBounds).not.toBeNull();
  expect(Math.abs(exitingPopoverBounds!.x - openPopoverBounds!.x)).toBeLessThan(1);
  expect(Math.abs(exitingPopoverBounds!.y - openPopoverBounds!.y)).toBeLessThan(1);
  // The forced one-second transition keeps the node around for the geometry
  // assertion above. Wait separately for React Aria's exit-node cleanup.
  await expect(exitingPopover).toHaveCount(0, { timeout: 3_000 });

  await page.evaluate(() =>
    document.documentElement.style.removeProperty("--motion-duration-menu-exit")
  );
  await row.click({ button: "right" });
  await expect(menu).toBeVisible();
  await page.keyboard.press("Escape");
  // Keyboard and pointer dismissal share the same exit animation. Wait for
  // cleanup without requiring the retired instant-close path.
  await expect(menu).toBeHidden();
  await expect
    .poll(() =>
      page.evaluate(() => ({
        appIsInert: (document.querySelector("#root") as HTMLElement | null)?.inert,
        documentOverflow: getComputedStyle(document.documentElement).overflow,
      }))
    )
    .toEqual({ appIsInert: false, documentOverflow: "visible" });
  await expect(menu).toBeHidden({ timeout: 1_500 });
  await page.evaluate(() =>
    document.documentElement.style.removeProperty("--motion-duration-menu-exit")
  );
});

test("a context menu opened again during its exit takes focus and closes on Escape", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const row = page.getByLabel("Keyboard task row");
  const menu = page.getByRole("menu", { name: "Keyboard task actions" });
  const renameItem = page.getByRole("menuitem", {
    name: "Rename keyboard task",
  });
  const exitingPopover = page.locator('[data-slot="menu-popover"][data-exiting]');

  // Hold the exit open so the second right click lands inside it.
  await page.evaluate(() =>
    document.documentElement.style.setProperty("--motion-duration-menu-exit", "1000ms")
  );
  await row.click({ button: "right" });
  await expect(renameItem).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(exitingPopover).toHaveCount(1);

  await row.click({ button: "right" });
  await expect(exitingPopover).toHaveCount(0);
  await expect(menu).toBeVisible();
  await expect(renameItem).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(menu).toBeHidden({ timeout: 3_000 });
});

test("task list item opens its context menu from the keyboard and restores focus", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const row = page.getByLabel("Keyboard task row");
  const menu = page.getByRole("menu", { name: "Keyboard task actions" });
  const renameItem = page.getByRole("menuitem", {
    name: "Rename keyboard task",
  });

  await expect(menu).toBeHidden();
  await expect(page.getByTestId("last-task-action")).toHaveText(
    "Last task action: none"
  );

  await row.focus();
  await page.keyboard.press("Shift+F10");

  await expect(menu).toBeVisible();
  await expect(row).toHaveAttribute("data-context-menu-open", "true");
  await expect(renameItem).toBeFocused();

  await page.keyboard.press("Enter");

  await expect(page.getByTestId("last-task-action")).toHaveText(
    "Last task action: rename-task"
  );
  await expect(menu).toBeHidden();
  await expect(row).toBeFocused();
  await expect(row).toHaveAttribute("data-context-menu-open", "false");

  await page.keyboard.press("Shift+F10");
  await expect(menu).toBeVisible();
  await page.keyboard.press("Escape");

  await expect(menu).toBeHidden();
  await expect(row).toBeFocused();
});

test("opted-out transform feedback is not compounded by the global press scale", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const button = page.getByRole("button", {
    name: "Existing transform feedback",
  });
  await holdButton(page, button);

  try {
    const pressedStyles = await getButtonSnapshot(button);

    expect(pressedStyles.scale).toBe("none");
    expect(pressedStyles.transform).toBe("matrix(0.94, 0, 0, 0.94, 0, 0)");
    expect(pressedStyles.width).toBeCloseTo(94, 1);
  } finally {
    await page.mouse.up();
  }
});

test("buttons without custom feedback retain the shared press scale", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const button = page.getByRole("button", { name: "Global press feedback" });
  await holdButton(page, button);

  try {
    const pressedStyles = await getButtonSnapshot(button);

    expect(pressedStyles.scale).toBe("0.98");
    expect(pressedStyles.transform).toBe("none");
    expect(pressedStyles.width).toBeCloseTo(98, 1);
  } finally {
    await page.mouse.up();
  }
});

test("reduced motion disables later transitions and custom action scaling", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto(fixtureUrl);

  const transformButton = page.getByRole("button", {
    name: "Existing transform feedback",
  });
  const transformTransition = await transformButton.evaluate((element) => ({
    duration: getComputedStyle(element).transitionDuration,
    property: getComputedStyle(element).transitionProperty,
  }));

  expect(transformTransition).toEqual({
    duration: "0s",
    property: "none",
  });

  const actionButton = page.getByRole("button", {
    name: "Custom action feedback",
  });
  await holdButton(page, actionButton);

  try {
    const pressedStyles = await getButtonSnapshot(actionButton);

    expect(pressedStyles.scale).toBe("1");
    expect(pressedStyles.transform).toBe("none");
    expect(pressedStyles.transitionDuration).toBe("0s");
    expect(pressedStyles.transitionProperty).toBe("none");
    expect(pressedStyles.width).toBeCloseTo(100, 1);
  } finally {
    await page.mouse.up();
  }
});

async function holdButton(page: Page, button: Locator) {
  await button.hover();
  await page.mouse.down();
  await page.evaluate(
    () =>
      new Promise<void>((resolveFrame) => {
        requestAnimationFrame(() => requestAnimationFrame(() => resolveFrame()));
      })
  );
  await page.evaluate(() => {
    for (const animation of document.getAnimations()) {
      animation.finish();
    }
  });
}

async function getButtonSnapshot(button: Locator) {
  return button.evaluate((element) => {
    const computedStyle = getComputedStyle(element);

    return {
      scale: computedStyle.scale,
      transform: computedStyle.transform,
      transitionDuration: computedStyle.transitionDuration,
      transitionProperty: computedStyle.transitionProperty,
      width: element.getBoundingClientRect().width,
    };
  });
}

async function getDropdownScrollSnapshot(scrollViewport: Locator) {
  return scrollViewport.evaluate((viewport) => {
    const viewportRect = viewport.getBoundingClientRect();
    const firstVisibleOption = Array.from(
      viewport.querySelectorAll<HTMLElement>('[role="option"]')
    ).find((option) => {
      const optionRect = option.getBoundingClientRect();
      return (
        optionRect.bottom > viewportRect.top && optionRect.top < viewportRect.bottom
      );
    });

    return {
      firstVisibleOption: firstVisibleOption?.textContent?.trim() ?? null,
      scrollTop: viewport.scrollTop,
    };
  });
}

/** Scrolls a fixture paragraph into view, selects it, and reports its rect. */
async function selectFixtureText(
  page: Page,
  testId: string,
  block: ScrollLogicalPosition,
  options: { backward?: boolean } = {}
) {
  // The fixture snapshots its anchor on pointerup; finish font layout before
  // selecting so a late font swap cannot invalidate that captured rectangle.
  await page.getByTestId(testId).waitFor({ state: "visible" });
  await page.evaluate(() => document.fonts.ready.then(() => undefined));
  const rect = await page.evaluate(
    ([id, scrollBlock, backward]) => {
      const element = document.querySelector(`[data-testid="${id}"]`)!;
      element.scrollIntoView({ block: scrollBlock as ScrollLogicalPosition });
      const range = document.createRange();
      range.selectNodeContents(element);
      const selection = window.getSelection();
      selection?.removeAllRanges();
      if (backward) {
        // A backward sweep ends where it began, so anchor and focus swap.
        selection?.setBaseAndExtent(
          range.endContainer,
          range.endOffset,
          range.startContainer,
          range.startOffset
        );
      } else {
        selection?.addRange(range);
      }
      const { bottom, left, right, top } = range.getBoundingClientRect();
      return { bottom, left, right, top };
    },
    [testId, block, options.backward === true] as const
  );
  await page.getByTestId(testId).dispatchEvent("pointerup");
  return rect;
}

async function getTooltipMotionSnapshot(tooltip: Locator) {
  return tooltip.evaluate((element) => {
    const style = getComputedStyle(element);
    const transitionDurations = style.transitionDuration
      .split(",")
      .map((duration) => duration.trim());

    return {
      allDurationsZero: transitionDurations.every(
        (duration) => duration === "0s" || duration === "0ms"
      ),
    };
  });
}

async function selectionBarGeometry(bar: Locator) {
  return bar.evaluate((element) => {
    const selection = window.getSelection();
    if (!selection?.rangeCount) throw new Error("Expected a selected text range");
    const rect = selection.getRangeAt(0).getBoundingClientRect();
    const actionBar = element as HTMLElement;
    const top = Number.parseFloat(actionBar.style.top);
    const left = Number.parseFloat(actionBar.style.left);
    return {
      topClearance: rect.top - (top + actionBar.offsetHeight),
      bottomClearance: top - rect.bottom,
      centered:
        Math.abs(left + actionBar.offsetWidth / 2 - (rect.left + rect.right) / 2) < 1,
    };
  });
}
