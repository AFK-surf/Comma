import { describe, expect, it, vi } from "vitest";
import userEvent from "@testing-library/user-event";
import { fireEvent, render, screen } from "@comma/test-utils/render";
import { Button } from "../../Button";
import { Dialog } from "../Dialog";
import { DialogPanel } from "../DialogPanel";

describe("Dialog", () => {
  it("opens from a trigger and renders the panel in a modal overlay", async () => {
    const user = userEvent.setup();

    render(
      <Dialog
        trigger={<Button hierarchy="primary">Open dialog</Button>}
        title="Blog post published"
        description="Team members can edit this post."
        actions={[{ label: "Confirm", hierarchy: "primary" }]}
      />
    );

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Open dialog" }));

    expect(screen.getByRole("dialog")).toHaveAccessibleName("Blog post published");
    expect(screen.getByRole("dialog")).toHaveAccessibleDescription(
      "Team members can edit this post."
    );
    expect(screen.getByText("Blog post published")).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Close dialog" })
    ).not.toBeInTheDocument();
    expect(document.querySelector(".bg-overlay-scrim")).toBeTruthy();
  });

  it("uses instance-safe title and description relationships", () => {
    render(
      <>
        <Dialog defaultOpen title="First dialog" description="First description." />
        <Dialog defaultOpen title="Second dialog" description="Second description." />
      </>
    );

    const dialogs = screen.getAllByRole("dialog", { hidden: true });
    const labelledBy = dialogs.map((dialog) => dialog.getAttribute("aria-labelledby"));
    const describedBy = dialogs.map((dialog) =>
      dialog.getAttribute("aria-describedby")
    );

    expect(new Set(labelledBy).size).toBe(2);
    expect(new Set(describedBy).size).toBe(2);
    expect(labelledBy.every(Boolean)).toBe(true);
    expect(describedBy.every(Boolean)).toBe(true);
  });

  it("keeps the standalone DialogPanel API instance-safe", () => {
    render(
      <>
        <DialogPanel title="First panel" description="First panel description." />
        <DialogPanel title="Second panel" description="Second panel description." />
      </>
    );

    const headings = screen.getAllByRole("heading");
    const descriptions = [
      screen.getByText("First panel description."),
      screen.getByText("Second panel description."),
    ];

    expect(new Set(headings.map((heading) => heading.id)).size).toBe(2);
    expect(new Set(descriptions.map((description) => description.id)).size).toBe(2);
    expect(headings.every((heading) => Boolean(heading.id))).toBe(true);
    expect(descriptions.every((description) => Boolean(description.id))).toBe(true);
  });

  it("reserves header padding only when the close button is opted into", () => {
    const { rerender } = render(
      <Dialog
        defaultOpen
        title='Delete "Draft task"?'
        description="This removes the task from the current collection."
      />
    );

    expect(
      screen.queryByRole("button", { name: "Close dialog" })
    ).not.toBeInTheDocument();
    expect(
      screen.getByRole("heading", { name: 'Delete "Draft task"?' }).parentElement
    ).not.toHaveClass("pr-4xl");

    rerender(
      <Dialog
        defaultOpen
        showCloseButton
        title='Delete "Draft task"?'
        description="This removes the task from the current collection."
      />
    );

    expect(screen.getByRole("button", { name: "Close dialog" })).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { name: 'Delete "Draft task"?' }).parentElement
    ).toHaveClass("pr-4xl");
  });

  it("closes from a trigger when the close button is pressed", async () => {
    const user = userEvent.setup();

    render(
      <Dialog
        trigger={<Button hierarchy="primary">Open dialog</Button>}
        showCloseButton
        title="Blog post published"
        description="Team members can edit this post."
        actions={[{ label: "Confirm", hierarchy: "primary" }]}
      />
    );

    await user.click(screen.getByRole("button", { name: "Open dialog" }));
    expect(screen.getByRole("dialog")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Close dialog" }));

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("closes from a trigger when a footer action has no onPress handler", async () => {
    const user = userEvent.setup();

    render(
      <Dialog
        trigger={<Button hierarchy="primary">Open dialog</Button>}
        title="Blog post published"
        description="Team members can edit this post."
        actions={[
          { label: "Cancel", hierarchy: "secondary-gray" },
          { label: "Confirm", hierarchy: "primary" },
        ]}
      />
    );

    await user.click(screen.getByRole("button", { name: "Open dialog" }));
    await user.click(screen.getByRole("button", { name: "Cancel" }));

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("closes when the close button is pressed", async () => {
    const user = userEvent.setup();
    const onOpenChange = vi.fn();

    render(
      <Dialog
        defaultOpen
        onOpenChange={onOpenChange}
        showCloseButton
        title="Rename project"
        description="Enter a new name."
      />
    );

    await user.click(screen.getByRole("button", { name: "Close dialog" }));

    expect(onOpenChange).toHaveBeenCalledWith(false);
  });

  it("badges Cancel with ESC and the primary action with the return keycap", () => {
    render(
      <Dialog
        defaultOpen
        title="Rename chat"
        description="Keep it short and recognizable"
        actions={[
          { label: "Cancel", hierarchy: "secondary-gray" },
          { label: "Save", hierarchy: "primary" },
        ]}
      />
    );

    const cancelKey = screen
      .getByRole("button", { name: "Cancel" })
      .querySelector('[data-slot="dialog-shortcut"]');
    const saveKey = screen
      .getByRole("button", { name: "Save" })
      .querySelector('[data-slot="dialog-shortcut"]');

    expect(cancelKey).toHaveTextContent("ESC");
    expect(cancelKey).toHaveClass("bg-quaternary");
    expect(saveKey?.querySelector("svg")).toHaveAttribute("data-comma-icon");
    expect(saveKey).toHaveClass("bg-dialog-shortcut-on-primary-bg");
  });

  it("runs the primary action on Enter and leaves opted-out footers alone", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn();

    const { rerender } = render(
      <Dialog
        defaultOpen
        title="Rename chat"
        actions={[
          { label: "Cancel", hierarchy: "secondary-gray" },
          { label: "Save", hierarchy: "primary", onPress: onSave },
        ]}
      />
    );

    screen.getByRole("dialog").focus();
    await user.keyboard("{Enter}");
    expect(onSave).toHaveBeenCalledTimes(1);

    rerender(
      <Dialog
        defaultOpen
        title="Rename chat"
        actions={[
          { label: "Cancel", hierarchy: "secondary-gray" },
          { label: "Save", hierarchy: "primary", onPress: onSave, shortcut: false },
        ]}
      />
    );

    expect(
      screen
        .getByRole("button", { name: "Save" })
        .querySelector('[data-slot="dialog-shortcut"]')
    ).toBeNull();

    screen.getByRole("dialog").focus();
    await user.keyboard("{Enter}");
    expect(onSave).toHaveBeenCalledTimes(1);
  });

  it("leaves Enter to the control that already owns it", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn();

    render(
      <Dialog
        defaultOpen
        title="Rename chat"
        actions={[
          { label: "Cancel", hierarchy: "secondary-gray" },
          { label: "Save", hierarchy: "primary", onPress: onSave },
        ]}
      />
    );

    screen.getByRole("button", { name: "Cancel" }).focus();
    await user.keyboard("{Enter}");

    expect(onSave).not.toHaveBeenCalled();
  });

  it("ignores composing Enter but retains ordinary Enter", () => {
    const onSave = vi.fn();

    render(
      <Dialog
        defaultOpen
        title="Rename chat"
        variant="input"
        input={{ "aria-label": "Chat name", autoFocus: true }}
        actions={[{ label: "Save", hierarchy: "primary", onPress: onSave }]}
      />
    );

    const input = screen.getByRole("textbox", { name: "Chat name" });
    fireEvent.keyDown(input, { key: "Enter", isComposing: true });
    fireEvent.keyDown(input, { key: "Enter", keyCode: 229 });

    expect(onSave).not.toHaveBeenCalled();

    fireEvent.keyDown(input, { key: "Enter" });

    expect(onSave).toHaveBeenCalledOnce();
  });

  it("honors a descendant React handler that prevents Enter", () => {
    const onSave = vi.fn();
    const onKeyDown = vi.fn((event: React.KeyboardEvent<HTMLInputElement>) => {
      event.preventDefault();
    });

    render(
      <Dialog
        defaultOpen
        title="Edit value"
        actions={[{ label: "Save", hierarchy: "primary", onPress: onSave }]}
      >
        <input aria-label="Owned input" onKeyDown={onKeyDown} />
      </Dialog>
    );

    fireEvent.keyDown(screen.getByRole("textbox", { name: "Owned input" }), {
      key: "Enter",
    });

    expect(onKeyDown).toHaveBeenCalledOnce();
    expect(onSave).not.toHaveBeenCalled();
  });

  it("leaves Enter inside content-editable controls", () => {
    const onSave = vi.fn();

    render(
      <Dialog
        defaultOpen
        title="Edit value"
        actions={[{ label: "Save", hierarchy: "primary", onPress: onSave }]}
      >
        <div aria-label="Rich editor" contentEditable suppressContentEditableWarning>
          Draft
        </div>
      </Dialog>
    );

    fireEvent.keyDown(screen.getByText("Draft"), { key: "Enter" });

    expect(onSave).not.toHaveBeenCalled();
  });

  it("supports controlled open state without a trigger", () => {
    const { rerender } = render(
      <Dialog
        isOpen={false}
        title="Hidden dialog"
        description="Should not render yet."
      />
    );

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();

    rerender(
      <Dialog
        isOpen
        title="Hidden dialog"
        description="Now visible."
        actions={[{ label: "Done", hierarchy: "primary" }]}
      />
    );

    expect(screen.getByRole("dialog")).toBeInTheDocument();
    expect(screen.getByText("Now visible.")).toBeInTheDocument();
  });
});
