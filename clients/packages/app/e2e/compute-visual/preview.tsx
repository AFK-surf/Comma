import { createRoot } from "react-dom/client";
import { CommaI18nProvider } from "@comma/i18n/react";
import {
  getNativeBridge,
  type ComputeNodeState,
  type HostMaintenanceState,
} from "@comma/native-bridge";
import { SettingsPage, createSettingsRegistry } from "@comma/ui/components/settings";
import { useDeviceSettingsCategory } from "../../src/components/devices/useDeviceSettingsCategory";
import {
  createRouter,
  createRootRoute,
  createMemoryHistory,
  RouterProvider,
} from "@tanstack/react-router";
import { CoreClient, CoreProvider } from "@comma/core-client";
import type { ComputeWorkload as CommaComputeWorkload } from "@comma/core/contract";
import "@comma/ui/styles.css";
import "../../src/styles.css";

// Browser-only fixture. Production entry points do not import it or set this bridge.
const params = new URLSearchParams(location.search);
const scene = params.get("scene") ?? "ready";
const workspace = "workspace-visual";
const listeners = new Set<(state: ComputeNodeState) => void>();
let state: ComputeNodeState = {
  status: "ready",
  desiredEnabled: true,
  confirmationId: "visual-session",
  bindingWorkspaceId: workspace,
  bindingInstallationId: "visual-host",
  bindingRevision: 1,
  revision: 1,
  eligibility: { eligible: true },
  observationFresh: true,
  observedAt: "2026-10-05T13:00:00Z",
  setup: { components: "ready", connection: "ready", shell: "ready" },
  observed: {
    connector: "ready",
    host: "ready",
    readability: "readable",
    salix: "ready",
  },
  facets: {
    admission: "accepting",
    connection: "connected",
    installationHealth: "healthy",
    runtimeReadiness: "ready",
    workActivity: "idle",
  },
};
if (["new", "no-node", "retained"].includes(scene))
  state = {
    ...state,
    status: "not_set",
    desiredEnabled: false,
    bindingWorkspaceId: undefined,
    setup: {
      components: "not_started",
      connection: "not_started",
      shell: "not_initialized",
    },
    facets: { ...state.facets, connection: "disconnected" },
  };
if (scene === "removal-incomplete")
  state = {
    ...state,
    status: "action_required",
    desiredEnabled: false,
    issue: "removal_incomplete",
    recoveryActions: ["finish_remove", "check_status"],
    observationFresh: false,
    facets: { ...state.facets, connection: "disconnected" },
  };
if (scene === "offline")
  state = {
    ...state,
    status: "action_required",
    issue: "connection",
    observationFresh: false,
    facets: { ...state.facets, connection: "disconnected" },
  };
if (scene === "authorization")
  state = {
    ...state,
    status: "action_required",
    issue: "authorization_unavailable",
    observationFresh: false,
  };
if (scene === "shell-failed")
  state = {
    ...state,
    status: "action_required",
    issue: "shell_initialization_pending",
    recoveryActions: ["continue_shell"],
    setup: { components: "ready", connection: "ready", shell: "failed" },
  };
if (scene === "setup")
  state = {
    ...state,
    status: "processing",
    observationFresh: false,
    setup: { components: "ready", connection: "connecting", shell: "not_initialized" },
    operation: {
      requestId: "setup-visual",
      operationId: "setup-visual",
      connectionEpoch: "one",
      kind: "configure",
      leaseGeneration: 1,
      outcome: "pending",
      targetRef: workspace,
      targetRevision: 1,
    },
    facets: { ...state.facets, connection: "connecting" },
  };
let host: HostMaintenanceState = {
  installation: scene === "retained" ? "not_installed" : "installed",
  installedReleaseId: "agent-vmm-installed",
  selectedReleaseId: "agent-vmm-selected",
  updateAvailable: true,
};
if (scene === "maintenance-failed")
  host = {
    ...host,
    operation: {
      requestId: "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
      action: "reinstall",
      dataPolicy: "preserve",
      phase: "installing",
      outcome: "failed",
      problem: "Download interrupted. Local files have been kept.",
    },
  };
