import {
  electron,
  electronTestDirectory,
  electronWait,
  expect,
  loadedMainWindow,
  test,
} from "./electron-test";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { join, resolve } from "node:path";
import type { ElectronApplication, Page } from "@playwright/test";
import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";
import { closeElectronTestApp } from "./close-electron-test-app";
import { closeElectronWindow } from "./electron-operations";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const helper = resolve(
  electronAppDir,
  "dist/native/darwin",
  process.arch,
  "opendropkit"
);
/** A Task-request invite link, as another Comma's Add someone nearby sends it. */
const inviteToken = "N".repeat(43);
const invite = `https://app.comma.surf/task-requests?invite=${inviteToken}`;

type ReceiverGlobals = typeof globalThis & {
  commaE2eAirDropReceiver: { listening(): Promise<number> };
};

/**
 * Comma receiving over the real OpenDropKit helper, with the backend's invite read scripted. Main's receiver listens
 * on a port it picks; the launch has Main report it when the helper says it listens, so the test waits for that
 * event, not for a process table.
 */
async function launchReceivingComma() {
  const api = await startChatSmokeStub({
    extraRoutes: (_request, url, response) => {
      if (url.pathname !== `/v1/comma/task-request-invites/${inviteToken}`)
        return false;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(
        JSON.stringify({
          workspace: {
            id: "wsp_nearby_sender",
            name: "Jinfei's workspace",
            owner: {
              id: "usr_nearby_sender",
              name: "Jinfei",
              email: "jinfei@comma.local",
            },
          },
          own: false,
          back: null,
          expires_at: null,
        })
      );
      return true;
    },
  });
  const userDataDir = await electronTestDirectory("comma-nearby-e2e-");
  recordElectronOnboardingCompleted(userDataDir, [api.userId]);
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
  let app: ElectronApplication | undefined;
  try {
    app = await electron.launch({
      args: [electronMain, `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: {
        ...hostEnv,
        COMMA_API_BASE_URL: api.baseUrl,
        COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "nearby@comma.local",
        COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "nearby-session-token",
        NODE_ENV: "test",
      },
      main: {
        arg: helper,
        beforeApp: (_electron, helperPath) => {
          const childProcess = process.getBuiltinModule("node:child_process");
          const spawnHelper = childProcess.spawn;
          let port: number | undefined;
          let heard: Array<(port: number) => void> = [];
          (globalThis as ReceiverGlobals).commaE2eAirDropReceiver = {
            listening: () =>
              port === undefined
                ? new Promise((listen) => heard.push(listen))
                : Promise.resolve(port),
          };
          childProcess.spawn = function (
            this: unknown,
            ...given: Parameters<typeof spawnHelper>
          ) {
            const child = (
              spawnHelper as (...args: unknown[]) => ReturnType<typeof spawnHelper>
            ).apply(this, given);
            const [command, args] = given as unknown as [
              string,
              readonly string[] | undefined,
            ];
            if (command !== helperPath || args?.[0] !== "receive") return child;
            let pending = "";
            child.stdout?.on("data", (chunk: Buffer) => {
              pending += chunk.toString();
              let newline: number;
              while ((newline = pending.indexOf("\n")) !== -1) {
                const line = pending.slice(0, newline);
                pending = pending.slice(newline + 1);
                try {
                  const event = JSON.parse(line) as { type?: string; port?: number };
                  if (event.type !== "listening" || typeof event.port !== "number")
                    continue;
                  port = event.port;
                  for (const listen of heard) listen(event.port);
                  heard = [];
                } catch {
                  // Not an event line; the app reads its own.
                }
              }
            });
            child.once("close", () => {
              port = undefined;
            });
            return child;
          } as typeof spawnHelper;
        },
      },
    });
    const launched = app;
    const main = await loadedMainWindow(launched);
    // Signed in: the receiver runs under this session's name.
    await expect(main.getByRole("textbox", { name: "AI prompt" })).toBeVisible();
    const port = await electronWait(
      launched,
      "Main's AirDrop receiver to listen",
      async () => ({ windows: launched.windows().map((page) => page.url()) }),
      () =>
        launched.evaluate(() =>
          (globalThis as ReceiverGlobals).commaE2eAirDropReceiver.listening()
        )
    );
    let sender: ReturnType<typeof spawn> | undefined;
    let senderOutput = "";
    /** Sends the invite link alone, no files, as another Comma's nearby list does over AirDrop. */
    const sendInvite = () => {
      sender = spawn(helper, [
        "send",
        "--name",
        "Jinfei’s Comma",
        "--host",
        "::1",
        "--port",
        String(port),
        "--url",
        invite,
        "--supports-url",
        "--json",
        "--identity-directory",
        join(userDataDir, "sender-identity"),
      ]);
      const record = (chunk: Buffer) => {
        senderOutput = `${senderOutput}${chunk.toString()}`.slice(-8192);
      };
      sender.stdout?.on("data", record);
      sender.stderr?.on("data", record);
      return sender;
    };
    /** Closing the card declines the invite; the sender's helper hears it and ends. */
    const closeCard = async (window: Page) => {
      const card = window.getByRole("dialog", { name: "Jinfei wants to connect" });
      await electronWait(
        launched,
        "the invite's connect card in the main window",
        async () => ({
          senderOutput,
          windows: launched.windows().map((page) => page.url()),
        }),
        () => expect(card).toBeVisible()
      );
      const ended =
        sender && sender.exitCode === null ? once(sender, "exit") : undefined;
      await card.getByRole("button", { name: "Close" }).click();
      await electronWait(
        launched,
        "the sender's helper to hear the answer and end",
        async () => ({ senderOutput }),
        async () => ended
      );
    };
    const close = async () => {
      if (sender && sender.exitCode === null && sender.signalCode === null) {
        sender.kill();
        await once(sender, "exit");
      }
      await closeElectronTestApp(launched);
      await api.close();
    };
    return {
      app: launched,
      main,
      sendInvite,
      closeCard,
      close,
      senderOutput: () => senderOutput,
    };
  } catch (error) {
    if (app) await closeElectronTestApp(app);
    await api.close();
    throw error;
  }
}

test(
  "a received nearby invite shows its connect card in the open main window",
  { tag: "@mac" },
  async () => {
    const receiving = await launchReceivingComma();
    try {
      receiving.sendInvite();
      await receiving.closeCard(receiving.main);
    } finally {
      await receiving.close();
    }
  }
);

test(
  "a received nearby invite opens the closed main window and shows its connect card there",
  { tag: "@mac" },
  async () => {
    const receiving = await launchReceivingComma();
    try {
      const { app, main } = receiving;
      const gone = main.waitForEvent("close", { timeout: 0 });
      // As its close button does: Comma keeps running in the menu bar.
      expect(await closeElectronWindow(app, main)).toBe("closed");
      await gone;

      receiving.sendInvite();
      const opened = await electronWait(
        app,
        "a main window to open for the invite",
        async () => ({
          senderOutput: receiving.senderOutput(),
          windows: app.windows().map((page) => page.url()),
        }),
        () => loadedMainWindow(app)
      );
      await receiving.closeCard(opened);
      // Main shows the window it opened, not only its page.
      const window = await app.browserWindow(opened);
      expect(await window.evaluate((browserWindow) => browserWindow.isVisible())).toBe(
        true
      );
    } finally {
      await receiving.close();
    }
  }
);
