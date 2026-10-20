import { screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { makeWorkspaceCloudVmModel } from "../src/WorkspaceCloudVmModel";
import { WorkspaceCloudVmSection } from "../src/WorkspaceCloudVmSection";
import { mountModel, ok, refuse, review, settle } from "./support";

describe("Workspace Cloud VM", () => {
  it("preserves the saved setting on failure and retries the exact audited command", async () => {
    const update = vi
      .fn()
      .mockReturnValueOnce(refuse(503, "provider_unavailable", "Provider unavailable"))
      .mockReturnValue(
        ok({
          workspace_id: "wsp_one",
          enabled: true,
          convergence_status: "pending",
        })
      );
    const user = userEvent.setup({ delay: null });
    const view = mountModel(
      makeWorkspaceCloudVmModel({
        current: {
          workspace_id: "wsp_one",
          enabled: false,
          convergence_status: "succeeded",
        },
        ready: true,
        userId: "usr_one",
      }),
      { api: { updateUserWorkspaceVm: update } }
    );
    view.render(<WorkspaceCloudVmSection model={view.model} />);
    await settle();
    const vm = screen.getByRole("switch", { name: "Cloud VM" });
    expect(vm).not.toBeChecked();
    // Cancelling the review keeps the saved setting.
    await user.click(vm);
    await settle();
    await user.click(
      within(screen.getByRole("dialog", { name: "Enable Cloud VM?" })).getByRole(
        "button",
        {
          name: "Cancel",
        }
      )
    );
    await settle();
    expect(vm).not.toBeChecked();
    expect(update).not.toHaveBeenCalled();

    await user.click(vm);
    await settle();
    await review(user, "Enable Cloud VM?", "Enable VM for this Workspace");
    const dialog = screen.getByRole("dialog", { name: "Enable Cloud VM?" });
    expect(within(dialog).getByText("Provider unavailable")).toBeVisible();
    expect(vm).not.toBeChecked();
    await user.click(within(dialog).getByRole("button", { name: /^Confirm$/ }));
    await settle();
    expect(screen.getByText(/Cloud VM setting saved/)).toBeVisible();
    expect(vm).toBeChecked();
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

  it("does not expose a mutation for an unready Workspace", async () => {
    const view = mountModel(
      makeWorkspaceCloudVmModel({
        current: {
          workspace_id: "wsp_one",
          enabled: true,
          convergence_status: "pending",
        },
        ready: false,
        userId: "usr_one",
      })
    );
    view.render(<WorkspaceCloudVmSection model={view.model} />);
    await settle();
    expect(screen.getByRole("switch", { name: "Cloud VM" })).toBeDisabled();
    expect(screen.getByText(/when the Workspace is ready/)).toBeVisible();
  });
});
