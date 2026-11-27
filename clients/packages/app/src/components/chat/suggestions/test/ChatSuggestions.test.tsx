import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { initializeCommaI18n, type CommaLocale } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { useMemo, useState } from "react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ChatSuggestion } from "@comma/core/contract";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import {
  ConversationView,
  type ConversationViewActions,
} from "../../conversation/ConversationView";
import { fixedDraftSource } from "../../composer/conversationDraft";
import type { ChatMessage, ConversationChannelState } from "@comma/core/chat";

describe("chat follow-up placeholder", () => {
  beforeEach(() => {
    initializeCommaI18n(["en"]);
  });

  it("asks the core for the settled turn's suggestions and shows the first prompt as a placeholder", async () => {
    const core = scriptedCore();
    renderConversation({ core, state: settled() });

    await waitFor(() => expect(suggestionInput()).toBeTruthy());
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveTextContent("");
    expect(core.asked).toEqual([
      {
        topic: "chatSuggestions",
        group: "grp_1",
        conversation: "cnv_1",
        message: "msg_a1",
        locale: "en",
      },
    ]);
  });

  it("re-rendering the same settled turn does not ask again", async () => {
    const core = scriptedCore();
    const { setState } = renderConversation({ core, state: settled() });

    await waitFor(() => {
      expect(suggestionInput()).toBeTruthy();
    });
    // A draft keystroke republishes the whole snapshot; the settled message is
    // what identifies the turn, so this must not ask for a second generation.
    setState(settled({ draft: "typing" }));
    await waitFor(() =>
      expect(screen.getByRole("textbox")).toHaveTextContent("typing")
    );

    expect(core.asked).toHaveLength(1);
  });

  // COMMA-274: the suggestions are model-written, so the language they were generated
  // in outlives a language switch unless the locale is part of what is asked.
  it("asks again in the new interface language and shows only its answer", async () => {
    const core = scriptedCore((topic) =>
      topic.locale === "zh-CN"
        ? [{ id: "sug_zh", label: "添加测试", prompt: "为解析器添加测试。" }]
        : null
    );
    const { setLocale } = renderConversation({ core, state: settled() });
    await waitFor(() => expect(core.asked).toHaveLength(1));

    await act(async () => setLocale("zh-CN"));

    await waitFor(() => expect(suggestionInput("为解析器添加测试。")).toBeTruthy());
    expect(core.asked.map((topic) => topic.locale)).toEqual(["en", "zh-CN"]);
  });

  it("accepts Tab into the draft without sending", async () => {
    const user = userEvent.setup();
    const actions = createActions();
    renderConversation({ actions, core: scriptedCore(), state: settled() });
    const input = await waitFor(() => {
      const candidate = suggestionInput();
      expect(candidate).toBeTruthy();
      return candidate!;
    });
    await user.click(input);
    await user.keyboard("{Tab}");
    expect(actions.setDraft).toHaveBeenCalledWith(
      "Open a pull request for this change."
    );
    expect(actions.send).not.toHaveBeenCalled();
    expect(input).toHaveFocus();
  });

  it.each([
    { key: "Tab", shiftKey: true },
    { key: "Tab", ctrlKey: true },
    { key: "Tab", altKey: true },
    { key: "Tab", metaKey: true },
    { key: "Tab", isComposing: true },
    { key: "Enter" },
  ])("does not accept the placeholder for %j", async (key) => {
    const actions = createActions();
    renderConversation({ actions, core: scriptedCore(), state: settled() });
    const input = await waitFor(() => {
      const candidate = suggestionInput();
      expect(candidate).toBeTruthy();
      return candidate!;
    });
    fireEvent.keyDown(input, key);
    expect(actions.setDraft).not.toHaveBeenCalled();
    expect(actions.send).not.toHaveBeenCalled();
  });

  it("preserves a draft when a suggestion arrives and Tab is pressed", async () => {
    const actions = createActions();
    const core = scriptedCore();
    renderConversation({ actions, core, state: settled({ draft: "half typed" }) });
    await waitFor(() => expect(core.asked).toHaveLength(1));
    const input = screen.getByRole("textbox", { name: "AI prompt" });
    fireEvent.keyDown(input, { key: "Tab" });
    expect(input).toHaveTextContent("half typed");
    expect(actions.setDraft).not.toHaveBeenCalled();
    expect(actions.send).not.toHaveBeenCalled();
  });

  it("clears the suggestion during a new round and replaces it when that round settles", async () => {
    const core = scriptedCore((topic) =>
      topic.message === "msg_a2"
        ? [{ id: "sug_3", label: "Verify", prompt: "Verify the deployed change." }]
        : undefined
    );
    const { setState } = renderConversation({ core, state: settled() });

    await waitFor(() => {
      expect(suggestionInput()).toBeTruthy();
    });
    setState(settled({ awaitingReply: true }));

    await waitFor(() => {
      expect(suggestionInput()).toBeNull();
    });
    setState(settled({ messages: [message("msg_a2", "assistant", "Deployed.")] }));
    await waitFor(() =>
      expect(suggestionInput("Verify the deployed change.")).toBeTruthy()
    );
    expect(core.asked.map((topic) => topic.message)).toEqual(["msg_a1", "msg_a2"]);
  });

  it("offers no follow-up under an open question card, and asks once answered", async () => {
    const core = scriptedCore();
    const openCardMessage = message("msg_q1", "assistant", "Choose one.", {
      parts: [
        {
          kind: "question",
          messageId: "msg_q1",
          prompt: "Choose one?",
          choices: [
            { id: "c1", label: "Option A" },
            { id: "c2", label: "Option B" },
          ],
          multiSelect: false,
          allowOther: true,
          state: { status: "open" },
        },
      ],
    });
    const { setState } = renderConversation({
      core,
      state: settled({ messages: [openCardMessage] }),
    });

    await act(async () => {});
    expect(suggestionInput()).toBeNull();
    expect(core.asked).toEqual([]);

    setState(
      settled({
        messages: [
          message("msg_q1", "assistant", "Choose one.", {
            parts: [
              {
                kind: "question",
                messageId: "msg_q1",
                prompt: "Choose one?",
                choices: [
                  { id: "c1", label: "Option A" },
                  { id: "c2", label: "Option B" },
                ],
                multiSelect: false,
                allowOther: true,
                state: { status: "answered", choiceIds: ["c1"] },
              },
            ],
          }),
        ],
      })
    );

    await waitFor(() => expect(core.asked).toHaveLength(1));
  });

  it("offers no follow-up under a Task's brief, before its Worker has answered", async () => {
    const core = scriptedCore();
    const { setState } = renderConversation({
      core,
      state: settled({
        messages: [message("msg_brief", "assistant", "Build it.", { brief: true })],
      }),
    });

    await act(async () => {});
    expect(core.asked).toEqual([]);
    expect(suggestionInput()).toBeNull();

    setState(
      settled({
        messages: [
          message("msg_brief", "assistant", "Build it.", { brief: true }),
          message("msg_a1", "assistant", "Built."),
        ],
      })
    );
    await waitFor(() => expect(suggestionInput()).toBeTruthy());
  });

  it("offers no follow-up while a Task's Worker is at work", async () => {
    const core = scriptedCore();
    renderConversation({
      core,
      state: settled({
        participantStatuses: [
          {
            actorRole: "worker",
            conversationId: "cnv_1",
            participantId: "par_w",
            state: "active",
            status: "working",
            updatedAt: 1,
          },
        ],
      }),
    });

    await act(async () => {});
    expect(core.asked).toEqual([]);
    expect(suggestionInput()).toBeNull();
  });

  it("offers no follow-up while a started Task's sandbox starts, and offers the reply's once it is ready", async () => {
    const core = scriptedCore();
    const task = (state: string) =>
      settled({
        conversation: {
          id: "cnv_1",
          group_id: "grp_1",
          kind: "agent_task",
          status: "in_progress",
          title: "Task",
        },
        messages: [
          message("msg_brief", "assistant", "Build it.", { brief: true }),
          message("msg_a1", "assistant", "Built."),
        ],
        participantStatuses: [],
        taskRun: {
          place: {
            kind: "sandbox",
            state,
            repo: { owner: "AFK-surf", name: "Cue", branch: "fix/task" },
          },
          vendor: "anthropic",
        },
      });
    const { setState } = renderConversation({ core, state: task("starting") });

    const slot = await screen.findByTestId("participant-status-slot");
    await act(async () => {});
    expect(slot).toHaveAttribute("data-active", "true");
    expect(slot).toHaveTextContent("Working");
    expect(core.asked).toEqual([]);
    expect(suggestionInput()).toBeNull();

    setState(task("ready"));
    await waitFor(() => expect(suggestionInput()).toBeTruthy());
    expect(core.asked.map((topic) => topic.message)).toEqual(["msg_a1"]);
  });

  it.each([
    {
      name: "a request the Router brought in",
      newest: message("msg_req", "assistant", "Fix the login page.", {
        routerRequest: true,
      }),
    },
    {
      name: "a run whose model cannot start",
      newest: message("msg_blocked", "assistant", "The model cannot start.", {
        messageType: "task_run_blocked",
      }),
    },
    {
      name: "a system notice",
      newest: message("msg_switched", "assistant", "Switched to another model.", {
        actorType: "system",
        messageType: "task_run_switched",
      }),
    },
    {
      name: "a person's message not answered yet",
      newest: message("msg_u2", "user", "Now add tests."),
    },
  ])("offers no follow-up when the newest message is $name", async ({ newest }) => {
    const core = scriptedCore();
    renderConversation({
      core,
      state: settled({
        messages: [
          message("msg_u1", "user", "Refactor the parser"),
          message("msg_a1", "assistant", "Done — here is the diff."),
          newest,
        ],
      }),
    });

    await screen.findByText("Done — here is the diff.");
    await act(async () => {});
    expect(core.asked).toEqual([]);
    expect(suggestionInput()).toBeNull();
  });

  it.each([
    { name: "renders nothing when the core has no suggestions", value: [] },
    { name: "renders nothing while the core is still asking", value: null },
    { name: "renders nothing when the topic fails", value: new Error("boom") },
  ])("$name", async ({ value }) => {
    const core = scriptedCore(() => value);
    renderConversation({ core, state: settled() });

    await waitFor(() => expect(core.asked).toHaveLength(1));
    expect(screen.queryByTestId("chat-suggestions")).toBeNull();
    expect(suggestionInput()).toBeNull();
  });

  it("stays out of the rail chat", async () => {
    const core = scriptedCore();
    renderConversation({ core, state: settled(), variant: "rail" });

    await waitFor(() => {
      expect(
        document.querySelector('[data-slot="chat-assistant-output"]')
      ).toBeTruthy();
    });
    expect(core.asked).toEqual([]);
    expect(suggestionInput()).toBeNull();
  });
});

