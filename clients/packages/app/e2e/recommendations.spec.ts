import { waitForSettledMotion } from "../../../e2e/helpers/motion";
import { expect, test, type Locator } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeWorkspace, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// The briefing heading is a time-of-day greeting, so specs that only need it as
// a stable anchor must not pin one time of day. `briefing-heading.spec.ts` pins
// the wording against a fixed clock.
const greetingHeading = /^Good (morning|afternoon|evening), /;

const source = {
  appId: "linear",
  appName: "Linear",
  connectionId: "local-linear",
  enabled: true,
  kind: "composio",
  label: "Linear",
};

const customProviderSource = {
  appId: "custom-crm",
  appName: "Custom CRM",
  connectionId: "local-custom-crm",
  enabled: true,
  iconUrl: "https://assets.comma.test/custom-crm.svg",
  kind: "composio",
  label: "Custom CRM",
};

const settings = {
  autoEnableNewSources: true,
  schedule: { enabled: true, hour: 8, minute: 0, timezone: "Asia/Singapore" },
  sourcesCheckedAt: "2026-08-17T00:00:00Z",
  sourceRevision: 1,
  sources: [source],
};

const additionalMockCardTitles = [
  "Team follow-ups",
  "Release checks",
  "Customer signals",
  "Weekly cleanup",
];

const additionalMockCards = additionalMockCardTitles.map((title, index) => ({
  fallbackText: title,
  id: `additional-mock-card-${index + 1}`,
  items: [
    {
      action: {
        label: title,
        prompt: title,
        requiresConfirmation: false,
        type: "open_task_form",
      },
      id: `additional-mock-item-${index + 1}`,
      parts: [{ kind: "markdown", text: title }],
    },
  ],
  sourceIds: [source.connectionId],
  template: "text-list@1",
  title,
}));

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

// Only where the card sits: its box still carries the enter transform while the
// card settles, so width and height are not stable to compare against.
const hoverCardOrigin = async (card: Locator) => {
  const box = await card.boundingBox();
  return { x: box?.x, y: box?.y };
};

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

const oldMockEnvelope = {
  settings,
  snapshot: {
    cards: [
      {
        fallbackText: "Review the old mock issue.",
        id: "old-mock-card",
        items: [
          {
            action: {
              label: "Review old mock issue",
              prompt: "Review COMMA-MOCK",
              requiresConfirmation: false,
              type: "open_task_form",
            },
            id: "old-mock-item",
            parts: [
              {
                kind: "markdown",
                text: "Prevent socket exhaustion recurrence and review ",
              },
              {
                kind: "inline-link",
                link: {
                  href: "https://linear.app/comma/issue/COMMA-143",
                  label: "COMMA-143",
                  sourceId: source.connectionId,
                },
              },
              { kind: "markdown", text: " and " },
              {
                kind: "inline-task",
                task: {
                  conversationId: "cnv_mock_follow_up",
                  label: "COMMA-144",
                },
              },
            ],
          },
        ],
        sourceIds: [source.connectionId],
        template: "text-list@1",
        title: "Old mock card",
      },
      {
        fallbackText: "Review the next mock issue.",
        id: "next-mock-card",
        items: [
          {
            action: {
              label: "Review next mock issue",
              prompt: "Review COMMA-NEXT",
              requiresConfirmation: false,
              type: "open_task_form",
            },
            id: "next-mock-item",
            parts: [{ kind: "markdown", text: "Review the next mock issue" }],
          },
        ],
        sourceIds: [source.connectionId],
        template: "text-list@1",
        title: "Next mock card",
      },
      ...additionalMockCards,
    ],
    generatedAt: 1,
    generation: 1,
    protocolVersion: 1,
    sourceRevision: 1,
    summary: [{ kind: "markdown", text: "Good morning.\n\nOld mock briefing." }],
    templateCatalogVersion: 1,
    warnings: [],
  },
  state: "fresh",
};

