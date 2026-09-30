import { expect, test, type Page } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeWorkspace, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

const plugin = {
  brand: "linear",
  category: "Integrations",
  description: "Plan product work",
  id: "linear",
  installed: false,
  locked: false,
  mcps: [],
  name: "Linear",
  skills: [],
  summary: "Plan product work",
};

async function setup(page: Page) {
  const stub = await startChatSmokeStub();
  await installBrowserTestSession(page, {
    apiBaseUrl: stub.baseUrl,
    email: "plugin-install@comma.local",
    token: "comma_sess_plugin_install",
  });
  await page.route(`**/v1/comma/workspaces/${chatSmokeWorkspace.id}/plugins`, (route) =>
    route.fulfill({ json: { data: [plugin] } })
  );
  return stub;
}

test("Add returns Home only after installation is confirmed", async ({ page }) => {
  const stub = await setup(page);
  let finish!: () => void;
  const response = new Promise<void>((resolve) => {
    finish = resolve;
  });
  try {
    await page.route("**/plugins/linear/install", async (route) => {
      await response;
      await route.fulfill({
        json: { authorization: null, plugin: { ...plugin, installed: true } },
      });
    });
    await page.goto("/#/plugins");
    await page.getByRole("button", { name: "Add Linear", exact: true }).click();
    await expect(
      page.getByRole("button", { name: "Add Linear", exact: true })
    ).toBeDisabled();
    await expect(page).toHaveURL(/#\/plugins$/);
    finish();
    await expect(page).toHaveURL(/#\/$/);
    await expect(page.getByRole("region", { name: "Comma assistant" })).toBeVisible();
  } finally {
    finish?.();
    await stub.close();
  }
});

test("pending authorization survives leaving Plugins and returning", async ({
  page,
}) => {
  const stub = await setup(page);
  const checks: string[] = [];
  let authorized = false;
  try {
    await page.route("**/plugins/linear/install", async (route) => {
      const body = route.request().postDataJSON();
      if (body.verify_only) checks.push(body.authorization_state);
      await route.fulfill({
        json:
          authorized && body.verify_only
            ? { authorization: null, plugin: { ...plugin, installed: true } }
            : { authorization: { state: "pending-linear" }, plugin },
      });
    });
    await page.goto("/#/plugins");
    await page.getByRole("button", { name: "Add Linear", exact: true }).click();
    await expect(
      page.getByRole("button", { name: "Add Linear", exact: true })
    ).toBeEnabled();
    await page.getByRole("link", { name: "Home", exact: true }).click();
    await expect.poll(() => checks.length).toBeGreaterThan(0);
    await page.getByRole("link", { name: "Plugins", exact: true }).click();
    authorized = true;
    await expect(page).toHaveURL(/#\/$/);
    expect(checks.every((state) => state === "pending-linear")).toBe(true);
  } finally {
    await stub.close();
  }
});

test("a stalled initial Add releases its button and a retry can finish", async ({
  page,
}) => {
  const stub = await setup(page);
  let attempts = 0;
  try {
    await page.clock.install();
    await page.route("**/plugins/linear/install", async (route) => {
      attempts += 1;
      if (attempts === 1) return; // Leave the first network response unresolved.
      await route.fulfill({
        json: { authorization: null, plugin: { ...plugin, installed: true } },
      });
    });
    await page.goto("/#/plugins");
    await page.getByRole("button", { name: "Add Linear", exact: true }).click();
    await expect.poll(() => attempts).toBe(1);
    await page.clock.fastForward(31_000);
    await expect(
      page.getByText("The connection request timed out. Try adding the plugin again.")
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Add Linear", exact: true })
    ).toBeEnabled();
    await page.getByRole("button", { name: "Add Linear", exact: true }).click();
    await expect(page).toHaveURL(/#\/$/);
    expect(attempts).toBe(2);
  } finally {
    await stub.close();
  }
});

test("an installed account is confirmed in Plugins before personal use", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  await installBrowserTestSession(page, {
    apiBaseUrl: stub.baseUrl,
    email: "plugin-confirm@comma.local",
    token: "comma_sess_plugin_confirm",
  });

  const slack = {
    ...plugin,
    id: "slack",
    name: "Slack",
    brand: "slack",
    installed: true,
  };
  let selectedAccountId: string | null = null;
  const requests: string[] = [];

  try {
    await page.route(
      `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/plugins`,
      (route) => route.fulfill({ json: { data: [slack] } })
    );
    await page.route("**/plugins/slack/personal-sources", (route) =>
      route.fulfill({
        json: {
          pluginId: "slack",
          sources: [
            {
              connectionId: "slack-composio",
              toolkit: "slack",
              kind: "composio",
              state: selectedAccountId ? "ready" : "needs_confirmation",
              selectedAccountId,
              candidates: [{ id: "ca_old0001" }, { id: "ca_new0002" }],
            },
          ],
        },
      })
    );
    await page.route("**/plugins/slack/personal-sources/prepare", async (route) => {
      const body = route.request().postDataJSON();
      requests.push(`prepare:${body.connection_id}`);
      await route.fulfill({
        json: {
          state: "confirm-old",
          toolkit: "slack",
          connectionId: body.connection_id,
          identity: "member · team",
        },
      });
    });
    await page.route("**/plugins/slack/personal-sources/confirm", async (route) => {
      const body = route.request().postDataJSON();
      requests.push(`confirm:${body.state}`);
      selectedAccountId = "ca_old0001";
      await route.fulfill({
        json: { state: "ready", toolkit: "slack", connectionId: "ca_old0001" },
      });
    });

    await page.goto("/#/plugins");
    await page.getByRole("button", { name: "View Slack plugin details" }).click();
    await expect(page.getByText("Choose an account", { exact: true })).toBeVisible();
    await page.getByRole("button", { name: "Check account ending in 0001" }).click();
    await expect(page.getByText(/member · team/)).toBeVisible();
    await page.getByRole("button", { name: "Use this account" }).click();
    await expect(page.getByText("Ready", { exact: true })).toBeVisible();
    // The confirmed account is no longer offered; the newer one is a switch.
    await expect(
      page.getByRole("button", { name: "Switch to account ending in 0002" })
    ).toBeVisible();
    await expect(page.getByRole("button", { name: /ending in 0001/ })).toHaveCount(0);
    expect(requests).toEqual(["prepare:ca_old0001", "confirm:confirm-old"]);
  } finally {
    await stub.close();
  }
});

test("personal sources name each product and keep MCP grants beside their MCP", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  await installBrowserTestSession(page, {
    apiBaseUrl: stub.baseUrl,
    email: "plugin-sources@comma.local",
    token: "comma_sess_plugin_sources",
  });

  const linear = {
    ...plugin,
    installed: true,
    mcps: [{ id: "mcp1_linear", name: "linear" }],
  };
  const reauthorized: unknown[] = [];
  let connected = false;

  try {
    await page.route(
      `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/plugins`,
      (route) => route.fulfill({ json: { data: [linear] } })
    );
    await page.route("**/plugins/linear/personal-sources", (route) =>
      route.fulfill({
        json: {
          pluginId: "linear",
          sources: [
            {
              connectionId: "linear-native",
              toolkit: "linear-native",
              kind: "native_mcp_oauth",
              state: "ready",
              candidates: [],
              mcpIds: ["mcp1_linear"],
            },
            {
              connectionId: "linear-managed",
              toolkit: "linear",
              kind: "managed_oauth",
              state: connected ? "ready" : "needs_authorization",
              candidates: [],
            },
          ],
        },
      })
    );
    await page.route("**/plugins/linear/reauthorize", async (route) => {
      reauthorized.push(route.request().postDataJSON());
      connected = true;
      await route.fulfill({ json: { authorization: null, plugin: linear } });
    });

    await page.goto("/#/plugins");
    await page.getByRole("button", { name: "View Linear plugin details" }).click();
    // The managed row carries the product name, not its lowercase key.
    await page.getByRole("button", { name: "Connect Linear", exact: true }).click();
    await expect(
      page.getByRole("button", { name: "Reconnect Linear", exact: true })
    ).toBeVisible();
    // The MCP grant is not a personal source; it is offered on the MCP row.
    await expect(page.getByText("Linear MCP", { exact: true })).toHaveCount(0);
    await page
      .getByRole("listitem")
      .filter({ has: page.getByText("linear", { exact: true }) })
      .getByRole("button", { name: "Reconnect Linear MCP", exact: true })
      .click();
    await expect.poll(() => reauthorized.length).toBe(2);
    expect(reauthorized).toEqual([
      { connection_id: "linear-managed" },
      { connection_id: "linear-native" },
    ]);
  } finally {
    await stub.close();
  }
});
