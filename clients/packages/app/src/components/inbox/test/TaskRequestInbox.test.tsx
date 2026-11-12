import type { ProductInboxItem } from "@comma/core-client";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { advance, flush } from "@comma/test-utils/fake-clock";
import { fireEvent, render, screen, within } from "@comma/test-utils/render";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  useParams,
} from "@tanstack/react-router";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { Toaster, toast } from "@comma/ui/components/toast";
import { afterEach, expect, it, vi } from "vitest";
import { useEffect } from "react";
import { defaultCommaClientSettings } from "@comma/native-bridge";
import { CommaWebClientSettingsProvider } from "../../commaClientSettings";
import { openNativePlatformExternalUrl } from "../../../nativePlatformActions";
import { playRequestSound } from "../../notifications/notificationSound";
import { InboxFiltersProvider, useInboxFilters } from "../filters/InboxFiltersState";
import { InboxDetailPane } from "../InboxRoute";
import { InboxView } from "../InboxView";
import {
  InboxLaunchProvider,
  InboxRequestPane,
  useRequestArrivalToasts,
} from "../TaskRequestInbox";

vi.mock("../../../nativePlatformActions", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../../../nativePlatformActions")>()),
  openNativePlatformExternalUrl: vi.fn(async () => undefined),
}));
vi.mock("../../notifications/notificationSound", () => ({
  playNotificationSound: vi.fn(),
  playRequestSound: vi.fn(),
}));

const user = () => userEvent.setup({ advanceTimers: vi.advanceTimersByTime });

const request = (id: string, createdAt: number) => ({
  id,
  sender: { id: "u2", name: "Sam", email: "sam@example.com", avatar_id: null },
  title: `Request ${id}`,
  content: `Do ${id}`,
  status: "pending",
  decline_reason: null,
  task: null,
  created_at: createdAt,
  expires_at: createdAt + 600_000,
});

const task = (id: string, updatedAt: number): ProductInboxItem => ({
  id: `w1:${id}`,
  kind: "agent_task",
  source: "salix.conversation",
  workspaceId: "w1",
  workspaceName: "W",
  groupId: "g1",
  conversationId: id,
  title: `Task ${id}`,
  status: "completed",
  updatedAt,
});

/** Narrows the Inbox's filters as the filter menu would: to these platforms, or these Request choices. */
function Narrow({ by, keys }: { by: "platforms" | "requests"; keys: string[] }) {
  const [, setFilters] = useInboxFilters();
  const key = keys.join(",");
  useEffect(
    () => setFilters((f) => ({ ...f, [by]: new Set(key.split(",")) })),
    [by, key, setFilters]
  );
  return null;
}

/** A call the server refuses, with the code it answers. */
let refused: { call: string; code: string } | undefined;
afterEach(() => {
  refused = undefined;
});

function scriptedCore(incoming: unknown[], calls: string[], sent: unknown[] = []) {
  // The Inbox's deleted marks, kept as the core keeps them: a mark never moves back.
  const deleted: Record<string, number> = {};
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "marks"
        ? { marks: topic.kind === "inboxDeleted" ? { ...deleted } : {} }
        : topic.topic === "workspace"
          ? { status: "ready", workspace: { id: "w1", name: "W" }, selected: true }
          : topic.topic === "taskRequests"
            ? {
                workspace: "w1",
                incoming,
                grants: [],
                targets: [],
                sent,
                links: [],
                error: false,
              }
            : topic.topic === "stations"
              ? { workspace: "w1", loading: false, stations: [] }
              : topic.topic === "models"
                ? {
                    workspace: "w1",
                    catalog: { sources: {}, models: [] },
                    presets: [],
                    profiles: [],
                    moreProfiles: false,
                    models: [
                      {
                        id: "gpt-5.5",
                        name: "GPT 5.5",
                        vendor: "openai",
                        efforts: [],
                        serving: ["p1"],
                      },
                    ],
                  }
                : undefined,
    calls: (name, params) => {
      calls.push(name);
      if (name === refused?.call)
        throw Object.assign(new Error(refused.code), { code: refused.code });
      if (name === "taskRequests.accept") return { task: { group_id: "g1", id: "c9" } };
      const { kind, entries = [] } = params as {
        kind?: string;
        entries?: [string, number][];
      };
      if (name === "marks.mark" && kind === "inboxDeleted") {
        for (const [id, at] of entries) deleted[id] = Math.max(deleted[id] ?? 0, at);
        queueMicrotask(() => core.changed("marks"));
      }
      return null;
    },
  });
  return core;
}