test("a rejected real refresh replaces stale mock recommendations with canonical empty state", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  let refreshRejected = false;
  const envelopeWithCustomProviderLogo = {
    ...oldMockEnvelope,
    settings: {
      ...oldMockEnvelope.settings,
      sources: [source, customProviderSource],
    },
    snapshot: {
      ...oldMockEnvelope.snapshot,
      cards: oldMockEnvelope.snapshot.cards.map((card) =>
        card.id === "additional-mock-card-1"
          ? { ...card, sourceIds: [customProviderSource.connectionId] }
          : card
      ),
    },
  };

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "recommendation-mode-switch@comma.local",
      token: "comma_sess_recommendation_mode_switch",
    });

    await page.route(customProviderSource.iconUrl, async (route) => {
      await route.fulfill({
        body: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="#5f6ad3"/></svg>',
        contentType: "image/svg+xml",
        status: 200,
      });
    });

    await page.route(
      `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations**`,
      async (route) => {
        const request = route.request();
        const url = new URL(request.url());

        if (request.method() === "POST" && url.pathname.endsWith("/refresh")) {
          refreshRejected = true;
          await route.fulfill({
            contentType: "application/json",
            json: { error: "no_recommendation_sources" },
            status: 409,
          });
          return;
        }

        if (request.method() === "GET") {
          await route.fulfill({
            contentType: "application/json",
            json: refreshRejected
              ? {
                  settings: { ...settings, sourceRevision: 2, sources: [] },
                  snapshot: null,
                  state: "empty",
                }
              : envelopeWithCustomProviderLogo,
          });
          return;
        }

        await route.continue();
      }
    );

    // Wide enough for the Greet rail to stay inline.
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto("/");
    // react-aria hover interactions (tooltips, hover cards) ignore synthetic
    // hovers until the page has seen a pointer press; press on static copy.
    await page.getByRole("heading", { name: greetingHeading }).click();

    await expect(page.getByRole("heading", { name: greetingHeading })).toBeVisible();
    await expect(page.getByText("Old mock briefing.")).toBeVisible();
    await expect(page.getByRole("heading", { name: "Old mock card" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Next mock card" })).toBeVisible();
    await expect(page.locator(".comma-recommendations-heading")).toHaveCSS(
      "padding-bottom",
      "0px"
    );
    await expect(
      page.locator('article.comma-recommendation-card[data-template="text-list@1"]')
    ).toHaveCount(6);
    const firstCard = page
      .locator('article.comma-recommendation-card[data-template="text-list@1"]')
      .filter({
        has: page.locator("h3").filter({ hasText: "Old mock card" }),
      });
    await expect(firstCard).toHaveCSS("border-radius", "12px");
    await expect(firstCard).toHaveCSS("border-top-style", "solid");
    await expect(firstCard.locator("h3")).toHaveCSS("font-size", "13px");
    await expect(firstCard.locator("h3")).toHaveCSS("line-height", "20px");
    await expect(firstCard.locator(".comma-recommendation-items")).toHaveCSS(
      "row-gap",
      "0px"
    );
    await expect(
      firstCard.locator(
        '.comma-recommendation-card-logo svg[data-provider-logo="linear"]'
      )
    ).toBeVisible();
    const firstItem = firstCard.locator(".comma-recommendation-text-item").first();
    await expect(firstItem).toHaveCSS("border-radius", "8px");
    const hoverIcon = firstItem.locator(".comma-recommendation-row-icon");
    await expect(hoverIcon).toHaveCSS("opacity", "0");
    await firstItem
      .getByRole("button", { name: "Review old mock issue" })
      .hover({ position: { x: 8, y: 18 } });
    await expect(hoverIcon).toHaveCSS("opacity", "1");
    const promptHoverCard = page.getByRole("tooltip");
    await expect(promptHoverCard).toContainText("Review COMMA-MOCK");
    await expect(promptHoverCard).toHaveCSS("padding-top", "6px");
    await expect(promptHoverCard).toHaveCSS("padding-right", "8px");
    await expect(promptHoverCard).toHaveCSS("padding-bottom", "6px");
    await expect(promptHoverCard).toHaveCSS("padding-left", "8px");
    const rowHoverCardOrigin = await hoverCardOrigin(promptHoverCard);

    // Inline chips take their own pointer events back, so the row's full-bleed
    // action button never sees a hover there. A chip with no preview of its own
    // stands in for the row, anchored to the row so the card does not move as
    // the pointer crosses onto it. Each hover starts from rest, or the outgoing
    // card would still be inside its close delay and answer for the new one.
    const liveHoverCard = page.locator(".comma-hover-card:not([data-exiting])");
    const restHover = async () => {
      await page.locator(".comma-home-chat").hover();
      await expect(page.locator(".comma-hover-card")).toHaveCount(0);
    };

    await restHover();
    await firstItem.getByRole("button", { name: "COMMA-144" }).hover();
    await expect(liveHoverCard).toContainText("Review COMMA-MOCK");
    expect(await hoverCardOrigin(liveHoverCard)).toEqual(rowHoverCardOrigin);

    // A chip that does have its own preview still owns its hover.
    await restHover();
    await firstItem.getByRole("button", { name: "COMMA-143" }).hover();
    await expect(liveHoverCard).toContainText(
      "Linear · linear.app/comma/issue/COMMA-143"
    );
    expect(
      await hoverIcon.evaluate((icon) => {
        const reference = document.createElement("span");
        reference.style.color = "var(--color-sidebar-icon-primary)";
        document.body.append(reference);
        const matches =
          getComputedStyle(icon).color === getComputedStyle(reference).color;
        reference.remove();
        return matches;
      })
    ).toBe(true);
    const itemContent = firstItem.locator(".comma-recommendation-text-item-content");
    await expect(itemContent).toHaveCSS("column-gap", "4px");
    await expect(itemContent).toHaveCSS("overflow", "hidden");
    await expect(itemContent).toHaveCSS("white-space", "nowrap");
    const prose = itemContent.locator("p > span").first();
    await expect(prose).toHaveCSS("text-overflow", "ellipsis");
    expect(
      await prose.evaluate(
        (element) =>
          element.scrollWidth > element.clientWidth &&
          element.scrollHeight <= element.clientHeight + 1
      )
    ).toBe(true);
    const inlineLink = itemContent.locator(".comma-recommendation-inline-source");
    // Was min-width: max-content — an unshrinkable chip hard-clipped at the
    // row's overflow edge whenever it alone exceeded the row. Chips now yield
    // after the prose (the shrink-factor gap in styles.css) and truncate
    // through their own label span.
    await expect(inlineLink).toHaveCSS("min-width", "0px");
    const inlineGeometry = await inlineLink.evaluate((element) => {
      const content = element.closest(".comma-recommendation-text-item-content");
      const icon = element.querySelector("svg, img");
      const label = element.querySelector("span");
      const proseElement = content?.querySelector("p > span");
      if (!content || !icon || !label || !proseElement) return null;
      const contentRect = content.getBoundingClientRect();
      const linkRect = element.getBoundingClientRect();
      return {
        contentRight: contentRect.right,
        gapFromProse: linkRect.left - proseElement.getBoundingClientRect().right,
        iconWidth: icon.getBoundingClientRect().width,
        labelWidth: label.getBoundingClientRect().width,
        linkRight: linkRect.right,
        linkWidth: linkRect.width,
      };
    });
    expect(inlineGeometry).not.toBeNull();
    expect(inlineGeometry!.linkRight).toBeLessThanOrEqual(
      inlineGeometry!.contentRight + 1
    );
    expect(inlineGeometry!.linkWidth).toBeGreaterThanOrEqual(
      inlineGeometry!.iconWidth + inlineGeometry!.labelWidth
    );
    expect(inlineGeometry!.gapFromProse).toBeCloseTo(4, 0);
    const inlineTask = itemContent.locator(".comma-recommendation-inline", {
      hasText: "COMMA-144",
    });
    await expect(inlineTask).toHaveCount(1);
    await expect(inlineTask).toHaveCSS("min-width", "0px");
    const inlineTaskBounds = await inlineTask.evaluate((element) => {
      const content = element.closest(".comma-recommendation-text-item-content");
      if (!content) return null;
      const contentRect = content.getBoundingClientRect();
      const inlineRect = element.getBoundingClientRect();
      return {
        contentRight: contentRect.right,
        inlineRight: inlineRect.right,
        inlineWidth: inlineRect.width,
      };
    });
    expect(inlineTaskBounds).not.toBeNull();
    expect(inlineTaskBounds!.inlineWidth).toBeGreaterThan(0);
    expect(inlineTaskBounds!.inlineRight).toBeLessThanOrEqual(
      inlineTaskBounds!.contentRight + 1
    );
    const refreshControl = page.getByRole("button", {
      exact: true,
      name: "Refresh",
    });
    const routinesTrigger = page.getByRole("button", {
      name: "Customize routines",
    });
    const toggleSidebar = page.getByRole("button", { name: "Toggle chat sidebar" });
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
    await page.waitForTimeout(300);
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
    await page.waitForTimeout(550);
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
    await expect(page.locator("html")).not.toHaveAttribute(
      "data-comma-routine-dragging"
    );
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
    const settingsContent = settingsActionItem.locator(
      '[data-slot="menu-item-content"]'
    );
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
    await expect(
      settingsActionItem.locator('[data-slot="menu-item-icon"]')
    ).toHaveCount(0);
    expect(
      await settingsContent.evaluate((element) => {
        const probe = document.createElement("span");
        probe.style.color = "var(--color-text-tertiary)";
        element.append(probe);
        const matches =
          getComputedStyle(probe).color === getComputedStyle(element).color;
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
    const triggerLabelToChevronGap = await firstVisibilityTrigger.evaluate(
      (trigger) => {
        const label = trigger.querySelector('[data-slot="dropdown-row-label"]')!;
        const indicator = trigger.querySelector(
          '[data-slot="dropdown-row-indicator"]'
        )!;
        return (
          indicator.getBoundingClientRect().left - label.getBoundingClientRect().right
        );
      }
    );
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
    expect(Math.abs(selectedLabelBounds.top - triggerLabelBounds.top)).toBeLessThan(
      0.5
    );
    expect(
      Math.abs(selectedLabelBounds.bottom - triggerLabelBounds.bottom)
    ).toBeLessThan(0.5);
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
    expect(
      Math.abs(hiddenVisibilityBounds!.x - initialVisibilityBounds!.x)
    ).toBeLessThan(0.1);
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
      Math.abs(
        selectedHiddenOptionBounds!.height - hiddenTriggerBoundsWhileOpen!.height
      )
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
    await expect(
      page.locator('article.comma-recommendation-card[data-template="text-list@1"] h3')
    ).toHaveText(["Old mock card", "Next mock card", ...additionalMockCardTitles]);

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
    await expect(page.getByRole("heading", { name: bottomRoutineTitle })).toHaveCount(
      0
    );
    await bottomVisibilityTrigger.click();
    await page.getByRole("option", { name: "Show" }).click();
    await expect(page.getByRole("heading", { name: bottomRoutineTitle })).toBeVisible();

    const oldRoutineRow = routinesDialog.getByRole("row", {
      exact: true,
      name: "Old mock card",
    });
    const nextRoutineRow = routinesDialog.getByRole("row", {
      exact: true,
      name: "Next mock card",
    });
    // Keep Greeting above its 681px route floor beside the 75px app rail
    // and 8px window inset, so closing the menu can restore its trigger.
    await page.setViewportSize({ height: 800, width: 780 });
    await expect(page.getByTestId("home-greet-rail")).toHaveAttribute(
      "data-folded",
      "false"
    );
    await expect(routinesDialog).toBeVisible();
    await expect
      .poll(async () => {
        const box = await oldRoutineRow.boundingBox();
        if (!box) return false;
        const center = box.x + box.width / 2;
        return center >= 0 && center <= 780;
      })
      .toBe(true);
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
      DataTransfer.prototype.setDragImage = function setRoutineDragImage(
        element,
        x,
        y
      ) {
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
    await expect(page.locator("html")).not.toHaveAttribute(
      "data-comma-routine-dragging"
    );
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
    await expect
      .poll(() =>
        oldRoutineRow.evaluate((row) => {
          const probe = document.createElement("div");
          probe.style.backgroundColor = "var(--color-bg-popup-secondary)";
          row.append(probe);
          const matches =
            getComputedStyle(probe).backgroundColor ===
            getComputedStyle(row).backgroundColor;
          probe.remove();
          return matches;
        })
      )
      .toBe(true);
    // Elevation rides on the pseudo-element's opacity; the row's own
    // box-shadow channel stays reserved for the instant focus ring, and the
    // row is never scaled (the scroll viewport would clip it).
    await expect
      .poll(() =>
        oldRoutineRow.evaluate((row) => {
          const pseudo = getComputedStyle(row, "::after");
          return {
            boxShadowIsNone: pseudo.boxShadow === "none",
            opacity: pseudo.opacity,
          };
        })
      )
      .toEqual({ boxShadowIsNone: false, opacity: "1" });
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
        row
          .getAnimations()
          .map((animation) => animation.finished.catch(() => undefined))
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
    await expect(page.locator("html")).not.toHaveAttribute(
      "data-comma-routine-dragging"
    );
    await expect(oldRoutineRow).not.toHaveAttribute("data-pointer-dragging");
    await expect(nextRoutineRow).not.toHaveAttribute("data-routine-drag-shift");
    await expect(oldRoutineRow.locator(".comma-routines-card-title")).toHaveCSS(
      "opacity",
      "1"
    );
    await expect(
      page.locator('article.comma-recommendation-card[data-template="text-list@1"] h3')
    ).toHaveText(["Next mock card", "Old mock card", ...additionalMockCardTitles]);
    await expect
      .poll(() =>
        page.evaluate(
          () =>
            (
              window as typeof window & {
                commaRoutineDragRecordingComplete?: boolean;
              }
            ).commaRoutineDragRecordingComplete ?? false
        )
      )
      .toBe(true);
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
    await expect(page.locator("html")).not.toHaveAttribute(
      "data-comma-routine-dragging"
    );
    await expect(oldRoutineRow).not.toHaveAttribute("data-pointer-dragging");
    await expect(nextRoutineRow).not.toHaveAttribute("data-routine-drag-shift");
    await page.waitForTimeout(350);
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
    await page.waitForTimeout(350);
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
    await expect(page.locator("html")).not.toHaveAttribute(
      "data-comma-routine-dragging"
    );
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
    await expect
      .poll(() => constrainedScrollViewport.evaluate((viewport) => viewport.scrollTop))
      .toBeGreaterThan(0);
    await expect(constrainedFirstRow).toHaveAttribute("data-pointer-dragging", "true");
    await page.keyboard.press("Escape");
    await page.mouse.up();
    await expect(routinesDialog).toBeVisible();
    await expect(constrainedFirstRow).not.toHaveAttribute("data-pointer-dragging");
    await page.keyboard.press("Escape");
    await expect(routinesDialog).toBeHidden();
    await refreshControl.click();

    await expect(page.getByText("No routines created yet")).toBeVisible();
    await expect(page.getByRole("heading", { name: "Old mock card" })).toHaveCount(0);

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
  } finally {
    await stub.close();
  }
});

test("styles per-product inline-link chips with brand logos and white tiles", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  const chipSources = [
    ["gmail", "Gmail"],
    ["github", "GitHub"],
    ["googlecalendar", "Google Calendar"],
    ["googledrive", "Google Drive"],
    ["linear", "Linear"],
    ["notion", "Notion"],
    ["slack", "Slack"],
  ].map(([appId, appName]) => ({
    appId,
    appName,
    connectionId: `local-${appId}`,
    enabled: true,
    kind: "composio",
    label: appName,
  }));
  const chipEnvelope = {
    settings: { ...settings, sources: chipSources },
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
        { kind: "markdown", text: ". GitHub needs review on " },
        {
          kind: "inline-link",
          link: {
            href: "https://github.com/AFK-surf/Comma/pull/884",
            label: "#884",
            sourceId: "local-github",
          },
        },
        { kind: "markdown", text: ". Up next " },
        {
          kind: "inline-link",
          link: {
            href: "https://www.google.com/calendar/event?eid=abc123",
            label: "Stand-up",
            sourceId: "local-googlecalendar",
          },
        },
        { kind: "markdown", text: ", then finish " },
        {
          kind: "inline-link",
          link: {
            href: "https://drive.google.com/open?id=1AbC_dEf-9",
            label: "Launch brief",
            sourceId: "local-googledrive",
          },
        },
        { kind: "markdown", text: ". Also " },
        {
          kind: "inline-link",
          link: {
            href: "https://linear.app/comma/issue/COMMA-151",
            label: "COMMA-151",
            sourceId: "local-linear",
          },
        },
        { kind: "markdown", text: ", " },
        {
          kind: "inline-link",
          link: {
            href: "https://www.notion.so/comma/Q3-plan-0123456789abcdef",
            label: "Q3 plan",
            sourceId: "local-notion",
          },
        },
        { kind: "markdown", text: " and " },
        {
          kind: "inline-link",
          link: {
            href: "https://comma.slack.com/archives/C0123/p1787311839000100",
            label: "release thread",
            sourceId: "local-slack",
          },
        },
        { kind: "markdown", text: ". The inbox also holds " },
        {
          kind: "inline-link",
          link: {
            href: "https://mail.google.com/mail/#all/198f2ab4c7d3e012",
            label:
              "[RESOLVED - Error] [P2][STG] A very long alert subject that must truncate instead of widening the briefing column",
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

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "recommendation-chip-styles@comma.local",
      token: "comma_sess_recommendation_chip_styles",
    });

    await page.route(
      `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations**`,
      async (route) => {
        if (route.request().method() === "GET") {
          await route.fulfill({
            contentType: "application/json",
            json: chipEnvelope,
          });
          return;
        }
        await route.continue();
      }
    );

    // Wide enough for the Greet rail to stay inline.
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto("/");
    // react-aria hover interactions (tooltips, hover cards) ignore synthetic
    // hovers until the page has seen a pointer press; press on static copy.
    await page.getByRole("heading", { name: greetingHeading }).click();
    await expect(page.getByRole("heading", { name: greetingHeading })).toBeVisible();

    const summary = page.locator(".comma-recommendations-summary");
    const gmailChip = summary.locator(".comma-recommendation-inline-source", {
      hasText: "Launch approval",
    });
    await expect(gmailChip.locator('svg[data-provider-logo="gmail"]')).toBeVisible();
    // The briefing chip is set in the paragraph's own type, not a ramp of its
    // own, so the label matches the 13px prose around it. Only the box comes
    // down off the prose's 20px line, so that the chips on consecutive lines of
    // a wrapped paragraph keep a gutter instead of meeting edge to edge.
    await expect(gmailChip).toHaveCSS("font-size", "13px");
    await expect(gmailChip).toHaveCSS("line-height", "18px");
    await expect(gmailChip).toHaveCSS("padding-left", "2px");

    const githubLogo = summary.locator('svg[data-provider-logo="github"]');
    await expect(githubLogo).toBeVisible();
    // The mark is the same 16px in the briefing as in a card row; the chip's
    // box is sized to keep a pixel clear of it rather than the other way round.
    await expect(githubLogo).toHaveCSS("width", "16px");
    await expect(githubLogo).toHaveCSS("background-color", "rgb(255, 255, 255)");
    await expect(githubLogo).toHaveCSS("border-radius", "4px");
    // Half-xxs inset: a 14px glyph on the 16px white tile.
    await expect(githubLogo).toHaveCSS("padding-top", "1px");

    const calendarLogo = summary.locator('svg[data-provider-logo="google-calendar"]');
    await expect(calendarLogo).toBeVisible();
    await expect(calendarLogo).toHaveCSS("background-color", "rgb(255, 255, 255)");
    await expect(calendarLogo).toHaveCSS("border-radius", "2px");

    const driveLogo = summary.locator('svg[data-provider-logo="google-drive"]');
    await expect(driveLogo).toBeVisible();
    await expect(driveLogo).toHaveCSS("background-color", "rgb(255, 255, 255)");
    await expect(driveLogo).toHaveCSS("border-radius", "2px");
    await expect(driveLogo).toHaveCSS("padding-left", "2px");

    // Linear, Notion and Slack marks get the same white tile as GitHub.
    for (const provider of ["linear", "notion", "slack"]) {
      const tiledLogo = summary.locator(`svg[data-provider-logo="${provider}"]`);
      await expect(tiledLogo).toBeVisible();
      await expect(tiledLogo).toHaveCSS("width", "16px");
      await expect(tiledLogo).toHaveCSS("background-color", "rgb(255, 255, 255)");
      await expect(tiledLogo).toHaveCSS("border-radius", "4px");
      await expect(tiledLogo).toHaveCSS("padding-top", "1px");
    }

    // A label longer than the rail column truncates inside the chip instead of
    // widening the line past the summary paragraph.
    const longChip = summary.locator(".comma-recommendation-inline-source", {
      hasText: "must truncate instead",
    });
    await expect(longChip).toBeVisible();
    const widths = await longChip.evaluate((chip) => {
      const span = chip.querySelector("span");
      const paragraph = chip.closest("p");
      if (!span || !paragraph) throw new Error("missing chip span or paragraph");
      return {
        chip: chip.getBoundingClientRect().width,
        paragraph: paragraph.getBoundingClientRect().width,
        spanClient: span.clientWidth,
        spanScroll: span.scrollWidth,
      };
    });
    expect(widths.chip).toBeLessThanOrEqual(widths.paragraph + 0.5);
    expect(widths.spanScroll).toBeGreaterThan(widths.spanClient);
  } finally {
    await stub.close();
  }
});

for (const [lastError, failureCopy] of [
  ["renderer_declined", "Nothing new in your apps to brief today."],
  [
    "member_identity_required",
    "Reconnect your apps in Plugins to verify your personal account.",
  ],
] as const) {
  test(`a failed generation names ${lastError} and Refresh generates at once`, async ({
    page,
  }) => {
    const stub = await startChatSmokeStub();
    let recommendationReads = 0;
    let refreshRequested = false;
    let releaseRefresh: (() => void) | undefined;
    const refreshReleased = new Promise<void>((resolve) => {
      releaseRefresh = resolve;
    });
    // The problem toast closes after five seconds, so the failed read waits
    // until the test watches for it.
    let releaseFailure: (() => void) | undefined;
    const failureReleased = new Promise<void>((resolve) => {
      releaseFailure = resolve;
    });

    try {
      await installBrowserTestSession(page, {
        apiBaseUrl: stub.baseUrl,
        email: "recommendation-failure-class@comma.local",
        token: "comma_sess_recommendation_failure_class",
      });

      await page.route(
        `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations**`,
        async (route) => {
          const request = route.request();
          const url = new URL(request.url());

          if (request.method() === "POST" && url.pathname.endsWith("/refresh")) {
            // The refresh request collects the sources before the server
            // reports the run; hold it until the test has looked at the rail.
            refreshRequested = true;
            await refreshReleased;
            await route.fulfill({
              contentType: "application/json",
              json: {
                envelope: { settings, snapshot: null, state: "refreshing" },
                run: {
                  generation: 2,
                  id: "rrn_failure_class",
                  sourceRevision: settings.sourceRevision,
                  status: "pending",
                  trigger: "manual",
                },
              },
            });
            return;
          }

          if (request.method() === "GET") {
            recommendationReads += 1;

            if (!refreshRequested) {
              await failureReleased;
              // The server reports a bounded, actionable failure rather than
              // displaying unrelated or identity-invalid recommendations.
              await route.fulfill({
                contentType: "application/json",
                json: {
                  lastError,
                  settings,
                  snapshot: null,
                  state: "error",
                },
              });
              return;
            }

            await route.fulfill({
              contentType: "application/json",
              json: {
                ...oldMockEnvelope,
                snapshot: {
                  ...oldMockEnvelope.snapshot,
                  generatedAt: 2,
                  generation: 2,
                  summary: [
                    {
                      kind: "markdown",
                      text: "Good afternoon.\n\nFresh briefing after the retry.",
                    },
                  ],
                },
              },
            });
            return;
          }

          await route.continue();
        }
      );

      // Wide enough for the Greet rail to stay inline.
      await page.setViewportSize({ width: 1440, height: 900 });
      await page.goto("/");

      const rail = page.locator(".comma-recommendations");
      // Routine problems are toasts; the rail keeps only its own content.
      const problem = page.getByTestId("routine-problem-toast");
      releaseFailure?.();
      await expect(problem).toBeVisible();
      await expect(problem).toContainText(failureCopy);
      await expect(rail.getByText(failureCopy)).toHaveCount(0);
      await expect(page.getByText("Routines are unavailable")).toHaveCount(0);
      await expect(rail).toHaveAttribute("data-state", "error");
      // A terminal generation error ends the discovery checks, which would
      // otherwise re-read every 1.5 seconds.
      const readsAtError = recommendationReads;
      await page.waitForTimeout(3_500);
      expect(recommendationReads).toBe(readsAtError);
      // The toast stack covers the composer's Send button, so a Routine
      // problem closes on its own; the rail header's refresh tries again.
      await expect(problem).toBeHidden({ timeout: 10_000 });

      await page.getByRole("button", { name: "Refresh", exact: true }).click();

      // Generating from the press, while the refresh request is still open.
      await expect(page.getByTestId("recommendations-generating")).toBeVisible();
      await expect(page.getByText("Generating your briefing…")).toBeVisible();
      await expect(rail).toHaveAttribute("data-state", "refreshing");
      await expect(page.getByText(failureCopy)).toHaveCount(0);
      expect(refreshRequested).toBe(true);

      releaseRefresh?.();

      await expect(page.getByText("Fresh briefing after the retry.")).toBeVisible({
        timeout: 8_000,
      });
      await expect(rail).toHaveAttribute("data-state", "fresh");
    } finally {
      releaseFailure?.();
      releaseRefresh?.();
      await stub.close();
    }
  });
}

test("failed generation and unreadable refresh retain the briefing until an authoritative read revokes it", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  let refreshes = 0;
  let readFailures = 0;
  const stale = { ...oldMockEnvelope, state: "stale", lastError: "failed" };

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "routine-fallback@comma.local",
      token: "comma_sess_routine_fallback",
    });
    await page.route(
      `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations**`,
      async (route) => {
        const request = route.request();
        if (
          request.method() === "POST" &&
          new URL(request.url()).pathname.endsWith("/refresh")
        ) {
          refreshes += 1;
          if (refreshes === 1) {
            await route.fulfill({
              json: {
                envelope: stale,
                run: {
                  id: "rrn_failed",
                  generation: 2,
                  sourceRevision: 1,
                  status: "failed",
                  trigger: "manual",
                },
              },
            });
          } else if (refreshes === 2) {
            await route.fulfill({
              status: 503,
              json: { error: "temporarily_unavailable" },
            });
          } else {
            await route.fulfill({
              status: 409,
              json: { error: "member_identity_required" },
            });
          }
        } else if (request.method() === "GET") {
          if (refreshes === 2) {
            readFailures += 1;
            await route.fulfill({
              status: 503,
              json: { error: "temporarily_unavailable" },
            });
          } else {
            await route.fulfill({
              json:
                refreshes >= 3
                  ? {
                      settings,
                      state: "error",
                      snapshot: null,
                      lastError: "member_identity_required",
                    }
                  : oldMockEnvelope,
            });
          }
        } else {
          await route.continue();
        }
      }
    );
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto("/");
    await expect(page.getByText("Old mock briefing.")).toBeVisible();
    await expect(page.getByText("Old mock card", { exact: true })).toBeVisible();
    await page.getByRole("button", { name: "Refresh", exact: true }).click();
    await expect(page.getByTestId("routine-problem-toast")).toContainText(
      "Couldn’t update routines. Showing the previous briefing."
    );
    await expect(
      page
        .locator(".comma-recommendations")
        .getByText("Couldn’t update routines. Showing the previous briefing.")
    ).toHaveCount(0);
    await expect(page.getByText("Old mock card", { exact: true })).toBeVisible();
    await page.getByRole("button", { name: "Refresh", exact: true }).click();
    await expect.poll(() => readFailures).toBeGreaterThan(0);
    await expect(page.getByText("Old mock briefing.")).toBeVisible();
    await expect(page.getByText("Old mock card", { exact: true })).toBeVisible();
    await expect(page.getByText("Routines are unavailable")).toHaveCount(0);
    await page.getByRole("button", { name: "Refresh", exact: true }).click();
    await expect(page.getByText("Old mock briefing.")).toHaveCount(0);
    await expect(page.getByText("Old mock card", { exact: true })).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("a manual refresh keeps polling after its first status read returns 5xx", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  let recommendationReads = 0;
  let refreshRequested = false;

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "recommendation-refresh-retry@comma.local",
      token: "comma_sess_recommendation_refresh_retry",
    });

    await page.route(
      `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations**`,
      async (route) => {
        const request = route.request();
        const url = new URL(request.url());

        if (request.method() === "POST" && url.pathname.endsWith("/refresh")) {
          refreshRequested = true;
          await route.fulfill({
            contentType: "application/json",
            json: {
              envelope: {
                settings,
                snapshot: null,
                state: "refreshing",
              },
              run: {
                generation: 2,
                id: "rrn_refresh_retry",
                sourceRevision: settings.sourceRevision,
                status: "running",
                trigger: "manual",
              },
            },
          });
          return;
        }

        if (request.method() === "GET") {
          if (!refreshRequested) {
            await route.fulfill({
              contentType: "application/json",
              json: oldMockEnvelope,
            });
            return;
          }

          recommendationReads += 1;
          if (recommendationReads === 1) {
            await route.fulfill({
              contentType: "application/json",
              json: { error: "temporary_recommendation_read_failure" },
              status: 503,
            });
            return;
          }

          await route.fulfill({
            contentType: "application/json",
            json: {
              ...oldMockEnvelope,
              snapshot: {
                ...oldMockEnvelope.snapshot,
                generatedAt: 2,
                generation: 2,
                summary: [
                  {
                    kind: "markdown",
                    text: "Good afternoon.\n\nFresh briefing after retry.",
                  },
                ],
              },
            },
          });
          return;
        }

        await route.continue();
      }
    );

    // Wide enough for the Greet rail to stay inline.
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto("/");
    // react-aria hover interactions (tooltips, hover cards) ignore synthetic
    // hovers until the page has seen a pointer press; press on static copy.
    await page.getByRole("heading", { name: greetingHeading }).click();
    await expect(page.getByText("Old mock briefing.")).toBeVisible();

    await page.getByRole("button", { exact: true, name: "Refresh" }).click();

    const rail = page.locator(".comma-recommendations");
    await expect(rail).toHaveAttribute("data-state", "refreshing");
    await expect(page.getByText("Generating your briefing…")).toBeVisible();
    await expect(page.getByText("Fresh briefing after retry.")).toBeVisible({
      timeout: 8_000,
    });
    await expect(rail).toHaveAttribute("data-state", "fresh");
    expect(recommendationReads).toBe(2);
  } finally {
    await stub.close();
  }
});

