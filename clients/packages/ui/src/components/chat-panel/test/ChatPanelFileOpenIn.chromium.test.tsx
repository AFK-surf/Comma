import "@comma/ui/styles.css";
import "@comma/test-utils/browser-commands";

import { cleanup, render } from "@comma/test-utils/render";
import { afterEach, expect, it } from "vitest";
import { commands, page, userEvent } from "vitest/browser";
import {
  ChatPanelFileOpenInMenu,
  fileApplicationsMaxHeight,
  type ChatPanelFileOpenInAction,
} from "../ChatPanelFileOpenInMenu";

const applications = Array.from({ length: 30 }, (_, index) => ({
  id: `app-${index + 1}`,
  name: `Application ${index + 1}`,
}));
const action: ChatPanelFileOpenInAction = {
  listApplications: async () => applications,
  openApplication: async () => undefined,
  reveal: { label: "Reveal in Finder", run: async () => undefined },
};

afterEach(async () => {
  cleanup();
  await page.viewport(1280, 720);
});

it("keeps a long list of applications to its own height in a tall window, and scrolls to the rest", async () => {
  await page.viewport(900, 900);
  render(
    <div style={{ display: "flex", justifyContent: "flex-end", padding: 24 }}>
      <ChatPanelFileOpenInMenu action={action} />
    </div>
  );
  await userEvent.click(page.getByRole("button", { name: "Open in" }));
  await expect
    .element(page.getByRole("menuitem", { name: "Application 1", exact: true }))
    .toBeVisible();
  for (const animation of document.getAnimations()) animation.finish();

  // The window has room for every row; the list still stops at its bound.
  const surface = document.querySelector<HTMLElement>('[data-slot="menu-popover"]')!;
  expect(surface.getBoundingClientRect().height).toBeLessThanOrEqual(
    fileApplicationsMaxHeight
  );
  const last = page.getByRole("menuitem", { name: "Reveal in Finder" });
  await expect.element(last).not.toBeInViewport();
  await userEvent.hover(
    page.getByRole("menuitem", { name: "Application 3", exact: true })
  );
  await commands.mouseWheel(0, 10_000);
  await expect.element(last).toBeInViewport();
});

it("flips upward when applications load near the bottom of the window", async () => {
  await page.viewport(720, 560);
  render(
    <div
      style={{
        height: "100vh",
        display: "flex",
        flexDirection: "column",
        justifyContent: "flex-end",
        alignItems: "flex-end",
        padding: "24px 24px 148px",
        boxSizing: "border-box",
      }}
    >
      <ChatPanelFileOpenInMenu action={action} />
    </div>
  );
  const trigger = page.getByRole("button", { name: "Open in" });
  await userEvent.click(trigger);
  await expect
    .element(page.getByRole("menuitem", { name: "Application 1", exact: true }))
    .toBeVisible();
  const surface = document.querySelector<HTMLElement>('[data-slot="menu-popover"]')!;
  await expect
    .element(page.elementLocator(surface))
    .toHaveAttribute("data-placement", "top");
  for (const animation of document.getAnimations()) animation.finish();

  const triggerRect = trigger.element().getBoundingClientRect();
  const popoverRect = surface.getBoundingClientRect();
  expect(popoverRect.bottom).toBeLessThanOrEqual(triggerRect.top);
  expect(popoverRect.top).toBeGreaterThanOrEqual(0);
  expect(popoverRect.height).toBeLessThanOrEqual(fileApplicationsMaxHeight);
});

it("flips upward even when the loading menu already fills the space below the trigger", async () => {
  await page.viewport(720, 560);
  let resolveApps!: (apps: typeof applications) => void;
  const deferredAction: ChatPanelFileOpenInAction = {
    listApplications: () =>
      new Promise((resolve) => {
        resolveApps = resolve;
      }),
    openApplication: async () => undefined,
    reveal: { label: "Reveal in Finder", run: async () => undefined },
  };
  render(
    <div
      style={{
        height: "100vh",
        display: "flex",
        flexDirection: "column",
        justifyContent: "flex-end",
        alignItems: "flex-end",
        padding: "24px 24px 104px",
        boxSizing: "border-box",
      }}
    >
      <ChatPanelFileOpenInMenu action={deferredAction} />
    </div>
  );
  const trigger = page.getByRole("button", { name: "Open in" });
  await userEvent.click(trigger);
  await expect
    .element(page.getByRole("menuitem", { name: "Reveal in Finder" }))
    .toBeVisible();
  const surface = document.querySelector<HTMLElement>('[data-slot="menu-popover"]')!;
  expect(surface.dataset.placement).toBe("bottom");

  resolveApps(applications);
  await expect
    .element(page.getByRole("menuitem", { name: "Application 1", exact: true }))
    .toBeVisible();
  await expect
    .element(page.elementLocator(surface))
    .toHaveAttribute("data-placement", "top");
  for (const animation of document.getAnimations()) animation.finish();

  const triggerRect = trigger.element().getBoundingClientRect();
  const popoverRect = surface.getBoundingClientRect();
  expect(popoverRect.bottom).toBeLessThanOrEqual(triggerRect.top);
  expect(popoverRect.height).toBeLessThanOrEqual(fileApplicationsMaxHeight);
});

it("clamps to the viewport and scrolls when neither side fits the full list bound", async () => {
  await page.viewport(720, 300);
  render(
    <div style={{ display: "flex", justifyContent: "flex-end", padding: "48px 24px" }}>
      <ChatPanelFileOpenInMenu action={action} />
    </div>
  );
  await userEvent.click(page.getByRole("button", { name: "Open in" }));
  await expect
    .element(page.getByRole("menuitem", { name: "Application 1", exact: true }))
    .toBeVisible();
  for (const animation of document.getAnimations()) animation.finish();

  const surface = document.querySelector<HTMLElement>('[data-slot="menu-popover"]')!;
  const popoverRect = surface.getBoundingClientRect();
  expect(popoverRect.bottom).toBeLessThanOrEqual(window.innerHeight);
  expect(popoverRect.height).toBeLessThan(fileApplicationsMaxHeight);

  const last = page.getByRole("menuitem", { name: "Reveal in Finder" });
  await expect.element(last).not.toBeInViewport();
  await userEvent.hover(
    page.getByRole("menuitem", { name: "Application 2", exact: true })
  );
  await commands.mouseWheel(0, 10_000);
  await expect.element(last).toBeInViewport();
});
