import { expect, test, type Page } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const base = "/orgs/acme/projects/p-1";
const project = { id: "p-1", name: "Support Desk", role: "admin" };

const task = (n: number, status: string, extra = {}) => ({
  id: `cnv1_${n}`,
  title: `Task ${n}`,
  status,
  kind: "agent_task",
  scheduled: false,
  updated_at: "2026-09-30T08:00:00Z",
  href: `${base}/tasks/cnv1_${n}`,
  ...extra,
});

const firstPage = (role = "admin") => ({
  project: { ...project, role },
  status: "ok",
  tasks: [
    task(1, "active", { title: "Investigate webhook" }),
    task(2, "done", { title: "Summarize findings", scheduled: true }),
    task(3, "active", { title: null, kind: "user_chat" }),
  ],
  next_cursor: "page-2",
  agents: { status: "ok", items: [{ id: "a-1", name: "Front desk" }] },
});

const schedules = (rows = 2) => ({
  project,
  status: "ok",
  truncated: false,
  schedules: [
    {
      id: "sched-digest",
      target: "agent",
      agent_name: "Front desk",
      prompt: "Post the daily digest",
      recurrence: "Every hour",
      last_run_at: null,
      href: `${base}/agents/a-1`,
    },
    {
      id: "sched-task",
      target: "task",
      agent_name: null,
      prompt: null,
      recurrence: "Every Wednesday at 6:30 PM (Asia/Shanghai)",
      last_run_at: "2026-09-30T08:00:00Z",
      href: `${base}/tasks/cnv1_2`,
    },
  ].slice(0, rows),
});

const settings = (role = "admin", members = grants) => ({
  project: {
    ...project,
    role,
    slug: "support",
    status: "active",
    runtime_id: "grp1_support",
  },
  org_runtime_id: "ten1_acme",
  access: { members, truncated: false },
});

const grants = [
  {
    id: "u-li",
    name: "Li Wei",
    email: "li@acme.test",
    role: "admin",
    granted_at: "2026-09-01T00:00:00Z",
  },
  {
    id: "u-sam",
    name: null,
    email: "sam@acme.test",
    role: "user",
    granted_at: null,
  },
];

async function open(
  page: Page,
  path: string,
  handle: (
    request: RecordedRequest
  ) => { status: number; body: unknown } | { status: number; text: string } | undefined
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) =>
    request.path === "/orgs/acme/context" ? ok(context) : handle(request)
  );
  await page.goto(path);
  return requests;
}

const writes = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.method !== "GET");

test("Tasks groups by status, searches, filters and pages in more", async ({
  page,
}) => {
  const requests = await open(page, `${base}/tasks`, (request) => {
    if (request.path !== `/orgs/acme/projects/p-1/tasks`) return undefined;
    return request.search === "?cursor=page-2"
      ? ok({
          project,
          status: "ok",
          tasks: [task(4, "done", { title: "Older report" })],
          next_cursor: null,
        })
      : ok(firstPage());
  });

  const main = page.getByRole("main");
  await expect(main.getByRole("heading", { level: 1, name: "Tasks" })).toBeVisible();
  await expect(main.getByText("Work items and chats in Support Desk.")).toBeVisible();
  // The detail is a LiveView page, linked for a full page load.
  await expect(main.getByRole("link", { name: "Investigate webhook" })).toHaveAttribute(
    "href",
    `${base}/tasks/cnv1_1`
  );
  await expect(main.getByRole("link", { name: "Untitled task" })).toBeVisible();
  await expect(
    main.getByRole("row", { name: /Summarize findings/ }).getByText("Scheduled")
  ).toBeVisible();

  // Scrolling to the end loads the next page.
  await expect(main.getByRole("link", { name: "Older report" })).toBeVisible();
  expect(requests.some((request) => request.search === "?cursor=page-2")).toBe(true);

  await main.getByRole("searchbox", { name: "Search tasks" }).fill("webhook");
  await expect(main.getByRole("link", { name: "Investigate webhook" })).toBeVisible();
  await expect(main.getByRole("link", { name: "Summarize findings" })).toHaveCount(0);

  await main.getByRole("searchbox", { name: "Search tasks" }).fill("");
  await main.getByRole("button", { name: "Show" }).click();
  await page.getByRole("option", { name: /^Done/ }).click();
  await expect(page).toHaveURL(/\/tasks\?view=done$/);
  await expect(main.getByRole("link", { name: "Summarize findings" })).toBeVisible();
  await expect(main.getByRole("link", { name: "Investigate webhook" })).toHaveCount(0);
});

