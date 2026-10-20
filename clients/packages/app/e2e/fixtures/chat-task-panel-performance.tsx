import { CoreProvider } from "@comma/core-client";
import { RightSidebar } from "@comma/ui/components/right-sidebar";
import { useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  RouterProvider,
} from "@tanstack/react-router";
import { initializeCommaI18n } from "@comma/i18n";
import type { ProductInboxItem } from "@comma/core-client";
import {
  ConversationView,
  type ConversationViewActions,
} from "../../src/components/chat/conversation/ConversationView";
import {
  idleConversationChannelState,
  type ChatMessage,
  type ConversationChannelState,
} from "@comma/core/chat";
// The UI shows what the core reads from these hand-built messages.
import { readState } from "../../../../e2e/app-shell/fixtures/coreReading";
// A fixture page builds with the web app's aliases, which leave test packages out.
import { createScriptedCore } from "../../../test-utils/src/scripted-core";
import { fixedDraftSource } from "../../src/components/chat/composer/conversationDraft";
import "../../src/styles.css";

initializeCommaI18n(["en"]);

declare global {
  interface Window {
    chatTaskPanelStress: {
      /**
       * One announcing turn per task, then `recentTurns` plain turns (enough to
       * fill the window by default). With none, the chips are in view.
       */
      load(taskCount: number, recentTurns?: number): void;
      stream(historyTurns: number): void;
      chunk(): void;
      restart(): void;
      complete(): void;
      toggleSidebar(): void;
      /** Re-emit the whole projection with one task's lifecycle advanced. */
      update(): void;
      /** Re-emit the same projection: an owner read that changes no Task. */
      reread(): void;
    };
  }
}

const GROUP_ID = "group";
const WORKSPACE_ID = "workspace";
const STATUSES = ["in_progress", "ready_for_review", "completed"] as const;

const taskId = (index: number) => `task-${index}`;

function message(messageId: string, role: string, text: string): ChatMessage {
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
  };
}

function transcript(taskCount: number, recentTurns: number): ChatMessage[] {
  const announcing = Array.from({ length: taskCount }, (_, index) => {
    const reply = message(`assistant-${index}`, "assistant", `Started task ${index}.`);
    return [
      message(`user-${index}`, "user", `Please start task ${index}`),
      {
        ...reply,
        parts: [
          ...(reply.parts ?? []),
          {
            kind: "inline-task" as const,
            task: {
              conversationId: taskId(index),
              status: "in_progress",
              title: `Task ${index}`,
              unavailable: false,
            },
          },
        ],
      },
    ];
  }).flat();
  // The reader sits on recent turns; the announcing turns are history.
  const recent = Array.from({ length: recentTurns }, (_, index) => [
    message(`recent-user-${index}`, "user", `Follow-up ${index}`),
    message(
      `recent-assistant-${index}`,
      "assistant",
      `Reply ${index} — ${"a paragraph of ordinary assistant prose. ".repeat(6)}`
    ),
  ]).flat();
  return [...announcing, ...recent];
}

// Shaped like the live projection: every emit is a fresh snapshot of new item
// objects, and each item carries its own archive facts.
function projectionItems(taskCount: number, revision: number): ProductInboxItem[] {
  return Array.from({ length: taskCount }, (_, index) => {
    const status = STATUSES[(index + (index === 0 ? revision : 0)) % STATUSES.length]!;
    const updatedAt = 1_720_000_000 + (index === 0 ? revision : 0);
    return {
      archiveAvailability: {
        allowed: status !== "in_progress",
        reason: status === "in_progress" ? "not_finished" : null,
      },
      archiveVersion: updatedAt,
      id: taskId(index),
      conversationId: taskId(index),
      workspaceId: WORKSPACE_ID,
      workspaceName: "Workspace",
      groupId: GROUP_ID,
      kind: "agent_task",
      source: "salix.conversation",
      title:
        index === 0
          ? `Task 0 — revision ${revision}`
          : `Task ${index} — review the implementation and the release notes`,
      status,
      updatedAt,
    };
  });
}

// The renderer's real projection over a stand-in owner. Every emit is an owner
// read; the projection decides, as in the app, which reads change the list.
// The Tasks the chat refers to are known from the same facts, as the core
// takes them from the list (so rows also exercise their archive control).
const summaryOf = (item: ProductInboxItem) => ({
  archive_availability: item.archiveAvailability,
  group_id: item.groupId,
  id: item.conversationId,
  kind: item.kind,
  status: item.status,
  title: item.title,
  updated_at: item.archiveVersion,
});

function createProjection() {
  let items: ProductInboxItem[] = [];
  const core = createScriptedCore({
    values: (topic) => {
      if (topic.topic === "tasks")
        return { activeWorkspaceId: WORKSPACE_ID, items, source: "live-sync" };
      if (topic.topic !== "taskSummaries") return undefined;
      // Each surface is told only of the Tasks it asked for, as the core tells it.
      const ids = new Set(String(topic.ids ?? "").split(","));
      return {
        summaries: items.filter((item) => ids.has(item.conversationId)).map(summaryOf),
      };
    },
  });
  return {
    controller: core.client,
    emit(next: ProductInboxItem[]) {
      items = next;
      core.changed("tasks");
      core.changed("taskSummaries");
    },
  };
}

