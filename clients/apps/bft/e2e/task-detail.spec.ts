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
const api = "/orgs/acme/projects/p-1/tasks/cnv1_a";
const project = { id: "p-1", name: "Support Desk", role: "admin" };

const header = (extra: Record<string, unknown> = {}) => ({
  id: "cnv1_a",
  title: "Refund above the limit",
  status: "active",
  kind: "agent_task",
  scheduled: false,
  schedulable: true,
  review_version: null,
  terminal: false,
  updated_at: "2026-10-01T09:00:00Z",
  ...extra,
});

const form = (extra: Record<string, unknown> = {}) => ({
  mode: "cron",
  interval_value: "1",
  interval_unit: "days",
  cron: "",
  timezone: "UTC",
  command: "",
  ...extra,
});

const noSchedule = { status: "none", recurrence: null, command: null, form: form() };

const hourly = {
  status: "ok",
  recurrence: "Every hour",
  command: "Inspect the refunds.",
  form: form({
    mode: "interval",
    interval_value: "1",
    interval_unit: "hours",
    command: "Inspect the refunds.",
  }),
};

const message = (n: number, extra: Record<string, unknown> = {}) => ({
  id: `msg${n}`,
  seq: n,
  author: n % 2 ? "Billing specialist" : "Mei Chen",
  from_person: n % 2 === 0,
  created_at: "2026-10-01T09:00:00Z",
  blocks: [{ type: "text", html: `<p>Message ${n}</p>` }],
  ...extra,
});

const detail = (extra: Record<string, unknown> = {}) => ({
  project,
  task: header(),
  schedule: noSchedule,
  participants: [
    {
      id: "worker",
      label: "Billing specialist",
      role_label: "worker",
      agent_href: `${base}/agents/a-1`,
      thread_url: null,
    },
    {
      id: "slack",
      label: "Dana Ops",
      role_label: "slack_thread",
      agent_href: null,
      thread_url: "https://app.slack.com/client/T1/C1/thread/C1-1",
    },
  ],
  messages: [
    message(1, {
      blocks: [
        {
          type: "text",
          html: '<p>Read the <a href="https://example.com" target="_blank" rel="noopener noreferrer">policy</a> and <strong>approve</strong>.</p>',
        },
      ],
    }),
    message(2, {
      blocks: [
        { type: "text", html: "<p>Report attached.</p>" },
        {
          type: "attachment",
          kind: "file",
          name: "report.pdf",
          path: "/reports/report.pdf",
          mime: "application/pdf",
          href: `${base}/tasks/cnv1_a/messages/msg2/attachments/1`,
        },
      ],
    }),
  ],
  has_older: false,
  ...extra,
});

const messagePage = (messages: unknown[], extra: Record<string, unknown> = {}) => ({
  task: header(),
  messages,
  has_more: false,
  ...extra,
});

async function open(
  browser: Page,
  handle: Parameters<typeof routeApi>[1],
  path = `${base}/tasks/cnv1_a`
) {
  await injectCsrfToken(browser);
  const requests = await routeApi(browser, (request) =>
    request.path === "/orgs/acme/context" ? ok(context) : handle(request)
  );
  await browser.goto(path);
  return requests;
}

const polls = (requests: RecordedRequest[]) =>
  requests.filter(
    (request) => request.method === "GET" && request.path === `${api}/messages`
  );

const thread = (browser: Page) => browser.getByRole("region", { name: "Conversation" });

/** Runs the clock in 30 s steps, letting each poll's reply land. */
async function pollSteps(browser: Page, steps: number) {
  for (let step = 0; step < steps; step += 1) {
    await browser.clock.runFor(30_100);
    await browser.waitForTimeout(150);
  }
}