for (const scenario of [
  {
    name: "fall-back",
    initial: "2026-11-01T04:30:00Z",
    hour: 8,
    before: "2026-11-01T12:03:00Z",
    after: "2026-11-01T13:02:00Z",
  },
  {
    name: "day before spring-forward",
    initial: "2026-03-07T08:00:00Z",
    hour: 2,
    before: "2026-03-09T06:01:00Z",
    after: "2026-03-09T06:02:00Z",
  },
]) {
  test(`daily briefing reload follows the delivery timezone through DST: ${scenario.name}`, async ({
    page,
  }) => {
    const stub = await startChatSmokeStub();
    let reads = 0;
    const initial = Date.parse(scenario.initial);
    try {
      await page.clock.install({ time: initial });
      await installBrowserTestSession(page, {
        apiBaseUrl: stub.baseUrl,
        email: "recommendation-dst@comma.local",
        token: "comma_sess_recommendation_dst",
      });
      await page.route(
        `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations**`,
        async (route) => {
          if (route.request().method() !== "GET") return route.continue();
          // The app also loads settings without query parameters. Count only
          // the rail's locale-bearing projection reads.
          if (new URL(route.request().url()).searchParams.has("locale")) reads += 1;
          await route.fulfill({
            json: {
              ...oldMockEnvelope,
              settings: {
                ...settings,
                schedule: {
                  ...settings.schedule,
                  hour: scenario.hour,
                  timezone: "America/New_York",
                },
              },
              snapshot: {
                ...oldMockEnvelope.snapshot,
                generation: Math.max(1, reads),
                summary: [
                  {
                    kind: "markdown",
                    text:
                      reads <= 1 ? "Old mock briefing." : "Fresh briefing after DST.",
                  },
                ],
              },
            },
          });
        }
      );
      await page.setViewportSize({ width: 1440, height: 900 });
      await page.goto("/");
      await expect(page.getByText("Old mock briefing.")).toBeVisible();
      // Let startup timers run before pausing the browser clock.
      await page.clock.pauseAt(initial + 60_000);

      // No projection reload before the next actual delivery plus grace.
      await page.clock.fastForward(Date.parse(scenario.before) - initial - 60_000);
      await expect(page.getByText("Old mock briefing.")).toBeVisible();
      expect(reads).toBe(1);

      // The next real target still reloads after a missing calendar time.
      await page.clock.fastForward(
        Date.parse(scenario.after) - Date.parse(scenario.before)
      );
      await expect(page.getByText("Fresh briefing after DST.")).toBeVisible();
      expect(reads).toBe(2);
    } finally {
      await stub.close();
    }
  });
}

