import type {
  ProductInboxItem,
  ProductInboxListResult,
  TaskSummariesValue,
  TaskSummary,
  StationTasksValue,
} from "@comma/core-client";
import type { SessionProductLease } from "@comma/session-contract";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { vi } from "vitest";
import type { CommaApiSessionTransport } from "../session/controller";
import type { CommaAuthContextValue } from "../components/auth-context";

export const testProductLease: SessionProductLease = {
  audience: "https://api.comma.test",
  authorityInstanceId: "test-electron-main",
  generation: 1,
  sessionId: "11111111-1111-4111-8111-111111111111",
};

export function createTestCommaAuthValue(): CommaAuthContextValue {
  const controller = new AbortController();
  const sessionTransport: CommaApiSessionTransport = {
    credentials: "include",
    signal: controller.signal,
    applyHeaders: () => undefined,
    reportSessionRejection: () => undefined,
  };
  return {
    apiBaseUrl: "",
    authenticated: true,
    productLease: testProductLease,
    sessionSignal: controller.signal,
    sessionTransport,
    signOut: vi.fn(),
    userEmail: "test@example.com",
  };
}

/** What a read asked: the workspace, the next page's cursor, the tasks to read exactly. */
export type ProductInboxHarnessRead = {
  conversationIds?: string[] | undefined;
  cursor?: string | undefined;
  session: SessionProductLease;
  workspaceId?: string | undefined;
};

/**
 * The client core's task list as a UI test scripts it (`tasks`): `initial` is
 * shown, each read (`tasks.refresh`, `tasks.more`) answers with `refresh`, a
 * next page is appended, and a staged archive or status shows until settled.
 * `retain`/`release` count the UIs that show the list. The Tasks referred to
 * (`taskSummaries`) are the list's, else what `summarize` says the core's
 * summary cache knows; each change of the list says them again. The Task
 * Workers a chat's activity focus follows (`taskWorkers`) are recorded while
 * shown (`followedWorkers`) and known to none.
 */
