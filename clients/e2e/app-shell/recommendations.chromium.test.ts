import {
  additionalMockCardTitles,
  oldMockEnvelope,
  settings,
  source,
} from "./fixtures/web-app/routes/recommendations-data";
import { waitForSettledMotion } from "./support/motion";
import { expect, test, type Locator, type Page } from "./support/page";
import { stepUntil, testClock, testPage } from "./support/virtual-time";
import { useWebApp } from "./support/web-app";

// A Routine briefing and the Routines settings, on the web app as one world
// (./support/web-app): the app, its client core's worker and the chat stub
// move on the test's time. The recommendations API is the stub's
// (./fixtures/web-app/routes/recommendations.ts): each test picks what it
// answers before its page opens.

// The briefing heading is a time-of-day greeting, so specs that only need it as
// a stable anchor must not pin one time of day. `briefing-heading.spec.ts` pins
// the wording against a fixed clock.
const greetingHeading = /^Good (morning|afternoon|evening), /;

const reminderUrl = "https://mail.google.com/mail/u/0/#inbox/launch-approval";
const reminderTranscript = [
  {
    actor_type: "agent",
    kind: "message",
    message_id: "reminder-earlier",
    created_at: 1_720_000_001,
    // Reminders stored before this contract keep a source block. Their text
    // stays readable as an ordinary message.
    content: [
      {
        type: "text" as const,
        text: "Reminder scheduled: Check the rollout checklist",
      },
      { type: "mail_reference" as const, source_key: "earlier-reminder" },
    ],
  },
  {
    actor_type: "agent",
    kind: "message",
    message_id: "reminder-current",
    created_at: 1_720_000_002,
    content: [
      {
        type: "text" as const,
        text: `Dana asked you to confirm the launch approval today so the Thursday announcement can go out. Want me to draft the reply?\n\n[Launch approval needed today](${reminderUrl})`,
      },
    ],
  },
];

const app = useWebApp(
  (title) =>
    title === "a proactive reminder reads as a Comma chat message with its source link"
      ? { workspaceTranscript: reminderTranscript }
      : {},
  // The tests wait in the page for frames and animations to finish.
  { routes: "recommendations", evaluationsStep: true }
);

type RecommendationCalls = {
  refreshes: number;
  reads: number;
  readFailures: number;
  queries: string[];
  proactiveWrites: { path: string; body: unknown }[];
  proactiveReads: string[];
};
/** What the app asked the stub's recommendations API so far. */
const calls = () =>
  app.stub().call("recommendationCalls") as Promise<RecommendationCalls>;

/**
 * Moves page time a frame at a time until `check` passes on what `read` gives
 * (as Playwright's `expect.poll` waits), then checks it once more so a
 * failure reports the value.
 */
async function eventually<T>(
  read: () => T | Promise<T>,
  check: (value: T) => void,
  frames?: number
) {
  await stepUntil(
    async () => {
      try {
        check(await read());
        return true;
      } catch {
        return false;
      }
    },
    frames === undefined ? {} : { frames }
  );
  check(await read());
}

type RoutineDragEvidence = {
  layoutAnimation?: {
    duration: number | null;
    transforms: (string | null)[];
  };
  nativeDragImageCalls: number;
};

type RoutineDragFrame = {
  hasTransformAnimation: boolean;
  order: string[];
  tops: Record<string, number>;
};

/** The text-list routines on the rail, in order, by the source each names. */
const routineCardTitles = (page: Page) =>
  page
    .locator('.comma-recommendation-card[data-template="text-list@1"]')
    .evaluateAll((cards) => cards.map((card) => card.getAttribute("aria-label")));

const readIconControlVisual = (control: Locator) =>
  control.evaluate((element) => {
    const icon = element.querySelector("svg")?.getBoundingClientRect();
    const style = getComputedStyle(element);
    const bounds = element.getBoundingClientRect();
    return {
      backgroundColor: style.backgroundColor,
      borderRadius: style.borderRadius,
      color: style.color,
      height: bounds.height,
      iconHeight: icon?.height ?? null,
      iconWidth: icon?.width ?? null,
      paddingBottom: style.paddingBottom,
      paddingLeft: style.paddingLeft,
      paddingRight: style.paddingRight,
      paddingTop: style.paddingTop,
      width: bounds.width,
    };
  });

const settleIconControlVisual = (control: Locator) =>
  control.evaluate(async (element) => {
    await new Promise<void>((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
    });
    await Promise.all(
      element
        .getAnimations({ subtree: true })
        .map((animation) => animation.finished.catch(() => undefined))
    );
  });

const readTextInkBounds = (text: Locator) =>
  text.evaluate((element) => {
    const range = document.createRange();
    range.selectNodeContents(element);
    const bounds = range.getBoundingClientRect();
    return {
      bottom: bounds.bottom,
      height: bounds.height,
      left: bounds.left,
      right: bounds.right,
      top: bounds.top,
      width: bounds.width,
    };
  });