function renderInbox(
  incoming: unknown[],
  items: ProductInboxItem[],
  narrow?: { by: "platforms" | "requests"; keys: string[] },
  sent: unknown[] = []
) {
  const calls: string[] = [];
  const core = scriptedCore(incoming, calls, sent);
  const root = createRootRoute({
    component: () =>
      core.wrap(
        <InboxFiltersProvider>
          {narrow ? <Narrow {...narrow} /> : null}
          <InboxView
            result={{
              items,
              source: "live-sync",
              activeWorkspaceId: "w1",
              hasMore: false,
            }}
          />
        </InboxFiltersProvider>
      ),
  });
  const router = createRouter({
    routeTree: root,
    history: createMemoryHistory({ initialEntries: ["/inbox"] }),
  });
  render(<RouterProvider router={router} />);
  return { calls, core };
}

/** The Inbox's rail and detail pane as the app routes them: a request, a Task's conversation, or nothing open. */
function renderPane(incoming: unknown[], at = "/inbox") {
  const calls: string[] = [];
  const core = scriptedCore(incoming, calls);
  const root = createRootRoute({
    component: () =>
      core.wrap(
        <InboxFiltersProvider>
          <InboxLaunchProvider>
            <Rail />
            <InboxDetailPane>
              <Outlet />
            </InboxDetailPane>
          </InboxLaunchProvider>
        </InboxFiltersProvider>
      ),
  });
  const routes = [
    createRoute({ getParentRoute: () => root, path: "/inbox", component: () => null }),
    createRoute({
      getParentRoute: () => root,
      path: "/inbox/request/$requestId",
      component: InboxRequestPane,
    }),
    createRoute({
      getParentRoute: () => root,
      path: "/inbox/$workspaceId/$groupId/$conversationId",
      component: TaskChat,
    }),
  ];
  const router = createRouter({
    routeTree: root.addChildren(routes),
    history: createMemoryHistory({ initialEntries: [at] }),
  });
  render(<RouterProvider router={router} />);
  return { calls, router };
}

function Rail() {
  const { requestId } = useParams({ strict: false }) as { requestId?: string };
  return (
    <InboxView
      result={{
        items: [],
        source: "live-sync",
        activeWorkspaceId: "w1",
        hasMore: false,
      }}
      selectedRequestId={requestId}
    />
  );
}

function TaskChat() {
  const { conversationId } = useParams({ strict: false }) as {
    conversationId?: string;
  };
  return <div data-testid="task-chat">{conversationId}</div>;
}

/** A request chip's way (from or to) and its words. */
const chip = (testId: string) => {
  const element = screen.getByTestId(testId);
  return [
    element.querySelector("[data-direction]")?.getAttribute("data-direction"),
    element.textContent,
  ];
};

const titles = () =>
  [...document.querySelectorAll("[data-inbox-row-id]")].map(
    (row) => row.getAttribute("data-inbox-row-id") ?? ""
  );

it("lists requests among the Tasks by when they came, and reads them again on opening", async () => {
  // Tasks' times are in milliseconds, requests' in seconds: they still interleave by time.
  const { calls } = renderInbox(
    [request("trq_new", 1_790_000_300), request("trq_mid", 1_790_000_150)],
    [task("t2", 1_790_000_200_000), task("t1", 1_790_000_100_000)]
  );
  await flush();
  expect(titles()).toEqual([
    "task-request:trq_new",
    "w1:t2",
    "task-request:trq_mid",
    "w1:t1",
  ]);
  expect(calls).toContain("taskRequests.refresh");
  // A waiting request is not an empty Inbox.
  expect(screen.queryByTestId("inbox-empty")).toBeNull();
});