test("shows the task, its thread and participants, and links back to Tasks in place", async ({
  page: browser,
}) => {
  await open(browser, (request) =>
    request.path === api
      ? ok(detail())
      : request.path === `${api}/messages`
        ? ok(messagePage([]))
        : undefined
  );

  const main = browser.getByRole("main");
  await expect(
    main.getByRole("heading", { level: 1, name: "Refund above the limit" })
  ).toBeVisible();
  await expect(main.getByText("Active", { exact: true })).toBeVisible();
  // The sidebar keeps Tasks current for one task.
  await expect(
    browser
      .getByRole("navigation", { name: "Organization navigation" })
      .getByRole("link", { name: "Tasks", exact: true })
  ).toHaveAttribute("aria-current", "page");

  const conversation = thread(browser);
  await expect(conversation.getByRole("strong")).toHaveText("approve");
  await expect(conversation.getByRole("link", { name: "policy" })).toHaveAttribute(
    "target",
    "_blank"
  );
  await expect(conversation.getByText("/reports/report.pdf")).toBeVisible();
  await expect(
    conversation.getByRole("link", { name: "Download report.pdf" })
  ).toHaveAttribute("href", `${base}/tasks/cnv1_a/messages/msg2/attachments/1`);

  const details = browser.getByRole("complementary", { name: "Task details" });
  await expect(
    details.getByRole("link", { name: "Billing specialist" })
  ).toHaveAttribute("href", `${base}/agents/a-1`);
  await expect(details.getByText("Slack thread")).toBeVisible();
  await expect(
    details.getByRole("link", { name: "Open the thread of Dana Ops" })
  ).toHaveAttribute("rel", "noopener noreferrer");
  await expect(details.getByText("This task does not repeat.")).toBeVisible();

  // Back to Tasks without a page load.
  await browser.evaluate(() => {
    (window as unknown as { marker: boolean }).marker = true;
  });
  await main.getByRole("link", { name: "Tasks", exact: true }).click();
  await expect(browser).toHaveURL(new RegExp(`${base}/tasks$`));
  expect(
    await browser.evaluate(() => (window as unknown as { marker?: boolean }).marker)
  ).toBe(true);
});

test("follows new messages with a cursor, once each, and stops polling a finished task later", async ({
  page: browser,
}) => {
  await browser.clock.install();
  let round = 0;
  const requests = await open(browser, (request) => {
    if (request.path === api) return ok(detail());
    if (request.path !== `${api}/messages`) return undefined;
    round += 1;
    // The second poll repeats a message it already returned.
    if (round === 1) return ok(messagePage([message(3)]));
    if (round === 2)
      return ok(
        messagePage([message(3), message(4)], {
          task: header({ status: "completed", terminal: true }),
        })
      );
    return ok(
      messagePage([], { task: header({ status: "completed", terminal: true }) })
    );
  });

  const conversation = thread(browser);
  await expect(conversation.getByText("Message 2")).toHaveCount(0);
  await expect(conversation.getByText("Report attached.")).toBeVisible();

  await browser.clock.runFor(3_100);
  await expect(conversation.getByText("Message 3")).toBeVisible();
  expect(polls(requests).map((request) => request.search)).toEqual(["?after=msg2"]);

  await browser.clock.runFor(3_100);
  await expect(conversation.getByText("Message 4")).toBeVisible();
  await expect(conversation.getByText("Message 3")).toHaveCount(1);
  await expect(
    browser.getByRole("main").getByText("Completed", { exact: true })
  ).toBeVisible();
  expect(polls(requests).at(-1)?.search).toBe("?after=msg3");

  // A completed task is followed for two minutes after its last new
  // message, then not at all.
  await pollSteps(browser, 8);
  const followed = polls(requests).length;
  expect(followed).toBeGreaterThan(2);
  await pollSteps(browser, 4);
  expect(polls(requests)).toHaveLength(followed);
});

test("a send on a finished task follows the reply that comes later", async ({
  page: browser,
}) => {
  await browser.clock.install();
  const done = { task: header({ status: "completed", terminal: true }) };
  let round = 0;
  const requests = await open(browser, (request) => {
    if (request.path === api) return ok(detail(done));
    if (request.path !== `${api}/messages`) return undefined;
    if (request.method === "POST")
      return { status: 201, body: { ok: true, data: { message_id: "msg3" } } };
    round += 1;
    if (round === 1) return ok(messagePage([message(3)], done));
    // The agent answers three polls later.
    if (round === 4) return ok(messagePage([message(5)], done));
    return ok(messagePage([], done));
  });

  const conversation = thread(browser);
  await expect(conversation.getByText("Report attached.")).toBeVisible();
  await pollSteps(browser, 2);
  expect(polls(requests)).toHaveLength(0);

  await browser
    .getByRole("textbox", { name: "Guidance for this task" })
    .fill("Reopen it.");
  await browser.getByRole("button", { name: "Send" }).click();
  await expect(conversation.getByText("Message 3")).toBeVisible();
  await pollSteps(browser, 3);
  await expect(conversation.getByText("Message 5")).toBeVisible();
  expect(
    polls(requests)
      .map((request) => request.search)
      .slice(0, 4)
  ).toEqual(["?after=msg2", "?after=msg3", "?after=msg3", "?after=msg3"]);
});