test("a rejected real refresh replaces stale mock recommendations with canonical empty state", async ({
  page,
}) => {
  await app.stub().call("setRecommendations", { name: "rejected-refresh" });

  // Wide enough for the Greet rail to stay inline.
  await page.setViewportSize({ width: 1440, height: 900 });
  await app.open(page);
  // react-aria hover interactions (tooltips, hover cards) ignore synthetic
  // hovers until the page has seen a pointer press; press on static copy.
  await page.getByRole("heading", { name: greetingHeading }).click();

  await expect(page.getByRole("heading", { name: greetingHeading })).toBeVisible();
  await expect(page.getByText("Old mock briefing.")).toBeVisible();
  await expect(page.getByRole("group", { name: "Old mock card" })).toBeVisible();
  await expect(page.getByRole("group", { name: "Next mock card" })).toBeVisible();
  await expect(page.locator(".comma-recommendations-heading")).toHaveCSS(
    "padding-bottom",
    "0px"
  );
  const textCards = page.locator(
    '.comma-recommendation-card[data-template="text-list@1"]'
  );
  await expect(textCards).toHaveCount(6);
  const firstCard = page.getByRole("group", { name: "Old mock card" });
  // Each row is a card of its own: the task, then its source.
  const firstItem = firstCard.locator(".comma-recommendation-text-item").first();
  await expect(firstItem).toHaveCSS("border-radius", "12px");
  await expect(firstItem).toHaveCSS("border-top-style", "solid");
  await expect(firstItem).toHaveCSS("padding-top", "12px");
  await expect(firstItem.locator(".comma-recommendation-source-origin")).toHaveText(
    "Old mock card"
  );
  await expect(
    firstItem.locator(
      '.comma-recommendation-source-origin-mark svg[data-provider-logo="linear"]'
    )
  ).toBeVisible();
  // The card shows the whole task; it wraps instead of truncating.
  const itemContent = firstItem.locator(".comma-recommendation-text-item-content");
  await expect(itemContent).toContainText(
    "Prevent socket exhaustion recurrence and review COMMA-143 and COMMA-144"
  );
  await expect(itemContent.locator("p").first()).toHaveCSS("white-space", "normal");

  // The card is the press target, with no preview to hover first.
  const liveHoverCard = page.locator(".comma-hover-card:not([data-exiting])");
  const rowAction = firstItem.getByRole("button", { name: "Review old mock issue" });
  await rowAction.hover({ position: { x: 8, y: 8 } });
  await testClock().advance(600);
  await expect(liveHoverCard).toHaveCount(0);

  // A chip with a preview of its own still owns its hover.
  await firstItem.getByRole("button", { name: "COMMA-143" }).hover();
  await expect(liveHoverCard).toContainText(
    "Linear · linear.app/comma/issue/COMMA-143"
  );
  await page.locator(".comma-home-chat").hover();
  await expect(page.locator(".comma-hover-card")).toHaveCount(0);
  const refreshControl = page.getByRole("button", {
    exact: true,
    name: "Refresh",
  });
  const routinesTrigger = page.getByRole("button", {
    name: "Customize routines",
  });
  const toggleSidebar = page
    .getByTestId("comma-window-bar")
    .getByRole("button", { name: "New tab" });
  await expect(refreshControl).toBeVisible();
  await expect(refreshControl).toHaveAttribute("aria-label", "Refresh");
  await expect(refreshControl).not.toContainText("Refresh");
  await expect(refreshControl.locator("[data-comma-icon]")).toBeVisible();
  await expect(routinesTrigger.locator("[data-comma-icon]")).toBeVisible();
  await expect(toggleSidebar).toBeVisible();

  // The Routines controls share the Chat Sidebar toggle's look and footprint
  // (28px box, 20px icon, 4px padding and radius, same colours).
  const routinesControlVisual = await readIconControlVisual(toggleSidebar);
  expect(routinesControlVisual).toMatchObject({ height: 28, width: 28 });
  expect(await readIconControlVisual(refreshControl)).toEqual(routinesControlVisual);
  expect(await readIconControlVisual(routinesTrigger)).toEqual(routinesControlVisual);

  const refreshPrecedesCustomize = await refreshControl.evaluate(
    (refresh, customize) => {
      if (!(customize instanceof Element)) return null;
      return Boolean(
        refresh.compareDocumentPosition(customize) & Node.DOCUMENT_POSITION_FOLLOWING
      );
    },
    await routinesTrigger.elementHandle()
  );
  expect(refreshPrecedesCustomize).toBe(true);
  await routinesTrigger.focus();
  await toggleSidebar.hover();
  await settleIconControlVisual(toggleSidebar);
  const toggleSidebarHoverVisual = await toggleSidebar.evaluate((element) => {
    const style = getComputedStyle(element);
    return {
      backgroundColor: style.backgroundColor,
      color: style.color,
    };
  });
  for (const control of [refreshControl, routinesTrigger]) {
    await control.hover();
    await settleIconControlVisual(control);
    expect(
      await control.evaluate((element) => {
        const style = getComputedStyle(element);
        return {
          backgroundColor: style.backgroundColor,
          color: style.color,
        };
      })
    ).toEqual(toggleSidebarHoverVisual);
  }
  await routinesTrigger.hover();
  await page.locator(".comma-home-chat").hover();
  await testClock().advance(300);
  await expect(routinesTrigger).toBeFocused();
  const triggerBoundsBeforePress = await routinesTrigger.boundingBox();
  expect(triggerBoundsBeforePress).not.toBeNull();
  await routinesTrigger.hover();
  await page.mouse.down();
  await routinesTrigger.evaluate((element) =>
    Promise.all(element.getAnimations().map((animation) => animation.finished))
  );
  const triggerBoundsDuringPress = await routinesTrigger.boundingBox();
  expect(triggerBoundsDuringPress).not.toBeNull();
  for (const dimension of ["x", "y", "width", "height"] as const) {
    expect(
      Math.abs(
        triggerBoundsDuringPress![dimension] - triggerBoundsBeforePress![dimension]
      )
    ).toBeLessThan(0.1);
  }
  await page.mouse.up();
  const routinesDialog = page.getByRole("dialog", { name: "Customize routines" });
  await expect(routinesDialog).toBeVisible();
  await expect(routinesDialog).toHaveAttribute("data-has-cards", "true");
  const routinesPopover = page.locator('[data-slot="menu-popover"]', {
    has: routinesDialog,
  });
  await expect(routinesPopover).toHaveAttribute("data-animation", "anchor");
  await expect(routinesDialog).toHaveCSS("padding-top", "4px");
  await expect(routinesDialog).toHaveCSS("padding-right", "4px");
  await expect(routinesDialog).toHaveCSS("padding-bottom", "4px");
  await expect(routinesDialog).toHaveCSS("padding-left", "4px");
  await testClock().advance(550);
  const stableTriggerBounds = await routinesTrigger.boundingBox();
  const stablePopoverBounds = await routinesPopover.boundingBox();
  const firstCardBounds = await firstCard.boundingBox();
  expect(stableTriggerBounds).not.toBeNull();
  expect(stablePopoverBounds).not.toBeNull();
  expect(firstCardBounds).not.toBeNull();
  expect(Math.abs(stableTriggerBounds!.x - triggerBoundsBeforePress!.x)).toBeLessThan(
    1
  );
  expect(
    stablePopoverBounds!.x - (stableTriggerBounds!.x + stableTriggerBounds!.width)
  ).toBeCloseTo(8, 0);
  expect(stablePopoverBounds!.x).toBeGreaterThanOrEqual(
    firstCardBounds!.x + firstCardBounds!.width
  );
  await expect(routinesDialog.getByRole("row")).toHaveCount(6);
  const customProviderRow = routinesDialog.getByRole("row", {
    name: "Team follow-ups",
  });
  const customProviderImage = customProviderRow.locator(
    '.comma-recommendation-card-logo img[src="https://assets.comma.test/custom-crm.svg"]'
  );
  await expect(customProviderImage).toBeVisible();
  expect(
    await customProviderImage.evaluate(
      (image) => image instanceof HTMLImageElement && image.draggable
    )
  ).toBe(false);
  await page.evaluate(() => {
    Object.defineProperty(window, "commaNativeImageDragStarts", {
      configurable: true,
      value: 0,
      writable: true,
    });
    document.addEventListener(
      "dragstart",
      () => {
        (
          window as typeof window & { commaNativeImageDragStarts: number }
        ).commaNativeImageDragStarts += 1;
      },
      { capture: true, once: true }
    );
  });
  const customProviderImageBounds = await customProviderImage.boundingBox();
  expect(customProviderImageBounds).not.toBeNull();
  await page.mouse.move(
    customProviderImageBounds!.x + customProviderImageBounds!.width / 2,
    customProviderImageBounds!.y + customProviderImageBounds!.height / 2
  );
  await page.mouse.down();
  await page.mouse.move(
    customProviderImageBounds!.x + customProviderImageBounds!.width / 2 + 24,
    customProviderImageBounds!.y + customProviderImageBounds!.height / 2 + 8,
    { steps: 4 }
  );
  await page.mouse.up();
  expect(
    await page.evaluate(
      () =>
        (window as typeof window & { commaNativeImageDragStarts: number })
          .commaNativeImageDragStarts
    )
  ).toBe(0);
  await expect(page.locator("html")).not.toHaveAttribute("data-comma-routine-dragging");
  const firstRoutineRow = routinesDialog.getByRole("row", {
    name: "Old mock card",
  });
  await expect(firstRoutineRow).toHaveCSS("height", "32px");
  await expect(firstRoutineRow).toHaveCSS("cursor", "default");
  const firstDragHandleBounds = await firstRoutineRow
    .locator(".comma-routines-card-drag-hit-area")
    .boundingBox();
  expect(firstDragHandleBounds).not.toBeNull();
  const dragHandleHitTarget = await page.evaluate(
    ({ x, y }) => {
      const target = document.elementFromPoint(x, y);
      return {
        cursor: target ? getComputedStyle(target).cursor : null,
        isDragHitArea: target?.matches(".comma-routines-card-drag-hit-area") ?? false,
        isRoutineRow: Boolean(target?.closest(".comma-routines-card-row")),
      };
    },
    {
      x: firstDragHandleBounds!.x + firstDragHandleBounds!.width / 2,
      y: firstDragHandleBounds!.y + firstDragHandleBounds!.height / 2,
    }
  );
  expect(dragHandleHitTarget).toEqual({
    cursor: "grab",
    isDragHitArea: true,
    isRoutineRow: true,
  });
  const firstRoutineTitle = firstRoutineRow.locator(".comma-routines-card-title");
  const firstRoutineTitleBounds = await firstRoutineTitle.boundingBox();
  expect(firstRoutineTitleBounds).not.toBeNull();
  expect(
    await page.evaluate(
      ({ x, y }) => {
        const target = document.elementFromPoint(x, y);
        return target ? getComputedStyle(target).cursor : null;
      },
      {
        x: firstRoutineTitleBounds!.x + firstRoutineTitleBounds!.width / 2,
        y: firstRoutineTitleBounds!.y + firstRoutineTitleBounds!.height / 2,
      }
    )
  ).toBe("default");
  const firstVisibilityTrigger = firstRoutineRow.getByRole("button", {
    name: /Old mock card visibility$/,
  });
  await expect(firstVisibilityTrigger).toHaveCSS("height", "32px");
  await expect(firstVisibilityTrigger).toHaveCSS(
    "background-color",
    "rgba(0, 0, 0, 0)"
  );
  await expect(firstVisibilityTrigger).toHaveCSS("width", "108px");
  const initialVisibilityBounds = await firstVisibilityTrigger.boundingBox();
  expect(initialVisibilityBounds).not.toBeNull();
  const actionsMenu = routinesDialog.locator(".comma-routines-panel-actions");
  await expect(actionsMenu).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
  await expect(actionsMenu.getByRole("menuitem", { name: "Refresh" })).toHaveCount(0);
  const settingsActionItem = actionsMenu.getByRole("menuitem", {
    name: "Routines settings",
  });
  const settingsContent = settingsActionItem.locator('[data-slot="menu-item-content"]');
  await expect(settingsActionItem).toHaveCSS("display", "block");
  await expect(settingsActionItem).toHaveCSS("font-size", "13px");
  expect(
    await settingsActionItem.evaluate(
      (element) => element.getBoundingClientRect().height
    )
  ).toBeCloseTo(32, 0);
  await expect(settingsContent).toHaveCSS("height", "32px");
  await expect(settingsContent).toHaveCSS("padding-top", "6px");
  await expect(settingsContent).toHaveCSS("padding-bottom", "6px");
  await expect(settingsActionItem.locator('[data-slot="menu-item-icon"]')).toHaveCount(
    0
  );
  expect(
    await settingsContent.evaluate((element) => {
      const probe = document.createElement("span");
      probe.style.color = "var(--color-text-tertiary)";
      element.append(probe);
      const matches = getComputedStyle(probe).color === getComputedStyle(element).color;
      probe.remove();
      return matches;
    })
  ).toBe(true);
  // It opens Settings on the Routines category, not the Settings root.
  expect(await settingsActionItem.getAttribute("href")).toBe(
    "/#/settings?category=recommendations"
  );
  const settingsLabelBox = await settingsActionItem
    .locator('[data-slot="menu-item-label"]')
    .boundingBox();
  expect(settingsLabelBox).not.toBeNull();
  const firstRowContentLeft = await firstRoutineRow.evaluate(
    (row) =>
      row.getBoundingClientRect().left + parseFloat(getComputedStyle(row).paddingLeft)
  );
  expect(Math.abs(settingsLabelBox!.x - firstRowContentLeft)).toBeLessThan(0.5);
  const dividerInsets = await actionsMenu.evaluate((element) => {
    const panel = element.closest(".comma-routines-panel")!;
    const panelRect = panel.getBoundingClientRect();
    const panelStyle = getComputedStyle(panel);
    const rect = element.getBoundingClientRect();
    return {
      left: rect.left - (panelRect.left + parseFloat(panelStyle.borderLeftWidth)),
      right: panelRect.right - parseFloat(panelStyle.borderRightWidth) - rect.right,
    };
  });
  expect(Math.abs(dividerInsets.left)).toBeLessThan(0.5);
  expect(Math.abs(dividerInsets.right)).toBeLessThan(0.5);
  const triggerLabelToChevronGap = await firstVisibilityTrigger.evaluate((trigger) => {
    const label = trigger.querySelector('[data-slot="dropdown-row-label"]')!;
    const indicator = trigger.querySelector('[data-slot="dropdown-row-indicator"]')!;
    return indicator.getBoundingClientRect().left - label.getBoundingClientRect().right;
  });
  expect(triggerLabelToChevronGap).toBeCloseTo(4, 1);
  const visibility = routinesDialog.getByRole("button", {
    name: /Old mock card visibility$/,
  });
  await visibility.click();
  const selectedVisibilityOption = page
    .getByRole("option", { name: "Show" })
    .locator('[data-slot="dropdown-option-content"]');
  const triggerVisibilityLabel = firstVisibilityTrigger.locator(
    '[data-slot="dropdown-trigger-label"]'
  );
  const selectedVisibilityLabel = selectedVisibilityOption.locator(
    '[data-slot="dropdown-option-label"]'
  );
  const hiddenOptionLabel = page
    .getByRole("option", { name: "Hidden" })
    .locator('[data-slot="dropdown-option-label"]');
  await waitForSettledMotion(
    page.getByRole("dialog", { name: "Old mock card visibility", exact: true })
  );
  const triggerBoundsWhileOpen = await firstVisibilityTrigger.boundingBox();
  const selectedOptionBounds = await selectedVisibilityOption.boundingBox();
  const triggerLabelBounds = await readTextInkBounds(triggerVisibilityLabel);
  const selectedLabelBounds = await readTextInkBounds(selectedVisibilityLabel);
  const hiddenOptionLabelBounds = await readTextInkBounds(hiddenOptionLabel);
  expect(triggerBoundsWhileOpen).not.toBeNull();
  expect(selectedOptionBounds).not.toBeNull();
  expect(triggerLabelBounds.width).toBeGreaterThan(0);
  expect(selectedLabelBounds.width).toBeGreaterThan(0);
  expect(Math.abs(selectedOptionBounds!.y - triggerBoundsWhileOpen!.y)).toBeLessThan(
    0.5
  );
  expect(
    Math.abs(selectedOptionBounds!.height - triggerBoundsWhileOpen!.height)
  ).toBeLessThan(0.1);
  // The text is the anchor: the checked option's ink opens exactly over the
  // trigger's ink (the popover slides sideways to meet the end-aligned
  // trigger label), while the option list itself stays start-aligned.
  expect(Math.abs(selectedLabelBounds.right - triggerLabelBounds.right)).toBeLessThan(
    0.5
  );
  expect(Math.abs(selectedLabelBounds.left - triggerLabelBounds.left)).toBeLessThan(
    0.5
  );
  expect(Math.abs(selectedLabelBounds.top - triggerLabelBounds.top)).toBeLessThan(0.5);
  expect(Math.abs(selectedLabelBounds.bottom - triggerLabelBounds.bottom)).toBeLessThan(
    0.5
  );
  // Options of different text widths share a left ink edge.
  expect(
    Math.abs(hiddenOptionLabelBounds.left - selectedLabelBounds.left)
  ).toBeLessThan(0.5);
  await page.getByRole("option", { name: "Hidden" }).click();
  await expect(firstCard).toHaveCount(0);
  const hiddenVisibilityTrigger = routinesDialog.getByRole("button", {
    name: /Old mock card visibility$/,
  });
  const hiddenVisibilityBounds = await hiddenVisibilityTrigger.boundingBox();
  expect(hiddenVisibilityBounds).not.toBeNull();
  expect(Math.abs(hiddenVisibilityBounds!.x - initialVisibilityBounds!.x)).toBeLessThan(
    0.1
  );
  expect(
    Math.abs(hiddenVisibilityBounds!.width - initialVisibilityBounds!.width)
  ).toBeLessThan(0.1);
  const hiddenVisibilityLabel = hiddenVisibilityTrigger.locator(
    '[data-slot="dropdown-trigger-label"]'
  );
  await expect(hiddenVisibilityLabel).toHaveText("Hidden");
  expect(
    await hiddenVisibilityLabel.evaluate(
      (element) => element.scrollWidth <= element.clientWidth
    )
  ).toBe(true);
  await hiddenVisibilityTrigger.click();
  const selectedHiddenOption = page
    .getByRole("option", { name: "Hidden" })
    .locator('[data-slot="dropdown-option-content"]');
  const selectedHiddenLabel = selectedHiddenOption.locator(
    '[data-slot="dropdown-option-label"]'
  );
  await waitForSettledMotion(
    page.getByRole("dialog", { name: "Old mock card visibility", exact: true })
  );
  const hiddenTriggerBoundsWhileOpen = await hiddenVisibilityTrigger.boundingBox();
  const selectedHiddenOptionBounds = await selectedHiddenOption.boundingBox();
  const hiddenTriggerLabelBounds = await readTextInkBounds(hiddenVisibilityLabel);
  const selectedHiddenLabelBounds = await readTextInkBounds(selectedHiddenLabel);
  expect(
    Math.abs(hiddenTriggerLabelBounds.right - triggerLabelBounds.right)
  ).toBeLessThan(0.5);
  expect(hiddenTriggerBoundsWhileOpen).not.toBeNull();
  expect(selectedHiddenOptionBounds).not.toBeNull();
  expect(
    Math.abs(selectedHiddenOptionBounds!.y - hiddenTriggerBoundsWhileOpen!.y)
  ).toBeLessThan(0.5);
  expect(
    Math.abs(selectedHiddenOptionBounds!.height - hiddenTriggerBoundsWhileOpen!.height)
  ).toBeLessThan(0.1);
  expect(
    Math.abs(selectedHiddenLabelBounds.right - hiddenTriggerLabelBounds.right)
  ).toBeLessThan(0.5);
  expect(
    Math.abs(selectedHiddenLabelBounds.left - hiddenTriggerLabelBounds.left)
  ).toBeLessThan(0.5);
  expect(
    Math.abs(selectedHiddenLabelBounds.top - hiddenTriggerLabelBounds.top)
  ).toBeLessThan(0.5);
  expect(
    Math.abs(selectedHiddenLabelBounds.bottom - hiddenTriggerLabelBounds.bottom)
  ).toBeLessThan(0.5);
  await page.getByRole("option", { name: "Show" }).click();
  await eventually(
    () => routineCardTitles(page),
    (titles) =>
      expect(titles).toEqual([
        "Old mock card",
        "Next mock card",
        ...additionalMockCardTitles,
      ])
  );

  const bottomRoutineTitle = additionalMockCardTitles.at(-1)!;
  const bottomRoutineRow = routinesDialog.getByRole("row", {
    name: bottomRoutineTitle,
  });
  const bottomVisibilityTrigger = bottomRoutineRow.getByRole("button", {
    name: new RegExp(`${bottomRoutineTitle} visibility$`),
  });
  await bottomVisibilityTrigger.click();
  const routeBeforeBottomVisibilityChange = page.url();
  const bottomVisibilityDialog = page.getByRole("dialog", {
    name: `${bottomRoutineTitle} visibility`,
    exact: true,
  });
  // The previous card's menu can still be leaving; read this card's option.
  const bottomHiddenOption = bottomVisibilityDialog.getByRole("option", {
    name: "Hidden",
  });
  await waitForSettledMotion(bottomVisibilityDialog);
  const bottomHiddenOptionBounds = await bottomHiddenOption.boundingBox();
  const settingsActionBounds = await settingsActionItem.boundingBox();
  expect(bottomHiddenOptionBounds).not.toBeNull();
  expect(settingsActionBounds).not.toBeNull();
  const bottomHiddenOptionCenter = {
    x: bottomHiddenOptionBounds!.x + bottomHiddenOptionBounds!.width / 2,
    y: bottomHiddenOptionBounds!.y + bottomHiddenOptionBounds!.height / 2,
  };
  expect(bottomHiddenOptionCenter.x).toBeGreaterThan(settingsActionBounds!.x);
  expect(bottomHiddenOptionCenter.x).toBeLessThan(
    settingsActionBounds!.x + settingsActionBounds!.width
  );
  expect(bottomHiddenOptionCenter.y).toBeGreaterThan(settingsActionBounds!.y);
  expect(bottomHiddenOptionCenter.y).toBeLessThan(
    settingsActionBounds!.y + settingsActionBounds!.height
  );
  await page.mouse.move(bottomHiddenOptionCenter.x, bottomHiddenOptionCenter.y);
  await page.mouse.down();
  await page.mouse.up();
  await expect(page).toHaveURL(routeBeforeBottomVisibilityChange);
  await expect(routinesDialog).toBeVisible();
  await expect(page.getByRole("group", { name: bottomRoutineTitle })).toHaveCount(0);
  await bottomVisibilityTrigger.click();
  await page.getByRole("option", { name: "Show" }).click();
  await expect(page.getByRole("group", { name: bottomRoutineTitle })).toBeVisible();

  const oldRoutineRow = routinesDialog.getByRole("row", {
    exact: true,
    name: "Old mock card",
  });
  const nextRoutineRow = routinesDialog.getByRole("row", {
    exact: true,
    name: "Next mock card",
  });
  // Keep Greeting above its 681px route floor beside the 68px app rail
  // and 8px window inset, so closing the menu can restore its trigger.
  await page.setViewportSize({ height: 800, width: 780 });
  await expect(page.getByTestId("home-greet-rail")).toHaveAttribute(
    "data-folded",
    "false"
  );
  await expect(routinesDialog).toBeVisible();
  await eventually(
    async () => {
      const box = await oldRoutineRow.boundingBox();
      if (!box) return false;
      const center = box.x + box.width / 2;
      return center >= 0 && center <= 780;
    },
    (value) => expect(value).toBe(true)
  );
  await expect(page.locator('[data-slot="dropdown-popover"]')).toBeHidden();
  await waitForSettledMotion(
    routinesDialog.locator('xpath=ancestor::*[@data-slot="menu-popover"][1]')
  );
  const oldRowBox = await oldRoutineRow.boundingBox();
  const nextRowBox = await nextRoutineRow.boundingBox();
  expect(oldRowBox).not.toBeNull();
  expect(nextRowBox).not.toBeNull();
  await page.evaluate(() => {
    const dragWindow = window as typeof window & {
      commaRoutineDragEvidence?: RoutineDragEvidence;
    };
    dragWindow.commaRoutineDragEvidence = { nativeDragImageCalls: 0 };
    const originalAnimate = Element.prototype.animate;
    Element.prototype.animate = function animateRoutineLayout(keyframes, options) {
      if (this instanceof HTMLElement && this.matches(".comma-routines-card-row")) {
        const frames = Array.isArray(keyframes) ? keyframes : [];
        const current = dragWindow.commaRoutineDragEvidence;
        if (current) {
          current.layoutAnimation = {
            duration:
              typeof options === "number"
                ? options
                : typeof options?.duration === "number"
                  ? options.duration
                  : null,
            transforms: frames.map((frame) => frame.transform?.toString() ?? null),
          };
        }
      }
      return originalAnimate.call(this, keyframes, options);
    };
    const originalSetDragImage = DataTransfer.prototype.setDragImage;
    DataTransfer.prototype.setDragImage = function setRoutineDragImage(element, x, y) {
      dragWindow.commaRoutineDragEvidence!.nativeDragImageCalls += 1;
      originalSetDragImage.call(this, element, x, y);
    };
  });
  const routineHoverVisualBefore = await oldRoutineRow.evaluate((row) => ({
    backgroundColor: getComputedStyle(row).backgroundColor,
    handleColor: getComputedStyle(
      row.querySelector<HTMLElement>(".comma-routines-card-drag-handle")!
    ).color,
  }));
  await page.mouse.move(
    oldRowBox!.x + oldRowBox!.width / 2,
    oldRowBox!.y + oldRowBox!.height / 2
  );
  await expect(oldRoutineRow).toHaveAttribute("data-hovered", "true");
  await oldRoutineRow.evaluate(async (row) => {
    await new Promise<void>((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
    });
    const handle = row.querySelector<HTMLElement>(".comma-routines-card-drag-handle");
    await Promise.all(
      [...row.getAnimations(), ...(handle?.getAnimations() ?? [])].map(
        (animation) => animation.finished
      )
    );
  });
  const routineHoverVisualAfter = await oldRoutineRow.evaluate((row) => ({
    backgroundColor: getComputedStyle(row).backgroundColor,
    handleColor: getComputedStyle(
      row.querySelector<HTMLElement>(".comma-routines-card-drag-handle")!
    ).color,
  }));
  expect(routineHoverVisualAfter).toEqual(routineHoverVisualBefore);
  expect(routineHoverVisualAfter.backgroundColor).toBe("rgba(0, 0, 0, 0)");
  const oldDragHitAreaBox = await oldRoutineRow
    .locator(".comma-routines-card-drag-hit-area")
    .boundingBox();
  expect(oldDragHitAreaBox).not.toBeNull();
  expect(
    await oldRoutineRow.evaluate((row) => row instanceof HTMLElement && row.draggable)
  ).toBe(false);
  await oldRoutineRow.evaluate((row) => {
    row.dataset.directSortSource = "true";
  });
  await page.mouse.move(
    oldDragHitAreaBox!.x + oldDragHitAreaBox!.width / 2,
    oldDragHitAreaBox!.y + oldDragHitAreaBox!.height / 2
  );
  await page.mouse.down();
  await page.mouse.move(
    oldDragHitAreaBox!.x + oldDragHitAreaBox!.width / 2,
    oldDragHitAreaBox!.y + oldDragHitAreaBox!.height / 2 + 2
  );
  await expect(page.locator("html")).not.toHaveAttribute("data-comma-routine-dragging");
  await expect(oldRoutineRow).not.toHaveAttribute("data-pointer-dragging");
  await page.mouse.move(
    oldDragHitAreaBox!.x + oldDragHitAreaBox!.width / 2,
    oldDragHitAreaBox!.y + oldDragHitAreaBox!.height / 2 + 8,
    { steps: 4 }
  );
  await expect(page.locator("html")).toHaveAttribute(
    "data-comma-routine-dragging",
    "true"
  );
  await expect(oldRoutineRow).toHaveAttribute("data-pointer-dragging", "true");
  await expect(oldRoutineRow).not.toHaveAttribute("data-dragging");
  await expect(oldRoutineRow).toHaveCSS("cursor", "grabbing");
  // The picked-up row lifts: opaque popup surface, elevation shadow, and the
  // drag-lift scale, so it reads as a card sliding above the list.
  await eventually(
    () =>
      oldRoutineRow.evaluate((row) => {
        const probe = document.createElement("div");
        probe.style.backgroundColor = "var(--color-bg-popup-secondary)";
        row.append(probe);
        const matches =
          getComputedStyle(probe).backgroundColor ===
          getComputedStyle(row).backgroundColor;
        probe.remove();
        return matches;
      }),
    (value) => expect(value).toBe(true)
  );
  // Elevation rides on the pseudo-element's opacity; the row's own
  // box-shadow channel stays reserved for the instant focus ring, and the
  // row is never scaled (the scroll viewport would clip it).
  await eventually(
    () =>
      oldRoutineRow.evaluate((row) => {
        const pseudo = getComputedStyle(row, "::after");
        return {
          boxShadowIsNone: pseudo.boxShadow === "none",
          opacity: pseudo.opacity,
        };
      }),
    (value) => expect(value).toEqual({ boxShadowIsNone: false, opacity: "1" })
  );
  await expect(oldRoutineRow).toHaveCSS("scale", "none");
  await expect(oldRoutineRow).not.toHaveCSS("transform", "none");
  await expect(oldRoutineRow.locator(".comma-routines-card-title")).toHaveCSS(
    "opacity",
    "1"
  );
  await expect(
    routinesDialog.locator('[data-slot="routine-drag-preview"]')
  ).toHaveCount(0);
  await expect(
    routinesDialog.locator(".react-aria-DropIndicator[data-drop-target]")
  ).toHaveCount(0);
  await page.mouse.move(
    nextRowBox!.x + nextRowBox!.width / 2,
    nextRowBox!.y + nextRowBox!.height - 2,
    { steps: 8 }
  );
  await page.evaluate(
    () =>
      new Promise<void>((resolve) => {
        requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
      })
  );
  await nextRoutineRow.evaluate((row) =>
    Promise.all(
      row.getAnimations().map((animation) => animation.finished.catch(() => undefined))
    )
  );
  await expect(routinesDialog.locator(".comma-routines-card-title")).toHaveText([
    "Old mock card",
    "Next mock card",
    ...additionalMockCardTitles,
  ]);
  await expect(nextRoutineRow).toHaveAttribute("data-routine-drag-shift", "up");
  const sourceVisualBeforeDrop = await oldRoutineRow.boundingBox();
  const nextVisualBeforeDrop = await nextRoutineRow.boundingBox();
  expect(sourceVisualBeforeDrop).not.toBeNull();
  expect(nextVisualBeforeDrop).not.toBeNull();
  expect(sourceVisualBeforeDrop!.y).toBeGreaterThan(nextRowBox!.y);
  expect(Math.abs(nextVisualBeforeDrop!.y - oldRowBox!.y)).toBeLessThan(1);
  expect(await oldRoutineRow.getAttribute("data-direct-sort-source")).toBe("true");
  const dragEvidenceBeforeDrop = await page.evaluate(
    () =>
      (
        window as typeof window & {
          commaRoutineDragEvidence?: RoutineDragEvidence;
        }
      ).commaRoutineDragEvidence
  );
  expect(dragEvidenceBeforeDrop?.nativeDragImageCalls).toBe(0);
  await page.evaluate(() => {
    const dragWindow = window as typeof window & {
      commaRoutineDragRecordingComplete?: boolean;
      commaRoutineDragFrames?: RoutineDragFrame[];
    };
    dragWindow.commaRoutineDragRecordingComplete = false;
    dragWindow.commaRoutineDragFrames = [];
    const stopAt = performance.now() + 500;

    const recordFrame = () => {
      const rows = Array.from(
        document.querySelectorAll<HTMLElement>(".comma-routines-card-row")
      );
      const rowFrames = rows.map((row) => ({
        title:
          row.querySelector(".comma-routines-card-title")?.textContent?.trim() ?? "",
        top: row.getBoundingClientRect().top,
      }));
      dragWindow.commaRoutineDragFrames?.push({
        hasTransformAnimation: rows.some((row) =>
          row.getAnimations().some((animation) => {
            const effect = animation.effect;
            return (
              animation.playState === "running" &&
              effect instanceof KeyframeEffect &&
              effect
                .getKeyframes()
                .some(
                  (frame) =>
                    typeof frame.transform === "string" && frame.transform !== "none"
                )
            );
          })
        ),
        order: rowFrames.map(({ title }) => title),
        tops: Object.fromEntries(rowFrames.map(({ title, top }) => [title, top])),
      });
      if (performance.now() < stopAt) requestAnimationFrame(recordFrame);
      else dragWindow.commaRoutineDragRecordingComplete = true;
    };
    requestAnimationFrame(recordFrame);
  });
  await page.mouse.up();
  await expect(page.locator("html")).not.toHaveAttribute("data-comma-routine-dragging");
  await expect(oldRoutineRow).not.toHaveAttribute("data-pointer-dragging");
  await expect(nextRoutineRow).not.toHaveAttribute("data-routine-drag-shift");
  await expect(oldRoutineRow.locator(".comma-routines-card-title")).toHaveCSS(
    "opacity",
    "1"
  );
  await eventually(
    () => routineCardTitles(page),
    (titles) =>
      expect(titles).toEqual([
        "Next mock card",
        "Old mock card",
        ...additionalMockCardTitles,
      ])
  );
  await eventually(
    () =>
      page.evaluate(
        () =>
          (
            window as typeof window & {
              commaRoutineDragRecordingComplete?: boolean;
            }
          ).commaRoutineDragRecordingComplete ?? false
      ),
    (value) => expect(value).toBe(true)
  );
  const dragEvidence = await page.evaluate(
    () =>
      (
        window as typeof window & {
          commaRoutineDragEvidence?: RoutineDragEvidence;
        }
      ).commaRoutineDragEvidence
  );
  const dragFrames = await page.evaluate(
    () =>
      (
        window as typeof window & {
          commaRoutineDragFrames?: RoutineDragFrame[];
        }
      ).commaRoutineDragFrames ?? []
  );
  expect(dragEvidence).toMatchObject({
    layoutAnimation: {
      // motionDuration.spatialMove: the drop travels back into its slot on
      // the same beat as the lift fade. Offsets may be fractional from
      // sub-pixel row positions at the drop instant.
      duration: 200,
      transforms: [
        expect.stringMatching(/^translateY\(-?\d+(?:\.\d+)?px\)$/),
        "translateY(0)",
      ],
    },
    nativeDragImageCalls: 0,
  });
  const firstReorderedFrame = dragFrames.find(
    (frame) => frame.order[0] === "Next mock card"
  );
  expect(firstReorderedFrame).toBeDefined();
  expect(firstReorderedFrame!.hasTransformAnimation).toBe(true);
  const firstOldCardTop = firstReorderedFrame!.tops["Old mock card"];
  const firstNextCardTop = firstReorderedFrame!.tops["Next mock card"];
  expect(firstOldCardTop).toBeDefined();
  expect(firstNextCardTop).toBeDefined();
  expect(Math.abs(firstOldCardTop! - sourceVisualBeforeDrop!.y)).toBeLessThan(8);
  expect(Math.abs(firstNextCardTop! - nextVisualBeforeDrop!.y)).toBeLessThan(8);
  const settledFrame = dragFrames.at(-1);
  expect(settledFrame?.order[0]).toBe("Next mock card");
  expect(settledFrame?.hasTransformAnimation).toBe(false);
  const settledOldCardTop = settledFrame!.tops["Old mock card"];
  const settledNextCardTop = settledFrame!.tops["Next mock card"];
  expect(settledOldCardTop).toBeDefined();
  expect(settledNextCardTop).toBeDefined();
  expect(Math.abs(settledNextCardTop! - oldRowBox!.y)).toBeLessThan(1);
  expect(Math.abs(settledOldCardTop! - nextRowBox!.y)).toBeLessThan(1);

  const reorderedOldHitArea = oldRoutineRow.locator(
    ".comma-routines-card-drag-hit-area"
  );
  const reorderedOldHitAreaBox = await reorderedOldHitArea.boundingBox();
  expect(reorderedOldHitAreaBox).not.toBeNull();
  await page.mouse.move(
    reorderedOldHitAreaBox!.x + reorderedOldHitAreaBox!.width / 2,
    reorderedOldHitAreaBox!.y + reorderedOldHitAreaBox!.height / 2
  );
  await page.mouse.down();
  await page.mouse.move(
    reorderedOldHitAreaBox!.x + reorderedOldHitAreaBox!.width / 2,
    reorderedOldHitAreaBox!.y + reorderedOldHitAreaBox!.height / 2 - 40,
    { steps: 6 }
  );
  await expect(oldRoutineRow).toHaveAttribute("data-pointer-dragging", "true");
  await expect(nextRoutineRow).toHaveAttribute("data-routine-drag-shift", "down");
  await page.keyboard.press("Escape");
  await page.mouse.up();
  await expect(routinesDialog).toBeVisible();
  await expect(page.locator("html")).not.toHaveAttribute("data-comma-routine-dragging");
  await expect(oldRoutineRow).not.toHaveAttribute("data-pointer-dragging");
  await expect(nextRoutineRow).not.toHaveAttribute("data-routine-drag-shift");
  await testClock().advance(350);
  await expect(oldRoutineRow).toHaveCSS("transform", "none");
  await expect(nextRoutineRow).toHaveCSS("transform", "none");
  await expect(routinesDialog.locator(".comma-routines-card-title")).toHaveText([
    "Next mock card",
    "Old mock card",
    ...additionalMockCardTitles,
  ]);

  // Dragging far past the list's end must pin the row to the last slot: an
  // unclamped translation extends the scroll viewport's scrollable overflow
  // and the edge auto-scroll chases it into an ever-growing blank region.
  const routineScrollViewport = routinesDialog.locator(
    ".comma-routines-card-scroll .comma-scroll-area__viewport"
  );
  const panelBoxBeforeOverdrag = await routinesDialog.boundingBox();
  const lastRoutineRow = routinesDialog.getByRole("row", {
    name: additionalMockCardTitles.at(-1)!,
  });
  const lastRowBoxBeforeOverdrag = await lastRoutineRow.boundingBox();
  const overdragHitAreaBox = await nextRoutineRow
    .locator(".comma-routines-card-drag-hit-area")
    .boundingBox();
  expect(panelBoxBeforeOverdrag).not.toBeNull();
  expect(lastRowBoxBeforeOverdrag).not.toBeNull();
  expect(overdragHitAreaBox).not.toBeNull();
  await page.mouse.move(
    overdragHitAreaBox!.x + overdragHitAreaBox!.width / 2,
    overdragHitAreaBox!.y + overdragHitAreaBox!.height / 2
  );
  await page.mouse.down();
  await page.mouse.move(
    overdragHitAreaBox!.x + overdragHitAreaBox!.width / 2,
    lastRowBoxBeforeOverdrag!.y + lastRowBoxBeforeOverdrag!.height + 320,
    { steps: 10 }
  );
  await expect(nextRoutineRow).toHaveAttribute("data-pointer-dragging", "true");
  // Overshoot past the last slot is rubber-banded: at most the damped cap
  // (routineDragOverdragCap = spacing.md), never a runaway translation.
  const overdragCap = 8;
  const overdraggedRowBox = await nextRoutineRow.boundingBox();
  expect(overdraggedRowBox).not.toBeNull();
  expect(overdraggedRowBox!.y).toBeLessThanOrEqual(
    lastRowBoxBeforeOverdrag!.y + overdragCap + 1
  );
  // Damped cap plus fractional row offsets and integer rounding of
  // scrollHeight — bounded, versus a runaway translation.
  expect(
    await routineScrollViewport.evaluate(
      (viewport) => viewport.scrollHeight - viewport.clientHeight
    )
  ).toBeLessThan(overdragCap + 5);
  const panelBoxDuringOverdrag = await routinesDialog.boundingBox();
  expect(panelBoxDuringOverdrag).not.toBeNull();
  expect(
    Math.abs(panelBoxDuringOverdrag!.height - panelBoxBeforeOverdrag!.height)
  ).toBeLessThan(1);
  await page.keyboard.press("Escape");
  await page.mouse.up();
  await expect(routinesDialog).toBeVisible();
  await expect(nextRoutineRow).not.toHaveAttribute("data-pointer-dragging");
  await testClock().advance(350);
  await expect(routinesDialog.locator(".comma-routines-card-title")).toHaveText([
    "Next mock card",
    "Old mock card",
    ...additionalMockCardTitles,
  ]);

  const keyboardReorder = oldRoutineRow.getByRole("button", {
    name: "Reorder Old mock card",
  });
  await keyboardReorder.focus();
  await page.keyboard.press("Enter");
  await expect(oldRoutineRow).toHaveAttribute("data-dragging", "true");
  await expect(page.locator("html")).toHaveAttribute(
    "data-comma-routine-dragging",
    "true"
  );
  await page.evaluate(
    () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve()))
  );
  await page.keyboard.press("Escape");
  await expect(oldRoutineRow).not.toHaveAttribute("data-dragging");
  await expect(page.locator("html")).not.toHaveAttribute("data-comma-routine-dragging");
  await expect(routinesDialog).toBeVisible();

  await page.keyboard.press("Escape");
  await expect(routinesDialog).toBeHidden();
  await expect(routinesTrigger).toBeFocused();
  await page.setViewportSize({ height: 180, width: 1280 });
  await routinesTrigger.click();
  const settingsAction = page.getByRole("menuitem", {
    name: "Routines settings",
  });
  await waitForSettledMotion(
    routinesDialog.locator('xpath=ancestor::*[@data-slot="menu-popover"][1]')
  );
  const constrainedPanel = await routinesDialog.evaluate((panel) => {
    const scrollViewport = panel.querySelector<HTMLElement>(
      ".comma-routines-card-scroll .comma-scroll-area__viewport"
    );
    const settingsItem = panel.querySelector<HTMLElement>(
      '[role="menuitem"][data-key="settings"]'
    );
    if (!scrollViewport || !settingsItem) return null;
    const panelRect = panel.getBoundingClientRect();
    const settingsRect = settingsItem.getBoundingClientRect();
    return {
      panelBottom: panelRect.bottom,
      panelTop: panelRect.top,
      scrollClientHeight: scrollViewport.clientHeight,
      scrollHeight: scrollViewport.scrollHeight,
      settingsBottom: settingsRect.bottom,
      viewportHeight: window.innerHeight,
    };
  });
  expect(constrainedPanel).not.toBeNull();
  expect(constrainedPanel!.panelTop).toBeGreaterThanOrEqual(0);
  expect(constrainedPanel!.panelBottom).toBeLessThanOrEqual(
    constrainedPanel!.viewportHeight
  );
  expect(constrainedPanel!.settingsBottom).toBeLessThanOrEqual(
    constrainedPanel!.viewportHeight
  );
  expect(constrainedPanel!.scrollHeight).toBeGreaterThan(
    constrainedPanel!.scrollClientHeight
  );
  await expect(settingsAction).toBeVisible();
  const constrainedScrollViewport = routinesDialog.locator(
    ".comma-routines-card-scroll .comma-scroll-area__viewport"
  );
  await constrainedScrollViewport.evaluate((viewport) => {
    viewport.scrollTop = 0;
  });
  const constrainedFirstRow = routinesDialog.getByRole("row", {
    exact: true,
    name: "Next mock card",
  });
  const constrainedDragHandle = constrainedFirstRow.locator(
    ".comma-routines-card-drag-hit-area"
  );
  const constrainedDragHandleBox = await constrainedDragHandle.boundingBox();
  const constrainedViewportBox = await constrainedScrollViewport.boundingBox();
  expect(constrainedDragHandleBox).not.toBeNull();
  expect(constrainedViewportBox).not.toBeNull();
  await page.mouse.move(
    constrainedDragHandleBox!.x + constrainedDragHandleBox!.width / 2,
    constrainedDragHandleBox!.y + constrainedDragHandleBox!.height / 2
  );
  await page.mouse.down();
  await page.mouse.move(
    constrainedDragHandleBox!.x + constrainedDragHandleBox!.width / 2,
    constrainedViewportBox!.y + constrainedViewportBox!.height - 1,
    { steps: 6 }
  );
  await eventually(
    () => constrainedScrollViewport.evaluate((viewport) => viewport.scrollTop),
    (value) => expect(value).toBeGreaterThan(0)
  );
  await expect(constrainedFirstRow).toHaveAttribute("data-pointer-dragging", "true");
  await page.keyboard.press("Escape");
  await page.mouse.up();
  await expect(routinesDialog).toBeVisible();
  await expect(constrainedFirstRow).not.toHaveAttribute("data-pointer-dragging");
  await page.keyboard.press("Escape");
  await expect(routinesDialog).toBeHidden();
  await refreshControl.click();

  await expect(page.getByText("No routines created yet")).toBeVisible();
  await expect(page.getByRole("group", { name: "Old mock card" })).toHaveCount(0);

  // Empty Routines puts its heading first in the rail, where it must share a
  // centre line with the Tasks rail heading even though only Routines carries
  // icon controls.
  const headingCentreY = (selector: string) =>
    page.evaluate((target) => {
      const rect = document.querySelector(target)?.getBoundingClientRect();
      return rect ? rect.top + rect.height / 2 : null;
    }, selector);
  const routinesHeadingCentre = await headingCentreY(
    ".comma-recommendations-heading h2"
  );
  const tasksHeadingCentre = await headingCentreY(
    '[data-testid="home-tasks-section"] header h2'
  );
  expect(routinesHeadingCentre).not.toBeNull();
  expect(tasksHeadingCentre).not.toBeNull();
  expect(Math.abs(routinesHeadingCentre! - tasksHeadingCentre!)).toBeLessThan(0.5);

  await expect(refreshControl).toBeDisabled();
  await routinesTrigger.focus();
  await page.locator(".comma-home-chat").hover();
  await settleIconControlVisual(refreshControl);
  const disabledRefreshVisual = await readIconControlVisual(refreshControl);
  expect(disabledRefreshVisual.backgroundColor).toBe("rgba(0, 0, 0, 0)");
  await refreshControl.hover();
  await settleIconControlVisual(refreshControl);
  expect(await readIconControlVisual(refreshControl)).toEqual(disabledRefreshVisual);
});