test("recommendation settings reports the resolved locale after a language change", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  const recommendationLocales: Array<string | null> = [];

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "recommendation-settings-locale@comma.local",
      token: "comma_sess_recommendation_settings_locale",
    });
    await page.addInitScript(() => {
      localStorage.setItem("comma.locale", "en");
    });

    await page.route("**/v1/comma/workspaces", async (route) => {
      if (route.request().method() !== "GET") {
        await route.continue();
        return;
      }

      await route.fulfill({
        contentType: "application/json",
        json: {
          data: [
            {
              group_id: chatSmokeWorkspace.group_id,
              id: chatSmokeWorkspace.id,
              name: chatSmokeWorkspace.name,
            },
          ],
        },
      });
    });

    await page.route("**/v1/comma/workspaces/*/recommendations**", async (route) => {
      const request = route.request();
      if (request.method() !== "GET") {
        await route.continue();
        return;
      }

      recommendationLocales.push(new URL(request.url()).searchParams.get("locale"));
      await route.fulfill({
        contentType: "application/json",
        json: { settings, snapshot: null, state: "empty" },
      });
    });

    await page.goto("/#/settings?category=recommendations");
    await expect.poll(() => recommendationLocales).toEqual(["en"]);

    await page.getByRole("button", { name: "General" }).click();
    const languageControl = page.locator(
      '[data-setting-id="app.language"] [data-slot="settings-control"] button'
    );
    await languageControl.click();
    await page.getByRole("option", { name: "Simplified Chinese" }).click();
    await expect(page.locator("html")).toHaveAttribute("lang", "zh-CN");

    await page.getByRole("button", { name: "例程" }).click();
    await expect.poll(() => recommendationLocales).toEqual(["en", "zh-CN"]);
  } finally {
    await stub.close();
  }
});

