import userEvent from "@testing-library/user-event";
import { render, screen, waitFor } from "@comma/test-utils/render";
import { expect, it, vi } from "vitest";
import { Button } from "../../Button";
import { TrashCanIcon } from "../../icons";
import { TaskListItem } from "../../TaskListItem/TaskListItem";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  SubmenuTrigger,
} from "../Menu";

it("runs a menu action from the keyboard and returns focus to its trigger", async () => {
  const user = userEvent.setup();
  const onAction = vi.fn();
  render(
    <MenuTrigger>
      <Button hierarchy="secondary-gray">Open task actions</Button>
      <MenuPopover>
        <Menu aria-label="Task actions" onAction={onAction}>
          <MenuItem id="rename" shortcut="⌥⌘R">
            Rename task
          </MenuItem>
          <MenuItem id="archive" isDisabled>
            Archive unavailable
          </MenuItem>
          <MenuSeparator />
          <MenuItem icon={<TrashCanIcon />} id="delete" tone="destructive">
            Delete
          </MenuItem>
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
  const trigger = screen.getByRole("button", { name: "Open task actions" });
  await user.click(trigger);
  expect(screen.getByRole("menuitem", { name: "Archive unavailable" })).toHaveAttribute(
    "aria-disabled",
    "true"
  );
  expect(screen.getByRole("separator")).toBeInTheDocument();
  await user.keyboard("{Escape}");
  await waitFor(() => expect(screen.queryByRole("menu")).toBeNull());
  await waitFor(() => expect(trigger).toHaveFocus());

  await user.keyboard("{Enter}");
  await waitFor(() =>
    expect(screen.getByRole("menuitem", { name: "Rename task" })).toHaveFocus()
  );
  // The disabled item is skipped.
  await user.keyboard("{ArrowDown}");
  expect(screen.getByRole("menuitem", { name: "Delete" })).toHaveFocus();
  await user.keyboard("{Enter}");
  expect(onAction).toHaveBeenCalledWith("delete");
  await waitFor(() => expect(screen.queryByRole("menu")).toBeNull());
  await waitFor(() => expect(trigger).toHaveFocus());
});

it("keeps focus and the active path through connected submenus from the keyboard", async () => {
  const user = userEvent.setup();
  render(
    <MenuTrigger>
      <Button hierarchy="secondary-gray">Open connected filters</Button>
      <MenuPopover closeSubmenusOnPointerLeave isNonModal>
        <Menu aria-label="Connected filters">
          <SubmenuTrigger delay={0}>
            <MenuItem id="status" shortcut="›">
              Status
            </MenuItem>
            <MenuPopover animation="none" offset={0} placement="left top">
              <Menu aria-label="Status options">
                <MenuItem id="backlog">Backlog</MenuItem>
              </Menu>
            </MenuPopover>
          </SubmenuTrigger>
          <SubmenuTrigger delay={0}>
            <MenuItem id="worker" shortcut="›">
              Worker
            </MenuItem>
            <MenuPopover animation="none" offset={0} placement="left top">
              <Menu aria-label="Worker options">
                <MenuItem id="codex">Codex</MenuItem>
              </Menu>
            </MenuPopover>
          </SubmenuTrigger>
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
  const trigger = screen.getByRole("button", { name: "Open connected filters" });
  trigger.focus();
  await user.keyboard("{Enter}");
  const status = await screen.findByRole("menuitem", { name: "Status" });
  await waitFor(() => expect(status).toHaveFocus());

  await user.keyboard("{ArrowRight}");
  await waitFor(() =>
    expect(screen.getByRole("menuitem", { name: "Backlog" })).toHaveFocus()
  );
  expect(status).toHaveAttribute("aria-expanded", "true");

  await user.keyboard("{ArrowLeft}");
  await waitFor(() =>
    expect(screen.queryByRole("menuitem", { name: "Backlog" })).toBeNull()
  );
  await waitFor(() => expect(status).toHaveFocus());

  await user.keyboard("{ArrowDown}");
  const worker = screen.getByRole("menuitem", { name: "Worker" });
  expect(worker).toHaveFocus();
  await user.keyboard("{ArrowRight}");
  await waitFor(() =>
    expect(screen.getByRole("menuitem", { name: "Codex" })).toHaveFocus()
  );

  await user.keyboard("{Escape}");
  await waitFor(() =>
    expect(screen.queryByRole("menuitem", { name: "Codex" })).toBeNull()
  );
  await waitFor(() => expect(worker).toHaveFocus());
  await user.keyboard("{Escape}");
  await waitFor(() => expect(screen.queryByRole("menu")).toBeNull());
  await waitFor(() => expect(trigger).toHaveFocus());
});

it("opens a task row's context menu from the keyboard and restores focus", async () => {
  const user = userEvent.setup();
  const onAction = vi.fn();
  render(
    <TaskListItem
      aria-label="Keyboard task row"
      contextMenu={{
        "aria-label": "Keyboard task actions",
        onAction,
        children: (
          <>
            <MenuItem id="rename-task">Rename keyboard task</MenuItem>
            <MenuItem id="delete-task" tone="destructive">
              Delete keyboard task
            </MenuItem>
          </>
        ),
      }}
      icon={<span>•</span>}
      title="Keyboard context menu task"
    />
  );
  const row = screen.getByLabelText("Keyboard task row");
  row.focus();
  await user.keyboard("{Shift>}{F10}{/Shift}");
  await screen.findByRole("menu", { name: "Keyboard task actions" });
  expect(row).toHaveAttribute("data-context-menu-open", "true");
  await waitFor(() =>
    expect(screen.getByRole("menuitem", { name: "Rename keyboard task" })).toHaveFocus()
  );
  await user.keyboard("{Enter}");
  expect(onAction).toHaveBeenCalledWith("rename-task");
  await waitFor(() => expect(screen.queryByRole("menu")).toBeNull());
  await waitFor(() => expect(row).toHaveFocus());
  expect(row).toHaveAttribute("data-context-menu-open", "false");

  await user.keyboard("{Shift>}{F10}{/Shift}");
  await screen.findByRole("menu", { name: "Keyboard task actions" });
  await user.keyboard("{Escape}");
  await waitFor(() => expect(screen.queryByRole("menu")).toBeNull());
  await waitFor(() => expect(row).toHaveFocus());
});