test("exhausted Routine credits show one actionable toast and a new refusal shows it again", async ({
  page,
}) => {
  await app.stub().call("setRecommendations", { name: "no-credits" });
  await page.setViewportSize({ width: 1440, height: 900 });
  await app.open(page);
  const notice = page.getByTestId("out-of-credits");
  await expect(notice).toHaveCount(1);
  await expect(notice).toContainText("Out of Comma credits");
  await notice.getByRole("button", { name: "Dismiss notification" }).click();
  await expect(notice).toHaveCount(0);

  const previousReads = (await calls()).reads;
  // A minute later, on the world's time: the page and its core both.
  await testClock().advance(61_000);
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await eventually(
    async () => (await calls()).reads,
    (value) => expect(value).toBeGreaterThan(previousReads)
  );
  await expect(notice).toHaveCount(0);

  await page.getByRole("button", { name: "Refresh", exact: true }).click();
  await eventually(
    async () => (await calls()).refreshes,
    (value) => expect(value).toBeGreaterThan(0)
  );
  await testClock().advance(2_100);
  await expect(notice).toHaveCount(1);
  await notice.getByRole("button", { name: "Add credits" }).click();
  await expect(page).toHaveURL(/#\/settings\?category=usage-billing$/);
  await testClock().advance(500);
  await expect(notice).toHaveCount(0);
});

test("failed generation and unreadable refresh retain the briefing until an authoritative read revokes it", async ({
  page,
}) => {
  await app.stub().call("setRecommendations", { name: "fallback" });
  await page.setViewportSize({ width: 1440, height: 900 });
  await app.open(page);
  await expect(page.getByText("Old mock briefing.")).toBeVisible();
  await expect(page.getByText("Old mock card", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Refresh", exact: true }).click();
  // The failed refresh keeps the previous briefing without a notice.
  await expect(page.locator(".comma-recommendations")).toHaveAttribute(
    "data-state",
    "stale"
  );
  await expect(page.getByTestId("routine-problem-toast")).toHaveCount(0);
  await expect(page.getByText("Old mock card", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Refresh", exact: true }).click();
  await eventually(
    async () => (await calls()).readFailures,
    (value) => expect(value).toBeGreaterThan(0)
  );
  await expect(page.getByText("Old mock briefing.")).toBeVisible();
  await expect(page.getByText("Old mock card", { exact: true })).toBeVisible();
  await expect(page.getByText("Routines are unavailable")).toHaveCount(0);
  await page.getByRole("button", { name: "Refresh", exact: true }).click();
  await expect(page.getByText("Old mock briefing.")).toHaveCount(0);
  await expect(page.getByText("Old mock card", { exact: true })).toHaveCount(0);
});

test("the app language is an account setting that every device follows", async ({
  page,
}) => {
  await app.stub().call("setRecommendations", { name: "empty" });
  const profileWrites = () => app.stub().call("profileWrites") as Promise<unknown[]>;

  // An account without a language takes this device's language once.
  await app.open(page, "/#/settings?category=general");
  await eventually(profileWrites, (value) => expect(value).toEqual([{ locale: "en" }]));

  const languageControl = page.locator(
    '[data-setting-id="app.language"] [data-slot="settings-control"] button'
  );
  await languageControl.click();
  await expect(page.getByRole("option", { name: "Auto detect" })).toHaveCount(0);
  await page.getByRole("option", { name: "Simplified Chinese" }).click();
  await eventually(profileWrites, (value) =>
    expect(value).toEqual([{ locale: "en" }, { locale: "zh-CN" }])
  );
  await expect(page.locator("html")).toHaveAttribute("lang", "zh-CN");

  // Another device with a stale local choice follows the account.
  await page.evaluate(() => {
    localStorage.setItem(
      "comma.client-settings",
      JSON.stringify({
        ...JSON.parse(localStorage.getItem("comma.client-settings") ?? "{}"),
        localePreference: "en",
      })
    );
  });
  await page.reload();
  await expect(page.locator("html")).toHaveAttribute("lang", "zh-CN");
  expect(await profileWrites()).toHaveLength(2);
  // Routine reads never carry the language; the server reads the account.
  expect((await calls()).queries.every((query) => !query.includes("locale"))).toBe(
    true
  );
});

test("Routines settings turn the owner's proactive messages off for the active workspace", async ({
  page,
}) => {
  await app.stub().call("setRecommendations", { name: "proactive" });
  await page.addInitScript(() => {
    localStorage.setItem("comma.activeWorkspaceId", "ws-active");
  });

  await app.open(page, "/#/settings?category=recommendations");
  // The window hands its stored selection to the core, which then reads that workspace's setting.
  await eventually(
    async () => (await calls()).proactiveReads,
    (value) => expect(value).toContain("/v1/comma/groups/grp-active/proactive")
  );
  const proactiveSwitch = page.getByRole("switch", { name: "Proactive messages" });
  await expect(proactiveSwitch).toBeChecked();
  await expect(proactiveSwitch).toBeEnabled();

  await proactiveSwitch
    .locator("xpath=ancestor::label")
    .locator(".comma-toggle")
    .click();
  await expect(proactiveSwitch).not.toBeChecked();
  await eventually(
    async () => (await calls()).proactiveWrites,
    (value) =>
      expect(value).toEqual([
        {
          path: "/v1/comma/groups/grp-active/proactive",
          body: { enabled: false, request_id: expect.any(String) },
        },
      ])
  );

  // Proactive messages judge the member's own items.
  const memberSwitch = page.getByRole("switch", { name: "Only matters involving me" });
  await memberSwitch.locator("xpath=ancestor::label").locator(".comma-toggle").click();
  await expect(proactiveSwitch).toBeDisabled();
  await expect(
    page.getByText("Turn on Only matters involving me to use proactive messages.")
  ).toBeVisible();
});

test("opening the Chat Sidebar from an inline link keeps the content frame anchored", async ({
  page,
}) => {
  const linkEnvelope = {
    settings: {
      ...settings,
      sources: [
        {
          ...source,
          appId: "gmail",
          appName: "Gmail",
          connectionId: "local-gmail",
          label: "Gmail",
        },
      ],
    },
    snapshot: {
      cards: [],
      generatedAt: 1,
      generation: 1,
      protocolVersion: 1,
      sourceRevision: 1,
      summary: [
        { kind: "markdown", text: "Good morning.\n\nGmail flagged " },
        {
          kind: "inline-link",
          link: {
            href: "https://mail.google.com/mail/#all/198f2ab4c7d3e011",
            label: "Launch approval",
            sourceId: "local-gmail",
          },
        },
        { kind: "markdown", text: "." },
      ],
      templateCatalogVersion: 1,
      warnings: [],
    },
    state: "fresh",
  };
  // Samples the content frame for ~400ms and reports any horizontal drift.
  const watchContentFrame = () =>
    page.evaluate(() => {
      const content = document.querySelector<HTMLElement>(".comma-content")!;
      const outlet = document.querySelector<HTMLElement>(".comma-route-outlet")!;
      const startLeft = Math.round(outlet.getBoundingClientRect().left);
      const maxScrollLeft = { value: 0 };
      const outletLefts = new Set<number>([startLeft]);
      const start = performance.now();
      (window as unknown as { commaFrameWatch?: Promise<unknown> }).commaFrameWatch =
        new Promise<{ maxScrollLeft: number; outletLefts: number[] }>((resolve) => {
          const tick = () => {
            maxScrollLeft.value = Math.max(maxScrollLeft.value, content.scrollLeft);
            outletLefts.add(Math.round(outlet.getBoundingClientRect().left));
            if (performance.now() - start < 400) {
              requestAnimationFrame(tick);
              return;
            }
            resolve({
              maxScrollLeft: maxScrollLeft.value,
              outletLefts: [...outletLefts],
            });
          };
          requestAnimationFrame(tick);
        });
    });
  const readContentFrame = () =>
    page.evaluate(
      () => (window as unknown as { commaFrameWatch: Promise<unknown> }).commaFrameWatch
    );

  await page.setViewportSize({ width: 1600, height: 900 });
  await app
    .stub()
    .call("setRecommendations", { name: "fixed", envelope: linkEnvelope });

  await app.open(page);
  await expect(page.getByRole("heading", { name: greetingHeading })).toBeVisible();
  const chatSidebar = page.locator(".comma-content > .comma-chat-sidebar");
  await expect(chatSidebar).toHaveAttribute("data-open", "false");
  const outletLeft = await page
    .locator(".comma-route-outlet")
    .evaluate((element) => Math.round(element.getBoundingClientRect().left));

  // Opening from the inline link must not scroll the clipped content frame
  // while the sidebar width is still animating.
  await watchContentFrame();
  await page
    .locator(".comma-recommendation-inline-source", { hasText: "Launch approval" })
    .click();
  await expect(chatSidebar).toHaveAttribute("data-open", "true");
  await expect(page.getByRole("tab", { name: /mail\.google\.com/ })).toBeVisible();
  expect(await readContentFrame()).toEqual({
    maxScrollLeft: 0,
    outletLefts: [outletLeft],
  });

  // The close affordance stays inside its tab even though the shell lifts
  // header controls with an unlayered `position: relative` rule.
  const browserTabItem = page.locator(
    '.comma-right-sidebar-tab-item[data-closable="true"]'
  );
  await browserTabItem.hover();
  const closeGeometry = await browserTabItem.evaluate((item) => {
    const tab = item.querySelector(".comma-right-sidebar-tab")!.getBoundingClientRect();
    const close = item
      .querySelector(".comma-right-sidebar-tab-close")!
      .getBoundingClientRect();
    return {
      inside:
        close.top >= tab.top - 0.5 &&
        close.bottom <= tab.bottom + 0.5 &&
        close.right <= tab.right + 0.5,
      position: getComputedStyle(item.querySelector(".comma-right-sidebar-tab-close")!)
        .position,
    };
  });
  expect(closeGeometry).toEqual({ inside: true, position: "absolute" });

  // Reopening with the keyboard shortcut must stay anchored as well.
  await page.keyboard.press("ControlOrMeta+Alt+KeyB");
  await expect(chatSidebar).toHaveAttribute("data-open", "false");
  await eventually(
    () =>
      page
        .locator(".comma-route-outlet")
        .evaluate((element) => Math.round(element.getBoundingClientRect().width)),
    (value) => expect(value).toBeGreaterThan(1200)
  );
  await watchContentFrame();
  await page.keyboard.press("ControlOrMeta+Alt+KeyB");
  await expect(chatSidebar).toHaveAttribute("data-open", "true");
  expect(await readContentFrame()).toEqual({
    maxScrollLeft: 0,
    outletLefts: [outletLeft],
  });
});

test("dragging the Chat Sidebar squeezes the Home chat, then reflows Tasks and Greet to their floors", async ({
  page,
}) => {
  const linkEnvelope = {
    settings: {
      ...settings,
      sources: [
        {
          ...source,
          appId: "gmail",
          appName: "Gmail",
          connectionId: "local-gmail",
          label: "Gmail",
        },
      ],
    },
    snapshot: {
      cards: [],
      generatedAt: 1,
      generation: 1,
      protocolVersion: 1,
      sourceRevision: 1,
      summary: [
        { kind: "markdown", text: "Good morning.\n\nGmail flagged " },
        {
          kind: "inline-link",
          link: {
            href: "https://mail.google.com/mail/#all/198f2ab4c7d3e011",
            label: "Launch approval",
            sourceId: "local-gmail",
          },
        },
        { kind: "markdown", text: "." },
      ],
      templateCatalogVersion: 1,
      warnings: [],
    },
    state: "fresh",
  };
  const readLayout = () =>
    page.evaluate(() => {
      // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer functions.
      const query = (selector: string) =>
        document.querySelector<HTMLElement>(selector)!;
      const layout = query(".comma-home-layout");
      const columns = getComputedStyle(layout)
        .gridTemplateColumns.split(" ")
        .map((value) => Math.round(Number.parseFloat(value)));
      // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer functions.
      const rail = (element: HTMLElement) => {
        const style = getComputedStyle(element);
        const surface = element.querySelector<HTMLElement>(".comma-home-rail-surface")!;
        return {
          folded: element.dataset.folded,
          // Unfolded rails reflow — the surface is the rail's own width and
          // stays opaque; only a fold fades it out while the track clips it.
          opacity: Math.round(Number(getComputedStyle(surface).opacity) * 100) / 100,
          position: style.position,
          surface: Math.round(surface.getBoundingClientRect().width),
          width: Math.round(element.getBoundingClientRect().width),
        };
      };
      return {
        chat: Math.round(query(".comma-home-chat").getBoundingClientRect().width),
        columns,
        greet: rail(query(".comma-home-greet-rail")),
        home: Math.round(
          query('.comma-chat-route[data-variant="home"]').getBoundingClientRect().width
        ),
        sidebar: Math.round(
          query(".comma-content > .comma-chat-sidebar").getBoundingClientRect().width
        ),
        tasks: rail(query(".comma-home-tasks-rail")),
      };
    });
  // `release: false` keeps the pointer down so the caller can assert the
  // continuous, pointer-tracking state mid-drag; a release keeps whatever
  // width the pointer left — every unfolded width is a legal resting shape.
  const dragHandle = async (
    deltaX: number,
    steps: number,
    { release = true }: { release?: boolean } = {}
  ) => {
    const handle = page.locator(".comma-chat-sidebar-resize-handle");
    const box = (await handle.boundingBox())!;
    const startX = box.x + box.width / 2;
    const y = box.y + 200;
    await page.mouse.move(startX, y);
    await page.mouse.down();
    for (let step = 1; step <= steps; step += 1) {
      await page.mouse.move(startX + (deltaX * step) / steps, y);
    }
    if (release) await page.mouse.up();
  };

  // Content width: 1503 - 8 inset - 75 icon rail = 1420 → with the sidebar
  // at 320 the Home route is 1100 wide (everything fits), at 720 it is 700
  // wide (Tasks folded, Greet reflowed to 259px).
  await page.setViewportSize({ width: 1503, height: 900 });
  await app
    .stub()
    .call("setRecommendations", { name: "fixed", envelope: linkEnvelope });
  await app.open(page);
  await expect(page.getByRole("heading", { name: greetingHeading })).toBeVisible();
  await page
    .locator(".comma-recommendation-inline-source", { hasText: "Launch approval" })
    .click();
  const chatSidebar = page.locator(".comma-content > .comma-chat-sidebar");
  await expect(chatSidebar).toHaveAttribute("data-open", "true");
  await eventually(
    async () => (await readLayout()).sidebar,
    (value) => expect(value).toBe(440)
  );
  // The aside takes its width in one step; its surface, with the resize
  // handle on its edge, then slides in over that edge.
  await eventually(
    () =>
      chatSidebar
        .locator(":scope > .comma-chat-sidebar-surface")
        .evaluate((element) => new DOMMatrix(getComputedStyle(element).transform).m41),
    (value) => expect(value).toBe(0)
  );

  const greetRail = page.getByTestId("home-greet-rail");
  const tasksRail = page.getByTestId("home-tasks-rail");

  // Both rails fit at this viewport with the new 240px content floor.
  await dragHandle(120, 12);
  await expect(tasksRail).toHaveAttribute("data-folded", "false");
  await expect(greetRail).toHaveAttribute("data-folded", "false");
  await eventually(
    async () => (await readLayout()).chat,
    (value) => expect(value).toBeGreaterThanOrEqual(393)
  );

  // Dragging the sidebar farther folds Greeting too, without squeezing chat.
  // With both rails folded at Home's floor, chat also takes the route inset
  // their handles no longer need.
  await dragHandle(-800, 32);
  await expect(greetRail).toHaveAttribute("data-folded", "true");
  await eventually(
    async () => (await readLayout()).chat,
    (value) => expect(value).toBe(425)
  );
  await eventually(
    async () => (await readLayout()).home,
    (value) => expect(value).toBe(425)
  );

  // Reversing restores any rail that fits; there is no partially visible rail.
  await dragHandle(800, 32);
  await expect(greetRail).toHaveAttribute("data-folded", "false");
  await expect(tasksRail).toHaveAttribute("data-folded", "false");
  await eventually(
    async () => (await readLayout()).chat,
    (value) => expect(value).toBeGreaterThanOrEqual(393)
  );
});

test("a source-only routine shows its task, quoted context and source on its card and stages the task from it", async ({
  page,
}) => {
  const envelope = structuredClone(oldMockEnvelope);
  const card = envelope.snapshot.cards[0]!;
  const sourceOnly = structuredClone(card.items[0]!);
  sourceOnly.id = "source-only-task";
  const sourceDetail =
    "Original request: <@U123|Alex> please test <https://example.com/fix|the transport fix>. <https://example.com/spec|Spec> https://example.com/logs <script>not executable</script> <javascript:alert(1)|unsafe>\n• Reconnect\n• Resend\n• Reorder\n• Report\n• Retry";
  const sourceLink = {
    href: "https://comma.slack.com/archives/C123/p123",
    label:
      "Please verify reconnect behavior after the transport change and report whether conversations lose messages.",
    sourceId: source.connectionId,
    previewText: sourceDetail,
    taskPrompt: "Verify reconnect behavior.",
  };
  sourceOnly.action = {
    type: "send_to_comma",
    label: "Use prompt",
    prompt: sourceLink.taskPrompt,
    requiresConfirmation: true,
  };
  sourceOnly.parts = [{ kind: "inline-link", link: sourceLink }];
  const wireEnvelope = {
    ...envelope,
    snapshot: {
      ...envelope.snapshot,
      prompts: {
        s1r1: {
          sourceId: source.connectionId,
          sourceUrl: sourceLink.href,
          objective: "Verify reconnect behavior.",
          context: sourceDetail,
          contextLabel: "Original context (quoted)",
        },
      },
      cards: envelope.snapshot.cards.map((entry, index) =>
        index === 0
          ? {
              ...entry,
              items: [
                ...entry.items,
                {
                  ...sourceOnly,
                  parts: [
                    {
                      kind: "inline-link",
                      link: {
                        href: sourceLink.href,
                        label: sourceLink.label,
                        sourceId: sourceLink.sourceId,
                        promptId: "s1r1",
                      },
                    },
                  ],
                  action: {
                    type: "send_to_comma",
                    label: "Use prompt",
                    requiresConfirmation: true,
                    promptId: "s1r1",
                  },
                },
              ],
            }
          : entry
      ),
    },
  };
  await app
    .stub()
    .call("setRecommendations", { name: "fixed", envelope: wireEnvelope });
  await page.setViewportSize({ width: 1100, height: 900 });
  await app.open(page);
  await page.getByRole("heading", { name: greetingHeading }).click();
  // The row's card shows what its hover card used to: the task its prompt
  // names, the quoted source words, then the source.
  const row = page.locator(".comma-recommendation-text-item", {
    has: page.locator(".comma-recommendation-source-detail"),
  });
  await expect(row).toHaveCount(1);
  await expect(row.locator(".comma-recommendation-inline-link")).toHaveCount(0);
  const objective = row.locator(".comma-recommendation-task-objective");
  await expect(objective).toHaveText("Verify reconnect behavior.");
  const detail = row.locator(".comma-recommendation-source-detail");
  await expect(detail).toBeVisible();
  await expect(row.locator(".comma-recommendation-source-origin")).toHaveText(
    "Old mock card"
  );
  await expect(
    detail.getByRole("link", { name: "@Alex", exact: true })
  ).toHaveAttribute("data-recommendation-href", "https://comma.slack.com/team/U123");
  await expect(
    detail.getByRole("link", { name: "the transport fix", exact: true })
  ).toHaveCount(1);
  await expect(detail.getByRole("link", { name: "Spec", exact: true })).toHaveCount(1);
  await expect(
    detail.getByRole("link", { name: "example.com/logs", exact: true })
  ).toHaveCount(1);
  await expect(detail.getByRole("link", { name: "unsafe", exact: true })).toHaveCount(
    0
  );
  expect(
    await detail.evaluate((node) => {
      const token = document.createElement("span");
      token.style.color = "var(--color-text-tertiary)";
      document.body.append(token);
      const matches = getComputedStyle(node).color === getComputedStyle(token).color;
      token.remove();
      return matches;
    })
  ).toBe(true);
  // Source lines and list items wrap inside the four-line preview.
  await expect(detail.locator(".comma-recommendation-source-line")).toHaveCount(6);
  const clamp = await detail.evaluate((node) => ({
    height: node.clientHeight,
    line: parseFloat(getComputedStyle(node).lineHeight),
    scroll: node.scrollHeight,
  }));
  expect(clamp.height).toBeLessThanOrEqual(clamp.line * 4 + 1);
  expect(clamp.scroll).toBeGreaterThan(clamp.height);
  const contextBox = await detail.boundingBox();
  const promptBox = await objective.boundingBox();
  // The task leads; the quoted context under it is its evidence.
  expect(promptBox!.y).toBeLessThan(contextBox!.y);
  await expect(page.locator(".comma-recommendation-source-detail script")).toHaveCount(
    0
  );
  // The dismiss control shows only while the pointer is over its card.
  const dismiss = row.getByRole("button", { name: "Don’t remind me" });
  await expect(dismiss).toHaveCSS("opacity", "0");
  // Nothing opens on a hover any more: the card already shows it all.
  await row.hover({ position: { x: 8, y: 8 } });
  await testClock().advance(600);
  await expect(page.locator(".comma-hover-card")).toHaveCount(0);
  await expect(dismiss).toHaveCSS("opacity", "1");
  // It sits in the card's top-trailing corner.
  const rowBox = await row.boundingBox();
  const dismissBox = await dismiss.boundingBox();
  expect(rowBox!.x + rowBox!.width - (dismissBox!.x + dismissBox!.width)).toBeLessThan(
    12
  );
  expect(dismissBox!.y - rowBox!.y).toBeLessThan(12);
  // What the app asks the server from here on: no message, Task or conversation is written.
  const requestsBefore = ((await app.stub().call("requests")) as string[]).length;
  const beforeUrl = page.url();
  await row
    .getByRole("button", { name: "Use prompt" })
    .click({ position: { x: 8, y: 8 } });
  // The member asks Comma for help with the task, staged above the prompt as
  // one tile. The quoted context stays on the card.
  const home = page.locator('.comma-chat-route[data-variant="home"]');
  const snippet = home.locator('[data-slot="snippet-attachment"]');
  await expect(snippet).toContainText("Help me verify reconnect behavior.");
  await expect(snippet).not.toContainText(sourceLink.href);
  await expect(home.getByRole("textbox", { name: "AI prompt" })).toHaveText("");
  expect(page.url()).toBe(beforeUrl);
  expect(testPage().popups()).toEqual([]);
  expect(
    ((await app.stub().call("requests")) as string[])
      .slice(requestsBefore)
      .filter((request) =>
        /^POST .*\/(messages|tasks|conversations)(?:\/|$)/.test(request)
      )
  ).toEqual([]);

  // Sending it shows the request as a file card, whose hover holds the source
  // URL, and opens that source item in the browser sidebar.
  const chatSidebar = page.locator(".comma-content > .comma-chat-sidebar");
  await expect(chatSidebar).toHaveAttribute("data-open", "false");
  await home.getByRole("button", { name: "Send" }).click();
  await expect(snippet).toHaveCount(0);
  const sent = home.locator('[data-testid^="chat-attached-text-"]');
  await expect(sent).toContainText("Help me verify reconnect behavior.");
  await expect(chatSidebar).toHaveAttribute("data-open", "true");
  await expect(page.getByRole("tab", { name: /comma\.slack\.com/ })).toBeVisible();
  await sent.hover();
  await expect(page.getByRole("tooltip")).toContainText(sourceLink.href);
});

test("a Routine prompt shown in the text field continues the focused draft", async ({
  page,
}) => {
  const envelope = structuredClone(oldMockEnvelope);
  // A source prompt keeps its URL in its own paragraph.
  const sourcePrompt =
    "Help me review COMMA-143\n\nhttps://linear.app/comma/issue/COMMA-143";
  envelope.snapshot.cards[0]!.items[0]!.action.prompt = sourcePrompt;
  await app.stub().call("setRecommendations", { name: "fixed", envelope: envelope });
  await page.setViewportSize({ width: 1440, height: 900 });
  await app.open(page);
  const composer = page.getByRole("textbox", { name: "AI prompt" });
  // A row stages its prompt above the composer; "Show in text field" writes
  // it into the draft.
  const showInTextField = () =>
    page
      .locator('[data-slot="snippet-attachment"]')
      .getByRole("button", { name: /^Show .* in text field$/ })
      .click();

  await page.getByRole("button", { name: "Review next mock issue" }).click();
  await showInTextField();
  await expect(composer).toHaveText("Review COMMA-NEXT");
  await expect(composer).toBeFocused();

  // A prompt after an earlier draft starts its own paragraph, and typing
  // continues after it.
  const oldRow = page.getByRole("button", { name: "Review old mock issue" });
  await oldRow.click({ position: { x: 8, y: 18 } });
  await showInTextField();
  await expect(composer).toHaveText(`Review COMMA-NEXT\n\n${sourcePrompt}`);
  await expect(composer).toBeFocused();
  await page.keyboard.type(" ok");
  await expect(composer).toHaveText(`Review COMMA-NEXT\n\n${sourcePrompt} ok`);
});

test("a proactive reminder reads as a Comma chat message with its source link", async ({
  page,
}) => {
  const url = reminderUrl;
  await app
    .stub()
    .call("setRecommendations", { name: "fixed", envelope: oldMockEnvelope });
  await app.open(page);
  await expect(
    page.getByText("Want me to draft the reply?", { exact: false })
  ).toBeVisible();
  await expect(
    page.getByRole("link", { name: "Launch approval needed today", exact: true })
  ).toHaveAttribute("href", url);
  await expect(
    page.getByText("Reminder scheduled: Check the rollout checklist", { exact: true })
  ).toBeVisible();
});
