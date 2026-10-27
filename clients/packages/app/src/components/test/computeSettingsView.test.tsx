import { act, render, renderHook, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { useCommaMessages } from "@comma/i18n/react";
import {
  computeNodeProblemSchema,
  type ComputeNodeState,
  type HostMaintenanceState,
} from "@comma/native-bridge";

// The local compute card over a scripted node owner and maintenance owner.

const mock = vi.hoisted(() => ({
  state: {} as ComputeNodeState,
  host: {} as HostMaintenanceState,
  canManage: true,
  maintain: vi.fn(),
  resume: vi.fn(),
  abandon: vi.fn(),
  refresh: vi.fn(),
  configure: vi.fn(),
  remove: vi.fn(),
  reset: vi.fn(),
}));
vi.mock("@comma/native-bridge", async (original) => ({
  ...(await original<object>()),
  getNativeBridge: () => bridge,
}));
vi.mock("../activeWorkspace", () => ({
  useActiveWorkspaceId: () => "workspace",
}));
vi.mock("../useComputeNode", async (original) => ({
  ...(await original<object>()),
  useComputeNode: () => ({
    available: true,
    pending: false,
    state: mock.state,
    refresh: mock.refresh,
    abandon: mock.abandon,
    configure: mock.configure,
    remove: mock.remove,
    resetLocalRecord: mock.reset,
  }),
}));
vi.mock("../useComputeWorkloadsSection", () => ({
  useComputeWorkloadsSection: () => ({
    workspaceName: "Workspace A",
    close: vi.fn(),
    canManage: mock.canManage,
    projection: { environments: [], workloads: [], can_manage: mock.canManage },
    rows: [],
    pending: false,
    refresh: vi.fn(),
    openCreate: vi.fn(),
  }),
}));
vi.mock("../useComputeRecoverySection", () => ({
  useComputeRecoverySection: () => ({}),
}));
const installed: HostMaintenanceState = {
  installation: "installed",
  selectedReleaseId: "release",
  updateAvailable: false,
};
const failedRequest = "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa";
const failedUpdate = (failureCode: "host_start_failed"): HostMaintenanceState => ({
  ...installed,
  operation: {
    requestId: failedRequest,
    action: "update",
    dataPolicy: "preserve",
    phase: "failed",
    outcome: "failed",
    failureCode,
  },
});
const bridge = {
  platform: "electron",
  computeNode: {
    state: { subscribe: () => () => {} },
    hostMaintenanceState: async () => mock.host,
    maintainHost: mock.maintain,
    resumeHostMaintenance: mock.resume,
    localOverview: async () => ({ availability: "available", environments: [] }),
  },
};
import { useComputeSettingsController } from "../useComputeSettingsController";
import { ComputeSettingsView } from "../ComputeSettingsView";

function Harness() {
  const controller = useComputeSettingsController(true, true);
  return (
    <>
      <ComputeSettingsView controller={controller} />
      {controller.nodeOverlay}
    </>
  );
}

async function show() {
  render(<Harness />);
  await act(async () => {});
  return within(screen.getByRole("region", { name: "Sandbox" }));
}

/** The card's own buttons, without its links to other pages. */
const cardActions = (card: ReturnType<typeof within>) =>
  card
    .queryAllByRole("button")
    .map((button: HTMLElement) => button.textContent)
    .filter((label: string | null) => label !== "Local settings");

const attention = (patch: Partial<ComputeNodeState>) => {
  mock.state = { ...mock.state, status: "action_required", ...patch };
};

beforeEach(() => {
  mock.canManage = true;
  mock.host = installed;
  mock.state = {
    status: "action_required",
    confirmationId: "session-a",
    desiredEnabled: true,
    observationFresh: true,
    bindingWorkspaceId: "workspace",
    bindingInstallationId: "operation-1",
    bindingRevision: 3,
    revision: 3,
    eligibility: { eligible: true },
    facets: { connection: "disconnected" },
  } as ComputeNodeState;
  mock.refresh.mockImplementation(async () => mock.state);
  mock.configure.mockImplementation(async () => mock.state);
  mock.remove.mockImplementation(async () => mock.state);
  mock.reset.mockImplementation(async () => mock.state);
  mock.maintain.mockResolvedValue(installed);
  mock.abandon.mockResolvedValue(undefined);
});
afterEach(() => {
  vi.clearAllMocks();
});

it.each([
  {
    state: "Not enabled",
    patch: {
      status: "not_set",
      desiredEnabled: false,
      bindingWorkspaceId: undefined,
    },
    actions: ["Enable this Mac"],
  },
  {
    state: "Preparing",
    patch: {
      status: "processing",
      deadlineAt: new Date(Date.now() + 9e5).toISOString(),
    },
    actions: [],
  },
  {
    state: "Available",
    patch: { status: "ready", facets: { connection: "connected" } },
    actions: ["Stop providing compute…", "Disconnect this workspace…"],
  },
  {
    state: "Needs attention",
    patch: { problem: "stop_failed", recoveryActions: ["continue_enable"] },
    actions: ["Retry", "Disconnect this workspace…"],
  },
] as const)("shows one status card for $state", async ({ state, patch, actions }) => {
  mock.state = { ...mock.state, ...patch } as ComputeNodeState;
  const card = await show();
  // One row: no badge, its reason only while it is not available, and the card's actions.
  expect(card.queryByText(state)).toBeNull();
  expect(cardActions(card)).toEqual(actions);
  expect(card.queryAllByRole("status").length > 0).toBe(state === "Preparing");
});

it("sets this Mac up for the workspace without a dialog", async () => {
  mock.state = {
    ...mock.state,
    status: "not_set",
    desiredEnabled: false,
    bindingWorkspaceId: undefined,
  };
  const card = await show();
  await userEvent.click(card.getByRole("button", { name: "Enable this Mac" }));
  expect(screen.queryByRole("dialog")).toBeNull();
  expect(mock.configure).toHaveBeenCalledWith({
    desiredEnabled: true,
    workspaceId: "workspace",
  });
});

it.each([
  { name: "retry budget", patch: { issue: "retry_budget_exhausted" }, action: "Retry" },
  { name: "clock skew", patch: { problem: "clock_skew" }, action: "Retry" },
  {
    name: "identity mismatch",
    patch: { problem: "identity_mismatch" },
    action: "Retry",
  },
] as const)("continues the same setup for $name", async ({ patch, action }) => {
  attention(patch);
  const card = await show();
  expect(cardActions(card)[0]).toBe(action);
  await userEvent.click(card.getByRole("button", { name: action }));
  expect(mock.configure).toHaveBeenCalledWith({
    desiredEnabled: true,
    workspaceId: "workspace",
  });
});

it.each([
  {
    name: "work that an update interrupts",
    patch: { problem: "host_update_interrupts_work" },
    action: "Update and stop work",
    request: { action: "update", dataPolicy: "preserve" },
  },
  {
    name: "a missing capability",
    patch: { issue: "capability_missing" },
    action: "Update Agent VMM",
    request: { action: "update", dataPolicy: "preserve" },
  },
  {
    name: "a local data migration",
    patch: { problem: "local_data_migration" },
    action: "Delete data and reinstall",
    request: { action: "reinstall", dataPolicy: "reset" },
  },
  {
    name: "a Host that cannot start",
    host: failedUpdate("host_start_failed"),
    action: "Delete data and reinstall",
    request: { action: "reinstall", dataPolicy: "reset" },
  },
] as const)("asks Main to maintain the Host for $name", async (row) => {
  if ("patch" in row) attention(row.patch);
  if ("host" in row) mock.host = row.host;
  const card = await show();
  expect(cardActions(card)).toContain(row.action);
  await userEvent.click(card.getByRole("button", { name: row.action }));
  expect(mock.maintain).toHaveBeenCalledWith(row.request);
});

it("offers the confirmed reinstall when the update target is older than the data", async () => {
  attention({ problem: "target_older_than_data" });
  const card = await show();
  expect(cardActions(card)).toContain("Delete data and reinstall");
  expect(cardActions(card)).not.toContain("Keep current version");
});

it("keeps uninstall available while a stuck maintenance request is unfinished", async () => {
  mock.host = {
    ...installed,
    operation: {
      requestId: failedRequest,
      action: "update",
      dataPolicy: "preserve",
      phase: "installing",
      outcome: "pending",
    },
  };
  const card = await show();
  await userEvent.click(card.getByRole("button", { name: "Local settings" }));
  const uninstall = screen.getByRole("button", { name: "Uninstall…" });
  expect(uninstall).toBeEnabled();
  await userEvent.click(uninstall);
  expect(mock.maintain).toHaveBeenCalledWith({
    action: "uninstall",
    dataPolicy: "preserve",
  });
});

it("says once that Main erased the local data and reinstalled", async () => {
  mock.host = {
    ...installed,
    operation: {
      requestId: failedRequest,
      action: "reinstall",
      dataPolicy: "reset",
      phase: "completed",
      outcome: "succeeded",
    },
    automaticReset: true,
  };
  const card = await show();
  expect(
    card.getByText("Local compute data was erased and reinstalled.")
  ).toBeVisible();
});

/** The phase of each maintenance step, in order. */
const steps = () =>
  [...document.querySelectorAll(".compute-steps li")].map((step) =>
    step.getAttribute("data-phase")
  );

it("shows where a failed maintenance stopped, why, and the progress of its retry", async () => {
  const failedReset: HostMaintenanceState = {
    ...installed,
    operation: {
      requestId: failedRequest,
      action: "reinstall",
      dataPolicy: "reset",
      phase: "failed",
      outcome: "failed",
      failedPhase: "stopping",
    },
  };
  const reason =
    "Comma could not stop the components. Select Continue maintenance to try again.";
  mock.host = failedReset;
  let finish!: (state: HostMaintenanceState) => void;
  mock.resume.mockImplementation(
    () =>
      new Promise((resolve) => {
        finish = resolve;
      })
  );
  const card = await show();
  expect(card.getByText(reason)).toBeVisible();
  await userEvent.click(card.getByRole("button", { name: "Local settings" }));
  await userEvent.click(screen.getByRole("button", { name: "View progress" }));
  expect(steps()).toEqual(["ready", "failed", "not_started", "not_started"]);
  expect(screen.getByText(reason)).toBeVisible();
  // The erase warning belongs to the person's confirmation, not to the status of a running or failed request.
  expect(screen.queryByText(/Permanently delete/)).toBeNull();

  await userEvent.click(screen.getByRole("button", { name: "Continue maintenance" }));
  expect(mock.resume).toHaveBeenCalledExactlyOnceWith({ requestId: failedRequest });
  expect(steps()).toEqual(["preparing", "not_started", "not_started", "not_started"]);
  expect(screen.getByRole("button", { name: "Continue maintenance" })).toBeDisabled();

  await act(async () => finish(failedReset));
  expect(steps()).toEqual(["ready", "failed", "not_started", "not_started"]);
  expect(screen.getByText("The new attempt did not succeed.")).toBeVisible();
  expect(screen.getByText(reason)).toBeVisible();
});

it("resets an unreadable local record", async () => {
  attention({
    issue: "local_record_unreadable",
    recoveryActions: ["reset_local_record"],
  });
  const card = await show();
  await userEvent.click(card.getByRole("button", { name: "Reset record" }));
  expect(mock.reset).toHaveBeenCalled();
});

it("removes a revoked registration after confirmation", async () => {
  attention({ issue: "revoked", problem: "registration_revoked" });
  const card = await show();
  expect(cardActions(card)).toEqual(["Remove compute node"]);
  await userEvent.click(card.getByRole("button", { name: "Remove compute node" }));
  await userEvent.click(
    within(screen.getByRole("dialog")).getByRole("button", {
      name: "Remove compute node",
    })
  );
  expect(mock.remove).toHaveBeenCalledWith({
    workspaceId: "workspace",
    installationId: "operation-1",
    confirmationId: "session-a",
    bindingRevision: 3,
  });
});

it("shows a removed node as not enabled, even with a stale revoked issue", async () => {
  mock.state = {
    ...mock.state,
    status: "removed",
    desiredEnabled: false,
    remoteRevocationConfirmed: true,
    bindingWorkspaceId: undefined,
    bindingInstallationId: undefined,
    issue: "revoked",
  };
  const card = await show();
  expect(cardActions(card)).toEqual(["Enable this Mac"]);
  expect(card.queryByText(/workspace admin removed/)).toBeNull();
});

it("shows a local removal whose cloud result is unresolved as not enabled", async () => {
  mock.state = {
    ...mock.state,
    status: "removed",
    desiredEnabled: false,
    remoteRevocationConfirmed: false,
    problem: "remote_revocation_unconfirmed",
    bindingWorkspaceId: undefined,
    bindingInstallationId: undefined,
  };
  const card = await show();
  expect(card.queryByText("Removing")).toBeNull();
  expect(cardActions(card)).toEqual(["Enable this Mac"]);
  await userEvent.click(card.getByRole("button", { name: "Enable this Mac" }));
  expect(mock.configure).toHaveBeenCalledWith({
    desiredEnabled: true,
    workspaceId: "workspace",
  });
});

it("shows a removal in progress as removing", async () => {
  mock.state = {
    ...mock.state,
    status: "processing",
    issue: "removal_incomplete",
    operation: {
      connectionEpoch: "1",
      kind: "remove",
      leaseGeneration: 0,
      operationId: "op",
      outcome: "pending",
      requestId: "req",
      targetRef: "compute-node/local",
      targetRevision: 1,
    },
  };
  const card = await show();
  expect(card.getByText("Removing")).toBeVisible();
  expect(cardActions(card)).toEqual([]);
});

it("offers one Enable again for a connection that is no longer valid", async () => {
  attention({
    issue: "needs_attention",
    problem: "registration_invalid",
    recoveryActions: ["continue_enable", "check_status"],
  });
  const card = await show();
  expect(card.getByText("This Mac's connection is no longer valid.")).toBeVisible();
  // One card action; the page keeps its own Disconnect link.
  expect(cardActions(card)).toEqual(["Enable again", "Disconnect this workspace…"]);
  await userEvent.click(card.getByRole("button", { name: "Enable again" }));
  expect(screen.queryByRole("dialog")).toBeNull();
  expect(mock.configure).toHaveBeenCalledExactlyOnceWith({
    desiredEnabled: true,
    workspaceId: "workspace",
  });
});

it("names the free space a setup needs and opens the compute storage", async () => {
  attention({
    problem: "insufficient_disk",
    diskRequirement: { requiredBytes: 20 * 1024 ** 3, availableBytes: 1024 ** 3 },
  });
  const card = await show();
  expect(card.getByText(/20 GB/)).toBeVisible();
  await userEvent.click(card.getByRole("button", { name: "Manage storage" }));
  expect(screen.getByRole("heading", { level: 1 })).toHaveTextContent(
    "Local compute storage"
  );
});

it("gives only the reason for an unsupported Mac", async () => {
  attention({ issue: "unsupported" });
  const card = await show();
  expect(
    card.getByText("Compute nodes require an Apple silicon Mac and the desktop app.")
  ).toBeVisible();
  expect(cardActions(card)).toEqual(["Disconnect this workspace…"]);
});

it("tells a reader without management permission why there is no node action", async () => {
  mock.canManage = false;
  mock.state = {
    ...mock.state,
    status: "not_set",
    desiredEnabled: false,
    bindingWorkspaceId: undefined,
  };
  const card = await show();
  expect(cardActions(card)).toEqual([]);
  expect(
    card.getByText(
      "You can view the status. Changes need workspace management permission."
    )
  ).toBeVisible();
});

it("closes an install request that was never handed over after confirmation", async () => {
  attention({
    issue: "enable_incomplete",
    recoveryActions: ["continue_enable", "check_status"],
    canAbandonRequest: true,
  });
  const card = await show();
  await userEvent.click(card.getByRole("button", { name: "Close unfinished request" }));
  const dialog = within(screen.getByRole("dialog"));
  await userEvent.click(
    dialog.getByRole("button", { name: "Close unfinished request" })
  );
  expect(mock.abandon).toHaveBeenCalledWith({
    workspaceId: "workspace",
    installationId: "operation-1",
    confirmationId: "session-a",
    bindingRevision: 3,
  });
});

it("offers no request closing when Main does not permit it", async () => {
  attention({ issue: "enable_incomplete" });
  const card = await show();
  expect(card.queryByRole("button", { name: "Close unfinished request" })).toBeNull();
});

it("keeps diagnostics and raw errors off the main card and collapsed in local settings", async () => {
  attention({
    problem: "stop_failed",
    problemDetail: "helper exited with status 70",
    setup: { components: "ready", connection: "failed", shell: "not_initialized" },
  });
  const card = await show();
  expect(
    card.getByText("Disabling did not finish. Check the status, then try again.")
  ).toBeVisible();
  expect(screen.queryByText(/helper exited/)).toBeNull();
  expect(screen.queryByText("Diagnostic details")).toBeNull();
  expect(screen.queryByText("Connect workspace")).toBeNull();
  await userEvent.click(card.getByRole("button", { name: "Local settings" }));
  const details = screen.getByText("Diagnostic details").closest("details")!;
  expect(details).not.toHaveAttribute("open");
  expect(within(details).getByText(/helper exited/)).not.toBeVisible();
});

it("has a message for every problem code Main publishes", async () => {
  const { computeProblemMessage } =
    await vi.importActual<typeof import("../useComputeNode")>("../useComputeNode");
  const { result } = renderHook(() => useCommaMessages());
  const texts = computeNodeProblemSchema.options.map((code) =>
    computeProblemMessage(code, result.current)
  );
  for (const [index, text] of texts.entries()) {
    expect(text).toBeTruthy();
    expect(text).not.toBe(computeNodeProblemSchema.options[index]);
  }
});