test("a failed later page keeps its place and retries the same cursor", async ({
  page,
}) => {
  let failing = true;
  const requests = await open(page, `${base}/tasks`, (request) => {
    if (request.path !== `/orgs/acme/projects/p-1/tasks`) return undefined;
    if (request.search !== "?cursor=page-2") return ok(firstPage());
    return failing
      ? {
          status: 503,
          body: {
            ok: false,
            error: {
              code: "runtime_unavailable",
              message:
                "Could not load more tasks. Salix is unavailable — retry shortly.",
            },
          },
        }
      : ok({
          project,
          status: "ok",
          tasks: [task(4, "done", { title: "Older report" })],
          next_cursor: null,
        });
  });

  const main = page.getByRole("main");
  await expect(main.getByRole("alert")).toContainText("Could not load more tasks.");
  await expect(main.getByRole("link", { name: "Investigate webhook" })).toBeVisible();
  await expect(main.getByRole("link", { name: "Older report" })).toHaveCount(0);

  failing = false;
  await main.getByRole("button", { name: "Retry" }).click();
  await expect(main.getByRole("link", { name: "Older report" })).toBeVisible();
  await expect(main.getByRole("alert")).toHaveCount(0);
  expect(
    requests.filter((request) => request.search === "?cursor=page-2")
  ).toHaveLength(2);
});

test("a search or filter loads further pages only on request", async ({ page }) => {
  const requests = await open(page, `${base}/tasks?view=done`, (request) => {
    if (request.path !== `/orgs/acme/projects/p-1/tasks`) return undefined;
    return request.search === "?cursor=page-2"
      ? ok({
          project,
          status: "ok",
          tasks: [task(4, "done", { title: "Older report" })],
          next_cursor: "page-3",
        })
      : ok(firstPage());
  });

  const main = page.getByRole("main");
  await expect(main.getByRole("link", { name: "Summarize findings" })).toBeVisible();
  await expect(
    main.getByText(/Search and filters cover the 3 most recent/)
  ).toBeVisible();
  expect(requests.some((request) => request.search.startsWith("?cursor="))).toBe(false);

  await main.getByRole("button", { name: "Load more" }).click();
  await expect(main.getByRole("link", { name: "Older report" })).toBeVisible();
  await expect(
    main.getByText(/Search and filters cover the 4 most recent/)
  ).toBeVisible();
  expect(requests.filter((request) => request.search.startsWith("?cursor="))).toEqual([
    expect.objectContaining({ search: "?cursor=page-2" }),
  ]);
});

test("the sidebar's Tasks link leaves the Scheduled view for All", async ({ page }) => {
  await open(page, `${base}/tasks?view=scheduled`, (request) => {
    if (request.path === "/orgs/acme/projects/p-1/tasks") return ok(firstPage());
    if (request.path === "/orgs/acme/projects/p-1/schedules") return ok(schedules());
    return undefined;
  });

  const main = page.getByRole("main");
  await expect(
    main.getByRole("heading", { name: "Recurring schedules" })
  ).toBeVisible();
  await page
    .getByRole("navigation", { name: "Organization navigation" })
    .getByRole("link", { name: "Tasks", exact: true })
    .click();
  await expect(page).toHaveURL(/\/tasks$/);
  await expect(main.getByRole("heading", { name: "All tasks" })).toBeVisible();
  await expect(main.getByRole("link", { name: "Investigate webhook" })).toBeVisible();
});

test("New task creates a task for the chosen agent and opens it", async ({ page }) => {
  const requests = await open(page, `${base}/tasks`, (request) => {
    if (request.path !== "/orgs/acme/projects/p-1/tasks") return undefined;
    return request.method === "POST"
      ? { status: 201, body: { ok: true, data: { id: "cnv1_new", href: "/created" } } }
      : ok(firstPage());
  });
  await page.route("**/created", (route) =>
    route.fulfill({ status: 200, body: "<title>Task detail</title>" })
  );

  await page.getByRole("button", { name: "New task" }).click();
  const dialog = page.getByRole("dialog", { name: "New task" });
  await dialog.getByLabel("Title").fill("Launch support");
  await dialog.getByRole("button", { name: "Create task" }).click();

  await expect(page).toHaveURL(/\/created$/);
  expect(writes(requests)).toEqual([
    expect.objectContaining({
      method: "POST",
      csrf,
      body: { title: "Launch support", agent_id: "a-1" },
    }),
  ]);
});