test("recommendation settings reads and writes the persisted active workspace", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  const activeWorkspaceId = "ws-active";
  const recommendationRequests: Array<{ method: string; path: string }> = [];
  const hiddenHomeRequests: string[] = [];
  let savedSettings: unknown;

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "recommendation-active-workspace@comma.local",
      token: "comma_sess_recommendation_active_workspace",
    });
    await page.addInitScript((workspaceId) => {
      localStorage.setItem("comma.activeWorkspaceId", workspaceId);
    }, activeWorkspaceId);

    await page.route("**/v1/comma/workspaces", async (route) => {
      if (route.request().method() !== "GET") {
        await route.continue();
        return;
      }

      await route.fulfill({
        contentType: "application/json",
        json: {
          data: [
            { group_id: "grp-first", id: "ws-first", name: "First workspace" },
            {
              group_id: "grp-active",
              id: activeWorkspaceId,
              name: "Active workspace",
            },
          ],
        },
      });
    });

    page.on("request", (request) => {
      const path = new URL(request.url()).pathname;
      if (
        request.method() === "POST" &&
        (path === "/v1/comma/me/bootstrap" || path.endsWith("/assistant-chat"))
      ) {
        hiddenHomeRequests.push(path);
      }
    });

    await page.route("**/v1/comma/workspaces/*/recommendations**", async (route) => {
      const request = route.request();
      const url = new URL(request.url());
      if (request.method() !== "GET" && request.method() !== "PATCH") {
        await route.continue();
        return;
      }

      recommendationRequests.push({ method: request.method(), path: url.pathname });
      if (request.method() === "PATCH") {
        savedSettings = request.postDataJSON();
      }

      await route.fulfill({
        contentType: "application/json",
        json: {
          settings: {
            ...settings,
            sources: [
              {
                ...source,
                enabled: request.method() === "GET",
              },
            ],
          },
          snapshot: null,
          state: "empty",
        },
      });
    });

    await page.goto("/#/settings");
    await expect(page.getByTestId("home-responsive-layout")).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Debug" })).toBeVisible();
    expect(hiddenHomeRequests).toEqual([]);
    await page.getByRole("button", { name: "Routines" }).click();
    const sourceSwitch = page.getByRole("switch", { name: "Linear" });
    await expect(sourceSwitch).toBeEnabled();
    await sourceSwitch
      .locator("xpath=ancestor::label")
      .locator(".comma-toggle")
      .click();

    await expect
      .poll(() => recommendationRequests)
      .toEqual([
        {
          method: "GET",
          path: `/v1/comma/workspaces/${activeWorkspaceId}/recommendations`,
        },
        {
          method: "PATCH",
          path: `/v1/comma/workspaces/${activeWorkspaceId}/recommendations/settings`,
        },
      ]);
    expect(hiddenHomeRequests).toEqual([]);
    expect(savedSettings).toMatchObject({
      sources: [{ connectionId: source.connectionId, enabled: false }],
    });
  } finally {
    await stub.close();
  }
});

