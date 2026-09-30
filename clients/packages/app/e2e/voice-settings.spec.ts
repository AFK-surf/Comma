import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

// Settings › System › Voice (docs/messaging-voice.md): a caller number is
// bound only after its SMS code checks out, its PIN is write-only, and a voice
// agent API key's plaintext is shown once, right after creation.
test("verifies a caller number, sets its PIN, and manages a voice key shown once", async ({
  page,
}, testInfo) => {
  const base = "http://127.0.0.1:65534";
  await installBrowserTestSession(page, {
    apiBaseUrl: base,
    email: "voice@example.com",
    token: "comma_sess_voice",
    userId: "usr_voice",
  });

  const line = "+15550001111";
  const caller = "+15551234567";
  const secret = "salix_vk_e2eSecretValueThatIsShownOnce";
  const readinessUrl = "https://salix.example.test/v1/agent-groups/grp_voice/voice";
  const sessionsUrl =
    "wss://salix.example.test/v1/agent-groups/grp_voice/voice/sessions";
  let codeSent = false;
  let number:
    | { e164: string; line: string; pin_set: boolean; verified_at: number }
    | undefined;
  let key:
    | {
        key_id: string;
        name: string;
        prefix: string;
        status: "active" | "disabled";
        created_at: number;
        sessions_url: string;
        readiness_url: string;
      }
    | undefined;
  const writes: { method: string; path: string; body: unknown }[] = [];
  const status = () => ({
    lines: [line],
    numbers: number
      ? [{ ...number, carrier: "twilio", pin_locked_until: null, status: "verified" }]
      : [],
    readiness: { ready: true, reason: null },
    sessions_url: sessionsUrl,
    readiness_url: readinessUrl,
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
        data: [{ id: "wsp_voice", group_id: "grp_voice", name: "Workspace" }],
      });
      return;
    }
    const voice = "/v1/comma/workspaces/wsp_voice/integrations/voice";
    const keys = "/v1/comma/workspaces/wsp_voice/voice-api-keys";
    if (!path.startsWith(voice) && !path.startsWith(keys)) {
      await respond({ data: [] });
      return;
    }
    if (req.method() === "GET") {
      await respond(path === voice ? status() : key ? [key] : []);
      return;
    }
    const body = req.method() === "DELETE" ? undefined : req.postDataJSON();
    writes.push({ method: req.method(), path, body });
    if (path === `${voice}/numbers/verify-start`) {
      codeSent = true;
      await respond({ e164: body.e164, line: body.line, status: "pending" });
      return;
    }
    if (path === `${voice}/numbers/verify-check`) {
      if (!codeSent || body.code !== "246810") {
        await respond({ error: "invalid_code" }, 422);
        return;
      }
      number = {
        e164: body.e164,
        line,
        pin_set: false,
        verified_at: 1_700_000_000_000,
      };
      await respond(status());
      return;
    }
    if (path === `${voice}/pin` && number) {
      number = { ...number, pin_set: body.pin !== "" };
      await respond(status());
      return;
    }
    if (path === keys && req.method() === "POST") {
      key = {
        key_id: "gak_voice",
        name: body.name,
        prefix: secret.slice(0, 15),
        status: "active",
        created_at: 1_700_000_000,
        sessions_url: sessionsUrl,
        readiness_url: readinessUrl,
      };
      await respond({ ...key, key: secret }, 201);
      return;
    }
    if (path === `${keys}/gak_voice` && req.method() === "PATCH" && key) {
      key = { ...key, ...body };
      await respond(key);
      return;
    }
    if (path === `${keys}/gak_voice` && req.method() === "DELETE") {
      key = undefined;
      await respond({ deleted: true });
      return;
    }
    await respond({ error: "not_found" }, 404);
  });

  await page.goto("/#/settings");
  await page.getByRole("button", { name: "Voice", exact: true }).click();
  const readiness = page.locator('[data-setting-id="voice.readiness.status"]');
  await expect(readiness).toContainText("Ready");

  // Add a number: the SMS code must check out before the number is listed.
  const lineRow = page.locator(`[data-setting-id="voice.line.${line}"]`);
  await expect(lineRow).toContainText(`Call ${line}`);
  await lineRow.getByRole("button", { name: "Add number", exact: true }).click();
  const add = page.getByRole("dialog", { name: "Add a phone number", exact: true });
  await expect(
    add.getByRole("button", { name: "Send code", exact: true })
  ).toBeDisabled();
  await add.getByRole("textbox", { name: "Phone number", exact: true }).fill(caller);
  await add.getByRole("button", { name: "Send code", exact: true }).click();

  const code = page.getByRole("dialog", { name: "Enter the code", exact: true });
  await code.getByRole("textbox", { name: "Code", exact: true }).fill("111111");
  await code.getByRole("button", { name: "Verify", exact: true }).click();
  await expect(code).toContainText("The code is not correct or has expired.");
  await code.getByRole("textbox", { name: "Code", exact: true }).fill("246810");
  await code.getByRole("button", { name: "Verify", exact: true }).click();
  await expect(code).toHaveCount(0);

  const numberRow = page.locator(`[data-setting-id="voice.number.${caller}.${line}"]`);
  await expect(numberRow).toContainText("Verified");
  await expect(numberRow).toContainText("No PIN");
  expect(writes.slice(0, 3)).toEqual([
    {
      method: "POST",
      path: "/v1/comma/workspaces/wsp_voice/integrations/voice/numbers/verify-start",
      body: { e164: caller, line },
    },
    {
      method: "POST",
      path: "/v1/comma/workspaces/wsp_voice/integrations/voice/numbers/verify-check",
      body: { e164: caller, code: "111111", line },
    },
    {
      method: "POST",
      path: "/v1/comma/workspaces/wsp_voice/integrations/voice/numbers/verify-check",
      body: { e164: caller, code: "246810", line },
    },
  ]);

  // Set the PIN; the page only ever learns that one is set.
  await numberRow.getByRole("button", { name: "Number actions", exact: true }).click();
  await page.getByRole("menuitem", { name: "Set PIN", exact: true }).click();
  const pin = page.getByRole("dialog", { name: "Caller PIN", exact: true });
  await pin.getByLabel("PIN (4 to 8 digits)").fill("2468");
  await pin.getByRole("button", { name: "Save PIN", exact: true }).click();
  await expect(pin).toHaveCount(0);
  await expect(numberRow).toContainText("PIN set");
  expect(writes[3]).toEqual({
    method: "PUT",
    path: "/v1/comma/workspaces/wsp_voice/integrations/voice/pin",
    body: { e164: caller, pin: "2468" },
  });

  // Create a voice key: the plaintext and a comma-voice command appear once.
  await page.getByRole("button", { name: "New voice key", exact: true }).click();
  const create = page.getByRole("dialog", { name: "New voice key", exact: true });
  await create.getByRole("textbox", { name: "Name", exact: true }).fill("Front desk");
  await create.getByRole("button", { name: "Create key", exact: true }).click();

  const created = page.getByTestId("voice-key-created");
  await expect(created).toBeVisible();
  await expect(page.getByTestId("voice-key-secret")).toHaveText(secret);
  const example = page.getByTestId("voice-key-example");
  await expect(example).toContainText(
    "export COMMA_VOICE_SERVER='https://salix.example.test'"
  );
  await expect(example).toContainText("export COMMA_VOICE_GROUP='grp_voice'");
  // The key goes to an owner-only file and reaches the CLI by --key-file,
  // never through the environment.
  await expect(example).toContainText(
    `(umask 077; printf '%s' '${secret}' > ~/.comma-voice-key)`
  );
  await expect(example).toContainText(
    "comma-voice check --key-file ~/.comma-voice-key && comma-voice call --key-file ~/.comma-voice-key"
  );
  await expect(example).not.toContainText("COMMA_VOICE_API_KEY");
  expect(writes[4]).toEqual({
    method: "POST",
    path: "/v1/comma/workspaces/wsp_voice/voice-api-keys",
    body: { name: "Front desk" },
  });
  await page.screenshot({
    animations: "disabled",
    path: testInfo.outputPath("voice-key-created.png"),
  });

  await created.getByRole("button", { name: "Done", exact: true }).click();
  await expect(page.getByTestId("voice-key-created")).toHaveCount(0);
  await expect(page.getByText(secret)).toHaveCount(0);

  const keyRow = page.locator('[data-setting-id="voice.key.gak_voice"]');
  await expect(keyRow).toContainText("Front desk");
  await expect(keyRow).toContainText("Active");

  await keyRow.getByRole("button", { name: "Key actions", exact: true }).click();
  await page.getByRole("menuitem", { name: "Disable key", exact: true }).click();
  await expect(keyRow).toContainText("Disabled");
  expect(writes[5]).toEqual({
    method: "PATCH",
    path: "/v1/comma/workspaces/wsp_voice/voice-api-keys/gak_voice",
    body: { status: "disabled" },
  });

  await keyRow.getByRole("button", { name: "Key actions", exact: true }).click();
  await page.getByRole("menuitem", { name: "Delete key", exact: true }).click();
  await page
    .getByRole("dialog", { name: "Delete this voice agent API key?", exact: true })
    .getByRole("button", { name: "Delete key", exact: true })
    .click();
  await expect(keyRow).toHaveCount(0);
  expect(writes[6]).toMatchObject({
    method: "DELETE",
    path: "/v1/comma/workspaces/wsp_voice/voice-api-keys/gak_voice",
  });
});
