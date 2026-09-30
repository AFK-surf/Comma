import userEvent from "@testing-library/user-event";
import { render, screen, waitFor } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { afterEach, describe, expect, it, vi } from "vitest";
import type {
  ConnectorRuntimeScopeSnapshot,
  NativeStateBridge,
} from "@comma/native-bridge";
import { writeActiveWorkspaceId } from "../components/activeWorkspace";
import { useCommaConnectorScope } from "../components/useCommaConnectorScope";

const api = {
  listWorkspaces: async () => {
    const response = await fetch("https://api.example/v1/comma/workspaces");
    return (await response.json()).data;
  },
};
function ScopeConsumer() {
  const scope = useCommaConnectorScope(true, api);
  return (
    <input
      type="checkbox"
      role="switch"
      aria-label="Connector scope"
      aria-checked={scope.scope === ""}
      checked={scope.scope === ""}
      disabled={!scope.available || scope.pending}
      onChange={(event) =>
        void scope.setScope(event.target.checked ? "" : "local_file_read")
      }
    />
  );
}
const renderScope = () => render(<ScopeConsumer />);
function createConnectorRuntimeState(initial: ConnectorRuntimeScopeSnapshot) {
  let current = initial;
  const listeners = new Set<(snapshot: ConnectorRuntimeScopeSnapshot) => void>();
  const get = vi.fn(async () => current);
  const state = Object.assign(get, {
    get,
    subscribe: vi.fn((listener: (snapshot: ConnectorRuntimeScopeSnapshot) => void) => {
      listeners.add(listener);
      queueMicrotask(() => listener(current));
      return () => listeners.delete(listener);
    }),
  }) as NativeStateBridge<ConnectorRuntimeScopeSnapshot>;

  return {
    emit(next: ConnectorRuntimeScopeSnapshot) {
      current = next;
      for (const listener of listeners) listener(next);
    },
    state,
  };
}

function installWorkspaceList(workspaceIds: readonly string[]) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(input.toString(), "https://api.example");
      if (url.pathname !== "/v1/comma/workspaces") {
        throw new Error(`Unexpected request: ${url.pathname}`);
      }
      return new Response(
        JSON.stringify({
          data: workspaceIds.map((id, index) => ({
            group_id: `grp-${index + 1}`,
            id,
            name: `Workspace ${index + 1}`,
          })),
        }),
        { headers: { "content-type": "application/json" }, status: 200 }
      );
    })
  );
}

describe("useCommaConnectorScope", () => {
  afterEach(() => vi.unstubAllGlobals());
  it("changes Connector scope for only the explicit active workspace", async () => {
    writeActiveWorkspaceId("wsp_settings");
    installWorkspaceList(["wsp_settings"]);
    const connectorState = createConnectorRuntimeState({
      revision: 1,
      scopes: [
        {
          available: true,
          scope: "",
          workspaceId: "wsp_settings",
        },
      ],
    });
    const scope = vi.fn(async () => ({
      available: true,
      scope: "" as const,
      workspaceId: "wsp_settings",
    }));
    const setScope = vi.fn(async () => {
      connectorState.emit({
        revision: 2,
        scopes: [
          {
            available: true,
            scope: "local_file_read",
            workspaceId: "wsp_settings",
          },
        ],
      });
      return {
        available: true,
        scope: "local_file_read" as const,
        workspaceId: "wsp_settings",
      };
    });
    installNativeBridgeMock({
      connectorRuntime: { scope, setScope, state: connectorState.state },
      platform: "electron",
    });
    renderScope();

    const toggle = screen.getByRole("switch", { name: "Connector scope" });
    await waitFor(() => expect(toggle).toBeEnabled());
    expect(toggle).toBeChecked();
    await userEvent.click(toggle);

    await waitFor(() =>
      expect(setScope).toHaveBeenCalledWith({
        scope: "local_file_read",
        workspaceId: "wsp_settings",
      })
    );
    await waitFor(() => expect(toggle).not.toBeChecked());
  });

  it("applies a newer runtime-pushed restricted scope", async () => {
    writeActiveWorkspaceId("wsp_restart");
    installWorkspaceList(["wsp_restart"]);
    const connectorState = createConnectorRuntimeState({
      revision: 1,
      scopes: [
        {
          available: true,
          scope: "",
          workspaceId: "wsp_restart",
        },
      ],
    });
    const scope = vi.fn(async () => ({
      available: true,
      scope: "" as const,
      workspaceId: "wsp_restart",
    }));
    installNativeBridgeMock({
      connectorRuntime: {
        scope,
        setScope: vi.fn(),
        state: connectorState.state,
      },
      platform: "electron",
    });
    renderScope();

    const toggle = screen.getByRole("switch", { name: "Connector scope" });
    await waitFor(() => expect(toggle).toBeChecked());
    connectorState.emit({
      revision: 2,
      scopes: [
        {
          available: true,
          scope: "local_file_read",
          workspaceId: "wsp_restart",
        },
      ],
    });

    await waitFor(() => expect(toggle).not.toBeChecked());
    connectorState.emit({
      revision: 1,
      scopes: [
        {
          available: true,
          scope: "",
          workspaceId: "wsp_restart",
        },
      ],
    });
    await Promise.resolve();
    expect(toggle).not.toBeChecked();
    expect(scope).toHaveBeenCalledTimes(1);
  });

  it("validates a stale persisted workspace before starting its Connector", async () => {
    writeActiveWorkspaceId("wsp_deleted");
    installWorkspaceList(["wsp_live"]);
    const connectorState = createConnectorRuntimeState({
      revision: 1,
      scopes: [
        {
          available: true,
          scope: "local_file_read",
          workspaceId: "wsp_live",
        },
      ],
    });
    const scope = vi.fn(async ({ workspaceId }: { workspaceId: string }) => ({
      available: true,
      scope: "local_file_read" as const,
      workspaceId,
    }));
    installNativeBridgeMock({
      connectorRuntime: {
        scope,
        setScope: vi.fn(),
        state: connectorState.state,
      },
      platform: "electron",
    });

    renderScope();

    await waitFor(() =>
      expect(screen.getByRole("switch", { name: "Connector scope" })).toBeEnabled()
    );
    expect(scope).toHaveBeenCalledWith({ workspaceId: "wsp_live" });
    expect(scope).not.toHaveBeenCalledWith({ workspaceId: "wsp_deleted" });
    expect(localStorage.getItem("comma.activeWorkspaceId")).toBe("wsp_live");
  });
});
