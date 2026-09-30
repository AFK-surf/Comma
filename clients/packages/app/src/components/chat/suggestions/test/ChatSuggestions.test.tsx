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
import type { CommaApiClient, CommaChatSuggestion } from "../../../../api";
import {
  ConversationView,
  type ConversationViewActions,
} from "../../conversation/ConversationView";
import { fixedDraftSource } from "../../composer/conversationDraft";
import type {
  ChatMessage,
  ConversationChannelState,
} from "../../model/conversationChannel";

describe("chat follow-up placeholder", () => {
  beforeEach(() => {
    initializeCommaI18n(["en"]);
  });

  it("asks for suggestions once a turn settles and shows the first prompt as a placeholder", async () => {
    const api = stubApi();
    renderConversation({ api, state: settled() });

    await waitFor(() => expect(suggestionInput()).toBeTruthy());
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveTextContent("");
    expect(api.generateChatSuggestions).toHaveBeenCalledTimes(1);
    expect(api.generateChatSuggestions).toHaveBeenCalledWith(
      "grp_1",
      "cnv_1",
      expect.objectContaining({ locale: "en" })
    );
  });

  it("re-rendering the same settled turn does not ask again", async () => {
    const api = stubApi();
    const { setState } = renderConversation({ api, state: settled() });

    await waitFor(() => {
      expect(suggestionInput()).toBeTruthy();
    });
    // A draft keystroke republishes the whole snapshot; the response key is
    // what identifies the turn, so this must not spend a second generation.
    setState(settled({ draft: "typing" }));
    await waitFor(() =>
      expect(screen.getByRole("textbox")).toHaveTextContent("typing")
    );

    expect(api.generateChatSuggestions).toHaveBeenCalledTimes(1);
  });

  // COMMA-274: the suggestions are model-written, so the language they were generated
  // in outlives a language switch unless the locale is part of the request key.
  it("regenerates the suggestions when the interface language changes", async () => {
    const api = stubApi();
    const { setLocale } = renderConversation({ api, state: settled() });

    await waitFor(() => {
      expect(api.generateChatSuggestions).toHaveBeenCalledTimes(1);
    });
    expect(api.generateChatSuggestions).toHaveBeenLastCalledWith(
      "grp_1",
      "cnv_1",
      expect.objectContaining({ locale: "en" })
    );

    setLocale("zh-CN");

    await waitFor(() => {
      expect(api.generateChatSuggestions).toHaveBeenCalledTimes(2);
    });
    expect(api.generateChatSuggestions).toHaveBeenLastCalledWith(
      "grp_1",
      "cnv_1",
      expect.objectContaining({ locale: "zh-CN" })
    );
  });

  it.each(["success", "failure"] as const)(
    "keeps the new language when the old request finishes with %s",
    async (outcome) => {
      const oldRequest = Promise.withResolvers<CommaChatSuggestion[]>();
      const newRequest = Promise.withResolvers<CommaChatSuggestion[]>();
      const api = stubApi();
      api.generateChatSuggestions
        .mockImplementationOnce(() => oldRequest.promise)
        .mockImplementationOnce(() => newRequest.promise);
      const { setLocale } = renderConversation({ api, state: settled() });
      await waitFor(() => {
        expect(api.generateChatSuggestions).toHaveBeenCalledTimes(1);
      });
      const oldSignal = api.generateChatSuggestions.mock.calls[0]?.[2]?.signal;

      await act(async () => setLocale("zh-CN"));
      await waitFor(() => {
        expect(api.generateChatSuggestions).toHaveBeenCalledTimes(2);
      });
      await act(async () => {
        newRequest.resolve([
          { id: "sug_zh", label: "添加测试", prompt: "为解析器添加测试。" },
        ]);
      });
      expect(suggestionInput("为解析器添加测试。")).toBeTruthy();

      // Settle even after cancellation to exercise both stale callback paths.
      await act(async () => {
        if (outcome === "success") {
          oldRequest.resolve([
            { id: "sug_en", label: "Old suggestion", prompt: "Old prompt" },
          ]);
        } else {
          oldRequest.reject(new Error("Old request failed"));
        }
      });
      expect(suggestionInput("Old prompt")).toBeNull();
      expect(suggestionInput("为解析器添加测试。")).toBeTruthy();
      expect(oldSignal?.aborted).toBe(true);
      expect(api.generateChatSuggestions).toHaveBeenCalledTimes(2);
    }
  );

  it("accepts Tab into the draft without sending", async () => {
    const user = userEvent.setup();
    const actions = createActions();
    renderConversation({ actions, api: stubApi(), state: settled() });
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
    renderConversation({ actions, api: stubApi(), state: settled() });
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
    const api = stubApi();
    renderConversation({ actions, api, state: settled({ draft: "half typed" }) });
    await waitFor(() => expect(api.generateChatSuggestions).toHaveBeenCalledTimes(1));
    const input = screen.getByRole("textbox", { name: "AI prompt" });
    fireEvent.keyDown(input, { key: "Tab" });
    expect(input).toHaveTextContent("half typed");
    expect(actions.setDraft).not.toHaveBeenCalled();
    expect(actions.send).not.toHaveBeenCalled();
  });

  it("clears the suggestion during a new round and replaces it when that round settles", async () => {
    const api = stubApi();
    const { setState } = renderConversation({ api, state: settled() });

    await waitFor(() => {
      expect(suggestionInput()).toBeTruthy();
    });
    setState(settled({ awaitingReply: true }));

    await waitFor(() => {
      expect(suggestionInput()).toBeNull();
    });
    api.generateChatSuggestions.mockResolvedValueOnce([
      { id: "sug_1", label: "Verify", prompt: "Verify the deployed change." },
    ]);
    setState(settled({ messages: [message("msg_a2", "assistant", "Deployed.")] }));
    await waitFor(() =>
      expect(suggestionInput("Verify the deployed change.")).toBeTruthy()
    );
    expect(api.generateChatSuggestions).toHaveBeenCalledTimes(2);
  });

  it("renders nothing when the generation comes back empty", async () => {
    const api = stubApi([]);
    renderConversation({ api, state: settled() });

    await waitFor(() => {
      expect(api.generateChatSuggestions).toHaveBeenCalledTimes(1);
    });
    expect(suggestionInput()).toBeNull();
  });

  it("renders nothing when the generation fails", async () => {
    const api = {
      generateChatSuggestions: vi.fn().mockRejectedValue(new Error("boom")),
    } as unknown as CommaApiClient & {
      generateChatSuggestions: ReturnType<typeof vi.fn>;
    };
    renderConversation({ api, state: settled() });

    await waitFor(() => {
      expect(api.generateChatSuggestions).toHaveBeenCalledTimes(1);
    });
    expect(suggestionInput()).toBeNull();
  });

  it("stays out of the side chat", async () => {
    const api = stubApi();
    renderConversation({ api, state: settled(), variant: "side-chat" });

    await waitFor(() => {
      expect(
        document.querySelector('[data-slot="chat-assistant-output"]')
      ).toBeTruthy();
    });
    expect(api.generateChatSuggestions).not.toHaveBeenCalled();
    expect(suggestionInput()).toBeNull();
  });
});

function stubApi(
  suggestions = [
    { id: "sug_1", label: "Ship it", prompt: "Open a pull request for this change." },
    { id: "sug_2", label: "Add tests", prompt: "Add tests for the new parser." },
  ]
) {
  return {
    generateChatSuggestions: vi.fn().mockResolvedValue(suggestions),
  } as unknown as CommaApiClient & {
    generateChatSuggestions: ReturnType<typeof vi.fn>;
  };
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
  api,
  locale: initialLocale = "en",
  state: initialState,
  variant = "route",
}: {
  actions?: ConversationViewActions;
  api: CommaApiClient;
  locale?: CommaLocale;
  state: ConversationChannelState;
  variant?: "home" | "rail" | "route" | "side-chat";
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
          api={api}
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
    ...render(<RouterProvider router={router} />),
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
