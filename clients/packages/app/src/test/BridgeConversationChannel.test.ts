import {
  chatProtocolVersion,
  type ChatRuntimeDraftsSnapshot,
  type ChatRuntimeSnapshot,
  type ChatSetDraftInput,
} from "@comma/chat-contract";
import type { SessionProductLease } from "@comma/session-contract";
import { installNativeBridgeMock as installNativeBridgeMockBase } from "@comma/test-utils/native-bridge";
import type {
  ChatMessage,
  ConversationChannelState,
} from "../components/chat/model/conversationChannel";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BridgeConversationChannel as SessionBoundBridgeConversationChannel } from "../runtime-chat/channel/BridgeConversationChannel";
import { testProductLease } from "./productInboxProjectionHarness";

class BridgeConversationChannel extends SessionBoundBridgeConversationChannel {
  constructor(
    options: Omit<
      ConstructorParameters<typeof SessionBoundBridgeConversationChannel>[0],
      "session"
    >
  ) {
    super({ ...options, session: testProductLease });
  }
}

describe("BridgeConversationChannel", () => {
  afterEach(() => {
    globalThis.commaNative = undefined;
    vi.restoreAllMocks();
  });

  it("preserves Router and Worker attribution through the Electron projection", async () => {
    const routerMessage = {
      ...message("message-router", "Router reply"),
      actorId: "actor-router",
      actorRole: "router" as const,
    };
    const workerMessage = {
      ...message("message-worker", "Worker reply"),
      actorId: "actor-worker",
      actorRole: "worker" as const,
    };
    const projected = snapshot("", {
      messages: [routerMessage, workerMessage],
      serverMessages: [routerMessage, workerMessage],
    });
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: {
          get: vi.fn(async () => projected),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            listener(projected);
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));

    expect(channel.getSnapshot().serverMessages.map((item) => item.actorRole)).toEqual([
      "router",
      "worker",
    ]);
    expect(channel.getSnapshot().serverMessages.map((item) => item.actorId)).toEqual([
      "actor-router",
      "actor-worker",
    ]);
    channel.stop();
  });

  it("preserves Main-owned local awaiting state through the Electron projection", async () => {
    const projected = snapshot("", {
      awaitingReply: true,
      awaitingTurnKey: "request-current",
      locallyAwaitingReply: true,
    });
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: {
          get: vi.fn(async () => projected),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            listener(projected);
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));

    expect(channel.getSnapshot()).toMatchObject({
      awaitingReply: true,
      awaitingTurnKey: "request-current",
      locallyAwaitingReply: true,
    });
    channel.stop();
  });

  it("preserves the canonical Task review version through the Electron Chat projection", async () => {
    const readyForReview = snapshot("");
    readyForReview.sessions[0]!.state.conversation = {
      groupId: "grp_test",
      id: "conversation-1",
      kind: "agent_task",
      reviewVersion: 2,
      status: "ready_for_review",
      title: "Review Task",
      workspaceId: "workspace-1",
    };
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: {
          get: vi.fn(async () => readyForReview),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            listener(readyForReview);
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));

    expect(channel.getSnapshot().conversation).toMatchObject({
      id: "conversation-1",
      review_version: 2,
      status: "ready_for_review",
    });
    channel.stop();
  });

  it("queues renderer commands until Main has retained the chat session", async () => {
    let resolveRetain: ((value: { revision: number }) => void) | undefined;
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const retain = vi.fn(
      () =>
        new Promise<{ revision: number }>((resolve) => {
          resolveRetain = resolve;
        })
    );
    const setDraft = vi.fn(async (input: ChatSetDraftInput) => {
      stateListener?.(snapshot(input.draft, { draftEpoch: 1, revision: 2 }));
      return { draftEpoch: 1, revision: 2 };
    });
    const send = vi.fn(async () => ({ revision: 3 }));
    const state = {
      get: vi.fn(async () => snapshot("")),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        stateListener = listener;
        listener(snapshot(""));
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        retain: retain as never,
        send: send as never,
        setDraft: setDraft as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    const draftCommand = channel.setDraft("Comma Center Electron smoke");
    const sendCommand = channel.send("Comma Center Electron smoke");

    expect(channel.getSnapshot().draft).toBe("Comma Center Electron smoke");
    expect(setDraft).not.toHaveBeenCalled();
    expect(send).not.toHaveBeenCalled();

    resolveRetain?.({ revision: 1 });
    await Promise.all([draftCommand, sendCommand]);

    expect(setDraft).toHaveBeenCalledWith({
      conversationId: "conversation-1",
      draft: "Comma Center Electron smoke",
      groupId: "grp_test",
      leaseId: expect.any(String),
      session: testProductLease,
      subscriberId: "renderer-1:grp_test/conversation-1",
      surfaceId: "renderer-1",
      workspaceId: "workspace-1",
    });
    expect(send).toHaveBeenCalledWith({
      conversationId: "conversation-1",
      groupId: "grp_test",
      leaseId: expect.any(String),
      sendIntentId: expect.any(String),
      session: testProductLease,
      subscriberId: "renderer-1:grp_test/conversation-1",
      surfaceId: "renderer-1",
      text: "Comma Center Electron smoke",
      workspaceId: "workspace-1",
    });
    expect(channel.getSnapshot().draft).toBe("Comma Center Electron smoke");

    channel.stop();
  });

  it("does not replace an optimistic renderer draft with stale Main snapshots", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        setDraft: vi.fn(async () => ({ draftEpoch: 1, revision: 2 })) as never,
        state: {
          get: vi.fn(async () => snapshot("", { draftEpoch: 0 })),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            stateListener = listener;
            listener(snapshot("", { draftEpoch: 0 }));
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "side-chat-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await channel.setDraft("你");
    expect(channel.getSnapshot().draft).toBe("你");

    stateListener?.(snapshot("", { draftEpoch: 0, revision: 2 }));
    expect(channel.getSnapshot().draft).toBe("你");

    stateListener?.(snapshot("你", { draftEpoch: 1, revision: 3 }));
    expect(channel.getSnapshot().draft).toBe("你");

    stateListener?.(snapshot("", { draftEpoch: 2, revision: 4 }));
    expect(channel.getSnapshot().draft).toBe("");
    channel.stop();
  });

  it("orders Main's draft echoes by epoch, so a late echo cannot restore deleted text", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const receipts = [
      deferred<{ draftEpoch: number; revision: number }>(),
      deferred<{ draftEpoch: number; revision: number }>(),
      deferred<{ draftEpoch: number; revision: number }>(),
    ];
    const setDraft = vi.fn(() => receipts[setDraft.mock.calls.length - 1]!.promise);
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(async () => ({ draftEpoch: 0, revision: 1 })) as never,
        setDraft: setDraft as never,
        state: {
          get: vi.fn(async () => snapshot("", { draftEpoch: 0 })),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            stateListener = listener;
            listener(snapshot("", { draftEpoch: 0 }));
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });
    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));

    // Type "b", then delete it, faster than Main acknowledges.
    const edits = ["a", "ab", "a"].map((draft) => channel.setDraft(draft));
    // Main applies each edit in order and publishes it before its receipt.
    for (const [index, draft] of ["a", "ab", "a"].entries()) {
      await vi.waitFor(() => expect(setDraft).toHaveBeenCalledTimes(index + 1));
      stateListener?.(snapshot(draft, { draftEpoch: index + 1, revision: index + 2 }));
      expect(channel.getSnapshot().draft).toBe("a");
      receipts[index]!.resolve({ draftEpoch: index + 1, revision: index + 2 });
    }
    await Promise.all(edits);
    expect(channel.getSnapshot().draft).toBe("a");

    // A later change from another surface or a send is Main's to show.
    stateListener?.(snapshot("", { draftEpoch: 4, revision: 5 }));
    expect(channel.getSnapshot().draft).toBe("");
    channel.stop();
  });

  it("mirrors another surface's draft from the drafts stream alone", async () => {
    let draftsListener: ((drafts: ChatRuntimeDraftsSnapshot) => void) | undefined;
    installNativeBridgeMock({
      chat: {
        drafts: {
          get: vi.fn(async () => drafts("", 0)),
          subscribe: vi.fn((listener: (next: ChatRuntimeDraftsSnapshot) => void) => {
            draftsListener = listener;
            listener(drafts("", 0));
            return vi.fn();
          }),
        } as never,
        retain: vi.fn(async () => ({ draftEpoch: 0, revision: 1 })) as never,
        state: {
          get: vi.fn(async () => snapshot("", { draftEpoch: 0 })),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            listener(snapshot("", { draftEpoch: 0 }));
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "side-chat-window", windowId: "renderer-2" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });
    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));
    const transcript = channel.getSnapshot().messages;

    draftsListener?.(drafts("typed in the main window", 3));
    expect(channel.getSnapshot().draft).toBe("typed in the main window");
    expect(channel.getSnapshot().messages).toBe(transcript);

    // A replayed, older publication cannot roll the mirror back.
    draftsListener?.(drafts("typed in the main", 2));
    expect(channel.getSnapshot().draft).toBe("typed in the main window");
    channel.stop();
  });

  it("drops a late Chat projection from a replaced Session generation", async () => {
    let stateListener:
      | ((envelope: ReturnType<typeof stateEnvelope>) => void)
      | undefined;
    const state = {
      get: vi.fn(async () => stateEnvelope(snapshot("current draft"))),
      subscribe: vi.fn(
        (listener: (envelope: ReturnType<typeof stateEnvelope>) => void) => {
          stateListener = listener;
          listener(stateEnvelope(snapshot("current draft")));
          return vi.fn();
        }
      ),
    };
    installNativeBridgeMockBase({
      chat: {
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().draft).toBe("current draft"));
    stateListener?.(
      stateEnvelope(snapshot("account A late draft", { revision: 2 }), {
        ...testProductLease,
        generation: testProductLease.generation + 1,
        sessionId: "ses_replaced",
      })
    );
    expect(channel.getSnapshot().draft).toBe("current draft");

    stateListener?.(
      stateEnvelope(snapshot("account B current draft", { revision: 3 }))
    );
    expect(channel.getSnapshot().draft).toBe("account B current draft");
    expect(state.get).toHaveBeenCalledWith({ session: testProductLease });
    channel.stop();
  });

  it("selects only its Main-owned surface projection and clears through the exact lease", async () => {
    const canonicalMessage = message("message-canonical", "Canonical history");
    const projectedMessage = message("message-projected", "After clear");
    const projectedParticipantStatus = {
      conversationId: "conversation-1",
      participantId: "participant-1",
      state: "active" as const,
      status: "is thinking...",
      updatedAt: 1,
    };
    const runtime = snapshot("", { messages: [canonicalMessage] });
    const session = runtime.sessions[0]!;
    session.state.serverMessages = [canonicalMessage];
    session.surfaceProjections = [
      {
        generation: 1,
        state: {
          ...session.state,
          messages: [message("message-other", "Other surface")],
          serverMessages: [message("message-other", "Other surface")],
        },
        subscriberId: "renderer-other:grp_test/conversation-1",
      },
      {
        generation: 2,
        state: {
          ...session.state,
          messages: [projectedMessage],
          participantStatus: projectedParticipantStatus,
          participantStatuses: [
            {
              ...projectedParticipantStatus,
              name: "Router",
              actorId: "actor_router",
              actorRole: "router",
            },
            {
              ...projectedParticipantStatus,
              participantId: "participant-2",
              name: "Worker",
              actorId: "actor_worker",
              actorRole: "worker",
            },
          ],
          serverMessages: [projectedMessage],
        },
        subscriberId: "renderer-1:grp_test/conversation-1",
      },
    ];
    const clearPresentation = vi.fn(async () => ({ revision: 2 }));
    installNativeBridgeMock({
      chat: {
        clearPresentation,
        retain: vi.fn(async () => ({ revision: 1 })),
        state: {
          get: vi.fn(async () => runtime),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            listener(runtime);
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "side-chat-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() =>
      expect(channel.getSnapshot().messages).toEqual([projectedMessage])
    );
    expect(channel.getSnapshot().participantStatus).toEqual(projectedParticipantStatus);
    expect(channel.getSnapshot().participantStatuses).toMatchObject([
      {
        name: "Router",
        participantId: "participant-1",
        actorId: "actor_router",
        actorRole: "router",
      },
      {
        name: "Worker",
        participantId: "participant-2",
        actorId: "actor_worker",
        actorRole: "worker",
      },
    ]);
    await channel.clearPresentation();

    expect(channel.getSnapshot().messages).not.toContainEqual(canonicalMessage);
    expect(clearPresentation).toHaveBeenCalledWith({
      conversationId: "conversation-1",
      groupId: "grp_test",
      leaseId: expect.any(String),
      session: testProductLease,
      subscriberId: "renderer-1:grp_test/conversation-1",
      workspaceId: "workspace-1",
    });
    channel.stop();
  });

  it("clears a previously seen session on a newer missing snapshot without erasing a pre-retain draft", async () => {
    const retain = deferred<{ revision: number }>();
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const materialized = snapshot("native draft", {
      messages: [message("message-private", "Account A private history")],
      revision: 2,
      sessionRevision: 2,
    });
    const state = {
      get: vi.fn(async () => materialized),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        stateListener = listener;
        listener(emptySnapshot(0));
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(() => retain.promise) as never,
        setDraft: vi.fn(async () => ({ revision: 2 })) as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    const queuedDraft = channel.setDraft("queued before retain");
    stateListener?.(emptySnapshot(1));
    expect(channel.getSnapshot().draft).toBe("queued before retain");

    retain.resolve({ revision: 1 });
    await queuedDraft;
    await vi.waitFor(() =>
      expect(channel.getSnapshot().messages.map((item) => item.text)).toEqual([
        "Account A private history",
      ])
    );

    const listener = vi.fn();
    channel.subscribe(listener);
    stateListener?.(emptySnapshot(3));
    expect(channel.getSnapshot()).toMatchObject({
      activity: undefined,
      assistantDraft: undefined,
      connection: "idle",
      draft: "",
      draftAttachments: [],
      messages: [],
      pending: [],
      serverMessages: [],
      status: "idle",
    });
    expect(listener).toHaveBeenCalledOnce();
    channel.stop();
  });

  it("paints a seeded transcript immediately and yields only to a settled projection", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const state = {
      get: vi.fn(async () =>
        snapshot("", { revision: 1, sessionRevision: 0, status: "loading" })
      ),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        stateListener = listener;
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const seededHistory = [channelMessage("message-history", "Carried history")];
    const seededConversation = {
      group_id: "grp_test",
      id: "conversation-1",
      kind: "user_chat" as const,
      messages: [],
      status: "open",
      title: "Carried title",
    };
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      initialState: {
        ...seededState(seededHistory),
        conversation: seededConversation,
      },
      workspaceId: "workspace-1",
    });

    // The seed paints before any native round-trip.
    expect(channel.getSnapshot().messages).toBe(seededHistory);
    expect(channel.getSnapshot().syncWarning).toBe("stale");

    channel.start();
    // The rebuilt Main entry's pre-canonical loading publish must not blank
    // the seeded transcript.
    await vi.waitFor(() => expect(state.get).toHaveBeenCalledOnce());
    expect(channel.getSnapshot().messages.map((item) => item.text)).toEqual([
      "Carried history",
    ]);
    expect(channel.getSnapshot().syncWarning).toBe("stale");

    // A send accepted in the interim overlays the seeded transcript.
    stateListener?.(
      snapshot("", {
        messages: [
          {
            ...message("pending:req-1", "Sent while seeded"),
            delivery: "sending" as const,
            source: "pending" as const,
          },
        ],
        pending: [
          {
            clientRequestId: "req-1",
            createdAt: 1,
            status: "sending",
            text: "Sent while seeded",
          },
        ] as never,
        revision: 2,
        status: "loading",
      })
    );
    expect(channel.getSnapshot().messages.map((item) => item.text)).toEqual([
      "Carried history",
      "Sent while seeded",
    ]);
    // The seeded conversation metadata is pinned while the rebuilt entry has
    // none of its own.
    expect(channel.getSnapshot().conversation).toBe(seededConversation);

    // A later interim publish whose pending was discarded must not leave a
    // ghost bubble: the overlay is rebuilt from the seed plus CURRENT pending
    // rows every time.
    stateListener?.(
      snapshot("", {
        messages: [],
        pending: [],
        revision: 3,
        status: "loading",
      })
    );
    expect(channel.getSnapshot().messages.map((item) => item.text)).toEqual([
      "Carried history",
    ]);
    expect(channel.getSnapshot().messages[0]).toBe(seededHistory[0]);

    // The settled canonical projection adopts wholesale, and value-identical
    // rows keep the seeded object identities.
    stateListener?.(
      snapshot("", {
        messages: [
          message("message-history", "Carried history"),
          message("message-reply", "Fresh canonical reply"),
        ],
        revision: 4,
        serverMessages: [
          message("message-history", "Carried history"),
          message("message-reply", "Fresh canonical reply"),
        ],
      })
    );
    expect(channel.getSnapshot().messages.map((item) => item.text)).toEqual([
      "Carried history",
      "Fresh canonical reply",
    ]);
    expect(channel.getSnapshot().serverMessages[0]).toBe(seededHistory[0]);
    expect(channel.getSnapshot().syncWarning).toBeUndefined();
    channel.stop();
  });

  it("yields a seeded transcript to a settled empty conversation and clears on a missing session", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const state = {
      get: vi.fn(async () => snapshot("", { revision: 1, sessionRevision: 1 })),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        stateListener = listener;
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      initialState: seededState([channelMessage("message-history", "Carried history")]),
      workspaceId: "workspace-1",
    });

    channel.start();
    // Main settled with a genuinely empty conversation: the server is the
    // source of truth, so the seed yields even though the result is emptier.
    await vi.waitFor(() => expect(channel.getSnapshot().messages).toEqual([]));
    expect(channel.getSnapshot().syncWarning).toBeUndefined();

    // And the missing-session hygiene applies to seeded channels unchanged.
    stateListener?.(
      snapshot("", {
        messages: [message("message-back", "Back again")],
        revision: 2,
      })
    );
    stateListener?.(emptySnapshot(3));
    expect(channel.getSnapshot().status).toBe("idle");
    expect(channel.getSnapshot().messages).toEqual([]);
    channel.stop();
  });

  it("keeps a seeded transcript visible beneath a settled error projection", async () => {
    const state = {
      get: vi.fn(async () => {
        const errored = snapshot("", {
          revision: 1,
          sessionRevision: 1,
          status: "error",
        });
        errored.sessions[0]!.state.errorKind = "network";
        return errored;
      }),
      subscribe: vi.fn(() => vi.fn()),
    };
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      initialState: seededState([channelMessage("message-history", "Carried history")]),
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("error"));
    expect(channel.getSnapshot().errorKind).toBe("network");
    expect(channel.getSnapshot().messages.map((item) => item.text)).toEqual([
      "Carried history",
    ]);
    channel.stop();
  });

  it("fences queued work and cleanup to the exact lifecycle whose retain receipt was delayed", async () => {
    const firstRetain = deferred<{ revision: number }>();
    const retain = vi
      .fn()
      .mockImplementationOnce(() => firstRetain.promise)
      .mockResolvedValueOnce({ revision: 2 });
    const release = vi.fn(async () => ({ revision: 3 }));
    const setDraft = vi.fn(async () => ({ revision: 3 }));
    const state = {
      get: vi.fn(async () => snapshot("")),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        listener(snapshot(""));
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        release: release as never,
        retain: retain as never,
        setDraft: setDraft as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const staleChannel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });
    const currentChannel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    staleChannel.start();
    const staleDraft = staleChannel.setDraft("account A private draft");
    staleChannel.stop();

    currentChannel.start();
    await vi.waitFor(() => expect(state.get).toHaveBeenCalledOnce());
    expect(retain).toHaveBeenCalledTimes(2);
    const staleRetain = retain.mock.calls[0]?.[0] as
      | { leaseId?: string; subscriberId?: string }
      | undefined;
    const currentRetain = retain.mock.calls[1]?.[0] as
      | { leaseId?: string; subscriberId?: string }
      | undefined;
    expect(staleRetain).toMatchObject({
      groupId: "grp_test",
      leaseId: expect.any(String),
      session: testProductLease,
      subscriberId: "renderer-1:grp_test/conversation-1",
    });
    expect(currentRetain).toMatchObject({
      leaseId: expect.any(String),
      subscriberId: staleRetain?.subscriberId,
    });
    expect(currentRetain?.leaseId).not.toBe(staleRetain?.leaseId);

    firstRetain.resolve({ revision: 1 });
    await expect(staleDraft).rejects.toThrow("Chat bridge is not retained.");
    expect(setDraft).not.toHaveBeenCalledWith(
      expect.objectContaining({ draft: "account A private draft" })
    );
    await vi.waitFor(() => expect(release).toHaveBeenCalledOnce());
    expect(release).toHaveBeenCalledWith({
      conversationId: "conversation-1",
      groupId: "grp_test",
      leaseId: staleRetain?.leaseId,
      session: testProductLease,
      subscriberId: staleRetain?.subscriberId,
      workspaceId: "workspace-1",
    });

    await currentChannel.setDraft("account B current draft");
    expect(setDraft).toHaveBeenCalledOnce();
    expect(setDraft).toHaveBeenCalledWith({
      conversationId: "conversation-1",
      draft: "account B current draft",
      groupId: "grp_test",
      leaseId: currentRetain?.leaseId,
      session: testProductLease,
      subscriberId: currentRetain?.subscriberId,
      surfaceId: "renderer-1",
      workspaceId: "workspace-1",
    });

    currentChannel.stop();
    await vi.waitFor(() => expect(release).toHaveBeenCalledTimes(2));
    expect(release).toHaveBeenLastCalledWith({
      conversationId: "conversation-1",
      groupId: "grp_test",
      leaseId: currentRetain?.leaseId,
      session: testProductLease,
      subscriberId: currentRetain?.subscriberId,
      workspaceId: "workspace-1",
    });
  });

  it("skips a publish that only moved another session, and parses none of it", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const initial = snapshot("", {
      messages: [message("message-1", "Reply")],
      revision: 1,
    });
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: {
          get: vi.fn(async () => initial),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            stateListener = listener;
            listener(initial);
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));
    const first = channel.getSnapshot();
    const emitted = vi.fn();
    channel.subscribe(emitted);

    // Another retained session's keystroke republishes the whole runtime. This
    // session's revision has not moved, so its projection is not even read: a
    // sibling that would fail the wire contract (a negative revision) goes
    // unnoticed, and neither the state nor the listeners see a change.
    const [ownSession] = initial.sessions;
    stateListener?.({
      ...initial,
      revision: 2,
      sessions: [
        { ...structuredClone(ownSession!) },
        {
          ...structuredClone(ownSession!),
          conversationId: "conversation-2",
          key: "grp_test/conversation-2",
          revision: -1,
          state: { ...ownSession!.state, draft: "sibling keystroke" },
        },
      ],
    });
    expect(channel.getSnapshot()).toBe(first);
    expect(emitted).not.toHaveBeenCalled();

    // Once this session moves, its projection is parsed and applied even
    // though the sibling is still malformed.
    stateListener?.({
      ...initial,
      revision: 3,
      sessions: [
        {
          ...structuredClone(ownSession!),
          revision: 2,
          state: { ...ownSession!.state, messages: [message("message-2", "Newer")] },
        },
        {
          ...structuredClone(ownSession!),
          conversationId: "conversation-2",
          key: "grp_test/conversation-2",
          revision: -1,
        },
      ],
    });
    expect(channel.getSnapshot().messages.map((item) => item.messageId)).toEqual([
      "message-2",
    ]);
    expect(emitted).toHaveBeenCalledTimes(1);

    // Ordering still holds across the skipped publish: an older snapshot that
    // arrives late is ignored.
    stateListener?.({
      ...initial,
      revision: 2,
      sessions: [
        {
          ...structuredClone(ownSession!),
          revision: 3,
          state: { ...ownSession!.state, messages: [] },
        },
      ],
    });
    expect(channel.getSnapshot().messages.map((item) => item.messageId)).toEqual([
      "message-2",
    ]);
  });

  it("preserves message identities and skips the emit for value-identical snapshot echoes", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const inlineTaskMessage = {
      ...message("message-1", "Reply with a task"),
      parts: [
        { kind: "markdown" as const, text: "Reply with a task " },
        {
          kind: "inline-task" as const,
          task: {
            conversationId: "cnv-task-1",
            status: "completed",
            title: "Inline task",
            unavailable: false,
            updatedAt: 1_720_000_000,
          },
        },
      ],
    };
    const plainMessage = message("message-2", "Plain reply");
    const initial = snapshot("", {
      messages: [inlineTaskMessage, plainMessage],
      revision: 1,
    });
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: {
          get: vi.fn(async () => initial),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            stateListener = listener;
            listener(initial);
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));
    const first = channel.getSnapshot();
    const emitted = vi.fn();
    channel.subscribe(emitted);

    // A per-keystroke IPC echo re-materializes every object with fresh
    // identities; the projection must reconcile them away and not emit.
    stateListener?.(
      snapshot("", {
        messages: [structuredClone(inlineTaskMessage), structuredClone(plainMessage)],
        revision: 2,
      })
    );
    expect(channel.getSnapshot()).toBe(first);
    expect(emitted).not.toHaveBeenCalled();

    // A real change replaces only the changed row; untouched rows keep their
    // object identity (memoized rows and compiled inline elements depend on it).
    const changed = structuredClone(inlineTaskMessage);
    changed.text = "Reply with a task (edited)";
    changed.parts[0] = { kind: "markdown", text: "Reply with a task (edited) " };
    stateListener?.(
      snapshot("", {
        messages: [changed, structuredClone(plainMessage)],
        revision: 3,
      })
    );
    const next = channel.getSnapshot();
    expect(next).not.toBe(first);
    expect(emitted).toHaveBeenCalledTimes(1);
    expect(next.messages[0]?.text).toBe("Reply with a task (edited)");
    expect(next.messages[1]).toBe(first.messages[1]);

    channel.stop();
  });

  it("does not let a delayed state read replace a newer native state event", async () => {
    let resolveStateRead: ((value: ChatRuntimeSnapshot) => void) | undefined;
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const staleSnapshot = snapshot("", { revision: 1, sessionRevision: 1 });
    const state = {
      get: vi.fn(
        () =>
          new Promise<ChatRuntimeSnapshot>((resolve) => {
            resolveStateRead = resolve;
          })
      ),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        stateListener = listener;
        listener(snapshot("", { revision: 0, sessionRevision: 0 }));
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(state.get).toHaveBeenCalledOnce());
    stateListener?.(
      snapshot("newer draft", {
        messages: [message("message-2", "New native event")],
        revision: 2,
        sessionRevision: 2,
      })
    );
    expect(channel.getSnapshot().messages.map((item) => item.text)).toEqual([
      "New native event",
    ]);

    resolveStateRead?.(staleSnapshot);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(channel.getSnapshot().draft).toBe("newer draft");
    expect(channel.getSnapshot().messages.map((item) => item.text)).toEqual([
      "New native event",
    ]);

    channel.stop();
  });

  it("rejects acceptance without invoking native send when retain fails", async () => {
    const retain = deferred<{ revision: number }>();
    const send = vi.fn(async () => ({ revision: 2 }));
    const state = {
      get: vi.fn(async () => snapshot("")),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        listener(snapshot(""));
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(() => retain.promise) as never,
        send: send as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    const operation = sendOperation(channel.send("not accepted"));
    retain.reject(new Error("retain failed"));

    await expect(operation.accepted).rejects.toThrow("retain failed");
    await expect(operation).rejects.toThrow("retain failed");
    expect(send).not.toHaveBeenCalled();

    channel.stop();
  });

  it("treats native send invocation as acceptance and leaves later failures in the channel", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const nativeCompletion = deferred<{ revision: number }>();
    const send = vi.fn(() => nativeCompletion.promise);
    const state = {
      get: vi.fn(async () => snapshot("")),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        stateListener = listener;
        listener(snapshot(""));
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        send: send as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(state.get).toHaveBeenCalledOnce());
    const operation = sendOperation(channel.send("charge it"));

    await expect(operation.accepted).resolves.toBeUndefined();
    expect(send).toHaveBeenCalledOnce();

    stateListener?.(
      snapshot("", {
        pending: [
          {
            clientRequestId: "req_failed",
            createdAt: 1,
            error: "Payment required",
            status: "failed",
            text: "charge it",
          },
        ],
        revision: 2,
      })
    );
    nativeCompletion.reject(new Error("402 Payment Required"));
    await expect(operation).rejects.toThrow("402 Payment Required");

    expect(channel.getSnapshot()).toMatchObject({
      errorKind: undefined,
      pending: [
        {
          clientRequestId: "req_failed",
          error: "Payment required",
          status: "failed",
        },
      ],
      status: "ready",
    });

    channel.stop();
  });

  it("waits for an uploading attachment discovered by the delayed initial state read", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const stateRead = deferred<ChatRuntimeSnapshot>();
    const send = vi.fn(async () => ({ revision: 3 }));
    const state = {
      get: vi.fn(() => stateRead.promise),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        stateListener = listener;
        listener(snapshot("", { revision: 0 }));
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        send: send as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    const operation = sendOperation(channel.send("fast send"));
    await vi.waitFor(() => expect(state.get).toHaveBeenCalledOnce());
    expect(send).not.toHaveBeenCalled();

    stateRead.resolve(
      snapshot("", {
        draftAttachments: [nativeAttachment("uploading")],
        revision: 1,
      })
    );
    await vi.waitFor(() =>
      expect(channel.getSnapshot().draftAttachments[0]?.status).toBe("uploading")
    );
    expect(send).not.toHaveBeenCalled();

    stateListener?.(
      snapshot("", {
        draftAttachments: [nativeAttachment("uploaded")],
        revision: 2,
      })
    );
    await expect(operation.accepted).resolves.toBeUndefined();
    await expect(operation).resolves.toEqual({ revision: 3 });
    expect(send).toHaveBeenCalledOnce();

    channel.stop();
  });

  it.each(["picker", "selected File", "retry selected File"])(
    "uses Main-owned intake for %s and receives only projected opaque refs",
    async (source) => {
      let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
      const localFileRef = `lfi1_${"d".repeat(43)}`;
      const pickAttachments = vi.fn(async () => {
        stateListener?.(
          snapshot("", {
            draftAttachments: [
              nativeAttachment("uploaded", {
                id: localFileRef,
                name: "notes.txt",
                size: 5,
              }),
            ],
            revision: 2,
          })
        );
        return { cancelled: false, errors: [], intakeId: "intake-picker", revision: 2 };
      });
      installNativeBridgeMock({
        chat: {
          pickAttachments: pickAttachments as never,
          retain: vi.fn(async () => ({ revision: 1 })) as never,
          state: {
            get: vi.fn(async () => snapshot("")),
            subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
              stateListener = listener;
              listener(snapshot(""));
              return vi.fn();
            }),
          } as never,
        },
        platform: "electron",
        self: { role: "main-window", windowId: "renderer-1" },
      });
      const channel = new BridgeConversationChannel({
        conversationId: "conversation-1",
        groupId: "grp_test",
        workspaceId: "workspace-1",
      });

      channel.start();
      await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));
      const file = new File(["notes"], "notes.txt");
      if (source === "retry selected File")
        pickAttachments.mockRejectedValueOnce(new Error("File intake failed."));
      if (source === "picker") await channel.pickAttachments?.();
      else {
        channel.attachFiles([{ data: file, name: file.name, size: file.size }]);
        await vi.waitFor(() => expect(pickAttachments).toHaveBeenCalledOnce());
      }

      if (source === "retry selected File") {
        await vi.waitFor(() =>
          expect(channel.getSnapshot().draftAttachments[0]?.status).toBe("failed")
        );
        channel.retryAttachment(channel.getSnapshot().draftAttachments[0]!.id);
        await vi.waitFor(() => expect(pickAttachments).toHaveBeenCalledTimes(2));
      }

      expect(pickAttachments).toHaveBeenCalledWith({
        ...(source !== "picker" ? { files: [file] } : {}),
        conversationId: "conversation-1",
        groupId: "grp_test",
        leaseId: expect.any(String),
        maxFiles: 50,
        maxTotalSize: 1024 * 1024 * 1024,
        maxUploadFiles: 8,
        session: testProductLease,
        subscriberId: "renderer-1:grp_test/conversation-1",
        surfaceId: "renderer-1",
        workspaceId: "workspace-1",
      });
      expect(channel.getSnapshot().draftAttachments).toMatchObject([
        { id: localFileRef, name: "notes.txt", status: "uploaded" },
      ]);
      channel.stop();
    }
  );

  it("shares an opaque local image preview and recreates its cache after restart", async () => {
    const localFileRef = `lfi1_${"p".repeat(43)}`;
    const runtime = snapshot("");
    const retain = vi.fn(async () => ({ revision: 1 }));
    const createObjectURL = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValueOnce("blob:first-local-preview")
      .mockReturnValueOnce("blob:restarted-local-preview");
    const revokeObjectURL = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => {});
    const preview = vi.fn(async () => ({
      pngImage: new Uint8Array([137, 80, 78, 71]),
      status: "ready" as const,
    }));
    installNativeBridgeMock({
      chat: {
        retain,
        state: {
          get: vi.fn(async () => runtime),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            listener(runtime);
            return vi.fn();
          }),
        } as never,
      },
      localFiles: { preview: preview as never },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });
    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));

    const [first, second] = await Promise.all([
      channel.previewLocalFile?.(localFileRef),
      channel.previewLocalFile?.(localFileRef),
    ]);
    expect(first?.url).toBe("blob:first-local-preview");
    expect(second?.url).toBe(first?.url);
    expect(createObjectURL).toHaveBeenCalledOnce();
    expect(preview).toHaveBeenCalledOnce();
    expect(preview).toHaveBeenCalledWith({
      localFileRef,
      session: testProductLease,
    });

    first?.release();
    await Promise.resolve();
    expect(revokeObjectURL).not.toHaveBeenCalled();

    channel.stop();
    expect(revokeObjectURL).toHaveBeenCalledOnce();
    await expect(channel.previewLocalFile?.(localFileRef)).resolves.toBeUndefined();
    expect(preview).toHaveBeenCalledOnce();

    channel.start();
    await vi.waitFor(() => expect(retain).toHaveBeenCalledTimes(2));
    const restarted = await channel.previewLocalFile?.(localFileRef);
    expect(restarted?.url).toBe("blob:restarted-local-preview");
    expect(preview).toHaveBeenCalledTimes(2);

    second?.release();
    expect(revokeObjectURL).toHaveBeenCalledOnce();
    channel.stop();
    expect(revokeObjectURL).toHaveBeenCalledTimes(2);
  });

  it("reads an uploaded workspace image through the authenticated Chat capability", async () => {
    const workspacePath = `/uploads/${"A".repeat(22)}-product-photo.JPG`;
    const runtime = snapshot("");
    const createObjectURL = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:workspace-image-preview");
    const revokeObjectURL = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => {});
    const readGroupImage = vi.fn(async () =>
      Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10])
    );
    const preview = vi.fn();
    installNativeBridgeMock({
      chat: {
        readGroupImage: readGroupImage as never,
        retain: vi.fn(async () => ({ revision: 1 })),
        state: {
          get: vi.fn(async () => runtime),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            listener(runtime);
            return vi.fn();
          }),
        } as never,
      },
      localFiles: { preview: preview as never },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });
    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));

    const image = await channel.previewLocalFile?.(workspacePath);
    expect(image?.url).toBe("blob:workspace-image-preview");
    expect(readGroupImage).toHaveBeenCalledWith({
      groupId: "grp_test",
      path: workspacePath,
      session: testProductLease,
      source: "group-file",
    });
    expect(preview).not.toHaveBeenCalled();
    expect(createObjectURL).toHaveBeenCalledOnce();
    expect((createObjectURL.mock.calls[0]![0] as Blob).type).toBe("image/png");

    await expect(
      channel.previewLocalFile?.("/uploads/../../account-secret.png")
    ).resolves.toBeUndefined();
    expect(readGroupImage).toHaveBeenCalledOnce();

    image?.release();
    await Promise.resolve();
    expect(revokeObjectURL).toHaveBeenCalledWith("blob:workspace-image-preview");
    channel.stop();
  });

  it("recreates the preview cache after a missing Session projection returns", async () => {
    const localFileRef = `lfi1_${"q".repeat(43)}`;
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const initial = snapshot("", { revision: 1, sessionRevision: 1 });
    const createObjectURL = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValueOnce("blob:initial-session-preview")
      .mockReturnValueOnce("blob:restored-session-preview");
    const revokeObjectURL = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => {});
    const preview = vi.fn(async () => ({
      pngImage: new Uint8Array([137, 80, 78, 71]),
      status: "ready" as const,
    }));
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(async () => ({ revision: 1 })),
        state: {
          get: vi.fn(async () => initial),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            stateListener = listener;
            listener(initial);
            return vi.fn();
          }),
        } as never,
      },
      localFiles: { preview: preview as never },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });
    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));

    const initialLease = await channel.previewLocalFile?.(localFileRef);
    expect(initialLease?.url).toBe("blob:initial-session-preview");

    stateListener?.(emptySnapshot(2));
    expect(channel.getSnapshot().status).toBe("idle");
    expect(revokeObjectURL).toHaveBeenCalledWith("blob:initial-session-preview");
    await expect(channel.previewLocalFile?.(localFileRef)).resolves.toBeUndefined();
    expect(preview).toHaveBeenCalledOnce();

    stateListener?.(snapshot("", { revision: 3, sessionRevision: 3 }));
    const restoredLease = await channel.previewLocalFile?.(localFileRef);
    expect(restoredLease?.url).toBe("blob:restored-session-preview");
    expect(preview).toHaveBeenCalledTimes(2);

    initialLease?.release();
    channel.stop();
    expect(revokeObjectURL).toHaveBeenCalledTimes(2);
    expect(createObjectURL).toHaveBeenCalledTimes(2);
  });

  it("single-flights concurrent local-file picker requests", async () => {
    const pickResult = deferred<{
      cancelled: boolean;
      errors: [];
      intakeId: string;
      revision: number;
    }>();
    const pickAttachments = vi.fn(() => pickResult.promise);
    installNativeBridgeMock({
      chat: {
        pickAttachments: pickAttachments as never,
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: {
          get: vi.fn(async () => snapshot("")),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            listener(snapshot(""));
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));
    const first = channel.pickAttachments?.() as Promise<unknown>;
    const second = channel.pickAttachments?.() as Promise<unknown>;

    expect(second).toBe(first);
    await vi.waitFor(() => expect(pickAttachments).toHaveBeenCalledOnce());
    pickResult.resolve({
      cancelled: true,
      errors: [],
      intakeId: "intake-single-flight",
      revision: 1,
    });
    await expect(Promise.all([first, second])).resolves.toEqual([undefined, undefined]);
    expect(pickAttachments).toHaveBeenCalledOnce();
    channel.stop();
  });

  it("re-arms the attachment picker from Main when the pick reply is lost", async () => {
    // Main fences every claim by its own id, so Renderer single-flight is a
    // UX convenience and must never outlive Main's dialog. A reply the
    // transport never delivers used to leave the "+" control dead for the
    // rest of the session: silent, with nothing to retry.
    const neverSettles = deferred<{
      cancelled: boolean;
      errors: [];
      intakeId: string;
      revision: number;
    }>();
    const pickAttachments = vi.fn(() => neverSettles.promise);
    let publish: ((next: ChatRuntimeSnapshot) => void) | undefined;
    installNativeBridgeMock({
      chat: {
        pickAttachments: pickAttachments as never,
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: {
          get: vi.fn(async () => snapshot("")),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            publish = listener;
            listener(snapshot(""));
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));

    const first = channel.pickAttachments?.() as Promise<unknown>;
    await vi.waitFor(() => expect(pickAttachments).toHaveBeenCalledOnce());

    // While Main reports the dialog open, a second press is still coalesced.
    publish?.(snapshot("", { revision: 2, sessionRevision: 2 }, true));
    await vi.waitFor(() => expect(channel.getSnapshot().connection).toBeDefined());
    expect(channel.pickAttachments?.()).toBe(first);
    expect(pickAttachments).toHaveBeenCalledOnce();

    // Main closes the dialog. The reply is still lost, but the control must
    // come back: Main's projection is the authority, not the reply. It comes
    // back only after the grace window that lets a merely-late reply land, so
    // this wait has to outlast that window.
    publish?.(snapshot("", { revision: 3, sessionRevision: 3 }, false));
    await vi.waitFor(
      () => {
        channel.pickAttachments?.();
        expect(pickAttachments).toHaveBeenCalledTimes(2);
      },
      { timeout: 3_000 }
    );

    channel.stop();
  });

  it("rejects a picker result that settles after the chat lifecycle stops", async () => {
    const pickResult = deferred<{
      cancelled: boolean;
      errors: Array<{
        errorClass: "local_file_unavailable";
        message: string;
        retryable: boolean;
      }>;
      intakeId: string;
      revision: number;
    }>();
    const pickAttachments = vi.fn(() => pickResult.promise);
    installNativeBridgeMock({
      chat: {
        pickAttachments: pickAttachments as never,
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: {
          get: vi.fn(async () => snapshot("")),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            listener(snapshot(""));
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));
    const operation = channel.pickAttachments?.() as Promise<unknown>;
    await vi.waitFor(() => expect(pickAttachments).toHaveBeenCalledOnce());
    channel.stop();
    pickResult.resolve({
      cancelled: false,
      errors: [
        {
          errorClass: "local_file_unavailable",
          message: "stale picker result",
          retryable: true,
        },
      ],
      intakeId: "intake-stale",
      revision: 2,
    });

    await expect(operation).rejects.toThrow("Chat bridge is not retained.");
    expect(channel.getSnapshot().draftAttachments).toEqual([]);
  });

  it("projects ownerless Connector remediation through the existing failed attachment state", async () => {
    const remediationMessage =
      "Reconnect this workspace's Comma Connector with a newly issued token, then select the file again.";
    const pickAttachments = vi
      .fn()
      .mockResolvedValueOnce({
        cancelled: false,
        errors: [
          {
            errorClass: "connector_reconfiguration_required",
            message: remediationMessage,
            retryable: true,
          },
        ],
        intakeId: "intake-remediation-1",
        revision: 1,
      })
      .mockResolvedValueOnce({
        cancelled: true,
        errors: [],
        intakeId: "intake-remediation-2",
        revision: 1,
      });
    const retryAttachment = vi.fn(async () => ({ revision: 2 }));
    installNativeBridgeMock({
      chat: {
        pickAttachments: pickAttachments as never,
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        retryAttachment: retryAttachment as never,
        state: {
          get: vi.fn(async () => snapshot("")),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            listener(snapshot(""));
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));
    await channel.pickAttachments?.();

    expect(channel.getSnapshot().draftAttachments).toEqual([
      {
        error: remediationMessage,
        id: "chat-intake-failure:intake-remediation-1:0",
        isImage: false,
        name: "File",
        path: undefined,
        size: 0,
        status: "failed",
      },
    ]);

    const failureId = channel.getSnapshot().draftAttachments[0]!.id;
    await channel.retryAttachment(failureId);

    expect(pickAttachments).toHaveBeenCalledTimes(2);
    expect(retryAttachment).toHaveBeenCalledWith(
      expect.objectContaining({ attachmentId: failureId })
    );
    expect(channel.getSnapshot().draftAttachments).toEqual([]);
    channel.stop();
  });

  it("opens a fresh picker before resolving a failure whose original reply is still pending", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const firstPick = deferred<{
      cancelled: boolean;
      errors: Array<{
        errorClass: "local_file_unavailable";
        message: string;
        retryable: boolean;
      }>;
      intakeId: string;
      revision: number;
    }>();
    const replacementPick = deferred<{
      cancelled: boolean;
      errors: [];
      intakeId: string;
      revision: number;
    }>();
    const pickAttachments = vi
      .fn()
      .mockReturnValueOnce(firstPick.promise)
      .mockReturnValueOnce(replacementPick.promise);
    const retryAttachment = vi.fn(async () => {
      stateListener?.(
        snapshot("draft", {
          draftAttachments: [],
          draftEpoch: 2,
          revision: 4,
        })
      );
      return { draftEpoch: 2, revision: 4 };
    });
    const beginSendIntent = vi.fn(async (input: { sendIntentId: string }) => ({
      draftEpoch: 2,
      revision: 5,
      sendIntentId: input.sendIntentId,
    }));
    const send = vi.fn(async () => ({ draftEpoch: 3, revision: 6 }));
    installNativeBridgeMock({
      chat: {
        beginSendIntent: beginSendIntent as never,
        pickAttachments: pickAttachments as never,
        retain: vi.fn(async () => ({ draftEpoch: 1, revision: 1 })) as never,
        retryAttachment: retryAttachment as never,
        send: send as never,
        state: {
          get: vi.fn(async () => snapshot("draft")),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            stateListener = listener;
            listener(snapshot("draft"));
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));
    const originalOperation = channel.pickAttachments?.() as Promise<unknown>;
    await vi.waitFor(() => expect(pickAttachments).toHaveBeenCalledOnce());
    const failureId = "chat-intake-failure:intake-original:0";
    stateListener?.(
      snapshot("draft", {
        draftAttachments: [
          {
            error: "unreadable",
            id: failureId,
            isImage: false,
            name: "missing.txt",
            path: undefined,
            size: 0,
            status: "failed",
          },
        ],
        draftEpoch: 1,
        revision: 2,
      })
    );

    const retry = channel.retryAttachment(failureId) as Promise<unknown>;
    const queuedSend = sendOperation(channel.send("draft"));
    expect(retryAttachment).not.toHaveBeenCalled();
    expect(beginSendIntent).not.toHaveBeenCalled();

    firstPick.resolve({
      cancelled: false,
      errors: [
        {
          errorClass: "local_file_unavailable",
          message: "unreadable",
          retryable: true,
        },
      ],
      intakeId: "intake-original",
      revision: 2,
    });
    await originalOperation;
    await vi.waitFor(() => expect(pickAttachments).toHaveBeenCalledTimes(2));
    expect(retryAttachment).not.toHaveBeenCalled();
    expect(beginSendIntent).not.toHaveBeenCalled();
    expect(channel.getSnapshot().draftAttachments).toEqual([
      expect.objectContaining({ id: failureId, status: "failed" }),
    ]);

    replacementPick.resolve({
      cancelled: true,
      errors: [],
      intakeId: "intake-replacement",
      revision: 3,
    });
    await retry;
    expect(retryAttachment).toHaveBeenCalledWith(
      expect.objectContaining({ attachmentId: failureId })
    );
    await expect(queuedSend.accepted).resolves.toBeUndefined();
    expect(beginSendIntent).toHaveBeenCalledOnce();
    expect(send).toHaveBeenCalledOnce();
    channel.stop();
  });

  it("passes the Main picker only the remaining draft count and byte budget", async () => {
    const pickAttachments = vi.fn(async () => ({
      cancelled: true,
      errors: [],
      intakeId: "intake-budget",
      revision: 1,
    }));
    const localAttachments = ["a", "b"].map((token) =>
      nativeAttachment("uploaded", {
        id: `lfi1_${token.repeat(43)}`,
        name: `${token}.bin`,
        size: 450 * 1024 * 1024,
      })
    );
    const regularAttachments = Array.from({ length: 47 }, (_, index) =>
      nativeAttachment("uploaded", {
        id: `native-${index}`,
        name: `regular-${index}.txt`,
        size: 1,
      })
    );
    const initial = snapshot("", {
      draftAttachments: [...localAttachments, ...regularAttachments],
    });
    installNativeBridgeMock({
      chat: {
        pickAttachments: pickAttachments as never,
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: {
          get: vi.fn(async () => initial),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            listener(initial);
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));
    await channel.pickAttachments?.();

    // Budgets are per class: the 47 uploads exhaust only the image-upload
    // allowance while the 2 local refs consume only the local-file count and
    // byte budgets — admission cannot depend on selection order.
    expect(pickAttachments).toHaveBeenCalledWith({
      conversationId: "conversation-1",
      groupId: "grp_test",
      leaseId: expect.any(String),
      maxFiles: 48,
      maxTotalSize: 124 * 1024 * 1024,
      maxUploadFiles: 0,
      session: testProductLease,
      subscriberId: "renderer-1:grp_test/conversation-1",
      surfaceId: "renderer-1",
      workspaceId: "workspace-1",
    });
    channel.stop();
  });

  it("waits past the attach receipt for an uploaded native projection before sending", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const attachReceipt = deferred<{ revision: number }>();
    const nativeSendCompletion = deferred<{ revision: number }>();
    const attach = vi.fn(() => attachReceipt.promise);
    const send = vi.fn(() => {
      stateListener?.(
        snapshot("", {
          pending: [
            {
              clientRequestId: "req_with_attachment",
              createdAt: 2,
              status: "sending",
              text: "send report",
            },
          ],
          revision: 4,
        })
      );
      return nativeSendCompletion.promise;
    });
    const state = {
      get: vi.fn(async () => snapshot("")),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        stateListener = listener;
        listener(snapshot(""));
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        attach: attach as never,
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        send: send as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(state.get).toHaveBeenCalledOnce());
    channel.attachFiles([
      { data: new Blob([new Uint8Array([1, 2, 3])]), name: "report.txt", size: 3 },
    ]);

    expect(channel.getSnapshot().draftAttachments).toEqual([
      expect.objectContaining({ name: "report.txt", status: "uploading" }),
    ]);
    const operation = sendOperation(channel.send("send report"));
    await vi.waitFor(() => expect(attach).toHaveBeenCalledOnce());
    expect(send).not.toHaveBeenCalled();

    attachReceipt.resolve({ revision: 2 });
    await Promise.resolve();
    expect(send).not.toHaveBeenCalled();

    stateListener?.(
      snapshot("", {
        draftAttachments: [nativeAttachment("uploading")],
        revision: 2,
      })
    );
    await Promise.resolve();
    expect(send).not.toHaveBeenCalled();

    stateListener?.(
      snapshot("", {
        draftAttachments: [nativeAttachment("uploaded")],
        revision: 3,
      })
    );
    await expect(operation.accepted).resolves.toBeUndefined();

    expect(attach).toHaveBeenCalledWith({
      bytes: new Uint8Array([1, 2, 3]),
      conversationId: "conversation-1",
      groupId: "grp_test",
      leaseId: expect.any(String),
      name: "report.txt",
      session: testProductLease,
      size: 3,
      subscriberId: "renderer-1:grp_test/conversation-1",
      surfaceId: "renderer-1",
      workspaceId: "workspace-1",
    });
    expect(attach.mock.invocationCallOrder[0]).toBeLessThan(
      send.mock.invocationCallOrder[0] ?? 0
    );
    expect(channel.getSnapshot().draftAttachments).toEqual([]);
    expect(channel.getSnapshot().pending).toEqual([
      expect.objectContaining({
        clientRequestId: "req_with_attachment",
        status: "sending",
      }),
    ]);

    nativeSendCompletion.resolve({ revision: 4 });
    await expect(operation).resolves.toEqual({ revision: 4 });
    channel.stop();
  });

  it("installs the admission wait before publishing the local uploading state", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const fileRead = deferred<ArrayBuffer>();
    const attachReceipt = deferred<{ revision: number }>();
    const attach = vi.fn(() => attachReceipt.promise);
    const send = vi.fn(async () => ({ revision: 3 }));
    const state = {
      get: vi.fn(async () => snapshot("")),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        stateListener = listener;
        listener(snapshot(""));
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        attach: attach as never,
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        send: send as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(state.get).toHaveBeenCalledOnce());
    let operation: ReturnType<typeof sendOperation> | undefined;
    channel.subscribe(() => {
      if (
        !operation &&
        channel
          .getSnapshot()
          .draftAttachments.some((attachment) => attachment.status === "uploading")
      ) {
        operation = sendOperation(channel.send("send from the state subscriber"));
      }
    });
    const data = new Blob([new Uint8Array([1])]);
    vi.spyOn(data, "arrayBuffer").mockReturnValue(fileRead.promise);

    channel.attachFiles([{ data, name: "subscriber.txt", size: 1 }]);
    expect(operation).toBeDefined();
    await Promise.resolve();
    expect(send).not.toHaveBeenCalled();
    expect(attach).not.toHaveBeenCalled();

    fileRead.resolve(new Uint8Array([1]).buffer);
    await vi.waitFor(() => expect(attach).toHaveBeenCalledOnce());
    stateListener?.(
      snapshot("", {
        draftAttachments: [
          nativeAttachment("uploaded", {
            id: "native-subscriber",
            name: "subscriber.txt",
            size: 1,
          }),
        ],
        revision: 2,
      })
    );
    attachReceipt.resolve({ revision: 2 });

    await expect(operation!.accepted).resolves.toBeUndefined();
    await expect(operation!).resolves.toEqual({ revision: 3 });
    expect(send).toHaveBeenCalledOnce();
    channel.stop();
  });

  it("waits for admissions added while an earlier attachment is settling", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const firstReceipt = deferred<{ revision: number }>();
    const secondReceipt = deferred<{ revision: number }>();
    const attach = vi
      .fn()
      .mockReturnValueOnce(firstReceipt.promise)
      .mockReturnValueOnce(secondReceipt.promise);
    const send = vi.fn(async () => ({ revision: 5 }));
    const state = {
      get: vi.fn(async () => snapshot("")),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        stateListener = listener;
        listener(snapshot(""));
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        attach: attach as never,
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        send: send as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(state.get).toHaveBeenCalledOnce());
    channel.attachFiles([{ data: new Blob(["a"]), name: "a.txt", size: 1 }]);
    await vi.waitFor(() => expect(attach).toHaveBeenCalledTimes(1));
    const operation = sendOperation(channel.send("send both files"));

    channel.attachFiles([{ data: new Blob(["b"]), name: "b.txt", size: 1 }]);
    await vi.waitFor(() => expect(attach).toHaveBeenCalledTimes(2));
    stateListener?.(
      snapshot("", {
        draftAttachments: [
          nativeAttachment("uploaded", {
            id: "native-a",
            name: "a.txt",
            size: 1,
          }),
          nativeAttachment("uploading", {
            id: "native-b",
            name: "b.txt",
            size: 1,
          }),
        ],
        revision: 2,
      })
    );
    firstReceipt.resolve({ revision: 2 });
    await Promise.resolve();
    expect(send).not.toHaveBeenCalled();

    stateListener?.(
      snapshot("", {
        draftAttachments: [
          nativeAttachment("uploaded", {
            id: "native-a",
            name: "a.txt",
            size: 1,
          }),
          nativeAttachment("uploaded", {
            id: "native-b",
            name: "b.txt",
            size: 1,
          }),
        ],
        revision: 3,
      })
    );
    secondReceipt.resolve({ revision: 3 });

    await expect(operation.accepted).resolves.toBeUndefined();
    await expect(operation).resolves.toEqual({ revision: 5 });
    expect(send).toHaveBeenCalledOnce();
    channel.stop();
  });

  it("removes the native attachment when local removal races its attach receipt", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const attachReceipt = deferred<{ revision: number }>();
    const attach = vi.fn(() => attachReceipt.promise);
    const removeAttachment = vi.fn(async () => ({ revision: 3 }));
    const state = {
      get: vi.fn(async () => snapshot("")),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        stateListener = listener;
        listener(snapshot(""));
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        attach: attach as never,
        removeAttachment: removeAttachment as never,
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(state.get).toHaveBeenCalledOnce());
    channel.attachFiles([
      { data: new Blob(["late"]), name: "remove-late.txt", size: 4 },
    ]);
    await vi.waitFor(() => expect(attach).toHaveBeenCalledOnce());
    const localAttachmentId = channel.getSnapshot().draftAttachments[0]!.id;

    channel.removeAttachment(localAttachmentId);
    expect(channel.getSnapshot().draftAttachments).toEqual([]);
    expect(removeAttachment).not.toHaveBeenCalled();

    stateListener?.(
      snapshot("", {
        draftAttachments: [
          nativeAttachment("uploading", {
            id: "native-remove-late",
            name: "remove-late.txt",
            size: 4,
          }),
        ],
        revision: 2,
      })
    );
    expect(channel.getSnapshot().draftAttachments).toEqual([]);
    attachReceipt.resolve({ revision: 2 });

    await vi.waitFor(() => expect(removeAttachment).toHaveBeenCalledOnce());
    expect(removeAttachment).toHaveBeenCalledWith({
      attachmentId: "native-remove-late",
      conversationId: "conversation-1",
      groupId: "grp_test",
      leaseId: expect.any(String),
      session: testProductLease,
      subscriberId: "renderer-1:grp_test/conversation-1",
      surfaceId: "renderer-1",
      workspaceId: "workspace-1",
    });
    expect(channel.getSnapshot().draftAttachments).toEqual([]);

    stateListener?.(snapshot("", { draftAttachments: [], revision: 3 }));
    expect(channel.getSnapshot().draftAttachments).toEqual([]);
    channel.stop();
  });

  it("keeps a failed authoritative attachment projection and blocks native send", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const attachReceipt = deferred<{ revision: number }>();
    const attach = vi.fn(() => attachReceipt.promise);
    const send = vi.fn(async () => ({ revision: 3 }));
    const state = {
      get: vi.fn(async () => snapshot("")),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        stateListener = listener;
        listener(snapshot(""));
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        attach: attach as never,
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        send: send as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(state.get).toHaveBeenCalledOnce());
    channel.attachFiles([{ data: new Blob(["broken"]), name: "broken.txt", size: 6 }]);
    const operation = sendOperation(channel.send("send broken file"));
    await vi.waitFor(() => expect(attach).toHaveBeenCalledOnce());

    attachReceipt.resolve({ revision: 2 });
    stateListener?.(
      snapshot("", {
        draftAttachments: [
          {
            ...nativeAttachment("failed"),
            error: "Upload failed",
            name: "broken.txt",
            size: 6,
          },
        ],
        revision: 2,
      })
    );
    // A blocked send is a visible failure, never a silently resolved no-op:
    // resolving here would report success for a message that was not sent.
    await expect(operation.accepted).rejects.toThrow(
      "An attachment could not be added. Remove or retry it, then send again."
    );
    await expect(operation).rejects.toThrow(
      "An attachment could not be added. Remove or retry it, then send again."
    );

    expect(send).not.toHaveBeenCalled();
    expect(channel.getSnapshot().draftAttachments).toEqual([
      expect.objectContaining({
        error: "Upload failed",
        name: "broken.txt",
        status: "failed",
      }),
    ]);

    channel.stop();
  });

  it("reserves Main send intent after awaiting pre-click draft receipts", async () => {
    const setDraftReceipt = deferred<{ draftEpoch: number; revision: number }>();
    const setDraft = vi.fn(() => setDraftReceipt.promise);
    const send = vi.fn(async () => ({ revision: 3 }));
    installNativeBridgeMock({
      chat: {
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        send: send as never,
        setDraft: setDraft as never,
        state: {
          get: vi.fn(async () => snapshot("")),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            listener(snapshot(""));
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));

    void channel.setDraft("hello");
    const operation = sendOperation(channel.send("hello"));
    await vi.waitFor(() => expect(setDraft).toHaveBeenCalledOnce());
    // The ordered Main reservation waits for the draft edit issued before the
    // click; Main then binds its epoch and Renderer sends no epoch back.
    expect(send).not.toHaveBeenCalled();

    setDraftReceipt.resolve({ draftEpoch: 7, revision: 2 });
    await expect(operation.accepted).resolves.toBeUndefined();
    expect(send).toHaveBeenCalledWith(expect.objectContaining({ text: "hello" }));
    expect((send.mock.calls as unknown[][])[0]?.[0]).not.toHaveProperty("draftEpoch");

    channel.stop();
  });

  it("reserves the send intent before a post-click edit can enter Main", async () => {
    const firstDraftReceipt = deferred<{ draftEpoch: number; revision: number }>();
    const secondDraftReceipt = deferred<{ draftEpoch: number; revision: number }>();
    const setDraft = vi
      .fn()
      .mockImplementationOnce(() => firstDraftReceipt.promise)
      .mockImplementationOnce(() => secondDraftReceipt.promise);
    const beginSendIntent = vi.fn(async (input: { sendIntentId: string }) => ({
      draftEpoch: 1,
      revision: 2,
      sendIntentId: input.sendIntentId,
    }));
    const send = vi.fn(async () => ({ draftEpoch: 2, revision: 4 }));
    installNativeBridgeMock({
      chat: {
        beginSendIntent: beginSendIntent as never,
        retain: vi.fn(async () => ({ draftEpoch: 0, revision: 1 })) as never,
        send: send as never,
        setDraft: setDraft as never,
        state: {
          get: vi.fn(async () => snapshot("")),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            listener(snapshot(""));
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));
    void channel.setDraft("A");
    const oldSend = sendOperation(channel.send("A"));
    void channel.setDraft("B");

    await vi.waitFor(() => expect(setDraft).toHaveBeenCalledTimes(1));
    expect(beginSendIntent).not.toHaveBeenCalled();
    firstDraftReceipt.resolve({ draftEpoch: 1, revision: 2 });
    await vi.waitFor(() => expect(beginSendIntent).toHaveBeenCalledOnce());
    // The post-click edit is sequenced after Main has frozen A's intent.
    await vi.waitFor(() => expect(setDraft).toHaveBeenCalledTimes(2));
    secondDraftReceipt.resolve({ draftEpoch: 2, revision: 3 });

    await expect(oldSend.accepted).resolves.toBeUndefined();
    expect(send).toHaveBeenCalledWith(
      expect.objectContaining({ sendIntentId: expect.any(String), text: "A" })
    );
    channel.stop();
  });

  it("never rereads or sends a Renderer epoch while admission waits", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const attachReceipt = deferred<{ revision: number }>();
    const attach = vi.fn(() => attachReceipt.promise);
    const send = vi.fn(async () => ({ revision: 9 }));
    const state = {
      get: vi.fn(async () => snapshot("")),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        stateListener = listener;
        listener(snapshot(""));
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        attach: attach as never,
        retain: vi.fn(async () => ({ draftEpoch: 3, revision: 1 })) as never,
        send: send as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(state.get).toHaveBeenCalledOnce());
    channel.attachFiles([
      { data: new Blob([new Uint8Array([1])]), name: "slow.txt", size: 1 },
    ]);
    const operation = sendOperation(channel.send("the reviewed text"));
    await vi.waitFor(() => expect(attach).toHaveBeenCalledOnce());

    // While the admission drain waits, another surface edits the draft and
    // advances the projection to epoch 9. Main already bound this immutable
    // send intent to epoch 3; Renderer sends only that intent id, so it cannot
    // substitute the newer projection and consume a draft the sender never
    // reviewed.
    attachReceipt.resolve({ revision: 2 });
    stateListener?.(
      snapshot("", {
        draftAttachments: [
          { ...nativeAttachment("uploaded"), name: "slow.txt", size: 1 },
        ],
        draftEpoch: 9,
        revision: 3,
      })
    );
    await expect(operation.accepted).resolves.toBeUndefined();
    expect(send).toHaveBeenCalledWith(
      expect.objectContaining({ text: "the reviewed text" })
    );
    expect((send.mock.calls as unknown[][])[0]?.[0]).not.toHaveProperty("draftEpoch");

    channel.stop();
  });

  it("rejects a send while unresolved picker failures remain and allows it after removal", async () => {
    const pickAttachments = vi.fn(async () => ({
      cancelled: false,
      errors: [{ message: "unreadable", retryable: false }],
      intakeId: "intake-unreadable",
      revision: 1,
    }));
    const send = vi.fn(async () => ({ revision: 3 }));
    installNativeBridgeMock({
      chat: {
        pickAttachments: pickAttachments as never,
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        send: send as never,
        state: {
          get: vi.fn(async () => snapshot("")),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            listener(snapshot(""));
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));
    await channel.pickAttachments?.();
    const failureId = channel.getSnapshot().draftAttachments[0]!.id;

    const blocked = sendOperation(channel.send("ship it"));
    await expect(blocked.accepted).rejects.toThrow(
      "An attachment could not be added. Remove or retry it, then send again."
    );
    expect(send).not.toHaveBeenCalled();

    channel.removeAttachment(failureId);
    const operation = sendOperation(channel.send("ship it"));
    await expect(operation.accepted).resolves.toBeUndefined();
    expect(send).toHaveBeenCalledOnce();

    channel.stop();
  });

  it("does not send a broad acknowledgement when a picker reply is lost", async () => {
    let stateListener: ((snapshot: ChatRuntimeSnapshot) => void) | undefined;
    const pickAttachments = vi.fn(async () => {
      stateListener?.(
        snapshot("", {
          draftAttachments: [
            {
              error: "The selected file could not be attached.",
              id: "chat-intake-failure:intake-lost-reply:0",
              isImage: false,
              name: "Selected file",
              path: undefined,
              size: 0,
              status: "failed",
            },
          ],
          revision: 2,
        })
      );
      throw new Error("picker process died");
    });
    const acknowledgeIntakeFailures = vi.fn(async () => ({
      draftEpoch: 5,
      revision: 2,
    }));
    const send = vi.fn(async () => ({ revision: 3 }));
    installNativeBridgeMock({
      chat: {
        acknowledgeIntakeFailures: acknowledgeIntakeFailures as never,
        pickAttachments: pickAttachments as never,
        retain: vi.fn(async () => ({ draftEpoch: 5, revision: 1 })) as never,
        send: send as never,
        state: {
          get: vi.fn(async () => snapshot("")),
          subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
            stateListener = listener;
            listener(snapshot(""));
            return vi.fn();
          }),
        } as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(channel.getSnapshot().status).toBe("ready"));
    await expect(channel.pickAttachments?.()).rejects.toThrow("picker process died");

    // Without the exact intake id from the lost reply Renderer cannot ack;
    // Main's projected outcome remains the only authority and gates send.
    expect(acknowledgeIntakeFailures).not.toHaveBeenCalled();
    const rows = channel.getSnapshot().draftAttachments;
    expect(rows).toEqual([
      expect.objectContaining({
        id: "chat-intake-failure:intake-lost-reply:0",
        status: "failed",
      }),
    ]);

    const blocked = sendOperation(channel.send("commit without files"));
    await expect(blocked.accepted).rejects.toThrow(
      "An attachment could not be added. Remove or retry it, then send again."
    );
    expect(send).not.toHaveBeenCalled();

    channel.stop();
  });

  it("ignores an attachment admission that completes after stop", async () => {
    const attachReceipt = deferred<{ revision: number }>();
    const attach = vi.fn(() => attachReceipt.promise);
    const state = {
      get: vi.fn(async () => snapshot("")),
      subscribe: vi.fn((listener: (next: ChatRuntimeSnapshot) => void) => {
        listener(snapshot(""));
        return vi.fn();
      }),
    };
    installNativeBridgeMock({
      chat: {
        attach: attach as never,
        retain: vi.fn(async () => ({ revision: 1 })) as never,
        state: state as never,
      },
      platform: "electron",
      self: { role: "main-window", windowId: "renderer-1" },
    });
    const channel = new BridgeConversationChannel({
      conversationId: "conversation-1",
      groupId: "grp_test",
      workspaceId: "workspace-1",
    });

    channel.start();
    await vi.waitFor(() => expect(state.get).toHaveBeenCalledOnce());
    channel.attachFiles([{ data: new Blob(["late"]), name: "late.txt", size: 4 }]);
    await vi.waitFor(() => expect(attach).toHaveBeenCalledOnce());
    expect(channel.getSnapshot().draftAttachments).toHaveLength(1);
    const operation = sendOperation(channel.send("late send"));

    channel.stop();
    await expect(operation.accepted).rejects.toThrow("Chat bridge is not retained");
    await expect(operation).rejects.toThrow("Chat bridge is not retained");
    attachReceipt.resolve({ revision: 2 });
    await Promise.resolve();

    expect(channel.getSnapshot().draftAttachments).toEqual([]);
  });
});

function snapshot(
  draft: string,
  {
    awaitingReply = false,
    awaitingTurnKey,
    draftAttachments = [],
    draftEpoch,
    locallyAwaitingReply = false,
    messages = [],
    pending = [],
    revision = 1,
    // Real projections split the canonical transcript out separately
    // (toConversationProjection); most cases here only exercise the combined
    // list, so the split defaults to empty unless a test needs the production
    // shape.
    serverMessages = [],
    sessionRevision = revision,
    status = "ready",
  }: {
    awaitingReply?: boolean;
    awaitingTurnKey?: string;
    draftAttachments?: ChatRuntimeSnapshot["sessions"][number]["state"]["draftAttachments"];
    draftEpoch?: number;
    locallyAwaitingReply?: boolean;
    messages?: ChatRuntimeSnapshot["sessions"][number]["state"]["messages"];
    pending?: ChatRuntimeSnapshot["sessions"][number]["state"]["pending"];
    revision?: number;
    serverMessages?: ChatRuntimeSnapshot["sessions"][number]["state"]["serverMessages"];
    sessionRevision?: number;
    status?: ChatRuntimeSnapshot["sessions"][number]["state"]["status"];
  } = {},
  attachmentIntakeInFlight?: boolean
): ChatRuntimeSnapshot {
  return {
    protocolVersion: chatProtocolVersion,
    revision,
    sessions: [
      {
        conversationId: "conversation-1",
        groupId: "grp_test",
        ...(draftEpoch === undefined ? {} : { draftEpoch }),
        draftOwnerSurfaceId: draft ? "renderer-1" : undefined,
        key: "grp_test/conversation-1",
        refs: 1,
        revision: sessionRevision,
        state: {
          activity: undefined,
          ...(attachmentIntakeInFlight === undefined
            ? {}
            : { attachmentIntakeInFlight }),
          assistantDraft: undefined,
          awaitingReply,
          awaitingSince: undefined,
          awaitingTimedOut: false,
          awaitingTurnKey,
          connection: "live",
          conversation: undefined,
          draft,
          draftAttachments,
          errorKind: undefined,
          lastBackoffMs: 0,
          locallyAwaitingReply,
          messages,
          pending,
          serverMessages,
          status,
          syncWarning: undefined,
        },
        workspaceId: "workspace-1",
      },
    ],
  };
}

function drafts(draft: string, draftEpoch: number): ChatRuntimeDraftsSnapshot {
  return {
    drafts: [{ draft, draftEpoch, key: "grp_test/conversation-1" }],
    protocolVersion: chatProtocolVersion,
  };
}

function emptySnapshot(revision: number): ChatRuntimeSnapshot {
  return {
    protocolVersion: chatProtocolVersion,
    revision,
    sessions: [],
  };
}

// A fully materialized channel row, value-equal to what the projection
// message() helper becomes after contractMessageToChannelMessage — so seeded
// rows and canonical rows reconcile to the same identity.
function channelMessage(messageId: string, text: string): ChatMessage {
  return {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: undefined,
    createdAt: undefined,
    createdBy: undefined,
    delivery: "sent",
    error: undefined,
    messageId,
    parts: [{ kind: "markdown", text }],
    refs: [],
    role: "assistant",
    source: "server",
    status: undefined,
    text,
  };
}

function seededState(serverMessages: ChatMessage[]): ConversationChannelState {
  return {
    activity: undefined,
    assistantDraft: undefined,
    awaitingReply: false,
    awaitingSince: undefined,
    awaitingTimedOut: false,
    awaitingTurnKey: undefined,
    connection: "idle",
    conversation: undefined,
    draft: "",
    draftAttachments: [],
    errorKind: undefined,
    lastBackoffMs: 0,
    messages: serverMessages,
    pending: [],
    participantStatus: undefined,
    serverMessages,
    status: "ready",
    syncWarning: "stale",
  };
}

type RawStateBridge<Snapshot> = {
  get: () => Promise<Snapshot>;
  subscribe: (listener: (snapshot: Snapshot) => void) => () => void;
};

function installNativeBridgeMock(
  overrides: NonNullable<Parameters<typeof installNativeBridgeMockBase>[0]>
) {
  const rawState = overrides.chat?.state as unknown as
    | RawStateBridge<ChatRuntimeSnapshot>
    | undefined;
  const rawDrafts = overrides.chat?.drafts as unknown as
    | RawStateBridge<ChatRuntimeDraftsSnapshot>
    | undefined;
  if (!rawState && !rawDrafts) {
    return installNativeBridgeMockBase(overrides);
  }
  return installNativeBridgeMockBase({
    ...overrides,
    chat: {
      ...overrides.chat,
      ...(rawState ? { state: envelopeStateBridge(rawState) as never } : {}),
      ...(rawDrafts ? { drafts: envelopeStateBridge(rawDrafts) as never } : {}),
    },
  });
}

/** Serves a raw test snapshot the way Main does: inside a session envelope. */
function envelopeStateBridge<Snapshot>(raw: RawStateBridge<Snapshot>) {
  const get = async (_input: { session: SessionProductLease }) =>
    stateEnvelope(await raw.get());
  return Object.assign(get, {
    get,
    subscribe: (
      listener: (envelope: ReturnType<typeof stateEnvelope<Snapshot>>) => void,
      _input: { session: SessionProductLease }
    ) => raw.subscribe((next) => listener(stateEnvelope(next))),
  });
}

function stateEnvelope<Snapshot>(value: Snapshot, session = testProductLease) {
  return { session, snapshot: value };
}

function nativeAttachment(
  status: "uploading" | "uploaded" | "failed",
  {
    id = "native-attachment-1",
    name = "report.txt",
    size = 3,
  }: { id?: string; name?: string; size?: number } = {}
) {
  return {
    error: undefined,
    id,
    isImage: false,
    name,
    path: status === "uploaded" ? `/uploads/${name}` : undefined,
    size,
    status,
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

function sendOperation(value: unknown) {
  return value as Promise<unknown> & { accepted: Promise<void> };
}

function message(messageId: string, text: string) {
  return {
    attachments: [],
    delivery: "sent" as const,
    messageId,
    parts: [{ kind: "markdown" as const, text }],
    refs: [],
    role: "assistant",
    source: "server" as const,
    text,
  };
}
