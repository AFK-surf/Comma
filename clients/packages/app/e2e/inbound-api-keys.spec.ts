import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

// Settings › System › Inbound API: the keys that let an external service post
// to the workspace Router (docs/product-features.md). The
// plaintext is shown once, right after creation, and never again.
test("creates, disables and deletes an inbound API key, showing the secret once", async ({
  page,
}, testInfo) => {
  const base = "http://127.0.0.1:65534";
  await installBrowserTestSession(page, {
    apiBaseUrl: base,
    email: "inbound@example.com",
    token: "comma_sess_inbound",
    userId: "usr_inbound",
  });

  const secret = "salix_gk_e2eSecretValueThatIsShownOnce";
  const postMessageUrl =
    "https://salix.example.test/v1/agent-groups/grp_inbound/router/post-message";
  let key:
    | {
        key_id: string;
        name: string;
        prefix: string;
        status: "active" | "disabled";
        created_by: string;
        created_at: number;
        post_message_url: string;
      }
    | undefined;
  const writes: { method: string; path: string; body: unknown }[] = [];

  await page.route(`${base}/v1/comma/workspaces**`, async (route) => {
    const req = route.request();
    const path = new URL(req.url()).pathname;
    const headers = {
      "access-control-allow-origin": req.headers().origin ?? "http://127.0.0.1:4173",
      "access-control-allow-credentials": "true",
      "access-control-allow-headers":
        "authorization,content-type,x-comma-session-transport",
      "access-control-allow-methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
      "content-type": "application/json",
    };
    const respond = (body: unknown, status = 200) =>
      route.fulfill({ headers, status, body: JSON.stringify(body) });
    if (req.method() === "OPTIONS") {
      await route.fulfill({ headers, status: 204 });
      return;
    }
    if (path === "/v1/comma/workspaces") {
      await respond({
        data: [{ id: "wsp_inbound", group_id: "grp_inbound", name: "Workspace" }],
      });
      return;
    }
    if (!path.includes("/router-api-keys")) {
      await respond({ data: [] });
      return;
    }
    if (req.method() === "GET") {
      await respond(key ? [key] : []);
      return;
    }
    const body = req.method() === "DELETE" ? undefined : req.postDataJSON();
    writes.push({ method: req.method(), path, body });
    if (req.method() === "POST") {
      key = {
        key_id: "gak_e2e",
        name: body.name,
        prefix: secret.slice(0, 15),
        status: "active",
        created_by: "comma_user:usr_inbound",
        created_at: 1_700_000_000,
        post_message_url: postMessageUrl,
      };
      await respond({ ...key, key: secret }, 201);
      return;
    }
    if (req.method() === "PATCH" && key) {
      key = { ...key, ...body };
      await respond(key);
      return;
    }
    if (req.method() === "DELETE") {
      key = undefined;
      await respond({ deleted: true });
      return;
    }
    await respond({ error: "not_found" }, 404);
  });

  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Inbound API", exact: true }).click();
  await expect(
    page.getByText("No inbound API keys yet.", { exact: true })
  ).toBeVisible();

  await page.getByRole("button", { name: "New key", exact: true }).click();
  const create = page.getByRole("dialog", { name: "New key", exact: true });
  await expect(
    create.getByRole("button", { name: "Create key", exact: true })
  ).toBeDisabled();
  await create.getByRole("textbox", { name: "Name", exact: true }).fill("Zendesk");
  await create.getByRole("button", { name: "Create key", exact: true }).click();

  // The one-time panel carries the plaintext and a ready-to-paste command whose
  // URL is the server-supplied posting endpoint, not this app's API host.
  const created = page.getByTestId("inbound-api-created");
  await expect(created).toBeVisible();
  await expect(page.getByTestId("inbound-api-secret")).toHaveText(secret);
  await expect(created).toContainText(`curl -X POST ${postMessageUrl}`);
  expect(writes[0]).toEqual({
    method: "POST",
    path: "/v1/comma/workspaces/wsp_inbound/router-api-keys",
    body: { name: "Zendesk" },
  });
  await page.screenshot({
    animations: "disabled",
    path: testInfo.outputPath("inbound-api-created.png"),
  });

  await created.getByRole("button", { name: "Done", exact: true }).click();
  await expect(page.getByTestId("inbound-api-created")).toHaveCount(0);
  await expect(page.getByText(secret)).toHaveCount(0);

  const row = page.getByTestId("inbound-api-key-gak_e2e");
  await expect(row).toContainText("Zendesk");
  await expect(row).toContainText("Active");

  await row.getByRole("button", { name: "Key actions", exact: true }).click();
  await page.getByRole("menuitem", { name: "Disable key", exact: true }).click();
  await expect(row).toContainText("Disabled");
  expect(writes[1]).toEqual({
    method: "PATCH",
    path: "/v1/comma/workspaces/wsp_inbound/router-api-keys/gak_e2e",
    body: { status: "disabled" },
  });

  await row.getByRole("button", { name: "Key actions", exact: true }).click();
  await page.getByRole("menuitem", { name: "Delete key", exact: true }).click();
  await page
    .getByRole("dialog", { name: "Delete this inbound API key?", exact: true })
    .getByRole("button", { name: "Delete key", exact: true })
    .click();
  await expect(
    page.getByText("No inbound API keys yet.", { exact: true })
  ).toBeVisible();
  expect(writes[2]).toMatchObject({
    method: "DELETE",
    path: "/v1/comma/workspaces/wsp_inbound/router-api-keys/gak_e2e",
  });
});
