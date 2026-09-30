import { render, screen, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { AdminConfirmationDialog, AdminDrawer } from "../src/adminUi";

describe("AdminConfirmationDialog", () => {
  it("cannot be dismissed while an audited command is in flight", async () => {
    const command = Promise.withResolvers<void>();
    const onOpenChange = vi.fn();
    const user = userEvent.setup();

    render(
      <AdminConfirmationDialog
        expected="confirm:target"
        isOpen
        onConfirm={() => command.promise}
        onOpenChange={onOpenChange}
        title="Run command?"
      />
    );

    await user.type(
      screen.getByRole("textbox", { name: /Confirmation value/ }),
      "confirm:target"
    );
    await user.click(screen.getByRole("button", { name: "Confirm" }));

    expect(await screen.findByRole("button", { name: "Working…" })).toBeVisible();
    expect(screen.queryByRole("button", { name: "Cancel" })).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Close dialog" })
    ).not.toBeInTheDocument();
    onOpenChange.mockClear();
    await user.keyboard("{Escape}");
    expect(onOpenChange).not.toHaveBeenCalled();

    command.resolve();
    await waitFor(() => expect(onOpenChange).toHaveBeenCalledWith(false));
  });

  it("guards the containing drawer while a one-time command is in flight", async () => {
    const onClose = vi.fn();
    const user = userEvent.setup();

    render(
      <AdminDrawer
        eyebrow="Secret command"
        isDismissable={false}
        onClose={onClose}
        title="Create secret"
      >
        <p>Working…</p>
      </AdminDrawer>
    );

    expect(screen.queryByRole("button", { name: "Close" })).not.toBeInTheDocument();
    await user.keyboard("{Escape}");
    await user.click(screen.getByRole("button", { name: "Close details" }));
    expect(onClose).not.toHaveBeenCalled();
  });
});
