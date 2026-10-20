import { expect, test, type Route } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

const corsHeaders = (origin: string | undefined) => ({
  "access-control-allow-origin": origin ?? "http://127.0.0.1:4173",
  "access-control-allow-credentials": "true",
  "access-control-allow-headers":
    "authorization,content-type,x-comma-session-transport",
  "access-control-allow-methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
  "content-type": "application/json",
});

// Settings › Work › Condensed Workspace, shown from Settings › Debug: the owner
// turns on the Group's shared list of current facts and edits its statements
// (docs/agent-runtime.md).
test("shows the Condensed Workspace from Debug, then adds, edits and removes a statement", async ({
  page,
}) => {
  const base = "http://127.0.0.1:65534";
  await installBrowserTestSession(page, {
    apiBaseUrl: base,
    email: "condensed@example.com",
    token: "comma_sess_condensed",
    userId: "usr_condensed",
  });

  let state = {
    enabled: false,
    revision: 0,
    statements: [] as { id: string; text: string }[],
    bytes: 0,
    recommended_max_bytes: 4096,
    max_bytes: 16384,
  };
  let nextId = 1;
  const writes: { method: string; path: string; body: unknown }[] = [];

  const handler = async (route: Route) => {
    const req = route.request();
    const path = new URL(req.url()).pathname;
    const headers = corsHeaders(req.headers().origin);
    const respond = (body: unknown, status = 200) =>
      route.fulfill({ headers, status, body: JSON.stringify(body) });
    if (req.method() === "OPTIONS") {
      await route.fulfill({ headers, status: 204 });
      return;
    }
    if (path === "/v1/comma/workspaces") {
      await respond({
        data: [{ id: "wsp_condensed", group_id: "grp_condensed", name: "Workspace" }],
      });
      return;
    }
    const prefix = "/v1/comma/groups/grp_condensed/condensed-workspace";
    if (!path.startsWith(prefix)) {
      await respond({ data: [] });
      return;
    }
    if (req.method() === "GET") {
      await respond(state);
      return;
    }
    const body = req.postDataJSON();
    writes.push({ method: req.method(), path: path.slice(prefix.length), body });
    if (path === `${prefix}/settings`) {
      state = { ...state, enabled: body.enabled };
    } else {
      let statements = state.statements;
      for (const op of body.operations) {
        if (op.op === "add")
          statements = [...statements, { id: `s${nextId++}`, text: op.text }];
        if (op.op === "replace")
          statements = statements.map((s) =>
            s.id === op.id ? { ...s, text: op.text } : s
          );
        if (op.op === "remove") statements = statements.filter((s) => s.id !== op.id);
      }
      const bytes = statements.reduce(
        (sum, s) => sum + `- [${s.id}] ${s.text}\n`.length,
        0
      );
      state = { ...state, revision: state.revision + 1, statements, bytes };
    }
    await respond(state);
  };
  await page.route(`${base}/v1/comma/workspaces**`, handler);
  await page.route(
    `${base}/v1/comma/groups/grp_condensed/condensed-workspace**`,
    handler
  );

  await page.goto("/#/settings");
  // The category stays hidden until Settings › Debug shows it.
  const category = page.getByRole("button", {
    name: "Condensed Workspace",
    exact: true,
  });
  await expect(category).toHaveCount(0);
  await page.getByRole("button", { name: "Debug", exact: true }).click();
  await page
    .locator(
      '[data-setting-id="debug.condensed-workspace.visible"] [data-slot="toggle-base"]'
    )
    .click();
  await category.click();

  const toggle = page.getByRole("switch", {
    name: "Share current facts with all Agents",
  });
  await expect(toggle).toBeEnabled();
  await page
    .locator(
      '[data-setting-id="condensed-workspace.enabled"] [data-slot="toggle-base"]'
    )
    .click();
  await expect(toggle).toBeChecked();
  await expect(page.getByText("No statements yet.", { exact: true })).toBeVisible();

  await page.getByRole("button", { name: "Add statement", exact: true }).click();
  await page
    .getByRole("textbox", { name: "Statement" })
    .fill("The launch is on Friday.");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(
    page.getByText("The launch is on Friday.", { exact: true })
  ).toBeVisible();

  await page.getByRole("button", { name: "Statement actions" }).click();
  await page.getByRole("menuitem", { name: "Edit statement" }).click();
  await page
    .getByRole("textbox", { name: "Statement" })
    .fill("The launch is on Tuesday.");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(
    page.getByText("The launch is on Tuesday.", { exact: true })
  ).toBeVisible();

  await page.getByRole("button", { name: "Statement actions" }).click();
  await page.getByRole("menuitem", { name: "Remove" }).click();
  await expect(page.getByText("No statements yet.", { exact: true })).toBeVisible();

  expect(writes).toEqual([
    { method: "PUT", path: "/settings", body: { enabled: true } },
    {
      method: "POST",
      path: "/operations",
      body: { operations: [{ op: "add", text: "The launch is on Friday." }] },
    },
    {
      method: "POST",
      path: "/operations",
      body: {
        operations: [{ op: "replace", id: "s1", text: "The launch is on Tuesday." }],
      },
    },
    {
      method: "POST",
      path: "/operations",
      body: { operations: [{ op: "remove", id: "s1" }] },
    },
  ]);
});
