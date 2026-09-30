import { describe, expect, it, vi } from "vitest";
import {
  CommaApiError,
  type CommaApiClient,
  type CommaConversation,
  type SalixMessage,
  type CommaWorkspaceBootstrap,
} from "@comma/app/api";
import {
  chatProtocolVersion,
  chatRuntimeSnapshotSchema,
  chatSurfaceProjectionLimit,
} from "@comma/chat-contract";
import { ChatCoordinator } from "../modules/chat";
import type { MainSessionBoundApi } from "../modules/session";

describe("ChatCoordinator", () => {
  it("uses the sending workspace's device for retained and detached messages", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({
      createApi: () => api,
      getClientDeviceId: (workspaceId) =>
        workspaceId === "wsp_a" ? "device-a" : undefined,
    });
    const target = { conversationId: "cnv_a", groupId: "grp_a", workspaceId: "wsp_a" };
    retainLease(coordinator, target, "renderer");
    await coordinator.sendDetachedMessage(target, "this computer");
    expect(api.sendMessage).toHaveBeenLastCalledWith(
      "grp_a",
      "cnv_a",
      expect.objectContaining({ clientDeviceId: "device-a" })
    );
    await coordinator.sendDetachedMessage(
      { ...target, conversationId: "cnv_detached" },
      "reply"
    );
    expect(api.sendMessage).toHaveBeenLastCalledWith("grp_a", "cnv_detached", {
      text: "reply",
      clientDeviceId: "device-a",
    });
    await coordinator.sendDetachedMessage(
      { conversationId: "cnv_b", groupId: "grp_b", workspaceId: "wsp_b" },
      "unknown"
    );
    expect(api.sendMessage).toHaveBeenLastCalledWith("grp_b", "cnv_b", {
      text: "unknown",
    });
    coordinator.close();
  });

  it("shares one channel and one draft projection across subscribers", () => {
    const coordinator = new ChatCoordinator({
      createApi: () => createApi(),
      releaseDelayMs: 0,
    });
    const target = { conversationId: "cnv_1", workspaceId: "wsp_1" };

    retainLease(coordinator, target, "electron");
    const sideChatLease = retainLease(coordinator, target, "side-chat");
    coordinator.setDraft({
      ...sideChatLease,
      draft: "shared",
      surfaceId: "side-chat",
    });

    expect(coordinator.state().sessions).toHaveLength(1);
    expect(coordinator.state().sessions[0]).toMatchObject({
      draftOwnerSurfaceId: "side-chat",
      refs: 2,
      state: { draft: "shared" },
    });
    coordinator.close();
  });

  it("publishes a keystroke as a draft without republishing the retained transcripts", () => {
    const coordinator = new ChatCoordinator({ createApi: () => createApi() });
    const lease = retainLease(
      coordinator,
      { conversationId: "cnv_1", workspaceId: "wsp_1" },
      "renderer"
    );
    coordinator.setDraft({ ...lease, draft: "h", surfaceId: "renderer" });
    const snapshots = vi.fn();
    const drafts = vi.fn();
    coordinator.subscribe(snapshots);
    coordinator.subscribeDrafts(drafts);
    const before = coordinator.state();

    const receipt = coordinator.setDraft({
      ...lease,
      draft: "hi",
      surfaceId: "renderer",
    });

    expect(snapshots).toHaveBeenCalledOnce();
    expect(drafts).toHaveBeenLastCalledWith({
      drafts: [{ draft: "hi", draftEpoch: receipt.draftEpoch, key: "grp_1/cnv_1" }],
      protocolVersion: chatProtocolVersion,
    });
    // State reads stay exact while reusing the validated transcript objects.
    const after = coordinator.state();
    expect(after.revision).toBe(before.revision);
    expect(after.sessions[0]).toMatchObject({
      draftEpoch: receipt.draftEpoch,
      state: { draft: "hi" },
    });
    expect(after.sessions[0]?.state.messages).toBe(before.sessions[0]?.state.messages);
    coordinator.close();
  });

  it("sends a detached reply through the retained channel without a send intent", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = {
      conversationId: "cnv_reply",
      groupId: "grp_1",
      workspaceId: "wsp_reply",
    };
    retainLease(coordinator, target, "renderer");

    await coordinator.sendDetachedMessage(target, "On it");

    // The retained channel tracks the send, so it carries a client request id
    // the bare API path never mints.
    expect(api.sendMessage).toHaveBeenCalledWith(
      "grp_1",
      "cnv_reply",
      expect.objectContaining({
        clientRequestId: expect.any(String),
        text: "On it",
      })
    );
    coordinator.close();
  });

  it("sends a detached reply straight to the API when no channel is retained", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });

    await coordinator.sendDetachedMessage(
      { conversationId: "cnv_gone", groupId: "grp_1", workspaceId: "wsp_gone" },
      "On it"
    );

    expect(api.sendMessage).toHaveBeenCalledWith("grp_1", "cnv_gone", {
      text: "On it",
    });
    expect(coordinator.state().sessions).toEqual([]);
    coordinator.close();
  });

  it("keeps selected local refs in the Main-owned draft and sends them without bytes", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_local", workspaceId: "wsp_local" };
    const lease = retainLease(coordinator, target, "renderer");
    const localFileRef = `lfi1_${"c".repeat(43)}`;

    coordinator.attachLocalFiles({
      ...lease,
      files: [
        {
          localFileRef,
          mediaType: "application/pdf",
          name: "report.pdf",
          size: 12,
        },
      ],
      surfaceId: "renderer",
    });

    expect(coordinator.state().sessions[0]).toMatchObject({
      draftOwnerSurfaceId: "renderer",
      state: {
        draftAttachments: [
          { id: localFileRef, name: "report.pdf", size: 12, status: "uploaded" },
        ],
      },
    });

    await coordinator.send(
      sendInput(coordinator, lease, { surfaceId: "renderer", text: "review" })
    );

    expect(api.sendMessage).toHaveBeenCalledWith(
      "grp_1",
      "cnv_local",
      expect.objectContaining({
        localFiles: [
          {
            displayName: "report.pdf",
            localFileRef,
            mediaType: "application/pdf",
            size: 12,
          },
        ],
        text: "review",
      })
    );
    coordinator.close();
  });

  it("reads a bounded uploaded workspace image through the current Main API", async () => {
    const imageBytes = Uint8Array.of(137, 80, 78, 71);
    const previewBytes = Uint8Array.of(137, 80, 78, 71, 13, 10, 26, 10);
    const renderGroupImagePreview = vi.fn(async () => previewBytes);
    const api = {
      fetchGroupFile: vi.fn(async () => new Blob([imageBytes], { type: "image/png" })),
    } as Partial<CommaApiClient> as CommaApiClient;
    const coordinator = new ChatCoordinator({
      createApi: () => api,
      renderGroupImagePreview,
    });
    const path = `/uploads/${"a".repeat(22)}-opaque-image.png`;

    await expect(
      coordinator.readGroupImage({
        groupId: "grp_1",
        path,
        source: "group-file",
      })
    ).resolves.toEqual(previewBytes);
    expect(api.fetchGroupFile).toHaveBeenCalledWith("grp_1", path);
    expect(renderGroupImagePreview).toHaveBeenCalledWith({
      bytes: imageBytes,
      mediaType: "image/png",
    });
    await expect(
      coordinator.readGroupImage({
        groupId: "grp_1",
        path: "/uploads/nested/private.png",
        source: "group-file",
      })
    ).rejects.toThrow();
    expect(api.fetchGroupFile).toHaveBeenCalledOnce();
    coordinator.close();
  });

  it("reads an Agent image by its blob reference without looking up a Message", async () => {
    const imageBytes = Uint8Array.of(137, 80, 78, 71);
    const previewBytes = Uint8Array.of(137, 80, 78, 71, 13, 10, 26, 10);
    const blobRef = {
      hash: "b".repeat(64),
      kind: "blob" as const,
      size: imageBytes.byteLength,
      uuid: "a".repeat(32),
    };
    const renderGroupImagePreview = vi.fn(async () => previewBytes);
    const api = {
      fetchAgentBlob: vi.fn(
        async () => new Blob([imageBytes], { type: "application/octet-stream" })
      ),
    } as Partial<CommaApiClient> as CommaApiClient;
    const coordinator = new ChatCoordinator({
      createApi: () => api,
      renderGroupImagePreview,
    });

    await expect(
      coordinator.readGroupImage({
        agentId: "agt1_image_author",
        blobRef,
        fileName: "capture.png",
        groupId: "grp_1",
        mediaType: "image/png",
        source: "agent-blob",
      })
    ).resolves.toEqual(previewBytes);
    expect(api.fetchAgentBlob).toHaveBeenCalledWith(
      "grp_1",
      "agt1_image_author",
      blobRef
    );
    expect(renderGroupImagePreview).toHaveBeenCalledWith({
      bytes: imageBytes,
      mediaType: "image/png",
    });
    coordinator.close();
  });

  it("rejects an oversized or mismatched uploaded Workspace image response", async () => {
    const oversizedApi = {
      fetchGroupFile: vi.fn(
        async () =>
          new Blob([new Uint8Array(10_000_001)], {
            type: "image/png",
          })
      ),
    } as Partial<CommaApiClient> as CommaApiClient;
    const mismatchedApi = {
      fetchGroupFile: vi.fn(
        async () => new Blob([Uint8Array.of(1)], { type: "image/svg+xml" })
      ),
    } as Partial<CommaApiClient> as CommaApiClient;
    const oversized = new ChatCoordinator({ createApi: () => oversizedApi });
    const mismatched = new ChatCoordinator({ createApi: () => mismatchedApi });

    await expect(
      oversized.readGroupImage({
        groupId: "grp_1",
        path: `/uploads/${"b".repeat(22)}-huge.png`,
        source: "group-file",
      })
    ).rejects.toThrow("Workspace image response is unavailable.");
    await expect(
      mismatched.readGroupImage({
        groupId: "grp_1",
        path: `/uploads/${"c".repeat(22)}-not-really.png`,
        source: "group-file",
      })
    ).rejects.toThrow("Workspace image response is unavailable.");
    oversized.close();
    mismatched.close();
  });

  it("reuses unchanged session projections when another session changes", () => {
    const coordinator = new ChatCoordinator({ createApi });
    const alpha = { conversationId: "cnv_alpha", workspaceId: "wsp_1" };
    const beta = { conversationId: "cnv_beta", workspaceId: "wsp_1" };
    const alphaLease = retainLease(coordinator, alpha, "alpha");
    retainLease(coordinator, beta, "beta");

    const before = coordinator.state();
    const alphaBefore = before.sessions.find((session) =>
      session.key.endsWith("alpha")
    );
    const betaBefore = before.sessions.find((session) => session.key.endsWith("beta"));

    coordinator.setDraft({
      ...alphaLease,
      draft: "changed",
      surfaceId: "alpha",
    });

    const after = coordinator.state();
    const alphaAfter = after.sessions.find((session) => session.key.endsWith("alpha"));
    const betaAfter = after.sessions.find((session) => session.key.endsWith("beta"));
    expect(alphaAfter).not.toBe(alphaBefore);
    expect(alphaAfter?.state.draft).toBe("changed");
    expect(betaAfter).toBe(betaBefore);
    expect(betaAfter).toMatchObject({
      conversationId: "cnv_beta",
      refs: 1,
      workspaceId: "wsp_1",
    });
    coordinator.close();
  });

  it("keeps canonical history available while another retained conversation updates", async () => {
    type EventListener = Parameters<
      CommaApiClient["streamConversationEvents"]
    >[2]["onEvent"];
    const eventListeners = new Map<string, EventListener>();
    const api = {
      pollConversation: vi.fn(async (groupId, conversationId) => ({
        conversation: {
          group_id: groupId,
          id: conversationId,
          kind: "user_chat" as const,
          messages: [],
          status: "active",
          title: "Chat",
        },
        notModified: false,
      })),
      streamConversationEvents: vi.fn(
        (_groupId, conversationId, opts) =>
          new Promise<void>((_resolve, reject) => {
            eventListeners.set(conversationId, opts.onEvent);
            opts.signal?.addEventListener("abort", () => reject(abortError()), {
              once: true,
            });
          })
      ),
    } as Partial<CommaApiClient> as CommaApiClient;
    const published = [] as ReturnType<ChatCoordinator["state"]>[];
    const coordinator = new ChatCoordinator({
      createApi: () => api,
      onStateChanged(snapshot) {
        published.push(chatRuntimeSnapshotSchema.parse(snapshot));
      },
    });

    retainLease(
      coordinator,
      { conversationId: "cnv_history", workspaceId: "wsp_1" },
      "history"
    );
    retainLease(
      coordinator,
      { conversationId: "cnv_recovering", workspaceId: "wsp_1" },
      "recovering"
    );
    await vi.waitFor(() => expect(eventListeners.size).toBe(2));

    eventListeners.get("cnv_history")?.(
      {
        conversation_id: "cnv_history",
        group_id: "grp_1",
        messages: [canonicalMessage("History remains visible", "msg_history", "agent")],
        status: "open",
        type: "snapshot",
      },
      "snapshot"
    );
    await vi.waitFor(() =>
      expect(
        published
          .at(-1)
          ?.sessions.flatMap((session) => session.state.messages)
          .map((message) => message.text)
      ).toContain("History remains visible")
    );

    eventListeners.get("cnv_recovering")?.(
      {
        conversation_id: "cnv_recovering",
        group_id: "grp_1",
        messages: [
          canonicalMessage("First canonical projection", "msg_recovering", "agent"),
        ],
        status: "open",
        type: "snapshot",
      },
      "snapshot"
    );
    expect(
      published
        .at(-1)
        ?.sessions.flatMap((session) => session.state.messages)
        .map((message) => message.text)
    ).toContain("History remains visible");

    eventListeners.get("cnv_recovering")?.(
      {
        conversation_id: "cnv_recovering",
        group_id: "grp_1",
        messages: [
          canonicalMessage("Updated canonical history", "msg_recovering", "agent"),
        ],
        status: "open",
        type: "snapshot",
      },
      "snapshot"
    );
    await vi.waitFor(() =>
      expect(
        published
          .at(-1)
          ?.sessions.flatMap((session) => session.state.messages)
          .map((message) => message.text)
      ).toEqual(["History remains visible", "Updated canonical history"])
    );
    coordinator.close();
  });

  it("publishes the same optimistic send projection to every listener", async () => {
    const snapshots: string[][] = [];
    const coordinator = new ChatCoordinator({ createApi });
    const target = { conversationId: "cnv_1", workspaceId: "wsp_1" };
    coordinator.subscribe((snapshot) => {
      snapshots.push(
        snapshot.sessions[0]?.state.messages.map((message) => message.text) ?? []
      );
    });
    const lease = retainLease(coordinator, target, "electron");

    await coordinator.send(
      sendInput(coordinator, lease, {
        surfaceId: "electron",
        text: "hello from either surface",
      })
    );

    expect(coordinator.state().sessions[0]?.state.messages).toMatchObject([
      { role: "user", text: "hello from either surface" },
    ]);
    expect(
      snapshots.some((messages) => messages.includes("hello from either surface"))
    ).toBe(true);
    coordinator.close();
  });

  it("materializes Clear as a per-surface observation fence", async () => {
    let onEvent:
      | Parameters<CommaApiClient["streamConversationEvents"]>[2]["onEvent"]
      | undefined;
    const api = {
      pollConversation: vi.fn(async () => ({
        conversation: {
          id: "cnv_1",
          kind: "user_chat" as const,
          messages: [],
          status: "active",
          title: "Chat",
          group_id: "grp_1",
        },
        notModified: false,
      })),
      streamConversationEvents: vi.fn(
        (_workspaceId, _conversationId, opts) =>
          new Promise<void>((_resolve, reject) => {
            onEvent = opts.onEvent;
            opts.signal?.addEventListener("abort", () => reject(abortError()), {
              once: true,
            });
          })
      ),
      sendMessage: vi.fn(() => new Promise<CommaConversation>(() => undefined)),
    } as Partial<CommaApiClient> as CommaApiClient;
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_1", workspaceId: "wsp_1" };
    const mainLease = retainLease(coordinator, target, "win_main:wsp_1/cnv_1");
    const sideLease = retainLease(coordinator, target, "win_side_chat:wsp_1/cnv_1");

    await vi.waitFor(() => expect(onEvent).toBeTypeOf("function"));

    onEvent?.(
      {
        type: "snapshot",
        conversation_id: "cnv_1",
        last_event_id: 1,
        messages: [
          canonicalMessage("Start D1", "msg_D1_user", "user"),
          canonicalMessage("Welcome", "msg_welcome", "agent"),
        ],
        status: "waiting",
        group_id: "grp_1",
      },
      "snapshot"
    );
    onEvent?.(
      {
        type: "message_draft_started",
        conversation_id: "cnv_1",
        draft_id: "draft_D1",
        response_key: "rsp_D1",
        source_message_ids: ["msg_D1_user"],
        status: "started",
        text: "Old D1 draft",
      },
      "message_draft_started"
    );
    onEvent?.(
      {
        type: "activity",
        conversation_id: "cnv_1",
        phase: "execution",
        producer_epoch: "epoch_D1",
        response_key: "rsp_D1",
        sequence: 1,
        source_message_ids: ["msg_D1_user"],
        status: "running",
        summary: "Old D1 activity",
        summary_class: "public",
      },
      "activity"
    );

    coordinator.clearPresentation(sideLease);
    let session = coordinator.state().sessions[0]!;
    let sideState = session.surfaceProjections?.find(
      (projection) => projection.subscriberId === sideLease.subscriberId
    )?.state;
    expect(session.state).toMatchObject({
      activity: { summary: "Old D1 activity" },
      assistantDraft: { draftId: "draft_D1" },
      messages: [{ messageId: "msg_D1_user" }, { messageId: "msg_welcome" }],
    });
    expect(sideState).toMatchObject({
      activity: undefined,
      assistantDraft: undefined,
      awaitingReply: false,
      locallyAwaitingReply: false,
      messages: [],
      pending: [],
      serverMessages: [],
    });

    void coordinator.send(
      sendInput(coordinator, sideLease, {
        surfaceId: "win_side_chat",
        text: "Start D2",
      })
    );
    session = coordinator.state().sessions[0]!;
    const d2ClientRequestId = session.state.pending[0]!.clientRequestId;
    sideState = session.surfaceProjections?.find(
      (projection) => projection.subscriberId === sideLease.subscriberId
    )?.state;
    expect(sideState).toMatchObject({
      activity: undefined,
      assistantDraft: undefined,
      awaitingReply: true,
      locallyAwaitingReply: true,
      messages: [{ role: "user", source: "pending", text: "Start D2" }],
      pending: [{ text: "Start D2" }],
    });

    onEvent?.(
      {
        type: "message_draft_delta",
        conversation_id: "cnv_1",
        draft_id: "draft_D1",
        response_key: "rsp_D1",
        source_message_ids: ["msg_D1_user"],
        status: "delta",
        text: "Late D1 draft",
      },
      "message_draft_delta"
    );
    onEvent?.(
      {
        type: "snapshot",
        conversation_id: "cnv_1",
        last_event_id: 2,
        messages: [
          canonicalMessage("Start D1", "msg_D1_user", "user"),
          canonicalMessage("Welcome", "msg_welcome", "agent"),
          canonicalMessage("Late D1 final", "msg_D1_final", "agent"),
        ],
        status: "waiting",
        group_id: "grp_1",
      },
      "snapshot"
    );
    session = coordinator.state().sessions[0]!;
    sideState = session.surfaceProjections?.find(
      (projection) => projection.subscriberId === sideLease.subscriberId
    )?.state;
    expect(sideState?.messages.map((message) => message.text)).toEqual([
      "Late D1 final",
      "Start D2",
    ]);
    expect(sideState?.assistantDraft).toBeUndefined();
    expect(sideState?.activity).toBeUndefined();

    onEvent?.(
      {
        type: "activity",
        conversation_id: "cnv_1",
        phase: "execution",
        producer_epoch: "epoch_D1",
        response_key: "rsp_D2",
        sequence: 2,
        source_message_ids: ["msg_D2_user"],
        status: "running",
        summary: "Fresh D2 activity",
        summary_class: "public",
      },
      "activity"
    );
    expect(
      coordinator.state().sessions[0]?.surfaceProjections?.[0]?.state.activity
    ).toMatchObject({ summary: "Fresh D2 activity" });
    onEvent?.(
      {
        type: "message_draft_started",
        conversation_id: "cnv_1",
        draft_id: "draft_D2",
        response_key: "rsp_D2",
        source_message_ids: ["msg_D2_user"],
        status: "started",
        text: "Fresh D2 draft",
      },
      "message_draft_started"
    );
    session = coordinator.state().sessions[0]!;
    sideState = session.surfaceProjections?.find(
      (projection) => projection.subscriberId === sideLease.subscriberId
    )?.state;
    expect(sideState?.assistantDraft).toMatchObject({
      draftId: "draft_D2",
      text: "Fresh D2 draft",
    });
    expect(sideState?.activity).toMatchObject({ summary: "Fresh D2 activity" });

    onEvent?.(
      {
        type: "message_created",
        client_request_id: d2ClientRequestId,
        conversation_id: "cnv_1",
        event_id: 3,
        message_id: "msg_D2_user",
        role: "user",
      },
      "message_created"
    );
    session = coordinator.state().sessions[0]!;
    sideState = session.surfaceProjections?.find(
      (projection) => projection.subscriberId === sideLease.subscriberId
    )?.state;
    expect(sideState).toMatchObject({
      activity: { summary: "Fresh D2 activity" },
      assistantDraft: { draftId: "draft_D2", text: "Fresh D2 draft" },
      messages: [{ text: "Late D1 final" }, { text: "Start D2" }],
    });
    expect(session.state.messages.map((message) => message.text)).toEqual([
      "Start D1",
      "Welcome",
      "Late D1 final",
      "Start D2",
    ]);
    expect(() => chatRuntimeSnapshotSchema.parse(coordinator.state())).not.toThrow();
    expect(mainLease.subscriberId).not.toBe(sideLease.subscriberId);
    coordinator.close();
  });

  it("shows canonical Messages first observed after Clear without reply metadata", async () => {
    let onEvent:
      | Parameters<CommaApiClient["streamConversationEvents"]>[2]["onEvent"]
      | undefined;
    const api = streamingApi((listener) => {
      onEvent = listener;
    });
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_1", workspaceId: "wsp_1" };
    const lease = retainLease(coordinator, target, "win_side_chat:resurrection");

    await vi.waitFor(() => expect(onEvent).toBeTypeOf("function"));

    onEvent?.(
      {
        type: "snapshot",
        conversation_id: "cnv_1",
        messages: [],
        status: "waiting",
        group_id: "grp_1",
      },
      "snapshot"
    );
    onEvent?.(
      {
        type: "message_draft_started",
        conversation_id: "cnv_1",
        draft_id: "draft_U",
        response_key: "rsp_U",
        source_message_ids: ["msg_U"],
        status: "started",
        text: "pre-Clear draft",
      },
      "message_draft_started"
    );
    coordinator.clearPresentation(lease);

    onEvent?.(
      {
        type: "message_created",
        conversation_id: "cnv_1",
        event_id: 1,
        message_id: "msg_U",
        role: "user",
      },
      "message_created"
    );
    onEvent?.(
      {
        type: "message_draft_delta",
        conversation_id: "cnv_1",
        draft_id: "draft_U",
        response_key: "rsp_U",
        source_message_ids: ["msg_U"],
        status: "delta",
        text: "resolved after Clear",
      },
      "message_draft_delta"
    );
    expect(
      surfaceState(coordinator, lease.subscriberId)?.assistantDraft
    ).toBeUndefined();

    onEvent?.(
      {
        type: "message_created",
        conversation_id: "cnv_1",
        event_id: 2,
        message_id: "msg_A",
        role: "assistant",
      },
      "message_created"
    );
    await vi.waitFor(() =>
      expect(api.streamConversationEvents).toHaveBeenCalledTimes(2)
    );
    onEvent?.(
      {
        type: "snapshot",
        conversation_id: "cnv_1",
        last_event_id: 2,
        messages: [
          canonicalMessage("U", "msg_U", "user"),
          canonicalMessage("A", "msg_A", "agent"),
        ],
        status: "waiting",
        group_id: "grp_1",
      },
      "snapshot"
    );

    expect(surfaceState(coordinator, lease.subscriberId)).toMatchObject({
      assistantDraft: undefined,
      messages: [{ messageId: "msg_U" }, { messageId: "msg_A" }],
      serverMessages: [{ messageId: "msg_U" }, { messageId: "msg_A" }],
    });
    coordinator.close();
  });

  it("shows a draft and Messages first observed after Clear", async () => {
    let onEvent:
      | Parameters<CommaApiClient["streamConversationEvents"]>[2]["onEvent"]
      | undefined;
    const api = streamingApi((listener) => {
      onEvent = listener;
    });
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_1", workspaceId: "wsp_1" };
    const lease = retainLease(coordinator, target, "win_side_chat:fresh");

    await vi.waitFor(() => expect(onEvent).toBeTypeOf("function"));

    coordinator.clearPresentation(lease);
    onEvent?.(
      {
        type: "snapshot",
        conversation_id: "cnv_1",
        messages: [],
        status: "waiting",
        group_id: "grp_1",
      },
      "snapshot"
    );
    onEvent?.(
      {
        type: "message_draft_started",
        conversation_id: "cnv_1",
        draft_id: "draft_U",
        response_key: "rsp_U",
        source_message_ids: ["msg_U"],
        status: "started",
        text: "fresh draft",
      },
      "message_draft_started"
    );
    onEvent?.(
      {
        type: "message_created",
        conversation_id: "cnv_1",
        event_id: 1,
        message_id: "msg_U",
        role: "user",
      },
      "message_created"
    );
    expect(surfaceState(coordinator, lease.subscriberId)?.assistantDraft).toMatchObject(
      {
        draftId: "draft_U",
        text: "fresh draft",
      }
    );

    onEvent?.(
      {
        type: "message_created",
        conversation_id: "cnv_1",
        event_id: 2,
        message_id: "msg_A",
        role: "assistant",
      },
      "message_created"
    );
    await vi.waitFor(() =>
      expect(api.streamConversationEvents).toHaveBeenCalledTimes(2)
    );
    onEvent?.(
      {
        type: "snapshot",
        conversation_id: "cnv_1",
        last_event_id: 2,
        messages: [
          canonicalMessage("U", "msg_U", "user"),
          canonicalMessage("A", "msg_A", "agent"),
        ],
        status: "waiting",
        group_id: "grp_1",
      },
      "snapshot"
    );

    expect(
      surfaceState(coordinator, lease.subscriberId)?.messages.map(
        (message) => message.messageId
      )
    ).toEqual(["msg_U", "msg_A"]);
    coordinator.close();
  });

  it("keeps bounded subscriber projections across release/recovery and fences stale leases", () => {
    const coordinator = new ChatCoordinator({ createApi });
    const target = { conversationId: "cnv_projection", workspaceId: "wsp_1" };
    const firstLease = retainLease(
      coordinator,
      target,
      "win_side_chat:wsp_1/cnv_projection"
    );
    coordinator.clearPresentation(firstLease);
    coordinator.release(firstLease);

    const recoveredLease = retainLease(coordinator, target, firstLease.subscriberId);
    expect(
      coordinator
        .state()
        .sessions[0]?.surfaceProjections?.map((projection) => projection.subscriberId)
    ).toContain(firstLease.subscriberId);
    expect(() => coordinator.clearPresentation(firstLease)).toThrow(
      /stale chat lease/i
    );
    coordinator.clearPresentation(recoveredLease);
    expect(
      coordinator
        .state()
        .sessions[0]?.surfaceProjections?.find(
          (projection) => projection.subscriberId === recoveredLease.subscriberId
        )?.generation
    ).toBe(2);
    coordinator.release(recoveredLease);

    for (let index = 0; index < chatSurfaceProjectionLimit; index += 1) {
      const lease = retainLease(
        coordinator,
        target,
        `surface_${index}:wsp_1/cnv_projection`
      );
      coordinator.clearPresentation(lease);
    }
    const projections = coordinator.state().sessions[0]?.surfaceProjections ?? [];
    expect(projections).toHaveLength(chatSurfaceProjectionLimit);
    expect(
      projections.some(
        (projection) => projection.subscriberId === recoveredLease.subscriberId
      )
    ).toBe(false);
    expect(projections.map((projection) => projection.subscriberId)).toEqual(
      Array.from(
        { length: chatSurfaceProjectionLimit },
        (_, index) => `surface_${index}:wsp_1/cnv_projection`
      )
    );
    expect(() => chatRuntimeSnapshotSchema.parse(coordinator.state())).not.toThrow();
    coordinator.close();
  });

  it("rejects a new clear instead of evicting an active subscriber projection", () => {
    const coordinator = new ChatCoordinator({ createApi });
    const target = { conversationId: "cnv_active_limit", workspaceId: "wsp_1" };
    const activeLeases = Array.from(
      { length: chatSurfaceProjectionLimit },
      (_, index) =>
        retainLease(coordinator, target, `active_${index}:wsp_1/cnv_active_limit`)
    );
    for (const lease of activeLeases) {
      coordinator.clearPresentation(lease);
    }
    const overflowLease = retainLease(
      coordinator,
      target,
      "active_overflow:wsp_1/cnv_active_limit"
    );

    expect(() => coordinator.clearPresentation(overflowLease)).toThrow(
      /surface projection limit \(8\) reached/i
    );
    expect(
      coordinator
        .state()
        .sessions[0]?.surfaceProjections?.map((projection) => projection.subscriberId)
    ).toEqual(activeLeases.map((lease) => lease.subscriberId));

    coordinator.release(activeLeases[0]!);
    expect(() => coordinator.clearPresentation(overflowLease)).not.toThrow();
    const projections = coordinator.state().sessions[0]?.surfaceProjections ?? [];
    expect(projections).toHaveLength(chatSurfaceProjectionLimit);
    expect(projections.map((projection) => projection.subscriberId)).not.toContain(
      activeLeases[0]!.subscriberId
    );
    expect(projections.map((projection) => projection.subscriberId)).toContain(
      overflowLease.subscriberId
    );
    coordinator.close();
  });

  it("keeps an untouched session's projection, verdict included, across another session's publish", () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const first = {
      conversationId: "cnv_first",
      groupId: "grp_test",
      workspaceId: "wsp_first",
    };
    const second = {
      conversationId: "cnv_second",
      groupId: "grp_test",
      workspaceId: "wsp_second",
    };
    const firstLease = retainLease(coordinator, first, "renderer");
    retainLease(coordinator, second, "renderer");
    const before = coordinator.state();
    const firstBefore = before.sessions.find((session) =>
      session.key.includes("first")
    );
    expect(firstBefore).toBeDefined();

    // Another subscriber republishes the second conversation. The first
    // session did not move, so its projection is served from the cache — the
    // same object, not a rebuilt and re-validated copy.
    retainLease(coordinator, second, "side-chat");
    const after = coordinator.state();
    expect(after.revision).toBeGreaterThan(before.revision);
    expect(after.sessions.find((session) => session.key.includes("first"))).toBe(
      firstBefore
    );

    // Changing the first session replaces only its projection.
    coordinator.setDraft({ ...firstLease, draft: "j", surfaceId: "renderer" });
    const touched = coordinator.state();
    expect(touched.sessions.find((session) => session.key.includes("first"))).not.toBe(
      firstBefore
    );
    expect(touched.sessions.find((session) => session.key.includes("second"))).toBe(
      after.sessions.find((session) => session.key.includes("second"))
    );
  });

  it("projects one target without renderer drafts, local paths, or unrelated sessions", async () => {
    const api = createApi();
    api.uploadGroupFile = vi.fn(async (_workspaceId, input) => ({
      name: input.name,
      path: `/private/${input.name}`,
      size: input.data.size,
    }));
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = {
      conversationId: "cnv_target",
      groupId: "grp_test",
      workspaceId: "wsp_target",
    };
    const unrelated = {
      conversationId: "cnv_unrelated",
      groupId: "grp_test",
      workspaceId: "wsp_unrelated",
    };

    const targetLease = retainLease(coordinator, target, "side-chat");
    const unrelatedLease = retainLease(coordinator, unrelated, "renderer");
    coordinator.setDraft({
      ...targetLease,
      draft: "assigned-renderer-draft-sentinel",
      surfaceId: "renderer-main",
    });
    coordinator.attach({
      ...targetLease,
      bytes: new Uint8Array([1]),
      name: "assigned-attachment-sentinel.txt",
      size: 1,
      surfaceId: "renderer-main",
    });
    coordinator.setDraft({
      ...unrelatedLease,
      draft: "unrelated-draft-sentinel",
      surfaceId: "renderer",
    });
    coordinator.attach({
      ...unrelatedLease,
      bytes: new Uint8Array([1]),
      name: "sentinel.txt",
      size: 1,
      surfaceId: "renderer",
    });
    await vi.waitFor(() =>
      expect(
        coordinator
          .state()
          .sessions.find((session) => session.key.includes("unrelated"))?.state
          .draftAttachments[0]
      ).toMatchObject({ status: "uploaded" })
    );
    await vi.waitFor(() =>
      expect(
        coordinator.state().sessions.find((session) => session.key.includes("target"))
          ?.state.draftAttachments[0]
      ).toMatchObject({ status: "uploaded" })
    );

    const projected = coordinator.sideChatSessionForTarget(target);
    expect(projected).toMatchObject({
      conversationId: "cnv_target",
      groupId: "grp_test",
      workspaceId: "wsp_target",
    });
    expect(projected).not.toHaveProperty("draftOwnerSurfaceId");
    expect(projected).not.toHaveProperty("key");
    expect(projected).not.toHaveProperty("refs");
    expect(projected?.state).toEqual({
      awaitingReply: false,
      messages: [],
    });
    expect(projected?.state).not.toHaveProperty("draft");
    expect(projected?.state).not.toHaveProperty("draftAttachments");
    expect(projected?.state).not.toHaveProperty("pending");
    expect(projected?.state).not.toHaveProperty("serverMessages");
    expect(JSON.stringify(projected)).not.toContain("assigned-renderer-draft-sentinel");
    expect(JSON.stringify(projected)).not.toContain(
      "/private/assigned-attachment-sentinel.txt"
    );
    expect(JSON.stringify(projected)).not.toContain("unrelated-draft-sentinel");
    expect(JSON.stringify(projected)).not.toContain(
      "/private/unrelated-attachment-sentinel.txt"
    );

    for (let index = 0; index < 25; index += 1) {
      retainLease(
        coordinator,
        {
          conversationId: `cnv_noise_${index}`,
          groupId: "grp_test",
          workspaceId: "wsp_noise",
        },
        `renderer-${index}`
      );
    }
    expect(coordinator.sideChatSessionForTarget(target)).toEqual(projected);
    expect(
      coordinator.sideChatSessionForTarget({
        conversationId: "missing",
        groupId: "grp_test",
        workspaceId: "missing",
      })
    ).toBeUndefined();
    coordinator.close();
  });

  it("notifies a side-chat target only when that target changes", () => {
    const coordinator = new ChatCoordinator({ createApi });
    const target = {
      conversationId: "cnv_target",
      groupId: "grp_test",
      workspaceId: "wsp_target",
    };
    const unrelated = {
      conversationId: "cnv_unrelated",
      groupId: "grp_test",
      workspaceId: "wsp_unrelated",
    };
    const targetLease = retainLease(coordinator, target, "side-chat");
    const listener = vi.fn();
    const unsubscribe = coordinator.subscribeSideChatTarget(target, listener);
    expect(listener).toHaveBeenCalledTimes(1);

    const unrelatedLease = retainLease(coordinator, unrelated, "renderer");
    coordinator.setDraft({
      ...unrelatedLease,
      draft: "must not wake target listener",
      surfaceId: "renderer",
    });
    expect(listener).toHaveBeenCalledTimes(1);

    // A draft is not Side Chat content, so an edit leaves the target quiet.
    coordinator.setDraft({
      ...targetLease,
      draft: "target draft",
      surfaceId: "native-side-chat",
    });
    expect(listener).toHaveBeenCalledTimes(1);

    retainLease(coordinator, target, "renderer");
    expect(listener).toHaveBeenCalledTimes(2);
    expect(JSON.stringify(listener.mock.lastCall?.[0])).not.toContain("target draft");

    unsubscribe();
    coordinator.close();
  });

  it("bounds retained sessions and per-surface message projections", async () => {
    const api = createApi();
    const messages = Array.from({ length: 550 }, (_, index) => ({
      ...canonicalMessage(
        `message ${index}`,
        `message-${index}`,
        index % 2 === 0 ? "user" : "agent"
      ),
      created_at: index,
    }));
    api.streamConversationEvents = vi.fn(
      async (_workspaceId, _conversationId, opts) => {
        opts.onEvent?.(
          {
            conversation_id: "cnv_window",
            messages,
            status: "waiting",
            type: "snapshot",
            group_id: "grp_window",
          },
          "snapshot"
        );
        await new Promise<void>((_resolve, reject) => {
          opts.signal?.addEventListener("abort", () => reject(abortError()), {
            once: true,
          });
        });
      }
    );
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = {
      conversationId: "cnv_window",
      groupId: "grp_window",
      workspaceId: "wsp_window",
    };
    retainLease(coordinator, target, "renderer");

    await vi.waitFor(() =>
      expect(coordinator.state().sessions[0]?.state.messages).toHaveLength(500)
    );
    const sideChatMessages =
      coordinator.sideChatSessionForTarget(target)?.state.messages;
    expect(sideChatMessages).toHaveLength(200);
    expect(sideChatMessages?.[0]?.messageId).toBe("message-350");
    expect(sideChatMessages?.at(-1)?.messageId).toBe("message-549");
    coordinator.close();

    const bounded = new ChatCoordinator({ createApi });
    for (let index = 0; index < 32; index += 1) {
      retainLease(
        bounded,
        { conversationId: `cnv_${index}`, workspaceId: "wsp_bounded" },
        `surface_${index}`
      );
    }
    expect(() =>
      retainLease(
        bounded,
        { conversationId: "cnv_overflow", workspaceId: "wsp_bounded" },
        "surface_overflow"
      )
    ).toThrow("Chat retains at most 32 active sessions.");
    bounded.close();
  });

  it("keeps a renderer-owned draft and attachments out of another surface send", async () => {
    const api = createApi();
    api.uploadGroupFile = vi.fn(async (_workspaceId, input) => ({
      name: input.name,
      path: "/private/renderer-owned.txt",
      size: input.data.size,
    }));
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_1", workspaceId: "wsp_1" };
    const lease = retainLease(coordinator, target, "renderer");
    coordinator.setDraft({
      ...lease,
      draft: "renderer draft",
      surfaceId: "renderer",
    });
    coordinator.attach({
      ...lease,
      bytes: new Uint8Array([1]),
      name: "renderer-owned.txt",
      size: 1,
      surfaceId: "renderer",
    });
    await vi.waitFor(() =>
      expect(coordinator.state().sessions[0]?.state.draftAttachments[0]).toMatchObject({
        status: "uploaded",
      })
    );

    await coordinator.send(
      sendInput(coordinator, lease, {
        surfaceId: "side-chat",
        text: "native-only text",
      })
    );

    expect(api.sendMessage).toHaveBeenLastCalledWith(
      "grp_1",
      "cnv_1",
      expect.objectContaining({ text: "native-only text" })
    );
    expect(coordinator.state().sessions[0]).toMatchObject({
      draftOwnerSurfaceId: "renderer",
      state: {
        draft: "renderer draft",
        draftAttachments: [
          expect.objectContaining({ path: "/private/renderer-owned.txt" }),
        ],
      },
    });

    await coordinator.send(
      sendInput(coordinator, lease, { surfaceId: "renderer", text: "renderer draft" })
    );

    expect(api.sendMessage).toHaveBeenLastCalledWith(
      "grp_1",
      "cnv_1",
      expect.objectContaining({
        text: expect.stringContaining("/private/renderer-owned.txt"),
      })
    );
    expect(coordinator.state().sessions[0]).toMatchObject({
      state: { draft: "", draftAttachments: [] },
    });
    expect(coordinator.state().sessions[0]).not.toHaveProperty("draftOwnerSurfaceId");
    coordinator.close();
  });

  it("lets the owning surface send without consuming its draft or attachments", async () => {
    const api = createApi();
    api.uploadGroupFile = vi.fn(async (_workspaceId, input) => ({
      name: input.name,
      path: "/private/keep-staged.txt",
      size: input.data.size,
    }));
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_1", workspaceId: "wsp_1" };
    const lease = retainLease(coordinator, target, "renderer");

    coordinator.setDraft({
      ...lease,
      draft: "unfinished follow-up",
      surfaceId: "renderer",
    });
    coordinator.attach({
      ...lease,
      bytes: new Uint8Array([1]),
      name: "keep-staged.txt",
      size: 1,
      surfaceId: "renderer",
    });
    await vi.waitFor(() =>
      expect(coordinator.state().sessions[0]?.state.draftAttachments[0]).toMatchObject({
        name: "keep-staged.txt",
        status: "uploaded",
      })
    );

    await coordinator.send(
      sendInput(coordinator, lease, {
        consumeDraft: false,
        surfaceId: "renderer",
        text: "generated suggestion",
      })
    );

    expect(api.sendMessage).toHaveBeenLastCalledWith(
      "grp_1",
      "cnv_1",
      expect.objectContaining({ text: "generated suggestion" })
    );
    expect(coordinator.state().sessions[0]).toMatchObject({
      draftOwnerSurfaceId: "renderer",
      state: {
        draft: "unfinished follow-up",
        draftAttachments: [
          expect.objectContaining({ name: "keep-staged.txt", status: "uploaded" }),
        ],
      },
    });
    coordinator.close();
  });

  it("localizes main-owned attachment validation with the coordinator locale", () => {
    const api = createApi();
    api.uploadGroupFile = vi.fn();
    const coordinator = new ChatCoordinator({
      createApi: () => api,
      locale: "zh-CN",
    });
    const target = { conversationId: "cnv_1", workspaceId: "wsp_1" };
    const lease = retainLease(coordinator, target, "renderer");

    coordinator.attach({
      ...lease,
      bytes: new Uint8Array([1]),
      name: "script.exe",
      size: 1,
      surfaceId: "renderer",
    });
    coordinator.attach({
      ...lease,
      bytes: new Uint8Array([1]),
      name: "huge.txt",
      size: 10_000_001,
      surfaceId: "renderer",
    });

    expect(api.uploadGroupFile).not.toHaveBeenCalled();
    expect(coordinator.state().sessions[0]?.state.draftAttachments).toMatchObject([
      { error: "不支持此文件类型", status: "failed" },
      { error: "文件超过 10 MB 上限", status: "failed" },
    ]);
    coordinator.close();
  });

  it("rejects another surface taking over a non-empty draft or attachments", async () => {
    const api = createApi();
    api.uploadGroupFile = vi.fn(async (_workspaceId, input) => ({
      name: input.name,
      path: "/private/renderer-owned.txt",
      size: input.data.size,
    }));
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_1", workspaceId: "wsp_1" };
    const lease = retainLease(coordinator, target, "renderer");
    coordinator.setDraft({
      ...lease,
      draft: "renderer draft",
      surfaceId: "renderer",
    });

    expect(() =>
      coordinator.setDraft({
        ...lease,
        draft: "side chat takeover",
        surfaceId: "side-chat",
      })
    ).toThrow("Chat draft belongs to another surface.");
    expect(() =>
      coordinator.attach({
        ...lease,
        bytes: new Uint8Array([1]),
        name: "takeover.txt",
        size: 1,
        surfaceId: "side-chat",
      })
    ).toThrow("Chat draft belongs to another surface.");
    expect(coordinator.state().sessions[0]).toMatchObject({
      draftOwnerSurfaceId: "renderer",
      state: { draft: "renderer draft", draftAttachments: [] },
    });

    coordinator.setDraft({ ...lease, draft: "", surfaceId: "renderer" });
    coordinator.attach({
      ...lease,
      bytes: new Uint8Array([1]),
      name: "renderer-owned.txt",
      size: 1,
      surfaceId: "renderer",
    });
    await vi.waitFor(() =>
      expect(coordinator.state().sessions[0]?.state.draftAttachments[0]).toMatchObject({
        status: "uploaded",
      })
    );
    expect(() =>
      coordinator.setDraft({
        ...lease,
        draft: "side chat takeover",
        surfaceId: "side-chat",
      })
    ).toThrow("Chat draft belongs to another surface.");
    expect(coordinator.state().sessions[0]).toMatchObject({
      draftOwnerSurfaceId: "renderer",
      state: {
        draft: "",
        draftAttachments: [expect.objectContaining({ name: "renderer-owned.txt" })],
      },
    });
    coordinator.close();
  });

  it("fences attachment intake after its exact retained lease is released", () => {
    const coordinator = new ChatCoordinator({ createApi });
    const target = { conversationId: "cnv_intake", workspaceId: "wsp_intake" };
    const lease = retainLease(coordinator, target, "renderer");
    const claim = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });

    expect(() => claim.assertCurrent()).not.toThrow();
    expect(coordinator.state().sessions[0]).toMatchObject({
      draftOwnerSurfaceId: "renderer",
    });

    coordinator.release(lease);

    expect(() => claim.assertCurrent()).toThrow(/stale chat lease/i);
    claim.releaseIfUnused();
    expect(coordinator.state().sessions[0]).not.toHaveProperty("draftOwnerSurfaceId");
    coordinator.close();
  });

  it("fences attachment intake after draft ownership moves to another surface", () => {
    const coordinator = new ChatCoordinator({ createApi });
    const target = { conversationId: "cnv_intake", workspaceId: "wsp_intake" };
    const rendererLease = retainLease(coordinator, target, "renderer");
    const sideChatLease = retainLease(coordinator, target, "side-chat");
    const claim = coordinator.claimAttachmentIntake({
      ...rendererLease,
      surfaceId: "renderer",
    });

    coordinator.setDraft({
      ...sideChatLease,
      draft: "",
      surfaceId: "side-chat",
    });

    expect(() => claim.assertCurrent()).toThrow(/another surface/i);
    claim.releaseIfUnused();
    expect(coordinator.state().sessions[0]).toMatchObject({
      draftOwnerSurfaceId: "side-chat",
    });
    coordinator.close();
  });

  it("releases only the empty draft owner created by a cancelled intake", () => {
    const coordinator = new ChatCoordinator({ createApi });
    const target = { conversationId: "cnv_intake", workspaceId: "wsp_intake" };
    const lease = retainLease(coordinator, target, "renderer");
    const created = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    created.releaseIfUnused();
    expect(coordinator.state().sessions[0]).not.toHaveProperty("draftOwnerSurfaceId");

    coordinator.setDraft({ ...lease, draft: "", surfaceId: "renderer" });
    const existing = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    existing.releaseIfUnused();
    expect(coordinator.state().sessions[0]).toMatchObject({
      draftOwnerSurfaceId: "renderer",
    });
    coordinator.close();
  });

  it("send fails fast and keeps the draft while the picker dialog is open", async () => {
    const coordinator = new ChatCoordinator({ createApi });
    const target = { conversationId: "cnv_intake", workspaceId: "wsp_intake" };
    const lease = retainLease(coordinator, target, "renderer");
    coordinator.setDraft({ ...lease, draft: "with files", surfaceId: "renderer" });
    const claim = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });

    await expect(
      coordinator.send(
        sendInput(coordinator, lease, { surfaceId: "renderer", text: "with files" })
      )
    ).rejects.toThrow(/still being selected/i);
    expect(coordinator.state().sessions[0]).toMatchObject({
      state: { draft: "with files", pending: [] },
    });

    claim.releaseIfUnused();
    coordinator.close();
  });

  it("send waits for a closed-dialog intake to settle so selected files are included", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_intake", workspaceId: "wsp_intake" };
    const lease = retainLease(coordinator, target, "renderer");
    const claim = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    claim.markDialogClosed();

    const send = coordinator.send(
      sendInput(coordinator, lease, {
        surfaceId: "renderer",
        text: "with settled files",
      })
    );
    let sendSettled = false;
    void send.finally(() => {
      sendSettled = true;
    });
    // The registration is still in flight; send must not compose yet.
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(sendSettled).toBe(false);
    expect(api.sendMessage).not.toHaveBeenCalled();

    coordinator.attachLocalFiles({
      ...lease,
      files: [
        {
          localFileRef: `lfi1_${"s".repeat(43)}`,
          mediaType: "text/plain",
          name: "settled.txt",
          size: 7,
        },
      ],
      surfaceId: "renderer",
    });
    claim.releaseIfUnused();

    await send;
    expect(api.sendMessage).toHaveBeenCalledWith(
      "grp_1",
      "cnv_intake",
      expect.objectContaining({
        localFiles: [
          expect.objectContaining({
            displayName: "settled.txt",
            localFileRef: `lfi1_${"s".repeat(43)}`,
          }),
        ],
        text: "with settled files",
      })
    );
    coordinator.close();
  });

  it("send rejects without committing when the intake settled with failures", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_intake", workspaceId: "wsp_intake" };
    const lease = retainLease(coordinator, target, "renderer");
    coordinator.setDraft({
      ...lease,
      draft: "with a broken file",
      surfaceId: "renderer",
    });
    const claim = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    claim.markDialogClosed();

    const send = coordinator.send(
      sendInput(coordinator, lease, {
        surfaceId: "renderer",
        text: "with a broken file",
      })
    );
    claim.settle({ cancelled: false, errorCount: 1 });
    claim.releaseIfUnused();

    await expect(send).rejects.toThrow(/could not be attached/i);
    expect(api.sendMessage).not.toHaveBeenCalled();
    expect(coordinator.state().sessions[0]).toMatchObject({
      state: { draft: "with a broken file", pending: [] },
    });
    coordinator.close();
  });

  it("rechecks terminal outcomes when a later intake fails during the send drain", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = {
      conversationId: "cnv_intake_drain_race",
      groupId: "grp_test",
      workspaceId: "wsp_intake_drain_race",
    };
    const lease = retainLease(coordinator, target, "renderer");
    const first = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    const second = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    first.markDialogClosed();
    second.markDialogClosed();

    const send = coordinator.send(
      sendInput(coordinator, lease, {
        surfaceId: "renderer",
        text: "must include both selections",
      })
    );
    // Main is awaiting the first claim. The second claim settles and removes
    // itself from the live Map before the iterator advances; its retained
    // terminal failure must still be rechecked before enqueue.
    second.settle({ cancelled: false, errorCount: 1 });
    second.releaseIfUnused();
    first.settle({ cancelled: false, errorCount: 0 });
    first.releaseIfUnused();

    await expect(send).rejects.toThrow(/could not be attached/i);
    expect(api.sendMessage).not.toHaveBeenCalled();
    coordinator.close();
  });

  it("send waits for an in-flight upload instead of silently skipping the enqueue", async () => {
    const api = createApi();
    let releaseUpload!: () => void;
    const uploadGate = new Promise<void>((resolve) => {
      releaseUpload = resolve;
    });
    (api as { uploadGroupFile?: unknown }).uploadGroupFile = vi.fn(
      async (_workspaceId: string, attrs: { name: string }) => {
        await uploadGate;
        return {
          name: attrs.name,
          path: `/uploads/${"u".repeat(22)}-${attrs.name}`,
          size: 3,
        };
      }
    );
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_upload", workspaceId: "wsp_upload" };
    const lease = retainLease(coordinator, target, "renderer");
    coordinator.attach({
      ...lease,
      bytes: new Uint8Array([1, 2, 3]),
      name: "photo.png",
      size: 3,
      surfaceId: "renderer",
    });

    const send = coordinator.send(
      sendInput(coordinator, lease, { surfaceId: "renderer", text: "with the photo" })
    );
    let sendSettled = false;
    void send.finally(() => {
      sendSettled = true;
    });
    await new Promise((resolve) => setTimeout(resolve, 25));
    // The old behavior let the channel silently skip this enqueue and still
    // report success; now the send is held until the upload settles.
    expect(sendSettled).toBe(false);
    expect(api.sendMessage).not.toHaveBeenCalled();

    releaseUpload();
    await send;
    expect(api.sendMessage).toHaveBeenCalledWith(
      "grp_1",
      "cnv_upload",
      expect.objectContaining({
        text: expect.stringContaining("photo.png"),
      })
    );
    coordinator.close();
  });

  it("a second send during an active drain rejects instead of duplicating", async () => {
    const coordinator = new ChatCoordinator({ createApi });
    const target = { conversationId: "cnv_intake", workspaceId: "wsp_intake" };
    const lease = retainLease(coordinator, target, "renderer");
    const claim = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    claim.markDialogClosed();

    const first = coordinator.send(
      sendInput(coordinator, lease, { surfaceId: "renderer", text: "queued once" })
    );
    expect(() =>
      sendInput(coordinator, lease, {
        surfaceId: "renderer",
        text: "queued once",
      })
    ).toThrow(/already in progress/i);

    claim.releaseIfUnused();
    await first;
    coordinator.close();
  });

  it("single-flights pure-text send intents before either commit starts", async () => {
    const coordinator = new ChatCoordinator({ createApi });
    const target = { conversationId: "cnv_text_send", workspaceId: "wsp_text_send" };
    const lease = retainLease(coordinator, target, "renderer");
    const first = sendInput(coordinator, lease, {
      surfaceId: "renderer",
      text: "only once",
    });

    expect(() =>
      sendInput(coordinator, lease, {
        surfaceId: "renderer",
        text: "duplicate click",
      })
    ).toThrow(/already in progress/i);
    await coordinator.send(first);
    coordinator.close();
  });

  it("releases a committed intent while its transport is pending so the successor draft can send and pick", async () => {
    const api = createApi();
    const firstTransport = deferred<CommaConversation>();
    vi.mocked(api.sendMessage).mockImplementationOnce(() => firstTransport.promise);
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = {
      conversationId: "cnv_successor_send",
      groupId: "grp_test",
      workspaceId: "wsp_successor_send",
    };
    const lease = retainLease(coordinator, target, "renderer");

    coordinator.setDraft({
      ...lease,
      draft: "message A",
      surfaceId: "renderer",
    });
    const firstInput = sendInput(coordinator, lease, {
      surfaceId: "renderer",
      text: "message A",
    });
    const firstSend = coordinator.send(firstInput);
    await vi.waitFor(() => expect(api.sendMessage).toHaveBeenCalledOnce());
    expect(coordinator.state().sessions[0]?.state).toMatchObject({
      draft: "",
      pending: [expect.objectContaining({ text: "message A" })],
    });
    await expect(coordinator.send(firstInput)).rejects.toThrow(/already sent/i);

    coordinator.setDraft({
      ...lease,
      draft: "message B",
      surfaceId: "renderer",
    });
    const successorIntake = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    successorIntake.markDialogClosed();
    successorIntake.releaseIfUnused();
    const secondSend = coordinator.send(
      sendInput(coordinator, lease, {
        surfaceId: "renderer",
        text: "message B",
      })
    );

    await vi.waitFor(() => expect(api.sendMessage).toHaveBeenCalledTimes(2));
    await secondSend;
    expect(coordinator.state().sessions[0]?.state.pending).toEqual(
      expect.arrayContaining([expect.objectContaining({ text: "message A" })])
    );

    // Session-lifetime replay history may accept arbitrarily many faster
    // successors while A is pending, but A's exact in-flight id must remain
    // unavailable for a fresh begin.
    for (let index = 0; index < 65; index += 1) {
      const text = `successor ${index}`;
      coordinator.setDraft({ ...lease, draft: text, surfaceId: "renderer" });
      await coordinator.send(
        sendInput(coordinator, lease, { surfaceId: "renderer", text })
      );
    }
    expect(() => coordinator.beginSendIntent(firstInput)).toThrow(/already sent/i);

    const firstAttrs = vi.mocked(api.sendMessage).mock.calls[0]![2];
    firstTransport.resolve({
      id: target.conversationId,
      kind: "user_chat",
      messages: [
        {
          ...canonicalMessage(
            firstAttrs.text,
            `msg_${firstAttrs.clientRequestId}`,
            "user"
          ),
          client_request_id: firstAttrs.clientRequestId,
          created_at: 1,
        },
      ],
      status: "active",
      title: "Chat",
      group_id: target.groupId,
    });
    await firstSend;

    // Completion moves A from the exact in-flight set into session-lifetime
    // committed history. Later completed sends cannot age it back into an
    // admissible id because the protocol has no bounded replay horizon.
    for (let index = 0; index < 65; index += 1) {
      const text = `post-settlement successor ${index}`;
      coordinator.setDraft({ ...lease, draft: text, surfaceId: "renderer" });
      await coordinator.send(
        sendInput(coordinator, lease, { surfaceId: "renderer", text })
      );
    }
    expect(() => coordinator.beginSendIntent(firstInput)).toThrow(/already sent/i);
    coordinator.close();
  });

  it("a draft edit during the drain invalidates the delayed send", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_intake", workspaceId: "wsp_intake" };
    const lease = retainLease(coordinator, target, "renderer");
    const claim = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    claim.markDialogClosed();

    const send = coordinator.send(
      sendInput(coordinator, lease, {
        surfaceId: "renderer",
        text: "the original text",
      })
    );
    coordinator.setDraft({
      ...lease,
      draft: "edited while settling",
      surfaceId: "renderer",
    });
    claim.releaseIfUnused();

    await expect(send).rejects.toThrow(/draft changed/i);
    expect(api.sendMessage).not.toHaveBeenCalled();
    expect(coordinator.state().sessions[0]).toMatchObject({
      state: { draft: "edited while settling" },
    });
    coordinator.close();
  });

  it("a stale draft epoch rejects the send before it can consume the newer draft", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_epoch", workspaceId: "wsp_epoch" };
    const lease = retainLease(coordinator, target, "renderer");
    const first = coordinator.setDraft({
      ...lease,
      draft: "the reviewed draft",
      surfaceId: "renderer",
    });
    expect(first.draftEpoch).toBeTypeOf("number");
    const input = sendInput(coordinator, lease, {
      surfaceId: "renderer",
      text: "the reviewed draft",
    });
    const second = coordinator.setDraft({
      ...lease,
      draft: "edited after the click",
      surfaceId: "renderer",
    });
    expect(second.draftEpoch).toBe(first.draftEpoch! + 1);

    await expect(coordinator.send(input)).rejects.toThrow(/draft changed/i);
    expect(api.sendMessage).not.toHaveBeenCalled();

    await coordinator.send(
      sendInput(coordinator, lease, {
        surfaceId: "renderer",
        text: "edited after the click",
      })
    );
    expect(api.sendMessage).toHaveBeenCalledOnce();
    coordinator.close();
  });

  it("a lost picker reply cannot yield a send that drops selected files", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_lost_reply", workspaceId: "wsp_lost_reply" };
    const lease = retainLease(coordinator, target, "renderer");

    // The picker settled with a failure but the IPC reply never reached the
    // renderer: no failure rows exist anywhere. Main retains the terminal
    // outcome on the entry, so every send keeps failing.
    const claim = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    claim.markDialogClosed();
    claim.settle({ cancelled: false, errorCount: 1 });
    claim.releaseIfUnused();

    for (let attempt = 0; attempt < 2; attempt += 1) {
      await expect(
        coordinator.send(
          sendInput(coordinator, lease, {
            surfaceId: "renderer",
            text: "text without the missing files",
          })
        )
      ).rejects.toThrow(/could not be attached/i);
    }
    expect(api.sendMessage).not.toHaveBeenCalled();

    // Delivery acknowledgement does not erase the failed draft attachment;
    // only the user's exact remove/retry decision resolves that gate.
    coordinator.acknowledgeIntakeFailures({
      ...lease,
      intakeId: claim.intakeId,
      surfaceId: "renderer",
    });
    coordinator.removeAttachment({
      ...lease,
      attachmentId: `chat-intake-failure:${claim.intakeId}:0`,
      surfaceId: "renderer",
    });
    await coordinator.send(
      sendInput(coordinator, lease, {
        surfaceId: "renderer",
        text: "acknowledged and reviewed",
      })
    );
    expect(api.sendMessage).toHaveBeenCalledOnce();
    coordinator.close();
  });

  it("binds acknowledgement to one intake so stale ack A cannot erase failed B", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_exact_ack", workspaceId: "wsp_exact_ack" };
    const lease = retainLease(coordinator, target, "renderer");

    const first = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    first.markDialogClosed();
    first.settle({ cancelled: false, errorCount: 1 });
    first.releaseIfUnused();
    coordinator.acknowledgeIntakeFailures({
      ...lease,
      intakeId: first.intakeId,
      surfaceId: "renderer",
    });

    const second = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    second.markDialogClosed();
    second.settle({ cancelled: false, errorCount: 1 });
    second.releaseIfUnused();

    // Delayed replay of A's delivery ack is idempotent for A only. It must
    // neither acknowledge nor resolve B's Main-owned failure gate.
    coordinator.acknowledgeIntakeFailures({
      ...lease,
      intakeId: first.intakeId,
      surfaceId: "renderer",
    });
    await expect(
      coordinator.send(
        sendInput(coordinator, lease, {
          surfaceId: "renderer",
          text: "must stay blocked by B",
        })
      )
    ).rejects.toThrow(/could not be attached/i);
    expect(api.sendMessage).not.toHaveBeenCalled();
    coordinator.close();
  });

  it("keeps a failed intake in Main across renderer loss and another surface", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = {
      conversationId: "cnv_intake_restart",
      groupId: "grp_test",
      workspaceId: "wsp_intake_restart",
    };
    const leaseA = retainLease(coordinator, target, "renderer-a");
    const failed = coordinator.claimAttachmentIntake({
      ...leaseA,
      surfaceId: "renderer-a",
    });
    failed.markDialogClosed();
    failed.settle({ cancelled: false, errorCount: 1 });
    failed.releaseIfUnused();
    coordinator.acknowledgeIntakeFailures({
      ...leaseA,
      intakeId: failed.intakeId,
      surfaceId: "renderer-a",
    });
    coordinator.release(leaseA);

    const leaseB = retainLease(coordinator, target, "renderer-b");
    expect(coordinator.state().sessions[0]?.state.draftAttachments).toEqual([
      expect.objectContaining({
        id: expect.stringContaining(failed.intakeId),
        status: "failed",
      }),
    ]);
    await expect(
      coordinator.send(
        sendInput(coordinator, leaseB, {
          surfaceId: "renderer-b",
          text: "must not bypass the lost renderer's selection",
        })
      )
    ).rejects.toThrow(/could not be attached/i);
    expect(api.sendMessage).not.toHaveBeenCalled();
    coordinator.close();
  });

  it("a new intake cannot supersede an unresolved failed selection", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_supersede", workspaceId: "wsp_supersede" };
    const lease = retainLease(coordinator, target, "renderer");

    const failed = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    failed.markDialogClosed();
    failed.settle({ cancelled: false, errorCount: 1 });
    failed.releaseIfUnused();

    // Reopening the picker cannot make the previous missing file disappear.
    const retried = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    retried.markDialogClosed();
    retried.releaseIfUnused();

    await expect(
      coordinator.send(
        sendInput(coordinator, lease, {
          surfaceId: "renderer",
          text: "still missing the first selection",
        })
      )
    ).rejects.toThrow(/could not be attached/i);
    coordinator.removeAttachment({
      ...lease,
      attachmentId: `chat-intake-failure:${failed.intakeId}:0`,
      surfaceId: "renderer",
    });
    await coordinator.send(
      sendInput(coordinator, lease, {
        surfaceId: "renderer",
        text: "failure explicitly removed",
      })
    );
    expect(api.sendMessage).toHaveBeenCalledOnce();
    coordinator.close();
  });

  it("a replayed send intent is refused instead of enqueuing a duplicate", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_replay", workspaceId: "wsp_replay" };
    const lease = retainLease(coordinator, target, "renderer");

    const input = sendInput(coordinator, lease, {
      surfaceId: "renderer",
      text: "sent exactly once",
    });
    await coordinator.send(input);
    expect(api.sendMessage).toHaveBeenCalledOnce();

    // A transport-level replay carries the same intent id; it must be
    // refused before any admission logic, never enqueue a second message.
    await expect(coordinator.send({ ...input })).rejects.toThrow(
      /already been sent|already sent/i
    );
    expect(api.sendMessage).toHaveBeenCalledOnce();
    coordinator.close();
  });

  it("a second claim on the same surface cannot displace the first intake's fence", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = {
      conversationId: "cnv_intake_same",
      groupId: "grp_test",
      workspaceId: "wsp_intake_same",
    };
    const lease = retainLease(coordinator, target, "renderer");

    // First picker call: dialog closed, registration still in flight.
    const first = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    first.markDialogClosed();

    // Second call from the SAME surface (Main cannot trust renderer-local
    // single-flight): cancelling it settles only its own claim.
    const second = coordinator.claimAttachmentIntake({
      ...lease,
      surfaceId: "renderer",
    });
    second.markDialogClosed();
    second.releaseIfUnused();

    const send = coordinator.send(
      sendInput(coordinator, lease, {
        surfaceId: "renderer",
        text: "still fenced by the first claim",
      })
    );
    let sendSettled = false;
    void send.finally(() => {
      sendSettled = true;
    });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(sendSettled).toBe(false);
    expect(api.sendMessage).not.toHaveBeenCalled();

    first.releaseIfUnused();
    await send;
    expect(api.sendMessage).toHaveBeenCalledOnce();
    coordinator.close();
  });

  it("seals picker intake admission once a send intent is reserved", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = {
      conversationId: "cnv_sealed_intent",
      groupId: "grp_test",
      workspaceId: "wsp_sealed_intent",
    };
    const lease = retainLease(coordinator, target, "renderer");
    const send = sendInput(coordinator, lease, {
      surfaceId: "renderer",
      text: "the click-time draft",
    });

    expect(() =>
      coordinator.claimAttachmentIntake({ ...lease, surfaceId: "renderer" })
    ).toThrow(/send is already in progress/i);
    await coordinator.send(send);
    expect(api.sendMessage).toHaveBeenCalledOnce();
    coordinator.close();
  });

  it("a second surface's cancelled picker cannot clear another surface's intake fence", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = {
      conversationId: "cnv_intake_multi",
      groupId: "grp_test",
      workspaceId: "wsp_intake_multi",
    };
    const leaseA = retainLease(coordinator, target, "surface-a");
    const leaseB = retainLease(coordinator, target, "surface-b");
    const claimA = coordinator.claimAttachmentIntake({
      ...leaseA,
      surfaceId: "surface-a",
    });
    claimA.markDialogClosed();

    // Surface B opens and cancels its own picker while A's registration is
    // still in flight. B settles only B's intake — A's fence must survive.
    const claimB = coordinator.claimAttachmentIntake({
      ...leaseB,
      surfaceId: "surface-b",
    });
    claimB.markDialogClosed();
    claimB.releaseIfUnused();

    const send = coordinator.send(
      sendInput(coordinator, leaseA, {
        surfaceId: "surface-a",
        text: "queued behind A's intake",
      })
    );
    let sendSettled = false;
    void send.finally(() => {
      sendSettled = true;
    });
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(sendSettled).toBe(false);
    expect(api.sendMessage).not.toHaveBeenCalled();

    claimA.releaseIfUnused();
    await send;
    expect(api.sendMessage).toHaveBeenCalledOnce();
    coordinator.close();
  });

  it("removing an attachment fences a send decided against the pre-removal draft", async () => {
    const api = createApi();
    const coordinator = new ChatCoordinator({ createApi: () => api });
    const target = { conversationId: "cnv_epoch2", workspaceId: "wsp_epoch2" };
    const lease = retainLease(coordinator, target, "renderer");
    const localFileRef = `lfi1_${"r".repeat(43)}`;
    coordinator.attachLocalFiles({
      ...lease,
      files: [
        {
          localFileRef,
          mediaType: "text/plain",
          name: "reviewed.txt",
          size: 3,
        },
      ],
      surfaceId: "renderer",
    });
    const reviewed = coordinator.setDraft({
      ...lease,
      draft: "send with the file",
      surfaceId: "renderer",
    });
    const send = sendInput(coordinator, lease, {
      surfaceId: "renderer",
      text: "send with the file",
    });

    // Removing content is an intent change: a send decided against the
    // draft-with-file must not silently commit the draft-without-file.
    const removal = coordinator.removeAttachment({
      ...lease,
      attachmentId: localFileRef,
      surfaceId: "renderer",
    });
    expect(removal.draftEpoch).toBe(reviewed.draftEpoch! + 1);

    await expect(coordinator.send(send)).rejects.toThrow(/draft changed/i);
    expect(api.sendMessage).not.toHaveBeenCalled();
    coordinator.close();
  });

  it("releases a session only after its last surface detaches", async () => {
    vi.useFakeTimers();
    const coordinator = new ChatCoordinator({ createApi, releaseDelayMs: 1 });
    const target = { conversationId: "cnv_1", workspaceId: "wsp_1" };
    const electronLease = retainLease(coordinator, target, "electron");
    const sideChatLease = retainLease(coordinator, target, "side-chat");
    coordinator.release(electronLease);
    await vi.advanceTimersByTimeAsync(2);
    expect(coordinator.state().sessions).toHaveLength(1);

    coordinator.release(sideChatLease);
    await vi.advanceTimersByTimeAsync(2);
    expect(coordinator.state().sessions).toEqual([]);
    vi.useRealTimers();
  });

  it("does not let an old exact lease release its same-subscriber replacement", () => {
    const coordinator = new ChatCoordinator({ createApi });
    const target = {
      conversationId: "cnv_shared",
      groupId: "grp_shared",
      workspaceId: "wsp_shared",
    };
    const leaseA = {
      ...target,
      leaseId: "00000000-0000-4000-8000-00000000000a",
      subscriberId: "win_main:wsp_shared/cnv_shared",
    };
    const leaseB = {
      ...target,
      leaseId: "00000000-0000-4000-8000-00000000000b",
      subscriberId: leaseA.subscriberId,
    };

    coordinator.retain(leaseA);
    coordinator.reset();
    coordinator.retain(leaseB);

    coordinator.release(leaseA);

    expect(coordinator.state().sessions).toEqual([
      expect.objectContaining({
        key: "grp_shared/cnv_shared",
        refs: 1,
        state: expect.objectContaining({ draft: "" }),
      }),
    ]);
    coordinator.close();
  });

  it("rejects an old exact lease command after the same subscriber is retained again", () => {
    const coordinator = new ChatCoordinator({ createApi });
    const target = {
      conversationId: "cnv_shared",
      groupId: "grp_shared",
      workspaceId: "wsp_shared",
    };
    const leaseA = {
      ...target,
      leaseId: "00000000-0000-4000-8000-00000000000a",
      subscriberId: "win_main:wsp_shared/cnv_shared",
    };
    const leaseB = {
      ...target,
      leaseId: "00000000-0000-4000-8000-00000000000b",
      subscriberId: leaseA.subscriberId,
    };

    coordinator.retain(leaseA);
    coordinator.reset();
    coordinator.retain(leaseB);

    expect(() =>
      coordinator.setDraft({
        ...leaseA,
        draft: "account A private draft",
        surfaceId: "win_main",
      })
    ).toThrow(/stale chat lease/i);
    expect(coordinator.state().sessions[0]).toMatchObject({
      refs: 1,
      state: { draft: "" },
    });

    coordinator.setDraft({
      ...leaseB,
      draft: "account B current draft",
      surfaceId: "win_main",
    });
    expect(coordinator.state().sessions[0]).toMatchObject({
      refs: 1,
      state: { draft: "account B current draft" },
    });
    coordinator.close();
  });

  it("does not cache a delayed skills result after its exact Session lease closes", async () => {
    const delayedSkills =
      deferred<Awaited<ReturnType<CommaApiClient["listWorkspaceSkills"]>>>();
    const apiA = {
      listWorkspaceSkills: vi.fn(() => delayedSkills.promise),
    } as Partial<CommaApiClient> as CommaApiClient;
    const apiB = {
      listWorkspaceSkills: vi.fn(async () => [
        {
          description: "B only",
          location: "skills/account-b/SKILL.md",
          name: "B",
          skill_id: "skill_b",
        },
      ]),
    } as Partial<CommaApiClient> as CommaApiClient;
    let currentA = true;
    let active = sessionBoundApi(apiA, 1, () => currentA);
    const coordinator = new ChatCoordinator({
      createSessionBoundApi: () => active,
    });

    const stale = coordinator.listSkills({ workspaceId: "wsp_shared" });
    await vi.waitFor(() => expect(apiA.listWorkspaceSkills).toHaveBeenCalledOnce());
    currentA = false;
    active = sessionBoundApi(apiB, 2, () => true);
    delayedSkills.resolve([
      {
        description: "A private",
        location: "skills/account-a/SKILL.md",
        name: "A",
        skill_id: "skill_a",
      },
    ]);

    await expect(stale).rejects.toThrow("Session generation 1 is stale.");
    await expect(
      coordinator.listSkills({ workspaceId: "wsp_shared" })
    ).resolves.toEqual([
      {
        description: "B only",
        location: "skills/account-b/SKILL.md",
        name: "B",
        skill_id: "skill_b",
      },
    ]);
    await coordinator.listSkills({ workspaceId: "wsp_shared" });
    expect(apiB.listWorkspaceSkills).toHaveBeenCalledOnce();
    coordinator.close();
  });

  it("does not let a delayed Workspace resolution overwrite the next exact Session", async () => {
    const delayedBootstrap = deferred<CommaWorkspaceBootstrap>();
    const apiA = {
      bootstrapWorkspace: vi.fn(() => delayedBootstrap.promise),
      ensureGroupChat: vi.fn(),
    } as Partial<CommaApiClient> as CommaApiClient;
    const apiB = {
      bootstrapWorkspace: vi.fn(async () => ({
        status: "ready" as const,
        workspace: {
          group_id: "grp_b",
          id: "wsp_b",
          name: "B",
          status: "ready" as const,
        },
      })),
      ensureGroupChat: vi.fn(async () => ({
        id: "cnv_b",
        kind: "user_chat" as const,
        messages: [],
        status: "open",
        title: "B Chat",
        group_id: "grp_b",
      })),
    } as Partial<CommaApiClient> as CommaApiClient;
    let currentA = true;
    let active = sessionBoundApi(apiA, 1, () => currentA);
    const coordinator = new ChatCoordinator({
      createSessionBoundApi: () => active,
    });

    const stale = coordinator.resolveWorkspaceChat();
    await vi.waitFor(() => expect(apiA.bootstrapWorkspace).toHaveBeenCalledOnce());
    currentA = false;
    active = sessionBoundApi(apiB, 2, () => true);
    await expect(coordinator.resolveWorkspaceChat()).resolves.toEqual({
      conversationId: "cnv_b",
      groupId: "grp_b",
      status: "ready",
      workspaceId: "wsp_b",
    });

    delayedBootstrap.resolve({
      status: "ready",
      workspace: { group_id: "grp_a", id: "wsp_a", name: "A", status: "ready" },
    });
    await expect(stale).rejects.toThrow("Session generation 1 is stale.");
    expect(apiA.ensureGroupChat).not.toHaveBeenCalled();
    await expect(coordinator.resolveWorkspaceChat()).resolves.toEqual({
      conversationId: "cnv_b",
      groupId: "grp_b",
      status: "ready",
      workspaceId: "wsp_b",
    });
    expect(apiB.ensureGroupChat).toHaveBeenCalledOnce();
    coordinator.close();
  });

  it("quarantines delayed send, upload, and SSE state from the signed-out generation", async () => {
    const delayedSend = deferred<CommaConversation>();
    const delayedUpload = deferred<{
      name: string;
      path: string;
      size: number;
    }>();
    let oldEvent:
      | Parameters<CommaApiClient["streamConversationEvents"]>[2]["onEvent"]
      | undefined;
    const accountAConversation: CommaConversation = {
      id: "cnv_shared",
      kind: "user_chat",
      messages: [],
      status: "active",
      title: "A",
      group_id: "grp_shared",
    };
    const apiA = {
      pollConversation: vi.fn(async () => ({
        conversation: accountAConversation,
        notModified: false,
      })),
      sendMessage: vi.fn(() => delayedSend.promise),
      streamConversationEvents: vi.fn(
        (_workspaceId, _conversationId, options) =>
          new Promise<void>((_resolve, reject) => {
            oldEvent = options.onEvent;
            options.signal?.addEventListener("abort", () => reject(abortError()), {
              once: true,
            });
          })
      ),
      uploadGroupFile: vi.fn(() => delayedUpload.promise),
    } as Partial<CommaApiClient> as CommaApiClient;
    const apiB = createApi();
    let currentA = true;
    let active = sessionBoundApi(apiA, 1, () => currentA);
    const coordinator = new ChatCoordinator({
      createSessionBoundApi: () => active,
    });
    const target = {
      conversationId: "cnv_shared",
      groupId: "grp_shared",
      workspaceId: "wsp_shared",
    };
    const leaseA = retainLease(coordinator, target, "win_main:shared");

    await vi.waitFor(() => expect(oldEvent).toBeTypeOf("function"));
    const staleSend = coordinator.send(
      sendInput(coordinator, leaseA, {
        surfaceId: "win_main",
        text: "account A private message",
      })
    );
    coordinator.attach({
      ...leaseA,
      bytes: new Uint8Array([1, 2, 3]),
      name: "account-a-private.txt",
      size: 3,
      surfaceId: "win_main",
    });
    await vi.waitFor(() => {
      expect(apiA.uploadGroupFile).toHaveBeenCalledOnce();
      expect(apiA.sendMessage).toHaveBeenCalledOnce();
    });

    currentA = false;
    expect(coordinator.state().sessions).toEqual([]);
    coordinator.reset();
    active = sessionBoundApi(apiB, 2, () => true);
    const leaseB = retainLease(coordinator, target, "win_main:shared");

    oldEvent?.(
      {
        type: "message_draft_started",
        conversation_id: "cnv_shared",
        draft_id: "draft_a",
        response_key: "rsp_a",
        source_message_ids: ["msg_a"],
        status: "started",
        text: "account A private draft",
      },
      "message_draft_started"
    );
    delayedUpload.resolve({
      name: "account-a-private.txt",
      path: "/uploads/account-a-private.txt",
      size: 3,
    });
    delayedSend.resolve({
      ...accountAConversation,
      messages: [
        {
          ...canonicalMessage("account A private message", "msg_a", "user"),
          client_request_id: "request-a",
          created_at: 1,
        },
      ],
    });

    await expect(staleSend).rejects.toThrow("Session generation 1 is stale.");
    await vi.waitFor(() =>
      expect(coordinator.state().sessions[0]).toMatchObject({
        conversationId: "cnv_shared",
        refs: 1,
        state: {
          draft: "",
          draftAttachments: [],
          messages: [],
          pending: [],
        },
      })
    );
    expect(coordinator.state().sessions[0]?.state.assistantDraft).toBeUndefined();
    coordinator.setDraft({
      ...leaseB,
      draft: "account B current draft",
      surfaceId: "win_main",
    });
    expect(coordinator.state().sessions[0]?.state.draft).toBe(
      "account B current draft"
    );
    coordinator.close();
  });

  it("does not create a generic conversation when Workspace Chat is unavailable", async () => {
    const api = {
      bootstrapWorkspace: vi.fn(async () => ({
        status: "ready" as const,
        workspace: {
          group_id: "grp_1",
          id: "wsp_1",
          name: "Workspace",
          status: "ready" as const,
        },
      })),
      ensureGroupChat: vi.fn(async () => {
        throw new CommaApiError(404, "not found");
      }),
    } as Partial<CommaApiClient> as CommaApiClient;
    const coordinator = new ChatCoordinator({ createApi: () => api });

    await expect(coordinator.resolveWorkspaceChat()).resolves.toEqual({
      status: "hidden",
    });

    expect(api.ensureGroupChat).toHaveBeenCalledWith("grp_1");
    coordinator.close();
  });

  it.each([
    { expectedStatus: "unauthorized", status: 401 },
    { expectedStatus: "hidden", status: 403 },
    { expectedStatus: "hidden", status: 404 },
  ] as const)(
    "classifies a $status workspace response as $expectedStatus",
    async ({ expectedStatus, status }) => {
      const api = {
        bootstrapWorkspace: vi.fn(async () => {
          throw new CommaApiError(status, "unauthorized");
        }),
      } as Partial<CommaApiClient> as CommaApiClient;
      const coordinator = new ChatCoordinator({ createApi: () => api });

      await expect(coordinator.resolveWorkspaceChat()).resolves.toEqual({
        status: expectedStatus,
      });
      coordinator.close();
    }
  );

  it("uses the server Workspace bootstrap before resolving chat", async () => {
    const api = {
      bootstrapWorkspace: vi.fn(async () => ({
        status: "ready" as const,
        workspace: {
          group_id: "grp_created",
          id: "wsp_created",
          name: "Default",
          status: "ready" as const,
        },
      })),
      ensureGroupChat: vi.fn(async () => ({
        created_at: 1_720_000_000,
        id: "cnv_chat",
        kind: "user_chat" as const,
        messages: [],
        status: "open",
        title: "Chat",
        group_id: "grp_created",
        updated_at: 1_720_000_003,
      })),
    } as Partial<CommaApiClient> as CommaApiClient;
    const coordinator = new ChatCoordinator({ createApi: () => api });

    await expect(coordinator.resolveWorkspaceChat()).resolves.toEqual({
      conversationId: "cnv_chat",
      createdAt: 1_720_000_000,
      groupId: "grp_created",
      status: "ready",
      updatedAt: 1_720_000_003,
      workspaceId: "wsp_created",
    });
    expect(api.bootstrapWorkspace).toHaveBeenCalledOnce();
    expect(api.ensureGroupChat).toHaveBeenCalledWith("grp_created");
    coordinator.close();
  });

  it("returns provisioning without entering Chat", async () => {
    const api = {
      bootstrapWorkspace: vi.fn(async () => ({
        retry_after_seconds: 2,
        status: "provisioning" as const,
        workspace: {
          group_id: "grp_reserved",
          id: "wsp_reserved",
          name: "Default",
          status: "provisioning" as const,
        },
      })),
      ensureGroupChat: vi.fn(),
    } as Partial<CommaApiClient> as CommaApiClient;
    const coordinator = new ChatCoordinator({ createApi: () => api });

    await expect(coordinator.resolveWorkspaceChat()).resolves.toEqual({
      groupId: "grp_reserved",
      retryAfterSeconds: 2,
      status: "provisioning",
      workspaceId: "wsp_reserved",
    });

    expect(api.ensureGroupChat).not.toHaveBeenCalled();
    coordinator.close();
  });

  it.each(["ready", "hidden", "error"] as const)(
    "rejects a stale %s Workspace Chat resolution without disturbing the current session",
    async (staleOutcome) => {
      const delayedA = deferred<CommaConversation>();
      const apiA = {
        bootstrapWorkspace: vi.fn(async () => ({
          status: "ready" as const,
          workspace: {
            group_id: "grp_a",
            id: "wsp_a",
            name: "A",
            status: "ready" as const,
          },
        })),
        ensureGroupChat: vi.fn(() => delayedA.promise),
      } as Partial<CommaApiClient> as CommaApiClient;
      const apiB = {
        bootstrapWorkspace: vi.fn(async () => ({
          status: "ready" as const,
          workspace: {
            group_id: "grp_b",
            id: "wsp_b",
            name: "B",
            status: "ready" as const,
          },
        })),
        ensureGroupChat: vi.fn(async () => ({
          id: "cnv_b",
          kind: "user_chat" as const,
          messages: [],
          status: "open",
          title: "B Chat",
          group_id: "grp_b",
        })),
      } as Partial<CommaApiClient> as CommaApiClient;
      let activeApi = apiA;
      const coordinator = new ChatCoordinator({ createApi: () => activeApi });

      const resolvingA = coordinator.resolveWorkspaceChat();
      await vi.waitFor(() => expect(apiA.ensureGroupChat).toHaveBeenCalled());
      coordinator.reset();
      activeApi = apiB;
      await expect(coordinator.resolveWorkspaceChat()).resolves.toEqual({
        conversationId: "cnv_b",
        groupId: "grp_b",
        status: "ready",
        workspaceId: "wsp_b",
      });

      const staleResolution = expect(resolvingA).rejects.toMatchObject({
        message: "Workspace Chat resolution was cancelled because the session changed.",
        name: "StaleChatSessionError",
      });
      if (staleOutcome === "ready") {
        delayedA.resolve({
          id: "cnv_a",
          kind: "user_chat",
          messages: [],
          status: "open",
          title: "A Chat",
          group_id: "grp_a",
        });
      } else {
        delayedA.reject(
          new CommaApiError(
            staleOutcome === "hidden" ? 403 : 500,
            staleOutcome === "hidden" ? "forbidden" : "unavailable"
          )
        );
      }
      await staleResolution;
      await expect(coordinator.resolveWorkspaceChat()).resolves.toMatchObject({
        conversationId: "cnv_b",
        groupId: "grp_b",
        workspaceId: "wsp_b",
      });
      expect(apiB.ensureGroupChat).toHaveBeenCalledTimes(1);
      coordinator.close();
    }
  );

  it("rejects a stale Workspace bootstrap after account switching", async () => {
    const delayedBootstrap = deferred<CommaWorkspaceBootstrap>();
    const apiA = {
      bootstrapWorkspace: vi.fn(() => delayedBootstrap.promise),
      ensureGroupChat: vi.fn(),
    } as Partial<CommaApiClient> as CommaApiClient;
    const apiB = {
      bootstrapWorkspace: vi.fn(async () => ({
        status: "ready" as const,
        workspace: {
          group_id: "grp_b",
          id: "wsp_b",
          name: "B",
          status: "ready" as const,
        },
      })),
      ensureGroupChat: vi.fn(async () => ({
        id: "cnv_b",
        kind: "user_chat" as const,
        messages: [],
        status: "open",
        title: "B Chat",
        group_id: "grp_b",
      })),
    } as Partial<CommaApiClient> as CommaApiClient;
    let activeApi = apiA;
    const coordinator = new ChatCoordinator({ createApi: () => activeApi });

    const resolvingA = coordinator.resolveWorkspaceChat();
    await vi.waitFor(() => expect(apiA.bootstrapWorkspace).toHaveBeenCalledOnce());
    coordinator.reset();
    activeApi = apiB;

    await expect(coordinator.resolveWorkspaceChat()).resolves.toMatchObject({
      conversationId: "cnv_b",
      groupId: "grp_b",
      status: "ready",
      workspaceId: "wsp_b",
    });

    delayedBootstrap.resolve({
      status: "ready",
      workspace: { group_id: "grp_a", id: "wsp_a", name: "A", status: "ready" },
    });
    await expect(resolvingA).rejects.toMatchObject({ name: "StaleChatSessionError" });
    expect(apiA.ensureGroupChat).not.toHaveBeenCalled();
    expect(apiB.ensureGroupChat).toHaveBeenCalledWith("grp_b");
    coordinator.close();
  });

  it("rejects a stale 401 from the previous account without disturbing the current Workspace", async () => {
    const delayedBootstrap = deferred<CommaWorkspaceBootstrap>();
    const apiA = {
      bootstrapWorkspace: vi.fn(() => delayedBootstrap.promise),
      ensureGroupChat: vi.fn(),
    } as Partial<CommaApiClient> as CommaApiClient;
    const apiB = {
      bootstrapWorkspace: vi.fn(async () => ({
        status: "ready" as const,
        workspace: {
          group_id: "grp_b",
          id: "wsp_b",
          name: "B",
          status: "ready" as const,
        },
      })),
      ensureGroupChat: vi.fn(async () => ({
        id: "cnv_b",
        kind: "user_chat" as const,
        messages: [],
        status: "open",
        title: "B Chat",
        group_id: "grp_b",
      })),
    } as Partial<CommaApiClient> as CommaApiClient;
    let activeApi = apiA;
    const coordinator = new ChatCoordinator({ createApi: () => activeApi });

    const resolvingA = coordinator.resolveWorkspaceChat();
    await vi.waitFor(() => expect(apiA.bootstrapWorkspace).toHaveBeenCalledOnce());
    coordinator.reset();
    activeApi = apiB;

    await expect(coordinator.resolveWorkspaceChat()).resolves.toEqual({
      conversationId: "cnv_b",
      groupId: "grp_b",
      status: "ready",
      workspaceId: "wsp_b",
    });

    delayedBootstrap.reject(new CommaApiError(401, "unauthorized"));
    await expect(resolvingA).rejects.toMatchObject({ name: "StaleChatSessionError" });
    await expect(coordinator.resolveWorkspaceChat()).resolves.toEqual({
      conversationId: "cnv_b",
      groupId: "grp_b",
      status: "ready",
      workspaceId: "wsp_b",
    });
    expect(apiA.ensureGroupChat).not.toHaveBeenCalled();
    expect(apiB.ensureGroupChat).toHaveBeenCalledTimes(1);
    coordinator.close();
  });
});

