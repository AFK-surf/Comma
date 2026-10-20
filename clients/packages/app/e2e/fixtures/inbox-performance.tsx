import { useState } from "react";
import { createRoot } from "react-dom/client";
import {
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  RouterProvider,
  useParams,
} from "@tanstack/react-router";
import { initializeCommaI18n } from "@comma/i18n";
import type { ProductInboxItem } from "@comma/core-client";
import { InboxView } from "../../src/components/inbox/InboxView";
import { CoreProvider } from "@comma/core-client";
import { useMarkTaskReviewSeen } from "../../src/components/tasks/taskReviewAttention";
import { marksCore } from "./marksCore";
import { InboxPaginationFixture } from "./inbox-pagination";
import "../../src/styles.css";
initializeCommaI18n(["en"]);
declare global {
  interface Window {
    inboxStress: {
      load(count: number): void;
      update(): void;
      read(index: number): void;
    };
  }
}
function Fixture() {
  const [items, setItems] = useState<ProductInboxItem[]>([]);
  const markTaskReviewSeen = useMarkTaskReviewSeen();
  const { conversationId } = useParams({ strict: false }) as {
    conversationId?: string;
  };
  window.inboxStress = {
    load: (count) =>
      setItems(
        Array.from({ length: count }, (_, index) => ({
          id: `task-${index}`,
          conversationId: `task-${index}`,
          workspaceId: "workspace",
          workspaceName: "Workspace",
          groupId: "group",
          kind: "agent_task",
          source: "salix.conversation",
          title: `Task ${index} — review the implementation and the release notes`,
          status: "ready_for_review",
          updatedAt: Date.now() - Math.floor(index / 50) * 86400000,
        }))
      ),
    update: () =>
      setItems((previous) =>
        previous.map((item, index) =>
          index === 0 ? { ...item, title: item.title + "." } : { ...item }
        )
      ),
    read: (index) => {
      const item = items[index];
      if (item) markTaskReviewSeen(item.conversationId, item.updatedAt);
    },
  };
  return (
    <div style={{ height: "100vh", display: "flex" }}>
      <InboxView
        result={{ source: "live-sync", items, hasMore: true }}
        onLoadMore={() =>
          setItems((previous) => [
            ...previous,
            ...previous.slice(0, 50).map((item, index) => ({
              ...item,
              id: `task-${previous.length + index}`,
              conversationId: `task-${previous.length + index}`,
              title: `Older task ${previous.length + index}`,
              updatedAt: previous.at(-1)!.updatedAt - 86400000,
            })),
          ])
        }
        selectedConversationId={conversationId}
      />
      <div>{conversationId}</div>
    </div>
  );
}
const root = createRootRoute({
  component: location.search.includes("pagination") ? InboxPaginationFixture : Fixture,
});
const route = createRoute({
  getParentRoute: () => root,
  path: "/inbox/$workspaceId/$groupId/$conversationId",
  component: () => null,
});
const router = createRouter({
  routeTree: root.addChildren([route]),
  history: createMemoryHistory({ initialEntries: ["/"] }),
});
// The reader's marks live in the core; this fixture's core keeps only them.
const core = marksCore();
createRoot(document.getElementById("root")!).render(
  <CoreProvider client={core}>
    <RouterProvider router={router} />
  </CoreProvider>
);
