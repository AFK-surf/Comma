import userEvent from "@testing-library/user-event";
import type { ResolvedWorkspace } from "@comma/core/contract";
import { flush } from "@comma/test-utils/fake-clock";
import { act, render, screen } from "@comma/test-utils/render";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, describe, expect, it, vi } from "vitest";
import type {
  ConnectorRuntimeScopeSnapshot,
  NativeStateBridge,
} from "@comma/native-bridge";
import { useCommaConnectorScope } from "../components/useCommaConnectorScope";

function ScopeConsumer() {
  const scope = useCommaConnectorScope(true);
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
/**
 * Renders the hook over a core that answers the workspace the app works in with `workspaceId` (`selected`: whether
 * the user ever selected one; the core falls back to the first when the selected one is gone,
 * core/test/workspace.test.ts).
 */
function renderScope(workspaceId: string, selected = true) {
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "workspace"
        ? ({
            status: "ready",
            workspace: { id: workspaceId, groupId: "grp-1", name: "Workspace 1" },
            selected,
          } satisfies ResolvedWorkspace)
        : undefined,
  });
  render(core.wrap(<ScopeConsumer />));
}
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

describe("useCommaConnectorScope", () => {
  afterEach(() => vi.unstubAllGlobals());
  it("changes Connector scope for only the explicit active workspace", async () => {
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
    renderScope("wsp_settings");
    await flush();

    const toggle = screen.getByRole("switch", { name: "Connector scope" });
    expect(toggle).toBeEnabled();
    expect(toggle).toBeChecked();
    await userEvent.setup({ advanceTimers: vi.advanceTimersByTime }).click(toggle);
    await flush();

    expect(setScope).toHaveBeenCalledWith({
      scope: "local_file_read",
      workspaceId: "wsp_settings",
    });
    expect(toggle).not.toBeChecked();
  });

  it("applies a newer runtime-pushed restricted scope", async () => {
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
    renderScope("wsp_restart");
    await flush();

    const toggle = screen.getByRole("switch", { name: "Connector scope" });
    expect(toggle).toBeChecked();
    act(() =>
      connectorState.emit({
        revision: 2,
        scopes: [
          {
            available: true,
            scope: "local_file_read",
            workspaceId: "wsp_restart",
          },
        ],
      })
    );
    await flush();

    expect(toggle).not.toBeChecked();
    act(() =>
      connectorState.emit({
        revision: 1,
        scopes: [
          {
            available: true,
            scope: "",
            workspaceId: "wsp_restart",
          },
        ],
      })
    );
    await flush();
    expect(toggle).not.toBeChecked();
    expect(scope).toHaveBeenCalledTimes(1);
  });

  it("starts no Connector before the user selected a workspace", async () => {
    const scope = vi.fn();
    installNativeBridgeMock({
      connectorRuntime: {
        scope,
        setScope: vi.fn(),
        state: createConnectorRuntimeState({ revision: 1, scopes: [] }).state,
      },
      platform: "electron",
    });

    renderScope("wsp_first", false);
    await flush();

    expect(screen.getByRole("switch", { name: "Connector scope" })).toBeDisabled();
    expect(scope).not.toHaveBeenCalled();
  });
});
