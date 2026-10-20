import { screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { makeWorkspaceSignalModel } from "../src/WorkspaceSignalModel";
import { WorkspaceSignalSection } from "../src/WorkspaceSignalSection";
import { mountModel, ok, refuse, review, settle } from "./support";

describe("Workspace Signal number", () => {
  it("shows the refusal of an audited change and then saves the Workspace number", async () => {
    const platform = { e164: "+15550100001", state: "active" };
    const own = { e164: "+15550100002", state: "active" };
    const update = vi
      .fn()
      .mockReturnValueOnce(refuse(409, "signal_account_scope"))
      .mockReturnValue(ok({ override: own, platform, effective: own }));
    const view = mountModel(makeWorkspaceSignalModel("usr_one"), {
      api: {
        getUserWorkspaceSignalNumber: vi
          .fn()
          .mockReturnValue(ok({ override: null, platform, effective: platform })),
        updateUserWorkspaceSignalNumber: update,
      },
    });
    const user = userEvent.setup({ delay: null });

    view.render(<WorkspaceSignalSection model={view.model} />);
    await settle();

    expect(screen.getByText("Platform number")).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Change Signal number" }));
    await user.type(
      screen.getByRole("textbox", { name: /^Workspace Signal number/ }),
      own.e164
    );
    await user.click(screen.getByRole("button", { name: "Save Signal number" }));
    await settle();

    const dialog = screen.getByRole("dialog", {
      name: "Set the Workspace Signal number?",
    });
    expect(dialog).toHaveTextContent(`Platform number→${own.e164}`);
    const expected = `workspace-signal-number:usr_one:${own.e164}`;
    await review(user, "Set the Workspace Signal number?", "Customer number");
    expect(within(dialog).getByText("signal_account_scope")).toBeVisible();

    await user.click(within(dialog).getByRole("button", { name: /^Confirm$/ }));
    await settle();
    expect(screen.getByText(`Signal number set to ${own.e164}.`)).toBeVisible();
    expect(update).toHaveBeenCalledTimes(2);
    expect(update.mock.calls[1]).toEqual([
      "usr_one",
      expect.objectContaining({
        number: own.e164,
        confirmation: expected,
        reason: "Customer number",
      }),
    ]);
  });
});