if (scene === "maintenance-active")
  host = {
    ...host,
    operation: {
      requestId: "bbbbbbbb-bbbb-4bbb-abbb-bbbbbbbbbbbb",
      action: "reinstall",
      dataPolicy: "preserve",
      phase: "installing",
      outcome: "pending",
    },
  };
const publish = () => {
  state = { ...state, revision: state.revision + 1 };
  listeners.forEach((fn) => fn(state));
  return state;
};
const bridge = getNativeBridge();
Object.defineProperty(globalThis, "commaNative", {
  value: {
    ...bridge,
    platform: scene === "browser" ? "web" : "electron",
    connectorRuntime: {
      ...bridge.connectorRuntime,
      scope: async () => ({
        workspaceId: workspace,
        available: true,
        scope: "",
        deviceId: "device-visual",
      }),
      state: {
        get: async () => ({
          revision: 1,
          scopes: [
            {
              workspaceId: workspace,
              available: true,
              scope: "",
              deviceId: "device-visual",
            },
          ],
        }),
        snapshot: () => undefined,
        subscribe: (listener: (s: unknown) => void) => {
          listener({
            revision: 1,
            scopes: [
              {
                workspaceId: workspace,
                available: true,
                scope: "",
                deviceId: "device-visual",
              },
            ],
          });
          return () => {};
        },
      },
    },
    computeNode: {
      ...bridge.computeNode,
      state: {
        get: async () => state,
        snapshot: () => state,
        subscribe: (listener: (s: ComputeNodeState) => void) => {
          listeners.add(listener);
          listener(state);
          return () => listeners.delete(listener);
        },
      },
      refresh: async () => {
        document.documentElement.dataset.refreshCount = String(
          Number(document.documentElement.dataset.refreshCount || 0) + 1
        );
        return state;
      },
      configure: async () => {
        document.documentElement.dataset.configureCount = String(
          Number(document.documentElement.dataset.configureCount || 0) + 1
        );
        state = {
          ...state,
          status: "processing",
          setup: {
            components: "preparing",
            connection: "not_started",
            shell: "not_initialized",
          },
        };
        return publish();
      },
      repair: async () => {
        document.documentElement.dataset.repairCount = String(
          Number(document.documentElement.dataset.repairCount || 0) + 1
        );
        return state;
      },
      drain: async () => {
        state = { ...state, status: "stopped", desiredEnabled: false };
        return publish();
      },
      remove: async () => {
        if (scene === "removal-incomplete") {
          throw new Error("operation failure requires operator action");
        }
        return state;
      },
      hostMaintenanceState: async () => host,
      maintainHost: async (input: {
        action: "update" | "reinstall" | "uninstall";
        dataPolicy: "preserve" | "reset";
      }) => {
        host = {
          ...host,
          operation: {
            ...input,
            requestId: crypto.randomUUID(),
            phase: "installing",
            outcome: "pending",
          },
        };
        return host;
      },
      resumeHostMaintenance: async () => host,
      localOverview: async () => ({
        availability: "available",
        collectedAt: "2026-10-05T13:00:00Z",
        disk: {
          usedBytes: "9019431321",
          capacityBytes: "68719476736",
          importReservationBytes: "0",
        },
        environments: [
          {
            key: "local-visual",
            label: "Default workspace",
            origin: "local",
            state: "observed_active",
            privateDiskBytes: "805306368",
            sampledAt: "2026-10-05T13:00:00Z",
            canReadWorkloads: true,
            canOperate: true,
            canDisposeLocal: false,
          },
          {
            key: "local-other",
            label: "BFT",
            origin: "remote",
            state: "unknown",
            privateDiskBytes: "2791728742",
            sampledAt: "2026-10-05T13:00:00Z",
            canReadWorkloads: false,
            canOperate: false,
            canDisposeLocal: true,
          },
        ],
      }),
      localWorkloads: async () => ({
        workloads: [{ label: "Default Shell", state: "ready" }],
      }),
      recoveryCandidates: async () => {
        if (params.get("recovery") === "failed")
          throw Object.assign(new Error("Recovery proof failed"), {
            bridgeError: { code: "COMPUTE_RECOVERY_UNVERIFIED" },
          });
        return {
          confirmationId: "visual-session",
          candidates:
            params.get("recovery") === "none"
              ? []
              : [
                  {
                    key: "visual-host",
                    label: "Mac",
                    machine: "MacBook Pro",
                    workspaceId: workspace,
                    endpoint: "https://salix.example.test",
                  },
                ],
        };
      },
      recover: async () => {
        state = { ...state, status: "ready", issue: undefined };
        return publish();
      },
    },
  },
});
const policy = {
  image: "shell.default",
  command: ["sh"],
  egress_mode: "deny_all",
  resources: { pid_max: 512, writable_quota_bytes: 2147483648 },
};
let rows: CommaComputeWorkload[] = [
  {
    id: "workload-default",
    name: "Default Shell",
    environment_id: "environment-visual",
    kind: "shell",
    observed_state: "ready",
    desired_state: "ready",
    phase:
      scene === "shell-failed"
        ? "action_required"
        : scene === "offline"
          ? "waiting_connection"
          : "ready",
    revision: 1,
    generation: 1,
    location: { provider: "agent_vmm" },
    actions: {
      rename: scene !== "readonly",
      delete: scene !== "readonly",
      retry: scene === "shell-failed",
    },
    runtime_policy: policy,
  },
  {
    id: "workload-service",
    name: "Weekly report",
    environment_id: "environment-visual",
    kind: "service",
    observed_state: "ready",
    phase: "ready",
    revision: 1,
    generation: 1,
    location: { provider: "agent_vmm" },
    actions: { rename: false, delete: false },
    uses: [{ kind: "service", id: "service-report", label: "Weekly report service" }],
    runtime_policy: policy,
  },
];
if (scene === "deletion-offline")
  rows[0] = {
    ...rows[0]!,
    phase: "waiting_connection",
    desired_state: "draining",
    deletion: {
      phase: "cleaning",
      request_id: "original-delete",
      error: "original_device_offline",
    },
    actions: { rename: true, delete: false, retry: false },
  };
