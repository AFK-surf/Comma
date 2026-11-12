import { render, screen, waitFor, fireEvent, act } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { it, expect } from "vitest";
import { renderHook } from "@testing-library/react";
import { CommaI18nProvider } from "@comma/i18n/react";
import { initializeCommaI18n } from "@comma/i18n";
import { AgentBrowserPanel, AgentBrowserTrigger } from "../AgentBrowserPanel";
import { useSessionBrowser } from "../useSessionBrowser";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import type { ReactNode } from "react";

const frame = (seq: number) => ({ seq, data: "", width: 1280, height: 720 });

const text = () =>
  screen.queryByRole("textbox", { name: "Text to type in the browser" });

it("offers text input only under takeover and stops its stream when unmounted", async () => {
  const binding = {
    agent_id: "agent",
    session_id: "session",
    status: "ready",
    control: "agent" as const,
    busy: false,
    updated_at: "2026-09-28T00:00:00.000000Z",
  };
  // What the core streams of the browser; the test moves it on as the core would.
  let view: Record<string, unknown> = {
    tabs: [{ tab_id: "tab", title: "Test page", url: "https://example.com" }],
    tab: "tab",
    status: "agent",
    controlling: false,
    error: null,
    pending: false,
    frame: null,
  };
  const unsubscribed: Record<string, unknown>[] = [];
  const core = createScriptedCore({
    values: (topic) => (topic.topic === "browserView" ? view : undefined),
    calls: (name) => (name === "browserView.command" ? { closed: false } : null),
    onUnsubscribe: (topic) => unsubscribed.push(topic),
  });
  const { unmount } = render(
    core.wrap(
      <AgentBrowserPanel
        workspaceId="workspace"
        id="browser-panel"
        binding={binding}
        onRefresh={() => {}}
      />
    )
  );
  await screen.findByText("Test page");
  expect(text()).toBeNull();
  await userEvent.click(screen.getByRole("button", { name: "Take control" }));
  const [taken] = core.sentTo("browserView.command") as Record<string, unknown>[];
  expect(taken).toMatchObject({
    workspace: "workspace",
    agent: "agent",
    session: "session",
    operation: "take_control",
  });
  act(() => {
    view = { ...view, controlling: true, status: "human" };
    core.changed("browserView");
  });
  await waitFor(() => expect(text()).toBeEnabled());
  fireEvent.change(text()!, { target: { value: "中文輸入" } });
  await userEvent.click(screen.getByRole("button", { name: "Send text" }));
  await waitFor(() =>
    expect(core.sentTo("browserView.input")).toEqual([
      expect.objectContaining({
        viewer: taken!.viewer,
        input: { type: "text", text: "中文輸入" },
      }),
    ])
  );
  await userEvent.click(screen.getByRole("button", { name: "Return to agent" }));
  expect(core.sentTo("browserView.command").at(-1)).toMatchObject({
    operation: "return_control",
  });
  act(() => {
    view = {
      ...view,
      controlling: false,
      status: "agent",
      storageError: "browser_storage_partially_saved",
    };
    core.changed("browserView");
  });
  await waitFor(() => expect(text()).toBeNull());
  expect(screen.getByRole("alert")).toHaveTextContent(
    "Some browser changes were saved."
  );
  unmount();
  // The panel lets go of the stream at once.
  await waitFor(() =>
    expect(unsubscribed).toContainEqual(
      expect.objectContaining({ topic: "browserView" })
    )
  );
});

it("says why the browser cannot be shown and reconnects from there", async () => {
  const binding = {
    agent_id: "agent",
    session_id: "session",
    status: "ready",
    control: "agent" as const,
    busy: false,
    updated_at: "2026-09-28T00:00:00.000000Z",
  };
  // The core could not read the tabs: the agent's last browser action is still running.
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "browserView"
        ? {
            tabs: [],
            tab: "",
            status: "disconnected",
            controlling: false,
            error: "busy",
            pending: false,
            frame: null,
          }
        : undefined,
  });
  let refreshed = 0;
  render(
    core.wrap(
      <AgentBrowserPanel
        workspaceId="workspace"
        id="browser-panel"
        binding={binding}
        onRefresh={() => refreshed++}
      />
    )
  );
  await screen.findByText(
    "The agent is still finishing a browser action. Try again when it's done."
  );
  expect(screen.queryByRole("status", { name: "Loading browser…" })).toBeNull();
  await userEvent.click(screen.getByRole("button", { name: "Reconnect" }));
  expect(core.sentTo("browserView.reconnect")).toEqual([
    expect.objectContaining({ agent: "agent", session: "session" }),
  ]);
  expect(refreshed).toBe(1);
});

