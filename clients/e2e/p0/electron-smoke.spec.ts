import { _electron as electron, expect, test } from "@playwright/test";
import {
  encodeSessionPresenceExpectation,
  sessionExpectation,
  sessionPresenceExpectationHeader,
  type SessionLifecycleSnapshot,
} from "@comma/session-contract";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../../apps/electron/src/test-support/electron-native-window";
import { recordElectronOnboardingCompleted } from "../helpers/electron-profile";
import { createE2eSessionProjection } from "../helpers/session-fixture";
import {
  chatSmokeWorkspaceChat,
  chatSmokeAssistantReply,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "./chat-stub";

import { computerUseAppName } from "../../apps/electron/scripts/native-paths";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const computerUseHelperExecutable = resolve(
  electronAppDir,
  "dist/native",
  process.platform,
  process.arch,
  `native/macos/${computerUseAppName}.app/Contents/MacOS/CommaComputerUseDaemon`
);
const computerUseResourceBundles = [
  "ComputerUseHost_CUShared.bundle",
  "ComputerUseHost_CUForeground.bundle",
].map((bundle) =>
  resolve(
    electronAppDir,
    "dist/native",
    process.platform,
    process.arch,
    `native/macos/${computerUseAppName}.app/Contents/Resources`,
    bundle
  )
);

function electronTestEnv() {
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...env } = process.env;
  return {
    ...env,
    NODE_ENV: "test",
  };
}

function electronChatEnv(baseUrl: string) {
  return {
    ...electronTestEnv(),
    COMMA_API_BASE_URL: baseUrl,
    COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "smoke@comma.local",
    COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "p0-smoke-session-token",
  };
}

test("electron app boots with an isolated native bridge", async ({
  browserName: _browserName,
}, testInfo) => {
  const app = await electron.launch({
    args: [electronMain, "--lang=en-US"],
    cwd: electronAppDir,
    env: electronTestEnv(),
    recordVideo: {
      dir: testInfo.outputPath("electron-video"),
      size: { width: 1280, height: 800 },
    },
  });
  let failed = false;
  let video: { path(): Promise<string> } | null = null;

  try {
    const appWindow = await findElectronWindowByNativeRole(app, "main-window");
    video = appWindow.video();

    await expect
      .poll(() => appWindow.evaluate(() => document.readyState))
      .toBe("complete");
    // The renderer reads app preferences from Main before its first render,
    // so the root fills an IPC round trip after the document loads.
    await expect
      .poll(() =>
        appWindow.evaluate(
          () => (document.getElementById("root")?.childElementCount ?? 0) > 0
        )
      )
      .toBe(true);
    await expect(
      appWindow.evaluate(() => {
        const rendererWindow = window as Window & {
          commaNative?: unknown;
          require?: unknown;
          process?: unknown;
        };

        return {
          hasRenderedRoot:
            (document.getElementById("root")?.childElementCount ?? 0) > 0,
          hasCommaNative: typeof rendererWindow.commaNative === "object",
          connectorStatusType:
            typeof rendererWindow.commaNative === "object" &&
            rendererWindow.commaNative !== null &&
            "connector" in rendererWindow.commaNative
              ? typeof (
                  rendererWindow.commaNative as {
                    connector?: { status?: unknown };
                  }
                ).connector?.status
              : "missing",
          requireType: typeof rendererWindow.require,
          processType: typeof rendererWindow.process,
        };
      })
    ).resolves.toEqual({
      hasRenderedRoot: true,
      hasCommaNative: true,
      connectorStatusType: "function",
      requireType: "undefined",
      processType: "undefined",
    });

    await test.step("native ComputerUse helper package is complete when built", () => {
      if (process.platform !== "darwin" || !existsSync(computerUseHelperExecutable)) {
        return;
      }

      for (const resourceBundle of computerUseResourceBundles) {
        expect(existsSync(resourceBundle)).toBe(true);
      }
    });
  } catch (error) {
    failed = true;
    throw error;
  } finally {
    await app.close();
    const videoPath = await video?.path();
    if (videoPath && failed) {
      await testInfo.attach("electron-video", {
        path: videoPath,
        contentType: "video/webm",
      });
    } else if (videoPath) {
      await rm(videoPath, { force: true });
    }
  }
});