if (scene === "cloud-retired")
  rows[0] = {
    ...rows[0]!,
    phase: "cloud_retired",
    desired_state: "stopped",
    deletion: { phase: "cloud_retired", request_id: "retired-original" },
    actions: { rename: true, delete: false, retry: false },
  };
if (["new", "no-node", "retained", "setup"].includes(scene)) rows = [];
const projection = () => ({
  workspace_name: "Default workspace",
  can_manage: scene !== "readonly",
  environments: [
    {
      id: "environment-visual",
      desired_state: state.desiredEnabled ? "ready" : "stopped",
      observed_state: "ready",
      can_create: ![
        "new",
        "no-node",
        "offline",
        "authorization",
        "readonly",
        "retained",
      ].includes(scene),
      create_unavailable_reason: ["new", "no-node", "retained"].includes(scene)
        ? "node_not_enabled"
        : "node_unavailable",
    },
  ],
  workloads: rows,
});
// What the core would answer: Compute from `rows`, and its calls change them.
const workloadCalls: Record<
  string,
  (p: Record<string, unknown>) => CommaComputeWorkload
> = {
  "compute.retry": (p) => {
    document.documentElement.dataset.retryRequest = JSON.stringify(p);
    rows = rows.map((row) =>
      row.id === p.id
        ? {
            ...row,
            phase: "ready",
            revision: row.revision! + 1,
            actions: {
              rename: row.actions?.rename ?? false,
              delete: row.actions?.delete ?? false,
              retry: false,
            },
          }
        : row
    );
    return rows.find((row) => row.id === p.id)!;
  },
  "compute.workload": (p) => rows.find((row) => row.id === p.id)!,
  "compute.create": (p) => {
    const row = {
      ...rows[0],
      id: "created-shell",
      name: p.name,
      environment_id: "environment-visual",
      kind: "shell",
      observed_state: "pending",
      phase: "starting",
      revision: 1,
      generation: 1,
    } as CommaComputeWorkload;
    rows.push(row);
    return row;
  },
  "compute.rename": (p) => {
    rows = rows.map((row) =>
      row.id === p.id
        ? { ...row, name: String(p.name), revision: row.revision! + 1 }
        : row
    );
    return rows.find((row) => row.id === p.id)!;
  },
  "compute.delete": (p) => {
    rows = rows.map((row) =>
      row.id === p.id
        ? {
            ...row,
            deletion: { phase: "waiting_connection", request_id: "delete-visual" },
            revision: row.revision! + 1,
          }
        : row
    );
    return rows.find((row) => row.id === p.id)!;
  },
};
const computeSubscribers = new Set<number>();
let deliver: ((data: unknown) => void) | undefined;
const sendCompute = () => {
  for (const id of computeSubscribers)
    deliver?.({
      id,
      value: {
        workspace,
        projection: projection(),
        error: false,
        creation: null,
        accepted: null,
      },
    });
};
const core = new CoreClient(
  (onMessage) => {
    deliver = (data) => queueMicrotask(() => onMessage(structuredClone(data)));
    return {
      post(raw) {
        const message = raw as {
          id: number;
          call?: string;
          params?: Record<string, unknown>;
          subscribe?: { topic: string };
          unsubscribe?: boolean;
        };
        if (message.subscribe?.topic === "compute") {
          computeSubscribers.add(message.id);
          sendCompute();
        } else if (message.subscribe?.topic === "workspace") {
          deliver?.({
            id: message.id,
            // The workspace the user selected: its Connector runs.
            value: {
              status: "ready",
              workspace: {
                id: workspace,
                groupId: "group-visual",
                name: "Default workspace",
              },
              selected: true,
            },
          });
        } else if (message.subscribe?.topic === "devices") {
          deliver?.({
            id: message.id,
            value: {
              workspace,
              loading: false,
              failed: false,
              hasMore: false,
              checks: {},
              cloud: null,
              devices: [
                {
                  device_id: "device-visual",
                  name: "Studio Mac",
                  status: "connected",
                  allows_operations: true,
                  os: "darwin",
                  system_info: {
                    cpu_model: "Apple M5 Max",
                    memory_total: 137438953472,
                    client_source: "comma_staging",
                  },
                  device_runtimes: [
                    {
                      device_runtime_id: "codex-visual",
                      provider: "codex",
                      status: "ready",
                      fresh: true,
                      version: "1.0",
                      auth: { mode: "chatgpt" },
                    },
                  ],
                },
              ],
            },
          });
        } else if (message.unsubscribe) computeSubscribers.delete(message.id);
        else if (message.call) {
          const run = workloadCalls[message.call];
          const ok = run ? run(message.params ?? {}) : null;
          deliver?.({ id: message.id, ok });
          sendCompute();
        }
      },
      close() {
        deliver = undefined;
      },
    };
  },
  { schedule: () => undefined }
);
function Preview() {
  const category = useDeviceSettingsCategory(true);
  return (
    <SettingsPage
      activeCategoryId="devices"
      registry={createSettingsRegistry({
        groups: [{ id: "settings", label: "Settings", categories: [category] }],
      })}
      searchAriaLabel="Search"
      searchPlaceholder="Search settings"
    />
  );
}
const router = createRouter({
  routeTree: createRootRoute({ component: Preview }),
  history: createMemoryHistory({ initialEntries: ["/"] }),
});
createRoot(document.getElementById("root")!).render(
  <CommaI18nProvider locale={params.get("locale") === "en" ? "en" : "zh-CN"}>
    <CoreProvider client={core}>
      <div style={{ height: "100vh", maxWidth: 1100, margin: "auto" }}>
        <RouterProvider router={router} />
      </div>
    </CoreProvider>
  </CommaI18nProvider>
);
