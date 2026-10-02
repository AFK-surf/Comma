import { createServer, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { emptyRoutineEnvelope } from "../helpers/routine-fixture";
import {
  createE2eSessionProjection,
  clearBrowserSessionFixtures,
  readBrowserSessionFixture,
  reflectedCorsRequestHeaders,
} from "../helpers/session-fixture";

export const chatSmokeWorkspace = {
  group_id: "grp-smoke",
  id: "ws-smoke",
  name: "Smoke Workspace",
};
export const chatSmokeWorkspaceChat = {
  id: "cnv_public_chat_smoke",
  status: "active",
  title: "聊天",
  kind: "user_chat",
  group_id: chatSmokeWorkspace.group_id,
  created_at: 1_720_000_000,
  updated_at: 1_720_000_000,
};
export const chatSmokeTaskConversation = {
  id: "cnv_public_task_smoke",
  status: "completed",
  title: "冒烟任务",
  kind: "agent_task",
  schedule: {
    schedule_id: "sch1_1720000002000000000",
    command: "Create the weekday workspace summary",
  },
  group_id: chatSmokeWorkspace.group_id,
  created_at: 1_720_000_002,
  updated_at: 1_720_000_003,
};
export const chatSmokeAssistantReply = "收到，stub 已生成回复。";
export type ChatSmokeAdditionalTaskRef = {
  browserLink: {
    label: string;
    url: string;
  };
  id: string;
  title: string;
};
export const chatSmokeSkill = {
  skill_id: "weekly-summary",
  name: "周会总结",
  description: "整理会议要点和后续事项",
  location: "salix://skills/weekly-summary",
};

export type TaskParticipantFixture = {
  actor_id?: string;
  actor_role?: "router" | "worker";
  issue?: string;
  participant_id: string;
  name: string;
  state: "active" | "stopped" | "error";
  status: string;
  updated_at: number;
};

export type ChatSmokeAttachment = {
  fileName: string;
  mimeType: string;
  path?: string;
  size: number;
  type: "file" | "image";
};

export type ChatSmokeStreamingFailure = {
  activity?: "public-tool";
  issue?: string;
  status?: string;
};

/** A Channel whose inbound message started the Router's current work. */
export type ChatSmokeWorkingProvider = "wechat" | "telegram" | "signal";

export async function startChatSmokeStub({
  additionalInboxConversations = [],
  conversationList,
  additionalWorkspaces = [],
  additionalTaskRefs = [],
  assistantAttachments = [],
  agentImage,
  attachmentFiles = {},
  assistantDraft,
  assistantReply = chatSmokeAssistantReply,
  extraInlineTasks = [],
  followupAssistantReply,
  holdAssistantReply = false,
  holdCompletedWorkspaceChatEventStream = false,
  holdStreamingReplyStart = false,
  externalActivityProvider,
  holdWorkspaceChatMessage = false,
  keepThinkingAfterReply = false,
  includeTaskInInbox = false,
  taskInboxSummaryOnly = false,
  includeWorkspaceChatInInboxList = false,
  inlineTaskBoundaryCases = false,
  inlineTaskReference = false,
  laterChatTurns = 0,
  priorAssistantReply,
  workspaceTranscript,
  priorUserMessage,
  sessionEmail = "smoke@comma.local",
  sessionHistory,
  sessionHistoryEvents,
  port: listenPort = 0,
  streamAssistantReply = false,
  archiveLatencyMs = 0,
  taskAcceptConflictOnce = false,
  unarchiveAfterArchiveMs,
  taskAssistantMessages,
  taskPreparationUnavailable = false,
  taskPreparationDelayMs = 0,
  taskAssistantReply,
  taskConversationExtras = {},
  taskTranscript,
  taskReviewVersion = 2,
  taskSchedule = chatSmokeTaskConversation.schedule,
  taskStatus = chatSmokeTaskConversation.status,
  taskDetailStatus,
  waitForInitialInboxListBeforeWorkspaceChat = false,
  workspaceChatDelayMs = 0,
  workspaceChatFirstResolutionDelayMs = workspaceChatDelayMs,
  workspaceChatMessageError,
  beforeWorkspaceChat,
  beforeWorkspaceChatDetail,
}: {
  /**
   * Extra conversations served in the Group conversation list. The product
   * inbox loads inside a SharedWorker on web, where Playwright page routes
   * cannot reach — task fixtures must come from this stub itself.
   */
  sessionHistory?: (url: URL) => { status?: number; body: unknown };
  sessionHistoryEvents?: (url: URL, response: ServerResponse) => void;
  port?: number;
  additionalInboxConversations?: readonly Record<string, unknown>[];
  conversationList?: (url: URL) => { status?: number; body: unknown };
  additionalWorkspaces?: readonly (typeof chatSmokeWorkspace)[];
  additionalTaskRefs?: readonly ChatSmokeAdditionalTaskRef[];
  assistantAttachments?: readonly ChatSmokeAttachment[];
  agentImage?: {
    agentId: string;
    bytes: Buffer;
    contentType: string;
    byUuid?: Record<string, Buffer>;
  };
  attachmentFiles?: Record<string, { bytes: Buffer; contentType: string }>;
  assistantDraft?: string;
  assistantReply?: string;
  /**
   * How long the stub takes to accept an archive. The Task keeps its pre-archive
   * fact for that window, so a client that hides it sooner did so on its own.
   */
  archiveLatencyMs?: number;
  /**
   * Another client puts the Task back this many ms after the archive lands, so
   * the archive response a waiting client finally receives is already stale.
   */
  unarchiveAfterArchiveMs?: number;
  /**
   * Extra Tasks known to the stub: each adds one committed assistant message
   * announcing an inline Task (own conversation id, title, and status
   * snapshot) and one entry in the group's conversation list, so the Tasks
   * also surface through the Inbox/sidebar projection.
   */
  extraInlineTasks?: readonly { id: string; status: string; title: string }[];
  followupAssistantReply?: string;
  holdAssistantReply?: boolean;
  holdCompletedWorkspaceChatEventStream?: boolean;
  /** Hold the first reply's live activity and draft behind a test-controlled gate. */
  holdStreamingReplyStart?: boolean;
  externalActivityProvider?: ChatSmokeWorkingProvider;
  /** Delay the first send's HTTP acknowledgment without delaying local UI feedback. */
  holdWorkspaceChatMessage?: boolean;
  /**
   * Keep the Agent working after its reply commits: the reconnected event
   * stream reports `thinking`, an active Participant, and a draft that keeps
   * growing. That is the live-run shape a reader meets when they reveal an
   * announcing turn from the Tasks panel.
   */
  keepThinkingAfterReply?: boolean;
  includeTaskInInbox?: boolean;
  /** Match the production list projection, which does not carry transcript bodies. */
  taskInboxSummaryOnly?: boolean;
  /** Opt-in escape hatch; the canonical unscoped Comma list is Task-only. */
  includeWorkspaceChatInInboxList?: boolean;
  inlineTaskBoundaryCases?: boolean;
  inlineTaskReference?: boolean;
  /** Synthetic user/assistant turns after the primary stub reply. */
  laterChatTurns?: number;
  priorAssistantReply?: string;
  workspaceTranscript?: readonly {
    actor_type: string;
    agent_id?: string;
    kind: string;
    message_id: string;
    created_at: number;
    agent_input?: Record<string, unknown>;
    metadata?: Record<string, unknown>;
    platform_message?: {
      provider: string;
      role: "user" | "assistant";
      content: { type: "text"; text: string }[];
    };
    content: (
      | { type: "text"; text: string }
      | { type: "mail_reference"; source_key: string }
      | {
          type: "file";
          file_name: string;
          mime_type: string;
          blob_ref: { uuid: string; hash: string; size: number };
        }
    )[];
  }[];
  priorUserMessage?: string;
  sessionEmail?: string;
  streamAssistantReply?: boolean;
  taskAcceptConflictOnce?: boolean;
  taskAssistantMessages?: readonly string[];
  taskPreparationUnavailable?: boolean;
  taskPreparationDelayMs?: number;
  taskAssistantReply?: string | undefined;
  /** Extra fields served on the Task conversation (origin, client_platform, …). */
  taskConversationExtras?: Record<string, unknown>;
  /** Raw canonical wire messages, including system and workflow authors. */
  taskTranscript?: readonly Record<string, unknown>[];
  taskReviewVersion?: number;
  taskSchedule?: typeof chatSmokeTaskConversation.schedule | null;
  taskStatus?: string;
  /** Override only detail reads to model a snapshot lagging behind the task list. */
  taskDetailStatus?: string;
  waitForInitialInboxListBeforeWorkspaceChat?: boolean;
  workspaceChatDelayMs?: number;
  /** Keep initial setup fast while later resolutions retain their test delay. */
  workspaceChatFirstResolutionDelayMs?: number;
  /** Reject a workspace Chat send before accepting its message. */
  workspaceChatMessageError?: { error: string; status: number };
  /** Real HTTP gates also cover requests made by the shared host. */
  beforeWorkspaceChat?: () => Promise<void>;
  beforeWorkspaceChatDetail?: () => Promise<void>;
} = {}) {
  const additionalTaskById = new Map(
    additionalTaskRefs.map((task, index) => [task.id, { index, task }])
  );
  const authCookies: (string | undefined)[] = [];
  const authHeaders: (string | undefined)[] = [];
  const chatMessageBodies: unknown[] = [];
  const messageBodies: unknown[] = [];
  const uploads: {
    auth: string | undefined;
    filename: string;
    path: string;
    bytes: Buffer;
    contentType: string;
  }[] = [];
  const failedOnce = new Set<string>();
  let workspaceChatCreated = false;
  let workspaceChatRequestCount = 0;
  const workspaceChatResponseStatuses: number[] = [];
  const workspaceChatDetailResponseStatuses: number[] = [];
  let userText = "";
  let followupUserText = "";
  let followupClientRequestId = "";
  let taskUserText = "";
  let taskClientRequestId = "";
  let taskParticipants: TaskParticipantFixture[] = [];
  let boundWorker: Pick<
    TaskParticipantFixture,
    "participant_id" | "actor_id" | "name"
  > | null = null;
  const taskStatusStreams = new Set<ServerResponse>();
  const thinkingTimers = new Set<ReturnType<typeof setInterval>>();
  let clientRequestId = "";
  let conversationListRequestCount = 0;
  let failNextConversationListRead = false;
  let failedConversationListReadObserved = Promise.resolve();
  let notifyFailedConversationListRead: (() => void) | undefined;
  let activeCompletedWorkspaceChatEventStreams = 0;
  let completedWorkspaceChatEventStreamRequestCount = 0;
  let delayedTaskDetail:
    | { body: ReturnType<typeof taskConversation>; response: ServerResponseLike }
    | undefined;
  let delayedTaskDetailObserved = Promise.resolve();
  let holdNextTaskDetail = false;
  let delayedTaskSummary: { body: unknown; response: ServerResponseLike } | undefined;
  let delayedTaskSummaryObserved = Promise.resolve();
  let holdNextTaskSummary = false;
  let messageSkillLocations: string[] = [];
  let thinkingReplies = 0;
  let notifyThinkingCommit: (() => void) | undefined;
  let assistantCommitted = !streamAssistantReply && !holdAssistantReply;
  let streamingReplyStarted = false;
  let streamingReplyResponse: ServerResponse | undefined;
  let streamingActivitySequence = 0;
  let streamingDraftRevision = 0;
  let streamingReconnectCount = 0;
  let workspaceChatEventsUnreachable = false;
  let droppedWorkspaceChatEventStreamCount = 0;
  const heldCompletedWorkspaceChatEventStreams = new Set<ServerResponse>();
  let participantSnapshotAvailable = true;
  let releaseWorkspaceChatMessage: (() => void) | undefined;
  let notifyWorkspaceChatMessage: (() => void) | undefined;
  let releaseStreamingReplyStart: (() => void) | undefined;
  let notifyStreamingReplyReady: (() => void) | undefined;
  let notifyInitialChatSnapshot: (() => void) | undefined;
  const workspaceChatMessageRelease = new Promise<void>((resolve) => {
    releaseWorkspaceChatMessage = resolve;
  });
  const workspaceChatMessageObserved = new Promise<void>((resolve) => {
    notifyWorkspaceChatMessage = resolve;
  });
  const streamingReplyStartRelease = new Promise<void>((resolve) => {
    releaseStreamingReplyStart = resolve;
  });
  const streamingReplyReady = new Promise<void>((resolve) => {
    notifyStreamingReplyReady = resolve;
  });
  const initialChatSnapshot = new Promise<void>((resolve) => {
    notifyInitialChatSnapshot = resolve;
  });
  let participantState: "active" | "error" | "stopped" = externalActivityProvider
    ? "active"
    : "stopped";
  let participantStatus = externalActivityProvider ? "is thinking..." : "";
  let workingProvider = externalActivityProvider;
  let participantIssue: string | undefined;
  let participantUpdatedAt = 1;
  // A turn that never commits an assistant message. The exact failure cause is
  // configurable so the browser test can verify that Activity presentation
  // never overrides the canonical Participant issue.
  let streamingReplyFailure: ChatSmokeStreamingFailure | undefined;
  let resolveDraftEmitted: (() => void) | undefined;
  let releaseStreamingReply: (() => void) | undefined;
  const draftEmitted = new Promise<void>((resolve) => {
    resolveDraftEmitted = resolve;
  });
  const streamingReplyRelease = new Promise<void>((resolve) => {
    releaseStreamingReply = resolve;
  });
  let draftText = assistantDraft ?? assistantReply.slice(0, -1);
  let notifyDelayedTaskDetail: (() => void) | undefined;
  let notifyDelayedTaskSummary: (() => void) | undefined;
  let taskAcceptRequestCount = 0;
  let taskDetailRequestCount = 0;
  let taskPreparationRequestCount = 0;
  let taskListRevision = 0;
  let taskListEventStreamRequestCount = 0;
  const taskListEventStreams = new Set<ServerResponse>();
  let currentTaskReviewVersion = taskReviewVersion;
  let currentTaskStatus = taskStatus;
  let currentTaskTitle = chatSmokeTaskConversation.title;
  let currentTaskLabels: string[] | undefined;
  let currentTaskUpdatedAt = chatSmokeTaskConversation.updated_at;
  let currentTaskAssistantMessages = taskAssistantMessages;
  let archivedFromStatus: string | undefined;
  let archivedAt: number | undefined;
  let workspaceChatHidden = false;
  let notifyInitialInboxList: (() => void) | undefined;
  const initialInboxListObserved = new Promise<void>((resolve) => {
    notifyInitialInboxList = resolve;
  });

  const server = createServer(async (req, res) => {
    authCookies.push(req.headers.cookie);
    authHeaders.push(req.headers.authorization);
    const requestOrigin = req.headers.origin;
    if (requestOrigin) {
      res.setHeader("access-control-allow-origin", requestOrigin);
      res.setHeader("access-control-allow-credentials", "true");
      res.setHeader("vary", "origin");
    }
    res.setHeader(
      "access-control-allow-headers",
      reflectedCorsRequestHeaders(
        req.headers["access-control-request-headers"],
        "authorization,content-type,accept,if-none-match,x-comma-session-transport"
      )
    );
    res.setHeader("access-control-allow-methods", "DELETE,GET,OPTIONS,PATCH,POST,PUT");
    res.setHeader("access-control-expose-headers", "etag");
    if (req.method === "OPTIONS") {
      res.writeHead(204).end();
      return;
    }

    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    if (sessionHistory && url.pathname.endsWith("/history/events")) {
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-store",
      });
      res.write(": connected\n\n");
      sessionHistoryEvents?.(url, res);
      return;
    }
    if (sessionHistory && url.pathname.endsWith("/history")) {
      const response = sessionHistory(url);
      res.writeHead(response.status ?? 200, { "content-type": "application/json" });
      res.end(JSON.stringify(response.body));
      return;
    }
    const path = url.pathname;
    const conversationPathPrefix = `/v1/comma/groups/${chatSmokeWorkspace.group_id}/conversations/`;
    const additionalTaskPath = path.startsWith(conversationPathPrefix)
      ? path.slice(conversationPathPrefix.length).split("/")
      : [];
    const additionalTaskEntry =
      additionalTaskPath.length > 0 && additionalTaskPath.length <= 2
        ? additionalTaskById.get(additionalTaskPath[0] ?? "")
        : undefined;
    const additionalTaskOperation = additionalTaskPath[1];
    if (req.method === "GET" && path === "/v1/comma/auth/session") {
      const projection = readBrowserSessionFixture(
        `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
        req.headers.cookie
      );
      if (projection === null) {
        writeJson(res, { error: "unauthorized" }, 401);
        return;
      }
      writeJson(res, projection ?? createE2eSessionProjection({ email: sessionEmail }));
      return;
    }

    if (req.method === "POST" && path === "/v1/comma/me/bootstrap") {
      writeJson(res, { status: "ready", workspace: chatSmokeWorkspace });
      return;
    }

    if (req.method === "GET" && path === "/v1/comma/workspaces") {
      writeJson(res, { data: [chatSmokeWorkspace, ...additionalWorkspaces] });
      return;
    }

    if (
      req.method === "GET" &&
      /^\/v1\/comma\/workspaces\/[^/]+\/recommendations$/.test(path)
    ) {
      writeJson(res, emptyRoutineEnvelope);
      return;
    }

    if (
      req.method === "GET" &&
      path === `/v1/comma/workspaces/${chatSmokeWorkspace.id}/skills`
    ) {
      writeJson(res, {
        data: [
          chatSmokeSkill,
          {
            skill_id: "code-review",
            name: "代码审查",
            description: "检查实现风险和测试缺口",
            location: "salix://skills/code-review",
          },
        ],
      });
      return;
    }

    if (
      req.method === "GET" &&
      path === `/v1/comma/groups/${chatSmokeWorkspace.group_id}/task-summaries`
    ) {
      const ids = new Set((url.searchParams.get("ids") ?? "").split(","));
      const body = {
        data: [
          taskConversation(),
          ...extraInlineTasks.map((task) => ({
            ...task,
            group_id: chatSmokeWorkspace.group_id,
            kind: "agent_task",
            updated_at: 1_720_000_011,
          })),
        ].filter((task) => ids.has(task.id)),
      };
      if (holdNextTaskSummary) {
        holdNextTaskSummary = false;
        delayedTaskSummary = { body, response: res };
        notifyDelayedTaskSummary?.();
        return;
      }
      writeJson(res, body);
      return;
    }
    if (
      req.method === "POST" &&
      ["archive", "unarchive"].some(
        (action) =>
          path === `${conversationPathPrefix}${chatSmokeTaskConversation.id}/${action}`
      )
    ) {
      const body = (await readJson(req)) as { expected_updated_at?: number };
      const archive = path.endsWith("/archive");
      if (
        (archive && currentTaskStatus === "archived") ||
        (!archive && currentTaskStatus !== "archived")
      ) {
        writeJson(res, taskConversation());
        return;
      }
      if (
        body.expected_updated_at !== currentTaskUpdatedAt ||
        (archive && (currentTaskStatus === "active" || taskSchedule !== null))
      ) {
        writeJson(res, { error: "Task changed or cannot be archived" }, 409);
        return;
      }
      if (archive) {
        if (archiveLatencyMs > 0) {
          await new Promise((resolve) => setTimeout(resolve, archiveLatencyMs));
        }
        archivedFromStatus = currentTaskStatus;
        archivedAt = Date.now();
        currentTaskStatus = "archived";
        if (unarchiveAfterArchiveMs !== undefined) {
          await new Promise((resolve) => setTimeout(resolve, unarchiveAfterArchiveMs));
          currentTaskStatus = archivedFromStatus!;
          archivedFromStatus = undefined;
          archivedAt = undefined;
        }
      } else {
        currentTaskStatus = archivedFromStatus!;
        archivedFromStatus = undefined;
        archivedAt = undefined;
      }
      currentTaskUpdatedAt = Math.max(currentTaskUpdatedAt + 1, Date.now());
      writeJson(res, taskConversation());
      broadcastTaskListInvalidation();
      return;
    }

    if (
      req.method === "GET" &&
      path === `/v1/comma/groups/${chatSmokeWorkspace.group_id}/conversations`
    ) {
      conversationListRequestCount += 1;
      notifyInitialInboxList?.();
      notifyInitialInboxList = undefined;
      if (failNextConversationListRead) {
        failNextConversationListRead = false;
        writeJson(res, { error: "temporary_unavailable" }, 503);
        notifyFailedConversationListRead?.();
        notifyFailedConversationListRead = undefined;
        return;
      }
      if (conversationList) {
        const page = conversationList(url);
        writeJson(res, page.body, page.status ?? 200);
        return;
      }
      if (workspaceChatCreated && workspaceChatDelayMs > 0) {
        await new Promise((resolve) => setTimeout(resolve, workspaceChatDelayMs));
      }
      writeJson(res, {
        data: [
          ...(workspaceChatCreated && includeWorkspaceChatInInboxList
            ? [workspaceChat()]
            : []),
          ...(userText || includeTaskInInbox
            ? [
                taskInboxSummaryOnly
                  ? { ...taskConversation(), messages: undefined }
                  : taskConversation(),
              ]
            : []),
          ...(userText || includeTaskInInbox
            ? extraInlineTasks.map((task, index) => ({
                created_at: 1_720_000_010 + index * 2,
                group_id: chatSmokeWorkspace.group_id,
                id: task.id,
                kind: "agent_task",
                messages: [],
                status: task.status,
                title: task.title,
                updated_at: 1_720_000_011 + index * 2,
              }))
            : []),
          ...additionalInboxConversations,
        ].filter((task) => {
          const mode = url.searchParams.get("archive") ?? "exclude";
          return (
            mode === "include" || (task.status === "archived") === (mode === "only")
          );
        }),
        has_more: false,
      });
      return;
    }

    if (
      req.method === "PATCH" &&
      path ===
        `/v1/comma/groups/${chatSmokeWorkspace.group_id}/conversations/${chatSmokeTaskConversation.id}`
    ) {
      const body = (await readJson(req)) as { title?: string; labels?: string[] };
      currentTaskTitle = body.title?.trim() || currentTaskTitle;
      if (body.labels) currentTaskLabels = [...body.labels];
      writeJson(res, taskConversation());
      return;
    }

    if (
      req.method === "GET" &&
      path === `/v1/comma/groups/${chatSmokeWorkspace.group_id}/conversations/events`
    ) {
      taskListEventStreamRequestCount += 1;
      taskListEventStreams.add(res);
      res.once("close", () => taskListEventStreams.delete(res));
      res.writeHead(200, {
        "cache-control": "no-cache",
        connection: "keep-alive",
        "content-type": "text/event-stream",
      });
      res.write(taskListInvalidationFrame());
      if (url.searchParams.get("conversation_id") === chatSmokeTaskConversation.id) {
        taskStatusStreams.add(res);
        res.once("close", () => taskStatusStreams.delete(res));
        res.write(taskParticipantFrame());
      }
      return;
    }

    const attachment = /\/messages\/([^/]+)\/attachments\/(\d+)$/.exec(path);
    const attachmentFile =
      attachment && attachmentFiles[`${attachment[1]}:${attachment[2]}`];
    if (req.method === "GET" && attachmentFile) {
      res.writeHead(200, { "content-type": attachmentFile.contentType });
      res.end(attachmentFile.bytes);
      return;
    }

    if (
      agentImage &&
      req.method === "POST" &&
      path ===
        `/v1/comma/groups/${chatSmokeWorkspace.group_id}/agents/${agentImage.agentId}/resources`
    ) {
      res.writeHead(200, { "content-type": agentImage.contentType });
      const request = JSON.parse((await readBuffer(req)).toString()) as {
        ref?: { uuid?: string };
      };
      res.end(agentImage.byUuid?.[request.ref?.uuid ?? ""] ?? agentImage.bytes);
      return;
    }

    const uploadedFile =
      req.method === "GET" &&
      path === `/v1/comma/groups/${chatSmokeWorkspace.group_id}/files`
        ? uploads.find((upload) => upload.path === url.searchParams.get("path"))
        : undefined;
    if (uploadedFile) {
      // GroupFiles.read_image derives its response type from the uploaded path.
      const imageTypes: Record<string, string> = {
        png: "image/png",
        jpg: "image/jpeg",
        jpeg: "image/jpeg",
        gif: "image/gif",
        webp: "image/webp",
      };
      const responseType =
        imageTypes[uploadedFile.filename.split(".").at(-1)?.toLowerCase() ?? ""] ??
        uploadedFile.contentType;
      res.writeHead(200, { "content-type": responseType });
      res.end(uploadedFile.bytes);
      return;
    }

    if (
      req.method === "GET" &&
      path === `/v1/comma/groups/${chatSmokeWorkspace.group_id}/files` &&
      url.searchParams.get("path") === "/uploads/AAAAAAAAAAAAAAAAAAAAAA-diagram.png"
    ) {
      res.writeHead(200, { "content-type": "image/png" });
      res.end(
        Buffer.from(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
          "base64"
        )
      );
      return;
    }

    if (
      req.method === "POST" &&
      path === `/v1/comma/groups/${chatSmokeWorkspace.group_id}/assistant-chat`
    ) {
      const resolutionRequestNumber = ++workspaceChatRequestCount;
      await beforeWorkspaceChat?.();
      if (waitForInitialInboxListBeforeWorkspaceChat) {
        await initialInboxListObserved;
      }
      const resolutionDelayMs =
        resolutionRequestNumber === 1
          ? workspaceChatFirstResolutionDelayMs
          : workspaceChatDelayMs;
      if (resolutionDelayMs > 0) {
        await new Promise((resolve) => setTimeout(resolve, resolutionDelayMs));
      }
      if (workspaceChatHidden) {
        writeJson(res, { error: "workspace_chat_hidden" }, 403);
        workspaceChatResponseStatuses.push(403);
        return;
      }
      workspaceChatCreated = true;
      writeJson(res, workspaceChat());
      workspaceChatResponseStatuses.push(200);
      return;
    }

    if (
      req.method === "GET" &&
      path ===
        `/v1/comma/groups/${chatSmokeWorkspace.group_id}/conversations/${chatSmokeWorkspaceChat.id}`
    ) {
      await beforeWorkspaceChatDetail?.();
      if (workspaceChatCreated) {
        writeJson(res, workspaceChat());
      } else {
        writeJson(res, { error: "not_found" }, 404);
      }
      workspaceChatDetailResponseStatuses.push(workspaceChatCreated ? 200 : 404);
      return;
    }

    if (
      req.method === "GET" &&
      path ===
        `/v1/comma/groups/${chatSmokeWorkspace.group_id}/conversations/${chatSmokeTaskConversation.id}`
    ) {
      if (url.searchParams.has("message_limit")) {
        taskPreparationRequestCount += 1;
        if (taskPreparationDelayMs > 0)
          await new Promise((resolve) => setTimeout(resolve, taskPreparationDelayMs));
        if (taskPreparationUnavailable) {
          writeJson(res, { error: "unavailable" }, 503);
        } else {
          const detail = taskConversation();
          writeJson(res, {
            ...detail,
            messages: detail.messages.slice(
              -Number(url.searchParams.get("message_limit"))
            ),
          });
        }
        return;
      }
      taskDetailRequestCount += 1;
      const detail = {
        ...taskConversation(),
        ...(taskDetailStatus === undefined ? {} : { status: taskDetailStatus }),
      };
      res.setHeader("etag", `"task-smoke-v${currentTaskReviewVersion}"`);
      if (holdNextTaskDetail) {
        holdNextTaskDetail = false;
        delayedTaskDetail = { body: detail, response: res };
        notifyDelayedTaskDetail?.();
        return;
      }
      writeJson(res, detail);
      return;
    }

    if (
      req.method === "GET" &&
      path ===
        `/v1/comma/groups/${chatSmokeWorkspace.group_id}/conversations/${chatSmokeTaskConversation.id}/preview`
    ) {
      writeJson(res, taskPreview());
      return;
    }

    if (req.method === "GET" && additionalTaskEntry) {
      const { index, task } = additionalTaskEntry;
      if (additionalTaskOperation === undefined) {
        res.setHeader("etag", `"task-${task.id}-v1"`);
        writeJson(res, additionalTaskConversation(task, index));
        return;
      }
      if (additionalTaskOperation === "messages") {
        res.setHeader("etag", `"task-${task.id}-messages-v1"`);
        writeJson(res, { data: additionalTaskMessages(task, index) });
        return;
      }
      if (additionalTaskOperation === "events") {
        writeJson(
          res,
          {
            code: "unsupported_for_kind",
            kind: "agent_task",
            operation: "events",
          },
          409
        );
        return;
      }
    }

    if (
      req.method === "POST" &&
      path === `/v1/comma/groups/${chatSmokeWorkspace.group_id}/files`
    ) {
      const contentType = req.headers["content-type"] ?? "";
      if (!String(contentType).startsWith("multipart/form-data")) {
        writeJson(res, { error: "expected multipart" }, 415);
        return;
      }

      const body = await readBuffer(req);
      const form = await new Response(new Uint8Array(body), {
        headers: { "content-type": String(contentType) },
      }).formData();
      const file = form.get("file");
      if (!file || typeof file === "string") {
        writeJson(res, { error: "expected file" }, 400);
        return;
      }
      const filename = file.name;
      const bytes = Buffer.from(await file.arrayBuffer());
      const uploadId = Buffer.alloc(16);
      uploadId.writeUInt32BE(uploads.length + 1, 12);
      if (filename.includes("fail-once") && !failedOnce.has(filename)) {
        failedOnce.add(filename);
        writeJson(res, { error: "file_too_large" }, 413);
        return;
      }

      const upload = {
        auth: req.headers.authorization,
        filename,
        path: `/uploads/${uploadId.toString("base64url")}-${filename}`,
        bytes,
        contentType: file.type || "application/octet-stream",
      };
      uploads.push(upload);
      writeJson(
        res,
        { path: upload.path, name: filename, size: bytes.byteLength },
        201
      );
      return;
    }

    if (
      req.method === "GET" &&
      path ===
        `/v1/comma/groups/${chatSmokeWorkspace.group_id}/conversations/${chatSmokeWorkspaceChat.id}/messages`
    ) {
      writeJson(res, { data: messages() });
      return;
    }

    if (
      req.method === "GET" &&
      path ===
        `/v1/comma/groups/${chatSmokeWorkspace.group_id}/conversations/${chatSmokeTaskConversation.id}/messages`
    ) {
      res.setHeader("etag", '"task-smoke-v1"');
      writeJson(res, { data: taskMessages() });
      return;
    }

    if (
      req.method === "POST" &&
      path ===
        `/v1/comma/groups/${chatSmokeWorkspace.group_id}/conversations/${chatSmokeWorkspaceChat.id}/messages`
    ) {
      const body = (await readJson(req)) as {
        client_request_id?: string;
        message?: { text?: string };
        skills?: { location?: string }[];
      };
      const nextUserText = body.message?.text ?? "";
      if (nextUserText.startsWith("Comma Center")) {
        chatMessageBodies.push(body);
      } else {
        messageBodies.push(body);
      }
      notifyWorkspaceChatMessage?.();
      if (holdWorkspaceChatMessage) await workspaceChatMessageRelease;
      if (workspaceChatMessageError) {
        writeJson(
          res,
          { error: workspaceChatMessageError.error },
          workspaceChatMessageError.status
        );
        return;
      }
      if (laterChatTurns > 0 && userText) {
        followupUserText = nextUserText;
        followupClientRequestId = body.client_request_id ?? "req-smoke-followup";
      } else {
        userText = nextUserText;
        clientRequestId = body.client_request_id ?? "req-smoke";
      }
      messageSkillLocations =
        body.skills
          ?.map((skill) => skill.location)
          .filter((location): location is string => typeof location === "string") ?? [];
      writeJson(res, {
        ...workspaceChat(),
        status: "active",
        messages: messages(),
      });
      broadcastTaskListInvalidation();
      return;
    }

    if (
      req.method === "POST" &&
      path ===
        `/v1/comma/groups/${chatSmokeWorkspace.group_id}/conversations/${chatSmokeTaskConversation.id}/messages`
    ) {
      const body = (await readJson(req)) as {
        message?: { text?: string };
        client_request_id?: string;
      };
      taskUserText = body.message?.text ?? "";
      taskClientRequestId = body.client_request_id ?? "task-request";
      writeJson(res, taskConversation());
      broadcastTaskListInvalidation();
      return;
    }

    if (
      req.method === "POST" &&
      path ===
        `/v1/comma/groups/${chatSmokeWorkspace.group_id}/conversations/${chatSmokeTaskConversation.id}/accept`
    ) {
      const body = (await readJson(req)) as { review_version?: number };
      taskAcceptRequestCount += 1;
      if (taskAcceptConflictOnce && taskAcceptRequestCount === 1) {
        currentTaskReviewVersion += 1;
        writeJson(res, { error: "conflict" }, 409);
        return;
      }
      if (body.review_version !== currentTaskReviewVersion) {
        writeJson(res, { error: "conflict" }, 409);
        return;
      }
      currentTaskStatus = "completed";
      writeJson(res, taskConversation());
      broadcastTaskListInvalidation();
      return;
    }

    if (
      req.method === "GET" &&
      path.startsWith(
        `/v1/comma/groups/${chatSmokeWorkspace.group_id}/conversations/${chatSmokeWorkspaceChat.id}/events`
      )
    ) {
      if (workspaceChatEventsUnreachable) {
        // A dropped connection, as when a laptop wakes before Wi-Fi rejoins.
        droppedWorkspaceChatEventStreamCount += 1;
        req.socket.destroy();
        return;
      }
      const snapshot = {
        activity_status: workspaceChatActivityStatus(),
        conversation_id: chatSmokeWorkspaceChat.id,
        messages: messages(),
        status: "active",
        stream: { drafts: true, window_ms: 30_000 },
        type: "snapshot",
        group_id: chatSmokeWorkspace.group_id,
        participant_draft: null,
      };
      if (!userText) notifyInitialChatSnapshot?.();

      if (externalActivityProvider) {
        streamingReplyResponse = res;
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write(sseFrame("snapshot", snapshot));
        res.write(participantStatusFrame());
        return;
      }

      if (
        streamAssistantReply &&
        userText &&
        !assistantCommitted &&
        !streamingReplyStarted
      ) {
        streamingReplyStarted = true;
        streamingReplyResponse = res;
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write(sseFrame("snapshot", snapshot));
        if (holdStreamingReplyStart) {
          res.write(participantStatusFrame());
          notifyStreamingReplyReady?.();
          await streamingReplyStartRelease;
        }
        if (res.destroyed) return;
        participantState = "active";
        participantStatus = "is thinking...";
        participantUpdatedAt += 1;
        res.write(participantStatusFrame());
        res.write(
          sseFrame("message_draft_started", {
            conversation_id: chatSmokeWorkspaceChat.id,
            draft_id: "draft-smoke-stream",
            response_key: "response-smoke-stream",
            revision: streamingDraftRevision,
            source_message_ids: ["msg-user-smoke"],
            status: "started",
            text: draftText,
            type: "message_draft_started",
          })
        );
        notifyStreamingReplyReady?.();
        resolveDraftEmitted?.();

        await streamingReplyRelease;

        // A reconnect replaces only the transport; completion belongs to the
        // same fixture response and must reach its currently open stream.
        res = streamingReplyResponse ?? res;

        if (streamingReplyFailure) {
          participantState = "error";
          participantStatus =
            streamingReplyFailure.status ?? "error: the model could not be reached";
          participantIssue = streamingReplyFailure.issue ?? "model_connection_failed";
          participantUpdatedAt += 1;
          if (!res.destroyed) {
            if (streamingReplyFailure.activity === "public-tool") {
              res.write(
                sseFrame("activity", {
                  action: "Running a command",
                  conversation_id: chatSmokeWorkspaceChat.id,
                  display_hold_ms: 5_000,
                  display_priority: "work",
                  display_strength: "strong",
                  phase: "execution",
                  producer_epoch: "epoch-chat-smoke",
                  response_key: "response-smoke-stream",
                  sequence: 1,
                  source_message_ids: ["msg-user-smoke"],
                  status: "failed",
                  summary: "Running a command",
                  summary_class: "public",
                  tool_name: "env.exec",
                  type: "activity",
                  updated_at: participantUpdatedAt,
                })
              );
            }
            res.write(participantStatusFrame());
            if (streamingReplyFailure.activity === "public-tool") {
              // Keep both exact frames resident long enough to assert their
              // precedence. Production streams can remain open after a
              // terminal Activity event as well.
              return;
            }
            res.end(
              sseFrame("conversation_invalidated", {
                conversation_id: chatSmokeWorkspaceChat.id,
                type: "conversation_invalidated",
              })
            );
          }
          return;
        }

        assistantCommitted = true;
        participantState = "stopped";
        participantStatus = "";
        participantUpdatedAt += 1;
        if (!res.destroyed) {
          res.write(
            sseFrame("message_draft_delta", {
              conversation_id: chatSmokeWorkspaceChat.id,
              draft_id: "draft-smoke-stream",
              response_key: "response-smoke-stream",
              revision: ++streamingDraftRevision,
              source_message_ids: ["msg-user-smoke"],
              status: "delta",
              text: assistantReply,
              type: "message_draft_delta",
            })
          );
          res.write(participantStatusFrame());
          res.end(
            sseFrame("conversation_invalidated", {
              conversation_id: chatSmokeWorkspaceChat.id,
              type: "conversation_invalidated",
            })
          );
        }
        return;
      }

      if (streamAssistantReply && streamingReplyStarted && !assistantCommitted) {
        streamingReplyResponse = res;
        streamingReconnectCount += 1;
        const draft = {
          conversation_id: chatSmokeWorkspaceChat.id,
          draft_id: "draft-smoke-stream",
          response_key: "response-smoke-stream",
          revision: streamingDraftRevision,
          source_message_ids: ["msg-user-smoke"],
          text: draftText,
        };
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write(
          sseFrame("snapshot", {
            ...snapshot,
            participant_draft: participantSnapshotAvailable ? draft : undefined,
          })
        );
        if (!participantSnapshotAvailable) return;
        // Real HTTP chunks may arrive in different paints. The first frame
        // must already preserve the draft before later Participant events.
        await new Promise((resolve) => setTimeout(resolve, 100));
        if (!res.destroyed) {
          res.write(participantStatusFrame());
          res.write(
            sseFrame("message_draft_started", {
              ...draft,
              type: "message_draft_started",
              status: "started",
            })
          );
        }
        return;
      }

      if (keepThinkingAfterReply && assistantCommitted) {
        participantState = "active";
        participantStatus = "is thinking...";
        participantUpdatedAt += 1;
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write(sseFrame("snapshot", { ...snapshot, activity_status: "thinking" }));
        res.write(participantStatusFrame());
        res.write(
          sseFrame("message_draft_started", {
            conversation_id: chatSmokeWorkspaceChat.id,
            draft_id: "draft-smoke-thinking",
            response_key: "response-smoke-thinking",
            source_message_ids: ["msg-user-smoke"],
            status: "started",
            text: "",
            type: "message_draft_started",
          })
        );
        notifyThinkingCommit = () => {
          notifyThinkingCommit = undefined;
          thinkingReplies += 1;
          if (res.destroyed) return;
          res.write(participantStatusFrame());
          res.end(
            sseFrame("conversation_invalidated", {
              conversation_id: chatSmokeWorkspaceChat.id,
              type: "conversation_invalidated",
            })
          );
        };
        let thinkingText = "";
        const thinkingTimer = setInterval(() => {
          if (res.destroyed) return;
          thinkingText += "正在整理这一步的结果。";
          res.write(
            sseFrame("message_draft_delta", {
              conversation_id: chatSmokeWorkspaceChat.id,
              draft_id: "draft-smoke-thinking",
              response_key: "response-smoke-thinking",
              source_message_ids: ["msg-user-smoke"],
              status: "delta",
              text: thinkingText,
              type: "message_draft_delta",
            })
          );
        }, 140);
        thinkingTimers.add(thinkingTimer);
        res.once("close", () => {
          clearInterval(thinkingTimer);
          thinkingTimers.delete(thinkingTimer);
        });
        return;
      }

      if (holdCompletedWorkspaceChatEventStream && assistantCommitted) {
        completedWorkspaceChatEventStreamRequestCount += 1;
        activeCompletedWorkspaceChatEventStreams += 1;
        heldCompletedWorkspaceChatEventStreams.add(res);
        let released = false;
        res.once("close", () => {
          heldCompletedWorkspaceChatEventStreams.delete(res);
          if (released) return;
          released = true;
          activeCompletedWorkspaceChatEventStreams -= 1;
        });
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write(sseFrame("snapshot", snapshot));
        res.write(participantStatusFrame());
        return;
      }

      writeConversationSse(res, snapshot);
      return;
    }

    if (
      req.method === "GET" &&
      path.startsWith(
        `/v1/comma/groups/${chatSmokeWorkspace.group_id}/conversations/${chatSmokeTaskConversation.id}/events`
      )
    ) {
      writeJson(
        res,
        {
          code: "unsupported_for_kind",
          kind: "agent_task",
          operation: "events",
        },
        409
      );
      return;
    }

    writeJson(res, { error: `unhandled ${req.method} ${path}` }, 404);
  });

  return new Promise<{
    activeTaskListEventStreams: number;
    authCookies: (string | undefined)[];
    activeCompletedWorkspaceChatEventStreams: number;
    chatMessageBodies: unknown[];
    authHeaders: (string | undefined)[];
    baseUrl: string;
    close: () => Promise<void>;
    completeStreamingReply: () => void;
    appendPriorAssistantReply: (text: string) => void;
    reconnectStreamingReply: () => void;
    droppedWorkspaceChatEventStreamCount: number;
    setWorkspaceChatEventsUnreachable: (unreachable: boolean) => void;
    setParticipantSnapshotAvailable: (available: boolean) => void;
    streamingReconnectCount: number;
    commitThinkingReply: () => void;
    failStreamingReply: (failure?: ChatSmokeStreamingFailure) => void;
    completedWorkspaceChatEventStreamRequestCount: number;
    conversationListRequestCount: number;
    workspaceChatRequestCount: number;
    workspaceChatResponseStatuses: readonly number[];
    workspaceChatDetailResponseStatuses: readonly number[];
    failNextConversationListRead: () => void;
    holdNextTaskDetail: () => void;
    holdNextTaskSummary: () => void;
    messageBodies: unknown[];
    publishStreamingActivity: (phase: "thinking" | "messaging") => void;
    publishStreamingParticipantStatus: (
      status: string,
      provider?: ChatSmokeWorkingProvider,
      state?: "active" | "stopped" | "error",
      issue?: string
    ) => void;
    publishTaskReviewUpdate: (input: {
      assistantMessages: readonly string[];
      title: string;
      updatedAt: number;
    }) => void;
    releaseDelayedTaskDetail: () => void;
    releaseDelayedTaskSummary: () => void;
    releaseWorkspaceChatMessage: () => void;
    startStreamingReply: () => void;
    updateStreamingDraft: (text: string) => void;
    taskAcceptRequestCount: number;
    taskDetailRequestCount: number;
    taskPreparationRequestCount: number;
    taskListEventStreamRequestCount: number;
    uploads: {
      auth: string | undefined;
      filename: string;
      path: string;
      bytes: Buffer;
      contentType: string;
    }[];
    /**
     * The account a bearer session (the Electron app) signs in as. A browser
     * session registered for its own cookie can belong to another one.
     */
    userId: string;
    setTaskParticipants: (
      participants: TaskParticipantFixture[],
      worker?: Pick<
        TaskParticipantFixture,
        "participant_id" | "actor_id" | "name"
      > | null
    ) => void;
    disconnectTaskStatusStreams: () => void;
    setWorkspaceChatHidden: (hidden: boolean) => void;
    waitForDraft: () => Promise<void>;
    waitForInitialChatSnapshot: () => Promise<void>;
    waitForStreamingReplyReady: () => Promise<void>;
    waitForWorkspaceChatMessage: () => Promise<void>;
    waitForFailedConversationListRead: () => Promise<void>;
    waitForDelayedTaskDetail: () => Promise<void>;
    waitForDelayedTaskSummary: () => Promise<void>;
  }>((resolve) => {
    server.listen(listenPort, "127.0.0.1", () => {
      const { port } = server.address() as AddressInfo;
      resolve({
        get activeTaskListEventStreams() {
          return taskListEventStreams.size;
        },
        authCookies,
        get activeCompletedWorkspaceChatEventStreams() {
          return activeCompletedWorkspaceChatEventStreams;
        },
        chatMessageBodies,
        authHeaders,
        baseUrl: `http://127.0.0.1:${port}`,
        reconnectStreamingReply: () => {
          if (!streamingReplyResponse || streamingReplyResponse.destroyed)
            throw new Error("No streaming reply to reconnect");
          streamingReplyResponse.end();
        },
        get droppedWorkspaceChatEventStreamCount() {
          return droppedWorkspaceChatEventStreamCount;
        },
        setWorkspaceChatEventsUnreachable: (unreachable) => {
          workspaceChatEventsUnreachable = unreachable;
          if (!unreachable) return;
          for (const stream of heldCompletedWorkspaceChatEventStreams) {
            droppedWorkspaceChatEventStreamCount += 1;
            stream.destroy();
          }
        },
        setParticipantSnapshotAvailable: (available) => {
          participantSnapshotAvailable = available;
        },
        get streamingReconnectCount() {
          return streamingReconnectCount;
        },
        close: () =>
          new Promise<void>((done) => {
            clearBrowserSessionFixtures(`http://127.0.0.1:${port}`);
            releaseStreamingReply?.();
            releaseStreamingReplyStart?.();
            releaseWorkspaceChatMessage?.();
            for (const timer of thinkingTimers) clearInterval(timer);
            thinkingTimers.clear();
            for (const stream of taskListEventStreams) {
              if (!stream.destroyed) stream.end();
            }
            taskListEventStreams.clear();
            const httpServer = server as Server;
            httpServer.close(() => done());
            httpServer.closeAllConnections();
          }),
        completeStreamingReply: () => releaseStreamingReply?.(),
        // One earlier request may commit while the independent Participant
        // already exposes the current request's draft. Keep that draft alive.
        appendPriorAssistantReply: (text) => {
          if (
            !priorUserMessage ||
            priorAssistantReply !== undefined ||
            !streamingReplyResponse ||
            streamingReplyResponse.destroyed
          ) {
            throw new Error("No unresolved prior reply beside a live draft");
          }
          priorAssistantReply = text;
          streamingReplyResponse.end(
            sseFrame("conversation_invalidated", {
              conversation_id: chatSmokeWorkspaceChat.id,
              type: "conversation_invalidated",
            })
          );
        },
        /** Commit the keepThinkingAfterReply draft as one more Agent message. */
        commitThinkingReply: () => notifyThinkingCommit?.(),
        failStreamingReply: (failure = {}) => {
          streamingReplyFailure = failure;
          releaseStreamingReply?.();
        },
        get completedWorkspaceChatEventStreamRequestCount() {
          return completedWorkspaceChatEventStreamRequestCount;
        },
        get conversationListRequestCount() {
          return conversationListRequestCount;
        },
        get workspaceChatRequestCount() {
          return workspaceChatRequestCount;
        },
        workspaceChatResponseStatuses,
        workspaceChatDetailResponseStatuses,
        failNextConversationListRead: () => {
          if (failNextConversationListRead) {
            throw new Error("A failed conversation list read is already armed.");
          }
          failNextConversationListRead = true;
          failedConversationListReadObserved = new Promise<void>((observed) => {
            notifyFailedConversationListRead = observed;
          });
        },
        holdNextTaskDetail: () => {
          if (delayedTaskDetail) {
            throw new Error("A delayed Task detail response is already pending.");
          }
          holdNextTaskDetail = true;
          delayedTaskDetailObserved = new Promise<void>((resolveDelayed) => {
            notifyDelayedTaskDetail = resolveDelayed;
          });
        },
        holdNextTaskSummary: () => {
          if (delayedTaskSummary || holdNextTaskSummary) {
            throw new Error("A delayed Task summary response is already pending.");
          }
          holdNextTaskSummary = true;
          delayedTaskSummaryObserved = new Promise<void>((resolveDelayed) => {
            notifyDelayedTaskSummary = resolveDelayed;
          });
        },
        messageBodies,
        publishStreamingActivity: (phase) => {
          writeStreamingFrame("activity", {
            action: phase === "messaging" ? "Typing" : "Thinking",
            phase,
            producer_epoch: "epoch-chat-smoke",
            sequence: ++streamingActivitySequence,
            status: "running",
            summary: phase === "messaging" ? "Typing" : "Thinking",
            summary_class: "generic",
          });
        },
        publishStreamingParticipantStatus: (
          status,
          provider,
          state = "active",
          issue
        ) => {
          workingProvider = provider;
          participantState = state;
          participantStatus = status;
          participantIssue = issue;
          participantUpdatedAt += 1;
          if (!streamingReplyResponse || streamingReplyResponse.destroyed) {
            throw new Error("The streaming reply is not connected.");
          }
          streamingReplyResponse.write(participantStatusFrame());
        },
        publishTaskReviewUpdate: ({ assistantMessages, title, updatedAt }) => {
          if (!Number.isFinite(updatedAt) || updatedAt <= currentTaskUpdatedAt) {
            throw new Error("A Task review update must advance updatedAt.");
          }
          currentTaskAssistantMessages = assistantMessages;
          currentTaskReviewVersion += 1;
          currentTaskStatus = "ready_for_review";
          currentTaskTitle = title;
          currentTaskUpdatedAt = updatedAt;
          broadcastTaskListInvalidation();
        },
        setTaskParticipants: (participants, worker) => {
          taskParticipants = participants;
          const identity =
            worker === undefined
              ? participants.find((p) => p.actor_role === "worker")
              : worker;
          boundWorker = identity
            ? {
                participant_id: identity.participant_id,
                ...(identity.actor_id ? { actor_id: identity.actor_id } : {}),
                name: identity.name,
              }
            : null;
          for (const stream of taskStatusStreams) {
            if (!stream.destroyed) stream.write(taskParticipantFrame());
          }
        },
        disconnectTaskStatusStreams: () => {
          for (const stream of taskStatusStreams) stream.end();
          taskStatusStreams.clear();
        },
        releaseDelayedTaskDetail: () => {
          const delayed = delayedTaskDetail;
          if (!delayed) {
            throw new Error("No delayed Task detail response is pending.");
          }
          delayedTaskDetail = undefined;
          notifyDelayedTaskDetail = undefined;
          writeJson(delayed.response, delayed.body);
        },
        releaseDelayedTaskSummary: () => {
          const delayed = delayedTaskSummary;
          if (!delayed) {
            throw new Error("No delayed Task summary response is pending.");
          }
          delayedTaskSummary = undefined;
          notifyDelayedTaskSummary = undefined;
          writeJson(delayed.response, delayed.body);
        },
        releaseWorkspaceChatMessage: () => releaseWorkspaceChatMessage?.(),
        startStreamingReply: () => releaseStreamingReplyStart?.(),
        updateStreamingDraft: (text) => {
          draftText = text;
          writeStreamingFrame("message_draft_delta", {
            draft_id: "draft-smoke-stream",
            revision: ++streamingDraftRevision,
            status: "delta",
            text,
          });
        },
        get taskAcceptRequestCount() {
          return taskAcceptRequestCount;
        },
        get taskPreparationRequestCount() {
          return taskPreparationRequestCount;
        },
        get taskDetailRequestCount() {
          return taskDetailRequestCount;
        },
        get taskListEventStreamRequestCount() {
          return taskListEventStreamRequestCount;
        },
        uploads,
        userId: createE2eSessionProjection({ email: sessionEmail }).user.id,
        setWorkspaceChatHidden: (hidden) => {
          workspaceChatHidden = hidden;
        },
        waitForDraft: () => draftEmitted,
        waitForInitialChatSnapshot: () => initialChatSnapshot,
        waitForStreamingReplyReady: () => streamingReplyReady,
        waitForWorkspaceChatMessage: () => workspaceChatMessageObserved,
        waitForFailedConversationListRead: () => failedConversationListReadObserved,
        waitForDelayedTaskDetail: () => delayedTaskDetailObserved,
        waitForDelayedTaskSummary: () => delayedTaskSummaryObserved,
      });
    });
  });

  function workspaceChat() {
    return {
      ...chatSmokeWorkspaceChat,
      activity_status: workspaceChatActivityStatus(),
      messages: messages(),
      status: chatSmokeWorkspaceChat.status,
    };
  }

  function workspaceChatActivityStatus() {
    return assistantCommitted ||
      (holdStreamingReplyStart && participantState === "stopped")
      ? "idle"
      : "thinking";
  }

  function writeStreamingFrame(event: string, data: Record<string, unknown>) {
    if (!streamingReplyResponse || streamingReplyResponse.destroyed) {
      throw new Error("The streaming reply is not connected.");
    }
    streamingReplyResponse.write(
      sseFrame(event, {
        conversation_id: chatSmokeWorkspaceChat.id,
        response_key: "response-smoke-stream",
        source_message_ids: ["msg-user-smoke"],
        type: event,
        ...data,
      })
    );
  }

  function taskParticipantFrame() {
    return sseFrame("task_participant_statuses", {
      type: "task_participant_statuses",
      group_id: chatSmokeWorkspace.group_id,
      conversation_id: chatSmokeTaskConversation.id,
      bound_worker: boundWorker,
      participants: taskParticipants.map((p) => ({
        ...p,
        conversation_id: chatSmokeTaskConversation.id,
      })),
    });
  }

  function taskListInvalidationFrame() {
    return sseFrame("conversation_list_invalidated", {
      group_id: chatSmokeWorkspace.group_id,
      kind: "agent_task",
      type: "conversation_list_invalidated",
      version: `smoke.${taskListRevision}`,
    });
  }

  function participantStatusFrame() {
    return sseFrame("participant_status", {
      conversation_id: chatSmokeWorkspaceChat.id,
      participant_id: "ptp-router-smoke",
      ...(participantIssue ? { issue: participantIssue } : {}),
      state: participantState,
      ...(participantState === "active" && workingProvider
        ? { working_provider: workingProvider }
        : {}),
      status: participantStatus,
      type: "participant_status",
      updated_at: participantUpdatedAt,
    });
  }

  function writeConversationSse(res: ServerResponseLike, snapshot: unknown) {
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.end(`${sseFrame("snapshot", snapshot)}${participantStatusFrame()}`);
  }

  function broadcastTaskListInvalidation() {
    taskListRevision += 1;
    const frame = taskListInvalidationFrame();
    for (const stream of taskListEventStreams) {
      if (!stream.destroyed) stream.write(frame);
    }
  }

  function taskConversation() {
    const conversation: Omit<typeof chatSmokeTaskConversation, "schedule"> & {
      messages: ReturnType<typeof taskMessages>;
      review_version?: number;
      archived_at?: number;
      archived_from_status?: string;
      archive_availability?: { allowed: boolean; reason: string | null };
      schedule?: typeof chatSmokeTaskConversation.schedule;
    } = {
      ...chatSmokeTaskConversation,
      ...taskConversationExtras,
      ...(currentTaskLabels ? { labels: currentTaskLabels } : {}),
      messages: taskMessages(),
      status: currentTaskStatus,
      title: currentTaskTitle,
      updated_at: currentTaskUpdatedAt,
      archive_availability: {
        allowed:
          taskSchedule === null &&
          [
            "ready_for_review",
            "completed",
            "failed",
            "cancelled",
            "escalated",
          ].includes(currentTaskStatus),
        reason:
          taskSchedule !== null
            ? "schedule_bound"
            : currentTaskStatus === "active"
              ? "not_finished"
              : null,
      },
      ...(archivedAt
        ? { archived_at: archivedAt, archived_from_status: archivedFromStatus! }
        : {}),
    };

    if (taskSchedule === null) {
      delete conversation.schedule;
    } else {
      conversation.schedule = taskSchedule;
    }

    if (currentTaskStatus === "ready_for_review") {
      conversation.review_version = currentTaskReviewVersion;
    }

    return conversation;
  }

  // Like the server's preview, the record carries the Task's origin and
  // labels: the inline Task's hover card draws them as chips.
  function taskPreview() {
    return {
      ...taskConversationExtras,
      ...(currentTaskLabels ? { labels: currentTaskLabels } : {}),
      activity_status: "idle",
      freshness: { refreshed_at: 1_720_000_003, state: "fresh" },
      id: chatSmokeTaskConversation.id,
      kind: chatSmokeTaskConversation.kind,
      status: currentTaskStatus,
      title: currentTaskTitle,
      updated_at: currentTaskUpdatedAt,
      group_id: chatSmokeWorkspace.group_id,
    };
  }

  function taskMessages() {
    if (taskTranscript) return [...taskTranscript];
    const replies =
      currentTaskAssistantMessages ?? (taskAssistantReply ? [taskAssistantReply] : []);
    return [
      ...replies.map((text, index) => ({
        actor_type: "agent",
        content: [{ type: "text", text }],
        created_at: 1_720_000_004 + index,
        kind: "message",
        message_id:
          index === 0
            ? "msg-task-assistant-smoke"
            : `msg-task-assistant-smoke-${index}`,
      })),
      ...(taskUserText
        ? [
            {
              actor_type: "user",
              client_request_id: taskClientRequestId,
              content: [{ type: "text", text: taskUserText }],
              created_at: 1_720_000_010,
              kind: "message",
              message_id: "msg-task-user-smoke",
            },
          ]
        : []),
    ];
  }

  function messages() {
    if (workspaceTranscript) return [...workspaceTranscript];
    if (!userText) {
      return [];
    }

    const userMessage = {
      actor_type: "user",
      client_request_id: clientRequestId,
      content: [{ type: "text", text: userContentText() }],
      created_at: 1_720_000_001,
      kind: "message",
      message_id: "msg-user-smoke",
    };
    const priorMessages = [
      ...(priorUserMessage
        ? [
            {
              actor_type: "user",
              content: [{ type: "text", text: priorUserMessage }],
              created_at: 1_720_000_000,
              kind: "message",
              message_id: "msg-prior-user-smoke",
            },
          ]
        : []),
      ...(priorAssistantReply
        ? [
            {
              actor_type: "agent",
              content: [{ type: "text", text: priorAssistantReply }],
              created_at: 1_720_000_000,
              kind: "message",
              message_id: "msg-prior-assistant-smoke",
            },
          ]
        : []),
    ];
    if (!assistantCommitted) {
      return [...priorMessages, userMessage];
    }

    const inlineTaskBlock = () => ({
      type: "conversation_ref",
      presentation: "inline",
      conversation_id: chatSmokeTaskConversation.id,
      kind: "agent_task",
      title: chatSmokeTaskConversation.title,
      status: currentTaskStatus,
      activity_status: "idle",
      freshness: { state: "fresh" },
      updated_at: chatSmokeTaskConversation.updated_at,
    });
    const inlineBoundaryMessage = (id: string, before: string, after: string) => ({
      actor_type: "agent",
      content: [
        { type: "text", text: before },
        inlineTaskBlock(),
        { type: "text", text: after },
      ],
      created_at: 1_720_000_003,
      kind: "message",
      message_id: id,
    });

    return [
      ...priorMessages,
      userMessage,
      ...(inlineTaskBoundaryCases
        ? [
            inlineBoundaryMessage(
              "msg-assistant-inline-info",
              "```typescript-before",
              "\nafter\n```"
            ),
            inlineBoundaryMessage(
              "msg-assistant-inline-quote",
              "> ```ts\n> before ",
              " after\n> ```"
            ),
            inlineBoundaryMessage(
              "msg-assistant-inline-indented",
              "    before ",
              " after"
            ),
            inlineBoundaryMessage(
              "msg-assistant-inline-cr",
              "```text\rbefore ",
              "\rafter\r```"
            ),
            inlineBoundaryMessage(
              "msg-assistant-inline-private",
              "Visible\n```comma:hidden\nsecret before ",
              " secret after"
            ),
            inlineBoundaryMessage(
              "msg-assistant-inline-emphasis",
              "Complete **before ",
              " after**."
            ),
            inlineBoundaryMessage(
              "msg-assistant-inline-reference",
              "See [documentation][docs] and ",
              ".\n\n[docs]: https://example.com/docs"
            ),
          ]
        : []),
      {
        actor_type: "agent",
        content: inlineTaskReference
          ? [
              { type: "text", text: `${assistantReply} ` },
              inlineTaskBlock(),
              { type: "text", text: " 已完成。" },
            ]
          : [
              { type: "text", text: assistantReply },
              ...assistantAttachments.map((attachment) => ({
                type: attachment.type,
                file_name: attachment.fileName,
                mime_type: attachment.mimeType,
                ...(attachment.path ? { path: attachment.path } : {}),
                size: attachment.size,
              })),
              {
                type: "conversation_ref",
                conversation_id: chatSmokeTaskConversation.id,
                kind: "agent_task",
                title: chatSmokeTaskConversation.title,
              },
              ...additionalTaskRefs.map((task) => ({
                type: "conversation_ref",
                conversation_id: task.id,
                kind: "agent_task",
                title: task.title,
              })),
            ],
        created_at: 1_720_000_002,
        kind: "message",
        message_id: "msg-assistant-smoke",
        reply_to_message_id: "msg-user-smoke",
        thread_root_message_id: "msg-user-smoke",
      },
      ...Array.from({ length: laterChatTurns }, (_, index) => [
        {
          actor_type: "user",
          content: [{ type: "text", text: `Earlier follow-up ${index + 1}` }],
          created_at: 1_720_000_010 + index * 2,
          kind: "message",
          message_id: `msg-later-user-smoke-${index + 1}`,
        },
        {
          actor_type: "agent",
          content: [{ type: "text", text: `Earlier reply ${index + 1}` }],
          created_at: 1_720_000_011 + index * 2,
          kind: "message",
          message_id: `msg-later-assistant-smoke-${index + 1}`,
        },
      ]).flat(),
      ...extraInlineTasks.map((task, index) => ({
        actor_type: "agent",
        content: [
          { type: "text", text: "已创建任务 " },
          {
            type: "conversation_ref",
            presentation: "inline",
            conversation_id: task.id,
            kind: "agent_task",
            title: task.title,
            status: task.status,
            activity_status: "idle",
            freshness: { state: "fresh" },
            updated_at: chatSmokeTaskConversation.updated_at,
          },
          { type: "text", text: " 。" },
        ],
        created_at: 1_720_000_004 + index,
        kind: "message",
        message_id: `msg-assistant-extra-task-${index + 1}`,
        reply_to_message_id: "msg-user-smoke",
        thread_root_message_id: "msg-user-smoke",
      })),
      ...Array.from({ length: thinkingReplies }, (_, index) => ({
        actor_type: "agent",
        content: [{ type: "text", text: `思考完成的第 ${index + 1} 条回复。` }],
        created_at: 1_720_000_200 + index,
        kind: "message",
        message_id: `msg-assistant-thinking-${index + 1}`,
      })),
      ...(followupAssistantReply
        ? [
            {
              actor_type: "agent",
              content: [{ type: "text", text: followupAssistantReply }],
              created_at: 1_720_000_003,
              kind: "message",
              message_id: "msg-assistant-followup-smoke",
            },
          ]
        : []),
      ...(followupUserText
        ? [
            {
              actor_type: "user",
              client_request_id: followupClientRequestId,
              content: [{ type: "text", text: followupUserText }],
              created_at: 1_720_000_100,
              kind: "message",
              message_id: "msg-user-followup-smoke",
            },
            {
              actor_type: "agent",
              content: [{ type: "text", text: "Follow-up complete." }],
              created_at: 1_720_000_101,
              kind: "message",
              message_id: "msg-assistant-followup-window-smoke",
            },
          ]
        : []),
    ];
  }

  function userContentText() {
    const taggedSkills = messageSkillLocations
      .map((location) => [chatSmokeSkill].find((skill) => skill.location === location))
      .filter((skill): skill is typeof chatSmokeSkill => skill !== undefined);

    if (taggedSkills.length === 0) {
      return userText;
    }

    return `${userText}\n\n[[comma-protocol]]\nThe user mentioned these skills:\n${taggedSkills
      .map((skill) => `- ${skill.name} — ${skill.location}`)
      .join("\n")}`;
  }
}

