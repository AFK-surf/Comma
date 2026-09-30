import { initializeCommaI18n } from "@comma/i18n";
import type { ProductInboxListResult } from "@comma/native-bridge";
import { act, render, waitFor } from "@comma/test-utils/render";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createCommaApi } from "../../../api";
import { ProductInboxProjectionProvider } from "../../../product-inbox";
import {
  createProductInboxProjectionHarness,
  createTestCommaAuthValue,
} from "../../../test/productInboxProjectionHarness";
import { CommaAuthContext } from "../../auth-context";
import { ChatProvider } from "../../chat/ChatProvider";
import { useWorkspaceTasks, type WorkspaceTasksState } from "../useWorkspaceTasks";

/**
 * Archiving is a decision the user has already made, so the Tasks board must
 * stop showing the Task at the moment of the click — not when the authority
 * answers and the projection is reread. These tests hold the archive request
 * open and demand the row is already gone.
 */
describe("useTaskArchive", () => {
  beforeEach(() => initializeCommaI18n(["en"]));
  afterEach(() => {
    localStorage.clear();
    vi.unstubAllGlobals();
    latest = undefined;
    document.body.innerHTML = "";
  });

  it("takes the Task out of the list before the archive request settles", async () => {
    const archive = deferred<Response>();
    const fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = input instanceof Request ? input.url : String(input);
      assertArchiveUrl(url);
      return archive.promise;
    });
    vi.stubGlobal("fetch", fetch);

    renderTasksBoard();
    await waitFor(() => expect(rows()).toHaveLength(1));

    let requestSettled = false;
    act(() => {
      void latest!.tasks[0]!.archiveAction!.run().finally(() => {
        requestSettled = true;
      });
    });

    await waitFor(() => expect(rows()).toHaveLength(0));
    expect(requestSettled).toBe(false);
    expect(fetch).toHaveBeenCalledTimes(1);

    act(() => archive.resolve(body(archivedConversation())));
    await waitFor(() => expect(requestSettled).toBe(true));
    expect(rows()).toHaveLength(0);
  });

  it("returns a Task the authority refused", async () => {
    const archive = deferred<Response>();
    const fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = input instanceof Request ? input.url : String(input);
      assertArchiveUrl(url);
      return archive.promise;
    });
    vi.stubGlobal("fetch", fetch);

    renderTasksBoard();
    await waitFor(() => expect(rows()).toHaveLength(1));

    let requestSettled = false;
    act(() => {
      void latest!.tasks[0]!.archiveAction!.run()
        .catch(() => undefined)
        .finally(() => {
          requestSettled = true;
        });
    });
    await waitFor(() => expect(rows()).toHaveLength(0));

    act(() =>
      archive.resolve(
        new Response(JSON.stringify({ error: "Task changed" }), {
          headers: { "content-type": "application/json" },
          status: 409,
        })
      )
    );
    await waitFor(() => expect(requestSettled).toBe(true));
    await waitFor(() => expect(rows()).toHaveLength(1));
  });
});

let latest: WorkspaceTasksState | undefined;

function TasksProbe() {
  latest = useWorkspaceTasks();
  return (
    <ul>
      {latest.tasks.map((task) => (
        <li data-testid="task-row" key={task.id}>
          {task.title}
        </li>
      ))}
    </ul>
  );
}

function renderTasksBoard() {
  const auth = createTestCommaAuthValue();
  const projection = createProductInboxProjectionHarness({
    initial: liveResult([
      {
        archiveAvailability: { allowed: true, reason: null },
        archiveVersion: 1,
        conversationId: "conversation-a",
        groupId: "grp_test",
        id: "conversation-a",
        kind: "agent_task",
        source: "salix.conversation",
        status: "completed",
        title: "Task one",
        updatedAt: 1,
        workspaceId: "workspace-a",
        workspaceName: "Account A",
      },
    ]),
  });
  return render(
    <CommaAuthContext.Provider value={auth}>
      <ProductInboxProjectionProvider controller={projection.controller}>
        <ChatProvider
          api={createCommaApi({ baseUrl: "", token: "" })}
          productLease={auth.productLease}
        >
          <TasksProbe />
        </ChatProvider>
      </ProductInboxProjectionProvider>
    </CommaAuthContext.Provider>
  );
}

function liveResult(items: ProductInboxListResult["items"]): ProductInboxListResult {
  return { activeWorkspaceId: "workspace-a", items, source: "live-sync" };
}

function archivedConversation() {
  return {
    group_id: "grp_test",
    id: "conversation-a",
    kind: "agent_task",
    status: "archived",
    title: "Task one",
    updated_at: 2,
  };
}

function assertArchiveUrl(url: string) {
  if (!url.endsWith("/conversations/conversation-a/archive")) {
    throw new TypeError(`Unexpected fetch: ${url}`);
  }
}

function body(value: unknown): Response {
  return new Response(JSON.stringify(value), {
    headers: { "content-type": "application/json" },
    status: 200,
  });
}

function rows() {
  return document.querySelectorAll('[data-testid="task-row"]');
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((settle) => {
    resolve = settle;
  });
  return { promise, resolve };
}