test("Routines settings turn the owner's proactive messages off for the active workspace", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  const proactiveWrites: Array<{ path: string; body: unknown }> = [];
  let relevanceMode = "member";
  let proactiveEnabled = true;

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "recommendation-proactive@comma.local",
      token: "comma_sess_recommendation_proactive",
    });
    await page.addInitScript(() => {
      localStorage.setItem("comma.activeWorkspaceId", "ws-active");
    });

    await page.route("**/v1/comma/workspaces", async (route) => {
      if (route.request().method() !== "GET") {
        await route.continue();
        return;
      }

      await route.fulfill({
        contentType: "application/json",
        json: {
          data: [
            { group_id: "grp-first", id: "ws-first", name: "First workspace" },
            { group_id: "grp-active", id: "ws-active", name: "Active workspace" },
          ],
        },
      });
    });

    await page.route("**/v1/comma/workspaces/*/recommendations**", async (route) => {
      const request = route.request();
      if (request.method() === "PATCH")
        relevanceMode = request.postDataJSON().relevanceMode;
      await route.fulfill({
        contentType: "application/json",
        json: {
          settings: { ...settings, relevanceMode },
          snapshot: null,
          state: "empty",
        },
      });
    });

    await page.route("**/v1/comma/groups/*/proactive", async (route) => {
      const request = route.request();
      if (request.method() === "PUT") {
        const body = request.postDataJSON();
        proactiveWrites.push({ path: new URL(request.url()).pathname, body });
        proactiveEnabled = body.enabled;
      }

      await route.fulfill({
        contentType: "application/json",
        json: { enabled: proactiveEnabled },
      });
    });

    await page.goto("/#/settings?category=recommendations");
    const proactiveSwitch = page.getByRole("switch", { name: "Proactive messages" });
    await expect(proactiveSwitch).toBeChecked();
    await expect(proactiveSwitch).toBeEnabled();

    await proactiveSwitch
      .locator("xpath=ancestor::label")
      .locator(".comma-toggle")
      .click();
    await expect(proactiveSwitch).not.toBeChecked();
    expect(proactiveWrites).toEqual([
      {
        path: "/v1/comma/groups/grp-active/proactive",
        body: { enabled: false, request_id: expect.any(String) },
      },
    ]);

    // Proactive messages judge the member's own items.
    const memberSwitch = page.getByRole("switch", { name: "Only my work" });
    await memberSwitch
      .locator("xpath=ancestor::label")
      .locator(".comma-toggle")
      .click();
    await expect(proactiveSwitch).toBeDisabled();
    await expect(
      page.getByText("Turn on Only my work to use proactive messages.")
    ).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("opening the Chat Sidebar from an inline link keeps the content frame anchored", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
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

  try {
    await page.setViewportSize({ width: 1600, height: 900 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "recommendation-link-sidebar@comma.local",
      token: "comma_sess_recommendation_link_sidebar",
    });
    await page.route(
      `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations**`,
      async (route) => {
        if (route.request().method() === "GET") {
          await route.fulfill({ contentType: "application/json", json: linkEnvelope });
          return;
        }
        await route.continue();
      }
    );

    await page.goto("/");
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
      const tab = item
        .querySelector(".comma-right-sidebar-tab")!
        .getBoundingClientRect();
      const close = item
        .querySelector(".comma-right-sidebar-tab-close")!
        .getBoundingClientRect();
      return {
        inside:
          close.top >= tab.top - 0.5 &&
          close.bottom <= tab.bottom + 0.5 &&
          close.right <= tab.right + 0.5,
        position: getComputedStyle(
          item.querySelector(".comma-right-sidebar-tab-close")!
        ).position,
      };
    });
    expect(closeGeometry).toEqual({ inside: true, position: "absolute" });

    // Reopening with the keyboard shortcut must stay anchored as well.
    await page.keyboard.press("ControlOrMeta+Alt+KeyB");
    await expect(chatSidebar).toHaveAttribute("data-open", "false");
    await expect
      .poll(() =>
        page
          .locator(".comma-route-outlet")
          .evaluate((element) => Math.round(element.getBoundingClientRect().width))
      )
      .toBeGreaterThan(1200);
    await watchContentFrame();
    await page.keyboard.press("ControlOrMeta+Alt+KeyB");
    await expect(chatSidebar).toHaveAttribute("data-open", "true");
    expect(await readContentFrame()).toEqual({
      maxScrollLeft: 0,
      outletLefts: [outletLeft],
    });
  } finally {
    await stub.close();
  }
});

