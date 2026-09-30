import { useRef, useState } from "react";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { expect, userEvent, waitFor, within } from "storybook/test";
import {
  Button,
  ChainLinkIcon,
  EditBigIcon,
  CopyContextMenu,
  LinkContextMenu,
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  TextEditContextMenu,
  TrashCanIcon,
  UnpinIcon,
  useTextEditContextMenuState,
} from "../index";

const TaskActionsMenu = () => (
  <Menu aria-label="Task actions">
    <MenuItem icon={<UnpinIcon />} id="unpin" shortcut="⌥⌘P">
      Unpin
    </MenuItem>
    <MenuItem icon={<EditBigIcon />} id="rename" shortcut="⌥⌘R">
      Rename task
    </MenuItem>
    <MenuItem icon={<ChainLinkIcon />} id="copy-link" shortcut="⌥⌘L">
      Copy link
    </MenuItem>
    <MenuSeparator />
    <MenuItem icon={<TrashCanIcon />} id="delete" tone="destructive">
      Delete
    </MenuItem>
  </Menu>
);

const TextEditContextMenuDemo = () => {
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const [lastAction, setLastAction] = useState("Right-click or Shift+F10");
  const { isOpen, pointerOffsets, handleOpenChange, openAtPointer, openFromKeyboard } =
    useTextEditContextMenuState({ isEnabled: true });

  return (
    <div className="flex flex-col items-start gap-md">
      <button
        className="rounded-md bg-primary px-lg py-sm text-sm font-medium text-secondary shadow-xs ring-1 ring-primary ring-inset"
        onContextMenu={(event) => {
          event.preventDefault();
          openAtPointer(event.currentTarget, event.clientX, event.clientY);
        }}
        onKeyDown={(event) => {
          if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
            event.preventDefault();
            openFromKeyboard();
          }
        }}
        ref={triggerRef}
        type="button"
      >
        Edit surface
      </button>
      <p className="text-sm text-secondary">{lastAction}</p>
      <TextEditContextMenu
        isOpen={isOpen}
        labels={{
          ariaLabel: "Edit menu",
          cut: "Cut",
          copy: "Copy",
          paste: "Paste",
          selectAll: "Select All",
        }}
        onAction={(action) => {
          setLastAction(`Ran ${action}`);
        }}
        onOpenChange={handleOpenChange}
        pointerOffsets={pointerOffsets}
        triggerRef={triggerRef}
      />
    </div>
  );
};

