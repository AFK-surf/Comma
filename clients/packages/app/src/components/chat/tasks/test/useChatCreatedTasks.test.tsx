import { act, renderHook, waitFor } from "@comma/test-utils/render";
import { afterEach, expect, it, vi } from "vitest";
import type { CommaApiClient, CommaConversation } from "../../../../api";
import { ProductInboxProjectionProvider } from "../../../../product-inbox";
import {
  createProductInboxProjectionHarness,
  testProductLease,
} from "../../../../test/productInboxProjectionHarness";
import {
  invalidateTaskSummaries,
  recordTaskSummary,
} from "../../../tasks/taskArchiveState";
import type { ChatMessage } from "../../model/conversationChannel";
import { useChatCreatedTasks } from "../useChatCreatedTasks";

afterEach(() => localStorage.clear());

const messages: ChatMessage[] = [
  {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: undefined,
    createdAt: 1,
    createdBy: undefined,
    delivery: "sent",
    error: undefined,
    messageId: "message",
    parts: [],
    refs: [{ kind: "agent_task", conversationId: "task", title: "Message title" }],
    role: "assistant",
    source: "server",
    status: "completed",
    text: "",
  },
];
const summary: CommaConversation = {
  id: "task",
  group_id: "group",
  kind: "agent_task",
  status: "completed",
  title: "Cached title",
  updated_at: 1,
  archive_availability: { allowed: true, reason: null },
};

it("uses current owner facts without summary churn and keeps a newer archive authoritative", async () => {
  const getTaskSummaries = vi.fn(async () => [summary]);
  const api = { getTaskSummaries } as unknown as CommaApiClient;
  recordTaskSummary(api, summary);
  const projection = createProductInboxProjectionHarness({
    initial: {
      activeWorkspaceId: "workspace",
      source: "live-sync",
      items: [
        {
          id: "task",
          conversationId: "task",
          groupId: "group",
          kind: "agent_task",
          workspaceId: "workspace",
          workspaceName: "Workspace",
          source: "salix.conversation",
          status: "completed",
          title: "Current title",
          updatedAt: 2,
          archiveVersion: 2,
          archiveAvailability: { allowed: true, reason: null },
        },
      ],
    },
  });
  const release = projection.controller.retain({ session: testProductLease });
  await waitFor(() => expect(projection.controller.getSnapshotSync()).not.toBeNull());
  const { result, unmount } = renderHook(
    () => useChatCreatedTasks({ api, groupId: "group", messages }),
    {
      wrapper: ({ children }) => (
        <ProductInboxProjectionProvider controller={projection.controller}>
          {children}
        </ProductInboxProjectionProvider>
      ),
    }
  );
  expect(result.current[0]).toMatchObject({
    title: "Current title",
    archiveVersion: 2,
  });
  const before = result.current;
  act(() => invalidateTaskSummaries(api));
  expect(result.current).toBe(before);
  expect(getTaskSummaries).not.toHaveBeenCalled();

  act(() => recordTaskSummary(api, { ...summary, status: "archived", updated_at: 3 }));
  expect(result.current).toEqual([]);
  unmount();
  release();
});

it("revalidates references outside the owner page and withholds stale archive permission", async () => {
  let resolve!: (value: CommaConversation[]) => void;
  const getTaskSummaries = vi.fn(
    () =>
      new Promise<CommaConversation[]>((done) => {
        resolve = done;
      })
  );
  const api = { getTaskSummaries } as unknown as CommaApiClient;
  recordTaskSummary(api, summary);
  const { result, unmount } = renderHook(() =>
    useChatCreatedTasks({ api, groupId: "group", messages })
  );
  expect(result.current[0]?.archiveVersion).toBe(1);
  act(() => invalidateTaskSummaries(api));
  expect(result.current[0]?.archiveVersion).toBeUndefined();
  await waitFor(() => expect(getTaskSummaries).toHaveBeenCalledWith("group", ["task"]));
  await act(async () => resolve([{ ...summary, status: "archived", updated_at: 2 }]));
  await waitFor(() => expect(result.current).toEqual([]));
  unmount();
});
