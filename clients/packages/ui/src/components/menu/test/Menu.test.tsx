import { useRef, useState } from "react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, screen } from "@comma/test-utils/render";
import { motionDuration } from "@comma/ui";
import { Button } from "../../Button";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  SubmenuTrigger,
} from "../Menu";
import { menuCompactClasses, menuClasses } from "../styles";

const TestIcon = ({ name }: { name: string }) => <span data-testid={name} />;

const TaskActionsMenu = ({
  onAction = vi.fn(),
}: {
  onAction?: (id: string) => void;
}) => (
  <Menu aria-label="Task actions" onAction={(id) => onAction(String(id))}>
    <MenuItem icon={<TestIcon name="unpin-icon" />} id="unpin" shortcut="⌥⌘P">
      Unpin
    </MenuItem>
    <MenuItem id="rename" shortcut="⌥⌘R">
      Rename task
    </MenuItem>
    <MenuSeparator />
    <MenuItem id="delete" tone="destructive">
      Delete
    </MenuItem>
  </Menu>
);

describe("Menu", () => {
  it("keeps the edit menu compact instead of the task-menu width", () => {
    expect(menuClasses).toContain("w-60");
    expect(menuCompactClasses).toContain("w-fit");
    expect(menuCompactClasses).toContain("min-w-44");
    expect(menuCompactClasses).not.toContain("w-60");
  });

  it("uses the Figma menu shell, item spacing, separator, and destructive tone", () => {
    const { container } = render(<TaskActionsMenu />);

    const menu = screen.getByRole("menu", { name: "Task actions" });
    const deleteItem = screen.getByRole("menuitem", { name: "Delete" });

    expect(menu).toHaveClass(
      "w-60",
      "rounded-xl",
      "border-[length:var(--border-width-0-5)]",
      "border-primary",
      "bg-popup-secondary",
      "py-sm",
      "text-sm",
      "text-secondary",
      "shadow-lg"
    );
    expect(screen.getByRole("menuitem", { name: "Unpin" })).toHaveClass("px-sm");
    expect(screen.getByRole("menuitem", { name: "Unpin" })).not.toHaveClass("py-px");
    expect(container.querySelector('[data-slot="menu-item-content"]')).toHaveClass(
      "gap-lg",
      "rounded-sm",
      "px-md",
      "py-sm",
      "font-medium"
    );
    expect(container.querySelector('[data-slot="menu-item-content"]')).not.toHaveClass(
      "text-sm",
      "transition-colors"
    );
    expect(container.querySelector('[data-slot="menu-item-content"]')).not.toHaveClass(
      "leading-5"
    );
    expect(container.querySelector('[data-slot="menu-item-icon"]')).toHaveClass(
      "size-xl"
    );
    expect(screen.getByText("⌥⌘P")).toHaveClass(
      "text-xs",
      "font-regular",
      "text-quaternary"
    );
    expect(screen.getByText("⌥⌘P")).not.toHaveClass("font-normal", "leading-[18px]");
    expect(screen.getByRole("separator")).toHaveClass(
      "my-xs",
      "border-t-[length:var(--border-width-0-5)]",
      "border-primary"
    );
    expect(screen.getByRole("separator")).not.toHaveClass("mx-sm");
    expect(deleteItem).toHaveAttribute("data-tone", "destructive");
    expect(deleteItem.firstElementChild).toHaveClass("text-error-primary");
  });

  it("uses foreground secondary for ordinary icons only while hovered", async () => {
    const user = userEvent.setup();
    const { container } = render(
      <Menu aria-label="Task actions">
        <MenuItem icon={<TestIcon name="rename-icon" />} id="rename">
          Rename task
        </MenuItem>
        <MenuItem icon={<TestIcon name="delete-icon" />} id="delete" tone="destructive">
          Delete
        </MenuItem>
      </Menu>
    );

    const renameItem = screen.getByRole("menuitem", { name: "Rename task" });
    const renameIcon = container.querySelector(
      '[data-slot="menu-item-icon"]:has([data-testid="rename-icon"])'
    );
    const deleteIcon = container.querySelector(
      '[data-slot="menu-item-icon"]:has([data-testid="delete-icon"])'
    );
    const renameContent = renameItem.firstElementChild;
    const deleteContent = screen.getByRole("menuitem", {
      name: "Delete",
    }).firstElementChild;

    expect(renameIcon).not.toHaveClass("text-fg-secondary");
    expect(deleteIcon).not.toHaveClass("text-fg-secondary");

    fireEvent.pointerDown(document.body, { pointerType: "mouse" });
    await user.hover(renameItem);

    expect(renameIcon).toHaveClass("text-fg-secondary");
    expect(renameContent).toHaveClass("bg-quaternary");

    await user.unhover(renameItem);
    await user.hover(screen.getByRole("menuitem", { name: "Delete" }));

    expect(deleteIcon).not.toHaveClass("text-fg-secondary");
    expect(deleteContent).toHaveClass("bg-menu-hover-error");
    expect(deleteContent).not.toHaveClass("bg-quaternary");
  });

  it("keeps a submenu trigger active through its connected panel and clears it on exit", async () => {
    const user = userEvent.setup();
    render(
      <MenuTrigger>
        <Button hierarchy="secondary-gray">Open filters</Button>
        <MenuPopover closeSubmenusOnPointerLeave>
          <Menu aria-label="Filters">
            <SubmenuTrigger delay={0}>
              <MenuItem
                appearance="sidebar"
                icon={<TestIcon name="filter-icon" />}
                id="status"
              >
                Status
              </MenuItem>
              <MenuPopover offset={0} placement="left top">
                <Menu aria-label="Status filters">
                  <MenuItem id="backlog">Backlog</MenuItem>
                </Menu>
              </MenuPopover>
            </SubmenuTrigger>
          </Menu>
        </MenuPopover>
      </MenuTrigger>
    );

    await user.click(screen.getByRole("button", { name: "Open filters" }));

    const statusEntry = screen.getByRole("menuitem", { name: "Status" });
    const statusContent = statusEntry.firstElementChild;
    const statusIcon = statusEntry.querySelector('[data-slot="menu-item-icon"]');

    expect(statusEntry).toHaveAttribute("data-appearance", "sidebar");
    expect(statusContent).toHaveClass("text-sidebar-text-secondary");
    expect(statusIcon).toHaveClass("text-sidebar-icon-primary");

    await user.click(statusEntry);
    const backlogEntry = await screen.findByRole("menuitem", { name: "Backlog" });

    await user.hover(backlogEntry);

    expect(statusEntry).toHaveAttribute("aria-expanded", "true");
    expect(statusEntry).toHaveAttribute("aria-haspopup", "menu");
    expect(statusEntry).not.toHaveAttribute("data-hovered");
    expect(statusContent).toHaveClass("bg-quaternary", "text-sidebar-text-highlight");
    expect(statusIcon).toHaveClass("text-sidebar-icon-primary");
    await user.hover(
      screen.getByRole("button", { name: "Open filters", hidden: true })
    );

    await act(async () => {
      await new Promise((resolve) =>
        setTimeout(resolve, motionDuration.submenuCloseDelay)
      );
    });
    expect(statusEntry).toHaveAttribute("aria-expanded", "false");
    expect(statusContent).not.toHaveClass(
      "bg-quaternary",
      "text-sidebar-text-highlight"
    );
    expect(screen.getByRole("menu", { name: "Open filters" })).toBeVisible();
  });

  it("uses tokenized press feedback while a pointer is held", () => {
    render(
      <Menu aria-label="Task actions">
        <MenuItem id="rename">Rename task</MenuItem>
      </Menu>
    );

    const item = screen.getByRole("menuitem", { name: "Rename task" });
    const content = item.firstElementChild;

    fireEvent.pointerDown(item, {
      button: 0,
      detail: 1,
      height: 2,
      isPrimary: true,
      pointerId: 1,
      pointerType: "mouse",
      pressure: 0.5,
      width: 2,
    });

    expect(item).toHaveAttribute("data-pressed", "true");
    expect(content).toHaveClass(
      "scale-[var(--motion-scale-pressed)]",
      "duration-[var(--motion-duration-feedback-in)]",
      "motion-reduce:scale-100"
    );

    fireEvent.pointerUp(item, {
      button: 0,
      detail: 1,
      height: 2,
      isPrimary: true,
      pointerId: 1,
      pointerType: "mouse",
      pressure: 0.5,
      width: 2,
    });
    fireEvent.click(item, { button: 0, detail: 1 });

    expect(item).not.toHaveAttribute("data-pressed");
    expect(content).not.toHaveClass("scale-[var(--motion-scale-pressed)]");
  });

  it("allows a menu to inherit a scoped typography token", () => {
    const { container } = render(
      <Menu aria-label="Compact actions" className="text-xs">
        <MenuItem id="compact">Compact action</MenuItem>
      </Menu>
    );

    expect(screen.getByRole("menu", { name: "Compact actions" })).toHaveClass(
      "text-xs"
    );
    expect(screen.getByRole("menu", { name: "Compact actions" })).not.toHaveClass(
      "text-sm"
    );
    expect(container.querySelector('[data-slot="menu-item-content"]')).not.toHaveClass(
      "text-sm"
    );
  });

  it("does not retain the hover background after pointer focus leaves an item", async () => {
    const user = userEvent.setup();
    const { container } = render(
      <Menu aria-label="Task actions">
        <MenuItem id="unpin">Unpin</MenuItem>
      </Menu>
    );

    const item = screen.getByRole("menuitem", { name: "Unpin" });
    const content = container.querySelector('[data-slot="menu-item-content"]');

    await user.click(item);
    await user.unhover(item);

    expect(content).not.toHaveClass("bg-quaternary");
  });

  it("keeps keyboard navigation active while the pointer remains over the previous item", async () => {
    const user = userEvent.setup();
    render(
      <MenuTrigger>
        <Button hierarchy="secondary-gray">Open task actions</Button>
        <MenuPopover>
          <TaskActionsMenu />
        </MenuPopover>
      </MenuTrigger>
    );

    await user.click(screen.getByRole("button", { name: "Open task actions" }));

    const renameItem = screen.getByRole("menuitem", { name: "Rename task" });
    const deleteItem = screen.getByRole("menuitem", { name: "Delete" });
    const renameContent = renameItem.firstElementChild;
    const deleteContent = deleteItem.firstElementChild;

    await user.hover(renameItem);
    fireEvent.pointerMove(renameItem, { clientX: 32, clientY: 48 });
    expect(renameItem).toHaveFocus();
    expect(renameContent).toHaveClass("bg-quaternary");

    await user.keyboard("{ArrowDown}");
    fireEvent.pointerMove(renameItem, { clientX: 33, clientY: 49 });

    expect(deleteItem).toHaveFocus();
    expect(renameItem).toHaveAttribute("data-hovered", "true");
    expect(deleteContent).toHaveClass("bg-menu-hover-error", "shadow-focus-gray");
    expect(renameContent).not.toHaveClass("bg-quaternary");

    await user.unhover(renameItem);
    await user.hover(renameItem);

    expect(renameContent).toHaveClass("bg-quaternary");
    expect(deleteContent).not.toHaveClass("bg-menu-hover-error", "shadow-focus-gray");
  });

  it.each([
    ["{ArrowDown}", "Rename task"],
    ["{ArrowUp}", "Delete"],
  ])(
    "keeps %s keyboard navigation authoritative over incidental pointer hover",
    async (key, expectedItemName) => {
      const user = userEvent.setup();
      render(
        <MenuTrigger>
          <Button hierarchy="secondary-gray">Open task actions</Button>
          <MenuPopover>
            <TaskActionsMenu />
          </MenuPopover>
        </MenuTrigger>
      );

      const trigger = screen.getByRole("button", { name: "Open task actions" });
      await user.tab();
      expect(trigger).toHaveFocus();
      await user.keyboard("{Enter}");

      const renameItem = screen.getByRole("menuitem", { name: "Rename task" });
      fireEvent.pointerEnter(renameItem, { pointerType: "mouse" });

      expect(screen.getByRole("menuitem", { name: "Unpin" })).toHaveFocus();

      await user.keyboard(key);

      expect(screen.getByRole("menuitem", { name: expectedItemName })).toHaveFocus();
    }
  );

  it("opens from a trigger, invokes the selected action, and closes the menu", async () => {
    const user = userEvent.setup();
    const onAction = vi.fn();

    render(
      <MenuTrigger>
        <Button hierarchy="secondary-gray">Open task actions</Button>
        <MenuPopover>
          <TaskActionsMenu onAction={onAction} />
        </MenuPopover>
      </MenuTrigger>
    );

    expect(screen.queryByRole("menu")).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Open task actions" }));
    expect(
      screen.getByRole("menu").closest('[data-slot="menu-popover"]')
    ).toHaveAttribute("data-animation", "anchor");
    await user.click(screen.getByRole("menuitem", { name: "Rename task" }));

    expect(onAction).toHaveBeenCalledWith("rename");
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });

  it("uses the shared animation for keyboard-triggered menus", async () => {
    const user = userEvent.setup();
    render(
      <MenuTrigger>
        <Button hierarchy="secondary-gray">Open task actions</Button>
        <MenuPopover>
          <TaskActionsMenu />
        </MenuPopover>
      </MenuTrigger>
    );

    await user.tab();
    await user.keyboard("{Enter}");

    expect(
      screen.getByRole("menu").closest('[data-slot="menu-popover"]')
    ).toHaveAttribute("data-animation", "anchor");
  });

  it("does not invoke a disabled item", async () => {
    const user = userEvent.setup();
    const onAction = vi.fn();

    render(
      <Menu aria-label="Task actions" onAction={(id) => onAction(String(id))}>
        <MenuItem id="rename" isDisabled>
          Rename task
        </MenuItem>
      </Menu>
    );

    await user.click(screen.getByRole("menuitem", { name: "Rename task" }));

    expect(onAction).not.toHaveBeenCalled();
  });

  it("anchors a selection-aligned popover on the checked row and offers reveal", async () => {
    const user = userEvent.setup();
    const options = [
      { id: "always", label: "Always show" },
      { id: "badged", label: "Show when badged" },
      { id: "never", label: "Don't show" },
    ];

    const SelectionMenu = () => {
      const triggerRef = useRef<HTMLDivElement>(null);
      const [value, setValue] = useState("badged");

      return (
        <div ref={triggerRef}>
          <MenuTrigger>
            <Button hierarchy="secondary-gray">Show</Button>
            <MenuPopover
              selectionAlign={{
                items: options.map(() => ({})),
                selectedIndex: options.findIndex((option) => option.id === value),
                triggerRef,
              }}
            >
              <Menu
                aria-label="Visibility"
                onAction={(key) => setValue(String(key))}
                selectedKeys={[value]}
                selectionMode="single"
                variant="embedded"
              >
                {options.map((option) => (
                  <MenuItem id={option.id} key={option.id}>
                    {option.label}
                  </MenuItem>
                ))}
              </Menu>
            </MenuPopover>
          </MenuTrigger>
        </div>
      );
    };

    render(<SelectionMenu />);
    await user.click(screen.getByRole("button", { name: "Show" }));

    const popover = screen.getByRole("menu").closest('[data-slot="menu-popover"]');
    expect(popover).toHaveAttribute("data-positioning", "selection-aligned");
    expect(popover).toHaveAttribute("data-anchor-index", "1");
    // Selection alignment retains the shared menu animation.
    expect(popover).toHaveAttribute("data-animation", "anchor");
    // The bottom chevron that reveals viewport-clipped rows on hover.
    expect(
      popover?.querySelector('[data-slot="dropdown-scroll-down-hit"]')
    ).not.toBeNull();

    // Keyboard focus lands on the checked row that sits over the trigger.
    await act(async () => {
      await new Promise((resolve) => requestAnimationFrame(() => resolve(undefined)));
    });
    expect(
      screen.getByRole("menuitemradio", { name: "Show when badged" })
    ).toHaveFocus();

    // Re-opening after a new selection re-anchors on the new checked row.
    await user.click(screen.getByRole("menuitemradio", { name: "Don't show" }));
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Show" }));
    expect(
      screen.getByRole("menu").closest('[data-slot="menu-popover"]')
    ).toHaveAttribute("data-anchor-index", "2");
  });
});

describe('MenuItem selectionIndicator="check"', () => {
  it("marks only the selected row with a checkmark and keeps the slot on the rest", () => {
    const { container } = render(
      <Menu aria-label="Device" selectedKeys={["mac"]} selectionMode="single">
        <MenuItem id="mac" selectionIndicator="check">
          This Mac
        </MenuItem>
        <MenuItem id="nas" selectionIndicator="check">
          Studio NAS
        </MenuItem>
      </Menu>
    );

    const indicators = container.querySelectorAll(
      '[data-slot="menu-item-selection-indicator"]'
    );
    expect(indicators).toHaveLength(2);
    expect(indicators[0]).not.toHaveClass("invisible");
    expect(indicators[0]?.querySelector("[data-comma-icon]")).not.toBeNull();
    // The unselected row keeps the slot so labels stay aligned.
    expect(indicators[1]).toHaveClass("invisible");
    expect(container.querySelector('[data-slot="checkbox-control"]')).toBeNull();
  });
});
