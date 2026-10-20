import "@comma/ui/styles.css";

import { Button } from "@comma/ui/components/Button";
import { Dropdown } from "@comma/ui/components/dropdown";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  SubmenuTrigger,
} from "@comma/ui/components/menu";
import {
  SelectionActionBar,
  type SelectionActionBarAnchor,
  type SelectionActionBarDirection,
} from "@comma/ui/components/selection-action-bar";
import { TaskListItem } from "@comma/ui/components/TaskListItem";
import { Tooltip } from "@comma/ui/components/tooltip";
import { TrashCanIcon } from "@comma/ui/components/icons";
import "@comma/test-utils/browser-commands";
import { StrictMode, useEffect, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { commands, page, userEvent } from "vitest/browser";

// Pointer, keyboard, selection and motion behavior of the shared menu, tooltip,
// selection bar, dropdown and press-feedback components, in real Chromium.

const fixtureStyles = `
[data-testid="button-feedback-fixture"] button {
  width: 100px;
  height: 40px;
  transform-origin: center;
}
@layer components {
  [data-testid="button-feedback-fixture"] .existing-transform-feedback {
    transition: transform 120ms linear;
  }
  [data-testid="button-feedback-fixture"] .existing-transform-feedback:active {
    transform: scale(0.94);
  }
}
[data-testid="button-feedback-fixture"] .custom-action-feedback {
  scale: 1;
  transition: scale 120ms linear;
}
[data-testid="button-feedback-fixture"] .custom-action-feedback[data-action-pressed] {
  scale: 0.94;
}
`;

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
      {/* Room below, so the top passage can be scrolled to the very top. */}
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
        <MenuTrigger>
          <Button hierarchy="secondary-gray">Open task actions</Button>
          <MenuPopover>
            <Menu aria-label="Task actions">
              <MenuItem id="rename" shortcut="⌥⌘R">
                Rename task
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

let root: Root | undefined;

async function mountFixture() {
  root?.unmount();
  document.body.replaceChildren();
  window.scrollTo(0, 0);
  const style = document.createElement("style");
  style.textContent = fixtureStyles;
  document.head.append(style);
  const container = document.createElement("div");
  container.id = "root";
  document.body.append(container);
  root = createRoot(container);
  root.render(
    <StrictMode>
      <MenuFixture />
    </StrictMode>
  );
  await expect
    .element(page.getByRole("button", { name: "Primary tooltip target" }))
    .toBeVisible();
  await document.fonts.ready;
}

const query = <T extends Element = HTMLElement>(selector: string) =>
  document.querySelector<T>(selector);
const nextFrames = () =>
  new Promise<void>((resolve) =>
    requestAnimationFrame(() => requestAnimationFrame(() => resolve()))
  );
const rectOf = (element: Element) => element.getBoundingClientRect();
const transitionDurationsAreZero = (element: Element) =>
  getComputedStyle(element)
    .transitionDuration.split(",")
    .map((duration) => duration.trim())
    .every((duration) => duration === "0s" || duration === "0ms");

/** Jumps every finite running animation to its end instead of waiting for it. */
async function finishMotion() {
  await nextFrames();
  for (const animation of document.getAnimations()) {
    if (animation.effect?.getComputedTiming().iterations !== Infinity)
      animation.finish();
  }
}

/** Scrolls a fixture paragraph into view and selects it as a pointer sweep would. */
function selectFixtureText(
  testId: string,
  block: ScrollLogicalPosition,
  backward = false
) {
  const element = query(`[data-testid="${testId}"]`)!;
  element.scrollIntoView({ block });
  const range = document.createRange();
  range.selectNodeContents(element);
  const selection = window.getSelection()!;
  selection.removeAllRanges();
  if (backward) {
    selection.setBaseAndExtent(
      range.endContainer,
      range.endOffset,
      range.startContainer,
      range.startOffset
    );
  } else {
    selection.addRange(range);
  }
  element.dispatchEvent(new PointerEvent("pointerup", { bubbles: true }));
}

const barAttribute = (name: string) =>
  query('[data-slot="selection-action-bar"]')?.getAttribute(name);

function selectionBarGeometry(bar: HTMLElement) {
  const rect = window.getSelection()!.getRangeAt(0).getBoundingClientRect();
  const top = Number.parseFloat(bar.style.top);
  const left = Number.parseFloat(bar.style.left);
  return {
    topClearance: rect.top - (top + bar.offsetHeight),
    bottomClearance: top - rect.bottom,
    centered: Math.abs(left + bar.offsetWidth / 2 - (rect.left + rect.right) / 2) < 1,
  };
}

function dropdownScrollSnapshot(viewport: HTMLElement) {
  const viewportRect = rectOf(viewport);
  const firstVisibleOption = [
    ...viewport.querySelectorAll<HTMLElement>('[role="option"]'),
  ].find((option) => {
    const optionRect = rectOf(option);
    return optionRect.bottom > viewportRect.top && optionRect.top < viewportRect.bottom;
  });
  return {
    firstVisibleOption: firstVisibleOption?.textContent?.trim() ?? null,
    scrollTop: viewport.scrollTop,
  };
}

const inViewport = (element: Element, viewport: Element) => {
  const rect = rectOf(element);
  const bounds = rectOf(viewport);
  return rect.top >= bounds.top - 1 && rect.bottom <= bounds.bottom + 1;
};

const appState = () => ({
  appIsInert: query("#root")?.inert,
  documentOverflow: getComputedStyle(document.documentElement).overflow,
});

const optionFont = (option: Element) =>
  getComputedStyle(option.querySelector('[data-slot="dropdown-option-label"]')!)
    .fontFamily;
const itemClasses = (item: { element(): Element }) =>
  item.element().querySelector('[data-slot="menu-item-content"]')!.className;
const exitingPopovers = () =>
  document.querySelectorAll('[data-slot="menu-popover"][data-exiting]');

async function holdButton(name: string) {
  await userEvent.hover(page.getByRole("button", { name }));
  await commands.mouseDown();
  await nextFrames();
  for (const animation of document.getAnimations()) animation.finish();
  const element = page.getByRole("button", { name }).element();
  const style = getComputedStyle(element);
  return {
    scale: style.scale,
    transform: style.transform,
    transitionDuration: style.transitionDuration,
    transitionProperty: style.transitionProperty,
    width: rectOf(element).width,
  };
}

beforeEach(async () => {
  await page.viewport(1280, 720);
});

afterEach(async () => {
  await commands.mouseUp().catch(() => {});
  document.documentElement.style.removeProperty("--motion-duration-menu-exit");
  window.getSelection()?.removeAllRanges();
  root?.unmount();
  root = undefined;
  document.body.replaceChildren();
});

describe("menu, tooltip and selection components in the browser", () => {
  it("tooltip motion follows pointer and keyboard intent", async () => {
    await mountFixture();
    const target = page.getByRole("button", { name: "Primary tooltip target" });
    const neutral = page.getByTestId("tooltip-neutral-area");

    await userEvent.click(target);
    await userEvent.hover(neutral);
    await expect.element(page.getByRole("tooltip")).not.toBeInTheDocument();

    await userEvent.hover(target);
    const pointerTooltip = page.getByRole("tooltip", { name: "Primary tip" });
    await expect.element(pointerTooltip).toBeVisible();
    expect(pointerTooltip.element().getAttribute("data-instant")).toBeNull();
    expect(transitionDurationsAreZero(pointerTooltip.element())).toBe(false);

    await mountFixture();
    await userEvent.hover(page.getByTestId("tooltip-neutral-area"));
    await userEvent.keyboard("{Tab}");
    await expect
      .element(page.getByRole("button", { name: "Primary tooltip target" }))
      .toHaveFocus();
    const keyboardTooltip = page.getByRole("tooltip", { name: "Primary tip" });
    await expect.element(keyboardTooltip).toHaveAttribute("data-instant", "true");
    expect(transitionDurationsAreZero(keyboardTooltip.element())).toBe(true);
  });

  it("selection action bar rests above the selection and flips near the top edge", async () => {
    await mountFixture();
    selectFixtureText("selection-source", "center");

    await expect.poll(() => barAttribute("data-placement")).toBe("top");
    await expect.poll(() => barAttribute("data-visible")).toBe("true");
    const barElement = query('[data-slot="selection-action-bar"]')!;
    const keycaps = [...barElement.querySelectorAll("kbd")].map((node) => {
      const rect = rectOf(node);
      return { height: Math.round(rect.height), width: Math.round(rect.width) };
    });
    expect(
      [...barElement.querySelectorAll("kbd")].map((node) => node.textContent)
    ).toEqual(["⌘", "L"]);
    // A wide symbol and a narrow letter occupy the same square keycap.
    expect(keycaps[0]).toEqual(keycaps[1]);
    expect(keycaps[0]!.width).toBe(keycaps[0]!.height);
    // The label sits further from its keycaps than the keycaps from each other.
    const action = page.getByRole("button", { name: "Add to chat" }).element();
    expect(getComputedStyle(action).columnGap).toBe("4px");
    expect(
      getComputedStyle(query('[data-slot="selection-action-bar-keys"]')!).columnGap
    ).toBe("2px");
    await expect
      .poll(() => selectionBarGeometry(barElement))
      .toMatchObject({ topClearance: 8, centered: true });

    await userEvent.click(page.getByRole("button", { name: "Add to chat" }));
    await expect
      .element(page.getByTestId("selection-quoted"))
      .toHaveTextContent("圆橡皮");
    await expect
      .poll(
        () => query('[data-slot="selection-action-bar"]')?.checkVisibility() ?? false
      )
      .toBe(false);

    // A selection scrolled hard against the viewport top has no room above it.
    selectFixtureText("selection-source-top", "start");
    await expect.poll(() => barAttribute("data-placement")).toBe("bottom");
    await expect
      .poll(() => selectionBarGeometry(query('[data-slot="selection-action-bar"]')!))
      .toMatchObject({ bottomClearance: 8 });
  });

  it("selection action bar arrives along the direction the selection was drawn", async () => {
    await mountFixture();
    const travel = () =>
      Number.parseFloat(
        getComputedStyle(query('[data-slot="selection-action-bar"]')!).getPropertyValue(
          "--comma-selection-action-bar-travel"
        )
      );

    selectFixtureText("selection-source", "center");
    await expect.poll(() => barAttribute("data-direction")).toBe("forward");
    // A left-to-right sweep hands the bar in from the left.
    expect(travel()).toBe(-1);

    selectFixtureText("selection-source", "center", true);
    await expect.poll(() => barAttribute("data-direction")).toBe("backward");
    expect(travel()).toBe(1);

    // Both directions settle at the same resting transform.
    await expect.poll(() => barAttribute("data-visible")).toBe("true");
    await expect
      .poll(
        () => getComputedStyle(query('[data-slot="selection-action-bar"]')!).transform
      )
      .toBe("matrix(1, 0, 0, 1, 0, 0)");
  });

  it("long dropdown preserves wheel progress when edge hover falls back to scrolling", async () => {
    await page.viewport(900, 500);
    await mountFixture();
    const fixture = query('[aria-label="Long dropdown scroll fallback fixture"]')!;
    await userEvent.click(
      fixture.querySelector<HTMLElement>('[data-slot="dropdown-trigger"]')!
    );

    await expect.poll(() => query('[data-slot="dropdown-popover"]')).not.toBeNull();
    const popover = query('[data-slot="dropdown-popover"]')!;
    const viewport = popover.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    )!;
    const scrollDownFade = popover.querySelector('[data-slot="dropdown-scroll-down"]')!;
    expect(getComputedStyle(scrollDownFade).pointerEvents).toBe("none");
    await expect
      .poll(() => ({
        clientHeight: viewport.clientHeight,
        scrollHeight: viewport.scrollHeight,
      }))
      .toMatchObject({ clientHeight: 177, scrollHeight: 728 });

    await finishMotion();
    await userEvent.hover(viewport);
    await commands.mouseWheel(0, 200);
    await expect.poll(() => viewport.scrollTop).toBe(200);
    const beforeHover = dropdownScrollSnapshot(viewport);
    expect(beforeHover.firstVisibleOption).toBe("Option 6");

    const box = rectOf(popover);
    await userEvent.hover(popover, {
      position: { x: box.width / 2, y: box.height - 8 },
    });
    await expect.poll(() => popover.getAttribute("data-content-expanded")).toBe("true");
    expect(popover.getAttribute("data-scroll-fallback")).toBe("true");
    expect(popover.hasAttribute("data-content-fully-expanded")).toBe(false);
    await expect.poll(() => viewport.clientHeight).toBeGreaterThan(177);
    await expect.poll(() => dropdownScrollSnapshot(viewport)).toEqual(beforeHover);
  });

  it("long virtualized dropdown opens on its checked option and mounts only rows in view", async () => {
    await mountFixture();
    const fixture = query('[aria-label="Virtualized dropdown fixture"]')!;
    const trigger = fixture.querySelector<HTMLElement>(
      '[data-slot="dropdown-trigger"]'
    )!;
    const triggerTop = rectOf(trigger).top;
    await userEvent.click(trigger);

    const checked = page.getByRole("option", { name: "Family 280", exact: true });
    await expect.element(checked).toHaveFocus();
    // Clamped at the viewport top, the list scrolls to the checked option.
    await expect.poll(() => rectOf(checked.element()).top).toBeCloseTo(triggerTop, 0);
    const popover = query('[data-slot="dropdown-popover"]')!;
    expect(popover.querySelectorAll('[role="option"]').length).toBeLessThan(60);
    expect(optionFont(checked.element())).toBe("serif");

    // Rows mount as they scroll into view, with their own face.
    const viewport = popover.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    )!;
    viewport.scrollTop = 0;
    const first = page.getByRole("option", { name: "Family 1", exact: true });
    await expect.poll(() => inViewport(first.element(), viewport)).toBe(true);
    expect(optionFont(first.element())).toBe("monospace");

    // Keyboard focus travels to rows that were never mounted.
    (checked.element() as HTMLElement).focus();
    await userEvent.keyboard("{End}");
    const last = page.getByRole("option", { name: "Family 300", exact: true });
    await expect.element(last).toHaveFocus();
    expect(inViewport(last.element(), viewport)).toBe(true);
    await userEvent.keyboard("{Enter}");
    await expect.poll(() => trigger.textContent).toBe("Family 300");
  });

  it("connected submenus preserve one active path and close after group exit", async () => {
    await mountFixture();
    const activeBackground = /(?:^|\s)bg-quaternary(?:\s|$)/;
    const trigger = page.getByRole("button", { name: "Open connected filters" });
    const status = page.getByRole("menuitem", { name: "Status" });
    const worker = page.getByRole("menuitem", { name: "Worker" });
    const statusMenu = page.getByRole("dialog", { name: "Status" });
    const workerMenu = page.getByRole("dialog", { name: "Worker" });

    await userEvent.click(trigger);
    // Hover a settled menu: a pointer resting on an arriving row would ride it.
    await finishMotion();
    await userEvent.hover(status);
    await expect.element(statusMenu).toBeVisible();
    expect(itemClasses(status)).toMatch(activeBackground);

    await userEvent.hover(page.getByRole("menuitem", { name: "Backlog" }));
    await expect.element(status).toHaveAttribute("aria-expanded", "true");
    expect(itemClasses(status)).toMatch(activeBackground);
    // The submenu docks flush against its trigger row.
    expect(
      Math.abs(rectOf(statusMenu.element()).right - rectOf(status.element()).left)
    ).toBeLessThanOrEqual(1);

    await userEvent.hover(worker);
    await expect.element(statusMenu).not.toBeInTheDocument();
    await expect.element(workerMenu).toBeVisible();
    await expect.element(status).toHaveAttribute("aria-expanded", "false");
    await expect.element(worker).toHaveAttribute("aria-expanded", "true");
    expect(itemClasses(status)).not.toMatch(activeBackground);
    expect(itemClasses(worker)).toMatch(activeBackground);

    const codex = page.getByRole("menuitem", { name: "Codex" });
    await userEvent.hover(codex);
    await expect.element(codex).toHaveFocus();

    await userEvent.hover(query("main")!, { position: { x: 10, y: 10 } });
    await expect.element(workerMenu).not.toBeInTheDocument();
    await expect.element(worker).toHaveAttribute("aria-expanded", "false");
    expect(itemClasses(worker)).not.toMatch(activeBackground);
    await expect
      .element(page.getByRole("menu", { name: "Open connected filters" }))
      .toBeVisible();
    await expect.element(worker).toHaveFocus();

    await userEvent.keyboard("{ArrowDown}");
    await expect.element(status).toHaveFocus();
    await userEvent.keyboard("{Escape}");
    await expect
      .element(page.getByRole("menu", { name: "Open connected filters" }))
      .not.toBeInTheDocument();
    await expect.element(trigger).toHaveFocus();
  });

  it("task list pointer context menu exits in place without locking the app", async () => {
    await mountFixture();
    const row = page.getByLabelText("Keyboard task row");
    const menu = page.getByRole("menu", { name: "Keyboard task actions" });

    document.documentElement.style.setProperty("--motion-duration-menu-exit", "1000ms");
    await userEvent.click(row, { button: "right" });
    await expect.element(menu).toBeVisible();
    const popover = menu.element().closest<HTMLElement>('[data-slot="menu-popover"]')!;
    expect(popover.getAttribute("data-animation")).toBe("anchor");
    await expect
      .poll(appState)
      .toEqual({ appIsInert: false, documentOverflow: "visible" });
    await finishMotion();
    const open = rectOf(popover);

    await userEvent.click(page.getByRole("menuitem", { name: "Rename keyboard task" }));
    await expect.poll(() => exitingPopovers().length).toBe(1);
    const leaving = rectOf(exitingPopovers()[0]!);
    expect(Math.abs(leaving.x - open.x)).toBeLessThan(1);
    expect(Math.abs(leaving.y - open.y)).toBeLessThan(1);
    await finishMotion();
    await expect.poll(() => exitingPopovers().length).toBe(0);
    await expect
      .element(page.getByTestId("last-task-action"))
      .toHaveTextContent("Last task action: rename-task");

    document.documentElement.style.removeProperty("--motion-duration-menu-exit");
    await userEvent.click(row, { button: "right" });
    await expect.element(menu).toBeVisible();
    await userEvent.keyboard("{Escape}");
    await expect.element(menu).not.toBeInTheDocument();
    await expect
      .poll(appState)
      .toEqual({ appIsInert: false, documentOverflow: "visible" });
  });

  it("a context menu opened again during its exit takes focus and closes on Escape", async () => {
    await mountFixture();
    const row = page.getByLabelText("Keyboard task row");
    const rename = page.getByRole("menuitem", { name: "Rename keyboard task" });

    // Hold the exit open so the second right click lands inside it.
    document.documentElement.style.setProperty("--motion-duration-menu-exit", "1000ms");
    await userEvent.click(row, { button: "right" });
    await expect.element(rename).toHaveFocus();
    await userEvent.keyboard("{Escape}");
    await expect.poll(() => exitingPopovers().length).toBe(1);

    await userEvent.click(row, { button: "right" });
    await expect.poll(() => exitingPopovers().length).toBe(0);
    await expect
      .element(page.getByRole("menu", { name: "Keyboard task actions" }))
      .toBeVisible();
    await expect.element(rename).toHaveFocus();
    await userEvent.keyboard("{Escape}");
    await finishMotion();
    await expect
      .element(page.getByRole("menu", { name: "Keyboard task actions" }))
      .not.toBeInTheDocument();
  });

  it("opted-out transform feedback is not compounded by the global press scale", async () => {
    await mountFixture();
    const pressed = await holdButton("Existing transform feedback");
    expect(pressed.scale).toBe("none");
    expect(pressed.transform).toBe("matrix(0.94, 0, 0, 0.94, 0, 0)");
    expect(pressed.width).toBeCloseTo(94, 1);
  });

  it("buttons without custom feedback retain the shared press scale", async () => {
    await mountFixture();
    const pressed = await holdButton("Global press feedback");
    expect(pressed.scale).toBe("0.98");
    expect(pressed.transform).toBe("none");
    expect(pressed.width).toBeCloseTo(98, 1);
  });

  it("reduced motion disables later transitions and custom action scaling", async () => {
    await commands.emulateMedia({ reducedMotion: "reduce" });
    try {
      await mountFixture();
      const transform = page
        .getByRole("button", { name: "Existing transform feedback" })
        .element();
      expect({
        duration: getComputedStyle(transform).transitionDuration,
        property: getComputedStyle(transform).transitionProperty,
      }).toEqual({ duration: "0s", property: "none" });

      const pressed = await holdButton("Custom action feedback");
      expect(pressed.scale).toBe("1");
      expect(pressed.transform).toBe("none");
      expect(pressed.transitionDuration).toBe("0s");
      expect(pressed.transitionProperty).toBe("none");
      expect(pressed.width).toBeCloseTo(100, 1);
    } finally {
      await commands.emulateMedia({ reducedMotion: "no-preference" });
    }
  });
});