let leaseSequence = 0;

let sendIntentSequence = 0;

/**
 * Builds a valid send input with a fresh intent id. Tests that exercise the
 * stale-intent or replay fences reserve or reuse their own sendIntentId
 * explicitly; Main owns the draft epoch bound to each reservation.
 */
function sendInput(
  coordinator: ChatCoordinator,
  lease: {
    conversationId: string;
    groupId: string;
    workspaceId: string;
    leaseId: string;
    subscriberId: string;
  },
  fields: {
    consumeDraft?: boolean;
    sendIntentId?: string;
    surfaceId: string;
    text: string;
  }
) {
  const sendIntentId = fields.sendIntentId ?? `test-intent-${++sendIntentSequence}`;
  const input = {
    ...lease,
    ...fields,
    sendIntentId,
  };
  coordinator.beginSendIntent(input);
  return input;
}

function retainLease(
  coordinator: ChatCoordinator,
  target: { conversationId: string; groupId?: string; workspaceId: string },
  subscriberId: string
) {
  const lease = {
    ...target,
    groupId: target.groupId ?? "grp_1",
    leaseId: `00000000-0000-4000-8000-${(++leaseSequence)
      .toString(16)
      .padStart(12, "0")}`,
    subscriberId,
  };
  coordinator.retain(lease);
  return lease;
}

