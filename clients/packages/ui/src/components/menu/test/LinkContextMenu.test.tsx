import { render, screen, waitFor } from "@comma/test-utils/render";
import { fireEvent } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { useRef } from "react";
import { describe, expect, it, vi } from "vitest";
import { HoverCard } from "../../hover-card";
import { LinkContextMenu } from "../LinkContextMenu";
import { useTextEditContextMenuState } from "../useTextEditContextMenuState";

const LinkMenuHost = ({
  hasMessage = true,
  onAction,
}: {
  hasMessage?: boolean;
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
        Link
      </button>
      <button type="button">Outside</button>
      <LinkContextMenu
        isOpen={isOpen}
        labels={{
          ariaLabel: "Link menu",
          copyLink: "Copy Link",
          openInComma: "Open in Comma",
          openInExternalBrowser: "Open in External Browser",
          ...(hasMessage ? { copyMessage: "Copy message" } : {}),
        }}
        onAction={onAction}
        onOpenChange={handleOpenChange}
        pointerOffsets={pointerOffsets}
        triggerRef={triggerRef}
      />
    </>
  );
};

describe("LinkContextMenu", () => {
  it("renders external, Comma, copy-link, and copy-message actions with a separator", async () => {
    const user = userEvent.setup();
    const onAction = vi.fn();
    render(<LinkMenuHost onAction={onAction} />);

    await user.pointer({
      keys: "[MouseRight>]",
      target: screen.getByRole("button", { name: "Link" }),
    });

    expect(
      screen.getByRole("menuitem", { name: "Open in External Browser" })
    ).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Open in Comma" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Copy Link" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Copy message" })).toBeInTheDocument();
    expect(screen.getByRole("separator")).toBeInTheDocument();
    expect(
      screen.getByRole("menu").closest('[data-slot="menu-popover"]')
    ).toHaveAttribute("data-animation", "anchor");

    await user.click(screen.getByRole("menuitem", { name: "Copy Link" }));
    expect(onAction).toHaveBeenCalledWith("copy-link");
  });

  it("disables Open in Comma when the Comma browser opener is unavailable", async () => {
    const user = userEvent.setup();
    const onAction = vi.fn();
    const triggerRef = { current: null as HTMLButtonElement | null };
    const Host = () => {
      const { isOpen, pointerOffsets, handleOpenChange, openAtPointer } =
        useTextEditContextMenuState({ isEnabled: true });
      return (
        <>
          <button
            onContextMenu={(event) => {
              event.preventDefault();
              openAtPointer(event.currentTarget, event.clientX, event.clientY);
            }}
            ref={(node) => {
              triggerRef.current = node;
            }}
            type="button"
          >
            Link
          </button>
          <LinkContextMenu
            disabledActions={{ openInComma: true }}
            isOpen={isOpen}
            labels={{
              ariaLabel: "Link menu",
              copyLink: "Copy Link",
              copyMessage: "Copy message",
              openInComma: "Open in Comma",
              openInExternalBrowser: "Open in External Browser",
            }}
            onAction={onAction}
            onOpenChange={handleOpenChange}
            pointerOffsets={pointerOffsets}
            triggerRef={triggerRef}
          />
        </>
      );
    };
    render(<Host />);

    await user.pointer({
      keys: "[MouseRight>]",
      target: screen.getByRole("button", { name: "Link" }),
    });

    expect(screen.getByRole("menuitem", { name: "Open in Comma" })).toHaveAttribute(
      "aria-disabled",
      "true"
    );
  });

  it("leaves out copy-message on a surface that has no message behind the link", async () => {
    const user = userEvent.setup();
    render(<LinkMenuHost hasMessage={false} onAction={vi.fn()} />);

    await user.pointer({
      keys: "[MouseRight>]",
      target: screen.getByRole("button", { name: "Link" }),
    });

    // Left out entirely rather than shown permanently disabled.
    expect(screen.getAllByRole("menuitem").map((item) => item.textContent)).toEqual([
      "Open in External Browser",
      "Open in Comma",
      "Copy Link",
    ]);
    expect(screen.getByRole("separator")).toBeInTheDocument();
  });

  it("lets an outside primary interaction keep its native target", async () => {
    const user = userEvent.setup();
    render(<LinkMenuHost onAction={vi.fn()} />);

    await user.pointer({
      keys: "[MouseRight>]",
      target: screen.getByRole("button", { name: "Link" }),
    });
    expect(await screen.findByRole("menu", { name: "Link menu" })).toBeInTheDocument();

    const outside = screen.getByRole("button", { name: "Outside" });
    const underlyingClick = vi.fn();
    outside.addEventListener("click", underlyingClick);
    await user.click(outside);

    expect(underlyingClick).toHaveBeenCalledOnce();
    await waitFor(() => expect(screen.queryByRole("menu")).not.toBeInTheDocument());
  });

  it("keeps new hover cards closed until the context menu closes", async () => {
    setInteractionModality("pointer");
    const user = userEvent.setup();
    render(
      <>
        <HoverCard content={<span>Preview</span>} delay={0}>
          <button type="button">Hovered</button>
        </HoverCard>
        <LinkMenuHost onAction={vi.fn()} />
      </>
    );

    await user.pointer({
      keys: "[MouseRight>]",
      target: screen.getByRole("button", { name: "Link" }),
    });
    expect(await screen.findByRole("menu", { name: "Link menu" })).toBeInTheDocument();

    await user.hover(screen.getByRole("button", { name: "Hovered" }));
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
    expect(screen.getByRole("menu", { name: "Link menu" })).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Outside" }));
    await user.hover(screen.getByRole("button", { name: "Hovered" }));
    expect(await screen.findByRole("tooltip")).toBeInTheDocument();
  });

  it("closes an open hover card when the menu opens over it", async () => {
    setInteractionModality("pointer");
    const user = userEvent.setup();
    const onAction = vi.fn();
    render(
      <>
        <HoverCard content={<span>Preview</span>} delay={0}>
          <button type="button">Hovered</button>
        </HoverCard>
        <LinkMenuHost onAction={onAction} />
      </>
    );

    await user.hover(screen.getByRole("button", { name: "Hovered" }));
    expect(await screen.findByRole("tooltip")).toBeInTheDocument();

    await user.pointer({
      keys: "[MouseRight>]",
      target: screen.getByRole("button", { name: "Link" }),
    });
    expect(await screen.findByRole("menu", { name: "Link menu" })).toBeInTheDocument();
    await waitFor(() => expect(screen.queryByRole("tooltip")).not.toBeInTheDocument());
  });

  it("dismisses the link menu after an outside pointer interaction", async () => {
    const user = userEvent.setup();
    render(<LinkMenuHost onAction={vi.fn()} />);

    await user.pointer({
      keys: "[MouseRight>]",
      target: screen.getByRole("button", { name: "Link" }),
    });
    expect(await screen.findByRole("menu", { name: "Link menu" })).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Outside" }));
    await waitFor(() => expect(screen.queryByRole("menu")).not.toBeInTheDocument());
  });

  it("closes on a right click outside every menu popover, but not on one inside", async () => {
    const user = userEvent.setup();
    render(<LinkMenuHost onAction={vi.fn()} />);

    await user.pointer({
      keys: "[MouseRight>]",
      target: screen.getByRole("button", { name: "Link" }),
    });
    expect(await screen.findByRole("menu", { name: "Link menu" })).toBeInTheDocument();

    // React Aria's interact-outside ignores non-primary presses, so this path
    // is the document-level contextmenu dismissal. A right click on the menu
    // itself is not an outside gesture and keeps it open…
    fireEvent.contextMenu(screen.getByRole("menuitem", { name: "Copy Link" }));
    expect(screen.getByRole("menu", { name: "Link menu" })).toBeInTheDocument();

    // …while one anywhere else closes it, and the untouched event travels on
    // so its target can open its own menu in the same gesture.
    fireEvent.contextMenu(screen.getByRole("button", { name: "Outside" }));
    await waitFor(() => expect(screen.queryByRole("menu")).not.toBeInTheDocument());
  });

  it("retargets to another trigger in one right-click gesture", async () => {
    const user = userEvent.setup();
    render(<LinkMenuHost onAction={vi.fn()} />);

    await user.pointer({
      keys: "[MouseRight>]",
      target: screen.getByRole("button", { name: "Link" }),
    });
    expect(await screen.findByRole("menu", { name: "Link menu" })).toBeInTheDocument();

    // The second right click closes the open menu via the document capture
    // listener and then reaches the trigger's own handler, which reopens the
    // menu at the new position — one gesture, no dead click.
    await user.pointer({
      keys: "[MouseRight>]",
      target: screen.getByRole("button", { name: "Link" }),
    });
    expect(await screen.findByRole("menu", { name: "Link menu" })).toBeInTheDocument();
  });
});
