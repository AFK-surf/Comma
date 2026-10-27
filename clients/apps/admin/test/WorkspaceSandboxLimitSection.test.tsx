import { screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { makeWorkspaceSandboxLimitModel } from "../src/WorkspaceSandboxLimitModel";
import { WorkspaceSandboxLimitSection } from "../src/WorkspaceSandboxLimitSection";
import { mountModel, ok, review, settle } from "./support";

describe("Workspace coding sandbox limit", () => {
  it("refuses a limit out of range and saves the Workspace's own limit", async () => {
    const update = vi
      .fn()
      .mockReturnValue(ok({ override: 8, default: 5, effective: 8 }));
    const view = mountModel(makeWorkspaceSandboxLimitModel("usr_one"), {
      api: {
        getUserWorkspaceSandboxLimit: vi
          .fn()
          .mockReturnValue(ok({ override: null, default: 5, effective: 5 })),
        updateUserWorkspaceSandboxLimit: update,
      },
    });
    const user = userEvent.setup({ delay: null });

    view.render(<WorkspaceSandboxLimitSection model={view.model} />);
    await settle();

    expect(screen.getByText("Deployment default")).toBeVisible();
    await user.click(
      screen.getByRole("button", { name: "Change coding sandbox limit" })
    );
    const input = screen.getByRole("textbox", {
      name: /^Workspace coding sandbox limit/,
    });
    const save = screen.getByRole("button", { name: "Save sandbox limit" });

    await user.type(input, "0");
    expect(screen.getByText("Enter a whole number from 1 to 100.")).toBeVisible();
    expect(save).toBeDisabled();

    await user.clear(input);
    await user.type(input, "8");
    await user.click(save);
    await settle();

    const dialog = screen.getByRole("dialog", {
      name: "Set the Workspace coding sandbox limit?",
    });
    expect(dialog).toHaveTextContent("Deployment default→8");
    await review(user, "Set the Workspace coding sandbox limit?", "Larger team");
    await settle();

    expect(screen.getByText("Coding sandbox limit set to 8.")).toBeVisible();
    expect(update).toHaveBeenCalledWith(
      "usr_one",
      expect.objectContaining({
        maxSandboxes: 8,
        confirmation: "workspace-sandbox-limit:usr_one:8",
        reason: "Larger team",
      })
    );
  });
});
