import { chatProtocolVersion } from "@comma/chat-contract";
import userEvent from "@testing-library/user-event";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { render, screen, waitFor, act } from "@comma/test-utils/render";
import { StrictMode, useLayoutEffect, useState } from "react";
import type { CommaApiClient } from "../../../api";
import { testProductLease } from "../../../test/productInboxProjectionHarness";
import { HomeRoute } from "../../RouteScreens";
import { ChatSidebarProvider } from "../../chat-sidebar/ChatSidebarContext";
import {
  CommaCenterStatusOwner,
  CommaCenterStatusProvider,
} from "../../sidebar/CommaCenterStatusContext";
import {
  ChatConsumerBoundary,
  ChatProvider,
  ChatSessionProvider,
  StaleChatSessionError,
  type ChatContextValue,
  useChatRegistry,
} from "../ChatProvider";
import { ConversationChannel } from "../model/conversationChannel";
import { useConversation } from "../conversation/useConversation";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const workspaceChat = vi.hoisted(() => ({
  resolve: vi.fn(),
  state: { status: "loading" } as
    | { status: "loading" }
    | {
        status: "ready";
        workspaceId: string;
        conversation: {
          group_id: string;
          id: string;
          kind: "user_chat";
          messages: never[];
          status: string;
          title: string;
        };
      },
}));

vi.mock("../../AuthGate", () => ({
  useCommaAuth: () => ({ userEmail: "person@example.com" }),
}));

vi.mock("../useWorkspaceChat", () => ({
  resolveWorkspaceChat: (...args: unknown[]) => workspaceChat.resolve(...args),
  useWorkspaceChat: () => ({ state: workspaceChat.state }),
}));

vi.mock("../../home/HomeTasksRail", () => ({
  HomeTasksRail: () => <div data-testid="home-tasks-section" />,
  HomeTasksRailLoading: () => <div data-testid="home-tasks-section" />,
}));

vi.mock("../useWorkspaceSkills", () => ({
  useWorkspaceSkills: () => [],
}));

