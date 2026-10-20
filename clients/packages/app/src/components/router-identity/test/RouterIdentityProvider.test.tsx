import { CommaI18nProvider } from "@comma/i18n/react";
import { initializeCommaI18n } from "@comma/i18n";
import type { NativeStateBridge, OnboardingWindowState } from "@comma/native-bridge";
import { createScriptedCore, resolvedWorkspace } from "@comma/test-utils/scripted-core";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ChatParticipantStatus } from "@comma/core/chat";
import { ParticipantStatusSlot } from "../../chat/thread/activity/ActivityLine";
import {
  RouterIdentityProvider,
  useRouterIdentity,
  useRouterRenamed,
} from "../RouterIdentityProvider";

/** The core's `router` topic: the Router Agent as read, or nothing while the read waits. */
const routerRead = (name: string) => ({ agent: "agent_router", name });

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

/**
 * The provider over a scripted core: `name` answers each `router` read (none
 * while it is undefined); the core's reads and calls are recorded.
 */
function renderIdentity(name: () => string | undefined, rename = "Atlas") {
  const reads: Record<string, unknown>[] = [];
  const calls: [string, unknown][] = [];
  const core = createScriptedCore({
    values: (topic) => {
      if (topic.topic === "workspace") return resolvedWorkspace("wsp_home");
      const current = topic.topic === "router" ? name() : undefined;
      return current === undefined ? undefined : routerRead(current);
    },
    calls: (call, params) => {
      calls.push([call, params]);
      return null;
    },
    onSubscribe: (topic) => {
      if (topic.topic === "router") reads.push(topic);
    },
  });
  const view = render(
    core.wrap(
      <CommaI18nProvider locale="en">
        <RouterIdentityProvider>
          <RenameButton name={rename} />
          <SettingsRenameButton name="Mira" />
          <ParticipantStatusSlot
            participantStatus={undefined}
            participantStatuses={taskParticipants}
          />
        </RouterIdentityProvider>
      </CommaI18nProvider>
    )
  );
  return { view, reads, calls, core };
}

describe("RouterIdentityProvider", () => {
  beforeEach(() => {
    initializeCommaI18n(["en"]);
  });
  afterEach(() => {
    localStorage.clear();
  });

  it("labels the Router by its stored name and by the name a rename returns", async () => {
    const { reads, calls } = renderIdentity(() => "Juno");

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
    // The core renames the workspace's Router Agent.
    expect(calls).toEqual([
      ["models.renameAgent", { workspace: "wsp_home", name: "Atlas" }],
    ]);
    expect(reads).toHaveLength(1);
  });

  it("shows a Router renamed in Settings at once, without reading it again", async () => {
    const { reads } = renderIdentity(() => "Juno");
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
    expect(reads).toHaveLength(1);
  });

  it("keeps a rename when the initial read resolves after it", async () => {
    // The initial read waits; the rename goes ahead without it.
    const { core } = renderIdentity(() => undefined);
    expect(screen.getByRole("status")).toHaveTextContent(
      "Comma and 2 workers are thinking"
    );

    await userEvent.click(screen.getByRole("button", { name: "Rename" }));
    await waitFor(() =>
      expect(screen.getByRole("status")).toHaveTextContent(
        "Atlas and 2 workers are thinking"
      )
    );
    await act(async () => core.emit("router", routerRead("Default workspace Router")));
    expect(screen.getByRole("status")).toHaveTextContent(
      "Atlas and 2 workers are thinking"
    );
  });

  it("shows the name given in the onboarding window once that window closes", async () => {
    const onboardingWindow = onboardingWindowState();
    installNativeBridgeMock({
      os: "macos",
      platform: "electron",
      onboarding: { window: onboardingWindow.state },
    });
    let routerName = "Default workspace Router";
    const { reads } = renderIdentity(() => routerName);
    await waitFor(() => expect(reads).toHaveLength(1));

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
    // One read more, of the active workspace.
    expect(reads).toEqual([
      { topic: "router", workspace: "wsp_home", read: "0" },
      { topic: "router", workspace: "wsp_home", read: "1" },
    ]);
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