test("a swarm member sees tasks without New task, and an empty swarm asks for an agent", async ({
  page,
}) => {
  await open(page, `${base}/tasks`, (request) =>
    request.path === "/orgs/acme/projects/p-1/tasks"
      ? ok({
          ...firstPage("user"),
          tasks: [],
          next_cursor: null,
          agents: { status: "ok", items: [] },
        })
      : undefined
  );

  const main = page.getByRole("main");
  await expect(main.getByText(/Create an agent first/)).toBeVisible();
  await expect(main.getByRole("link", { name: "Manage agents" })).toHaveAttribute(
    "href",
    `${base}/agents`
  );
  await expect(main.getByRole("button", { name: "New task" })).toHaveCount(0);
});

test("the retired Schedules page opens the Scheduled view, which deletes behind a confirmation", async ({
  page,
}) => {
  const requests = await open(page, `${base}/schedules`, (request) => {
    if (request.path === "/orgs/acme/projects/p-1/tasks") return ok(firstPage());
    if (request.path === "/orgs/acme/projects/p-1/schedules") return ok(schedules());
    if (request.path === "/orgs/acme/projects/p-1/schedules/sched-digest")
      return ok(schedules(0));
    return undefined;
  });

  await expect(page).toHaveURL(/\/tasks\?view=scheduled$/);
  const main = page.getByRole("main");
  await expect(
    main.getByRole("heading", { name: "Recurring schedules" })
  ).toBeVisible();
  await expect(main.getByRole("link", { name: "Task" })).toHaveAttribute(
    "href",
    `${base}/tasks/cnv1_2`
  );
  await expect(main.getByText("Runs this task")).toBeVisible();
  await expect(main.getByText("Every hour")).toBeVisible();

  await main.getByRole("button", { name: "Delete the schedule of Front desk" }).click();
  const confirm = page.getByRole("dialog", { name: "Delete schedule" });
  await confirm.getByRole("button", { name: "Delete" }).click();
  await expect(main.getByText("No recurring schedules.")).toBeVisible();
  expect(writes(requests)).toEqual([
    expect.objectContaining({
      method: "DELETE",
      path: "/orgs/acme/projects/p-1/schedules/sched-digest",
      csrf,
    }),
  ]);
});

test("deleting a schedule that is already gone reloads the list", async ({ page }) => {
  let rows = 2;
  await open(page, `${base}/tasks?view=scheduled`, (request) => {
    if (request.path === "/orgs/acme/projects/p-1/tasks") return ok(firstPage());
    if (request.path === "/orgs/acme/projects/p-1/schedules")
      return ok(schedules(rows));
    if (request.path === "/orgs/acme/projects/p-1/schedules/sched-task") {
      // Someone else deleted it first.
      rows = 1;
      return {
        status: 404,
        body: {
          ok: false,
          error: {
            code: "schedule_not_found",
            message: "That schedule no longer exists.",
          },
        },
      };
    }
    return undefined;
  });

  const main = page.getByRole("main");
  await main.getByRole("button", { name: "Delete the schedule of Task" }).click();
  await page
    .getByRole("dialog", { name: "Delete schedule" })
    .getByRole("button", { name: "Delete" })
    .click();
  await expect(page.getByRole("dialog", { name: "Delete schedule" })).toHaveCount(0);
  await expect(main.getByText("Runs this task")).toHaveCount(0);
  await expect(main.getByText("Every hour")).toBeVisible();
});

