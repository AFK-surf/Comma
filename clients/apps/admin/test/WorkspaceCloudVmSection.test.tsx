import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { AdminApi } from "../src/adminApi";
import { WorkspaceCloudVmSection } from "../src/WorkspaceCloudVmSection";

describe("Workspace Cloud VM", () => {
  it("preserves the saved setting on failure and retries the exact audited command", async () => {
    const update = vi
      .fn()
      .mockRejectedValueOnce(new Error("Provider unavailable"))
      .mockResolvedValue({
        workspace_id: "wsp_one",
        enabled: true,
        convergence_status: "pending",
      });
    const user = userEvent.setup();
    render(
      <WorkspaceCloudVmSection
        api={{ updateUserWorkspaceVm: update } as unknown as AdminApi}
        current={{
          workspace_id: "wsp_one",
          enabled: false,
          convergence_status: "succeeded",
        }}
        onAccessDenied={vi.fn()}
        ready
        userId="usr_one"
      />
    );
    await user.selectOptions(
      screen.getByRole("combobox", { name: "Cloud VM setting" }),
      "enabled"
    );
    expect(
      screen.getByRole("button", { name: "Review Cloud VM change" })
    ).toBeDisabled();
    await user.type(
      screen.getByRole("textbox", { name: /^Reason/ }),
      "Enable VM for this Workspace"
    );
    await user.click(screen.getByRole("button", { name: "Review Cloud VM change" }));
    const dialog = screen.getByRole("dialog", { name: "Enable Cloud VM?" });
    await user.type(within(dialog).getByRole("textbox"), "workspace-vm:wsp_one:enable");
    await user.click(within(dialog).getByRole("button", { name: /^Confirm$/ }));
    expect(await within(dialog).findByText("Provider unavailable")).toBeVisible();
    expect(screen.getByText("Disabled", { selector: "dd" })).toBeVisible();
    await user.click(within(dialog).getByRole("button", { name: /^Confirm$/ }));
    expect(await screen.findByText(/Cloud VM setting saved/)).toBeVisible();
    expect(update).toHaveBeenCalledTimes(2);
    expect(update.mock.calls[0]).toEqual(update.mock.calls[1]);
    expect(update.mock.calls[0]).toEqual([
      "usr_one",
      "wsp_one",
      expect.objectContaining({
        enabled: true,
        confirmation: "workspace-vm:wsp_one:enable",
        reason: "Enable VM for this Workspace",
      }),
    ]);
  });

  it("does not expose a mutation for an unready Workspace", () => {
    render(
      <WorkspaceCloudVmSection
        api={{} as AdminApi}
        current={{
          workspace_id: "wsp_one",
          enabled: true,
          convergence_status: "pending",
        }}
        onAccessDenied={vi.fn()}
        ready={false}
        userId="usr_one"
      />
    );
    expect(screen.queryByRole("combobox")).not.toBeInTheDocument();
    expect(screen.getByText(/when the Workspace is ready/)).toBeVisible();
  });
});