function additionalTaskConversation(task: ChatSmokeAdditionalTaskRef, index: number) {
  return {
    created_at: 1_720_000_100 + index * 2,
    id: task.id,
    kind: "agent_task",
    messages: additionalTaskMessages(task, index),
    status: "completed",
    title: task.title,
    updated_at: 1_720_000_101 + index * 2,
    group_id: chatSmokeWorkspace.group_id,
  };
}

function additionalTaskMessages(task: ChatSmokeAdditionalTaskRef, index: number) {
  const taskAssistantReply = `[${task.browserLink.label}](${task.browserLink.url})`;
  return [
    {
      actor_type: "agent",
      content: [{ type: "text", text: taskAssistantReply }],
      created_at: 1_720_000_101 + index * 2,
      kind: "message",
      message_id: `msg-task-assistant-${task.id}`,
    },
  ];
}

function writeJson(res: ServerResponseLike, body: unknown, status = 200) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

function sseFrame(event: string, data: unknown) {
  return `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
}

function readJson(req: NodeJS.ReadableStream) {
  return new Promise<unknown>((resolve) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      resolve(raw ? JSON.parse(raw) : {});
    });
  });
}

function readBuffer(req: NodeJS.ReadableStream) {
  return new Promise<Buffer>((resolve) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
    req.on("end", () => {
      resolve(Buffer.concat(chunks));
    });
  });
}

type ServerResponseLike = {
  destroyed: boolean;
  end: (chunk?: string) => void;
  setHeader: (name: string, value: string) => void;
  write: (chunk: string) => boolean;
  writeHead: (statusCode: number, headers?: Record<string, string>) => void;
};
