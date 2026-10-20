import type { ConnectorRuntimeScopeSnapshot } from "@comma/native-bridge";
import {
  createNativeStateBridgeMock,
  installNativeBridgeMock,
} from "@comma/test-utils/native-bridge";
import { render, waitFor } from "@comma/test-utils/render";
import { expect, it, vi } from "vitest";
import { createScriptedCore, resolvedWorkspace } from "@comma/test-utils/scripted-core";
import { CommaConnectorRuntimeOwner } from "../useCommaConnectorScope";

it("keeps the active workspace Connector alive outside Settings", async () => {
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
  // The core answers the workspace the user selected.
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "workspace" ? resolvedWorkspace("wsp_active") : undefined,
  });

  render(core.wrap(<CommaConnectorRuntimeOwner />));

  await waitFor(() =>
    expect(scope).toHaveBeenCalledWith({ workspaceId: "wsp_active" })
  );
});