test("a cursor that left the conversation starts the thread over", async ({
  page: browser,
}) => {
  await browser.clock.install();
  const requests = await open(browser, (request) => {
    if (request.path === api) return ok(detail());
    if (request.path !== `${api}/messages`) return undefined;
    // msg2 is gone: polls after it stay empty, the latest page has new ids.
    if (request.search === "") return ok(messagePage([message(7), message(8)]));
    if (request.search === "?after=msg8") return ok(messagePage([message(9)]));
    return ok(messagePage([]));
  });

  const conversation = thread(browser);
  await expect(conversation.getByText("Report attached.")).toBeVisible();
  await pollSteps(browser, 11);
  await expect(conversation.getByText("Message 8")).toBeVisible();
  await expect(conversation.getByText("Report attached.")).toHaveCount(0);
  const searches = polls(requests).map((request) => request.search);
  expect(searches.slice(0, 10)).toEqual(Array(10).fill("?after=msg2"));
  expect(searches[10]).toBe("");

  await browser.clock.runFor(3_100);
  await expect(conversation.getByText("Message 9")).toBeVisible();
});

test("backs off while nothing changes and pauses while the tab is hidden", async ({
  page: browser,
}) => {
  await browser.clock.install();
  const requests = await open(browser, (request) =>
    request.path === api
      ? ok(detail())
      : request.path === `${api}/messages`
        ? ok(messagePage([]))
        : undefined
  );
  await expect(thread(browser).getByText("Report attached.")).toBeVisible();

  // Each wait starts once the previous reply has landed.
  const settle = async (count: number) => {
    await expect.poll(() => polls(requests).length).toBe(count);
    await browser.waitForTimeout(200);
  };
  await browser.clock.runFor(3_100); // the first poll after 3 s
  await settle(1);
  await browser.clock.runFor(5_800); // nothing changed: the next waits 6 s
  expect(polls(requests)).toHaveLength(1);
  await browser.clock.runFor(400);
  await settle(2);
  await browser.clock.runFor(11_600); // then 12 s
  expect(polls(requests)).toHaveLength(2);
  await browser.clock.runFor(600);
  await settle(3);

  await browser.evaluate(() => {
    Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await browser.clock.runFor(120_000);
  expect(polls(requests)).toHaveLength(3);

  // Visible again: it reads at once.
  await browser.evaluate(() => {
    Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await expect.poll(() => polls(requests).length).toBe(4);
});

test("steers the task: a failed send keeps the text and retries with the same request id", async ({
  page: browser,
}) => {
  let sends = 0;
  const requests = await open(browser, (request) => {
    if (request.path === api) return ok(detail());
    if (request.path === `${api}/messages` && request.method === "POST") {
      sends += 1;
      return sends === 1
        ? {
            status: 503,
            body: {
              ok: false,
              error: { code: "send_failed", message: "Could not send the message." },
            },
          }
        : { status: 201, body: { ok: true, data: { message_id: "msg3" } } };
    }
    if (request.path === `${api}/messages`)
      return ok(messagePage(sends > 1 ? [message(3)] : []));
    return undefined;
  });

  const composer = browser.getByRole("textbox", { name: "Guidance for this task" });
  await composer.fill("Please summarize the deployment.");
  await browser.getByRole("button", { name: "Send" }).click();
  await expect(browser.getByRole("alert")).toContainText("Could not send the message.");
  await expect(composer).toHaveValue("Please summarize the deployment.");

  // The draft survives a reload.
  await browser.reload();
  await expect(composer).toHaveValue("Please summarize the deployment.");

  await composer.press("ControlOrMeta+Enter");
  await expect(browser.getByText("Guidance added.")).toBeVisible();
  await expect(composer).toHaveValue("");
  await expect(thread(browser).getByText("Message 3")).toBeVisible();

  const sent = requests.filter((request) => request.method === "POST");
  expect(sent).toHaveLength(2);
  expect(sent[0]).toEqual(
    expect.objectContaining({
      csrf,
      body: {
        text: "Please summarize the deployment.",
        request_id: expect.any(String),
      },
    })
  );
  expect(sent[1]?.body).toEqual(
    expect.objectContaining({ request_id: expect.stringMatching(/^[0-9a-f-]{36}$/) })
  );

  await browser.reload();
  await expect(composer).toHaveValue("");
});

test("text typed while a message sends stays in the composer", async ({
  page: browser,
}) => {
  let release: (() => void) | undefined;
  const held = new Promise<void>((resolve) => {
    release = resolve;
  });
  const requests = await open(browser, async (request) => {
    if (request.path === api) return ok(detail());
    if (request.path === `${api}/messages` && request.method === "POST") {
      await held;
      return { status: 201, body: { ok: true, data: { message_id: "msg3" } } };
    }
    return request.path === `${api}/messages` ? ok(messagePage([])) : undefined;
  });

  const composer = browser.getByRole("textbox", { name: "Guidance for this task" });
  await composer.fill("First part.");
  await browser.getByRole("button", { name: "Send" }).click();
  await expect
    .poll(() => requests.some((request) => request.method === "POST"))
    .toBe(true);
  await composer.press("End");
  await composer.pressSequentially(" Second part.");
  release?.();

  await expect(browser.getByText("Guidance added.")).toBeVisible();
  await expect(composer).toHaveValue("Second part.");
  expect(requests.find((request) => request.method === "POST")?.body).toEqual(
    expect.objectContaining({ text: "First part." })
  );
  // The draft keeps only the unsent text.
  await browser.reload();
  await expect(composer).toHaveValue("Second part.");
});

test("a retry of the same draft reuses its request id", async ({ page: browser }) => {
  let sends = 0;
  const requests = await open(browser, (request) => {
    if (request.path === api) return ok(detail());
    if (request.path === `${api}/messages` && request.method === "POST") {
      sends += 1;
      return sends === 1
        ? {
            status: 503,
            body: {
              ok: false,
              error: { code: "send_failed", message: "Could not send the message." },
            },
          }
        : { status: 201, body: { ok: true, data: { message_id: "msg3" } } };
    }
    return request.path === `${api}/messages` ? ok(messagePage([])) : undefined;
  });
  const composer = browser.getByRole("textbox", { name: "Guidance for this task" });
  await composer.fill("Ship it.");
  await browser.getByRole("button", { name: "Send" }).click();
  await expect(browser.getByRole("alert")).toContainText("Could not send the message.");
  await browser.getByRole("button", { name: "Send" }).click();
  await expect(browser.getByText("Guidance added.")).toBeVisible();
  const [first, second] = requests
    .filter((request) => request.method === "POST")
    .map((request) => (request.body as { request_id: string }).request_id);
  expect(second).toBe(first);
});

test("pages in older messages when the reader scrolls up", async ({
  page: browser,
}) => {
  const latest = Array.from({ length: 30 }, (_, index) => message(index + 21));
  const requests = await open(browser, (request) => {
    if (request.path === api) return ok(detail({ messages: latest, has_older: true }));
    if (request.path !== `${api}/messages`) return undefined;
    if (request.search === "?before=msg21")
      return ok(
        messagePage(Array.from({ length: 20 }, (_, index) => message(index + 1)))
      );
    return ok(messagePage([]));
  });

  const conversation = thread(browser);
  await expect(conversation.getByText("Message 50", { exact: true })).toBeVisible();
  await conversation.getByText("Message 21", { exact: true }).scrollIntoViewIfNeeded();
  await expect(conversation.getByText("Message 1", { exact: true })).toBeAttached();
  expect(requests.some((request) => request.search === "?before=msg21")).toBe(true);
  // Message 21 stays where the reader left it rather than jumping away.
  await expect(conversation.getByText("Message 21", { exact: true })).toBeInViewport();
});

test("an empty older page ends paging and the end stays followed", async ({
  page: browser,
}) => {
  await browser.clock.install();
  const latest = Array.from({ length: 30 }, (_, index) => message(index + 21));
  let replied = false;
  const requests = await open(browser, (request) => {
    if (request.path === api) return ok(detail({ messages: latest, has_older: true }));
    if (request.path !== `${api}/messages`) return undefined;
    if (request.search === "?before=msg21") return ok(messagePage([]));
    return ok(messagePage(replied ? [message(51)] : []));
  });

  const conversation = thread(browser);
  await expect(conversation.getByText("Message 50", { exact: true })).toBeVisible();
  await conversation.getByText("Message 21", { exact: true }).scrollIntoViewIfNeeded();
  await expect
    .poll(() => requests.some((request) => request.search === "?before=msg21"))
    .toBe(true);
  await browser.waitForTimeout(200);

  // The reader goes back to the end; a new message keeps it in view.
  await browser
    .locator(".bft-task-scroll")
    .evaluate((element) => element.scrollTo({ top: element.scrollHeight }));
  await browser.waitForTimeout(100);
  replied = true;
  await browser.clock.runFor(3_100);
  await expect(conversation.getByText("Message 51", { exact: true })).toBeInViewport();
  expect(requests.filter((request) => request.search === "?before=msg21")).toHaveLength(
    1
  );
});

test("marks a reviewed task complete, and a changed one asks for another look", async ({
  page: browser,
}) => {
  let accepts = 0;
  const requests = await open(browser, (request) => {
    if (request.path === api)
      return ok(
        detail({
          task: header({
            status: "ready_for_review",
            review_version: 1_780_000_000_000,
          }),
        })
      );
    if (request.path === `${api}/review`) {
      accepts += 1;
      return accepts === 1
        ? {
            status: 409,
            body: {
              ok: false,
              error: {
                code: "review_changed",
                message: "The task changed. Review it again before completing it.",
              },
            },
          }
        : ok({ task: header({ status: "completed", terminal: true }) });
    }
    return request.path === `${api}/messages`
      ? ok(
          messagePage([], {
            task: header({
              status: "ready_for_review",
              review_version: 1_780_000_000_000,
            }),
          })
        )
      : undefined;
  });

  const main = browser.getByRole("main");
  await expect(main.getByText("Ready for review", { exact: true })).toBeVisible();
  await main.getByRole("button", { name: "Mark complete" }).click();
  await expect(browser.getByRole("alert")).toContainText("Review it again");

  await main.getByRole("button", { name: "Mark complete" }).click();
  await expect(main.getByText("Completed", { exact: true })).toBeVisible();
  await expect(main.getByRole("button", { name: "Mark complete" })).toHaveCount(0);
  expect(requests.filter((request) => request.path === `${api}/review`).at(-1)).toEqual(
    expect.objectContaining({ csrf, body: { review_version: 1_780_000_000_000 } })
  );
});

test("adds, changes and deletes the task's schedule", async ({ page: browser }) => {
  let schedule: Record<string, unknown> = noSchedule;
  const requests = await open(browser, (request) => {
    if (request.path === api) return ok(detail({ schedule }));
    if (request.path === `${api}/schedule/preview`)
      return ok({
        recurrence: request.search.includes("mode=interval")
          ? "Every 30 minutes"
          : "Every Wednesday at 6:30 PM (Asia/Shanghai)",
      });
    if (request.path === `${api}/schedule` && request.method === "PUT") {
      const body = request.body as Record<string, string>;
      schedule =
        body.mode === "interval"
          ? { ...hourly, recurrence: "Every 30 minutes", form: body }
          : {
              status: "ok",
              recurrence: "Every Wednesday at 6:30 PM (Asia/Shanghai)",
              command: body.command,
              form: body,
            };
      return ok({ task: header({ scheduled: true }), schedule });
    }
    if (request.path === `${api}/schedule` && request.method === "DELETE") {
      schedule = noSchedule;
      return ok({ task: header(), schedule });
    }
    return request.path === `${api}/messages` ? ok(messagePage([])) : undefined;
  });

  const details = browser.getByRole("complementary", { name: "Task details" });
  await details.getByRole("button", { name: "Add schedule" }).click();
  const dialog = browser.getByRole("dialog", { name: "Add schedule" });
  await dialog.getByRole("radio", { name: "Repeat after a duration" }).check();
  await dialog.getByLabel("Repeat every").fill("30");
  await dialog.getByRole("button", { name: "Unit" }).click();
  await browser.getByRole("option", { name: "Minutes" }).click();
  await expect(dialog.getByText("Every 30 minutes")).toBeVisible();
  await dialog.getByLabel("Command").fill("Inspect the refunds.");
  await dialog.getByRole("button", { name: "Save schedule" }).click();

  await expect(browser.getByText("Task schedule saved.")).toBeVisible();
  await expect(details.getByText("Every 30 minutes")).toBeVisible();
  await expect(details.getByText("Inspect the refunds.")).toBeVisible();
  await expect(
    browser.getByRole("main").getByText("Scheduled", { exact: true })
  ).toBeVisible();

  await details.getByRole("button", { name: "Edit" }).click();
  const edit = browser.getByRole("dialog", { name: "Edit schedule" });
  await expect(edit.getByLabel("Repeat every")).toHaveValue("30");
  await edit.getByRole("radio", { name: "At a fixed time" }).check();
  await edit.getByLabel("Cron expression").fill("30 18 * * 3");
  await edit.getByLabel("Time zone").fill("Asia/Shanghai");
  await expect(
    edit.getByText("Every Wednesday at 6:30 PM (Asia/Shanghai)")
  ).toBeVisible();
  await edit.getByRole("button", { name: "Save schedule" }).click();
  await expect(
    details.getByText("Every Wednesday at 6:30 PM (Asia/Shanghai)")
  ).toBeVisible();

  await details.getByRole("button", { name: "Delete schedule" }).click();
  await browser
    .getByRole("dialog", { name: "Delete schedule" })
    .getByRole("button", { name: "Delete" })
    .click();
  await expect(details.getByText("This task does not repeat.")).toBeVisible();
  await expect(details.getByRole("button", { name: "Add schedule" })).toBeVisible();

  const writes = requests.filter((request) => request.method !== "GET");
  expect(writes.map((request) => [request.method, request.csrf])).toEqual([
    ["PUT", csrf],
    ["PUT", csrf],
    ["DELETE", csrf],
  ]);
  expect(writes[0]?.body).toEqual(
    expect.objectContaining({
      mode: "interval",
      interval_value: "30",
      interval_unit: "minutes",
      command: "Inspect the refunds.",
    })
  );
  expect(writes[1]?.body).toEqual(
    expect.objectContaining({
      mode: "cron",
      cron: "30 18 * * 3",
      timezone: "Asia/Shanghai",
    })
  );
});

test("a swarm member reads the schedule without write controls", async ({
  page: browser,
}) => {
  await open(browser, (request) =>
    request.path === api
      ? ok(
          detail({
            project: { ...project, role: "user" },
            schedule: hourly,
            task: header({ scheduled: true }),
          })
        )
      : request.path === `${api}/messages`
        ? ok(messagePage([]))
        : undefined
  );
  const details = browser.getByRole("complementary", { name: "Task details" });
  await expect(details.getByText("Every hour")).toBeVisible();
  await expect(details.getByRole("button", { name: "Edit" })).toHaveCount(0);
  await expect(details.getByRole("button", { name: "Delete schedule" })).toHaveCount(0);
  // Steering is open to every swarm member.
  await expect(
    browser.getByRole("textbox", { name: "Guidance for this task" })
  ).toBeVisible();
});

test("a missing task says so with a way back to Tasks", async ({ page: browser }) => {
  await open(browser, (request) =>
    request.path === api
      ? {
          status: 404,
          body: {
            ok: false,
            error: { code: "task_not_found", message: "Task not found." },
          },
        }
      : undefined
  );
  const main = browser.getByRole("main");
  await expect(main.getByRole("heading", { name: "Task not found" })).toBeVisible();
  await expect(main.getByRole("link", { name: "Back to tasks" })).toHaveAttribute(
    "href",
    `${base}/tasks`
  );
});

test("fits 900px wide without sideways scrolling", async ({ page: browser }) => {
  await browser.setViewportSize({ width: 900, height: 700 });
  await open(browser, (request) =>
    request.path === api
      ? ok(
          detail({
            task: header({
              title:
                "A very long task title that keeps going to check that the heading never widens the page at all",
            }),
            schedule: hourly,
          })
        )
      : request.path === `${api}/messages`
        ? ok(messagePage([]))
        : undefined
  );
  await expect(
    browser.getByRole("main").getByRole("heading", { level: 1 })
  ).toBeVisible();
  expect(
    await browser.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth
    )
  ).toBeLessThanOrEqual(0);
});
