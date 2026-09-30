import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { AdminApi, AdminUser } from "../src/adminApi";
import { UserWorkspaceBillingPanel } from "../src/UserWorkspaceBillingPanel";

const noSignalNumber = { override: null, platform: null, effective: null };

describe("UserWorkspaceBillingPanel", () => {
  it("shows both agent models and independently changes the Worker assignment", async () => {
    const billingOverview = {
      workspace: {
        id: "wsp_owner",
        name: "Owner Workspace",
        status: "ready" as const,
        tenant_id: "tnt_owner",
        group_id: "grp_owner",
        billing_account_id: "billing_owner",
        created_at: 1_784_880_000,
        updated_at: 1_784_880_500,
      },
      billing: {
        account_id: "billing_owner",
        account_status: "active" as const,
        current_credits: 1_200,
        active_grants: [],
        has_more: false,
      },
    };
    const modelOptions = [
      {
        template_id: "template_luna",
        name: "GPT-5.6 Luna",
        model: "gpt-5.6-luna",
        provider: "openai",
        scope: "global" as const,
      },
      {
        template_id: "template_sol",
        name: "GPT-5.6 Sol",
        model: "gpt-5.6-sol",
        provider: "openai",
        scope: "global" as const,
      },
      {
        template_id: "template_terra",
        name: "GPT-5.6 Terra",
        model: "gpt-5.6-terra",
        provider: "openai",
        scope: "global" as const,
      },
    ];
    const firstModels = {
      workspace_id: "wsp_owner",
      agents: {
        router: {
          agent_id: "agent_router",
          role: "router" as const,
          template_id: "template_luna",
          template_name: "GPT-5.6 Luna",
          model: "gpt-5.6-luna",
          provider: "openai",
        },
        worker: {
          agent_id: "agent_worker",
          role: "worker" as const,
          template_id: "template_sol",
          template_name: "GPT-5.6 Sol",
          model: "gpt-5.6-sol",
          provider: "openai",
        },
      },
      available_models: modelOptions,
    };
    const updatedModels = {
      ...firstModels,
      agents: {
        ...firstModels.agents,
        worker: {
          ...firstModels.agents.worker,
          template_id: "template_terra",
          template_name: "GPT-5.6 Terra",
          model: "gpt-5.6-terra",
        },
      },
    };
    const api = {
      getUserWorkspaceSignalNumber: vi.fn().mockResolvedValue(noSignalNumber),
      getUserWorkspaceAgentModels: vi
        .fn()
        .mockResolvedValueOnce(firstModels)
        .mockResolvedValue(updatedModels),
      getUserWorkspaceBilling: vi.fn().mockResolvedValue(billingOverview),
      updateUserWorkspaceAgentModel: vi
        .fn()
        .mockResolvedValue(updatedModels.agents.worker),
    } as unknown as AdminApi;
    const user: AdminUser = {
      id: "usr_owner",
      email: "owner@example.com",
      name: "Owner",
      status: "active",
    };
    const interaction = userEvent.setup();

    render(
      <UserWorkspaceBillingPanel
        api={api}
        onAccessDenied={vi.fn()}
        onApplyRedeemCode={vi.fn()}
        onBack={vi.fn()}
        onEnsureWorkspace={vi.fn()}
        user={user}
      />
    );

    expect(await screen.findByRole("heading", { name: "Agent models" })).toBeVisible();
    expect(await screen.findByText("gpt-5.6-luna")).toBeVisible();
    expect(screen.getByText("gpt-5.6-sol")).toBeVisible();

    await interaction.click(
      screen.getByRole("button", { name: "Change Worker model" })
    );
    const pane = await screen.findByRole("region", { name: "Change Worker model" });
    await interaction.selectOptions(
      screen.getByRole("combobox", { name: "Worker model" }),
      "template_terra"
    );
    await interaction.type(
      screen.getByRole("textbox", { name: /^Reason/ }),
      "Use the approved lower-latency model"
    );
    await interaction.click(screen.getByRole("button", { name: "Review command" }));

    const confirmation = await screen.findByRole("dialog", {
      name: "Change Worker model?",
    });
    await interaction.type(
      screen.getByRole("textbox", { name: /Confirmation/ }),
      "workspace-agent-model:usr_owner:worker:template_terra"
    );
    await interaction.click(screen.getByRole("button", { name: "Confirm" }));

    expect(
      await screen.findByText("Worker model changed to GPT-5.6 Terra — gpt-5.6-terra.")
    ).toBeVisible();
    expect(api.updateUserWorkspaceAgentModel).toHaveBeenCalledWith(
      "usr_owner",
      "worker",
      expect.objectContaining({
        confirmation: "workspace-agent-model:usr_owner:worker:template_terra",
        reason: "Use the approved lower-latency model",
        templateId: "template_terra",
      })
    );
    expect(api.getUserWorkspaceAgentModels).toHaveBeenCalledTimes(2);
    expect(screen.getByText("gpt-5.6-terra")).toBeVisible();
    expect(pane).not.toBeInTheDocument();
    expect(confirmation).not.toBeInTheDocument();
  });

  it("shows the Tenant and Agent group ids that the Workspace references", async () => {
    const api = {
      getUserWorkspaceSignalNumber: vi.fn().mockResolvedValue(noSignalNumber),
      getUserWorkspaceAgentModels: vi
        .fn()
        .mockResolvedValue(workspaceAgentModelsFixture()),
      getUserWorkspaceBilling: vi.fn().mockResolvedValue({
        workspace: {
          id: "wsp_owner",
          name: "Owner Workspace",
          status: "ready",
          tenant_id: "tnt_owner",
          group_id: "grp_owner",
          billing_account_id: "billing_owner",
          created_at: 1_784_880_000,
          updated_at: 1_784_880_500,
        },
        billing: {
          account_id: "billing_owner",
          account_status: "active",
          current_credits: 1_200,
          active_grants: [],
          has_more: false,
        },
      }),
    } as unknown as AdminApi;

    render(
      <UserWorkspaceBillingPanel
        api={api}
        onAccessDenied={vi.fn()}
        onApplyRedeemCode={vi.fn()}
        onBack={vi.fn()}
        onEnsureWorkspace={vi.fn()}
        user={{
          id: "usr_owner",
          email: "owner@example.com",
          name: "Owner",
          status: "active",
        }}
      />
    );

    expect(await screen.findByText("Tenant ID")).toBeVisible();
    expect(screen.getByText("tnt_owner")).toBeVisible();
    expect(screen.getByText("Agent group ID")).toBeVisible();
    expect(screen.getByText("grp_owner")).toBeVisible();
  });

  it("keeps Billing visible when the agent-model projection fails and retries it independently", async () => {
    const api = {
      getUserWorkspaceSignalNumber: vi.fn().mockResolvedValue(noSignalNumber),
      getUserWorkspaceAgentModels: vi
        .fn()
        .mockRejectedValueOnce(new Error("Salix unavailable"))
        .mockResolvedValue(workspaceAgentModelsFixture()),
      getUserWorkspaceBilling: vi.fn().mockResolvedValue({
        workspace: {
          id: "wsp_owner",
          name: "Owner Workspace",
          status: "ready",
          tenant_id: "tnt_owner",
          group_id: "grp_owner",
          billing_account_id: "billing_owner",
          created_at: 1_784_880_000,
          updated_at: 1_784_880_500,
        },
        billing: {
          account_id: "billing_owner",
          account_status: "active",
          current_credits: 1_200,
          active_grants: [],
          has_more: false,
        },
      }),
    } as unknown as AdminApi;

    render(
      <UserWorkspaceBillingPanel
        api={api}
        onAccessDenied={vi.fn()}
        onApplyRedeemCode={vi.fn()}
        onBack={vi.fn()}
        onEnsureWorkspace={vi.fn()}
        user={{
          id: "usr_owner",
          email: "owner@example.com",
          name: "Owner",
          status: "active",
        }}
      />
    );

    expect(
      await screen.findByRole("heading", { name: "Agent models couldn’t be loaded" })
    ).toBeVisible();
    expect(screen.getByText("1,200")).toBeVisible();

    await userEvent.click(screen.getByRole("button", { name: "Retry" }));

    expect(await screen.findAllByText("gpt-5.6-luna")).toHaveLength(2);
    expect(api.getUserWorkspaceAgentModels).toHaveBeenCalledTimes(2);
    expect(api.getUserWorkspaceBilling).toHaveBeenCalledTimes(1);
  });

  it("keeps redeem-code application disabled for a mismatched Billing owner", async () => {
    const onApplyRedeemCode = vi.fn();
    const api = {
      getUserWorkspaceSignalNumber: vi.fn().mockResolvedValue(noSignalNumber),
      getUserWorkspaceAgentModels: vi
        .fn()
        .mockResolvedValue(workspaceAgentModelsFixture()),
      getUserWorkspaceBilling: vi.fn().mockResolvedValue({
        workspace: {
          id: "wsp_owner",
          name: "Owner Workspace",
          status: "ready",
          tenant_id: "tnt_owner",
          group_id: "grp_owner",
          billing_account_id: "billing_owner",
          created_at: 1_784_880_000,
          updated_at: 1_784_880_500,
        },
        billing: {
          account_id: "billing_owner",
          account_status: "identity_mismatch",
          current_credits: 0,
          active_grants: [],
          has_more: false,
        },
      }),
    } as unknown as AdminApi;
    const user: AdminUser = {
      id: "usr_owner",
      email: "owner@example.com",
      name: "Owner",
      status: "active",
    };

    render(
      <UserWorkspaceBillingPanel
        api={api}
        onAccessDenied={vi.fn()}
        onApplyRedeemCode={onApplyRedeemCode}
        onBack={vi.fn()}
        onEnsureWorkspace={vi.fn()}
        user={user}
      />
    );

    expect(
      await screen.findByText(
        "The Billing account does not belong to this Workspace. No credits or grants were read."
      )
    ).toBeInTheDocument();
    expect(screen.getAllByText("0")).toHaveLength(2);

    const applyButton = screen.getByRole("button", {
      name: "Apply redeem code",
    });
    expect(applyButton).toBeDisabled();
    expect(screen.getByRole("button", { name: "Issue credits" })).toBeDisabled();
    await userEvent.click(applyButton);
    expect(onApplyRedeemCode).not.toHaveBeenCalled();
  });

  it("issues a package-backed grant without sending Billing owner fields", async () => {
    const overview = {
      workspace: {
        id: "wsp_owner",
        name: "Owner Workspace",
        status: "ready" as const,
        tenant_id: "tnt_owner",
        group_id: "grp_owner",
        billing_account_id: "billing_owner",
        created_at: 1_784_880_000,
        updated_at: 1_784_880_500,
      },
      billing: {
        account_id: "billing_owner",
        account_status: "active" as const,
        current_credits: 1_200,
        active_grants: [],
        has_more: false,
      },
    };
    const api = {
      getUserWorkspaceSignalNumber: vi.fn().mockResolvedValue(noSignalNumber),
      getUserWorkspaceAgentModels: vi
        .fn()
        .mockResolvedValue(workspaceAgentModelsFixture()),
      getUserWorkspaceBilling: vi.fn().mockResolvedValue(overview),
      issueUserWorkspaceCredits: vi.fn().mockResolvedValue({
        manual_grant: {
          id: "manual_grant_1",
          billing_account_id: "billing_owner",
          package_code: "comma_support",
          package_version: "2026-07",
          source_type: "manual_adjustment",
          source_id: "comma_admin:wsp_owner",
          source_event_id: "audit_1",
          operator_snapshot: {
            id: "usr_admin",
            type: "comma_admin_user",
            reason: "Approved support grant",
          },
          valid_from: "2026-07-28T08:00:00Z",
          expires_at: "2099-08-01T00:00:00Z",
          credit_grant_id: "grant_1",
          status: "issued",
        },
        grant: {
          id: "grant_1",
          billing_account_id: "billing_owner",
          remaining_credits: 4_000_000,
          valid_from: "2026-07-28T08:00:00Z",
          expires_at: "2099-08-01T00:00:00Z",
          status: "active",
        },
        idempotent: false,
      }),
      listPackageVersions: vi.fn().mockResolvedValue([
        {
          id: "package_v1",
          package_code: "comma_support",
          package_name: "Comma Support",
          version: "2026-07",
          surface: "comma",
          kind: "one_time",
          grant_credits: 4_000_000,
          grant_period: "current_period",
          status: "active",
        },
      ]),
    } as unknown as AdminApi;
    const user: AdminUser = {
      id: "usr_owner",
      email: "owner@example.com",
      name: "Owner",
      status: "active",
    };
    const interaction = userEvent.setup();

    render(
      <UserWorkspaceBillingPanel
        api={api}
        onAccessDenied={vi.fn()}
        onApplyRedeemCode={vi.fn()}
        onBack={vi.fn()}
        onEnsureWorkspace={vi.fn()}
        user={user}
      />
    );

    await interaction.click(
      await screen.findByRole("button", { name: "Issue credits" })
    );
    const pane = await screen.findByRole("region", {
      name: "Issue Workspace credits",
    });
    expect(
      screen.queryByRole("dialog", { name: "Issue Workspace credits" })
    ).toBeNull();
    await interaction.type(
      screen.getByRole("textbox", { name: /^Reason/ }),
      "Approved support grant"
    );
    await interaction.click(screen.getByRole("button", { name: "Review command" }));

    const confirmation = await screen.findByRole("dialog", {
      name: "Issue these credits?",
    });
    await interaction.type(
      screen.getByRole("textbox", { name: /Confirmation/ }),
      "issue-workspace-credits:wsp_owner:comma_support:2026-07"
    );
    await interaction.click(screen.getByRole("button", { name: "Confirm" }));

    expect(await screen.findByText("Issued 4,000,000 credits.")).toBeInTheDocument();
    expect(api.issueUserWorkspaceCredits).toHaveBeenCalledWith(
      "usr_owner",
      expect.objectContaining({
        confirmation: "issue-workspace-credits:wsp_owner:comma_support:2026-07",
        packageCode: "comma_support",
        packageVersion: "2026-07",
        reason: "Approved support grant",
      })
    );
    const command = vi.mocked(api.issueUserWorkspaceCredits).mock.calls[0]?.[1];
    expect(command).not.toHaveProperty("billingAccountId");
    expect(command).not.toHaveProperty("workspaceId");
    expect(api.getUserWorkspaceBilling).toHaveBeenCalledTimes(2);
    expect(pane).not.toBeInTheDocument();
    expect(confirmation).not.toBeInTheDocument();
  });
});

function workspaceAgentModelsFixture() {
  const template = {
    template_id: "template_luna",
    name: "GPT-5.6 Luna",
    model: "gpt-5.6-luna",
    provider: "openai",
    scope: "global" as const,
  };

  return {
    workspace_id: "wsp_owner",
    agents: {
      router: {
        agent_id: "agent_router",
        role: "router" as const,
        template_id: template.template_id,
        template_name: template.name,
        model: template.model,
        provider: template.provider,
      },
      worker: {
        agent_id: "agent_worker",
        role: "worker" as const,
        template_id: template.template_id,
        template_name: template.name,
        model: template.model,
        provider: template.provider,
      },
    },
    available_models: [template],
  };
}
