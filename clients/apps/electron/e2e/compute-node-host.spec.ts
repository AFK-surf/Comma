import { electron, expect, test } from "./electron-test";
import { mkdir, mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { request as httpRequest } from "node:http";
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import { startSessionProjectionStub } from "../../../e2e/helpers/session-fixture";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { closeElectronTestApp } from "./close-electron-test-app";

const configPath = process.env.COMMA_COMPUTE_HOST_CONFIG;
test.skip(!configPath, "requires the isolated CommaWeb/Host fixture");
test(
  "creates two real Shells and completes an offline exact deletion through Main",
  { tag: "@mac" },
  async () => {
    const config = JSON.parse(await readFile(configPath!, "utf8")) as {
      api_base_url: string;
      workspace_id: string;
      user_id: string;
      email: string;
      session_id: string;
      token: string;
    };
    const directory = await mkdtemp(join(tmpdir(), "cue-real-host-electron-"));
    const userData = join(directory, "user-data");
    await mkdir(userData);
    recordElectronOnboardingCompleted(userData, [config.user_id]);
    const lifecycle = join(directory, "lifecycle");
    await writeFile(
      lifecycle,
      `#!/usr/bin/env node
const fs = require('node:fs'), crypto = require('node:crypto');
const directory = ${JSON.stringify(configPath! + ".commands")};
let stdin = ''; process.stdin.on('data', chunk => stdin += chunk); process.stdin.on('end', () => {
 const id = crypto.randomUUID(), file = directory + '/' + id;
 fs.writeFileSync(file + '.tmp', JSON.stringify({args:process.argv.slice(2),stdin}), {mode:0o600}); fs.renameSync(file+'.tmp',file+'.request');
 const deadline = Date.now()+100000;
 const timer = setInterval(() => {
  if (fs.existsSync(file+'.response')) { clearInterval(timer); const result = JSON.parse(fs.readFileSync(file+'.response')); fs.unlinkSync(file+'.response'); if(result.error) { console.error(result.error);process.exitCode=1; } else console.log(JSON.stringify(result.result)); }
  else if(Date.now()>deadline) { clearInterval(timer); console.error('Host fixture command timed out');process.exitCode=1; }
 },25);
});
`,
      { mode: 0o700 }
    );
    // Session projection is test wiring. All compute requests reach the real
    // API with a real persisted Session; no compute response is intercepted.
    const session = await startSessionProjectionStub({
      email: config.email,
      userId: config.user_id,
      sessionId: config.session_id,
      handleRequest: (request, response, path) => {
        if (!path.includes("/compute") && path !== "/v1/comma/workspaces") return false;
        const target = new URL(request.url!, config.api_base_url);
        const proxied = httpRequest(
          target,
          { method: request.method, headers: request.headers },
          (incoming) => {
            response.writeHead(incoming.statusCode ?? 502, incoming.headers);
            incoming.pipe(response);
          }
        );
        proxied.on("error", (error) => {
          response.writeHead(502);
          response.end(String(error));
        });
        request.pipe(proxied);
        return true;
      },
    });
    const { ELECTRON_RUN_AS_NODE: _unused, ...env } = process.env;
    const app = await electron.launch({
      args: [
        resolve("apps/electron/.vite/build/main.js"),
        "--lang=en-US",
        `--user-data-dir=${userData}`,
        // HOME below has no login keychain; see compute-node-lifecycle.spec.ts.
        "--use-mock-keychain",
      ],
      cwd: resolve("apps/electron"),
      env: {
        ...env,
        HOME: directory,
        COMMA_API_BASE_URL: session.baseUrl,
        COMMA_ELECTRON_STARTUP_SESSION_EMAIL: config.email,
        COMMA_ELECTRON_STARTUP_SESSION_TOKEN: config.token,
        COMMA_ELECTRON_E2E_COMPUTE_NODE_LIFECYCLE_PATH: lifecycle,
        NODE_ENV: "test",
      },
    });
    const native = (operation: string) =>
      new Promise<void>((finish, reject) => {
        const child = execFile(lifecycle, [operation], (error) =>
          error ? reject(error) : finish()
        );
        child.stdin?.end();
      });
    const projection = async () => {
      const response = await fetch(
        `${config.api_base_url}/v1/comma/workspaces/${config.workspace_id}/compute`,
        { headers: { Authorization: `Bearer ${config.token}` } }
      );
      expect(response.status).toBe(200);
      return (await response.json()) as {
        workloads: Array<{
          id: string;
          name: string;
          observed_state: string;
          deletion?: { phase: string } | null;
        }>;
      };
    };
    try {
      const page = await findElectronWindowByNativeRole(app, "main-window");
      await page.waitForLoadState("domcontentloaded");
      // Home opens first and selects the account's workspace; Settings works in it.
      await page.evaluate(() => {
        window.location.hash = "#/settings";
      });
      await page.getByRole("button", { name: "Devices", exact: true }).click();
      await page.getByRole("button", { name: "Enable this Mac", exact: true }).click();
      await page
        .getByRole("dialog", { name: "Enable this Mac", exact: true })
        .getByRole("button", { name: "Enable this Mac", exact: true })
        .click();
      await expect
        .poll(
          async () =>
            (await projection()).workloads.filter((w) => w.observed_state === "ready")
              .length
        )
        .toBe(1);
      // The setup steps return to the main view once all three are ready.
      await expect(
        page.getByRole("button", { name: "Refresh workloads", exact: true })
      ).toBeVisible();
      await page
        .getByRole("button", { name: "Refresh workloads", exact: true })
        .click();
      await page.getByRole("button", { name: /Node actions$/ }).click();
      await page.getByRole("menuitem", { name: "Rename", exact: true }).click();
      await page
        .getByRole("dialog", { name: "Rename", exact: true })
        .getByRole("textbox")
        .fill("Delete target");
      await page
        .getByRole("dialog", { name: "Rename", exact: true })
        .getByRole("button", { name: "Save name", exact: true })
        .click();
      await page.getByRole("button", { name: "New Shell", exact: true }).click();
      await page
        .getByRole("textbox", { name: "Name", exact: true })
        .fill("Keep neighbor");
      await page.getByRole("button", { name: "Confirm creation", exact: true }).click();
      await expect
        .poll(
          async () =>
            (await projection()).workloads.filter((w) => w.observed_state === "ready")
              .length
        )
        .toBe(2);
      const shells = (await projection()).workloads;
      for (const shell of shells)
        await expect
          .poll(() =>
            readFile(configPath! + ".written-" + shell.id, "utf8").catch(() => "")
          )
          .toBe("written");
      await native("fixture-disconnect");
      await page
        .getByRole("button", { name: "Refresh workloads", exact: true })
        .click();
      await page
        .getByRole("button", { name: /Node actions$/ })
        .first()
        .click();
      // Locate the target by opening its own row, rather than relying on sort order.
      await page.keyboard.press("Escape");
      const targetButton = page.getByRole("button", {
        name: "Delete target",
        exact: true,
      });
      await targetButton.click();
      await page.getByRole("button", { name: "Delete Shell", exact: true }).click();
      await page
        .getByRole("dialog", { name: "Delete Shell", exact: true })
        .getByRole("button", { name: "Delete workload", exact: true })
        .click();
      await expect
        .poll(
          async () =>
            (await projection()).workloads.find((w) => w.name === "Delete target")
              ?.deletion?.phase
        )
        .not.toBeUndefined();
      expect(
        (await projection()).workloads.find((w) => w.name === "Delete target")?.deletion
          ?.phase
      ).not.toBe("complete");
      await native("fixture-reconnect");
      await expect
        .poll(
          async () =>
            (await projection()).workloads.find((w) => w.name === "Delete target")
              ?.deletion?.phase
        )
        .toBe("complete");
      expect(
        (await projection()).workloads.find((w) => w.name === "Keep neighbor")?.deletion
      ).toBeNull();
      await writeFile(configPath! + ".ui-complete", randomUUID());
    } finally {
      await closeElectronTestApp(app);
      await session.close();
      await rm(directory, { recursive: true, force: true });
    }
  }
);