it("hides requests while a filter chooses among the Tasks, and counts them as hidden", async () => {
  renderInbox([request("trq_1", 1_790_000_300)], [task("t1", 1_790_000_100_000)], {
    by: "platforms",
    keys: ["slack"],
  });
  await flush();
  expect(screen.queryByTestId("inbox-task-request")).toBeNull();
  expect(screen.getByTestId("inbox-filter-footer").textContent).toContain("2");
});

it("narrows through a Request filter to the requests sent to one person", async () => {
  const sentOne = sentRequest({ created_at: 1_790_000_200, task_updated_at: null });
  const toDog = sentRequest({
    id: "trq_8",
    workspace: {
      id: "w_dog",
      name: "Dogs",
      owner: { id: "u_dog", name: "Rex", email: null },
    },
    created_at: 1_790_000_150,
    task_updated_at: null,
  });
  const asked = { ...task("t2", 1_790_000_250_000), origin: "task_request" };
  renderInbox(
    [request("trq_1", 1_790_000_300)],
    [asked, task("t1", 1_790_000_100_000)],
    { by: "requests", keys: ["to:u_cat"] },
    [sentOne, toDog]
  );
  await flush();
  expect(titles()).toEqual(["task-request-sent:trq_9"]);
});

it("keeps what one person asked of the person: their waiting requests and the Tasks made of them", async () => {
  const asked = {
    ...task("t2", 1_790_000_250_000),
    origin: "task_request",
    requestedBy: { id: "u2", name: "Sam" },
  };
  const askedByAnother = {
    ...task("t3", 1_790_000_240_000),
    origin: "task_request",
    requestedBy: { id: "u3", name: "Sam" },
  };
  renderInbox(
    [request("trq_1", 1_790_000_300)],
    [asked, askedByAnother, task("t1", 1_790_000_100_000)],
    { by: "requests", keys: ["from:u2"] },
    [sentRequest({ created_at: 1_790_000_200, task_updated_at: null })]
  );
  await flush();
  // Two senders of one name stay apart by their User id.
  expect(titles()).toEqual(["task-request:trq_1", "w1:t2"]);
});

it("lists each person a request came from and went to in the Request filter, with their avatars", async () => {
  const asked = {
    ...task("t2", 1_790_000_250_000),
    origin: "task_request",
    requestedBy: {
      id: "u2",
      name: "Sam",
      avatar: { workspace: "w1", request: "trq_0", revision: "avt_sam" },
    },
  };
  renderInbox(
    [request("trq_1", 1_790_000_300)],
    [asked, task("t1", 1_790_000_100_000)],
    undefined,
    [sentRequest({ created_at: 1_790_000_200, task_updated_at: null })]
  );
  await flush();
  // Each row names its person by avatar alone, and says which way the request went in words for assistive
  // technology; hovering the avatar shows the person.
  // A waiting request is no Task yet: its row's avatar says who sent it, without a chip.
  expect(screen.queryByTestId("inbox-request-chip")).toBeNull();
  expect(chip("inbox-item-request")).toEqual(["from", "SFrom Sam"]);
  expect(chip("inbox-sent-request-chip")).toEqual(["to", "CTo CatsJuice"]);
  setInteractionModality("pointer");
  await user().hover(screen.getByTestId("inbox-sent-request-chip"));
  await advance(250);
  expect(screen.getByRole("tooltip")).toHaveTextContent(/^ToCCatsJuice$/);
  await user().unhover(screen.getByTestId("inbox-sent-request-chip"));
  await advance(250);

  await user().click(screen.getByTestId("inbox-filter-trigger"));
  await user().click(screen.getByRole("menuitem", { name: "Request" }));
  await flush();
  const panel = screen.getByTestId("inbox-request-filter");
  const rows = within(panel)
    .getAllByRole("menuitemcheckbox")
    .map((row) => row.textContent);
  expect(rows).toEqual([
    expect.stringMatching(/^S.*Sam.*2/),
    expect.stringMatching(/^C.*CatsJuice.*1/),
    expect.stringMatching(/Not from a request.*1/),
  ]);
  expect(within(panel).getByText("From a request")).toBeTruthy();
  expect(within(panel).getByText("To")).toBeTruthy();

  await user().click(within(panel).getByRole("menuitemcheckbox", { name: /Sam/ }));
  await flush();
  expect(titles()).toEqual(["w1:t1", "task-request-sent:trq_9"]);
});