test("Settings renames, copies runtime ids and manages access", async ({ page }) => {
  let current = settings();
  const requests = await open(page, `${base}/settings`, (request) => {
    if (request.path === "/orgs/acme/projects/p-1/settings") {
      if (request.method === "PATCH") {
        current = {
          ...current,
          project: { ...current.project, name: "Help Desk" },
        };
      }
      return ok(current);
    }
    if (request.path === "/orgs/acme/projects/p-1/access") {
      current = {
        ...current,
        access: {
          ...current.access,
          members: [
            ...current.access.members,
            {
              id: "u-new",
              name: null,
              email: "new@acme.test",
              role: "admin",
              granted_at: null,
            },
          ],
        },
      };
      return ok(current);
    }
    if (request.path === "/orgs/acme/projects/p-1/access/u-sam") {
      current = {
        ...current,
        access: {
          ...current.access,
          members: current.access.members.filter((member) => member.id !== "u-sam"),
        },
      };
      return ok(current);
    }
    return undefined;
  });

  const main = page.getByRole("main");
  await expect(main.getByRole("heading", { level: 1, name: "Settings" })).toBeVisible();
  await expect(main.getByText("grp1_support")).toBeVisible();
  await expect(main.getByText("ten1_acme")).toBeVisible();
  await expect(
    main.getByRole("button", { name: "Copy Agent Swarm runtime id" })
  ).toBeVisible();

  await main.getByLabel("Name").fill("Help Desk");
  await main.getByRole("button", { name: "Save" }).click();
  await expect(main.getByText("Saved")).toBeVisible();

  await main.getByRole("button", { name: "Add user" }).click();
  const add = page.getByRole("dialog", { name: "Add user" });
  await add.getByRole("button", { name: "Add user" }).click();
  await expect(add.getByText("Enter an email address.")).toBeVisible();
  await add.getByLabel("Email").fill("new@acme.test");
  await add.getByRole("button", { name: "Role" }).click();
  await page.getByRole("option", { name: /^Admin/ }).click();
  await add.getByRole("button", { name: "Add user" }).click();
  await expect(main.getByText("new@acme.test")).toBeVisible();

  await main.getByRole("button", { name: "Remove sam@acme.test" }).click();
  await page
    .getByRole("dialog", { name: "Remove access" })
    .getByRole("button", { name: "Remove" })
    .click();
  await expect(main.getByText("sam@acme.test")).toHaveCount(0);

  expect(
    writes(requests).map(({ method, path, body, csrf: token }) => ({
      method,
      path,
      body,
      token,
    }))
  ).toEqual([
    {
      method: "PATCH",
      path: "/orgs/acme/projects/p-1/settings",
      body: { name: "Help Desk" },
      token: csrf,
    },
    {
      method: "POST",
      path: "/orgs/acme/projects/p-1/access",
      body: { email: "new@acme.test", role: "admin" },
      token: csrf,
    },
    {
      method: "DELETE",
      path: "/orgs/acme/projects/p-1/access/u-sam",
      body: undefined,
      token: csrf,
    },
  ]);
});

test("an admin who demotes themselves loses the admin controls", async ({ page }) => {
  const me = {
    id: "user-1",
    name: "Mei Chen",
    email: "mei@acme.test",
    role: "admin",
    granted_at: "2026-09-01T00:00:00Z",
  };
  await open(page, `${base}/settings`, (request) => {
    if (request.path === "/orgs/acme/projects/p-1/settings")
      return ok(settings("admin", [me]));
    if (request.path === "/orgs/acme/projects/p-1/access/user-1")
      return ok(settings("user", [{ ...me, role: "user" }]));
    return undefined;
  });

  const main = page.getByRole("main");
  await main.getByRole("button", { name: "Role of Mei Chen" }).click();
  await page.getByRole("option", { name: /^User/ }).click();
  await expect(main.getByRole("button", { name: "Add user" })).toHaveCount(0);
  await expect(main.getByRole("button", { name: /Remove/ })).toHaveCount(0);
  await expect(main.getByRole("button", { name: "Archive Agent Swarm" })).toHaveCount(
    0
  );
});

test("an admin who removes their own access lands on the swarms list", async ({
  page,
}) => {
  const me = {
    id: "user-1",
    name: "Mei Chen",
    email: "mei@acme.test",
    role: "admin",
    granted_at: "2026-09-01T00:00:00Z",
  };
  await open(page, `${base}/settings`, (request) => {
    if (request.path === "/orgs/acme/projects/p-1/settings")
      return ok(settings("admin", [me]));
    if (request.path === "/orgs/acme/projects/p-1/access/user-1")
      return ok({
        redirect: "/orgs/acme/projects",
        notice: 'You no longer have access to Agent Swarm "Support Desk".',
      });
    if (request.path === "/orgs/acme/projects")
      return ok({ viewer: { can_create: true }, projects: [], next_cursor: null });
    return undefined;
  });

  await page.getByRole("main").getByRole("button", { name: "Remove Mei Chen" }).click();
  await page
    .getByRole("dialog", { name: "Remove access" })
    .getByRole("button", { name: "Remove" })
    .click();
  await expect(page).toHaveURL(/\/orgs\/acme\/projects$/);
  await expect(page.getByRole("status")).toContainText(
    'You no longer have access to Agent Swarm "Support Desk".'
  );
});