export function createProductInboxProjectionHarness({
  initial,
  refresh,
  retain,
  summarize,
  stationTasks,
}: {
  initial: ProductInboxListResult;
  /** The Tasks the workspace's stations host (`stationTasks`), when a test gives them. */
  stationTasks?: StationTasksValue | undefined;
  summarize?: (groupId: string, conversationId: string) => TaskSummary | undefined;
  refresh?: (
    input: ProductInboxHarnessRead
  ) => ProductInboxListResult | Promise<ProductInboxListResult>;
  retain?: (input: {
    session: SessionProductLease;
  }) => ProductInboxListResult | Promise<ProductInboxListResult>;
}) {
  let current = initial;
  const stages = new Map<
    number,
    { groupId: string; conversationId: string; status: string }
  >();
  let nextStage = 0;
  const shown = (): ProductInboxListResult =>
    stages.size === 0
      ? current
      : {
          ...current,
          items: current.items.map((item) => {
            const stage = [...stages.values()].find(
              (s) =>
                s.groupId === item.groupId && s.conversationId === item.conversationId
            );
            return stage ? { ...item, status: stage.status } : item;
          }),
        };
  const refreshMock = vi.fn(async (input: ProductInboxHarnessRead) => {
    const result = refresh ? await refresh(input) : current;
    if (input.cursor) {
      const ids = new Set(result.items.map((item) => item.id));
      current = {
        ...current,
        ...result,
        items: [...current.items.filter((item) => !ids.has(item.id)), ...result.items],
      };
    } else current = result;
    publish();
    return current;
  });
  // A `retain` that throws is a core that cannot keep the list: the topic fails.
  let failure: Error | undefined;
  const retainMock = vi.fn(async (input: { session: SessionProductLease }) => {
    if (retain) {
      try {
        current = await retain(input);
      } catch (error) {
        failure = error instanceof Error ? error : new Error(String(error));
      }
      publish(failure ?? shown());
    }
    return current;
  });
  const release = vi.fn(async (_input: { session: SessionProductLease }) => true);
  // The core keeps the list while any UI shows it, and reads a workspace a UI
  // starts to show.
  let shownBy = 0;
  // The Tasks (`ids`) of each `taskWorkers` topic shown now.
  const followed: string[] = [];
  // The reader's marks (seen, deleted, unread, acknowledged), kept as the core keeps them.
  const marks = new Map<string, Record<string, number>>();
  let markedAt = 0;
  const scripted = createScriptedCore({
    // The task list, the Tasks referred to from it, and the reader's marks; anything else goes to a
    // real core when a test gives one.
    owns: (name) =>
      name === "tasks" ||
      name === "taskSummaries" ||
      name.startsWith("tasks.") ||
      name === "marks" ||
      name.startsWith("marks.") ||
      name === "taskWorkers" ||
      name === "stationTasks",
    values: (topic) =>
      topic.topic === "tasks"
        ? (failure ?? shown())
        : topic.topic === "taskSummaries"
          ? summariesOf(shown().items, topic, summarize)
          : topic.topic === "marks"
            ? { marks: marks.get(String(topic.kind)) ?? {} }
            : topic.topic === "taskWorkers"
              ? {}
              : topic.topic === "stationTasks"
                ? (stationTasks ?? { state: "unavailable", tasks: [] })
                : undefined,
    onSubscribe: (topic) => {
      if (topic.topic === "taskWorkers") followed.push(String(topic.ids));
      if (topic.topic !== "tasks") return;
      if (shownBy++ === 0) void retainMock({ session: testProductLease });
      const workspaceId = typeof topic.workspace === "string" ? topic.workspace : "";
      if (workspaceId && workspaceId !== current.activeWorkspaceId)
        void refreshMock({ session: testProductLease, workspaceId });
    },
    onUnsubscribe: (topic) => {
      if (topic.topic === "taskWorkers")
        followed.splice(followed.indexOf(String(topic.ids)), 1);
      if (topic.topic === "tasks" && --shownBy === 0)
        void release({ session: testProductLease });
    },
    calls: async (name, raw) => {
      const params = (raw ?? {}) as Record<string, unknown>;
      const workspaceId =
        typeof params.workspace === "string" ? params.workspace : undefined;
      switch (name) {
        case "tasks.refresh":
          await refreshMock({
            session: testProductLease,
            ...(workspaceId ? { workspaceId } : {}),
            ...(Array.isArray(params.conversations)
              ? { conversationIds: params.conversations as string[] }
              : {}),
          });
          return null;
        case "tasks.more": {
          if (!current.nextCursor) return null;
          const before = current;
          await refreshMock({
            cursor: current.nextCursor,
            session: testProductLease,
            ...(workspaceId ? { workspaceId } : {}),
          });
          if (current.source !== "live-sync") {
            const code = current.errorCode ?? "unknown";
            current = before;
            publish();
            throw Object.assign(new Error(code), { code });
          }
          return null;
        }
        case "tasks.stage": {
          const stage = ++nextStage;
          stages.set(stage, {
            conversationId: String(params.conversationId),
            groupId: String(params.groupId),
            status: String(params.status),
          });
          publish();
          return { stage };
        }
        case "marks.mark":
        case "marks.unmark": {
          const kind = String(params.kind);
          const next = { ...marks.get(kind) };
          const ids = Array.isArray(params.ids) ? (params.ids as string[]) : [];
          if (name === "marks.unmark") for (const id of ids) delete next[id];
          else {
            markedAt += 1;
            for (const id of ids) next[id] ??= markedAt;
            for (const [id, revision] of (params.entries ?? []) as [string, number][])
              if ((next[id] ?? -Infinity) < revision) next[id] = revision;
          }
          marks.set(kind, next);
          // Every surface sees the marks it subscribed to, as the core sends them.
          scripted.changed("marks");
          return null;
        }
        case "tasks.stage.settle":
          if (params.accepted !== true) stages.delete(params.stage as number);
          publish();
          return null;
        default:
          return null;
      }
    },
  });

  /** The list changed: so did what the Tasks referred to from it say. */
  function publish(value: ProductInboxListResult | Error = shown()) {
    scripted.emit("tasks", value);
    scripted.changed("taskSummaries");
  }

  return {
    controller: scripted.client,
    /** The Tasks of each Worker feed the UI asks the core to follow now. */
    followedWorkers: () => [...followed],
    emit(result: ProductInboxListResult) {
      current = result;
      publish();
    },
    refresh: refreshMock,
    release,
    retain: retainMock,
    wrap: scripted.wrap,
  };
}

/** What the core says of Tasks (`taskSummaries`): the list's facts, else the summary cache's. */
function summariesOf(
  items: readonly ProductInboxItem[],
  topic: Record<string, unknown>,
  summarize:
    | ((groupId: string, conversationId: string) => TaskSummary | undefined)
    | undefined
): TaskSummariesValue {
  const group = String(topic.group ?? "");
  const listed = new Map(
    items
      .filter((item) => item.groupId === group)
      .map((item) => [item.conversationId, item] as const)
  );
  return {
    summaries: String(topic.ids ?? "")
      .split(",")
      .filter(Boolean)
      .flatMap((id): TaskSummary[] => {
        const item = listed.get(id);
        if (!item) {
          const known = summarize?.(group, id);
          return known ? [known] : [];
        }
        return [
          {
            id: item.conversationId,
            group_id: item.groupId,
            kind: item.kind,
            status: item.status,
            title: item.title,
            ...(item.archiveVersion === undefined
              ? {}
              : { updated_at: item.archiveVersion }),
            ...(item.archiveAvailability
              ? { archive_availability: item.archiveAvailability }
              : {}),
            ...(item.labels === undefined ? {} : { labels: item.labels }),
            ...(item.origin === undefined ? {} : { origin: item.origin }),
          },
        ];
      }),
  };
}
