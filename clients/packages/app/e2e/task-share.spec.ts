import { expect, test, type Route } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

const token = "T".repeat(43);
const shareApi = "https://share-api.comma.test";
const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
  "base64"
);

test("a Task owner previews a Task, then creates, copies, and stops its public link", async ({
  context,
  page,
}) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  const reply = "The quarterly report is ready.";
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskAssistantReply: reply,
    taskStatus: "active",
  });
  const shareUrl = `http://127.0.0.1:4173/s/${token}`;
  const calls: string[] = [];
  let shared = false;

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-share@comma.local",
      token: "comma_sess_task_share",
    });
    await page.route(
      `${stub.baseUrl}/v1/comma/groups/*/conversations/*/share`,
      async (route) => {
        const request = route.request();
        const method = request.method();
        const headers = await request.allHeaders();
        const cors = {
          "access-control-allow-origin": headers.origin ?? "*",
          "access-control-allow-credentials": "true",
        };
        if (method === "OPTIONS") {
          return route.fulfill({
            status: 204,
            headers: {
              ...cors,
              "access-control-allow-methods": "GET,PUT,DELETE,OPTIONS",
              "access-control-allow-headers":
                headers["access-control-request-headers"] ?? "content-type",
            },
          });
        }
        calls.push(method);
        if (method === "PUT") shared = true;
        if (method === "DELETE") shared = false;
        if (method === "DELETE") return json(route, 200, { revoked: true }, cors);
        if (!shared) return json(route, 404, { error: "not_found" }, cors);
        return json(
          route,
          200,
          {
            url: shareUrl,
            created_at: 1_790_100_000,
            shared_at: 1_790_100_000,
            message_count: 4,
            artifact_count: 2,
            has_newer_messages: false,
          },
          cors
        );
      }
    );

    await page.goto(
      `/#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    await page.getByTestId("task-share-button").click();
    const title = chatSmokeTaskConversation.title;
    // The dialog names the Task and previews its conversation.
    await expect(
      page
        .getByRole("dialog", { name: `Share “${title}”` })
        .getByRole("region", { name: title })
    ).toContainText(reply);
    const dialog = page.getByTestId("task-share-dialog");
    await dialog.getByRole("button", { name: "Create public link" }).click();

    await expect(dialog.getByTestId("task-share-url")).toHaveValue(shareUrl);
    // Creating removes the pressed button, so Copy link takes the focus.
    const copy = dialog.getByRole("button", { name: "Copy link" });
    await expect(copy).toBeFocused();
    await expect(dialog.getByText("2 files are public.")).toBeVisible();
    await copy.click();
    await expect
      .poll(() => page.evaluate(() => navigator.clipboard.readText()))
      .toBe(shareUrl);
    await expect(dialog.getByRole("button", { name: "Link copied" })).toBeVisible();

    await dialog.getByRole("button", { name: "Link actions" }).click();
    await page.getByRole("menuitem", { name: "Stop sharing" }).click();
    await expect(
      dialog.getByRole("button", { name: "Create public link" })
    ).toBeFocused();
    expect(calls).toEqual(["GET", "PUT", "DELETE"]);
  } finally {
    await stub.close();
  }
});

/** One entry of the owner's `task-shares` list. */
const share = (id: string, title: string, files: number, sharedAt: number) => ({
  conversation: {
    id,
    kind: "agent_task",
    title,
    status: "completed",
    group_id: chatSmokeWorkspace.group_id,
  },
  url: `http://127.0.0.1:4173/s/${id.padEnd(43, "T").slice(0, 43)}`,
  created_at: sharedAt,
  shared_at: sharedAt,
  message_count: 3,
  artifact_count: files,
});