function surfaceState(coordinator: ChatCoordinator, subscriberId: string) {
  return coordinator
    .state()
    .sessions[0]?.surfaceProjections?.find(
      (projection) => projection.subscriberId === subscriberId
    )?.state;
}

function streamingApi(
  onListener: (
    listener: Parameters<CommaApiClient["streamConversationEvents"]>[2]["onEvent"]
  ) => void
) {
  return {
    pollConversation: vi.fn(async (groupId) => ({
      conversation: {
        id: "cnv_1",
        kind: "user_chat" as const,
        messages: [],
        status: "active",
        title: "Chat",
        group_id: groupId,
      },
      notModified: false,
    })),
    streamConversationEvents: vi.fn(
      (_workspaceId, _conversationId, opts) =>
        new Promise<void>((_resolve, reject) => {
          onListener(opts.onEvent);
          opts.signal?.addEventListener("abort", () => reject(abortError()), {
            once: true,
          });
        })
    ),
  } as Partial<CommaApiClient> as CommaApiClient;
}

function createApi() {
  const conversation: CommaConversation = {
    id: "cnv_1",
    kind: "user_chat",
    messages: [],
    status: "active",
    title: "Chat",
    group_id: "grp_1",
  };
  return {
    pollConversation: vi.fn(async (groupId, conversationId) => ({
      conversation: {
        ...conversation,
        id: conversationId,
        group_id: groupId,
      },
      notModified: false,
    })),
    streamConversationEvents: vi.fn(
      (_workspaceId, _conversationId, opts) =>
        new Promise<void>((_resolve, reject) => {
          opts.signal?.addEventListener("abort", () => reject(abortError()), {
            once: true,
          });
        })
    ),
    sendMessage: vi.fn(async (groupId, conversationId, attrs) => ({
      ...conversation,
      group_id: groupId,
      id: conversationId,
      messages: [
        {
          ...canonicalMessage(attrs.text, `msg_${attrs.clientRequestId}`, "user"),
          client_request_id: attrs.clientRequestId,
          created_at: 1,
        },
      ],
    })),
  } as Partial<CommaApiClient> as CommaApiClient;
}

function canonicalMessage(
  text: string,
  messageId: string,
  actorType: "user" | "agent" | "system",
  metadata?: SalixMessage["metadata"]
): SalixMessage {
  return {
    actor_type: actorType,
    content: [{ text, type: "text" }],
    kind: "message",
    message_id: messageId,
    ...(metadata ? { metadata } : {}),
  };
}

function sessionBoundApi(
  api: CommaApiClient,
  generation: number,
  isCurrent: () => boolean
): MainSessionBoundApi {
  return {
    api,
    assertCurrent() {
      if (!isCurrent()) {
        throw new Error(`Session generation ${generation} is stale.`);
      }
    },
    isCurrent,
    session: {
      audience: "https://api.comma.example",
      authorityInstanceId: "authority-1",
      generation,
      sessionId: `session-${generation}`,
    },
  };
}

function abortError() {
  const error = new Error("Aborted");
  error.name = "AbortError";
  return error;
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
