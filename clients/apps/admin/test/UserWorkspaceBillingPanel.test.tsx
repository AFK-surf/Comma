import { Effect } from "effect";
import { screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { TestClock } from "effect/testing";
import { describe, expect, it, vi } from "vitest";
import type {
  AdminApiShape,
  AdminUser,
  AdminWorkspaceAgentModel,
} from "../src/adminApi";
import { makeUserWorkspaceBillingModel } from "../src/UserWorkspaceBillingModel";
import { UserWorkspaceBillingPanel } from "../src/UserWorkspaceBillingPanel";
import { mountModel, ok, refuse, review, settle, onTestClock } from "./support";

const noSignalNumber = { override: null, platform: null, effective: null };
const defaultSandboxLimit = { override: null, default: 5, effective: 5 };

async function mountPanel(api: Partial<AdminApiShape>, user: AdminUser) {
  const view = mountModel(makeUserWorkspaceBillingModel(user), { api });
  view.render(
    <UserWorkspaceBillingPanel model={view.model} onEnsureWorkspace={vi.fn()} />
  );
  await settle();
  return view;
}

describe("UserWorkspaceBillingPanel", () => {
  it("shows both agent models and independently returns the Worker to the platform model", async () => {
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
    const firstModels = workspaceAgentModelsFixture({
      worker: {
        agent_id: "agent_worker",
        role: "worker" as const,
        source: "pinned" as const,
        model: "gpt-5.6-sol",
        provider: "openai",
        selection: { kind: "catalog" as const, model: "gpt-5.6-sol" },
      },
    });
    const updatedModels = workspaceAgentModelsFixture();
    const api = {
      getUserWorkspaceSignalNumber: vi.fn().mockReturnValue(ok(noSignalNumber)),
      getUserWorkspaceSandboxLimit: vi.fn().mockReturnValue(ok(defaultSandboxLimit)),
      getUserWorkspaceAgentModels: vi
        .fn()
        .mockReturnValueOnce(ok(firstModels))
        .mockReturnValue(ok(updatedModels)),
      getUserWorkspaceBilling: vi.fn().mockReturnValue(ok(billingOverview)),
      updateUserWorkspaceAgentModel: vi
        .fn()
        .mockReturnValue(ok(updatedModels.agents.worker)),
    } satisfies Partial<AdminApiShape>;
    const user: AdminUser = {
      id: "usr_owner",
      email: "owner@example.com",
      name: "Owner",
      status: "active",
    };
    const interaction = userEvent.setup({ delay: null });

    await mountPanel(api, user);

    expect(screen.getByRole("heading", { name: "Agent models" })).toBeVisible();
    expect(screen.getByText("gpt-5.6-luna")).toBeVisible();
    expect(screen.getByText("gpt-5.6-sol")).toBeVisible();

    await interaction.click(
      screen.getByRole("button", { name: "Change Worker model" })
    );
    await settle();
    const pane = screen.getByRole("dialog", { name: "Change Worker model" });
    const picker = screen.getByRole("combobox", { name: "Worker model" });
    expect(picker).toHaveValue("catalog:gpt-5.6-sol");
    await interaction.selectOptions(picker, "Platform default (GPT-5.6 Luna)");
    await interaction.click(screen.getByRole("button", { name: "Change model…" }));
    await settle();

    const confirmation = screen.getByRole("dialog", {
      name: "Change Worker model?",
    });
    expect(confirmation).toHaveTextContent(
      "Worker modelgpt-5.6-sol→Platform default (GPT-5.6 Luna)"
    );
    await review(
      interaction,
      "Change Worker model?",
      "Use the approved lower-latency model"
    );

    expect(screen.getByText("Worker model changed to gpt-5.6-luna.")).toBeVisible();
    expect(api.updateUserWorkspaceAgentModel).toHaveBeenCalledWith(
      "usr_owner",
      "worker",
      expect.objectContaining({
        confirmation: "workspace-agent-model:usr_owner:worker:default",
        model: null,
        reason: "Use the approved lower-latency model",
      })
    );
    expect(api.getUserWorkspaceAgentModels).toHaveBeenCalledTimes(2);
    expect(screen.getAllByText("gpt-5.6-luna")).toHaveLength(2);
    expect(pane).not.toBeInTheDocument();
    expect(confirmation).not.toBeInTheDocument();
  });

  it("shows the Tenant and Agent group ids that the Workspace references", async () => {
    const api = {
      getUserWorkspaceSignalNumber: vi.fn().mockReturnValue(ok(noSignalNumber)),
      getUserWorkspaceSandboxLimit: vi.fn().mockReturnValue(ok(defaultSandboxLimit)),
      getUserWorkspaceAgentModels: vi
        .fn()
        .mockReturnValue(ok(workspaceAgentModelsFixture())),
      getUserWorkspaceBilling: vi.fn().mockReturnValue(
        ok({
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
        })
      ),
    } satisfies Partial<AdminApiShape>;

    await mountPanel(api, {
      id: "usr_owner",
      email: "owner@example.com",
      name: "Owner",
      status: "active",
    });

    expect(screen.getByText("Tenant ID")).toBeVisible();
    expect(screen.getByText("tnt_owner")).toBeVisible();
    expect(screen.getByText("Agent group ID")).toBeVisible();
    expect(screen.getByText("grp_owner")).toBeVisible();
  });

  it("keeps Billing visible when the agent-model projection fails and retries it independently", async () => {
    const api = {
      getUserWorkspaceSignalNumber: vi.fn().mockReturnValue(ok(noSignalNumber)),
      getUserWorkspaceSandboxLimit: vi.fn().mockReturnValue(ok(defaultSandboxLimit)),
      getUserWorkspaceAgentModels: vi
        .fn()
        .mockReturnValueOnce(refuse(503, "salix_unavailable", "Salix unavailable"))
        .mockReturnValue(ok(workspaceAgentModelsFixture())),
      getUserWorkspaceBilling: vi.fn().mockReturnValue(
        ok({
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
        })
      ),
    } satisfies Partial<AdminApiShape>;

    await mountPanel(api, {
      id: "usr_owner",
      email: "owner@example.com",
      name: "Owner",
      status: "active",
    });

    expect(screen.getByText("Agent models couldn’t be loaded")).toBeVisible();
    expect(screen.getByText("1,200")).toBeVisible();

    await userEvent.click(screen.getByRole("button", { name: "Retry" }));
    await settle();

    expect(screen.getAllByText("gpt-5.6-luna")).toHaveLength(2);
    expect(api.getUserWorkspaceAgentModels).toHaveBeenCalledTimes(2);
    expect(api.getUserWorkspaceBilling).toHaveBeenCalledTimes(1);
  });

  it("keeps redeem-code application disabled for a mismatched Billing owner", async () => {
    const api = {
      getUserWorkspaceSignalNumber: vi.fn().mockReturnValue(ok(noSignalNumber)),
      getUserWorkspaceSandboxLimit: vi.fn().mockReturnValue(ok(defaultSandboxLimit)),
      getUserWorkspaceAgentModels: vi
        .fn()
        .mockReturnValue(ok(workspaceAgentModelsFixture())),
      getUserWorkspaceBilling: vi.fn().mockReturnValue(
        ok({
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
        })
      ),
    } satisfies Partial<AdminApiShape>;
    const user: AdminUser = {
      id: "usr_owner",
      email: "owner@example.com",
      name: "Owner",
      status: "active",
    };

    const view = await mountPanel(api, user);

    expect(
      screen.getByText(
        "The Billing account does not belong to this Workspace. No credits or grants were read."
      )
    ).toBeInTheDocument();
    expect(screen.getByText("0", { selector: "strong" })).toBeInTheDocument();

    const applyButton = screen.getByRole("button", {
      name: "Apply redeem code",
    });
    expect(applyButton).toBeDisabled();
    await userEvent.click(applyButton);
    view.runtime.runFork(view.model.openIssueCredits);
    await settle();
    expect(view.links.applyRedeemCode).not.toHaveBeenCalled();
    expect(screen.queryByRole("dialog", { name: "Issue credits" })).toBeNull();
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
      getUserWorkspaceSignalNumber: vi.fn().mockReturnValue(ok(noSignalNumber)),
      getUserWorkspaceSandboxLimit: vi.fn().mockReturnValue(ok(defaultSandboxLimit)),
      getUserWorkspaceAgentModels: vi
        .fn()
        .mockReturnValue(ok(workspaceAgentModelsFixture())),
      getUserWorkspaceBilling: vi.fn().mockReturnValue(ok(overview)),
      issueUserWorkspaceCredits: vi.fn().mockReturnValue(
        ok({
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
        })
      ),
      listPackageVersions: Effect.suspend(
        vi.fn().mockReturnValue(
          ok([
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
          ])
        )
      ),
    } satisfies Partial<AdminApiShape>;
    const user: AdminUser = {
      id: "usr_owner",
      email: "owner@example.com",
      name: "Owner",
      status: "active",
    };
    const interaction = userEvent.setup({ delay: null });

    const view = await mountPanel(api, user);
    // The default expiry is 30 days after now, and must be in the future.
    await onTestClock(
      view.runtime.runPromise(TestClock.setTime(Date.parse("2026-07-28T08:00:00Z")))
    );

    // The account page's header opens the Issue credits drawer.
    view.runtime.runFork(view.model.openIssueCredits);
    await settle();
    const pane = screen.getByRole("dialog", { name: "Issue credits" });
    await interaction.click(screen.getByRole("button", { name: "Issue credits…" }));
    await settle();

    const confirmation = screen.getByRole("dialog", {
      name: "Issue these credits?",
    });
    expect(confirmation).toHaveTextContent("Credits—→+4,000,000");
    await review(interaction, "Issue these credits?", "Approved support grant");

    expect(screen.getByText("Issued 4,000,000 credits.")).toBeInTheDocument();
    expect(api.issueUserWorkspaceCredits).toHaveBeenCalledWith(
      "usr_owner",
      expect.objectContaining({
        confirmation: "issue-workspace-credits:wsp_owner:comma_support:2026-07",
        packageCode: "comma_support",
        packageVersion: "2026-07",
        reason: "Approved support grant",
      })
    );
    const command = api.issueUserWorkspaceCredits.mock.calls[0]?.[1];
    expect(command).not.toHaveProperty("billingAccountId");
    expect(command).not.toHaveProperty("workspaceId");
    expect(command).toHaveProperty("expiresAt", "2026-08-27T08:00:00.000Z");
    expect(api.getUserWorkspaceBilling).toHaveBeenCalledTimes(2);
    expect(pane).not.toBeInTheDocument();
    expect(confirmation).not.toBeInTheDocument();
  });
});

function workspaceAgentModelsFixture(
  overrides: { worker?: AdminWorkspaceAgentModel } = {}
) {
  const platform = {
    agent_id: "agent_router",
    role: "router" as const,
    source: "platform_default" as const,
    model: "gpt-5.6-luna",
    provider: "openai",
    selection: { kind: "builtin" as const },
  };

  return {
    workspace_id: "wsp_owner",
    agents: {
      router: platform,
      worker: overrides.worker ?? {
        ...platform,
        agent_id: "agent_worker",
        role: "worker" as const,
      },
    },
    platform_defaults: {
      router: { name: "GPT-5.6 Luna", model: "gpt-5.6-luna", provider: "openai" },
      worker: { name: "GPT-5.6 Luna", model: "gpt-5.6-luna", provider: "openai" },
    },
  };
}
