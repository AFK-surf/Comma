import type { TaskRequestContact, TaskRequestSent } from "@comma/core-client";
import { flush } from "@comma/test-utils/fake-clock";
import { fireEvent, render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { Toaster } from "@comma/ui/components/toast";
import {
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  RouterProvider,
} from "@tanstack/react-router";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { CommaAuthContext, type CommaAuthContextValue } from "../../auth-context";
import { PersonTasks } from "../PersonTasks";

const user = () => userEvent.setup({ advanceTimers: vi.advanceTimersByTime });

const person: TaskRequestContact = {
  id: "u_cat",
  name: "CatsJuice",
  email: "cat@example.com",
  avatar: null,
  sends: null,
  receives: [{ grant: "trg_1", workspace: "Cats", full: false }],
  waiting: null,
  lastAt: 1_790_000_000,
  lastTitle: "Check weather",
};

const sent = (extra: Partial<TaskRequestSent> = {}): TaskRequestSent => ({
  id: "trq_1",
  workspace: {
    id: "w_cat",
    name: "Cats",
    owner: { id: "u_cat", name: "CatsJuice", email: "cat@example.com" },
  },
  title: "Check weather",
  content: "Check weather in Shanghai",
  status: "accepted",
  decline_reason: null,
  task_status: "active",
  reply: null,
  created_at: 1_790_000_000,
  decided_at: 1_790_000_010,
  task_updated_at: 1_790_000_020,
  ...extra,
});

const authValue = {
  apiBaseUrl: "https://comma.test",
  authenticated: true,
  userId: "u_me",
  userEmail: "me@example.com",
  userDisplayName: "Me",
  signOut: vi.fn(),
} as unknown as CommaAuthContextValue;

function renderPersonTasks(sentRequests: TaskRequestSent[]) {
  const core = createScriptedCore({
    values: (topic) => {
      if (topic.topic === "workspace")
        return {
          status: "ready",
          workspace: { id: "w_me", groupId: "g_me", name: "Mine" },
          selected: true,
        };
      if (topic.topic === "tasks")
        return { items: [], source: "live-sync", hasMore: false };
      if (topic.topic === "collaborations") return { items: [] };
      if (topic.topic === "taskRequests") {
        return {
          workspace: "w_me",
          incoming: [],
          grants: [],
          targets: [],
          sent: sentRequests,
          links: [],
          own: "review",
          people: [person],
          error: false,
        };
      }
      return undefined;
    },
    calls: () => null,
  });

  const root = createRootRoute({
    component: () => (
      <CommaAuthContext.Provider value={authValue}>
        {core.wrap(
          <>
            <PersonTasks person={person} />
            <Toaster />
          </>
        )}
      </CommaAuthContext.Provider>
    ),
  });
  const router = createRouter({
    routeTree: root.addChildren([
      createRoute({ getParentRoute: () => root, path: "/", component: () => null }),
      createRoute({
        getParentRoute: () => root,
        path: "/inbox/request/$requestId",
        component: () => null,
      }),
    ]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });

  render(<RouterProvider router={router} />);
  return { core };
}

describe("PersonTasks", () => {
  it("deletes a decided sent request via the row context menu", async () => {
    const { core } = renderPersonTasks([sent({ id: "trq_stuck", task_status: null })]);
    await flush();

    fireEvent.contextMenu(screen.getByTestId("person-task"));
    await flush();
    await user().click(screen.getByRole("menuitem", { name: "Delete" }));
    await flush();
    expect(screen.getByText("Delete this request?")).toBeTruthy();
    expect(core.sent).not.toContainEqual([
      "taskRequests.hide",
      { request: "trq_stuck" },
    ]);
    await user().click(screen.getByRole("button", { name: "Delete" }));
    await flush();

    expect(core.sent).toContainEqual(["taskRequests.hide", { request: "trq_stuck" }]);
  });

  it("withdraws a pending sent request from the row actions button", async () => {
    const { core } = renderPersonTasks([
      sent({ id: "trq_wait", status: "pending", task_status: null, decided_at: null }),
    ]);
    await flush();

    await user().click(screen.getByTestId("person-task-actions"));
    await flush();
    await user().click(screen.getByRole("menuitem", { name: "Withdraw" }));
    await flush();

    expect(core.sent).toContainEqual([
      "taskRequests.withdraw",
      { request: "trq_wait" },
    ]);
  });
});