const defaultSuggestions: ChatSuggestion[] = [
  { id: "sug_1", label: "Ship it", prompt: "Open a pull request for this change." },
  { id: "sug_2", label: "Add tests", prompt: "Add tests for the new parser." },
];

const unavailableHistory = {
  available: false,
  start: 0,
  total: 0,
  items: [],
  usage: null,
};

/**
 * A core answering `chatSuggestions` with `answer(topic)` (the default suggestions when it gives undefined), and the
 * topics the UI asked, in order.
 */
function scriptedCore(
  answer: (topic: Record<string, unknown>) => unknown = () => undefined
) {
  const asked: Record<string, unknown>[] = [];
  const core = createScriptedCore({
    values: (topic) => {
      if (topic.topic !== "chatSuggestions") return undefined;
      const value = answer(topic);
      return value === undefined ? defaultSuggestions : value;
    },
    onSubscribe: (topic) => {
      if (topic.topic === "chatSuggestions") asked.push(topic);
    },
    // A coding Task's sandbox that is not running answers no history.
    calls: (name) => (name === "coding.history" ? unavailableHistory : null),
  });
  return { asked, wrap: core.wrap };
}

function createActions(): ConversationViewActions {
  return {
    attachFiles: vi.fn(),
    discard: vi.fn(),
    refresh: vi.fn(),
    removeAttachment: vi.fn(),
    retry: vi.fn(),
    retryAttachment: vi.fn(),
    send: vi.fn(),
    setDraft: vi.fn(),
  };
}