test("electron routes one Chat send through the Main-owned /v1 proxy", async ({
  browserName: _browserName,
}, testInfo) => {
  const stub = await startChatSmokeStub({
    additionalInboxConversations: [chatSmokeWorkspaceChat],
  });
  const userDataDir = await mkdtemp(join(tmpdir(), "comma-chat-smoke-"));
  recordElectronOnboardingCompleted(userDataDir, [stub.userId]);
  const app = await electron.launch({
    args: [electronMain, "--lang=en-US", `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronChatEnv(stub.baseUrl),
    recordVideo: {
      dir: testInfo.outputPath("electron-video"),
      size: { width: 1280, height: 800 },
    },
  });
  await app.context().addInitScript(installAssetsFetchRecorder);
  let failed = false;
  let video: { path(): Promise<string> } | null = null;

  try {
    const appWindow = await findElectronWindowByNativeRole(app, "main-window");
    video = appWindow.video();
    await appWindow.evaluate(installAssetsFetchRecorder);
    await appWindow.waitForLoadState("domcontentloaded");

    await appWindow.getByRole("link", { name: "Inbox", exact: true }).click();
    const content = appWindow.getByRole("region", { name: "Content" });

    // The host list supplies the notification used to open this Chat.
    const workspaceChatItem = content.getByTestId("inbox-item");
    await expect(workspaceChatItem).toHaveCount(1);
    const workspaceChatUpdatedAt = chatSmokeWorkspaceChat.updated_at * 1_000;
    const expectedWorkspaceChatDate = new Intl.DateTimeFormat("en-US", {
      day: "numeric",
      month: "short",
    }).format(new Date(workspaceChatUpdatedAt));
    await expect(
      content.getByRole("heading", {
        name: expectedWorkspaceChatDate,
        exact: true,
      })
    ).toBeVisible();
    // Match InboxView's compact-time unit conversion. Each displayed unit is
    // rounded before the next conversion, which can differ by one day from a
    // single millisecond-to-day division at a rounding boundary.
    const ageSeconds = Math.max(
      0,
      Math.round((Date.now() - workspaceChatUpdatedAt) / 1_000)
    );
    const expectedWorkspaceChatAgeDays = Math.round(
      Math.round(Math.round(ageSeconds / 60) / 60) / 24
    );
    await expect(workspaceChatItem).toContainText(`${expectedWorkspaceChatAgeDays}d`);
    await workspaceChatItem.click();
    await expect(appWindow).toHaveURL(
      new RegExp(
        `#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeWorkspaceChat.id}$`
      )
    );

    const conversation = content.getByRole("region", { name: "Conversation" });
    const textbox = conversation.getByRole("textbox", { name: "AI prompt" });
    await textbox.fill("Electron bridge smoke");
    await conversation
      .getByRole("button", { name: "Send message", exact: true })
      .click();
    await expect(textbox).toHaveAttribute("contenteditable", "true");
    await expect(textbox).toHaveText("");
    await expect(conversation.getByText("Electron bridge smoke")).toBeVisible();
    await expect(conversation.getByText(chatSmokeAssistantReply)).toBeVisible();
    expect(stub.messageBodies).toEqual([
      expect.objectContaining({
        message: { text: "Electron bridge smoke", type: "text" },
      }),
    ]);
    expect(
      stub.authHeaders.some((header) => header === "Bearer p0-smoke-session-token")
    ).toBe(true);
    const rendererAssetsFetches = await appWindow.evaluate(() => {
      const windowWithRecorder = window as Window & {
        commaSmokeAssetsFetches?: AssetsFetchRecord[];
      };
      return windowWithRecorder.commaSmokeAssetsFetches ?? [];
    });
    expect(rendererAssetsFetches.length).toBeGreaterThan(0);
    expect(
      rendererAssetsFetches.flatMap((fetchRecord) =>
        fetchRecord.headers.filter(([name]) => name === "authorization")
      )
    ).toEqual([]);
  } catch (error) {
    failed = true;
    throw error;
  } finally {
    await app.close();
    await stub.close();
    await rm(userDataDir, { force: true, recursive: true });
    const videoPath = await video?.path();
    if (videoPath && failed) {
      await testInfo.attach("electron-video", {
        path: videoPath,
        contentType: "video/webm",
      });
    } else if (videoPath) {
      await rm(videoPath, { force: true });
    }
  }
});

