import "@comma/ui/styles.css";
import "@comma/test-utils/browser-commands";

import { cleanup, render } from "@comma/test-utils/render";
import { afterEach, beforeEach, expect, it } from "vitest";
import { commands, page, userEvent } from "vitest/browser";
import { Button } from "../../Button";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "../Menu";

const items = Array.from({ length: 40 }, (_, index) => `Computer ${index + 1}`);

const anchoredMenu = (rows: readonly string[]) => (
  <MenuTrigger isOpen>
    <Button hierarchy="secondary-gray">Computer</Button>
    <MenuPopover placement="bottom start">
      <Menu aria-label="Computers">
        {rows.map((row) => (
          <MenuItem id={row} key={row}>
            {row}
          </MenuItem>
        ))}
      </Menu>
    </MenuPopover>
  </MenuTrigger>
);

const popover = () =>
  document.querySelector<HTMLElement>('[data-slot="menu-popover"]')!;
const finishMotion = () => {
  for (const animation of document.getAnimations()) animation.finish();
};

beforeEach(async () => {
  await page.viewport(800, 400);
});

afterEach(async () => {
  cleanup();
  await page.viewport(1280, 720);
});

it("an anchored menu taller than the window scrolls inside it, down to its last item", async () => {
  render(anchoredMenu(items));
  await expect.element(page.getByRole("menu")).toBeVisible();
  finishMotion();

  const last = page.getByRole("menuitem", { name: "Computer 40", exact: true });
  const surface = popover();
  expect(surface.getBoundingClientRect().bottom).toBeLessThanOrEqual(
    window.innerHeight
  );
  await expect.element(last).not.toBeInViewport();

  await userEvent.hover(
    page.getByRole("menuitem", { name: "Computer 3", exact: true })
  );
  await commands.mouseWheel(0, 10_000);

  // Clipped by the menu's own scroll area, the row is in view only once the
  // menu has scrolled to it, inside the popover.
  await expect.element(last).toBeInViewport({ ratio: 1 });
  const row = last.element().getBoundingClientRect();
  const box = surface.getBoundingClientRect();
  expect(row.top).toBeGreaterThanOrEqual(box.top);
  expect(row.bottom).toBeLessThanOrEqual(box.bottom);
});

it("a short anchored menu keeps its natural size with nothing to scroll or clip", async () => {
  render(anchoredMenu(items.slice(0, 3)));
  await expect.element(page.getByRole("menu")).toBeVisible();
  finishMotion();

  const scrollArea = popover().querySelector<HTMLElement>('[data-slot="scroll-area"]')!;
  await expect
    .element(page.elementLocator(scrollArea))
    .toHaveAttribute("data-has-overflow-y", "false");
  expect(popover().getBoundingClientRect().height).toBe(
    page.getByRole("menu").element().getBoundingClientRect().height
  );
  // The menu's own shadow stays visible around it.
  expect(getComputedStyle(scrollArea).overflow).toBe("visible");
});
