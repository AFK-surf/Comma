import "@comma/ui/styles.css";

import "./styles.css";

import {
  Button,
  Dropdown,
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  SelectionActionBar,
  SubmenuTrigger,
  TaskListItem,
  Tooltip,
  TrashCanIcon,
  type SelectionActionBarAnchor,
  type SelectionActionBarDirection,
} from "@comma/ui";
import { StrictMode, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";

/** Mirrors the chat surface: select text, act on it from a floating bar. */
function SelectionActionBarFixture() {
  const [anchor, setAnchor] = useState<SelectionActionBarAnchor | null>(null);
  const [direction, setDirection] = useState<SelectionActionBarDirection>("none");
  const [quoted, setQuoted] = useState("none");

  // Document-level, exactly as the app's own selection hook listens.
  useEffect(() => {
    const syncSelection = () => {
      const selection = window.getSelection();
      if (!selection || selection.isCollapsed || selection.rangeCount === 0) {
        setAnchor(null);
        return;
      }
      const rect = selection.getRangeAt(0).getBoundingClientRect();
      setAnchor({
        bottom: rect.bottom,
        left: rect.left,
        right: rect.right,
        top: rect.top,
      });
      const { anchorNode, anchorOffset, focusNode, focusOffset } = selection;
      if (!anchorNode || !focusNode) {
        setDirection("none");
      } else if (anchorNode === focusNode) {
        setDirection(anchorOffset < focusOffset ? "forward" : "backward");
      } else {
        const position = anchorNode.compareDocumentPosition(focusNode);
        setDirection(
          position & Node.DOCUMENT_POSITION_FOLLOWING ? "forward" : "backward"
        );
      }
    };

    document.addEventListener("pointerup", syncSelection);
    document.addEventListener("keyup", syncSelection);
    return () => {
      document.removeEventListener("pointerup", syncSelection);
      document.removeEventListener("keyup", syncSelection);
    };
  }, []);

  return (
    <section
      aria-label="Selection action bar fixture"
      className="mt-10 flex flex-col gap-6"
    >
      <p className="max-w-[420px]" data-testid="selection-source-top">
        A passage pinned to the very top of the page, so the bar has to flip below the
        selection instead of resting above it.
      </p>
      <p className="max-w-[420px]" data-testid="selection-source">
        圆橡皮，中间留出金属箍空隙。点 形状 → 铅笔 会得到一支完整的铅笔。
      </p>
      <div data-testid="selection-quoted">Quoted: {quoted}</div>
      {/* Room below, so the top passage can actually be scrolled to the very
          top of the viewport and the bar has to flip under it. */}
      <div aria-hidden className="h-[1200px]" />
      <SelectionActionBar
        actions={[
          {
            id: "add-to-chat",
            label: "Add to chat",
            onPress: () => {
              setQuoted(window.getSelection()?.toString() ?? "");
              window.getSelection()?.removeAllRanges();
              setAnchor(null);
            },
            shortcut: ["⌘", "L"],
          },
        ]}
        anchor={anchor}
        ariaLabel="Selection menu"
        direction={direction}
      />
    </section>
  );
}

const longDropdownItems = Array.from({ length: 20 }, (_, index) => ({
  id: `option-${index + 1}`,
  label: `Option ${index + 1}`,
}));

// A font menu's length: each option previews its own family.
const fontDropdownItems = Array.from({ length: 300 }, (_, index) => ({
  id: `family-${index + 1}`,
  label: `Family ${index + 1}`,
  fontFamily: index % 2 ? "serif" : "monospace",
}));

function MenuFixture() {
  const [lastAction, setLastAction] = useState("none");
  const [lastTaskAction, setLastTaskAction] = useState("none");
  const [isCustomActionPressed, setIsCustomActionPressed] = useState(false);

  return (
    <main className="min-h-screen bg-primary p-8 text-primary">
      <section
        aria-label="Tooltip interaction fixture"
        className="mx-auto flex max-w-[720px] items-center gap-6"
      >
        <div
          className="rounded-md border border-primary p-3"
          data-testid="tooltip-neutral-area"
        >
          Neutral pointer area
        </div>
        <Tooltip content="Primary tip" placement="bottom">
          <Button hierarchy="secondary-gray">Primary tooltip target</Button>
        </Tooltip>
      </section>
      <section className="mx-auto flex max-w-[480px] flex-col items-start gap-6">
        <h1 className="text-lg font-semibold">Menu E2E Fixture</h1>
        <MenuTrigger>
          <Button hierarchy="secondary-gray">Open task actions</Button>
          <MenuPopover>
            <Menu
              aria-label="Task actions"
              onAction={(key) => setLastAction(String(key))}
            >
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
        <MenuTrigger>
          <Button hierarchy="secondary-gray">Open connected filters</Button>
          <MenuPopover closeSubmenusOnPointerLeave isNonModal>
            <Menu aria-label="Connected filters">
              <SubmenuTrigger delay={0}>
                <MenuItem className="pointer-events-auto" id="status" shortcut="›">
                  Status
                </MenuItem>
                <MenuPopover animation="none" offset={0} placement="left top">
                  <Menu aria-label="Status options">
                    <MenuItem id="backlog">Backlog</MenuItem>
                  </Menu>
                </MenuPopover>
              </SubmenuTrigger>
              <SubmenuTrigger delay={0}>
                <MenuItem className="pointer-events-auto" id="worker" shortcut="›">
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
        <TaskListItem
          aria-label="Keyboard task row"
          contextMenu={{
            "aria-label": "Keyboard task actions",
            onAction: (key) => setLastTaskAction(String(key)),
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
        <output aria-live="polite" data-testid="last-action">
          Last action: {lastAction}
        </output>
        <output aria-live="polite" data-testid="last-task-action">
          Last task action: {lastTaskAction}
        </output>
      </section>
      <section
        aria-label="Button press feedback fixture"
        className="mt-10 flex gap-6"
        data-testid="button-feedback-fixture"
      >
        <button type="button">Global press feedback</button>
        <button
          className="existing-transform-feedback"
          data-no-press-feedback
          type="button"
        >
          Existing transform feedback
        </button>
        <button
          className="custom-action-feedback"
          data-action-pressed={isCustomActionPressed || undefined}
          data-no-press-feedback
          onPointerCancel={() => setIsCustomActionPressed(false)}
          onPointerDown={() => setIsCustomActionPressed(true)}
          onPointerLeave={() => setIsCustomActionPressed(false)}
          onPointerUp={() => setIsCustomActionPressed(false)}
          type="button"
        >
          Custom action feedback
        </button>
      </section>
      <SelectionActionBarFixture />
      <section
        aria-label="Long dropdown scroll fallback fixture"
        className="fixed right-xl bottom-7xl"
      >
        <Dropdown
          defaultValue="option-3"
          items={longDropdownItems}
          size="sm"
          width="content"
        />
      </section>
      <section
        aria-label="Virtualized dropdown fixture"
        className="fixed top-[50vh] left-xl w-64"
      >
        <Dropdown
          className="w-full"
          defaultValue="family-280"
          items={fontDropdownItems}
          size="sm"
          virtualized
        />
      </section>
    </main>
  );
}

createRoot(document.getElementById("root") as HTMLElement).render(
  <StrictMode>
    <MenuFixture />
  </StrictMode>
);
