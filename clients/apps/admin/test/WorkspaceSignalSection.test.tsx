import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { AdminApi } from "../src/adminApi";
import { WorkspaceSignalSection } from "../src/WorkspaceSignalSection";

describe("Workspace Signal number", () => {
  it("shows the refusal of an audited change and then saves the Workspace number", async () => {
    const platform = { e164: "+15550100001", state: "active" };
    const own = { e164: "+15550100002", state: "active" };
    const update = vi
      .fn()
      .mockRejectedValueOnce(new Error("signal_account_scope"))
      .mockResolvedValue({ override: own, platform, effective: own });
    const api = {
      getUserWorkspaceSignalNumber: vi
        .fn()
        .mockResolvedValue({ override: null, platform, effective: platform }),
      updateUserWorkspaceSignalNumber: update,
    } as unknown as AdminApi;
    const user = userEvent.setup();

    render(
      <WorkspaceSignalSection api={api} onAccessDenied={vi.fn()} userId="usr_one" />
    );

    expect(await screen.findByText("Not set", { selector: "dd" })).toBeVisible();
    await user.click(screen.getByRole("button", { name: "Change Signal number" }));
    await user.type(
      screen.getByRole("textbox", { name: /^Workspace Signal number/ }),
      own.e164
    );
    await user.type(
      screen.getByRole("textbox", { name: /^Reason/ }),
      "Customer number"
    );
    await user.click(
      screen.getByRole("button", { name: "Review Signal number change" })
    );

    const dialog = screen.getByRole("dialog", {
      name: "Set the Workspace Signal number?",
    });
    const expected = `workspace-signal-number:usr_one:${own.e164}`;
    await user.type(within(dialog).getByRole("textbox"), expected);
    await user.click(within(dialog).getByRole("button", { name: /^Confirm$/ }));
    expect(await within(dialog).findByText("signal_account_scope")).toBeVisible();

    await user.click(within(dialog).getByRole("button", { name: /^Confirm$/ }));
    expect(await screen.findByText(`Signal number set to ${own.e164}.`)).toBeVisible();
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