test("a briefing link answers a right-click with the same menu chat gives its links", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  const linkEnvelope = {
    settings,
    snapshot: {
      cards: [],
      generatedAt: 1,
      generation: 1,
      protocolVersion: 1,
      sourceRevision: 1,
      summary: [
        { kind: "markdown", text: "Good morning.\n\nA review is waiting on " },
        {
          kind: "inline-link",
          link: {
            href: "https://linear.app/comma/issue/COMMA-151",
            label: "COMMA-151",
            sourceId: source.connectionId,
          },
        },
        { kind: "markdown", text: "." },
      ],
      templateCatalogVersion: 1,
      warnings: [],
    },
    state: "fresh",
  };

  try {
    await page.setViewportSize({ width: 1440, height: 900 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "recommendation-link-menu@comma.local",
      token: "comma_sess_recommendation_link_menu",
    });
    await page.route(
      `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations**`,
      async (route) => {
        if (route.request().method() === "GET") {
          await route.fulfill({ contentType: "application/json", json: linkEnvelope });
          return;
        }
        await route.continue();
      }
    );

    await page.goto("/");
    await expect(page.getByRole("heading", { name: greetingHeading })).toBeVisible();

    const inlineLink = page
      .locator(".comma-recommendations-summary .comma-recommendation-inline-source")
      .filter({ hasText: "COMMA-151" });
    await expect(inlineLink).toBeVisible();

    // react-aria hover interactions ignore synthetic hovers until the page has
    // seen a pointer press; press on static copy first.
    await page.getByRole("heading", { name: /^Good/ }).click();
    await inlineLink.hover();
    const hoverCard = page.getByRole("tooltip");
    await expect(hoverCard).toBeVisible();

    // The gesture that matters is a right-click on a chip the reader is
    // already hovering: the preview must give way to the menu.
    await inlineLink.click({ button: "right" });
    const linkMenu = page.getByRole("menu", { name: "Link menu" });
    await expect(linkMenu).toBeVisible();
    await expect(hoverCard).toBeHidden();
    // Chat's items, minus the one with no meaning in a briefing: the link sits
    // in prose, not in a message.
    await expect(linkMenu.getByRole("menuitem")).toHaveText([
      "Open in External Browser",
      "Open in Comma",
      "Copy Link",
    ]);
    await expect(linkMenu.getByRole("menuitem", { name: "Copy message" })).toHaveCount(
      0
    );

    // The menu opens at the pointer rather than at the rail's corner.
    const menuBox = await linkMenu.boundingBox();
    const linkBox = await inlineLink.boundingBox();
    expect(menuBox).not.toBeNull();
    expect(linkBox).not.toBeNull();
    expect(menuBox!.x).toBeGreaterThan(linkBox!.x - 8);

    await page.context().grantPermissions(["clipboard-read", "clipboard-write"], {
      origin: new URL(page.url()).origin,
    });
    await linkMenu.getByRole("menuitem", { name: "Copy Link" }).click();
    await expect(linkMenu).toBeHidden();
    await expect
      .poll(() => page.evaluate(() => navigator.clipboard.readText()))
      .toBe("https://linear.app/comma/issue/COMMA-151");

    // "Open in Comma" is the same destination a left-click takes, so the two
    // gestures cannot disagree about where the link goes.
    const chatSidebar = page.locator(".comma-content > .comma-chat-sidebar");
    await expect(chatSidebar).toHaveAttribute("data-open", "false");
    await inlineLink.click({ button: "right" });
    await expect(linkMenu).toBeVisible();
    await linkMenu.getByRole("menuitem", { name: "Open in Comma" }).click();
    await expect(chatSidebar).toHaveAttribute("data-open", "true");
    await expect(page.getByRole("tab", { name: /linear\.app/ })).toBeVisible();

    // Prose that is not a link keeps the platform's own menu.
    await page
      .getByRole("heading", { name: greetingHeading })
      .click({ button: "right" });
    await expect(linkMenu).toBeHidden();
  } finally {
    await stub.close();
  }
});

test("dragging the Chat Sidebar squeezes the Home chat, then reflows Tasks and Greet to their floors", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
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

  try {
    // Content width: 1503 - 8 inset - 75 icon rail = 1420 → with the sidebar
    // at 320 the Home route is 1100 wide (everything fits), at 720 it is 700
    // wide (Tasks folded, Greet reflowed to 259px).
    await page.setViewportSize({ width: 1503, height: 900 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "recommendation-home-fold@comma.local",
      token: "comma_sess_recommendation_home_fold",
    });
    await page.route(
      `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations**`,
      async (route) => {
        if (route.request().method() === "GET") {
          await route.fulfill({ contentType: "application/json", json: linkEnvelope });
          return;
        }
        await route.continue();
      }
    );
    await page.goto("/");
    await expect(page.getByRole("heading", { name: greetingHeading })).toBeVisible();
    await page
      .locator(".comma-recommendation-inline-source", { hasText: "Launch approval" })
      .click();
    const chatSidebar = page.locator(".comma-content > .comma-chat-sidebar");
    await expect(chatSidebar).toHaveAttribute("data-open", "true");
    await expect.poll(async () => (await readLayout()).sidebar).toBe(440);

    const greetRail = page.getByTestId("home-greet-rail");
    const tasksRail = page.getByTestId("home-tasks-rail");

    // Both rails fit at this viewport with the new 240px content floor.
    await dragHandle(120, 12);
    await expect(tasksRail).toHaveAttribute("data-folded", "false");
    await expect(greetRail).toHaveAttribute("data-folded", "false");
    await expect
      .poll(async () => (await readLayout()).chat)
      .toBeGreaterThanOrEqual(393);

    // Dragging the sidebar farther folds Greeting too, without squeezing chat.
    // With both rails folded at Home's floor, chat also takes the route inset
    // their handles no longer need.
    await dragHandle(-800, 32);
    await expect(greetRail).toHaveAttribute("data-folded", "true");
    await expect.poll(async () => (await readLayout()).chat).toBe(425);
    await expect.poll(async () => (await readLayout()).home).toBe(425);

    // Reversing restores any rail that fits; there is no partially visible rail.
    await dragHandle(800, 32);
    await expect(greetRail).toHaveAttribute("data-folded", "false");
    await expect(tasksRail).toHaveAttribute("data-folded", "false");
    await expect
      .poll(async () => (await readLayout()).chat)
      .toBeGreaterThanOrEqual(393);
  } finally {
    await stub.close();
  }
});

