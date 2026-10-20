/* eslint-disable unicorn/require-post-message-target-origin -- Messages target a MessagePort, not a Window. */
/* eslint-disable no-underscore-dangle -- Checks the actual private preload sentinel. */
import { createElement } from "react";
import { closeElectronTestApp } from "../close-electron-test-app";
import { renderToStaticMarkup } from "react-dom/server";
import { IconCircleInfo } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconCircleInfo";
import { IconSun } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconSun";
import { IconMoon } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconMoon";
import { IconCloud } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconCloud";
import { IconCloudySun } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconCloudySun";
import { IconRainy } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconRainy";
import { IconSnowFlakes } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconSnowFlakes";
import { IconTrainFrontView } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconTrainFrontView";
import { type ElectronApplication, type Page } from "@playwright/test";
import {
  test,
  expect,
  electron,
  electronTestDirectory,
  type ElectronMainSetup,
} from "../electron-test";
import { setElectronCookie } from "../electron-operations";
import {
  startElectronTestServer,
  startElectronTlsTestServer,
  type ElectronTestServer,
} from "../electron-test-server";
import { readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { build } from "esbuild";
import { createRequire } from "node:module";
import {
  dynamicUiDocument,
  dynamicUiCsp,
} from "../../../../packages/chat-contract/src/dynamic-ui/runtime";
import { MAIN_SHUTDOWN_COMPLETE_LINE } from "../../src/main/e2e-shutdown-report";
import { sharedBuildDir } from "../../../../e2e/helpers/shared-build";

const widgetIcons = {
  info: renderToStaticMarkup(createElement(IconCircleInfo)),
  sun: renderToStaticMarkup(createElement(IconSun)),
  moon: renderToStaticMarkup(createElement(IconMoon)),
  cloud: renderToStaticMarkup(createElement(IconCloud)),
  "partly-cloudy": renderToStaticMarkup(createElement(IconCloudySun)),
  rain: renderToStaticMarkup(createElement(IconRainy)),
  snow: renderToStaticMarkup(createElement(IconSnowFlakes)),
  train: renderToStaticMarkup(createElement(IconTrainFrontView)),
};

let app: ElectronApplication;
let page: Page;
let directory: string;
let target: string;
let requests: string[];
let server: ElectronTestServer;

// The runtime, the window security and the preload a test's app loads, and
// the app's Main: built once per run, not per test.
let built: string;
test.beforeAll(async () => {
  built = await sharedBuildDir("dynamic-ui-runtime", async (output) => {
    await build({
      entryPoints: [resolve("packages/chat-contract/src/dynamic-ui/runtime.ts")],
      outfile: join(output, "runtime.cjs"),
      bundle: true,
      minify: true,
      platform: "node",
      format: "cjs",
    });
    const productionRuntime = createRequire(resolve("package.json"))(
      join(output, "runtime.cjs")
    ) as { dynamicUiDocument: typeof dynamicUiDocument };
    await writeFile(
      join(output, "runtime.html"),
      productionRuntime.dynamicUiDocument()
    );
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
    await writeFile(
      join(output, "main.cjs"),
      `
      const {app,BrowserWindow,protocol,session}=require('electron');
      const {installWindowSecurity,installSessionSecurity,installDynamicUiNetworkSecurity}=require('./security.cjs');
      const fs=require('node:fs');
      // No quit sequence of its own: Node's exit is its finished close.
      process.on('exit',()=>fs.writeSync(1,${JSON.stringify(`${MAIN_SHUTDOWN_COMPLETE_LINE}\n`)}));
      // Startup milestones in a file, so a launch that never shows its window says how far it got.
      const report=(line)=>fs.appendFileSync(process.env.COMMA_UI_FIXTURE_LOG,line+'\\n');
      process.on('unhandledRejection',(error)=>report('startup failed: '+(error&&error.stack||error)));
      app.on('child-process-gone',(_event,details)=>report('child process gone: '+details.type+' '+details.reason+' '+details.exitCode));
      protocol.registerSchemesAsPrivileged([{scheme:'comma-ui',privileges:{standard:true,secure:true,supportFetchAPI:true}}]);
      app.whenReady().then(async()=>{
        report('ready');
        protocol.handle('comma-ui', request=>new Response(fs.readFileSync(${JSON.stringify(join(output, "runtime.html"))}),{headers:{'content-type':'text/html','content-security-policy':${JSON.stringify(dynamicUiCsp)}}}));
        installSessionSecurity(session.defaultSession);installDynamicUiNetworkSecurity(session.defaultSession);
        // Shown, as Comma's windows are: a hidden window stops sending the
        // compositor's hit-test data, so input meant for the moved widget frame
        // (its own process) is routed by stale regions and never reaches it.
        const window=new BrowserWindow({show:true,webPreferences:{backgroundThrottling:false,sandbox:true,contextIsolation:true,nodeIntegration:false,preload:${JSON.stringify(join(output, "preload.cjs"))}}});
        report('window created');
        window.webContents.on('render-process-gone',(_event,details)=>report('renderer gone: '+details.reason+' '+details.exitCode));
        window.webContents.once('did-finish-load',()=>report('window loaded'));
        installWindowSecurity({webContents:window.webContents});
        // The widget is a cross-origin frame, so Chromium routes a click to it by
        // its composited hit-test regions. In an unmapped Linux window, a click
        // aimed at a widget button after the frame resized reached no handler in
        // CI. Product windows are mapped; map this one on the per-worker display.
        if(process.platform==='linux')window.showInactive();
        await window.loadURL('data:text/html,<html><body></body></html>');
      });`
    );
  });
});

test.beforeEach(async () => {
  directory = await electronTestDirectory("comma-ui-test-");
  requests = [];
  server = await startElectronTestServer((request, response) => {
    requests.push(request.url ?? "");
    response.end("unexpected request");
  });
  server.server.on("connection", () => requests.push("connection"));
  target = `${server.origin}/leak`;
});

/**
 * Launches the fixture app. What a test serves for `https:` is given here, at launch: the app's session has its
 * handler before the app's first window exists.
 */
async function launch(main?: ElectronMainSetup) {
  app = await electron.launch({
    args: [join(built, "main.cjs")],
    env: {
      ...(process.env as Record<string, string>),
      COMMA_UI_FIXTURE_LOG: join(directory, "fixture.log"),
    },
    main,
  });
  page = await app.firstWindow().catch(async (error: unknown) => {
    const milestones = await readFile(join(directory, "fixture.log"), "utf8").catch(
      () => "(none)\n"
    );
    throw new Error(`${String(error)}\nFixture startup milestones:\n${milestones}`, {
      cause: error,
    });
  });
}

test.afterEach(async () => {
  // What the widget told its host goes with a failure: a click that changed
  // nothing (two such failures on main) may follow a script the runtime
  // stopped, which only these messages say.
  const info = test.info();
  if (info.status !== info.expectedStatus && app)
    await info.attach("widget-messages", {
      body: JSON.stringify(
        await messages().catch((error: unknown) => String(error)),
        null,
        2
      ),
      contentType: "application/json",
    });
  // A bounded close: on Linux this bare app can outlive Playwright's teardown.
  if (app) await closeElectronTestApp(app);
  await server.close();
});

async function mount(
  agentScript: string,
  agentHtml = '<div class="stack"><p id="result">Initial</p><button id="refresh">Refresh</button></div>',
  initialData: Record<string, unknown> = { city: "Singapore" },
  initialTheme?: Record<string, string>,
  cardInit: Record<string, unknown> = {},
  container?: string
) {
  await page.evaluate(
    ({ script, html, data, icons, theme, cards, slot }) => {
      const host = window as unknown as { uiMessages: unknown[]; uiPort?: MessagePort };
      host.uiMessages = [];
      window.addEventListener("message", (event) => {
        const frame = document.querySelector("iframe")!;
        if (
          event.source !== frame.contentWindow ||
          event.data?.type !== "comma-ui:ready"
        )
          return;
        const channel = new MessageChannel();
        host.uiPort = channel.port1;
        channel.port1.addEventListener("message", (incoming) => {
          host.uiMessages.push(incoming.data);
          if (incoming.data.type === "height")
            frame.style.height = `${Math.min(12000, Math.max(60, incoming.data.value))}px`;
        });
        channel.port1.start();
        frame.contentWindow!.postMessage(
          {
            type: "comma-ui:init",
            payload: {
              version: 1,
              html,
              script,
              data,
            },
            state: {},
            icons,
            theme,
            ...cards,
          },
          "*",
          [channel.port2]
        );
      });
      const frame = document.createElement("iframe");
      frame.sandbox.add("allow-scripts");
      frame.src = "comma-ui://runtime/";
      frame.style.width = "300px";
      frame.style.border = "0";
      (slot ? document.querySelector(slot)! : document.body).append(frame);
    },
    {
      script: agentScript,
      html: agentHtml,
      data: initialData,
      icons: widgetIcons,
      theme: initialTheme,
      cards: cardInit,
      slot: container,
    }
  );
}
async function messages() {
  return page.evaluate(
    () => (window as unknown as { uiMessages: Record<string, unknown>[] }).uiMessages
  );
}

test("loads HTTPS presentation resources while external scripts stay inside the Worker", async () => {
  await launch({
    whenReady: ({ session }) => {
      session.defaultSession.protocol.handle("https", (request) => {
        const path = new URL(request.url).pathname;
        if (path === "/theme.css")
          return new Response("#result { font-style: italic }", {
            headers: { "content-type": "text/css", "access-control-allow-origin": "*" },
          });
        if (path === "/library.js")
          return new Response(
            `
        globalThis.libraryValue = typeof document + ':' + typeof Worker;
        fetch('https://widget.test/forbidden').then(()=>comma.text('result','LEAK'),()=>comma.text('result',libraryValue));
      `,
            {
              headers: {
                "content-type": "text/javascript",
                "access-control-allow-origin": "*",
              },
            }
          );
        if (path === "/image.svg")
          return new Response(
            '<svg xmlns="http://www.w3.org/2000/svg" width="12" height="8"><rect width="12" height="8" fill="red"/></svg>',
            {
              headers: {
                "content-type": "image/svg+xml",
                "access-control-allow-origin": "*",
              },
            }
          );
        throw Error("Unexpected external request: " + request.url);
      });
    },
  });
  await mount(
    "",
    `<link rel="stylesheet" href="https://widget.test/theme.css"><script src="https://widget.test/library.js"></script><img id="photo" src="https://widget.test/image.svg" alt="Test image"><p id="result">Loading</p>`
  );
  const frame = page.frameLocator("iframe");
  await expect(frame.locator("#result")).toHaveText("undefined:undefined");
  await expect(frame.locator("#result")).toHaveCSS("font-style", "italic");
  await expect
    .poll(() =>
      frame
        .locator("#photo")
        .evaluate((node) => (node as HTMLImageElement).naturalWidth)
    )
    .toBe(12);
  expect(requests).toEqual([]);
});

test("loads declared HTTPS resources but blocks dependency and authored script egress", async () => {
  const font = await readFile(resolve("packages/ui/src/fonts/InterVariable.woff2"));
  const received: {
    path: string;
    cookie: string | undefined;
    authorization: string | undefined;
    referer: string | undefined;
  }[] = [];
  await launch();
  // The app trusts the TLS test server's certificate from its launch.
  const resources = await startElectronTlsTestServer((request, response) => {
    const path = request.url ?? "/";
    received.push({
      path,
      cookie: request.headers.cookie,
      authorization: request.headers.authorization,
      referer: request.headers.referer,
    });
    response.setHeader("Access-Control-Allow-Origin", "*");
    if (path === "/downgrade") {
      response.writeHead(302, { location: target });
      response.end();
      return;
    }
    if (path === "/redirect") {
      response.writeHead(302, { location: "/image" });
      response.end();
      return;
    }
    if (path === "/style") {
      response.setHeader("Content-Type", "text/css");
      response.end(
        '@font-face{font-family:widget-test;src:url("/font")}#result{font-family:widget-test;font-style:italic}'
      );
      return;
    }
    if (path === "/font") {
      response.setHeader("Content-Type", "font/woff2");
      response.end(font);
      return;
    }
    if (path.startsWith("/leak?")) {
      response.setHeader("Content-Type", "text/javascript");
      response.end("void 0;");
      return;
    }
    if (path === "/script") {
      response.setHeader("Content-Type", "text/javascript");
      response.end(`
          globalThis.probeImports = (value) => {
            const url = ${JSON.stringify(origin)} + '/leak?value=' + encodeURIComponent(value);
            let blocked = 0;
            for (const owner of [globalThis, Object.getPrototypeOf(globalThis)]) {
              try { const load = owner['importScripts']; load.call(globalThis, url); }
              catch { blocked++; }
            }
            return blocked === 2;
          };
          comma.request('dependency:' + probeImports('dependency-private'));
          comma.text("result",typeof document);
        `);
      return;
    }
    response.setHeader("Content-Type", "image/svg+xml");
    response.end('<svg xmlns="http://www.w3.org/2000/svg" width="12" height="8"/>');
  });
  const origin = resources.origin;
  try {
    await setElectronCookie(app, {
      url: origin,
      name: "private-session",
      value: "must-not-leak",
      secure: true,
      sameSite: "no_restriction",
    });
    await mount(
      `comma.request('authored:' + probeImports(comma.data.city));
       comma.on('secret', 'input', event => comma.request('input:' + probeImports(event.value)));`,
      `<link rel="stylesheet" href="${origin}/style"><script src="${origin}/script"></script><img id="photo" src="${origin}/redirect" alt="Image"><img src="${origin}/downgrade" alt="Blocked"><p id="result">Loading</p><input id="secret" type="text">`
    );
    await expect(page.frameLocator("iframe").locator("#result")).toHaveText(
      "undefined"
    );
    await expect
      .poll(() =>
        page
          .frameLocator("iframe")
          .locator("#photo")
          .evaluate((node) => (node as HTMLImageElement).naturalWidth)
      )
      .toBe(12);
    await expect
      .poll(() => received.some((entry) => entry.path === "/font"))
      .toBe(true);
    await page.frameLocator("iframe").locator("#secret").fill("user-private");
    await expect
      .poll(async () =>
        (await messages())
          .filter((message) => message.type === "request")
          .map((message) => message.value)
      )
      .toEqual(["dependency:true", "authored:true", "input:true"]);
    expect(received.filter((entry) => entry.path.startsWith("/leak?"))).toEqual([]);
    expect(
      received.every((entry) => !entry.cookie && !entry.authorization && !entry.referer)
    ).toBe(true);
    expect(requests).toEqual([]);
  } finally {
    await resources.close();
  }
});

test("bounds simultaneous resource loading without blocking the chat", async () => {
  await launch({
    whenReady: ({ session }) => {
      const state = globalThis as typeof globalThis & { resourceLoads: number };
      state.resourceLoads = 0;
      session.defaultSession.protocol.handle("https", async () => {
        state.resourceLoads++;
        await new Promise((finishDelay) => setTimeout(finishDelay, 300));
        return new Response(
          '<svg xmlns="http://www.w3.org/2000/svg" width="12" height="8"/>',
          {
            headers: {
              "content-type": "image/svg+xml",
              "access-control-allow-origin": "*",
            },
          }
        );
      });
    },
  });
  await mount(
    "",
    Array.from(
      { length: 140 },
      (_, i) => `<img src="https://widget.test/${i}.svg" alt="Test">`
    ).join("") + '<p id="result">Responsive</p>'
  );
  await expect
    .poll(() =>
      page
        .frameLocator("iframe")
        .locator("img")
        .evaluateAll((nodes) =>
          nodes.every((node) => (node as HTMLImageElement).complete)
        )
    )
    .toBe(true);
  const loads = await app.evaluate(
    () => (globalThis as typeof globalThis & { resourceLoads: number }).resourceLoads
  );
  expect(loads).toBeGreaterThan(0);
  expect(loads).toBeLessThanOrEqual(8);
  await expect(page.frameLocator("iframe").locator("#result")).toHaveText("Responsive");
});

// The widget frame is the runtime's alone: Electron gives it no preload and
// no native bridge. (What the frame's script may reach is
// e2e/app-shell/dynamic-ui-runtime.chromium.test.ts.)
test("the widget frame has no native bridge or preload", async () => {
  await launch();
  await mount("comma.text('result', comma.data.city);");
  await expect(page.frameLocator("iframe").locator("#result")).toHaveText("Singapore");
  expect(
    await page.frames()[1]!.evaluate(() => ({
      bridge: typeof (window as unknown as { commaNative?: unknown }).commaNative,
      preload: typeof (window as unknown as { __commaNativePreload?: unknown })
        .__commaNativePreload,
    }))
  ).toEqual({ bridge: "undefined", preload: "undefined" });
});

test("terminates a stuck worker and keeps the transcript responsive", async () => {
  await launch();
  await mount("while(true){}");
  await expect
    .poll(async () =>
      (await messages()).some(
        (message) =>
          message.type === "error" && message.reason === "UI script timed out"
      )
    )
    .toBe(true);
  expect(await page.evaluate(() => 1 + 1)).toBe(2);
});

// Main refuses the widget frame's own navigation (installWindowSecurity).
test("the widget frame cannot navigate itself away", async () => {
  await launch();
  await mount("comma.text('result', comma.data.city);");
  await expect(page.frameLocator("iframe").locator("#result")).toHaveText("Singapore");
  await page.frames()[1]!.evaluate((url) => {
    location.href = url;
  }, target);
  expect(page.frames()[1]!.url()).toBe("comma-ui://runtime/");
  expect(requests).toEqual([]);
});

// The widget is a frame of its own process: Chromium routes a click to it by
// the regions the compositor last drew for it. A click sent before the frame
// drew its new size reached nothing (twice on main). The click waits until
// the frame and its page have each drawn a frame since the widget last
// resized: what the browser will hit is what the page shows.
test("a trusted click reaches the widget in its own process once it has drawn", async () => {
  await launch();
  await mount(
    "let n=0; comma.on('add','click',()=>comma.text('count',String(++n)));",
    '<section class="card"><strong id="count" class="metric">0</strong><button id="add">Add</button></section>'
  );
  const frame = page.frameLocator("iframe");
  await expect(frame.locator("#count")).toHaveText("0");
  await drawn();
  await frame.locator("#add").click();
  await expect(frame.locator("#count")).toHaveText("1");
  // A new theme lays the widget out again.
  await page.evaluate(() =>
    (window as unknown as { uiPort: MessagePort }).uiPort.postMessage({
      type: "theme",
      theme: { scheme: "dark" },
    })
  );
  await expect(frame.locator("html")).toHaveCSS("color-scheme", "dark");
  await drawn();
  await frame.locator("#add").click();
  await expect(frame.locator("#count")).toHaveText("2");
});

/**
 * The widget has the height it last asked for, and the frame and then its
 * page have each drawn since: the compositor's regions for the frame are the
 * ones on screen.
 */
async function drawn() {
  const frame = page.frameLocator("iframe");
  await expect
    .poll(() =>
      frame.locator("body").evaluate((body) => {
        const height = Math.min(
          12000,
          Math.max(60, Math.ceil(body.getBoundingClientRect().height))
        );
        return window.innerHeight === height;
      })
    )
    .toBe(true);
  await page.frames()[1]!.evaluate(nextFrames);
  await page.evaluate(nextFrames);
}

/** Resolves once the document has drawn twice more: its next frame was presented. */
function nextFrames() {
  return new Promise<void>((done) =>
    // ast-grep-ignore: ts-test-timer -- the browser's own frames, the event the click waits for, not a time.
    requestAnimationFrame(() =>
      // ast-grep-ignore: ts-test-timer -- the browser's own frames, the event the click waits for, not a time.
      requestAnimationFrame(() => done())
    )
  );
}
