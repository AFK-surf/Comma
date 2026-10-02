import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

// Settings › Channels › Signal (docs/messaging-voice.md): a connection code is
// shown once and the card picks up the chat that sends it, a connected chat can
// be disconnected, and the workspace number is shown without a way to change it.
test("creates a one-time Signal code, shows the new chat, disconnects a chat, and shows the workspace number", async ({
  page,
}, testInfo) => {
  const base = "http://127.0.0.1:65534";
  await installBrowserTestSession(page, {
    apiBaseUrl: base,
    email: "signal@example.com",
    token: "comma_sess_signal",
    userId: "usr_signal",
  });

  const platform = "+15550100001";
  const own = "+15550100002";
  const command = "comma connect ABCD-EFGH";
  let claims: { claim_id: string; expires_at: number }[] = [];
  let bindings = [
    {
      binding_id: "sgb_alice",
      kind: "user",
      peer: "00000000-0000-4000-8000-000000000011",
      display_name: "Alice",
      bound_at: 1_700_000_000_000,
      number: platform,
    },
  ];
  let override: { e164: string; state: string } | null = null;
  const writes: { method: string; path: string; body: unknown }[] = [];
  const account = () => ({ e164: override?.e164 ?? platform, state: "active" });
  const status = () => ({ account: account(), bindings, pending_claims: claims });
  const numberView = () => ({
    override,
    platform: { e164: platform, state: "active" },
    effective: account(),
  });

  await page.route(`${base}/v1/comma/workspaces**`, async (route) => {
    const req = route.request();
    const path = decodeURIComponent(new URL(req.url()).pathname);
    const headers = {
      "access-control-allow-origin": req.headers().origin ?? "http://127.0.0.1:4173",
      "access-control-allow-credentials": "true",
      "access-control-allow-headers":
        "authorization,content-type,x-comma-session-transport",
      "access-control-allow-methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
      "content-type": "application/json",
    };
    const respond = (body: unknown, code = 200) =>
      route.fulfill({ headers, status: code, body: JSON.stringify(body) });
    if (req.method() === "OPTIONS") {
      await route.fulfill({ headers, status: 204 });
      return;
    }
    if (path === "/v1/comma/workspaces") {
      await respond({
        data: [{ id: "wsp_signal", group_id: "grp_signal", name: "Workspace" }],
      });
      return;
    }
    const signal = "/v1/comma/workspaces/wsp_signal/integrations/signal";
    if (!path.startsWith(signal)) {
      await respond({ data: [] });
      return;
    }
    if (req.method() === "GET") {
      await respond(path === `${signal}/number` ? numberView() : status());
      return;
    }
    const body = req.method() === "DELETE" ? undefined : req.postDataJSON();
    writes.push({ method: req.method(), path, body });
    if (path === `${signal}/claims` && req.method() === "POST") {
      claims = [{ claim_id: "sgc_1", expires_at: 1_900_000_000_000 }];
      await respond({
        ...status(),
        claim: {
          claim_id: "sgc_1",
          code: "ABCD-EFGH",
          command,
          number: account().e164,
          expires_at: 1_900_000_000_000,
        },
      });
      return;
    }
    if (path === `${signal}/bindings/sgb_alice`) {
      bindings = bindings.filter((binding) => binding.binding_id !== "sgb_alice");
      await respond(status());
      return;
    }
    await respond({ error: "not_found" }, 404);
  });

  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Channels", exact: true }).click();

  // A new code: the message to send appears once, with the number to send it to.
  const card = page.locator('[data-setting-id="signal.connection"]');
  await expect(card).toContainText("Connected");
  await card.getByRole("button", { name: "New code", exact: true }).click();
  await expect(page.getByTestId("signal-code-message")).toHaveText(command);
  await expect(page.getByTestId("signal-code")).toContainText(platform);
  expect(writes[0]).toMatchObject({
    method: "POST",
    path: "/v1/comma/workspaces/wsp_signal/integrations/signal/claims",
  });
  await page.screenshot({
    animations: "disabled",
    path: testInfo.outputPath("signal-code.png"),
  });
  await page
    .getByTestId("signal-code")
    .getByRole("button", { name: "Done", exact: true })
    .click();
  await expect(page.getByText(command)).toHaveCount(0);
  const claim = page.locator('[data-setting-id="signal.claim.sgc_1"]');
  await expect(claim).toContainText("Unused code");
  await expect(card).toContainText("Connecting");

  // The code is sent from a Signal group: the card shows the group without a reload.
  claims = [];
  bindings = [
    ...bindings,
    {
      binding_id: "sgb_team",
      kind: "group",
      peer: "group:team",
      display_name: "Team",
      bound_at: 1_700_000_100_000,
      number: platform,
    },
  ];
  await expect(page.locator('[data-setting-id="signal.chat.sgb_team"]')).toContainText(
    "Team"
  );
  await expect(claim).toHaveCount(0);
  await expect(card).not.toContainText("Connecting");
  await card.screenshot({
    animations: "disabled",
    path: testInfo.outputPath("signal-card.png"),
  });

  // Disconnect the connected chat after confirmation.
  const chat = page.locator('[data-setting-id="signal.chat.sgb_alice"]');
  await expect(chat).toContainText("Alice");
  await chat.getByRole("button", { name: "Disconnect (Alice)", exact: true }).click();
  await page
    .getByRole("dialog", { name: "Disconnect this Signal chat?", exact: true })
    .getByRole("button", { name: "Disconnect", exact: true })
    .click();
  await expect(chat).toHaveCount(0);
  expect(writes[1]).toMatchObject({
    method: "DELETE",
    path: "/v1/comma/workspaces/wsp_signal/integrations/signal/bindings/sgb_alice",
  });

  // The workspace number is shown; changing it is not offered.
  const numberRow = page.locator('[data-setting-id="signal.number"]');
  await expect(numberRow).toContainText(`Uses the Comma number ${platform}.`);
  await expect(numberRow.getByRole("button")).toHaveCount(0);

  // A preset own number is shown the same way, without a way back to the Comma number.
  override = { e164: own, state: "active" };
  await page.reload();
  await page.getByRole("button", { name: "Channels", exact: true }).click();
  await expect(numberRow).toContainText(`Uses this workspace's own number ${own}.`);
  await expect(numberRow.getByRole("button")).toHaveCount(0);
  expect(writes).toHaveLength(2);
});