test("the access list loads grants past the first page", async ({ page }) => {
  const requests = await open(page, `${base}/settings`, (request) => {
    if (request.path === "/orgs/acme/projects/p-1/settings")
      return ok({
        ...settings(),
        access: { members: grants, truncated: true, next_cursor: "100" },
      });
    if (request.path === "/orgs/acme/projects/p-1/access" && request.method === "GET")
      return ok({
        members: [
          {
            id: "u-late",
            name: null,
            email: "late@acme.test",
            role: "user",
            granted_at: null,
          },
        ],
        truncated: false,
        next_cursor: null,
      });
    return undefined;
  });

  const main = page.getByRole("main");
  await expect(main.getByText("sam@acme.test")).toBeVisible();
  await main.getByRole("button", { name: "Load more" }).click();
  await expect(main.getByText("late@acme.test")).toBeVisible();
  await expect(main.getByRole("button", { name: "Load more" })).toHaveCount(0);
  await expect(
    main.getByRole("button", { name: "Remove late@acme.test" })
  ).toBeVisible();
  expect(requests.some((request) => request.search === "?cursor=100")).toBe(true);
});

test("archiving shows a blocker in place, then lands on the swarms list with a notice", async ({
  page,
}) => {
  let blocked = true;
  await open(page, `${base}/access`, (request) => {
    if (request.path === "/orgs/acme/projects/p-1/settings") return ok(settings());
    if (request.path === "/orgs/acme/projects/p-1/archive") {
      return blocked
        ? {
            status: 409,
            body: {
              ok: false,
              error: {
                code: "archive_blocked",
                message:
                  "Delete every schedule in the Scheduled view of Tasks before archiving this Agent Swarm.",
              },
            },
          }
        : ok({
            redirect: "/orgs/acme/projects",
            notice: 'Agent Swarm "Support Desk" archived.',
          });
    }
    if (request.path === "/orgs/acme/projects")
      return ok({ viewer: { can_create: true }, projects: [], next_cursor: null });
    return undefined;
  });

  // The retired Access address opens Settings at its Access section.
  await expect(page).toHaveURL(/\/settings#access$/);
  const main = page.getByRole("main");
  await main.getByRole("button", { name: "Archive Agent Swarm" }).click();
  const confirm = page.getByRole("dialog", { name: "Archive Agent Swarm" });
  await confirm.getByRole("button", { name: "Archive Agent Swarm" }).click();
  await expect(confirm.getByRole("alert")).toContainText("Scheduled view of Tasks");

  blocked = false;
  await confirm.getByRole("button", { name: "Archive Agent Swarm" }).click();
  await expect(page).toHaveURL(/\/orgs\/acme\/projects$/);
  await expect(page.getByRole("status")).toContainText(
    'Agent Swarm "Support Desk" archived.'
  );
});

test("a swarm member reads Settings without write controls", async ({ page }) => {
  await open(page, `${base}/settings`, (request) =>
    request.path === "/orgs/acme/projects/p-1/settings"
      ? ok(settings("user", [grants[0]!]))
      : undefined
  );

  const main = page.getByRole("main");
  await expect(main.getByText("Li Wei")).toBeVisible();
  await expect(main.getByText("Support Desk", { exact: true })).toBeVisible();
  await expect(main.getByRole("button", { name: "Save" })).toHaveCount(0);
  await expect(main.getByRole("button", { name: "Add user" })).toHaveCount(0);
  await expect(main.getByRole("button", { name: /Remove/ })).toHaveCount(0);
  await expect(main.getByRole("button", { name: "Archive Agent Swarm" })).toHaveCount(
    0
  );
});

test("pages fit 900px wide without sideways scrolling", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 700 });
  await open(page, `${base}/tasks`, (request) => {
    if (request.path === "/orgs/acme/projects/p-1/tasks") return ok(firstPage());
    if (request.path === "/orgs/acme/projects/p-1/settings") return ok(settings());
    return undefined;
  });
  for (const path of ["/tasks", "/settings"]) {
    await page.goto(`${base}${path}`);
    await expect(
      page.getByRole("main").getByRole("heading", { level: 1 })
    ).toBeVisible();
    expect(
      await page.evaluate(
        () =>
          document.documentElement.scrollWidth - document.documentElement.clientWidth
      )
    ).toBeLessThanOrEqual(0);
  }
});
