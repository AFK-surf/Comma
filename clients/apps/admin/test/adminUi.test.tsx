import { act, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { Effect } from "effect";
import { describe, expect, it, vi } from "vitest";
import { AdminApiError } from "../src/adminApi";
import {
  confirmationBusy,
  makeConfirmation,
  type Confirmation,
  type ConfirmationRequest,
} from "../src/adminModel";
import { useAdminState } from "../src/adminRuntime";
import { AdminConfirmationDialog, AdminDrawer } from "../src/adminUi";
import { mountModel, pending, settle } from "./support";

/** Each try of the command waits on the next reply; a failed reply shows "The command failed.". */
function command(tries = 1) {
  const replies = Array.from({ length: tries }, () => pending<void>());
  const queue = [...replies];
  const run = vi.fn<ConfirmationRequest["run"]>(() =>
    queue.shift()!.effect.pipe(Effect.mapError(() => "The command failed."))
  );
  return { replies, run };
}

function mountConfirmation(
  run: ConfirmationRequest["run"],
  request: Partial<ConfirmationRequest> = { typed: "target" }
) {
  const view = mountModel(makeConfirmation);
  view.runtime.runSync(
    view.model.open({
      keyPrefix: "test-command",
      run,
      title: "Run command?",
      ...request,
    })
  );
  return view;
}

describe("AdminConfirmationDialog", () => {
  it("cannot be dismissed while an audited command is in flight", async () => {
    const {
      replies: [first, second],
      run,
    } = command(2);
    const view = mountConfirmation(run);
    view.render(<AdminConfirmationDialog confirmation={view.model} />);
    const user = userEvent.setup({ delay: null });

    await user.type(screen.getByRole("textbox", { name: "Reason" }), "Rotate it");
    await user.type(
      screen.getByRole("textbox", { name: "Type “target” to confirm" }),
      "target"
    );
    await user.click(screen.getByRole("button", { name: "Confirm" }));
    await settle();

    expect(screen.getByRole("button", { name: "Working…" })).toBeVisible();
    expect(screen.queryByRole("button", { name: "Cancel" })).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Close dialog" })
    ).not.toBeInTheDocument();
    await user.keyboard("{Escape}");
    await settle();
    expect(screen.getByRole("dialog", { name: "Run command?" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Working…" })).toBeVisible();

    // A failed try keeps the dialog open with the message; the retry reuses the key.
    act(() =>
      first!.fail(new AdminApiError({ code: "internal", message: "boom", status: 500 }))
    );
    await settle();
    expect(screen.getByText("The command failed.")).toBeVisible();
    expect(screen.getByRole("button", { name: "Confirm" })).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Confirm" }));
    await settle();
    expect(run).toHaveBeenCalledTimes(2);
    expect(run.mock.calls[1]?.[0]).toBe(run.mock.calls[0]?.[0]);
    expect(run.mock.calls[1]?.[1]).toBe("Rotate it");

    act(() => second!.succeed());
    await settle();
    expect(
      screen.queryByRole("dialog", { name: "Run command?" })
    ).not.toBeInTheDocument();
  });

  it("guards the containing drawer while a one-time command is in flight", async () => {
    const onClose = vi.fn();
    const {
      replies: [reply],
      run,
    } = command();
    const view = mountConfirmation(run);
    view.render(<GuardedDrawer confirmation={view.model} onClose={onClose} />);
    act(() => {
      view.runtime.runSync(view.model.setReason("Issue a token"));
      view.runtime.runSync(view.model.setValue("target"));
      view.runtime.runFork(view.model.confirm);
    });
    await settle();
    const user = userEvent.setup({ delay: null });

    expect(screen.queryByRole("button", { name: "Close" })).not.toBeInTheDocument();
    await user.keyboard("{Escape}");
    await user.click(screen.getByRole("button", { name: "Close details" }));
    expect(onClose).not.toHaveBeenCalled();

    act(() => reply!.succeed());
    await settle();
    expect(screen.getByRole("button", { name: "Close" })).toBeVisible();
  });

  it("asks a routine command only for its reason, and shows what it changes", async () => {
    const {
      replies: [reply],
      run,
    } = command();
    const view = mountConfirmation(run, {
      changes: [{ label: "Cloud VM", before: "Enabled", after: "Disabled" }],
    });
    view.render(<AdminConfirmationDialog confirmation={view.model} />);
    const user = userEvent.setup({ delay: null });

    expect(screen.getByRole("definition")).toHaveTextContent("Enabled→Disabled");
    expect(
      screen.queryByRole("textbox", { name: /to confirm/ })
    ).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Confirm" }));
    await settle();
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Enter a reason of at least 3 characters."
    );
    expect(run).not.toHaveBeenCalled();

    await user.type(screen.getByRole("textbox", { name: "Reason" }), "  User asked  ");
    await user.click(screen.getByRole("button", { name: "Confirm" }));
    await settle();
    expect(run).toHaveBeenCalledWith(expect.any(String), "User asked");
    act(() => reply!.succeed());
    await settle();
    expect(
      screen.queryByRole("dialog", { name: "Run command?" })
    ).not.toBeInTheDocument();
  });

  it("runs a guarded command only when the typed name matches", async () => {
    const { run } = command();
    const view = mountConfirmation(run);
    view.render(<AdminConfirmationDialog confirmation={view.model} />);
    const user = userEvent.setup({ delay: null });

    await user.type(screen.getByRole("textbox", { name: "Reason" }), "Rotate it");
    await user.type(
      screen.getByRole("textbox", { name: "Type “target” to confirm" }),
      "targ"
    );
    await user.click(screen.getByRole("button", { name: "Confirm" }));
    await settle();
    expect(screen.getByRole("alert")).toHaveTextContent(
      "The confirmation does not match this target."
    );
    expect(run).not.toHaveBeenCalled();
  });
});

function GuardedDrawer({
  confirmation,
  onClose,
}: {
  confirmation: Confirmation;
  onClose: () => void;
}) {
  const busy = confirmationBusy(useAdminState(confirmation.state));
  return (
    <AdminDrawer
      eyebrow="Secret command"
      isDismissable={!busy}
      onClose={onClose}
      title="Create secret"
    >
      <p>Working…</p>
    </AdminDrawer>
  );
}
