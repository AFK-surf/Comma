import { idleConversationChannelState } from "@comma/core/chat";
import userEvent from "@testing-library/user-event";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { advance, flush } from "@comma/test-utils/fake-clock";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { render as renderUi, screen } from "@comma/test-utils/render";
import {
  StrictMode,
  useLayoutEffect,
  useState,
  type ReactElement,
  type ReactNode,
} from "react";
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
import { CoreConversationChannel } from "../channel/CoreConversationChannel";
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

/** The window's views of conversations (`chatView`) it subscribed to and let go. */
let views: { subscribed: number; unsubscribed: number } = {
  subscribed: 0,
  unsubscribed: 0,
};
/** The core the window's chat talks to: it shows nothing, unless a test scripts its chat. */
let core = scriptedChat(undefined, false);

function Core({ children }: { children: ReactNode }) {
  return core.wrap(children);
}

function render(ui: ReactElement) {
  return renderUi(ui, { wrapper: Core });
}

describe("ChatProvider session ownership", () => {
  beforeEach(() => {
    core = scriptedChat(undefined, false);
    installNativeBridgeMock({ platform: "web" });
    workspaceChat.resolve.mockReset();
    workspaceChat.state = { status: "loading" };
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("fails a delayed startup attempt closed after provider teardown", async () => {
    const resolution = deferred<ReadyResolution>();
    workspaceChat.resolve.mockReturnValue(resolution.promise);
    const sessionA = new AbortController();
    const start = vi.spyOn(CoreConversationChannel.prototype, "start");
    const send = vi.spyOn(CoreConversationChannel.prototype, "send");
    const rendered = render(
      <ChatProvider productLease={testProductLease} sessionSignal={sessionA.signal}>
        <ChatSidebarProvider>
          <HomeRoute />
        </ChatSidebarProvider>
      </ChatProvider>
    );

    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    await user.type(screen.getByRole("textbox", { name: "AI prompt" }), "A");
    await user.click(screen.getByRole("button", { name: "Send" }));
    expect(workspaceChat.resolve).toHaveBeenCalledOnce();

    rendered.unmount();
    resolution.resolve(readyResolution());
    await flush();

    expect(start).not.toHaveBeenCalled();
    expect(send).not.toHaveBeenCalled();
    expect(views.subscribed).toBe(0);
    expect(core.sentTo("chatView.send")).toEqual([]);
  });

  it("revokes an attempt before a pending step can continue", async () => {
    const pendingStep = deferred<string>();
    const contexts: ChatContextValue[] = [];
    render(
      <ChatProvider productLease={testProductLease}>
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const attempt = contexts.at(-1)!.beginAttempt();
    let attemptSignal!: AbortSignal;
    const result = attempt.run((signal) => {
      attemptSignal = signal;
      return pendingStep.promise;
    });

    attempt.release();
    pendingStep.resolve("late");

    await expect(result).rejects.toBeInstanceOf(StaleChatSessionError);
    expect(attemptSignal.aborted).toBe(true);
  });

  it("revokes old registry capabilities without letting an old release touch B", async () => {
    const sessionA = new AbortController();
    const sessionB = new AbortController();
    const contexts: ChatContextValue[] = [];
    const rendered = render(
      <ChatProvider productLease={testProductLease} sessionSignal={sessionA.signal}>
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const contextA = contexts.at(-1)!;
    const leaseA = contextA.retain("wsp_same", "grp_test", "cnv_same");

    sessionA.abort();
    rendered.rerender(
      <ChatProvider productLease={testProductLease} sessionSignal={sessionB.signal}>
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const contextB = contexts.at(-1)!;
    const leaseB = contextB.retain("wsp_same", "grp_test", "cnv_same");
    const stopB = vi.spyOn(leaseB.channel, "stop");

    expect(() => contextA.retain("wsp_same", "grp_test", "cnv_same")).toThrow(
      StaleChatSessionError
    );

    leaseA.release();
    await flush();
    expect(stopB).not.toHaveBeenCalled();

    leaseB.release();
    await flush();
    expect(stopB).toHaveBeenCalledOnce();
  });

  it("keeps Home target retirement identity-safe and scoped to its session", () => {
    const sessionA = new AbortController();
    const contexts: ChatContextValue[] = [];
    const rendered = render(
      <ChatProvider productLease={testProductLease} sessionSignal={sessionA.signal}>
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
      <ChatProvider productLease={testProductLease}>
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const registry = contexts.at(-1)!;
    // What the core read ahead (chat.prepare): the conversation and its last messages as the transcript shows them.
    registry.rememberConversationSnapshot({
      conversation: {
        group_id: "grp_test",
        id: "cnv_prepared",
        kind: "agent_task",
        status: "active",
        title: "Prepared Task",
        updated_at: 2,
        messages: [],
      },
      messages: [
        {
          messageId: "msg_prepared",
          role: "assistant",
          text: "Ready before navigation",
          attachments: [],
          refs: [],
          delivery: "sent",
          source: "server",
        },
      ],
    });
    const lease = registry.retain("wsp_test", "grp_test", "cnv_prepared");
    expect(lease.channel.getSnapshot().serverMessages[0]?.text).toBe(
      "Ready before navigation"
    );
    lease.release();
    view.rerender(
      <ChatProvider productLease={{ ...testProductLease, sessionId: "another-login" }}>
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
      <ChatProvider productLease={testProductLease}>
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
      <ChatProvider productLease={testProductLease}>
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
    core = createScriptedCore({
      values: (topic) =>
        topic.topic === "chatView"
          ? {
              session: {
                sessionId: testProductLease.sessionId,
                audience: testProductLease.audience,
              },
              revision: 1,
              draftEpoch: 0,
              lease: { leaseId: "lease", subscriberId: "web:test:grp_seed/cnv_seed" },
              state: {
                ...idleConversationChannelState,
                connection: "live" as const,
                messages: [transcriptMessage],
                serverMessages: [transcriptMessage],
                status: "ready" as const,
              },
            }
          : undefined,
    });
    const contexts: ChatContextValue[] = [];
    const rendered = render(
      <ChatProvider productLease={testProductLease}>
        <RegistryProbe onContext={(context) => contexts.push(context)} />
      </ChatProvider>
    );
    const leaseA = contexts.at(-1)!.retain("wsp_seed", "grp_seed", "cnv_seed");
    await flush();
    expect(leaseA.channel.getSnapshot().messages.map((item) => item.text)).toEqual([
      "Carried history",
    ]);
    const seededRows = leaseA.channel.getSnapshot().serverMessages;

    // Navigating away lets the lease and transport expire, but the next
    // render can still read the canonical transcript without native IPC.
    leaseA.release();
    await advance(10);
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
    core = scriptedChat();
    const contexts: ChatContextValue[] = [];
    const session = new AbortController();
    render(
      <StrictMode>
        <ChatProvider productLease={testProductLease} sessionSignal={session.signal}>
          <RegistryProbe onContext={(context) => contexts.push(context)} />
          <ConversationProbe />
        </ChatProvider>
      </StrictMode>
    );

    await flush();
    expect(screen.getByRole("status", { name: "strict-status" })).toHaveTextContent(
      "ready"
    );
    // The window retained its conversation in the core once and kept it: every release StrictMode's simulated
    // cleanup made was answered by a retain. That the core keeps the conversation's one stream through such a
    // release and retain is the core's own: core/test/chat/chat.test.ts, "keeps its conversation's one stream
    // when it lets go and retains it again within the release delay".
    expect(views.subscribed).toBeGreaterThan(0);
    expect(views.subscribed).toBe(views.unsubscribed + 1);
  });

  it("keeps the Home conversation lease while route consumers unmount", async () => {
    core = scriptedChat();
    const rendered = render(homeLeaseTree({ route: true }));

    await flush();
    expect(screen.getByRole("status", { name: "strict-status" })).toHaveTextContent(
      "ready:Chat"
    );

    rendered.rerender(homeLeaseTree({ route: false }));
    await flush();
    expect(screen.queryByRole("status", { name: "strict-status" })).toBeNull();
    await flush();
    rendered.rerender(homeLeaseTree({ route: false }));
    expect(
      screen.getByRole("status", { name: "home-lease-snapshot" })
    ).toHaveTextContent("ready:Chat");

    rendered.rerender(homeLeaseTree({ route: true }));
    await flush();
    expect(screen.getByRole("status", { name: "strict-status" })).toHaveTextContent(
      "ready:Chat"
    );
    expect(
      screen.getByRole("status", { name: "home-lease-snapshot" })
    ).toHaveTextContent("ready:Chat");
  });

  it("keeps unkeyed Settings state and Home history across a generation bump", async () => {
    core = scriptedChat("Kept through Settings");
    const rendered = render(
      authenticatedSessionTree(testProductLease, { view: "home" })
    );

    await flush();
    expect(screen.getByRole("status", { name: "home-history" })).toHaveTextContent(
      "Kept through Settings"
    );

    rendered.rerender(authenticatedSessionTree(testProductLease, { view: "settings" }));
    await userEvent
      .setup({ advanceTimers: vi.advanceTimersByTime })
      .click(screen.getByRole("button", { name: "Open edit name" }));
    expect(screen.getByRole("status", { name: "settings-category" })).toHaveTextContent(
      "profile"
    );
    expect(screen.getByRole("status", { name: "settings-draft" })).toHaveTextContent(
      "Ada Lovelace"
    );

    rendered.rerender(
      authenticatedSessionTree(
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
    await flush();
    expect(screen.getByRole("status", { name: "home-history" })).toHaveTextContent(
      "Kept through Settings"
    );

    rendered.rerender(
      authenticatedSessionTree(
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
    core = scriptedChat();
    const session = new AbortController();
    render(
      <ChatProvider productLease={testProductLease} sessionSignal={session.signal}>
        <ConversationProbe />
      </ChatProvider>
    );

    await flush();
    expect(screen.getByRole("status", { name: "strict-status" })).toHaveTextContent(
      "ready:Chat"
    );

    session.abort();

    await flush();
    expect(screen.getByRole("status", { name: "strict-status" })).toHaveTextContent(
      "idle:"
    );
  });

  it("fails a passive retain closed when revocation wins the commit race", async () => {
    const session = new AbortController();
    render(
      <ChatProvider productLease={testProductLease} sessionSignal={session.signal}>
        <AbortSessionInLayout controller={session} />
        <ConversationProbe />
      </ChatProvider>
    );

    await flush();
    expect(screen.getByRole("status", { name: "strict-status" })).toHaveTextContent(
      "idle:"
    );
    expect(views.subscribed).toBe(0);
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

function homeLeaseTree({ route }: { route: boolean }) {
  return (
    <ChatProvider productLease={testProductLease}>
      <RememberHomeTarget />
      <CommaCenterStatusOwner />
      <HomeLeaseSnapshot />
      {route ? <ConversationProbe /> : null}
    </ChatProvider>
  );
}

function authenticatedSessionTree(
  productLease: typeof testProductLease,
  { view }: { view: "home" | "settings" }
) {
  return (
    <ChatSessionProvider productLease={productLease}>
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

/**
 * The window's chat on a scripted core (what it shows, not the core's own behavior): Home's conversation, titled
 * "Chat", with `historyText` as its one message, while a window shows it (`shows: false`: never). Counts the views
 * the window subscribes to and lets go (`views`).
 */
function scriptedChat(historyText?: string, shows = true) {
  const session = {
    sessionId: testProductLease.sessionId,
    audience: testProductLease.audience,
  };
  const counted = { subscribed: 0, unsubscribed: 0 };
  views = counted;
  const messages = historyText
    ? [
        {
          attachments: [],
          delivery: "sent" as const,
          messageId: "msg-settings-history",
          parts: [{ kind: "markdown" as const, text: historyText }],
          refs: [],
          role: "assistant" as const,
          source: "server" as const,
          text: historyText,
        },
      ]
    : [];
  return createScriptedCore({
    values: (topic) =>
      topic.topic === "chatView" && shows
        ? {
            session,
            revision: 1,
            draftEpoch: 0,
            lease: { leaseId: "lease", subscriberId: "web:test:grp_strict/cnv_strict" },
            state: {
              ...idleConversationChannelState,
              connection: "live" as const,
              conversation: {
                group_id: "grp_strict",
                id: "cnv_strict",
                kind: "user_chat" as const,
                status: "active",
                title: "Chat",
              },
              messages,
              serverMessages: messages,
              status: "ready" as const,
            },
          }
        : undefined,
    calls: () => ({ revision: 1, draftEpoch: 0 }),
    onSubscribe: (topic) => {
      if (topic.topic === "chatView") counted.subscribed += 1;
    },
    onUnsubscribe: (topic) => {
      if (topic.topic === "chatView") counted.unsubscribed += 1;
    },
  });
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