test("electron assets proxy streams SSE chunks incrementally", async ({
  browserName: _browserName,
}, testInfo) => {
  const stub = await startStreamingFlushStub();
  const userDataDir = await mkdtemp(join(tmpdir(), "comma-assets-stream-"));
  recordElectronOnboardingCompleted(userDataDir, [stub.userId]);
  const app = await electron.launch({
    args: [electronMain, "--lang=en-US", `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronChatEnv(stub.baseUrl),
    recordVideo: {
      dir: testInfo.outputPath("electron-video"),
      size: { width: 1280, height: 800 },
    },
  });
  let failed = false;
  let video: { path(): Promise<string> } | null = null;

  try {
    const appWindow = await findElectronWindowByNativeRole(app, "main-window");
    video = appWindow.video();
    await appWindow.waitForLoadState("domcontentloaded");

    const lifecycle = (await appWindow.evaluate(async () => {
      const scope = window as unknown as {
        commaNative?: {
          session?: {
            state?: { get?: () => Promise<unknown> };
          };
        };
      };
      return scope.commaNative?.session?.state?.get?.();
    })) as SessionLifecycleSnapshot | undefined;
    if (!lifecycle || lifecycle.phase !== "signed_in") {
      throw new Error("streaming flush probe requires a signed-in Main session");
    }
    const expectationHeaderValue = encodeSessionPresenceExpectation(
      sessionExpectation(lifecycle)
    );

    const result = await appWindow.evaluate(
      async ({ expectationHeaderName, expectationHeader }) => {
        const startedAt = performance.now();
        const response = await fetch("assets://./v1/streaming-flush-probe", {
          headers: {
            accept: "text/event-stream",
            [expectationHeaderName]: expectationHeader,
          },
        });
        const reader = response.body?.getReader();
        if (!reader) {
          throw new Error("streaming flush probe did not expose a readable body");
        }

        const decoder = new TextDecoder();
        const chunks: { atMs: number; text: string }[] = [];
        for (;;) {
          const { done, value } = await reader.read();
          const atMs = performance.now() - startedAt;
          if (done) {
            return {
              chunks,
              contentType: response.headers.get("content-type"),
              durationMs: atMs,
              status: response.status,
            };
          }
          chunks.push({ atMs, text: decoder.decode(value, { stream: true }) });
        }
      },
      {
        expectationHeader: expectationHeaderValue,
        expectationHeaderName: sessionPresenceExpectationHeader,
      }
    );

    expect(result.status).toBe(200);
    expect(result.contentType).toContain("text/event-stream");
    expect(result.chunks.map((chunk) => chunk.text).join("")).toContain('"step":3');
    expect(result.durationMs).toBeGreaterThanOrEqual(1_000);
    expect(result.chunks.length).toBeGreaterThanOrEqual(2);
    expect(result.durationMs - result.chunks[0]!.atMs).toBeGreaterThanOrEqual(600);
  } catch (error) {
    failed = true;
    throw error;
  } finally {
    await app.close();
    await stub.close();
    await rm(userDataDir, { force: true, recursive: true });
    const videoPath = await video?.path();
    if (videoPath && failed) {
      await testInfo.attach("electron-video", {
        path: videoPath,
        contentType: "video/webm",
      });
    } else if (videoPath) {
      await rm(videoPath, { force: true });
    }
  }
});

type AssetsFetchRecord = {
  headers: [string, string][];
  url: string;
};

function installAssetsFetchRecorder() {
  const windowWithRecorder = window as Window & {
    commaSmokeAssetsFetchRecorderInstalled?: boolean;
    commaSmokeAssetsFetches?: AssetsFetchRecord[];
  };
  if (windowWithRecorder.commaSmokeAssetsFetchRecorderInstalled) {
    return;
  }

  const fetches: AssetsFetchRecord[] = [];
  const originalFetch = window.fetch.bind(window);
  windowWithRecorder.commaSmokeAssetsFetchRecorderInstalled = true;
  windowWithRecorder.commaSmokeAssetsFetches = fetches;
  window.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    const requestUrl =
      typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const headers = new Headers(input instanceof Request ? input.headers : undefined);
    if (init?.headers) {
      new Headers(init.headers).forEach((value, name) => headers.set(name, value));
    }

    if (requestUrl.startsWith("assets://")) {
      fetches.push({
        headers: Array.from(headers.entries()).map(([name, value]) => [
          name.toLowerCase(),
          value,
        ]),
        url: requestUrl,
      });
    }

    return originalFetch(input, init);
  };
}

function startStreamingFlushStub() {
  const session = createE2eSessionProjection({ email: "smoke@comma.local" });
  const server = createServer((req, res) => {
    res.setHeader("access-control-allow-origin", "*");
    res.setHeader("access-control-allow-headers", "authorization,content-type,accept");
    res.setHeader("access-control-allow-methods", "GET,OPTIONS");
    if (req.method === "OPTIONS") {
      res.writeHead(204).end();
      return;
    }

    if (req.method === "GET" && req.url === "/v1/comma/workspaces") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ data: [] }));
      return;
    }

    if (req.method === "GET" && req.url === "/v1/comma/auth/session") {
      res.writeHead(200, {
        "cache-control": "no-store",
        "content-type": "application/json",
      });
      res.end(JSON.stringify(session));
      return;
    }

    if (req.method === "GET" && req.url === "/v1/streaming-flush-probe") {
      res.writeHead(200, {
        "cache-control": "no-cache",
        connection: "keep-alive",
        "content-type": "text/event-stream",
      });
      res.flushHeaders();
      writeProbeChunk(res, 1);
      setTimeout(() => {
        writeProbeChunk(res, 2);
        setTimeout(() => {
          writeProbeChunk(res, 3);
          res.end();
        }, 700);
      }, 700);
      return;
    }

    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: `unhandled ${req.method} ${req.url}` }));
  });

  return new Promise<{
    baseUrl: string;
    close: () => Promise<void>;
    userId: string;
  }>((resolveStub) => {
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address() as AddressInfo;
      resolveStub({
        baseUrl: `http://127.0.0.1:${port}`,
        close: () =>
          new Promise<void>((done) => (server as Server).close(() => done())),
        userId: session.user.id,
      });
    });
  });
}

function writeProbeChunk(res: { write: (chunk: string) => void }, step: number) {
  res.write(`event: probe\ndata: ${JSON.stringify({ step })}\n\n`);
}
