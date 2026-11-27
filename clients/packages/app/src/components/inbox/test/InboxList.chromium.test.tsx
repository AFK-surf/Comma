import "@comma/ui/styles.css";
import "@comma/app/styles.css";

import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import type { ProductInboxItem } from "@comma/core-client";
import { initializeCommaI18n } from "@comma/i18n";
import { cleanup, render } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, beforeAll, expect, it } from "vitest";
import { page } from "vitest/browser";
import { InboxFiltersProvider } from "../filters/InboxFiltersState";
import { InboxList } from "../InboxList";

beforeAll(() => {
  initializeCommaI18n(["en"]);
});

afterEach(cleanup);

const item = (over: Partial<ProductInboxItem>): ProductInboxItem => ({
  id: "w1:c1",
  kind: "user_chat",
  source: "salix.conversation",
  workspaceId: "w1",
  workspaceName: "Acme",
  groupId: "grp_test",
  conversationId: "c1",
  title: "Kickoff sync",
  status: "open",
  updatedAt: 1_000,
  ...over,
});

it("keeps a 2px gap between rows with avatar or Loop chips, unclipped in narrow content", async () => {
  const items = [
    item({
      id: "w1:c1",
      conversationId: "c1",
      title: "Look at Comma's proactive replies",
      status: "running",
      origin: "task_request",
      requestedBy: { id: "u_px", name: "Pat Xu" },
    }),
    item({
      id: "w1:c2",
      conversationId: "c2",
      title: "https://example.com/project/1",
      status: "done",
      loop: {
        state: "active",
        cadence: { everyMinutes: 60 },
        startedAt: 1_000,
        wakeCount: 1,
      },
    }),
    item({ id: "w1:c3", conversationId: "c3", title: "Kickoff sync", status: "done" }),
  ];
  const rootRoute = createRootRoute({ component: Outlet });
  const listRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/",
    component: () => (
      <section
        data-testid="inbox-rail"
        className="comma-content flex h-[320px] w-[320px] flex-col bg-primary"
      >
        <InboxList
          groups={[{ key: "today", label: "Today", items }]}
          renderRequest={() => null}
          onDeleteItem={() => undefined}
          onMarkReadItem={() => undefined}
          onMarkUnreadItem={() => undefined}
          onOpenItem={() => undefined}
          seenMarks={new Map()}
          selectedConversationId="c2"
          unreadMarks={new Map()}
          label="Inbox"
        />
      </section>
    ),
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([listRoute]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
  const core = createScriptedCore({});
  render(
    core.wrap(
      <InboxFiltersProvider>
        <RouterProvider router={router} />
      </InboxFiltersProvider>
    )
  );
  await expect.element(page.getByText("Kickoff sync")).toBeVisible();
  const rows = [
    ...document.querySelectorAll<HTMLElement>('[data-slot="task-list-item"]'),
  ].map((row) => row.getBoundingClientRect());
  expect(rows).toHaveLength(3);
  for (const row of rows) {
    expect(row.height).toBe(36);
  }
  for (let index = 1; index < rows.length; index++) {
    expect(rows[index]!.top - rows[index - 1]!.bottom).toBe(2);
  }
  const badgeSlots = [
    ...document.querySelectorAll<HTMLElement>('[data-slot="task-list-item-badges"]'),
  ];
  expect(badgeSlots).toHaveLength(2);
  for (const slot of badgeSlots) {
    expect(slot.offsetHeight).toBe(20);
    expect(getComputedStyle(slot).overflowY).toBe("visible");
  }
  expect(
    document.querySelector<HTMLElement>('[data-testid="inbox-item-request"]')
      ?.offsetHeight
  ).toBe(22);
  expect(
    document.querySelector<HTMLElement>('[data-testid="inbox-item-schedule"]')
      ?.offsetHeight
  ).toBe(22);
});
