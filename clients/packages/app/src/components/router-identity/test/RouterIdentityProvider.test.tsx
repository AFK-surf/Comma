import { CommaI18nProvider } from "@comma/i18n/react";
import { initializeCommaI18n } from "@comma/i18n";
import type { NativeStateBridge, OnboardingWindowState } from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { CommaApiClient } from "../../../api";
import type { AgentModels } from "../../../api/modelCatalog";
import { writeActiveWorkspaceId } from "../../activeWorkspace";
import { CommaAuthContext, type CommaAuthContextValue } from "../../auth-context";
import type { ChatParticipantStatus } from "../../chat/model/conversationChannel";
import { ParticipantStatusSlot } from "../../chat/thread/activity/ActivityLine";
import {
  RouterIdentityProvider,
  useRouterIdentity,
  useRouterRenamed,
} from "../RouterIdentityProvider";

const routerModel = (name: string) => ({
  agent_id: "agent_router",
  name,
  role: "router" as const,
});

const agentModels = (routerName: string): AgentModels => ({
  workspace_id: "wsp_home",
  agents: { router: routerModel(routerName) },
  workers: { items: [], next_cursor: null },
});

// Task Participants keep the Agent name from when they joined the Task.
const participant = (
  participantId: string,
  actorRole: "router" | "worker",
  name: string
): ChatParticipantStatus => ({
  conversationId: "task_1",
  participantId,
  actorId: `actor_${participantId}`,
  actorRole,
  name,
  state: "active",
  status: "is thinking...",
  updatedAt: 1,
});
const taskParticipants = [
  participant("router", "router", "Default workspace Router"),
  participant("worker_1", "worker", "Designer"),
  participant("worker_2", "worker", "Reviewer"),
];

function RenameButton({ name }: { name: string }) {
  const { setRouterName } = useRouterIdentity();
  return (
    <button type="button" onClick={() => void setRouterName(name)}>
      Rename
    </button>
  );
}

/** Agent models in Settings, which rename the Router through their own request. */
function SettingsRenameButton({ name }: { name: string }) {
  const routerRenamed = useRouterRenamed();
  return (
    <button type="button" onClick={() => routerRenamed(name, "wsp_home")}>
      Rename in Settings
    </button>
  );
}

function renderIdentity(
  api: Partial<CommaApiClient>,
  rename = "Atlas",
  workspaceId?: string
) {
  const auth = { api } as unknown as CommaAuthContextValue;
  return render(
    <CommaI18nProvider locale="en">
      <CommaAuthContext.Provider value={auth}>
        <RouterIdentityProvider {...(workspaceId ? { workspaceId } : {})}>
          <RenameButton name={rename} />
          <SettingsRenameButton name="Mira" />
          <ParticipantStatusSlot
            participantStatus={undefined}
            participantStatuses={taskParticipants}
          />
        </RouterIdentityProvider>
      </CommaAuthContext.Provider>
    </CommaI18nProvider>
  );
}

describe("RouterIdentityProvider", () => {
  beforeEach(() => {
    initializeCommaI18n(["en"]);
    writeActiveWorkspaceId("wsp_home");
  });
  afterEach(() => {
    localStorage.clear();
  });

  it("labels the Router by its stored name and by the name a rename returns", async () => {
    const getAgentModels = vi.fn(async () => agentModels("Juno"));
    const renameAgent = vi.fn(async () => undefined);
    renderIdentity({ getAgentModels, renameAgent });

    // The stored name replaces the Task Participant's joining snapshot.
    await waitFor(() =>
      expect(screen.getByRole("status")).toHaveTextContent(
        "Juno and 2 workers are thinking"
      )
    );

    await userEvent.click(screen.getByRole("button", { name: "Rename" }));
    await waitFor(() =>
      expect(screen.getByRole("status")).toHaveTextContent(
        "Atlas and 2 workers are thinking"
      )
    );
    // The Router is renamed as its Agent, by the id its read gave.
    expect(renameAgent).toHaveBeenCalledWith("wsp_home", "agent_router", "Atlas");
    expect(getAgentModels).toHaveBeenCalledTimes(1);
  });

  it("shows a Router renamed in Settings at once, without reading it again", async () => {
    const getAgentModels = vi.fn(async () => agentModels("Juno"));
    renderIdentity({ getAgentModels });
    await waitFor(() =>
      expect(screen.getByRole("status")).toHaveTextContent(
        "Juno and 2 workers are thinking"
      )
    );

    await userEvent.click(screen.getByRole("button", { name: "Rename in Settings" }));
    await waitFor(() =>
      expect(screen.getByRole("status")).toHaveTextContent(
        "Mira and 2 workers are thinking"
      )
    );
    expect(getAgentModels).toHaveBeenCalledOnce();
  });

  it("keeps a rename when the initial read resolves after it", async () => {
    let resolveRead!: (models: AgentModels) => void;
    // The initial read hangs; the rename reads the Router's Agent id itself.
    const getAgentModels = vi
      .fn<() => Promise<AgentModels>>()
      .mockImplementationOnce(
        () => new Promise<AgentModels>((resolve) => (resolveRead = resolve))
      )
      .mockResolvedValue(agentModels("Default workspace Router"));
    const renameAgent = vi.fn(async () => undefined);
    renderIdentity({ getAgentModels, renameAgent });
    expect(screen.getByRole("status")).toHaveTextContent(
      "Comma and 2 workers are thinking"
    );

    await userEvent.click(screen.getByRole("button", { name: "Rename" }));
    await waitFor(() =>
      expect(screen.getByRole("status")).toHaveTextContent(
        "Atlas and 2 workers are thinking"
      )
    );
    resolveRead(agentModels("Default workspace Router"));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(screen.getByRole("status")).toHaveTextContent(
      "Atlas and 2 workers are thinking"
    );
  });

  it("shows the name given in the onboarding window once that window closes", async () => {
    // A Side Chat Task window, bound to its Task's workspace.
    const onboardingWindow = onboardingWindowState();
    installNativeBridgeMock({
      os: "macos",
      platform: "electron",
      onboarding: { window: onboardingWindow.state },
    });
    let routerName = "Default workspace Router";
    const getAgentModels = vi.fn(async () => agentModels(routerName));
    renderIdentity({ getAgentModels }, "Atlas", "wsp_home");
    await waitFor(() => expect(getAgentModels).toHaveBeenCalledOnce());

    // The onboarding opens over the display and names the Router there.
    onboardingWindow.publish({ open: true });
    routerName = "Atlas";
    expect(screen.getByRole("status")).toHaveTextContent(
      "Comma and 2 workers are thinking"
    );

    onboardingWindow.publish({ open: false });
    await waitFor(() =>
      expect(screen.getByRole("status")).toHaveTextContent(
        "Atlas and 2 workers are thinking"
      )
    );
    expect(getAgentModels).toHaveBeenCalledTimes(2);
    expect(getAgentModels).toHaveBeenLastCalledWith("wsp_home", expect.anything());
  });
});

/** Main's onboarding window state, published by the test and replayed to each subscriber. */
function onboardingWindowState() {
  let current: OnboardingWindowState = { open: false };
  const listeners = new Set<(snapshot: OnboardingWindowState) => void>();
  const get = vi.fn(async () => current);
  const state = Object.assign(get, {
    get,
    subscribe: (listener: (snapshot: OnboardingWindowState) => void) => {
      listeners.add(listener);
      void get().then(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  }) as unknown as NativeStateBridge<OnboardingWindowState>;
  return {
    state,
    publish: (next: OnboardingWindowState) => {
      current = next;
      act(() => {
        for (const listener of listeners) listener(next);
      });
    },
  };
}