it("names whom a sent request went to only once it is a Task", async () => {
  renderInbox([], [], undefined, [
    sentRequest({ status: "pending", task_status: null, decided_at: null }),
  ]);
  await flush();
  expect(screen.getByTestId("inbox-task-request-sent")).toBeTruthy();
  expect(screen.queryByTestId("inbox-sent-request-chip")).toBeNull();
});

it("says the Inbox is empty only without Tasks or requests", async () => {
  renderInbox([], []);
  await flush();
  expect(screen.getByTestId("inbox-empty")).toBeTruthy();
});

it("opens a request in the detail pane as a Task behind a blur, with its card where the message box would be", async () => {
  const { router } = renderPane([request("trq_1", 1_000)]);
  await flush();

  await user().click(screen.getByTestId("inbox-task-request"));
  await flush();
  expect(router.state.location.pathname).toBe("/inbox/request/trq_1");
  expect(screen.getByTestId("inbox-task-request").getAttribute("aria-current")).toBe(
    "page"
  );
  const pane = screen.getByTestId("inbox-request-pane");
  // The Task's own header and conversation, the conversation hidden from reading and from assistive technology.
  expect(pane.querySelector(".comma-chat-header h1")?.textContent).toBe(
    "Request trq_1"
  );
  expect(screen.getByTestId("inbox-request-preview").getAttribute("aria-hidden")).toBe(
    "true"
  );
  // The card sits in the message box's frame, below the conversation.
  const card = screen.getByTestId("task-request-card");
  expect(card.closest(".comma-chat-composer-frame")).toBeTruthy();
  expect(screen.getByRole("textbox", { name: "What should it do?" })).toHaveProperty(
    "value",
    "Do trq_1"
  );
});

it("opens the Task made from a request in its place, coming out of the blur once", async () => {
  const { calls, router } = renderPane(
    [request("trq_1", 1_000)],
    "/inbox/request/trq_1"
  );
  await flush();

  await user().click(screen.getByRole("button", { name: "Create task" }));
  await flush();
  expect(calls).toContain("taskRequests.accept");
  // It stays in the Inbox: the Task's conversation takes the request's place in the detail pane.
  expect(decodeURIComponent(router.state.location.pathname)).toBe("/inbox/w1/g1/c9");
  expect(screen.getByTestId("task-chat").textContent).toBe("c9");
  const detail = screen.getByTestId("inbox-detail-pane");
  expect(detail.getAttribute("data-launch")).toBe("true");
  // jsdom has no AnimationEvent: the event the browser sends as the Task's launch animation ends.
  const end = Object.assign(new Event("animationend", { bubbles: true }), {
    animationName: "comma-inbox-task-launch",
  });
  fireEvent(screen.getByTestId("task-chat"), end);
  await flush();
  expect(detail.getAttribute("data-launch")).toBeNull();
});

it("closes a request's pane when it is declined", async () => {
  const { calls, router } = renderPane(
    [request("trq_1", 1_000)],
    "/inbox/request/trq_1"
  );
  await flush();

  await user().click(screen.getByRole("button", { name: "Decline" }));
  await flush();
  expect(calls).toContain("taskRequests.decline");
  expect(router.state.location.pathname).toBe("/inbox");
});

it("closes a request's pane once it has been answered elsewhere", async () => {
  const { router } = renderPane([], "/inbox/request/trq_gone");
  await flush();
  expect(router.state.location.pathname).toBe("/inbox");
});

/** The `taskRequests` topic with these requests waiting. */
const waiting = (incoming: unknown[]) => ({
  workspace: "w1",
  incoming,
  grants: [],
  targets: [],
  sent: [],
  links: [],
  error: false,
});

