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

const xPlugin = {
  ...plugin,
  id: "x-twitter",
  name: "X",
  brand: "x",
  summary: "Read public X posts",
  mcps: [{ id: "mcp1_0000000000000000009", name: "X" }],
  credentialSetup: {
    key: "X_BEARER_TOKEN",
    label: "App-only Bearer Token",
    helpUrl: "https://docs.x.com/tools/mcp#simple-route-app-only-bearer",
  },
};

test("X retries a rejected token, connects without a device, updates and uninstalls", async ({
  page,
}) => {
  const stub = await setup(page);
  let installed = false;
  const tokens: string[] = [];
  try {
    await page.route("**/plugins", (route) =>
      route.fulfill({ json: { data: [{ ...xPlugin, installed }] } })
    );
    await page.route("**/plugins/x-twitter/personal-sources", (route) =>
      route.fulfill({ json: { pluginId: "x-twitter", sources: [] } })
    );
    await page.route("**/plugins/x-twitter/install", async (route) => {
      const body = route.request().postDataJSON();
      if (!body.config_values) {
        await route.fulfill({
          json: {
            plugin: { ...xPlugin, installed },
            authorization: null,
            configuration: xPlugin.credentialSetup,
          },
        });
      } else if (body.config_values.X_BEARER_TOKEN === "invalid-token") {
        await route.fulfill({
          status: 422,
          json: { error: "plugin_credential_rejected" },
        });
      } else {
        expect(Object.keys(body.config_values)).toEqual(["X_BEARER_TOKEN"]);
        tokens.push(body.config_values.X_BEARER_TOKEN);
        installed = true;
        await route.fulfill({
          json: { plugin: { ...xPlugin, installed }, authorization: null },
        });
      }
    });
    await page.route("**/plugins/x-twitter", async (route) => {
      expect(route.request().method()).toBe("DELETE");
      installed = false;
      await route.fulfill({ json: { ...xPlugin, installed } });
    });
    await page.goto("/#/plugins");
    await page.getByRole("button", { name: "Add X", exact: true }).click();
    const dialog = page.getByRole("dialog", { name: "Connect X" });
    await expect(dialog).toBeVisible();
    await expect(
      dialog.getByRole("button", { name: "Connect", exact: true })
    ).toBeDisabled();
    const input = dialog.getByLabel("App-only Bearer Token");
    await expect(input).toHaveAttribute("type", "password");
    await input.fill("invalid-token");
    await dialog.getByRole("button", { name: "Connect", exact: true }).click();
    await expect(dialog.getByRole("alert")).toBeVisible();
    await expect(
      dialog.getByRole("button", { name: "Connect", exact: true })
    ).toBeEnabled();
    expect(tokens).toEqual([]);
    await dialog.getByRole("button", { name: "Cancel", exact: true }).click();
    const add = page.getByRole("button", { name: "Add X", exact: true });
    await expect(add).toBeEnabled();
    await add.click();
    await input.fill("x-test-own-token");
    await dialog.getByRole("button", { name: "Connect", exact: true }).click();
    await expect(dialog).toHaveCount(0);
    expect(tokens).toEqual(["x-test-own-token"]);

    await page
      .getByRole("button", { name: "View X plugin details", exact: true })
      .click();
    await page.getByRole("button", { name: "Update token", exact: true }).click();
    const updateDialog = page.getByRole("dialog", { name: "Update X token" });
    const replacementInput = updateDialog.getByLabel("App-only Bearer Token");
    await expect(replacementInput).toHaveValue("");
    await replacementInput.fill("x-test-replacement-token");
    await updateDialog
      .getByRole("button", { name: "Update token", exact: true })
      .click();
    await expect(updateDialog).toHaveCount(0);
    expect(tokens).toEqual(["x-test-own-token", "x-test-replacement-token"]);
    await page.getByRole("button", { name: "Uninstall X", exact: true }).click();
    await expect(
      page.getByRole("button", { name: "Add to Comma X", exact: true })
    ).toBeVisible();
  } finally {
    await stub.close();
  }
});

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

test("Add stays in Plugins and shows the confirmed installation", async ({ page }) => {
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
    await expect(
      page.getByRole("button", { name: "Add Linear", exact: true })
    ).toHaveCount(0);
    await expect(page).toHaveURL(/#\/plugins$/);
  } finally {
    finish?.();
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

test("a personal source missing a newly required scope asks for a reconnect", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();
  await installBrowserTestSession(page, {
    apiBaseUrl: stub.baseUrl,
    email: "plugin-scope@comma.local",
    token: "comma_sess_plugin_scope",
  });
  const linear = {
    ...plugin,
    installed: true,
    mcps: [{ id: "mcp1_linear", name: "linear" }],
  };
  const reauthorized: unknown[] = [];
  let widened = false;

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
              connectionId: "linear-managed",
              toolkit: "linear",
              kind: "managed_oauth",
              state: widened ? "ready" : "needs_reauthorization",
              candidates: [],
            },
          ],
        },
      })
    );
    await page.route("**/plugins/linear/reauthorize", async (route) => {
      reauthorized.push(route.request().postDataJSON());
      widened = true;
      await route.fulfill({ json: { authorization: null, plugin: linear } });
    });

    await page.goto("/#/plugins");
    await page.getByRole("button", { name: "View Linear plugin details" }).click();
    await expect(page.getByText("Reconnect to grant new access")).toBeVisible();
    await page.getByRole("button", { name: "Reconnect Linear", exact: true }).click();
    await expect
      .poll(() => reauthorized)
      .toEqual([{ connection_id: "linear-managed" }]);
    await expect(page.getByText("Ready", { exact: true })).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("an Outlook integration shows the Outlook logo, not its initial", async ({
  page,
}) => {
  const stub = await setup(page);

  try {
    await page.route(
      `**/v1/comma/workspaces/${chatSmokeWorkspace.id}/plugins`,
      (route) =>
        route.fulfill({
          json: {
            data: [
              {
                ...plugin,
                brand: "outlook",
                description: "Connect Outlook mail and calendar",
                id: "outlook",
                name: "Microsoft Outlook",
                summary: "Connect Outlook mail and calendar",
              },
            ],
          },
        })
    );

    await page.goto("/#/plugins");
    const artwork = page.locator('[data-plugin-brand="outlook"]').first();
    await expect(artwork.locator('svg[data-provider-logo="outlook"]')).toBeVisible();
    await expect(artwork).not.toHaveText("M");
  } finally {
    await stub.close();
  }
});