const meta = {
  title: "Base components/Menu",
  parameters: {
    layout: "centered",
  },
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {
  render: () => <TaskActionsMenu />,
};

export const Triggered: Story = {
  render: () => (
    <MenuTrigger>
      <Button hierarchy="secondary-gray">Task actions</Button>
      <MenuPopover>
        <TaskActionsMenu />
      </MenuPopover>
    </MenuTrigger>
  ),
};

const visibilityOptions = [
  { id: "always", label: "Always show" },
  { id: "badged", label: "Show when badged" },
  { id: "never", label: "Don't show" },
];

const SelectionAlignedDemo = () => {
  const triggerRef = useRef<HTMLDivElement | null>(null);
  const [value, setValue] = useState("badged");
  const selectedLabel =
    visibilityOptions.find((option) => option.id === value)?.label ?? "Show";

  return (
    <div ref={triggerRef}>
      <MenuTrigger>
        <Button hierarchy="secondary-gray">{selectedLabel}</Button>
        <MenuPopover
          selectionAlign={{
            items: visibilityOptions.map(() => ({})),
            selectedIndex: visibilityOptions.findIndex((option) => option.id === value),
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
            {visibilityOptions.map((option) => (
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

export const SelectionAligned: Story = {
  name: "Selection-aligned pop-up",
  render: () => <SelectionAlignedDemo />,
};

export const TextEdit: Story = {
  name: "Text edit context menu",
  render: () => <TextEditContextMenuDemo />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);
    const trigger = canvas.getByRole("button", { name: "Edit surface" });

    trigger.focus();
    await userEvent.keyboard("{Shift>}{F10}{/Shift}");

    expect(await page.findByRole("menuitem", { name: "Copy" })).toHaveFocus();
    expect(page.getByRole("menuitem", { name: "Paste" })).toBeInTheDocument();
    expect(page.getByRole("menuitem", { name: "Cut" })).toBeInTheDocument();
    expect(page.getByRole("menuitem", { name: "Select All" })).toBeInTheDocument();

    await userEvent.keyboard("{Escape}");
    await waitFor(() => expect(page.queryByRole("menu")).not.toBeInTheDocument());
  },
};

const LinkContextMenuDemo = () => {
  const triggerRef = useRef<HTMLAnchorElement | null>(null);
  const [lastAction, setLastAction] = useState("Right-click the link");
  const { isOpen, pointerOffsets, handleOpenChange, openAtPointer } =
    useTextEditContextMenuState({ isEnabled: true });

  return (
    <div className="flex flex-col items-start gap-md">
      <a
        className="text-sm font-medium text-brand-secondary underline"
        href="https://example.com/docs"
        onContextMenu={(event) => {
          event.preventDefault();
          openAtPointer(event.currentTarget, event.clientX, event.clientY);
        }}
        ref={triggerRef}
      >
        example.com/docs
      </a>
      <p className="text-sm text-secondary">{lastAction}</p>
      <LinkContextMenu
        isOpen={isOpen}
        labels={{
          ariaLabel: "Link menu",
          copyLink: "Copy Link",
          copyMessage: "Copy message",
          openInComma: "Open in Comma",
          openInExternalBrowser: "Open in External Browser",
        }}
        onAction={(action) => {
          setLastAction(`Ran ${action}`);
        }}
        onOpenChange={handleOpenChange}
        pointerOffsets={pointerOffsets}
        triggerRef={triggerRef}
      />
    </div>
  );
};

export const Link: Story = {
  name: "Link context menu",
  render: () => <LinkContextMenuDemo />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);
    const link = canvas.getByRole("link", { name: "example.com/docs" });

    await userEvent.pointer({ keys: "[MouseRight>]", target: link });

    expect(
      await page.findByRole("menuitem", { name: "Open in External Browser" })
    ).toBeInTheDocument();
    expect(page.getByRole("menuitem", { name: "Open in Comma" })).toBeInTheDocument();
    expect(page.getByRole("menuitem", { name: "Copy Link" })).toBeInTheDocument();
    expect(page.getByRole("menuitem", { name: "Copy message" })).toBeInTheDocument();
    expect(page.getByRole("separator")).toBeInTheDocument();

    await userEvent.keyboard("{Escape}");
    await waitFor(() => expect(page.queryByRole("menu")).not.toBeInTheDocument());
  },
};

const CopyContextMenuDemo = () => {
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const [lastAction, setLastAction] = useState("Right-click the text");
  const { isOpen, pointerOffsets, handleOpenChange, openAtPointer } =
    useTextEditContextMenuState({ isEnabled: true });

  return (
    <div className="flex flex-col items-start gap-md">
      <button
        className="text-sm text-secondary"
        onContextMenu={(event) => {
          event.preventDefault();
          openAtPointer(event.currentTarget, event.clientX, event.clientY);
        }}
        ref={triggerRef}
        type="button"
      >
        Agent reply text
      </button>
      <p className="text-sm text-secondary">{lastAction}</p>
      <CopyContextMenu
        isOpen={isOpen}
        labels={{
          ariaLabel: "Text menu",
          copy: "Copy",
        }}
        onAction={(action) => {
          setLastAction(`Ran ${action}`);
        }}
        onOpenChange={handleOpenChange}
        pointerOffsets={pointerOffsets}
        triggerRef={triggerRef}
      />
    </div>
  );
};

export const Copy: Story = {
  name: "Copy context menu",
  render: () => <CopyContextMenuDemo />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const page = within(canvasElement.ownerDocument.body);
    const text = canvas.getByRole("button", { name: "Agent reply text" });

    await userEvent.pointer({ keys: "[MouseRight>]", target: text });

    const items = await page.findAllByRole("menuitem");
    expect(items).toHaveLength(1);
    expect(items[0]).toHaveTextContent("Copy");

    await userEvent.keyboard("{Escape}");
    await waitFor(() => expect(page.queryByRole("menu")).not.toBeInTheDocument());
  },
};