function settled(
  overrides: Partial<ConversationChannelState> = {}
): ConversationChannelState {
  return {
    activity: undefined,
    assistantDraft: undefined,
    awaitingReply: false,
    awaitingSince: undefined,
    awaitingTimedOut: false,
    connection: "live",
    conversation: {
      id: "cnv_1",
      group_id: "grp_1",
      kind: "user_chat",
      status: "completed",
      title: "Chat",
    },
    draft: "",
    draftAttachments: [],
    errorKind: undefined,
    lastBackoffMs: 0,
    messages: [
      message("msg_u1", "user", "Refactor the parser"),
      message("msg_a1", "assistant", "Done — here is the diff."),
    ],
    participantStatus: undefined,
    pending: [],
    serverMessages: [],
    status: "ready",
    syncWarning: undefined,
    ...overrides,
  };
}

function message(
  messageId: string,
  role: string,
  text: string,
  overrides: Partial<ChatMessage> = {}
): ChatMessage {
  return {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: undefined,
    createdAt: 1,
    createdBy: undefined,
    delivery: "sent",
    error: undefined,
    messageId,
    parts: [{ kind: "markdown", text }],
    refs: [],
    role,
    source: "server",
    status: "completed",
    text,
    ...overrides,
  };
}

function renderConversation({
  actions = createActions(),
  core,
  locale: initialLocale = "en",
  state: initialState,
  variant = "route",
}: {
  actions?: ConversationViewActions;
  core: ReturnType<typeof scriptedCore>;
  locale?: CommaLocale;
  state: ConversationChannelState;
  variant?: "home" | "rail" | "route";
}) {
  let setViewState: ((next: ConversationChannelState) => void) | undefined;
  let setViewLocale: ((next: CommaLocale) => void) | undefined;

  function RouteComponent() {
    const [viewState, setState] = useState(initialState);
    const [viewLocale, setLocale] = useState<CommaLocale>(initialLocale);
    const draftSource = useMemo(
      () => fixedDraftSource(viewState.draft),
      [viewState.draft]
    );
    setViewState = setState;
    setViewLocale = setLocale;
    return (
      <CommaI18nProvider locale={viewLocale}>
        <ConversationView
          actions={actions}
          draftSource={draftSource}
          groupId="grp_1"
          state={viewState}
          variant={variant}
          workspaceId="wsp_1"
        />
      </CommaI18nProvider>
    );
  }

  const rootRoute = createRootRoute({ component: Outlet });
  const conversationRoute = createRoute({
    component: RouteComponent,
    getParentRoute: () => rootRoute,
    path: "/",
  });
  const inboxRoute = createRoute({
    component: () => null,
    getParentRoute: () => rootRoute,
    path: "/inbox",
  });
  const targetConversationRoute = createRoute({
    component: () => null,
    getParentRoute: () => rootRoute,
    path: "/inbox/$workspaceId/$groupId/$conversationId",
  });
  const router = createRouter({
    history: createMemoryHistory({ initialEntries: ["/"] }),
    routeTree: rootRoute.addChildren([
      conversationRoute,
      inboxRoute,
      targetConversationRoute,
    ]),
  });

  return {
    ...render(core.wrap(<RouterProvider router={router} />)),
    setLocale: (next: CommaLocale) => {
      if (!setViewLocale) throw new Error("Conversation route did not render.");
      setViewLocale(next);
    },
    setState: (next: ConversationChannelState) => {
      if (!setViewState) throw new Error("Conversation route did not render.");
      setViewState(next);
    },
  };
}

function suggestionInput(prompt = "Open a pull request for this change.") {
  const input = screen.queryByRole("textbox");
  return input?.getAttribute("data-placeholder") === prompt ? input : null;
}