test("Settings lists the shared Tasks and stops a link", async ({ page }) => {
  const stub = await startChatSmokeStub({ includeTaskInInbox: true });
  let shares = [
    share("cnv_launch_notes", "Launch notes", 0, 1_790_200_000),
    share(chatSmokeTaskConversation.id, "Quarterly report", 2, 1_790_100_000),
  ];
  const revoked: string[] = [];

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-share-list@comma.local",
      token: "comma_sess_task_share_list",
    });
    await page.route(
      (url) => url.pathname.endsWith("/task-shares") || url.pathname.endsWith("/share"),
      async (route) => {
        const request = route.request();
        const headers = await request.allHeaders();
        const cors = {
          "access-control-allow-origin": headers.origin ?? "*",
          "access-control-allow-credentials": "true",
        };
        if (request.method() === "OPTIONS") {
          return route.fulfill({
            status: 204,
            headers: {
              ...cors,
              "access-control-allow-methods": "GET,DELETE,OPTIONS",
              "access-control-allow-headers":
                headers["access-control-request-headers"] ?? "content-type",
            },
          });
        }
        if (request.method() === "DELETE") {
          const id = new URL(request.url()).pathname.split("/").at(-2)!;
          revoked.push(id);
          shares = shares.filter((entry) => entry.conversation.id !== id);
          return json(route, 200, { revoked: true }, cors);
        }
        return json(
          route,
          200,
          { data: shares, has_more: false, next_cursor: null },
          cors
        );
      }
    );

    await page.goto("/#/settings?category=shared-tasks");
    const launch = page.locator('[data-setting-id="shared-task.cnv_launch_notes"]');
    const report = page.locator(
      `[data-setting-id="shared-task.${chatSmokeTaskConversation.id}"]`
    );
    // Most recently shared first, each with its public files.
    await expect(launch).toContainText("Launch notes");
    await expect(report).toContainText("Quarterly report");
    await expect(report).toContainText("2 files are public.");
    expect(
      await page
        .locator('[data-setting-id^="shared-task."]')
        .evaluateAll((rows) => rows.map((row) => row.getAttribute("data-setting-id")))
    ).toEqual([
      "shared-task.cnv_launch_notes",
      `shared-task.${chatSmokeTaskConversation.id}`,
    ]);

    await launch.getByRole("button", { name: "Stop sharing" }).click();
    await expect(launch).toHaveCount(0);
    expect(revoked).toEqual(["cnv_launch_notes"]);

    await report.getByRole("button", { name: "Stop sharing" }).click();
    await expect(page.getByText("No shared tasks", { exact: true })).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("a public link shows the shared Task and its files without a Comma session", async ({
  context,
  page,
}) => {
  const requests: { path: string; cookie: string | undefined }[] = [];
  // A Comma session cookie for the API origin must never reach public reads.
  await context.addCookies([
    {
      name: "comma_session",
      value: "private",
      domain: "share-api.comma.test",
      path: "/",
    },
  ]);
  await page.addInitScript((baseUrl) => {
    localStorage.setItem("comma.apiBaseUrl", baseUrl);
  }, shareApi);

  await page.route(`${shareApi}/v1/comma/public/shares/**`, async (route) => {
    const url = new URL(route.request().url());
    const path = url.pathname.replace(`/v1/comma/public/shares/${token}`, "");
    requests.push({ path, cookie: (await route.request().allHeaders()).cookie });
    if (path === "") {
      return json(route, 200, {
        title: "Quarterly report",
        shared_at: 1_790_100_000,
        message_count: 3,
        artifacts: [
          {
            type: "file",
            seq: 3,
            index: 1,
            file_name: "report.csv",
            mime_type: "text/csv",
            size: 11,
          },
          {
            type: "image",
            seq: 5,
            index: 0,
            file_name: "chart.png",
            mime_type: "image/png",
            size: png.length,
          },
        ],
        artifacts_truncated: false,
      });
    }
    if (path === "/messages" && url.searchParams.get("after_seq") === "0") {
      return json(route, 200, {
        messages: [
          {
            seq: 1,
            role: "user",
            created_at: 1,
            content: [{ type: "text", text: "Summarize Q3." }],
          },
          {
            seq: 3,
            role: "assistant",
            created_at: 2,
            content: [
              { type: "text", text: "Here is the **report**." },
              {
                type: "file",
                index: 1,
                file_name: "report.csv",
                mime_type: "text/csv",
                size: 11,
              },
            ],
          },
        ],
        next_after_seq: 3,
      });
    }
    if (path === "/messages") {
      return json(route, 200, {
        messages: [
          {
            seq: 5,
            role: "assistant",
            created_at: 3,
            content: [
              {
                type: "image",
                index: 0,
                file_name: "chart.png",
                mime_type: "image/png",
                size: png.length,
              },
            ],
          },
        ],
        next_after_seq: null,
      });
    }
    if (path === "/attachments/3/1") {
      return route.fulfill({
        status: 200,
        contentType: "text/csv",
        body: "a,b\n1,2\n",
      });
    }
    if (path === "/attachments/5/0") {
      return route.fulfill({ status: 200, contentType: "image/png", body: png });
    }
    return json(route, 404, { error: "not_found" });
  });

  await page.goto(`/s/${token}`);
  await expect(page.getByRole("heading", { name: "Quarterly report" })).toBeVisible();
  await expect(page).toHaveTitle("Quarterly report");
  const thread = page.getByTestId("share-view-thread");
  await expect(thread.getByText("Summarize Q3.")).toBeVisible();
  await expect(thread.locator("strong", { hasText: "report" })).toBeVisible();

  const files = page.getByRole("complementary", { name: "Files" });
  await expect(files.getByTestId("share-view-artifact")).toHaveCount(2);
  const download = page.waitForEvent("download");
  await files.getByRole("button", { name: "Preview report.csv" }).click();
  expect((await download).suggestedFilename()).toBe("report.csv");
  // The thread's own file card downloads through the same public route.
  const threadDownload = page.waitForEvent("download");
  await thread.getByRole("button", { name: "Preview report.csv" }).click();
  expect((await threadDownload).suggestedFilename()).toBe("report.csv");

  await thread.getByRole("button", { name: "Load more" }).click();
  await expect(thread.getByRole("img", { name: "chart.png" })).toBeVisible();
  await expect(thread.getByRole("button", { name: "Load more" })).toHaveCount(0);

  expect(requests.length).toBeGreaterThan(0);
  expect(requests.every((request) => request.cookie === undefined)).toBe(true);
});

test("a stopped or unknown public link says it is not available", async ({ page }) => {
  await page.addInitScript((baseUrl) => {
    localStorage.setItem("comma.apiBaseUrl", baseUrl);
  }, shareApi);
  await page.route(`${shareApi}/v1/comma/public/shares/**`, (route) =>
    json(route, 404, { error: "not_found" })
  );

  await page.goto(`/s/${token}`);
  await expect(
    page.getByRole("heading", { name: "This link is not available" })
  ).toBeVisible();
});

function json(
  route: Route,
  status: number,
  body: unknown,
  headers: Record<string, string> = { "access-control-allow-origin": "*" }
) {
  return route.fulfill({
    status,
    contentType: "application/json",
    headers,
    body: JSON.stringify(body),
  });
}
