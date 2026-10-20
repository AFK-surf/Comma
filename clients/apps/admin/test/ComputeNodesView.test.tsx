import { screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, expect, it, vi } from "vitest";
import type {
  AdminApiShape,
  AdminPage,
  AgentVmmCommandResult,
  AgentVmmNode,
  AgentVmmOverview,
} from "../src/adminApi";
import { makeComputeNodesModel } from "../src/ComputeNodesModel";
import { ComputeNodesView } from "../src/ComputeNodesView";
import { mountModel, ok, pending, review, settle } from "./support";

const overview: AgentVmmOverview = {
  total: 1,
  ready: 0,
  needs_attention: 1,
  disabled: 0,
  revoked: 0,
  enrolling: 0,
  draining: 0,
  disconnected_or_stale: 1,
  lease_expiring: 0,
  unknown_outcome: 0,
};

const node: AgentVmmNode = {
  id: "registration-a",
  device_id: "host-a",
  group_id: "group-a",
  status: "unknown",
  issue: "observation_stale",
  updated_at: "2026-09-01T10:00:00Z",
  registration: { status: "ready", desired_enabled: true, revision: 7 },
  installation: null,
  connection: {
    status: "stale",
    last_observed_at: "2026-09-01T09:58:00Z",
    binding_count: 1,
  },
  work: { allocations: 1, workloads: 1, runtimes: 1 },
  operations: {},
};

const page: AdminPage<AgentVmmNode> = { data: [node], hasMore: false };
const accepted: AgentVmmCommandResult = {
  accepted: true,
  action: "disable_agent_vmm_registration",
  target: "registration-a",
  result_revision: 8,
};

afterEach(() => window.history.replaceState(null, "", "/"));

function fleetApi() {
  return {
    getAgentVmmNode: vi.fn(() => ok(node)),
    getAgentVmmOverview: vi.fn(() => ok(overview)),
    listAgentVmmNodes: vi.fn(() => ok(page)),
  };
}

async function mountComputeNodes(api: Partial<AdminApiShape>) {
  const view = mountModel(makeComputeNodesModel, { api });
  view.render(<ComputeNodesView model={view.model} />);
  await settle();
  return view;
}

it("loads a tenant's fleet and keeps the open node in the URL", async () => {
  window.history.replaceState(null, "", "/?section=compute");
  const api = fleetApi();
  await mountComputeNodes(api);
  const user = userEvent.setup({ delay: null });

  expect(screen.getByText("Enter a tenant ID to load its fleet.")).toBeVisible();
  await user.click(screen.getByRole("textbox", { name: "Tenant ID" }));
  await user.paste(" tenant-a ");
  await user.click(screen.getByRole("button", { name: "Load tenant" }));
  await settle();

  expect(api.getAgentVmmOverview).toHaveBeenCalledWith("tenant-a");
  expect(api.listAgentVmmNodes).toHaveBeenCalledWith("tenant-a", { limit: 50 });
  expect(window.location.search).toBe("?section=compute&tenant=tenant-a");
  await user.click(screen.getByRole("button", { name: "Open compute node host-a" }));
  await settle();

  const drawer = screen.getByRole("dialog", { name: "host-a" });
  expect(within(drawer).getByText("observation_stale")).toBeVisible();
  expect(api.getAgentVmmNode).toHaveBeenCalledWith("tenant-a", "registration-a");
  expect(window.location.search).toBe(
    "?section=compute&tenant=tenant-a&registration=registration-a"
  );
  await user.click(within(drawer).getByRole("button", { name: "Close" }));
  await settle();
  expect(screen.queryByRole("dialog", { name: "host-a" })).toBeNull();
  expect(window.location.search).toBe("?section=compute&tenant=tenant-a");
});

it("runs an audited node command and reloads the fleet", async () => {
  window.history.replaceState(
    null,
    "",
    "/?section=compute&tenant=tenant-a&registration=registration-a"
  );
  const api = fleetApi();
  const reply = pending<AgentVmmCommandResult>();
  const execute = vi.fn(() => reply.effect);
  await mountComputeNodes({ ...api, executeAgentVmmCommand: execute });
  const user = userEvent.setup({ delay: null });

  const drawer = screen.getByRole("dialog", { name: "host-a" });
  await user.click(within(drawer).getByRole("button", { name: "Disable / drain" }));
  await settle();
  const confirmation = screen.getByRole("dialog", {
    name: "Disable and drain registration",
  });
  await user.type(
    within(confirmation).getByRole("textbox", { name: "Reason" }),
    "Drain it"
  );
  await user.click(within(confirmation).getByRole("button", { name: "Confirm" }));
  await settle();

  expect(within(confirmation).getByRole("button", { name: "Working…" })).toBeVisible();
  expect(execute).toHaveBeenCalledWith(
    "tenant-a",
    "disable_agent_vmm_registration",
    "registration-a",
    7,
    {
      confirmation: "disable_agent_vmm_registration:registration-a:7",
      idempotencyKey: expect.stringMatching(
        /^agent-vmm:disable_agent_vmm_registration:registration-a:/
      ),
      reason: "Drain it",
    }
  );

  reply.succeed(accepted);
  await settle();
  expect(
    screen.queryByRole("dialog", { name: "Disable and drain registration" })
  ).toBeNull();
  expect(
    screen.getByText(
      "Disable and drain registration was accepted. Refresh to observe convergence."
    )
  ).toBeVisible();
  expect(api.getAgentVmmOverview).toHaveBeenCalledTimes(2);
  expect(api.getAgentVmmNode).toHaveBeenCalledTimes(2);
});

it("asks for a reason and the host's name before a node is revoked", async () => {
  window.history.replaceState(
    null,
    "",
    "/?section=compute&tenant=tenant-a&registration=registration-a"
  );
  const execute = vi.fn(() => ok(accepted));
  await mountComputeNodes({ ...fleetApi(), executeAgentVmmCommand: execute });
  const user = userEvent.setup({ delay: null });

  const drawer = screen.getByRole("dialog", { name: "host-a" });
  await user.click(within(drawer).getByRole("button", { name: "Revoke registration" }));
  await settle();
  const confirmation = screen.getByRole("dialog", { name: "Revoke registration" });
  await user.click(within(confirmation).getByRole("button", { name: "Confirm" }));
  await settle();
  expect(
    within(confirmation).getByText("Enter a reason of at least 3 characters.")
  ).toBeVisible();
  expect(execute).not.toHaveBeenCalled();

  await review(user, "Revoke registration", "Retire the host", "host-a");
  expect(execute).toHaveBeenCalledWith(
    "tenant-a",
    "revoke_agent_vmm_registration",
    "registration-a",
    7,
    expect.objectContaining({
      confirmation: "revoke_agent_vmm_registration:registration-a:7",
      reason: "Retire the host",
    })
  );
});
