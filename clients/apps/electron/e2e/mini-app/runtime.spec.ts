/* eslint-disable unicorn/require-post-message-target-origin -- Messages target a MessagePort, not a Window. */
/* eslint-disable no-underscore-dangle -- Checks the actual private preload sentinel. */
import { closeElectronTestApp } from "../close-electron-test-app";
import { type ElectronApplication, type Page } from "@playwright/test";
import { test, expect, electron, electronTestDirectory } from "../electron-test";
import {
  startElectronTestServer,
  startElectronTlsTestServer,
  type ElectronTestServer,
} from "../electron-test-server";
import { readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { build } from "esbuild";
import { MAIN_SHUTDOWN_COMPLETE_LINE } from "../../src/main/e2e-shutdown-report";
import { sharedBuildDir } from "../../../../e2e/helpers/shared-build";

// The Comma app frame in Electron (design AFK-surf/Cue#4070 §7.1, §8): Main's
// `comma-app` scheme serves the runtime, its network guard and window security
// hold the frame, and the preload stays in the top frame. What the runtime
// does inside the frame is e2e/app-shell/mini-app-runtime.chromium.test.ts.

let app: ElectronApplication;
let page: Page;
let directory: string;
let requests: string[];
let server: ElectronTestServer;
let tls: ElectronTestServer;

let built: string;
test.beforeAll(async () => {
  built = await sharedBuildDir("mini-app-runtime", async (output) => {
    // The shipped runtime, the window security and the preload.
    await build({
      entryPoints: [resolve("packages/chat-contract/src/mini-app/runtime.ts")],
      outfile: join(output, "runtime.cjs"),
      bundle: true,
      minify: true,
      platform: "node",
      format: "cjs",
    });
    await build({
      entryPoints: [resolve("apps/electron/src/main/security.ts")],
      outfile: join(output, "security.cjs"),
      bundle: true,
      platform: "node",
      format: "cjs",
      external: ["electron"],
    });
    await build({
      entryPoints: [resolve("apps/electron/src/preload/index.ts")],
      outfile: join(output, "preload.cjs"),
      bundle: true,
      platform: "node",
      format: "cjs",
      external: ["electron"],
    });
    // The scheme and handler as Main registers them (src/main/protocol.ts).
    await writeFile(
      join(output, "main.cjs"),
      `
      const {app,BrowserWindow,protocol,session}=require('electron');
      const {installWindowSecurity,installSessionSecurity,installDynamicUiNetworkSecurity}=require('./security.cjs');
      const runtime=require('./runtime.cjs');
      const fs=require('node:fs');
      process.on('exit',()=>fs.writeSync(1,${JSON.stringify(`${MAIN_SHUTDOWN_COMPLETE_LINE}\n`)}));
      const report=(line)=>fs.appendFileSync(process.env.COMMA_APP_FIXTURE_LOG,line+'\\n');
      process.on('unhandledRejection',(error)=>report('startup failed: '+(error&&error.stack||error)));
      protocol.registerSchemesAsPrivileged([{scheme:'comma-app',privileges:{standard:true,secure:true}}]);
      app.whenReady().then(async()=>{
        report('ready');
        protocol.handle('comma-app',request=>request.url!==runtime.miniAppRuntimeUrl
          ?new Response('Not found',{status:404})
          :new Response(runtime.miniAppRuntimeDocument(),{headers:{'content-type':'text/html; charset=utf-8','content-security-policy':runtime.miniAppRuntimeCsp,'cache-control':'no-store'}}));
        installSessionSecurity(session.defaultSession);installDynamicUiNetworkSecurity(session.defaultSession);
        const window=new BrowserWindow({show:true,webPreferences:{backgroundThrottling:false,sandbox:true,contextIsolation:true,nodeIntegration:false,preload:${JSON.stringify(join(output, "preload.cjs"))}}});
        report('window created');
        installWindowSecurity({webContents:window.webContents});
        if(process.platform==='linux')window.showInactive();
        await window.loadURL('data:text/html,<html><body></body></html>');
      });`
    );
  });
});

test.beforeEach(async () => {
  directory = await electronTestDirectory("comma-app-test-");
  requests = [];
  server = await startElectronTestServer((request, response) => {
    requests.push(`http ${request.url ?? ""}`);
    response.end("unexpected request");
  });
  server.server.on("connection", () => requests.push("http connection"));
  server.server.on("upgrade", (request) => requests.push(`ws ${request.url ?? ""}`));
  tls = await startElectronTlsTestServer((request, response) => {
    requests.push(`https ${request.url ?? ""}`);
    response.setHeader("access-control-allow-origin", "*");
    response.end("unexpected request");
  });
});

test.afterEach(async () => {
  if (app) await closeElectronTestApp(app);
  await server.close();
  await tls.close();
});

async function launch() {
  app = await electron.launch({
    args: [join(built, "main.cjs")],
    env: {
      ...(process.env as Record<string, string>),
      COMMA_APP_FIXTURE_LOG: join(directory, "fixture.log"),
    },
  });
  page = await app.firstWindow().catch(async (error: unknown) => {
    const milestones = await readFile(join(directory, "fixture.log"), "utf8").catch(
      () => "(none)\n"
    );
    throw new Error(`${String(error)}\nFixture startup milestones:\n${milestones}`, {
      cause: error,
    });
  });
  // The window is first reported on its initial blank document; the fixture's
  // page is a navigation away, and evaluating before it lands loses the context.
  await page.waitForURL((url) => url.protocol === "data:");
}

/** Opens an app frame as the host does and runs `script` as the app's module. */
async function mount(script: string) {
  await page.evaluate((source) => {
    const host = window as unknown as {
      appMessages: Record<string, unknown>[];
      appDraft: Promise<Record<string, unknown>>;
    };
    host.appMessages = [];
    let drafted!: (message: Record<string, unknown>) => void;
    host.appDraft = new Promise((settle) => {
      drafted = settle;
    });
    let opened = false;
    window.addEventListener("message", (event) => {
      const frame = document.querySelector("iframe")!;
      if (
        opened ||
        event.source !== frame.contentWindow ||
        event.data?.type !== "comma-app:ready"
      )
        return;
      opened = true;
      const channel = new MessageChannel();
      channel.port1.addEventListener("message", (incoming) => {
        host.appMessages.push(incoming.data);
        if (incoming.data.op === "chat.draft") drafted(incoming.data);
        if (incoming.data.type === "call")
          channel.port1.postMessage({
            type: "result",
            id: incoming.data.id,
            ok: true,
            value: null,
          });
      });
      channel.port1.start();
      frame.contentWindow!.postMessage(
        {
          type: "comma-app:init",
          init: {
            app: { id: "app-1", name: "Test app", version: 1 },
            viewer: null,
            theme: "light",
            tokens: {},
            locale: "en-US",
            timeZone: "UTC",
            capabilities: ["chat.draft"],
            grants: ["chat.draft"],
            storage: [],
          },
        },
        "*",
        [channel.port2]
      );
      const encoder = new TextEncoder();
      channel.port1.postMessage({
        type: "files",
        files: [
          {
            path: "index.html",
            mime: "text/html",
            data: encoder.encode(
              '<p id="out">Loading</p><script type="module" src="app.js"></script>'
            ).buffer,
          },
          {
            path: "app.js",
            mime: "text/javascript",
            data: encoder.encode(source).buffer,
          },
        ],
      });
    });
    const frame = document.createElement("iframe");
    frame.sandbox.add("allow-scripts", "allow-forms");
    frame.src = "comma-app://runtime/";
    document.body.append(frame);
  }, script);
}

test("an app frame has an opaque origin, no native bridge and no network", async () => {
  await launch();
  const http = server.origin;
  const https = tls.origin;
  await mount(`
    const results = {};
    const deny = async (name, run) => { try { await run(); results[name] = "allowed"; } catch { results[name] = "blocked"; } };
    await deny("http", () => fetch(${JSON.stringify(`${http}/leak`)}));
    await deny("https", () => fetch(${JSON.stringify(`${https}/leak`)}, { mode: "no-cors" }));
    await deny("websocket", () => new Promise((resolve, reject) => { const socket = new WebSocket(${JSON.stringify(`${http.replace("http:", "ws:")}/leak`)}); socket.onopen = resolve; socket.onerror = reject; }));
    await deny("image", () => new Promise((resolve, reject) => { const image = new Image(); image.onload = resolve; image.onerror = reject; image.src = ${JSON.stringify(`${https}/image`)}; }));
    await deny("scheme", () => fetch("comma-app://runtime/other"));
    await deny("assets", () => fetch("assets://./v1/comma/workspaces"));
    results.origin = self.origin;
    results.bridge = typeof window.commaNative;
    results.preload = typeof window.__commaNativePreload;
    document.getElementById("out").textContent = "Started";
    await comma.chat.draft(JSON.stringify(results));
  `);
  // The app's last step: everything it checked is in the draft it proposes.
  const draft = await page.evaluate(
    () => (window as unknown as { appDraft: Promise<Record<string, unknown>> }).appDraft
  );
  expect(JSON.parse((draft.args as { text: string }).text)).toEqual({
    http: "blocked",
    https: "blocked",
    websocket: "blocked",
    image: "blocked",
    scheme: "blocked",
    assets: "blocked",
    origin: "null",
    bridge: "undefined",
    preload: "undefined",
  });
  await expect(page.frameLocator("iframe").locator("#out")).toHaveText("Started");
  expect(
    await page.frames()[1]!.evaluate(() => ({
      bridge: typeof (window as unknown as { commaNative?: unknown }).commaNative,
      preload: typeof (window as unknown as { __commaNativePreload?: unknown })
        .__commaNativePreload,
    }))
  ).toEqual({ bridge: "undefined", preload: "undefined" });
  expect(requests).toEqual([]);
});

test("an app frame cannot navigate itself or the window", async () => {
  await launch();
  await mount(`document.getElementById("out").textContent = "Started";`);
  await expect(page.frameLocator("iframe").locator("#out")).toHaveText("Started");
  const target = `${server.origin}/leak`;
  await page.frames()[1]!.evaluate((url) => {
    location.href = url;
  }, target);
  const topNavigation = await page.frames()[1]!.evaluate((url) => {
    try {
      top!.location.href = url;
      return "navigated";
    } catch {
      return "blocked";
    }
  }, target);
  expect(topNavigation).toBe("blocked");
  expect(page.frames()[1]!.url()).toBe("comma-app://runtime/");
  expect(page.url()).toMatch(/^data:/);
  expect(requests).toEqual([]);
});