it("keeps a live screen when the browser refuses a takeover as busy", async () => {
  const binding = {
    agent_id: "agent",
    session_id: "session",
    status: "ready",
    control: "agent" as const,
    busy: false,
    updated_at: "2026-09-28T00:00:00.000000Z",
  };
  let view: Record<string, unknown> = {
    tabs: [{ tab_id: "tab", title: "Test page", url: "https://example.com" }],
    tab: "tab",
    status: "agent",
    controlling: false,
    error: null,
    pending: false,
    frame: frame(1),
  };
  const core = createScriptedCore({
    values: (topic) => (topic.topic === "browserView" ? view : undefined),
  });
  render(
    core.wrap(
      <AgentBrowserPanel
        workspaceId="workspace"
        id="browser-panel"
        binding={binding}
        onRefresh={() => {}}
      />
    )
  );
  await screen.findByText("Test page");
  // The core's take_control was refused: the agent's action still runs, and its stream goes on.
  act(() => {
    view = { ...view, error: "busy" };
    core.changed("browserView");
  });
  const notice =
    "The agent is still finishing a browser action. Try again when it's done.";
  await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent(notice));
  act(() => {
    view = { ...view, frame: frame(2) };
    core.changed("browserView");
  });
  await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent(notice));
  expect(screen.queryByRole("button", { name: "Reconnect" })).toBeNull();
  expect(screen.getByText("Agent controlling")).toBeVisible();
});

it("shows only the current participant's browser after switching, and asks the core to read it again", async () => {
  const binding = {
    agent_id: "agent",
    session_id: "old-session",
    status: "ready",
    control: "agent" as const,
    busy: false,
    updated_at: "2026-09-28T00:00:00Z",
  };
  // What the core has read for each participant; none yet is null.
  const read = new Map<string, unknown>([["old-participant", { browser: binding }]]);
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "sessionBrowser"
        ? (read.get(String(topic.participant)) ?? null)
        : undefined,
  });
  const { result, rerender, unmount } = renderHook(
    ({ participant }) =>
      useSessionBrowser(true, "workspace", "conversation", participant),
    {
      initialProps: { participant: "old-participant" },
      wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
    }
  );
  await waitFor(() => expect(result.current.browser).toEqual(binding));

  rerender({ participant: "new-participant" });
  await act(async () => {});
  expect(result.current.browser).toBeUndefined();
  act(() => {
    read.set("new-participant", { browser: null });
    core.changed("sessionBrowser");
  });
  await act(async () => {});
  expect(result.current.browser).toBeUndefined();

  result.current.refresh();
  await waitFor(() =>
    expect(core.sentTo("sessionBrowser.refresh")).toEqual([
      {
        workspace: "workspace",
        conversation: "conversation",
        participant: "new-participant",
      },
    ])
  );
  unmount();
});

it("keeps reading the conversation's participant while its status clears for a send", async () => {
  const binding = {
    agent_id: "agent",
    session_id: "session",
    status: "ready",
    control: "agent" as const,
    busy: false,
    updated_at: "2026-09-28T00:00:00Z",
  };
  const subscribed: Record<string, unknown>[] = [];
  const unsubscribed: Record<string, unknown>[] = [];
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "sessionBrowser" ? { browser: binding } : undefined,
    onSubscribe: (topic) => subscribed.push(topic),
    onUnsubscribe: (topic) => unsubscribed.push(topic),
  });
  const { result, rerender, unmount } = renderHook(
    ({ participant }: { participant: string | undefined }) =>
      useSessionBrowser(true, "workspace", "conversation", participant),
    {
      initialProps: { participant: "participant" as string | undefined },
      wrapper: ({ children }: { children: ReactNode }) => core.wrap(children),
    }
  );
  await waitFor(() => expect(result.current.browser).toEqual(binding));

  // The member sends: the participant's status clears, then comes back.
  rerender({ participant: undefined });
  await act(async () => {});
  expect(result.current.browser).toEqual(binding);
  rerender({ participant: "participant" });
  await act(async () => {});
  expect(result.current.browser).toEqual(binding);
  expect(subscribed).toEqual([
    {
      topic: "sessionBrowser",
      workspace: "workspace",
      conversation: "conversation",
      participant: "participant",
    },
  ]);
  expect(unsubscribed).toEqual([]);
  unmount();
});

it("words the header trigger and the panel in the reader's language", () => {
  const binding = {
    agent_id: "agent",
    session_id: "session",
    status: "ready",
    control: "agent" as const,
    busy: false,
    updated_at: "2026-09-28T00:00:00.000000Z",
  };
  // The core has said nothing yet, so the panel stays in its first state.
  const core = createScriptedCore();
  try {
    render(
      core.wrap(
        <CommaI18nProvider locale="zh-CN">
          <AgentBrowserTrigger
            open={false}
            panelId="browser-panel"
            onToggle={() => {}}
          />
          <AgentBrowserPanel
            workspaceId="workspace"
            id="browser-panel"
            binding={binding}
            onRefresh={() => {}}
          />
        </CommaI18nProvider>
      )
    );
    expect(screen.getByRole("button", { name: "浏览器" })).toBeInTheDocument();
    expect(screen.getByRole("region", { name: "Agent 浏览器" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "接管控制" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "刷新" })).toBeEnabled();
    expect(screen.getByRole("status", { name: "正在加载浏览器…" })).toBeInTheDocument();
  } finally {
    initializeCommaI18n(["en"]);
  }
});