function Arrivals() {
  useRequestArrivalToasts();
  return null;
}

afterEach(() => toast.dismissAll());

/** The arrival toasts on screen: those Sonner has not taken away. */
const arrivals = () =>
  screen
    .queryAllByTestId("task-request-arrived")
    .filter(
      (t) => t.closest("[data-sonner-toast]")?.getAttribute("data-removed") !== "true"
    );

it("raises a toast for a request that comes while the window is open, whose View opens it in the Inbox", async () => {
  const core = scriptedCore([request("trq_1", 1)], []);
  const root = createRootRoute({
    component: () =>
      core.wrap(
        <>
          <Arrivals />
          <Outlet />
          <Toaster />
        </>
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
  await flush();
  // What waited when the window first read the list raises none: the Inbox's dot shows it.
  expect(arrivals()).toEqual([]);

  core.emit("taskRequests", waiting([request("trq_2", 2), request("trq_1", 1)]));
  await flush();
  const [arrived] = arrivals();
  expect(arrived).toHaveTextContent("New request from Sam");
  expect(arrived).toHaveTextContent("Do trq_2");
  // The sender's avatar leads it: their initial, without an avatar of their own.
  expect(arrived?.querySelector(".comma-user-avatar")).not.toBeNull();

  await user().click(screen.getByRole("button", { name: "View" }));
  await flush();
  expect(router.state.location.pathname).toBe("/inbox/request/trq_2");
  await advance(1000);
  expect(arrivals()).toEqual([]);

  // A request answered elsewhere takes its toast away.
  core.emit("taskRequests", waiting([request("trq_3", 3), request("trq_1", 1)]));
  await flush();
  expect(arrivals().map((t) => t.textContent)).toEqual([
    expect.stringContaining("Do trq_3"),
  ]);
  core.emit("taskRequests", waiting([request("trq_1", 1)]));
  await flush();
  await advance(1000);
  expect(arrivals()).toEqual([]);
});

it.each([
  { requestSound: true, plays: 1 },
  { requestSound: false, plays: 0 },
])(
  "plays the request sound once for the requests a read brings: $plays with requestSound $requestSound",
  async ({ requestSound, plays }) => {
    vi.mocked(playRequestSound).mockClear();
    const core = scriptedCore([request("trq_1", 1)], []);
    const root = createRootRoute({
      component: () =>
        core.wrap(
          <CommaWebClientSettingsProvider
            initialSettings={{ ...defaultCommaClientSettings, requestSound }}
          >
            <Arrivals />
            <Toaster />
          </CommaWebClientSettingsProvider>
        ),
    });
    const router = createRouter({
      routeTree: root,
      history: createMemoryHistory({ initialEntries: ["/"] }),
    });
    render(<RouterProvider router={router} />);
    await flush();
    // What waited when the window first read the list makes no sound.
    expect(playRequestSound).not.toHaveBeenCalled();

    core.emit(
      "taskRequests",
      waiting([request("trq_3", 3), request("trq_2", 2), request("trq_1", 1)])
    );
    await flush();
    expect(arrivals()).toHaveLength(2);
    expect(playRequestSound).toHaveBeenCalledTimes(plays);
  }
);

/** A request the person sent, as the core lists it. */
const sentRequest = (extra: Record<string, unknown> = {}) => ({
  id: "trq_9",
  workspace: {
    id: "w_cat",
    name: "Cats",
    owner: { id: "u_cat", name: "CatsJuice", email: null },
  },
  title: "Summarize Q3",
  content: "Summarize the Q3 numbers",
  status: "accepted",
  decline_reason: null,
  task_status: "active",
  reply: null,
  created_at: 1,
  decided_at: 2,
  task_updated_at: 3,
  ...extra,
});

it("follows a request the person sent as the Task it asked for, and raises its result", async () => {
  const core = scriptedCore([], [], [sentRequest()]);
  const root = createRootRoute({
    component: () =>
      core.wrap(
        <InboxFiltersProvider>
          <InboxLaunchProvider>
            <Arrivals />
            <Rail />
            <InboxDetailPane>
              <Outlet />
            </InboxDetailPane>
            <Toaster />
          </InboxLaunchProvider>
        </InboxFiltersProvider>
      ),
  });
  const router = createRouter({
    routeTree: root.addChildren([
      createRoute({
        getParentRoute: () => root,
        path: "/inbox",
        component: () => null,
      }),
      createRoute({
        getParentRoute: () => root,
        path: "/inbox/request/$requestId",
        component: InboxRequestPane,
      }),
    ]),
    history: createMemoryHistory({ initialEntries: ["/inbox"] }),
  });
  render(<RouterProvider router={router} />);
  await flush();

  // It sits among the Tasks by when it last changed, its Task's status as its mark alone; nothing to raise yet.
  expect(titles()).toEqual(["task-request-sent:trq_9"]);
  expect(screen.getByTestId("inbox-task-request-sent")).not.toHaveTextContent(
    "In progress"
  );
  expect(screen.queryByTestId("task-request-result")).toBeNull();

  // Its Task waits for review with a reply: the person hears of it, and View opens what came of it.
  core.emit("taskRequests", {
    ...waiting([]),
    sent: [
      sentRequest({ task_status: "ready_for_review", reply: "Revenue grew 12%." }),
    ],
  });
  await flush();
  const result = screen.getByTestId("task-request-result");
  expect(result).toHaveTextContent("Your request to CatsJuice: Needs Review");
  expect(result).toHaveTextContent("Revenue grew 12%.");
  await user().click(screen.getByRole("button", { name: "View" }));
  await flush();
  expect(router.state.location.pathname).toBe("/inbox/request/trq_9");
  // Its details sit beside it as a Task's do: its status, and whom it went to.
  expect(screen.getByTestId("inbox-sent-request-status")).toHaveTextContent(
    "Needs Review"
  );
  expect(screen.getByTestId("inbox-sent-request-to")).toHaveTextContent("CatsJuice");
  expect(screen.getByTestId("inbox-sent-request-reply")).toHaveTextContent(
    "Revenue grew 12%."
  );

  // The reply is Markdown, drawn as a Task's reply is, not as its source.
  core.emit("taskRequests", {
    ...waiting([]),
    sent: [
      sentRequest({
        task_status: "done",
        reply:
          "**Revenue grew 12%.**\n\n### Next\n- Hire two people\n\n" +
          "![chart](https://tracker.example/pixel.png) [Report](https://example.com/report)",
      }),
    ],
  });
  await flush();
  const reply = screen.getByTestId("inbox-sent-request-reply");
  expect(reply).not.toHaveTextContent("**");
  expect(within(reply).getByText("Revenue grew 12%.").closest("strong")).not.toBeNull();
  expect(within(reply).getByRole("heading", { name: "Next" })).toBeInTheDocument();
  expect(within(reply).getByRole("listitem")).toHaveTextContent("Hire two people");
  // It comes from another workspace's Task: its images load nothing, and its links open outside.
  expect(reply.querySelector("img")).toBeNull();
  expect(reply).toHaveTextContent("Image: chart (not loaded)");
  fireEvent.click(within(reply).getByRole("link", { name: "Report" }));
  expect(openNativePlatformExternalUrl).toHaveBeenCalledWith(
    "https://example.com/report"
  );
});

/** Opens a row's menu as a right click does, and chooses `item` in it. */
const choose = async (row: HTMLElement, item: string) => {
  fireEvent.contextMenu(row);
  await flush();
  await user().click(screen.getByRole("menuitem", { name: item }));
  await flush();
};

it("withdraws a request the person sent while it waits, from its row's menu", async () => {
  const { core } = renderInbox([], [], undefined, [
    sentRequest({ status: "pending", task_status: null, decided_at: null }),
  ]);
  await flush();
  fireEvent.contextMenu(screen.getByTestId("inbox-task-request-sent"));
  await flush();
  // Nothing was decided yet: it can still be taken back, not only hidden.
  expect(screen.queryByRole("menuitem", { name: "Delete notification" })).toBeNull();
  await user().click(screen.getByRole("menuitem", { name: "Withdraw" }));
  await flush();
  expect(core.sent).toContainEqual(["taskRequests.withdraw", { request: "trq_9" }]);
});

it("hides a decided request the person sent until its Task reports again", async () => {
  // Accepted, and its Task never moved on: the person cannot stop another person's Task, only stop following it.
  const { calls, core } = renderInbox([], [], undefined, [sentRequest()]);
  await flush();
  await choose(screen.getByTestId("inbox-task-request-sent"), "Delete notification");
  expect(calls).not.toContain("taskRequests.withdraw");
  expect(titles()).toEqual([]);

  // Its Task reports a result: the request comes back with it.
  core.emit("taskRequests", {
    ...waiting([]),
    sent: [sentRequest({ task_status: "ready_for_review", task_updated_at: 4 })],
  });
  await flush();
  expect(titles()).toEqual(["task-request-sent:trq_9"]);
});

it("declines a waiting request from its row's menu, rather than hiding it", async () => {
  const { core } = renderInbox([request("trq_1", 1_790_000_300)], []);
  await flush();
  fireEvent.contextMenu(screen.getByTestId("inbox-task-request"));
  await flush();
  expect(screen.queryByRole("menuitem", { name: "Delete notification" })).toBeNull();
  await user().click(screen.getByRole("menuitem", { name: "Decline" }));
  await flush();
  expect(core.sent).toContainEqual([
    "taskRequests.decline",
    { workspace: "w1", request: "trq_1" },
  ]);
});

it("reads a sent request again when its owner decided before the withdraw arrived", async () => {
  refused = { call: "taskRequests.withdraw", code: "task_request_closed" };
  const { calls } = renderInbox([], [], undefined, [
    sentRequest({ status: "pending", task_status: null, decided_at: null }),
  ]);
  render(<Toaster />);
  await flush();
  const refreshes = () =>
    calls.filter((name) => name === "taskRequests.refresh").length;
  const before = refreshes();
  await choose(screen.getByTestId("inbox-task-request-sent"), "Withdraw");
  // A retry would fail the same way: the person hears it no longer waits, and the row reads what came of it.
  expect(await screen.findByText("This request is no longer waiting.")).toBeTruthy();
  expect(screen.queryByText("That did not work. Try again.")).toBeNull();
  expect(refreshes()).toBe(before + 1);
});

it("reads the waiting requests again when the sender withdrew before the decline arrived", async () => {
  refused = { call: "taskRequests.decline", code: "task_request_closed" };
  const { calls } = renderInbox([request("trq_1", 1_790_000_300)], []);
  render(<Toaster />);
  await flush();
  const refreshes = () =>
    calls.filter((name) => name === "taskRequests.refresh").length;
  const before = refreshes();
  await choose(screen.getByTestId("inbox-task-request"), "Decline");
  expect(await screen.findByText("This request is no longer waiting.")).toBeTruthy();
  expect(screen.queryByText("That did not work. Try again.")).toBeNull();
  expect(refreshes()).toBe(before + 1);
});

it("deletes the decided requests the person sent with the rest of the Inbox, but not one still waiting", async () => {
  const { core } = renderInbox([], [], undefined, [
    sentRequest({
      id: "trq_decided",
      decided_at: 1_790_000_200,
      task_updated_at: null,
    }),
    sentRequest({
      id: "trq_waiting",
      status: "pending",
      task_status: null,
      decided_at: null,
    }),
  ]);
  await flush();
  await user().click(screen.getByTestId("inbox-actions-trigger"));
  await flush();
  await user().click(screen.getByRole("menuitem", { name: "Delete all" }));
  await flush();
  // Marked in milliseconds, as the Tasks' marks are.
  expect(core.sent).toContainEqual([
    "marks.mark",
    {
      kind: "inboxDeleted",
      entries: [["task-request-sent:trq_decided", 1_790_000_200_000]],
    },
  ]);
  expect(titles()).toEqual(["task-request-sent:trq_waiting"]);
});