describe("ChatProvider session ownership", () => {
  beforeEach(() => {
    installNativeBridgeMock({ platform: "web" });
    workspaceChat.resolve.mockReset();
    workspaceChat.state = { status: "loading" };
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("fails a delayed startup attempt closed after provider teardown", async () => {
    const resolution = deferred<ReadyResolution>();
    workspaceChat.resolve.mockReturnValue(resolution.promise);
    const apiA = createApi();
    const sessionA = new AbortController();
    const start = vi.spyOn(ConversationChannel.prototype, "start");
    const send = vi.spyOn(ConversationChannel.prototype, "send");
    const rendered = render(
      <ChatProvider
        api={apiA}
        productLease={testProductLease}
        sessionSignal={sessionA.signal}
      >
        <ChatSidebarProvider>
          <HomeRoute />
        </ChatSidebarProvider>
      </ChatProvider>
    );

    await userEvent.type(screen.getByRole("textbox", { name: "AI prompt" }), "A");
    await userEvent.click(screen.getByRole("button", { name: "Send" }));
    expect(workspaceChat.resolve).toHaveBeenCalledOnce();

    rendered.unmount();
    resolution.resolve(readyResolution());
    await Promise.resolve();
    await Promise.resolve();

    expect(start).not.toHaveBeenCalled();
    expect(send).not.toHaveBeenCalled();
    expect(apiA.streamConversationEvents).not.toHaveBeenCalled();
    expect(apiA.sendMessage).not.toHaveBeenCalled();
  });

  it("revokes an attempt-scoped API before a pending step can continue", async () => {
    const api = createApi();
    const pendingWorkspaces = deferred<never[]>();
    vi.mocked(api.listWorkspaces).mockReturnValueOnce(pendingWorkspaces.promise);
    const contexts: ChatContextValue[] = [];
    render(
      <ChatProvider api={api} productLease={testProductLease}>
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const attempt = contexts.at(-1)!.beginAttempt();
    let attemptApi!: CommaApiClient;
    const result = attempt.run(async (apiCapability) => {
      attemptApi = apiCapability;
      await apiCapability.listWorkspaces();
      return apiCapability.bootstrapWorkspace();
    });

    expect(api.listWorkspaces).toHaveBeenCalledOnce();
    attempt.release();
    pendingWorkspaces.resolve([]);

    await expect(result).rejects.toBeInstanceOf(StaleChatSessionError);
    await expect(attemptApi.listWorkspaces()).rejects.toBeInstanceOf(
      StaleChatSessionError
    );
    expect(api.bootstrapWorkspace).not.toHaveBeenCalled();
  });

  it("revokes old API and registry capabilities without letting an old release touch B", async () => {
    vi.useFakeTimers();
    const apiA = createApi();
    const apiB = createApi();
    const sessionA = new AbortController();
    const sessionB = new AbortController();
    const contexts: ChatContextValue[] = [];
    const rendered = render(
      <ChatProvider
        api={apiA}
        productLease={testProductLease}
        releaseDelayMs={0}
        sessionSignal={sessionA.signal}
      >
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const contextA = contexts.at(-1)!;
    const pendingApiCall = deferred<never[]>();
    vi.mocked(apiA.listWorkspaces).mockReturnValueOnce(pendingApiCall.promise);
    const oldApiResult = contextA.api.listWorkspaces();
    const leaseA = contextA.retain("wsp_same", "grp_test", "cnv_same");

    sessionA.abort();
    rendered.rerender(
      <ChatProvider
        api={apiB}
        productLease={testProductLease}
        releaseDelayMs={0}
        sessionSignal={sessionB.signal}
      >
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const contextB = contexts.at(-1)!;
    const leaseB = contextB.retain("wsp_same", "grp_test", "cnv_same");
    const stopB = vi.spyOn(leaseB.channel, "stop");

    pendingApiCall.resolve([]);
    await expect(oldApiResult).rejects.toBeInstanceOf(StaleChatSessionError);
    await expect(contextA.api.listWorkspaces()).rejects.toBeInstanceOf(
      StaleChatSessionError
    );
    expect(() => contextA.retain("wsp_same", "grp_test", "cnv_same")).toThrow(
      StaleChatSessionError
    );

    leaseA.release();
    await vi.runAllTimersAsync();
    expect(stopB).not.toHaveBeenCalled();

    leaseB.release();
    await vi.runAllTimersAsync();
    expect(stopB).toHaveBeenCalledOnce();
  });

  it("keeps Home target retirement identity-safe and scoped to its session", () => {
    const sessionA = new AbortController();
    const contexts: ChatContextValue[] = [];
    const rendered = render(
      <ChatProvider
        api={createApi()}
        productLease={testProductLease}
        sessionSignal={sessionA.signal}
      >
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const contextA = contexts.at(-1)!;
    const onTargetChange = vi.fn();
    const unsubscribe = contextA.subscribeHomeConversationTarget(onTargetChange);
    contextA.rememberHomeConversationTarget("wsp_a", "grp_test", "cnv_a");
    expect(contextA.getHomeConversationTarget()).toEqual({
      conversationId: "cnv_a",
      groupId: "grp_test",
      workspaceId: "wsp_a",
    });
    expect(onTargetChange).toHaveBeenCalledOnce();

    contextA.rememberHomeConversationTarget("wsp_a", "grp_test", "cnv_a");
    expect(onTargetChange).toHaveBeenCalledOnce();

    contextA.retireHomeConversationTarget("grp_other", "cnv_other");
    expect(contextA.getHomeConversationTarget()).toEqual({
      conversationId: "cnv_a",
      groupId: "grp_test",
      workspaceId: "wsp_a",
    });
    expect(onTargetChange).toHaveBeenCalledOnce();

    contextA.retireHomeConversationTarget("grp_test", "cnv_a");
    expect(contextA.getHomeConversationTarget()).toBeUndefined();
    expect(onTargetChange).toHaveBeenCalledTimes(2);

    contextA.rememberHomeConversationTarget("wsp_b", "grp_test", "cnv_b");
    contextA.retireHomeConversationTarget("grp_test", "cnv_a");
    expect(contextA.getHomeConversationTarget()).toEqual({
      conversationId: "cnv_b",
      groupId: "grp_test",
      workspaceId: "wsp_b",
    });
    expect(onTargetChange).toHaveBeenCalledTimes(3);

    sessionA.abort();
    expect(onTargetChange).toHaveBeenCalledTimes(4);
    unsubscribe();
    // A real re-login always issues a new sessionId; the revoked session's
    // target must not leak into it. (A same-sessionId remount — a credential
    // generation bump — deliberately keeps the target; see the carry test.)
    rendered.rerender(
      <ChatProvider
        api={createApi()}
        productLease={{
          ...testProductLease,
          sessionId: `${testProductLease.sessionId}-relogin`,
        }}
      >
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );

    expect(contextA.getHomeConversationTarget()).toBeUndefined();
    expect(contexts.at(-1)!.getHomeConversationTarget()).toBeUndefined();
  });

  it("opens prepared canonical content synchronously and isolates it from another login", () => {
    const contexts: ChatContextValue[] = [];
    const view = render(
      <ChatProvider api={createApi()} productLease={testProductLease}>
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const registry = contexts.at(-1)!;
    registry.rememberConversationSnapshot({
      group_id: "grp_test",
      id: "cnv_private_tail",
      kind: "agent_task",
      status: "ready_for_review",
      title: "Private tail",
      message_count: 100,
      messages: [
        {
          message_id: "msg_delivery",
          kind: "app_event",
          actor_type: "system",
          content: [],
          metadata: { event_type: "provider.status" },
        },
      ],
    });
    expect(
      registry.getRetainedSnapshot("grp_test", "cnv_private_tail")
    ).toBeUndefined();
    registry.rememberConversationSnapshot({
      group_id: "grp_test",
      id: "cnv_prepared",
      kind: "agent_task",
      status: "active",
      title: "Prepared Task",
      updated_at: 2,
      messages: [
        {
          message_id: "msg_prepared",
          kind: "message",
          actor_type: "agent",
          content: [{ type: "text", text: "Ready before navigation" }],
        },
      ],
    });
    const lease = registry.retain("wsp_test", "grp_test", "cnv_prepared");
    expect(lease.channel.getSnapshot().serverMessages[0]?.text).toBe(
      "Ready before navigation"
    );
    lease.release();
    view.rerender(
      <ChatProvider
        api={createApi()}
        productLease={{ ...testProductLease, sessionId: "another-login" }}
      >
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    expect(
      contexts.at(-1)!.getRetainedSnapshot("grp_test", "cnv_prepared")
    ).toBeUndefined();
  });

  it("retains only the lightweight canonical Home conversation summary", () => {
    const contexts: ChatContextValue[] = [];
    render(
      <ChatProvider api={createApi()} productLease={testProductLease}>
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const registry = contexts.at(-1)!;
    const onTargetChange = vi.fn();
    registry.subscribeHomeConversationTarget(onTargetChange);
    const conversation = {
      created_at: 1_000,
      freshness: { refreshed_at: 1_500, state: "fresh" as const },
      group_id: "grp_test",
      id: "cnv_a",
      kind: "user_chat" as const,
      messages: [],
      status: "active",
      title: "Workspace Chat",
      updated_at: 2_000,
    };

    registry.rememberHomeConversationTarget("wsp_a", "grp_test", "cnv_a", conversation);

    expect(registry.getHomeConversationTarget()).toEqual({
      conversationId: "cnv_a",
      groupId: "grp_test",
      summary: {
        created_at: 1_000,
        freshness: { refreshed_at: 1_500, state: "fresh" },
        group_id: "grp_test",
        id: "cnv_a",
        kind: "user_chat",
        status: "active",
        title: "Workspace Chat",
        updated_at: 2_000,
      },
      workspaceId: "wsp_a",
    });
    expect(registry.getHomeConversationTarget()?.summary).not.toHaveProperty(
      "messages"
    );
    expect(onTargetChange).toHaveBeenCalledOnce();

    registry.rememberHomeConversationTarget("wsp_a", "grp_test", "cnv_a", conversation);
    expect(onTargetChange).toHaveBeenCalledOnce();

    registry.rememberHomeConversationTarget("wsp_a", "grp_test", "cnv_a", {
      ...conversation,
      title: "Renamed Workspace Chat",
    });
    expect(registry.getHomeConversationTarget()?.summary?.title).toBe(
      "Renamed Workspace Chat"
    );
    expect(onTargetChange).toHaveBeenCalledTimes(2);
  });

  it("carries the Home target across a same-session generation remount only", () => {
    const contexts: ChatContextValue[] = [];
    const rendered = render(
      <ChatProvider api={createApi()} productLease={testProductLease}>
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const contextA = contexts.at(-1)!;
    contextA.rememberHomeConversationTarget("wsp_a", "grp_test", "cnv_a");

    // A credential reconcile (renderer 401/409 recovery, token refresh) bumps
    // only the generation: the remounted registry keeps the Home target so the
    // route-independent Comma assistant status owner never drops its lease.
    rendered.rerender(
      <ChatProvider
        api={createApi()}
        productLease={{
          ...testProductLease,
          generation: testProductLease.generation + 1,
        }}
      >
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const contextB = contexts.at(-1)!;
    expect(contextB).not.toBe(contextA);
    expect(contextB.getHomeConversationTarget()).toEqual({
      conversationId: "cnv_a",
      groupId: "grp_test",
      workspaceId: "wsp_a",
    });

    // Retiring under the current session also drops the carry for later
    // remounts.
    contextB.retireHomeConversationTarget("grp_test", "cnv_a");
    rendered.rerender(
      <ChatProvider
        api={createApi()}
        productLease={{
          ...testProductLease,
          generation: testProductLease.generation + 2,
        }}
      >
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    expect(contexts.at(-1)!.getHomeConversationTarget()).toBeUndefined();

    // A different signed-in session (new sessionId) never inherits the target.
    contexts.at(-1)!.rememberHomeConversationTarget("wsp_a", "grp_test", "cnv_a");
    rendered.rerender(
      <ChatProvider
        api={createApi()}
        productLease={{
          ...testProductLease,
          generation: testProductLease.generation + 3,
          sessionId: `${testProductLease.sessionId}-other`,
        }}
      >
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    expect(contexts.at(-1)!.getHomeConversationTarget()).toBeUndefined();
  });

  it("seeds a same-session generation remount with the previous generation's transcript", async () => {
    const transcriptMessage = {
      attachments: [],
      delivery: "sent" as const,
      messageId: "message-history",
      parts: [{ kind: "markdown" as const, text: "Carried history" }],
      refs: [],
      role: "assistant",
      source: "server" as const,
      text: "Carried history",
    };
    const runtimeSnapshot = {
      protocolVersion: chatProtocolVersion,
      revision: 1,
      sessions: [
        {
          conversationId: "cnv_seed",
          groupId: "grp_seed",
          draftOwnerSurfaceId: undefined,
          key: "grp_seed/cnv_seed",
          refs: 1,
          revision: 1,
          state: {
            activity: undefined,
            assistantDraft: undefined,
            awaitingReply: false,
            awaitingSince: undefined,
            awaitingTimedOut: false,
            connection: "live",
            conversation: undefined,
            draft: "",
            draftAttachments: [],
            errorKind: undefined,
            lastBackoffMs: 0,
            messages: [transcriptMessage],
            pending: [],
            serverMessages: [transcriptMessage],
            status: "ready",
            syncWarning: undefined,
          },
          workspaceId: "wsp_seed",
        },
      ],
    };
    installNativeBridgeMock({
      chat: {
        release: vi.fn(async () => ({ revision: 2 })),
        retain: vi.fn(async () => ({ revision: 1 })),
        state: {
          get: vi.fn(async (input: { session: unknown }) => ({
            session: input.session,
            snapshot: runtimeSnapshot,
          })),
          subscribe: vi.fn(() => vi.fn()),
        },
      } as never,
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const contexts: ChatContextValue[] = [];
    const rendered = render(
      <ChatProvider
        api={createApi()}
        productLease={testProductLease}
        releaseDelayMs={0}
      >
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const leaseA = contexts.at(-1)!.retain("wsp_seed", "grp_seed", "cnv_seed");
    await waitFor(() =>
      expect(leaseA.channel.getSnapshot().messages.map((item) => item.text)).toEqual([
        "Carried history",
      ])
    );
    const seededRows = leaseA.channel.getSnapshot().serverMessages;

    // Navigating away lets the lease and transport expire, but the next
    // render can still read the canonical transcript without native IPC.
    leaseA.release();
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(
      contexts.at(-1)!.getRetainedSnapshot("grp_seed", "cnv_seed")?.serverMessages
    ).toBe(seededRows);
    const revisit = contexts.at(-1)!.retain("wsp_seed", "grp_seed", "cnv_seed");
    expect(revisit.channel.getSnapshot().serverMessages).toBe(seededRows);

    // A same-session generation bump remounts the provider; the replacement
    // channel paints the carried transcript synchronously — before any native
    // round-trip — with the previous rows' object identities intact.
    rendered.rerender(
      <ChatProvider
        api={createApi()}
        productLease={{
          ...testProductLease,
          generation: testProductLease.generation + 1,
        }}
      >
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const leaseB = contexts.at(-1)!.retain("wsp_seed", "grp_seed", "cnv_seed");
    expect(leaseB.channel.getSnapshot().serverMessages).toBe(seededRows);
    expect(leaseB.channel.getSnapshot().syncWarning).toBe("stale");

    // A different signed-in session gets a cold channel, never a seed.
    rendered.rerender(
      <ChatProvider
        api={createApi()}
        productLease={{
          ...testProductLease,
          generation: testProductLease.generation + 2,
          sessionId: `${testProductLease.sessionId}-other`,
        }}
      >
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const leaseC = contexts.at(-1)!.retain("wsp_seed", "grp_seed", "cnv_seed");
    expect(leaseC.channel.getSnapshot().messages).toEqual([]);
  });

  it("reactivates the current generation after StrictMode's simulated cleanup", async () => {
    const api = createApi();
    const contexts: ChatContextValue[] = [];
    const session = new AbortController();
    render(
      <StrictMode>
        <ChatProvider
          api={api}
          productLease={testProductLease}
          releaseDelayMs={0}
          sessionSignal={session.signal}
        >
          <RegistryProbe onContext={(context) => contexts.push(context)} />
          <ConversationProbe />
        </ChatProvider>
      </StrictMode>
    );

    const context = contexts.at(-1)!;
    await expect(context.api.listWorkspaces()).resolves.toEqual([]);
    await waitFor(() =>
      expect(screen.getByRole("status", { name: "strict-status" })).toHaveTextContent(
        "ready"
      )
    );
    expect(api.streamConversationEvents).toHaveBeenCalledOnce();
  });

  it("keeps the Home conversation lease while route consumers unmount", async () => {
    const api = createApi();
    const rendered = render(homeLeaseTree(api, { route: true }));

    await waitFor(() =>
      expect(screen.getByRole("status", { name: "strict-status" })).toHaveTextContent(
        "ready:Chat"
      )
    );

    rendered.rerender(homeLeaseTree(api, { route: false }));
    await waitFor(() =>
      expect(screen.queryByRole("status", { name: "strict-status" })).toBeNull()
    );
    await act(async () => {
      await new Promise((resolve) => window.setTimeout(resolve, 0));
    });
    rendered.rerender(homeLeaseTree(api, { route: false }));
    expect(
      screen.getByRole("status", { name: "home-lease-snapshot" })
    ).toHaveTextContent("ready:Chat");

    rendered.rerender(homeLeaseTree(api, { route: true }));
    await waitFor(() =>
      expect(screen.getByRole("status", { name: "strict-status" })).toHaveTextContent(
        "ready:Chat"
      )
    );
    expect(
      screen.getByRole("status", { name: "home-lease-snapshot" })
    ).toHaveTextContent("ready:Chat");
  });

  it("keeps unkeyed Settings state and Home history across a generation bump", async () => {
    const api = createApi("Kept through Settings");
    const rendered = render(
      authenticatedSessionTree(api, testProductLease, { view: "home" })
    );

    await waitFor(() =>
      expect(screen.getByRole("status", { name: "home-history" })).toHaveTextContent(
        "Kept through Settings"
      )
    );

    rendered.rerender(
      authenticatedSessionTree(api, testProductLease, { view: "settings" })
    );
    await userEvent.click(screen.getByRole("button", { name: "Open edit name" }));
    expect(screen.getByRole("status", { name: "settings-category" })).toHaveTextContent(
      "profile"
    );
    expect(screen.getByRole("status", { name: "settings-draft" })).toHaveTextContent(
      "Ada Lovelace"
    );

    rendered.rerender(
      authenticatedSessionTree(
        api,
        { ...testProductLease, generation: testProductLease.generation + 1 },
        { view: "settings" }
      )
    );
    expect(screen.getByRole("status", { name: "settings-category" })).toHaveTextContent(
      "profile"
    );
    expect(screen.getByRole("status", { name: "settings-draft" })).toHaveTextContent(
      "Ada Lovelace"
    );
    await waitFor(() =>
      expect(screen.getByRole("status", { name: "home-history" })).toHaveTextContent(
        "Kept through Settings"
      )
    );

    rendered.rerender(
      authenticatedSessionTree(
        api,
        { ...testProductLease, generation: testProductLease.generation + 1 },
        { view: "home" }
      )
    );
    expect(screen.getByRole("status", { name: "home-history" })).toHaveTextContent(
      "Kept through Settings"
    );
    expect(screen.getByRole("status", { name: "strict-status" })).toHaveTextContent(
      "ready:Chat"
    );
  });

  it("fails observer reads closed to an empty snapshot during synchronous revocation", async () => {
    const api = createApi();
    const session = new AbortController();
    render(
      <ChatProvider
        api={api}
        productLease={testProductLease}
        releaseDelayMs={0}
        sessionSignal={session.signal}
      >
        <ConversationProbe />
      </ChatProvider>
    );

    await waitFor(() =>
      expect(screen.getByRole("status", { name: "strict-status" })).toHaveTextContent(
        "ready:Chat"
      )
    );

    session.abort();

    await waitFor(() =>
      expect(screen.getByRole("status", { name: "strict-status" })).toHaveTextContent(
        "idle:"
      )
    );
  });

  it("fails a passive retain closed when revocation wins the commit race", async () => {
    const api = createApi();
    const session = new AbortController();
    render(
      <ChatProvider
        api={api}
        productLease={testProductLease}
        releaseDelayMs={0}
        sessionSignal={session.signal}
      >
        <AbortSessionInLayout controller={session} />
        <ConversationProbe />
      </ChatProvider>
    );

    await waitFor(() =>
      expect(screen.getByRole("status", { name: "strict-status" })).toHaveTextContent(
        "idle:"
      )
    );
    expect(api.streamConversationEvents).not.toHaveBeenCalled();
  });
});

function RegistryProbe({
  onContext,
}: {
  onContext: (context: ChatContextValue) => void;
}) {
  const context = useChatRegistry();
  useLayoutEffect(() => {
    onContext(context);
  }, [context, onContext]);
  return null;
}

function RememberHomeTarget() {
  const registry = useChatRegistry();
  useLayoutEffect(() => {
    registry.rememberHomeConversationTarget("wsp_strict", "grp_strict", "cnv_strict");
  }, [registry]);
  return null;
}

function HomeLeaseSnapshot() {
  const registry = useChatRegistry();
  const snapshot = registry.getRetainedSnapshot("grp_strict", "cnv_strict");
  return (
    <output aria-label="home-lease-snapshot">
      {snapshot?.status ?? "missing"}:{snapshot?.conversation?.title ?? ""}
    </output>
  );
}

function homeLeaseTree(api: CommaApiClient, { route }: { route: boolean }) {
  return (
    <ChatProvider api={api} productLease={testProductLease} releaseDelayMs={0}>
      <RememberHomeTarget />
      <CommaCenterStatusOwner />
      <HomeLeaseSnapshot />
      {route ? <ConversationProbe /> : null}
    </ChatProvider>
  );
}

function authenticatedSessionTree(
  api: CommaApiClient,
  productLease: typeof testProductLease,
  { view }: { view: "home" | "settings" }
) {
  return (
    <ChatSessionProvider api={api} productLease={productLease} releaseDelayMs={0}>
      <CommaCenterStatusProvider>
        <ChatConsumerBoundary>
          <CommaCenterStatusOwner />
          <HomeHistorySnapshot />
        </ChatConsumerBoundary>
        {view === "home" ? (
          <ChatConsumerBoundary>
            <RememberHomeTarget />
            <ConversationProbe />
          </ChatConsumerBoundary>
        ) : (
          <SettingsDraftProbe />
        )}
      </CommaCenterStatusProvider>
    </ChatSessionProvider>
  );
}

function HomeHistorySnapshot() {
  const conversation = useConversation("wsp_strict", "grp_strict", "cnv_strict");
  return (
    <output aria-label="home-history">
      {conversation.state.messages.map((message) => message.text).join(" ") || "empty"}
    </output>
  );
}

function SettingsDraftProbe() {
  const [category, setCategory] = useState("general");
  const [draft, setDraft] = useState("");
  const [dialogOpen, setDialogOpen] = useState(false);

  return (
    <div>
      <output aria-label="settings-category">{category}</output>
      {dialogOpen ? <output aria-label="settings-draft">{draft}</output> : null}
      <button
        type="button"
        onClick={() => {
          setCategory("profile");
          setDialogOpen(true);
          setDraft("Ada Lovelace");
        }}
      >
        Open edit name
      </button>
    </div>
  );
}

function ConversationProbe() {
  const conversation = useConversation("wsp_strict", "grp_strict", "cnv_strict");
  return (
    <output aria-label="strict-status">
      {conversation.state.status}:{conversation.state.conversation?.title}
    </output>
  );
}

function AbortSessionInLayout({ controller }: { controller: AbortController }) {
  useLayoutEffect(() => {
    controller.abort();
  }, [controller]);
  return null;
}

function createApi(historyText?: string) {
  return {
    bootstrapWorkspace: vi.fn(),
    listWorkspaces: vi.fn(async () => []),
    pollConversation: vi.fn(async (groupId: string, conversationId: string) => ({
      conversation: {
        group_id: groupId,
        id: conversationId,
        kind: "user_chat" as const,
        messages: historyText
          ? [
              {
                actor_type: "agent",
                content: [{ text: historyText, type: "text" }],
                created_at: 1_720_000_002,
                kind: "message",
                message_id: "msg-settings-history",
              },
            ]
          : [],
        status: "active",
        title: "Chat",
      },
      notModified: false,
    })),
    streamConversationEvents: vi.fn(
      async (
        _groupId: string,
        _conversationId: string,
        opts: Parameters<CommaApiClient["streamConversationEvents"]>[2]
      ) =>
        new Promise<void>((resolve) => {
          if (opts.signal?.aborted) {
            resolve();
            return;
          }
          opts.signal?.addEventListener("abort", () => resolve(), { once: true });
        })
    ),
    sendMessage: vi.fn(),
    uploadGroupFile: vi.fn(),
  } as unknown as CommaApiClient;
}

type ReadyResolution = ReturnType<typeof readyResolution>;

function readyResolution() {
  return {
    conversation: {
      group_id: "grp_a",
      id: "cnv_a",
      kind: "user_chat" as const,
      messages: [] as never[],
      status: "open",
      title: "Chat",
    },
    groupId: "grp_a",
    status: "ready" as const,
    workspaceId: "wsp_a",
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}
