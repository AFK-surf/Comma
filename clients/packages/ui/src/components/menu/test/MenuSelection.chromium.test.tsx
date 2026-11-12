import "@comma/ui/styles.css";

import { render } from "@comma/test-utils/render";
import { afterEach, expect, it } from "vitest";
import { Button } from "../../Button";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "../Menu";
import { CONTEXT_SELECTION_HIGHLIGHT } from "../preserveTextSelection";

// A modal menu makes the page inert, and Chromium is slow with a selection inside inert content: every row the
// pointer crosses moves focus, and each focus change walks the inert content around the selection. So the page's
// selection is held aside, painted as a highlight, while such a menu is open.

afterEach(() => {
  window.getSelection()?.removeAllRanges();
});

const page = (isOpen: boolean, isNonModal = false) => (
  <>
    <p>Selected diff text</p>
    <MenuTrigger isOpen={isOpen}>
      <Button hierarchy="secondary-gray">More</Button>
      <MenuPopover isNonModal={isNonModal}>
        <Menu aria-label="Changes">
          <MenuItem id="wrap">Word wrap</MenuItem>
          <MenuItem id="refresh">Refresh</MenuItem>
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  </>
);

const select = (paragraph: HTMLElement) => {
  const text = paragraph.firstChild!;
  window.getSelection()!.setBaseAndExtent(text, 0, text, 8);
};

it("holds the page's selection aside while a modal menu is open, painted, and gives it back as it closes", () => {
  const { container, rerender } = render(page(false));
  const paragraph = container.querySelector("p")!;
  select(paragraph);

  rerender(page(true));
  expect(document.querySelector('[role="menu"]')).not.toBeNull();
  expect(window.getSelection()!.rangeCount).toBe(0);
  expect(CSS.highlights.get(CONTEXT_SELECTION_HIGHLIGHT)?.size).toBe(1);

  rerender(page(false));
  expect(window.getSelection()!.toString()).toBe("Selected");
  expect(CSS.highlights.has(CONTEXT_SELECTION_HIGHLIGHT)).toBe(false);
});

it("leaves the selection where it is under a non-modal menu, which makes nothing inert", () => {
  const { container, rerender } = render(page(false, true));
  select(container.querySelector("p")!);

  rerender(page(true, true));
  expect(document.querySelector('[role="menu"]')).not.toBeNull();
  expect(window.getSelection()!.toString()).toBe("Selected");
});
