import { fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { useRef } from "react";
import { describe, expect, it, vi } from "vitest";
import { HoverCard } from "../../hover-card";
import { CopyContextMenu } from "../CopyContextMenu";
import { CONTEXT_SELECTION_HIGHLIGHT } from "../preserveTextSelection";
import { useTextEditContextMenuState } from "../useTextEditContextMenuState";

const FakeHighlight = class extends Set<AbstractRange> {
  constructor(...ranges: Range[]) {
    super(ranges);
  }
};

const CopyMenuHost = ({
  disabled,
  onAction,
}: {
  disabled?: boolean;
  onAction: (action: string) => void;
}) => {
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const { isOpen, pointerOffsets, handleOpenChange, openAtPointer } =
    useTextEditContextMenuState({ isEnabled: true });

  return (
    <>
      <button
        onContextMenu={(event) => {
          event.preventDefault();
          openAtPointer(event.currentTarget, event.clientX, event.clientY);
        }}
        ref={triggerRef}
        type="button"
      >
        Text
      </button>
      <button type="button">Outside</button>
      <CopyContextMenu
        {...(disabled ? { disabledActions: { copy: true } } : {})}
        isOpen={isOpen}
        labels={{
          ariaLabel: "Text menu",
          copy: "Copy",
        }}
        onAction={onAction}
        onOpenChange={handleOpenChange}
        pointerOffsets={pointerOffsets}
        triggerRef={triggerRef}
      />
    </>
  );
};

const SelectableCopyMenuHost = () => {
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const { isOpen, pointerOffsets, handleOpenChange, openAtPointer } =
    useTextEditContextMenuState({
      isEnabled: true,
      preserveTextSelection: true,
    });

  return (
    <>
      <p>Agent reply text</p>
      <button
        onContextMenu={(event) => {
          event.preventDefault();
          openAtPointer(event.currentTarget, event.clientX, event.clientY);
        }}
        ref={triggerRef}
        type="button"
      >
        Open menu
      </button>
      <CopyContextMenu
        isOpen={isOpen}
        labels={{
          ariaLabel: "Text menu",
          copy: "Copy",
        }}
        onAction={vi.fn()}
        onOpenChange={handleOpenChange}
        pointerOffsets={pointerOffsets}
        triggerRef={triggerRef}
      />
    </>
  );
};

const PointerOffsetStateHost = () => {
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const { handleOpenChange, openAtPointer, pointerOffsets } =
    useTextEditContextMenuState({ isEnabled: true });

  return (
    <>
      <button
        onClick={() => {
          if (triggerRef.current) openAtPointer(triggerRef.current, 120, 80);
        }}
        ref={triggerRef}
        type="button"
      >
        Open offset state
      </button>
      <button onClick={() => handleOpenChange(false)} type="button">
        Close offset state
      </button>
      <output aria-label="Pointer offsets">{JSON.stringify(pointerOffsets)}</output>
    </>
  );
};

describe("CopyContextMenu", () => {
  it("retains pointer offsets while a context menu closes", async () => {
    const user = userEvent.setup();
    render(<PointerOffsetStateHost />);

    await user.click(screen.getByRole("button", { name: "Open offset state" }));
    const pointerOffsets = screen.getByRole("status", { name: "Pointer offsets" });
    expect(pointerOffsets).not.toHaveTextContent("null");
    const openOffsets = pointerOffsets.textContent;

    await user.click(screen.getByRole("button", { name: "Close offset state" }));
    expect(pointerOffsets).toHaveTextContent(openOffsets ?? "");
  });

  it("renders a single Copy action", async () => {
    const user = userEvent.setup();
    const onAction = vi.fn();
    render(<CopyMenuHost onAction={onAction} />);

    await user.pointer({
      keys: "[MouseRight>]",
      target: screen.getByRole("button", { name: "Text" }),
    });

    const items = screen.getAllByRole("menuitem");
    expect(items).toHaveLength(1);
    expect(items[0]).toHaveTextContent("Copy");

    await user.click(items[0]!);
    expect(onAction).toHaveBeenCalledWith("copy");
  });

  it("disables Copy when the action is unavailable", async () => {
    const user = userEvent.setup();
    render(<CopyMenuHost disabled onAction={vi.fn()} />);

    await user.pointer({
      keys: "[MouseRight>]",
      target: screen.getByRole("button", { name: "Text" }),
    });

    expect(screen.getByRole("menuitem", { name: "Copy" })).toHaveAttribute(
      "aria-disabled",
      "true"
    );
  });

  it("paints the text selection after the menu receives focus", async () => {
    const highlights = new Map<string, Highlight>();
    Object.defineProperty(window, "Highlight", {
      configurable: true,
      value: FakeHighlight,
    });
    Object.defineProperty(CSS, "highlights", {
      configurable: true,
      value: highlights,
    });
    render(<SelectableCopyMenuHost />);

    const paragraph = screen.getByText("Agent reply text");
    const textNode = paragraph.firstChild;
    if (!textNode) throw new Error("expected a text node");
    const range = document.createRange();
    range.setStart(textNode, 0);
    range.setEnd(textNode, 5);
    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);

    const trigger = screen.getByRole("button", { name: "Open menu" });
    fireEvent.pointerDown(trigger, {
      button: 2,
      isPrimary: true,
      pointerId: 1,
      pointerType: "mouse",
    });
    fireEvent.contextMenu(trigger, {
      clientX: 120,
      clientY: 80,
    });
    expect(await screen.findByRole("menu", { name: "Text menu" })).toBeInTheDocument();
    expect(
      screen.getByRole("menu").closest('[data-slot="menu-popover"]')
    ).toHaveAttribute("data-animation", "anchor");
    await waitFor(() => expect(highlights.has(CONTEXT_SELECTION_HIGHLIGHT)).toBe(true));
  });

  it("lets an outside primary interaction keep its native target", async () => {
    const user = userEvent.setup();
    render(<CopyMenuHost onAction={vi.fn()} />);

    await user.pointer({
      keys: "[MouseRight>]",
      target: screen.getByRole("button", { name: "Text" }),
    });
    expect(await screen.findByRole("menu", { name: "Text menu" })).toBeInTheDocument();

    const outside = screen.getByRole("button", { name: "Outside" });
    const underlyingClick = vi.fn();
    outside.addEventListener("click", underlyingClick);
    await user.click(outside);

    expect(underlyingClick).toHaveBeenCalledOnce();
    await waitFor(() => expect(screen.queryByRole("menu")).not.toBeInTheDocument());
  });

  it("closes an open hover card when the menu opens over it", async () => {
    setInteractionModality("pointer");
    const user = userEvent.setup();
    render(
      <>
        <HoverCard content={<span>Preview</span>} delay={0}>
          <button type="button">Hovered</button>
        </HoverCard>
        <CopyMenuHost onAction={vi.fn()} />
      </>
    );

    await user.hover(screen.getByRole("button", { name: "Hovered" }));
    expect(await screen.findByRole("tooltip")).toBeInTheDocument();

    await user.pointer({
      keys: "[MouseRight>]",
      target: screen.getByRole("button", { name: "Text" }),
    });
    expect(await screen.findByRole("menu", { name: "Text menu" })).toBeInTheDocument();
    await waitFor(() => expect(screen.queryByRole("tooltip")).not.toBeInTheDocument());
  });

  it("dismisses a context menu after an outside pointer interaction", async () => {
    const user = userEvent.setup();
    render(<CopyMenuHost onAction={vi.fn()} />);

    await user.pointer({
      keys: "[MouseRight>]",
      target: screen.getByRole("button", { name: "Text" }),
    });
    expect(await screen.findByRole("menu", { name: "Text menu" })).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Outside" }));
    await waitFor(() => expect(screen.queryByRole("menu")).not.toBeInTheDocument());
  });
});