test("source-only task labels scroll on hover and focus without changing mixed prose rows", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "routine@example.com",
      token: "comma_sess_routine_test",
    });
    const envelope = structuredClone(oldMockEnvelope);
    const card = envelope.snapshot.cards[0]!;
    const sourceOnly = structuredClone(card.items[0]!);
    sourceOnly.id = "source-only-task";
    const sourceDetail =
      "Original request: <@U123|Alex> please test <https://example.com/fix|the transport fix>. [Spec](https://example.com/spec) https://example.com/logs <script>not executable</script> <javascript:alert(1)|unsafe>";
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
    await page.route(
      `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations**`,
      (route) => route.fulfill({ json: wireEnvelope })
    );
    await page.setViewportSize({ width: 1100, height: 900 });
    await page.goto("/");
    await page.getByRole("heading", { name: greetingHeading }).click();
    const row = page.locator('[data-source-only="true"]');
    await expect(row).toHaveCount(1);
    await expect(row.locator("[data-provider-logo]")).toHaveCount(0);
    const label = row.locator(".comma-recommendation-inline-source > span");
    await expect(label).toBeVisible();
    const detail = page.locator(".comma-recommendation-source-detail");
    await expect(detail).toBeHidden();
    await expect(row.locator(".comma-recommendation-inline-source")).toHaveAttribute(
      "data-source-detail",
      "true"
    );
    await waitForSettledMotion(row);
    await row.locator(".comma-recommendation-inline-source").hover();
    await expect(detail).toBeVisible();
    await expect(page.locator(".comma-recommendation-task-objective")).toHaveText(
      "Verify reconnect behavior."
    );
    await expect(
      detail.getByRole("button", { name: "@Alex", exact: true })
    ).toHaveAttribute("data-recommendation-href", "https://comma.slack.com/team/U123");
    await expect(
      detail.getByRole("button", { name: "the transport fix", exact: true })
    ).toHaveCount(1);
    await expect(detail.getByRole("button", { name: "Spec", exact: true })).toHaveCount(
      1
    );
    await expect(
      detail.getByRole("button", { name: "https://example.com/logs", exact: true })
    ).toHaveCount(1);
    await expect(
      detail.getByRole("button", { name: "unsafe", exact: true })
    ).toHaveCount(0);
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
    const contextBox = await detail.boundingBox();
    const promptBox = await page
      .locator(".comma-recommendation-task-objective")
      .boundingBox();
    expect(contextBox!.y).toBeLessThan(promptBox!.y);
    await expect(page.locator(".comma-recommendation-source-detail")).toHaveCount(1);
    await expect(
      page.locator(".comma-recommendation-source-detail script")
    ).toHaveCount(0);
    await page.mouse.move(1050, 850);
    await expect(detail).toBeHidden();
    await page.keyboard.press("Tab");
    await row.locator(".comma-recommendation-inline-source").focus();
    await expect(detail).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(detail).toBeHidden();
    const geometry = await label.evaluate((node) => ({
      height: node.getBoundingClientRect().height,
      line: parseFloat(getComputedStyle(node).lineHeight),
      width: node.clientWidth,
      scroll: node.scrollWidth,
    }));
    expect(geometry.height).toBeLessThanOrEqual(geometry.line + 1);
    expect(geometry.scroll).toBeGreaterThan(geometry.width + 1);
    await page.getByRole("heading", { name: greetingHeading }).click();
    await expect.poll(() => label.evaluate((node) => node.scrollLeft)).toBe(0);
    await row.hover();
    await expect
      .poll(() => label.evaluate((node) => node.scrollLeft))
      .toBeGreaterThan(10);
    await expect
      .poll(
        () =>
          label.evaluate(
            (node) => node.scrollWidth - node.clientWidth - node.scrollLeft
          ),
        { timeout: 20000 }
      )
      .toBeLessThanOrEqual(1);
    await page.mouse.move(1050, 850);
    await expect.poll(() => label.evaluate((node) => node.scrollLeft)).toBe(0);
    await page.keyboard.press("Tab");
    await row.locator(".comma-recommendation-inline-source").focus();
    await expect
      .poll(() => label.evaluate((node) => node.scrollLeft))
      .toBeGreaterThan(10);
    await page.emulateMedia({ reducedMotion: "reduce" });
    await expect.poll(() => label.evaluate((node) => node.scrollLeft)).toBe(0);
    await expect(row).not.toHaveAttribute("data-scrolling", "true");
    await page.getByRole("heading", { name: greetingHeading }).click();
    await page.emulateMedia({ reducedMotion: "no-preference" });
    const shortLabel = "Short request";
    await label.evaluate((node, text) => {
      node.textContent = text;
    }, shortLabel);
    await row.hover();
    await expect(row).not.toHaveAttribute("data-scrolling", "true");
    await expect.poll(() => label.evaluate((node) => node.scrollLeft)).toBe(0);
    await expect(
      page
        .locator(".comma-recommendation-text-item:not([data-source-only])")
        .first()
        .locator(".comma-recommendation-text-item-content")
    ).toHaveCSS("white-space", "nowrap");
    const writes: string[] = [];
    page.on("request", (request) => {
      if (
        request.method() === "POST" &&
        /\/(messages|tasks|conversations)(?:\/|$)/.test(new URL(request.url()).pathname)
      ) {
        writes.push(request.url());
      }
    });
    const beforeUrl = page.url();
    const beforePages = page.context().pages().length;
    await row.locator(".comma-recommendation-inline-source").click();
    // The member asks Comma for help with the task. The quoted context stays in the hover.
    await expect(page.getByRole("textbox", { name: "AI prompt" })).toHaveText(
      "Help me verify reconnect behavior."
    );
    expect(page.url()).toBe(beforeUrl);
    expect(page.context().pages()).toHaveLength(beforePages);
    expect(writes).toEqual([]);
  } finally {
    await stub.close();
  }
});

test("same-name Routine tasks ask Comma for help with each distinct source URL, without the quoted context or sending", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "routine@example.com",
      token: "comma_sess_routine_test",
    });
    const envelope = structuredClone(oldMockEnvelope);
    const urls = [
      "https://github.com/team/a/pull/7",
      "https://github.com/team/b/pull/7",
    ];
    const objective = "Review login fix";
    const contexts = ["Please review authentication.", "Please review session expiry."];
    const wireEnvelope = {
      ...envelope,
      snapshot: {
        ...envelope.snapshot,
        summary: [{ kind: "markdown", text: "Your work briefing" }],
        prompts: Object.fromEntries(
          urls.map((sourceUrl, index) => [
            `s1r${index + 1}`,
            {
              sourceId: source.connectionId,
              sourceUrl,
              objective,
              context: contexts[index],
              contextLabel: "Original context (quoted)",
            },
          ])
        ),
        cards: [
          {
            ...envelope.snapshot.cards[0]!,
            items: urls.map((href, index) => ({
              id: `item-${index + 1}`,
              parts: [
                {
                  kind: "inline-link",
                  link: {
                    href,
                    label: objective,
                    sourceId: source.connectionId,
                    promptId: `s1r${index + 1}`,
                  },
                },
              ],
              action: {
                type: "send_to_comma",
                label: "Use prompt",
                requiresConfirmation: true,
                promptId: `s1r${index + 1}`,
              },
            })),
          },
        ],
      },
    };
    await page.route(
      `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations**`,
      (route) => route.fulfill({ json: wireEnvelope })
    );
    const writes: string[] = [];
    page.on("request", (request) => {
      if (
        request.method() === "POST" &&
        /\/(messages|tasks|conversations)(?:\/|$)/.test(new URL(request.url()).pathname)
      )
        writes.push(request.url());
    });
    await page.goto("/");
    const rows = page.locator('[data-source-only="true"]');
    await expect(rows).toHaveCount(2);
    const composer = page.getByRole("textbox", { name: "AI prompt" });
    let expected = "My unfinished note";
    await composer.fill(expected);
    for (const [index, url] of urls.entries()) {
      await rows.nth(index).locator(".comma-recommendation-inline-source").click();
      expected += `\n\nHelp me review login fix\n\n${url}`;
      await expect(composer).toHaveText(expected);
    }
    expect(writes).toEqual([]);
  } finally {
    await stub.close();
  }
});

test("a proactive reminder reads as a Comma chat message with its source link", async ({
  page,
}) => {
  const url = "https://mail.google.com/mail/u/0/#inbox/launch-approval";
  const transcript = [
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
          text: `Dana asked you to confirm the launch approval today so the Thursday announcement can go out. Want me to draft the reply?\n\n[Launch approval needed today](${url})`,
        },
      ],
    },
  ];
  const stub = await startChatSmokeStub({ workspaceTranscript: transcript });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "reminder@comma.local",
      token: "comma_sess_reminder",
    });
    await page.route(
      `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/recommendations**`,
      (route) => route.fulfill({ json: oldMockEnvelope })
    );
    await page.goto("/");
    await expect(
      page.getByText("Want me to draft the reply?", { exact: false })
    ).toBeVisible();
    await expect(
      page.getByRole("link", { name: "Launch approval needed today", exact: true })
    ).toHaveAttribute("href", url);
    await expect(
      page.getByText("Reminder scheduled: Check the rollout checklist", { exact: true })
    ).toBeVisible();
  } finally {
    await stub.close();
  }
});