const projection = createProjection();
let projectedTaskCount = 0;
let projectionRevision = 0;

const noop = () => undefined;
const emptyDraft = fixedDraftSource("");
const actions: ConversationViewActions = {
  attachFiles: noop,
  discard: noop,
  refresh: async () => undefined,
  removeAttachment: noop,
  retry: noop,
  retryAttachment: noop,
  send: noop,
  setDraft: noop,
};

function Fixture() {
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [sidebarMounted, setSidebarMounted] = useState(false);
  const [state, setState] = useState<ConversationChannelState>(
    idleConversationChannelState
  );
  const shown = useMemo(() => readState(state), [state]);
  window.chatTaskPanelStress = {
    stream: (historyTurns) => {
      projection.emit([]);
      const messages = Array.from({ length: historyTurns }, (_, index) => {
        const prompt = message(`stream-user-${index}`, "user", `Question ${index}`);
        return [
          prompt,
          {
            ...message(
              `stream-reply-${index}`,
              "assistant",
              `Answer ${index}. ${"Ordinary completed prose. ".repeat(8)}`
            ),
            replyToMessageId: prompt.messageId,
            threadRootMessageId: prompt.messageId,
          },
        ];
      }).flat();
      const prompt = message(
        "stream-prompt",
        "user",
        "Explain the result step by step."
      );
      setState({
        ...idleConversationChannelState,
        connection: "live",
        conversation: {
          group_id: GROUP_ID,
          id: "conversation",
          kind: "user_chat",
          status: "completed",
          title: "Streaming conversation",
        },
        messages: [...messages, prompt],
        assistantDraft: {
          conversationId: "conversation",
          draftId: "stream-draft",
          responseKey: "stream-response",
          sourceMessageIds: [prompt.messageId],
          status: "streaming",
          text: "## Result\n\nThe result is",
        },
        status: "ready",
      });
    },
    chunk: () =>
      setState((current) => ({
        ...current,
        assistantDraft: current.assistantDraft && {
          ...current.assistantDraft,
          // Transport snapshots reconstruct this list too.
          sourceMessageIds: [...current.assistantDraft.sourceMessageIds],
          text: current.assistantDraft.text + " a useful detail",
        },
      })),
    restart: () =>
      setState((current) => ({
        ...current,
        assistantDraft: current.assistantDraft && {
          ...current.assistantDraft,
          responseKey: `${current.assistantDraft.responseKey}:next`,
          text: "## Replacement\n\nNew response body",
        },
      })),
    complete: () =>
      setState((current) => ({
        ...current,
        assistantDraft: undefined,
        messages: [
          ...current.messages,
          {
            ...message("stream-completed", "assistant", current.assistantDraft!.text),
            replyToMessageId: "stream-prompt",
            threadRootMessageId: "stream-prompt",
          },
        ],
      })),
    toggleSidebar: () => {
      setSidebarMounted(true);
      setSidebarOpen((open) => !open);
    },
    load: (taskCount, recentTurns = 12) => {
      projectedTaskCount = taskCount;
      projectionRevision = 0;
      projection.emit(projectionItems(taskCount, 0));
      setState({
        ...idleConversationChannelState,
        connection: "live",
        conversation: {
          group_id: GROUP_ID,
          id: "conversation",
          kind: "user_chat",
          status: "completed",
          title: "Chat",
        },
        messages: transcript(taskCount, recentTurns),
        status: "ready",
      });
    },
    update: () => {
      projectionRevision += 1;
      projection.emit(projectionItems(projectedTaskCount, projectionRevision));
    },
    reread: () => {
      projection.emit(projectionItems(projectedTaskCount, projectionRevision));
    },
  };
  return (
    <div style={{ display: "flex", height: "100vh" }}>
      <ConversationView
        actions={actions}
        live
        draftSource={emptyDraft}
        groupId={GROUP_ID}
        state={shown}
        variant="route"
        workspaceId={WORKSPACE_ID}
      />
      <RightSidebar
        activeTab="details"
        ariaLabel="Details"
        open={sidebarOpen}
        width={440}
        onWidthChange={noop}
        onTabChange={noop}
        tabs={[{ id: "details", label: "Details" }]}
      >
        {sidebarMounted ? (
          <ConversationView
            actions={actions}
            live
            draftSource={emptyDraft}
            groupId={GROUP_ID}
            state={shown}
            variant="rail"
            workspaceId={WORKSPACE_ID}
          />
        ) : null}
      </RightSidebar>
    </div>
  );
}

const root = createRootRoute({ component: Fixture });
const taskRoute = createRoute({
  getParentRoute: () => root,
  path: "/tasks/$workspaceId/$groupId/$conversationId",
  component: () => null,
});
const router = createRouter({
  routeTree: root.addChildren([taskRoute]),
  history: createMemoryHistory({ initialEntries: ["/"] }),
});
createRoot(document.getElementById("root")!).render(
  <CoreProvider client={projection.controller}>
    <RouterProvider router={router} />
  </CoreProvider>
);
