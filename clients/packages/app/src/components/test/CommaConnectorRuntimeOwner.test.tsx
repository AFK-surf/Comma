import type { ConnectorRuntimeScopeSnapshot } from "@comma/native-bridge";
import {
  createNativeStateBridgeMock,
  installNativeBridgeMock,
} from "@comma/test-utils/native-bridge";
import { render, waitFor } from "@comma/test-utils/render";
import { afterEach, expect, it, vi } from "vitest";
import type { CommaApiClient } from "../../api";
import { writeActiveWorkspaceId } from "../activeWorkspace";
import { CommaConnectorRuntimeOwner } from "../useCommaConnectorScope";

afterEach(() => {
  localStorage.clear();
});

it("keeps the active workspace Connector alive outside Settings", async () => {
  writeActiveWorkspaceId("wsp_active");
  const snapshot: ConnectorRuntimeScopeSnapshot = {
    revision: 1,
    scopes: [
      {
        available: true,
        scope: "local_file_read",
        workspaceId: "wsp_active",
      },
    ],
  };
  const scope = vi.fn(async () => snapshot.scopes[0]!);
  installNativeBridgeMock({
    connectorRuntime: {
      scope,
      setScope: vi.fn(),
      state: createNativeStateBridgeMock(() => snapshot),
    },
    platform: "electron",
  });
  const api: Pick<CommaApiClient, "listWorkspaces"> = {
    listWorkspaces: vi.fn(async () => [
      {
        group_id: "grp_active",
        id: "wsp_active",
        name: "Active Workspace",
      },
    ]),
  };

  render(<CommaConnectorRuntimeOwner api={api} />);

  await waitFor(() =>
    expect(scope).toHaveBeenCalledWith({ workspaceId: "wsp_active" })
  );
});
