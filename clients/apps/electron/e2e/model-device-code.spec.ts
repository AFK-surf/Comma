import { expect, test } from "./electron-test";
import { request } from "node:http";
import { chatSmokeWorkspace, startChatSmokeStub } from "../../../e2e/p0/chat-stub";
import { startElectronTestServer } from "./electron-test-server";

// Keep the real renderer, preload, capability gateway, and OS clipboard. Only
// the backend and external browser destination are test doubles.
test(
  "device sign-in copies through Main before opening the browser and retries a failed copy",
  { tag: "@shared-app" },
  async ({ sharedElectron }) => {
    const stub = await startChatSmokeStub();
    const base = `/v1/comma/workspaces/${chatSmokeWorkspace.id}`;
    const responses: Record<string, unknown> = {
      "/v1/comma/model-catalog": {
        sources: { "github-copilot": { name: "GitHub Copilot", kind: "subscription" } },
        models: [],
      },
      [`${base}/agent-models`]: {
        workspace_id: chatSmokeWorkspace.id,
        agents: { router: { agent_id: "router", name: "Router", role: "router" } },
        task_model: { selection: { kind: "builtin" } },
      },
      [`${base}/subscription-accounts`]: { accounts: [], next: "" },
      [`${base}/subscription-accounts/oauth`]: {
        id: "device-copy-attempt",
        url: "https://github.com/login/device",
        mode: "device",
        user_code: "ABCD-1234",
        interval: 60,
        expires_at: "2099-01-01T00:00:00Z",
      },
      [`${base}/subscription-accounts/oauth/device-copy-attempt`]: {
        status: "pending",
        interval: 60,
      },
    };
    const server = await startElectronTestServer((req, res) => {
      const path = new URL(req.url!, "http://localhost").pathname;
      if (path in responses) {
        req.resume();
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify(responses[path]));
        return;
      }
      const upstream = request(
        new URL(req.url!, stub.baseUrl),
        {
          method: req.method,
          headers: req.headers,
        },
        (reply) => {
          res.writeHead(reply.statusCode!, reply.headers);
          reply.pipe(res);
          res.on("close", () => reply.destroy());
        }
      );
      upstream.on("error", () => res.destroy());
      req.pipe(upstream);
    });
    const { app, mainWindow: page } = sharedElectron;
    try {
      sharedElectron.useApi(server.server);
      await sharedElectron.signIn({ email: "smoke@comma.local", userId: stub.userId });
      // Main's clipboard and browser are the test's until it ends.
      await app.evaluate(async ({ clipboard, shell }) => {
        const scope = globalThis as typeof globalThis & {
          deviceCopyProbe?: {
            failCopy: boolean;
            opened: { url: string; text: string }[];
            restore(): void;
          };
        };
        const { writeText } = clipboard;
        const { openExternal } = shell;
        const probe = {
          failCopy: false,
          opened: [] as { url: string; text: string }[],
          restore() {
            // Back as they were: own properties of the module, or its prototype's.
            Reflect.deleteProperty(clipboard, "writeText");
            if (clipboard.writeText !== writeText) clipboard.writeText = writeText;
            Reflect.deleteProperty(shell, "openExternal");
            if (shell.openExternal !== openExternal) shell.openExternal = openExternal;
            delete scope.deviceCopyProbe;
          },
        };
        scope.deviceCopyProbe = probe;
        await clipboard.writeText("previous clipboard");
        clipboard.writeText = async (text) => {
          if (probe.failCopy) throw new Error("Clipboard unavailable");
          await writeText.call(clipboard, text);
        };
        shell.openExternal = async (url) => {
          probe.opened.push({ url, text: await clipboard.readText() });
        };
      });
      await page.getByRole("button", { name: "Settings", exact: true }).click();
      await page.getByRole("button", { name: "Model & API", exact: true }).click();
      await page.getByRole("button", { name: "Add profile", exact: true }).click();
      await page.getByRole("button", { name: "GitHub Copilot", exact: true }).click();
      await expect(page.getByRole("status", { name: "Device code" })).toHaveText(
        "ABCD-1234"
      );
      const copy = page.getByRole("button", {
        name: "Copy code and continue to GitHub Copilot",
      });
      const opened = () =>
        app.evaluate(
          () =>
            (
              globalThis as typeof globalThis & {
                deviceCopyProbe: { opened: { url: string; text: string }[] };
              }
            ).deviceCopyProbe.opened
        );
      await copy.click();
      await expect
        .poll(opened)
        .toEqual([{ url: "https://github.com/login/device", text: "ABCD-1234" }]);
      await expect
        .poll(() => app.evaluate(({ clipboard }) => clipboard.readText()))
        .toBe("ABCD-1234");

      await app.evaluate(async ({ clipboard }) => {
        await clipboard.writeText("previous clipboard");
        (
          globalThis as typeof globalThis & { deviceCopyProbe: { failCopy: boolean } }
        ).deviceCopyProbe.failCopy = true;
      });
      await copy.click();
      await expect(
        page.getByText(
          "Could not copy the code or open the sign-in page. Try again or copy the code manually."
        )
      ).toBeVisible();
      expect(await opened()).toHaveLength(1);
      expect(await app.evaluate(({ clipboard }) => clipboard.readText())).toBe(
        "previous clipboard"
      );
      await expect(page.getByRole("status", { name: "Device code" })).toHaveText(
        "ABCD-1234"
      );
      await app.evaluate(() => {
        (
          globalThis as typeof globalThis & { deviceCopyProbe: { failCopy: boolean } }
        ).deviceCopyProbe.failCopy = false;
      });
      await copy.click();
      await expect.poll(opened).toHaveLength(2);
      expect((await opened())[1]).toEqual({
        url: "https://github.com/login/device",
        text: "ABCD-1234",
      });
    } finally {
      await app.evaluate(() =>
        (
          globalThis as typeof globalThis & { deviceCopyProbe?: { restore(): void } }
        ).deviceCopyProbe?.restore()
      );
      await server.close();
      await stub.close();
    }
  }
);
