/* eslint-disable unicorn/require-post-message-target-origin -- Messages target a MessagePort, not a Window. */
/* eslint-disable no-underscore-dangle -- Checks the actual private preload sentinel. */
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { IconCircleInfo } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconCircleInfo";
import { IconSun } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconSun";
import { IconMoon } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconMoon";
import { IconCloud } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconCloud";
import { IconCloudySun } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconCloudySun";
import { IconRainy } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconRainy";
import { IconSnowFlakes } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconSnowFlakes";
import { IconTrainFrontView } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconTrainFrontView";
import {
  test,
  expect,
  _electron as electron,
  type ElectronApplication,
  type Page,
} from "@playwright/test";
import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createServer } from "node:http";
import { createServer as createHttpsServer } from "node:https";
import { execFileSync } from "node:child_process";
import { build } from "esbuild";
import { createRequire } from "node:module";
import {
  dynamicUiDocument,
  dynamicUiCsp,
} from "../../../../packages/chat-contract/src/dynamic-ui/runtime";

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
let server: ReturnType<typeof createServer>;

test.beforeEach(async () => {
  directory = await mkdtemp(join(tmpdir(), "comma-ui-test-"));
  requests = [];
  server = createServer((request, response) => {
    requests.push(request.url ?? "");
    response.end("unexpected request");
  });
  server.on("connection", () => requests.push("connection"));
  await new Promise<void>((resolveListen) =>
    server.listen(0, "127.0.0.1", resolveListen)
  );
  const address = server.address();
  target = `http://127.0.0.1:${typeof address === "object" && address ? address.port : 0}/leak`;
  await build({
    entryPoints: [resolve("packages/chat-contract/src/dynamic-ui/runtime.ts")],
    outfile: join(directory, "runtime.cjs"),
    bundle: true,
    minify: true,
    platform: "node",
    format: "cjs",
  });
  const productionRuntime = createRequire(resolve("package.json"))(
    join(directory, "runtime.cjs")
  ) as { dynamicUiDocument: typeof dynamicUiDocument };
  await writeFile(
    join(directory, "runtime.html"),
    productionRuntime.dynamicUiDocument()
  );
  await build({
    entryPoints: [resolve("apps/electron/src/main/security.ts")],
    outfile: join(directory, "security.cjs"),
    bundle: true,
    platform: "node",
    format: "cjs",
    external: ["electron"],
  });
  await build({
    entryPoints: [resolve("apps/electron/src/preload/index.ts")],
    outfile: join(directory, "preload.cjs"),
    bundle: true,
    platform: "node",
    format: "cjs",
    external: ["electron"],
  });
  await writeFile(
    join(directory, "main.cjs"),
    `
    const {app,BrowserWindow,protocol,session}=require('electron');
    const {installWindowSecurity,installSessionSecurity,installDynamicUiNetworkSecurity}=require('./security.cjs');
    const fs=require('node:fs');
    protocol.registerSchemesAsPrivileged([{scheme:'comma-ui',privileges:{standard:true,secure:true,supportFetchAPI:true}}]);
    app.whenReady().then(async()=>{
      protocol.handle('comma-ui', request=>new Response(fs.readFileSync(${JSON.stringify(join(directory, "runtime.html"))}),{headers:{'content-type':'text/html','content-security-policy':${JSON.stringify(dynamicUiCsp)}}}));
      installSessionSecurity(session.defaultSession);installDynamicUiNetworkSecurity(session.defaultSession);
      const window=new BrowserWindow({show:false,webPreferences:{sandbox:true,contextIsolation:true,nodeIntegration:false,preload:${JSON.stringify(join(directory, "preload.cjs"))}}});
      installWindowSecurity({webContents:window.webContents});
      await window.loadURL('data:text/html,<html><body></body></html>');
    });`
  );
  app = await electron.launch({ args: [join(directory, "main.cjs")] });
  page = await app.firstWindow();
});

test.afterEach(async () => {
  await app?.close();
  await new Promise<void>((done) => server.close(() => done()));
  await rm(directory, { recursive: true, force: true });
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
  await app.evaluate(({ session }) => {
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
  execFileSync(
    "openssl",
    [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      join(directory, "key.pem"),
      "-out",
      join(directory, "cert.pem"),
      "-days",
      "1",
      "-subj",
      "/CN=127.0.0.1",
    ],
    { stdio: "ignore" }
  );
  const font = await readFile(resolve("packages/ui/src/fonts/InterVariable.woff2"));
  const received: {
    path: string;
    cookie: string | undefined;
    authorization: string | undefined;
    referer: string | undefined;
  }[] = [];
  const resources = createHttpsServer(
    {
      key: await readFile(join(directory, "key.pem")),
      cert: await readFile(join(directory, "cert.pem")),
    },
    (request, response) => {
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
    }
  );
  await new Promise<void>((resolveListen) =>
    resources.listen(0, "127.0.0.1", resolveListen)
  );
  const address = resources.address();
  const origin = `https://127.0.0.1:${typeof address === "object" && address ? address.port : 0}`;
  try {
    await app.evaluate(async ({ session }, url) => {
      session.defaultSession.setCertificateVerifyProc((request, callback) =>
        callback(request.hostname === "127.0.0.1" ? 0 : -3)
      );
      await session.defaultSession.cookies.set({
        url,
        name: "private-session",
        value: "must-not-leak",
        secure: true,
        sameSite: "no_restriction",
      });
    }, origin);
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
    resources.closeAllConnections();
    await new Promise<void>((done) => resources.close(() => done()));
  }
});

test("bounds simultaneous resource loading without blocking the chat", async () => {
  await app.evaluate(({ session }) => {
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

test("runs local interaction while requests, imports, nested workers and storage stay blocked", async () => {
  await mount(`(async()=>{
    const results={};
    const deny=async(name,fn)=>{try{await fn();results[name]='allowed'}catch{results[name]='blocked'}};
    await deny('fetch',()=>fetch(${JSON.stringify(target)}));
    await deny('noCors',()=>fetch(${JSON.stringify(target)},{mode:'no-cors'}));
    await deny('websocket',()=>new Promise((resolve,reject)=>{const s=new WebSocket(${JSON.stringify(target.replace("http:", "ws:"))});s.onopen=resolve;s.onerror=reject}));
    await deny('imports',()=>importScripts(${JSON.stringify(target)}));
    await deny('dynamicImport',()=>import(${JSON.stringify(target)}));
    await deny('dataImport',()=>import('data:text/javascript,export default 1'));
    await deny('nested',()=>new Worker(URL.createObjectURL(new Blob(['postMessage(1)']))));
    await deny('assets',()=>fetch('assets://./v1/comma/workspaces'));
    await deny('file',()=>fetch('file:///etc/passwd'));
    await deny('idb',()=>indexedDB.open('test'));
    await deny('cache',()=>caches.open('test'));
    await deny('broadcast',()=>new BroadcastChannel('test'));
    await deny('sharedWorker',()=>new SharedWorker('data:text/javascript,void 0'));
    await deny('transport',()=>new WebTransport(${JSON.stringify(target.replace("http:", "https:"))}).ready);
    results.dom=typeof document;results.rtc=typeof RTCPeerConnection;
    comma.request(JSON.stringify(results));comma.text('result',comma.data.city);
    comma.on('refresh','click',()=>comma.request('Refresh weather'));
  })()`);
  await expect
    .poll(async () => (await messages()).some((message) => message.type === "request"))
    .toBe(true);
  const result = (await messages()).find((message) => message.type === "request")!;
  expect(JSON.parse(String(result.value))).toEqual({
    fetch: "blocked",
    noCors: "blocked",
    websocket: "blocked",
    imports: "blocked",
    dynamicImport: "blocked",
    dataImport: "blocked",
    nested: "blocked",
    assets: "blocked",
    file: "blocked",
    idb: "blocked",
    cache: "blocked",
    broadcast: "blocked",
    sharedWorker: "blocked",
    transport: "blocked",
    dom: "undefined",
    rtc: "undefined",
  });
  const frame = page.frameLocator("iframe");
  await expect(frame.locator("#result")).toHaveText("Singapore");
  expect(
    await page.frames()[1]!.evaluate(() => ({
      bridge: typeof (window as unknown as { commaNative?: unknown }).commaNative,
      preload: typeof (window as unknown as { __commaNativePreload?: unknown })
        .__commaNativePreload,
    }))
  ).toEqual({ bridge: "undefined", preload: "undefined" });
  await frame.locator("#refresh").focus();
  await frame.locator("#refresh").press("Enter");
  await expect
    .poll(async () =>
      (await messages()).some((message) => message.value === "Refresh weather")
    )
    .toBe(true);
  expect(requests).toEqual([]);
});

test("button handlers receive clicks on nested labels and SVG icons", async () => {
  await mount(
    `let count = 0; comma.on('refresh', 'click', () => comma.text('result', String(++count)));`,
    '<p id="result">0</p><button id="refresh"><span id="label">Refresh</span><comma-icon name="sun"></comma-icon></button>'
  );
  const frame = page.frameLocator("iframe");
  await frame.locator("#label").click();
  await expect(frame.locator("#result")).toHaveText("1");
  await frame.locator("#refresh svg").click();
  await expect(frame.locator("#result")).toHaveText("2");
  await frame.locator("#refresh").focus();
  await frame.locator("#refresh").press("Enter");
  await expect(frame.locator("#result")).toHaveText("3");
});

test("renders calendar line breaks without rejecting the widget", async () => {
  await mount(
    "",
    "<table><tbody><tr><td>25<br/><small>Holiday</small></td></tr></tbody></table>"
  );
  const cell = page.frameLocator("iframe").locator("td");
  await expect(cell).toBeVisible();
  await expect(cell).toHaveText("25Holiday");
  await expect(cell.locator("br")).toHaveCount(1);
  const positions = await cell.evaluate((node) => {
    const range = document.createRange();
    range.selectNodeContents(node.firstChild!);
    return {
      date: range.getBoundingClientRect().bottom,
      label: node.querySelector("small")!.getBoundingClientRect().top,
    };
  });
  expect(positions.label).toBeGreaterThanOrEqual(positions.date - 1);
});

test("rejects hostile markup without requesting resources", async () => {
  await mount("", `<img src="${target}"><p>Unsafe</p>`);
  await expect
    .poll(async () => (await messages()).some((message) => message.type === "error"))
    .toBe(true);
  expect(requests).toEqual([]);
});

test("bounds chart allocation and recovers shared state without business calls", async ({
  browserName,
}, testInfo) => {
  void browserName;
  await mount(
    "comma.chart('trend',{labels:['Mon','Tue'],values:[25,27],type:'line'});comma.onState(state=>comma.text('result',state.filter));",
    '<div class="stack"><p id="result">All</p><comma-chart id="trend"></comma-chart></div>'
  );
  const frame = page.frameLocator("iframe");
  await expect(frame.locator("canvas")).toHaveAttribute("role", "img");
  await expect(frame.locator("canvas")).toHaveAttribute("aria-label", /Mon/);
  await page.evaluate(() =>
    (window as unknown as { uiPort: MessagePort }).uiPort.postMessage({
      type: "state",
      value: { filter: "Tomorrow" },
    })
  );
  await expect(frame.locator("#result")).toHaveText("Tomorrow");
  expect((await messages()).filter((message) => message.type === "request")).toEqual(
    []
  );
  expect(
    await frame.locator("canvas").evaluate((node) => node.getBoundingClientRect().width)
  ).toBeLessThanOrEqual(300);
  await expect
    .poll(async () => (await messages()).some((message) => message.type === "height"))
    .toBe(true);
  await page.screenshot({ path: testInfo.outputPath("narrow-card.png") });
});

test("rejects excess chart allocation before starting agent code", async () => {
  await mount(
    "comma.request('should not run')",
    "<comma-chart></comma-chart>".repeat(9)
  );
  await expect
    .poll(async () =>
      (await messages()).some(
        (message) =>
          message.type === "error" &&
          message.reason === "A UI supports at most eight charts"
      )
    )
    .toBe(true);
  expect((await messages()).filter((message) => message.type === "request")).toEqual(
    []
  );
});

test("terminates a stuck worker and keeps the transcript responsive", async () => {
  await mount("while(true){}");
  await expect
    .poll(
      async () =>
        (await messages()).some(
          (message) =>
            message.type === "error" && message.reason === "UI script timed out"
        ),
      { timeout: 5000 }
    )
    .toBe(true);
  expect(await page.evaluate(() => 1 + 1)).toBe(2);
});

test("rejects raw worker update floods and child-frame navigation", async () => {
  await mount(
    "for(let i=0;i<100;i++)postMessage({type:'text',id:'result',value:'flood'})"
  );
  await expect
    .poll(async () => (await messages()).some((message) => message.type === "error"))
    .toBe(true);
  await page.frames()[1]!.evaluate((url) => {
    location.href = url;
  }, target);
  expect(page.frames()[1]!.url()).toBe("comma-ui://runtime/");
  expect(requests).toEqual([]);
});

test("a render pass over a long paginated list counts as one update", async () => {
  // A generated rental list hid every row, then showed one page: 139 SDK calls
  // per render. Counted one call at a time, the first render broke the rate
  // limit, and Reload failed the same way.
  await mount(
    `const rows=comma.data.rows,pages=Math.ceil(rows.length/30);let page=0;
    function render(){
      for(let i=0;i<rows.length;i++)comma.visible('r'+i,false);
      for(let i=page*30;i<Math.min(rows.length,page*30+30);i++)comma.visible('r'+i,true);
      comma.text('page',(page+1)+' / '+pages);
    }
    comma.on('next','click',()=>{page=(page+1)%pages;render();});
    render();`,
    `<section><p id="page"></p><button id="next">Next</button>${Array.from(
      { length: 108 },
      (_, i) => `<p id="r${i}">Row ${i}</p>`
    ).join("")}</section>`,
    { rows: Array.from({ length: 108 }, (_, i) => i) }
  );
  const frame = page.frameLocator("iframe");
  await expect(frame.locator("#page")).toHaveText("1 / 4");
  await expect(frame.locator("p[id^='r']:visible")).toHaveCount(30);
  for (let i = 0; i < 3; i++) await frame.getByRole("button", { name: "Next" }).click();
  await expect(frame.locator("#page")).toHaveText("4 / 4");
  await expect(frame.locator("#r107")).toBeVisible();
  await expect(frame.locator("#r0")).toBeHidden();
  expect((await messages()).filter((item) => item.type === "error")).toEqual([]);
});

test("batched updates keep the data each call saw", async () => {
  // Calls leave together when the task ends. Each one must carry its own
  // copy, so a script that reuses and changes one object keeps both tables.
  await mount(
    "const value={columns:['Name'],rows:[['First']]};comma.table('first',value);value.rows=[['Second']];comma.table('second',value);",
    '<section><table id="first"></table><table id="second"></table></section>'
  );
  const frame = page.frameLocator("iframe");
  await expect(frame.locator("#first tbody td")).toHaveText("First");
  await expect(frame.locator("#second tbody td")).toHaveText("Second");
  expect((await messages()).filter((item) => item.type === "error")).toEqual([]);
});

test("batched updates keep the message and rate budgets", async () => {
  // 39 KB of text in one task leaves as two messages under the 32 KiB budget.
  await mount(
    "for(let i=0;i<10;i++)comma.text('t'+i,'x'.repeat(3900));",
    Array.from({ length: 10 }, (_, i) => `<p id="t${i}"></p>`).join("")
  );
  await expect(page.frameLocator("iframe").locator("#t9")).toHaveText("x".repeat(3900));
  expect((await messages()).filter((item) => item.type === "error")).toEqual([]);
  // One update per task still counts, so a script that updates in a timeout
  // loop is stopped.
  await page.reload();
  await mount(
    "let n=0;(function loop(){comma.text('result',String(n++));setTimeout(loop,0);})();"
  );
  await expect
    .poll(async () =>
      (await messages()).some(
        (item) => item.type === "error" && item.reason === "UI update rate exceeded"
      )
    )
    .toBe(true);
});

test("SDK batches and raw messages obey the UTF-8 byte budget", async () => {
  const html = Array.from({ length: 7 }, (_, i) => `<p id="t${i}"></p>`).join("");
  await mount("for(let i=0;i<7;i++)comma.text('t'+i,'汉'.repeat(4000));", html);
  await expect(page.frameLocator("iframe").locator("#t6")).toHaveText(
    "汉".repeat(4000)
  );
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);

  await page.reload();
  await mount(
    "postMessage({type:'batch',ops:Array.from({length:7},(_,i)=>({type:'text',id:'t'+i,value:'汉'.repeat(4000)}))});",
    html
  );
  await expect
    .poll(async () => (await messages()).find((m) => m.type === "error")?.reason)
    .toBe("UI message budget exceeded");
});

test("table data stays readable at chat widths and markup remains inert text", async ({
  browserName: _browserName,
}, testInfo) => {
  await mount(
    `
    const rows=[['09/21 周一','晴','28° / 22°','10%','东北风 2级'],['09/22 周二','小雨','25° / 21°','80%','东北风 3级']];
    comma.table('forecast',{columns:['日期','天气','最高 / 最低','降水','风'],rows});
    comma.on('refresh','click',()=>comma.table('forecast',{columns:['日期','备注'],rows:[['09/23','<img src="${target}">']]}));
  `,
    '<section class="stack"><h2>杭州天气</h2><small>演示数据 · 非实时预报</small><table id="forecast" aria-label="每日天气"></table><button id="refresh">切换数据</button></section>'
  );
  const frame = page.frameLocator("iframe");
  await expect(frame.getByRole("cell", { name: "东北风 3级" })).toBeVisible();
  for (const width of [320, 760]) {
    await page.locator("iframe").evaluate((node, value) => {
      node.style.width = `${value}px`;
    }, width);
    await expect
      .poll(() =>
        frame.locator("body").evaluate((node) => node.scrollWidth <= node.clientWidth)
      )
      .toBe(true);
    await expect(frame.getByRole("cell", { name: "28° / 22°" })).toBeVisible();
    await expect
      .poll(async () => {
        const contentHeight = await frame.locator("body > div").evaluate((node) => {
          const style = getComputedStyle(document.body);
          return Math.ceil(
            node.getBoundingClientRect().height +
              Number.parseFloat(style.paddingTop) +
              Number.parseFloat(style.paddingBottom)
          );
        });
        const frameHeight = await page
          .locator("iframe")
          .evaluate((node) => node.clientHeight);
        return frameHeight === contentHeight;
      })
      .toBe(true);
    await page
      .locator("iframe")
      .screenshot({ path: testInfo.outputPath(`table-${width}.png`) });
  }
  await frame.getByRole("button", { name: "切换数据" }).click();
  await expect(
    frame.getByRole("cell", { name: `<img src="${target}">` })
  ).toBeVisible();
  await expect(frame.locator("img")).toHaveCount(0);
  expect(requests).toEqual([]);
});

test("HTML passed to a dynamic table text target fails visibly instead of leaking tags", async () => {
  await mount(
    `const target='rows'; comma.text(target,'<tr><td>09/21 Mon</td></tr>');`,
    '<table><tbody id="rows"></tbody></table>'
  );
  await expect
    .poll(async () =>
      (await messages()).some(
        (item) => item.type === "error" && String(item.reason).includes("comma.table")
      )
    )
    .toBe(true);
  await expect(page.frameLocator("iframe").locator("body")).toBeEmpty();
});

test("table replacement is bounded across all tables and does not accumulate old rows", async () => {
  await mount(
    `
    const value={columns:['A','B','C','D','E','F'],rows:Array.from({length:24},()=>[1,2,3,4,5,6])};
    for(let i=0;i<4;i++)comma.table('first',value);
    comma.on('add','click',()=>comma.table('second',value));
  `,
    '<section><table id="first"></table><table id="second"></table><button id="add">Add table</button></section>'
  );
  await expect(page.frameLocator("iframe").locator("#first tbody tr")).toHaveCount(24);
  expect((await messages()).some((item) => item.type === "error")).toBe(false);
  await page.frameLocator("iframe").getByRole("button", { name: "Add table" }).click();
  await expect
    .poll(async () =>
      (await messages()).some(
        (item) => item.type === "error" && String(item.reason).includes("node budget")
      )
    )
    .toBe(true);
});

// Captured from the real-model weather evaluation, with the API name updated to Comma.
test("renders the recorded model-generated forecast in narrow and wide chats", async ({
  browserName: _browserName,
}, testInfo) => {
  const artifact = JSON.parse(
    await readFile(
      resolve("apps/electron/e2e/dynamic-ui/fixtures/weather-model-output.json"),
      "utf8"
    )
  );
  await mount(artifact.script, artifact.html, artifact.data);
  const frame = page.frameLocator("iframe");
  await expect(frame.getByRole("cell", { name: "28 / 22" })).toBeVisible();
  for (const width of [320, 760]) {
    await page.locator("iframe").evaluate((node, value) => {
      node.style.width = `${value}px`;
    }, width);
    await expect
      .poll(async () => {
        const height = await frame.locator("body > div").evaluate((node) => {
          const style = getComputedStyle(document.body);
          return Math.ceil(
            node.getBoundingClientRect().height +
              Number.parseFloat(style.paddingTop) +
              Number.parseFloat(style.paddingBottom)
          );
        });
        return (
          (await page.locator("iframe").evaluate((node) => node.clientHeight)) ===
          height
        );
      })
      .toBe(true);
    await expect
      .poll(() =>
        frame.locator("body").evaluate((node) => node.scrollWidth <= node.clientWidth)
      )
      .toBe(true);
    await page
      .locator("iframe")
      .screenshot({ path: testInfo.outputPath(`model-${width}.png`) });
  }
  expect((await messages()).some((item) => item.type === "error")).toBe(false);
});

test("renders the Worker result delivered as dynamic UI", async ({
  browserName: _browserName,
}, testInfo) => {
  const artifact = JSON.parse(
    await readFile(
      resolve("apps/electron/e2e/dynamic-ui/fixtures/weather-result-output.json"),
      "utf8"
    )
  );
  await mount(artifact.script, artifact.html, artifact.data);
  const frame = page.frameLocator("iframe");
  await expect(frame.locator("body")).toContainText("上海");
  await expect(frame.locator("body")).toContainText("Evaluation weather fixture");
  await expect(frame.locator("body")).toContainText("09/17");
  for (const width of [320, 760]) {
    await page.locator("iframe").evaluate((node, value) => {
      node.style.width = `${value}px`;
    }, width);
    await expect
      .poll(() =>
        frame.locator("body").evaluate((node) => node.scrollWidth <= node.clientWidth)
      )
      .toBe(true);
    await page
      .locator("iframe")
      .screenshot({ path: testInfo.outputPath(`worker-result-${width}.png`) });
  }
  expect((await messages()).filter((item) => item.type === "error")).toEqual([]);
});

test("text updates share the DOM budget and remove stale child targets", async () => {
  await mount(
    `for(let i=0;i<251;i++)comma.text('n'+i,'value');`,
    Array.from({ length: 500 }, (_, i) => `<span id="n${i}"></span>`).join("")
  );
  await expect
    .poll(async () =>
      (await messages()).some(
        (item) => item.type === "error" && String(item.reason).includes("node budget")
      )
    )
    .toBe(true);
  await page.reload();
  await mount(
    `comma.text('parent','Done');comma.table('old',{columns:['A'],rows:[[1]]});`,
    '<section id="parent"><table id="old"></table></section>'
  );
  await expect
    .poll(async () =>
      (await messages()).some(
        (item) => item.type === "error" && String(item.reason).includes("Invalid table")
      )
    )
    .toBe(true);
});

test("static Agent HTML renders without script startup errors", async () => {
  await mount(
    "",
    '<section class="stack"><h2>Weather fixture</h2><p>28 °C</p></section>'
  );
  await expect(page.frameLocator("iframe").locator("h2")).toHaveText("Weather fixture");
  expect((await messages()).filter((message) => message.type === "error")).toEqual([]);
  expect(requests).toEqual([]);
});

test("a late host listener can initialize an already loaded iframe", async () => {
  await page.evaluate(() => {
    const frame = document.createElement("iframe");
    frame.sandbox.add("allow-scripts");
    frame.src = "comma-ui://runtime/";
    document.body.append(frame);
  });
  await expect
    .poll(() => page.frames().some((frame) => frame.url() === "comma-ui://runtime/"))
    .toBe(true);
  await page.evaluate(
    () =>
      new Promise<void>((resolveReady) => {
        const frame = document.querySelector("iframe")!;
        window.addEventListener("message", (event) => {
          if (
            event.source !== frame.contentWindow ||
            event.data?.type !== "comma-ui:ready"
          )
            return;
          const channel = new MessageChannel();
          channel.port1.addEventListener("message", (incoming) => {
            if (incoming.data?.type === "ready") resolveReady();
          });
          channel.port1.start();
          frame.contentWindow!.postMessage(
            {
              type: "comma-ui:init",
              payload: { version: 1, html: "<p>Recovered</p>", script: "", data: {} },
            },
            "*",
            [channel.port2]
          );
        });
        frame.contentWindow!.postMessage({ type: "comma-ui:hello" }, "*");
      })
  );
  await expect(page.frameLocator("iframe").locator("p")).toHaveText("Recovered");
});

test("widget composition stays readable in wide and narrow light/dark chats", async () => {
  await mount(
    "comma.on('refresh','click',()=>comma.request('Refresh this weather forecast'));",
    `<div class="widget-grid">
      <section class="card"><div class="widget-head"><h2 class="widget-title">杭州 · 当前天气</h2><span class="widget-meta">示例数据</span></div><div class="widget-body"><p class="hero">26<span class="unit"> °C</span></p><p>多云，适合出行</p><p class="sub">最高 29° · 最低 22°</p></div><div class="widget-footer"><button id="refresh">刷新天气</button></div></section>
      <section class="card"><div class="widget-head"><h2>未来三天</h2></div><div class="list-item"><span class="grow">周四 · 多云</span><strong>26 / 21°</strong></div><div class="list-item"><span class="grow">周五 · 小雨</span><strong>24 / 20°</strong></div><div class="list-item"><span class="grow">周六 · 晴</span><strong>28 / 22°</strong></div><p class="sub">来源：测试数据 · 16:00 更新</p></section>
    </div>`
  );
  const widget = page.frameLocator("iframe");
  await expect(widget.getByRole("button", { name: "刷新天气" })).toBeVisible();
  for (const colorScheme of ["light", "dark"] as const) {
    await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
    await page.evaluate(
      (scheme) =>
        (window as unknown as { uiPort: MessagePort }).uiPort.postMessage({
          type: "theme",
          theme: { scheme },
        }),
      colorScheme
    );
    for (const width of [320, 760]) {
      await page.locator("iframe").evaluate((frame, value) => {
        frame.style.width = `${value}px`;
      }, width);
      await expect
        .poll(() =>
          widget
            .locator("body")
            .evaluate((body) => body.scrollWidth <= body.clientWidth)
        )
        .toBe(true);
      const cards = widget.locator(".card");
      const first = await cards.nth(0).boundingBox();
      const second = await cards.nth(1).boundingBox();
      expect(first).not.toBeNull();
      expect(second).not.toBeNull();
      if (width === 320) expect(second!.y).toBeGreaterThan(first!.y);
      else expect(second!.y).toBe(first!.y);
      await expect
        .poll(async () => (await page.locator("iframe").boundingBox())!.height)
        .toBeGreaterThan(second!.y + second!.height - 20);
      await page.screenshot({
        path: test.info().outputPath(`widgets-${colorScheme}-${width}.png`),
      });
    }
  }
  await widget.getByRole("button", { name: "刷新天气" }).focus();
  await page.keyboard.press("Enter");
  await expect
    .poll(messages)
    .toContainEqual({ type: "request", value: "Refresh this weather forecast" });
  expect((await messages()).filter((item: any) => item.type === "error")).toEqual([]);
});

// Unedited outputs from gpt-5.6-terra using the current ui.create contract and evaluation facts.
for (const scenario of ["weather", "journeys"]) {
  test(`renders designed ${scenario} and keeps local interactions functional`, async ({
    browserName: _browserName,
  }, testInfo) => {
    const artifact = JSON.parse(
      await readFile(
        resolve(
          `apps/electron/e2e/dynamic-ui/fixtures/${scenario}-designed-output.json`
        ),
        "utf8"
      )
    );
    await mount(artifact.script, artifact.html, artifact.data);
    const frame = page.frameLocator("iframe");
    await expect(frame.locator("body")).toContainText("杭州");
    if (scenario === "weather") {
      await expect(frame.locator("#todayHigh")).toHaveText("30");
      await expect(
        frame.getByRole("img", { name: "9/16: 30, 9/17: 31, 9/18: 26, 9/19: 27" })
      ).toBeVisible();
      await expect(frame.locator("#weather2")).toHaveText("小雨 26 / 20°C");
    } else {
      await expect(frame.locator("#train0")).toBeVisible();
      const item = await frame.locator("#train0").boundingBox();
      const heading = await frame.locator("#train0 > div").first().boundingBox();
      expect(heading!.width).toBeGreaterThan(item!.width - 2);
      await frame.getByLabel("按席位状态筛选").selectOption("waitlist");
      await expect(frame.locator("#train0")).toBeHidden();
      await expect(frame.locator("#train1")).toBeHidden();
      await expect(frame.locator("#train2")).toBeVisible();
      await frame.getByLabel("按席位状态筛选").selectOption("all");
      await expect(frame.locator("#train0")).toBeVisible();
      await frame.getByRole("button", { name: "查询更多班次或席别" }).click();
      await expect
        .poll(async () => (await messages()).some((m) => m.type === "request"))
        .toBe(true);
    }
    for (const colorScheme of ["light", "dark"] as const) {
      await page.emulateMedia({ colorScheme });
      await page.evaluate(
        (scheme) =>
          (window as unknown as { uiPort: MessagePort }).uiPort.postMessage({
            type: "theme",
            theme: { scheme },
          }),
        colorScheme
      );
      for (const width of [320, 760]) {
        await page.locator("iframe").evaluate((node, value) => {
          node.style.width = `${value}px`;
        }, width);
        await expect
          .poll(() =>
            frame
              .locator("body")
              .evaluate((node) => node.scrollWidth <= node.clientWidth)
          )
          .toBe(true);
        await expect
          .poll(async () => {
            const expected = await frame
              .locator("body > div")
              .evaluate((node) => Math.ceil(node.getBoundingClientRect().height + 4));
            return (
              (await page.locator("iframe").evaluate((node) => node.clientHeight)) ===
              Math.max(60, expected)
            );
          })
          .toBe(true);
        if (scenario === "weather") {
          await expect
            .poll(() =>
              frame
                .locator("canvas")
                .evaluate(
                  (node: HTMLCanvasElement) =>
                    Math.abs(
                      node.getContext("2d")!.getTransform().a * node.clientWidth -
                        node.width
                    ) < 1
                )
            )
            .toBe(true);
        }
        await page.locator("iframe").screenshot({
          path: testInfo.outputPath(`${scenario}-${colorScheme}-${width}.png`),
        });
      }
    }
    expect((await messages()).filter((item) => item.type === "error")).toEqual([]);
  });
}

test("widgets remain immediately visible with legacy entrance classes and interactive controls", async () => {
  await mount(
    "comma.on('refresh','click',()=>comma.request('Update forecast'))",
    '<section class="card stack"><div id="hero" class="feature motion-enter"><comma-icon name="partly-cloudy" class="icon-hero tone-warm" aria-label="晴间多云"></comma-icon><strong class="hero">30°C</strong></div><div class="compact-grid motion-stagger"><div><comma-icon name="sun" class="icon-lg tone-warm"></comma-icon><p>周四 晴</p></div><div><comma-icon name="rain" class="icon-lg tone-cool"></comma-icon><p>周五 小雨</p></div><div><comma-icon name="snow" class="icon-lg"></comma-icon><p>周六 雪</p></div></div><button id="refresh">更新预报</button></section>'
  );
  const frame = page.frameLocator("iframe");
  await expect(frame.getByRole("img", { name: "晴间多云" })).toBeVisible();
  expect(
    (await frame.getByRole("img", { name: "晴间多云" }).boundingBox())!.width
  ).toBe(48);
  const motion = await frame.locator("#hero").evaluate(async (element) => {
    element.classList.remove("motion-enter");
    void element.getBoundingClientRect();
    element.classList.add("motion-enter");
    const animations = element.getAnimations();
    const count = animations.length;
    await Promise.all(animations.map((animation) => animation.finished));
    return {
      count,
      opacity: getComputedStyle(element).opacity,
      transform: getComputedStyle(element).transform,
    };
  });
  expect(motion.count).toBe(0);
  expect(motion.opacity).toBe("1");
  await page.emulateMedia({ reducedMotion: "reduce" });
  await expect
    .poll(() =>
      frame.locator("#hero").evaluate((element) => element.getAnimations().length)
    )
    .toBe(0);
  await expect(frame.getByRole("img", { name: "晴间多云" })).toBeVisible();
  // The host must resize the initial iframe before the native click scrolls it.
  await expect
    .poll(async () => (await messages()).some((m) => m.type === "height"))
    .toBe(true);
  await frame.getByRole("button", { name: "更新预报" }).click();
  await expect
    .poll(async () => (await messages()).some((m) => m.type === "request"))
    .toBe(true);
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
});

test("renders model-authored weather with semantic icons and motion", async ({
  browserName: _browserName,
}, testInfo) => {
  const artifact = JSON.parse(
    await readFile(
      resolve("apps/electron/e2e/dynamic-ui/fixtures/weather-illustrated-output.json"),
      "utf8"
    )
  );
  await mount(artifact.script, artifact.html, artifact.data);
  const frame = page.frameLocator("iframe");
  await expect(frame.getByRole("img", { name: "晴", exact: true })).toBeVisible();
  await expect(frame.getByRole("img", { name: "小雨", exact: true })).toBeVisible();
  await expect(frame.locator("body")).toContainText("26 / 20°C");
  for (const colorScheme of ["light", "dark"] as const) {
    await page.emulateMedia({ colorScheme });
    await page.evaluate(
      (scheme) =>
        (window as unknown as { uiPort: MessagePort }).uiPort.postMessage({
          type: "theme",
          theme: { scheme },
        }),
      colorScheme
    );
    for (const width of [320, 760]) {
      await page.locator("iframe").evaluate((element, value) => {
        element.style.width = `${value}px`;
      }, width);
      await expect
        .poll(() =>
          frame
            .locator("canvas")
            .evaluate(
              (node: HTMLCanvasElement) =>
                Math.abs(
                  node.getContext("2d")!.getTransform().a * node.clientWidth -
                    node.width
                ) < 1
            )
        )
        .toBe(true);
      await expect
        .poll(async () => {
          const expected = await frame
            .locator("body > div")
            .evaluate((node) => Math.ceil(node.getBoundingClientRect().height + 4));
          return (
            (await page.locator("iframe").evaluate((node) => node.clientHeight)) ===
            expected
          );
        })
        .toBe(true);
      await expect
        .poll(() =>
          frame.locator("body").evaluate((node) => node.scrollWidth <= node.clientWidth)
        )
        .toBe(true);
      await page.locator("iframe").screenshot({
        path: testInfo.outputPath(`weather-icons-${colorScheme}-${width}.png`),
      });
    }
  }
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
});

test("only physical widget wheel input reaches the host scroll channel", async () => {
  await mount(
    "comma.on('attack','click',()=>postMessage({type:'wheel',deltaX:0,deltaY:999,deltaMode:0}))",
    '<section class="card"><p>Scrollable chat widget</p><button id="attack">Action</button></section>'
  );
  const frame = page.frameLocator("iframe");
  await expect(frame.getByText("Scrollable chat widget")).toBeVisible();
  await frame
    .locator("body")
    .evaluate((body) =>
      body.dispatchEvent(
        new WheelEvent("wheel", { bubbles: true, cancelable: true, deltaY: 500 })
      )
    );
  expect((await messages()).filter((m) => m.type === "wheel")).toEqual([]);
  await frame.getByText("Scrollable chat widget").hover();
  await page.mouse.wheel(0, 120);
  await expect
    .poll(async () =>
      (await messages())
        .filter((m) => m.type === "wheel")
        .reduce((sum, m) => sum + Number(m.deltaY), 0)
    )
    .toBe(120);
  await page.mouse.wheel(0, -80);
  await expect
    .poll(async () =>
      (await messages())
        .filter((m) => m.type === "wheel")
        .reduce((sum, m) => sum + Number(m.deltaY), 0)
    )
    .toBe(40);
  expect(await frame.locator("html").evaluate(() => window.scrollY)).toBe(0);
  await frame.getByRole("button", { name: "Action" }).click();
  await expect
    .poll(async () => (await messages()).some((m) => m.type === "error"))
    .toBe(true);
  expect(
    (await messages())
      .filter((m) => m.type === "wheel")
      .reduce((sum, m) => sum + Number(m.deltaY), 0)
  ).toBe(40);
});

test("a wheel over a widget scrolls the chat and tells the host first", async () => {
  await page.evaluate(() => {
    const chat = document.createElement("div");
    chat.id = "chat";
    chat.style.cssText = "height:300px;width:320px;overflow-y:auto";
    const slot = document.createElement("div");
    slot.id = "slot";
    const before = document.createElement("div");
    before.style.height = "120px";
    const after = document.createElement("div");
    after.style.height = "1200px";
    chat.append(before, slot, after);
    document.body.append(chat);
    const order: string[] = [];
    (window as unknown as { order: string[] }).order = order;
    chat.addEventListener("scroll", () => order.push("scroll"), { passive: true });
  });
  await mount(
    "",
    '<section class="card"><p>Widget in chat</p></section>',
    {},
    undefined,
    {},
    "#slot"
  );
  const frame = page.frameLocator("iframe");
  await expect(frame.getByText("Widget in chat")).toBeVisible();
  await expect
    .poll(() =>
      page.evaluate(() => Boolean((window as { uiPort?: MessagePort }).uiPort))
    )
    .toBe(true);
  await page.evaluate(() => {
    const host = window as unknown as { uiPort: MessagePort; order: string[] };
    host.uiPort.addEventListener("message", (event) => {
      if (event.data?.type === "wheel") host.order.push("wheel");
    });
  });

  await frame.getByText("Widget in chat").hover();
  await page.mouse.wheel(0, 120);

  await expect
    .poll(() => page.locator("#chat").evaluate((chat) => chat.scrollTop))
    .toBeGreaterThan(0);
  const order = await page.evaluate(
    () => (window as unknown as { order: string[] }).order
  );
  expect(order.indexOf("wheel")).toBeGreaterThanOrEqual(0);
  expect(order.indexOf("wheel")).toBeLessThan(order.indexOf("scroll"));
  expect(await frame.locator("html").evaluate(() => window.scrollY)).toBe(0);
});

test("keeps a model-authored seven-day forecast compact at chat widths", async ({
  browserName: _browserName,
}, testInfo) => {
  const artifact = JSON.parse(
    await readFile(
      resolve("apps/electron/e2e/dynamic-ui/fixtures/weather-simple-output.json"),
      "utf8"
    )
  );
  await mount(artifact.script, artifact.html, artifact.data);
  const frame = page.frameLocator("iframe");
  await expect(frame.locator("#heroHigh")).toHaveText("29°");
  await expect(frame.locator("#d6")).toHaveText("30° / 22°");
  for (const width of [760, 320]) {
    await page.locator("iframe").evaluate((element, value) => {
      element.style.width = `${value}px`;
    }, width);
    await expect
      .poll(() =>
        frame.locator("body").evaluate((node) => node.scrollWidth <= node.clientWidth)
      )
      .toBe(true);
    await expect
      .poll(async () => {
        const natural = await frame
          .locator("body > div")
          .evaluate((node) => Math.ceil(node.getBoundingClientRect().height + 4));
        return (
          (await page.locator("iframe").evaluate((node) => node.clientHeight)) ===
          natural
        );
      })
      .toBe(true);
    expect((await page.locator("iframe").boundingBox())!.height).toBeLessThan(
      width === 760 ? 340 : 500
    );
    await page
      .locator("iframe")
      .screenshot({ path: testInfo.outputPath(`simple-${width}.png`) });
  }
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
});

test("renders a real Task weather widget with readable atmospheric contrast", async ({
  browserName: _browserName,
}, testInfo) => {
  const artifact = JSON.parse(
    await readFile(
      resolve("apps/electron/e2e/dynamic-ui/fixtures/weather-task-output.json"),
      "utf8"
    )
  );
  await mount(artifact.script, artifact.html, artifact.data);
  const frame = page.frameLocator("iframe");
  await expect(frame.locator("#todayHigh")).toHaveText("28°");
  for (const colorScheme of ["light", "dark"] as const) {
    await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
    await page.evaluate(
      (scheme) =>
        (window as unknown as { uiPort: MessagePort }).uiPort.postMessage({
          type: "theme",
          theme: { scheme },
        }),
      colorScheme
    );
    for (const width of [760, 320]) {
      await page.locator("iframe").evaluate((node, value) => {
        node.style.width = `${value}px`;
      }, width);
      await expect
        .poll(() =>
          frame.locator("body").evaluate((node) => node.scrollWidth <= node.clientWidth)
        )
        .toBe(true);
      const color = await frame
        .locator("#todayHigh")
        .evaluate((node) => getComputedStyle(node).color);
      expect(color).toBe("rgb(255, 255, 255)");
      await page.locator("iframe").screenshot({
        path: testInfo.outputPath(`weather-${colorScheme}-${width}.png`),
      });
    }
  }
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
});

test("uses Comma palette instead of OS appearance and updates without losing interaction state", async () => {
  await page.emulateMedia({ colorScheme: "dark" });
  await mount(
    "let n=0; comma.on('add','click',()=>comma.text('count',String(++n)));",
    '<section class="card"><strong id="count" class="metric">0</strong><p id="context">Local count</p><button id="add">Add</button></section>',
    {},
    {
      scheme: "light",
      background: "rgb(247, 238, 226)",
      foreground: "rgb(40, 35, 30)",
      secondary: "rgb(85, 74, 61)",
      surface: "rgb(235, 223, 206)",
    }
  );
  const frame = page.frameLocator("iframe");
  await expect(frame.locator("section")).toHaveCSS(
    "background-color",
    "rgb(247, 238, 226)"
  );
  await expect(frame.locator("html")).toHaveCSS("color-scheme", "light");
  await expect(frame.locator("#context")).toHaveCSS("color", "rgb(85, 74, 61)");
  await frame.locator("#add").click();
  await expect(frame.locator("#count")).toHaveText("1");
  await page.emulateMedia({ colorScheme: "light" });
  await page.evaluate(() =>
    (window as unknown as { uiPort: MessagePort }).uiPort.postMessage({
      type: "theme",
      theme: {
        scheme: "dark",
        background: "rgb(36, 39, 56)",
        foreground: "rgb(238, 229, 248)",
        secondary: "rgb(195, 181, 207)",
        surface: "rgb(57, 48, 72)",
      },
    })
  );
  await expect(frame.locator("section")).toHaveCSS(
    "background-color",
    "rgb(36, 39, 56)"
  );
  await expect(frame.locator("html")).toHaveCSS("color-scheme", "dark");
  await expect(frame.locator("#count")).toHaveCSS("color", "rgb(238, 229, 248)");
  await expect(frame.locator("#context")).toHaveCSS("color", "rgb(195, 181, 207)");
  await frame.locator("#add").click();
  await expect(frame.locator("#count")).toHaveText("2");
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
});

test("whole-item links require user activation and leave navigation to the host", async () => {
  await mount(
    "",
    '<a href="https://example.test/train"><strong class="metric">18:01 → 19:03</strong><span> G1510</span></a>'
  );
  const link = page.frameLocator("iframe").locator("a");
  await expect(link).toBeVisible();
  await link.evaluate((node: HTMLElement) => node.click());
  expect((await messages()).filter((m) => m.type === "open-link")).toEqual([]);
  await link.click();
  await expect
    .poll(async () => (await messages()).filter((m) => m.type === "open-link").length)
    .toBe(1);
  await link.focus();
  await page.keyboard.press("Enter");
  await expect
    .poll(async () => (await messages()).filter((m) => m.type === "open-link").length)
    .toBe(2);
  expect((await messages()).find((m) => m.type === "open-link")?.url).toBe(
    "https://example.test/train"
  );
  expect(page.frames()[1]?.url()).toBe("comma-ui://runtime/");
  expect(requests).toEqual([]);
});

test("Worker cannot forge a link activation", async () => {
  await mount('postMessage({type:"open-link",url:"https://example.test/forged"})');
  await expect
    .poll(async () => (await messages()).some((m) => m.type === "error"))
    .toBe(true);
  expect((await messages()).filter((m) => m.type === "open-link")).toEqual([]);
});

test("renders Agent data through a card template with host tokens, logos and saved progress", async () => {
  const list = {
    title: "Launch checks",
    source: "Linear",
    sourceBrand: "linear",
    groups: [
      {
        items: [
          { id: "notes", label: "Update changelog", done: true },
          { id: "rollout", label: `<img src="${target}">` },
        ],
      },
    ],
    actions: [{ label: "Draft notes", prompt: "Draft the release notes" }],
  };
  await mount(
    'comma.card("card", "checklist", comma.data.list);',
    '<section id="card"></section>',
    { list },
    undefined,
    {
      seed: "block-1",
      locale: "en",
      copy: { checklistProgress: "{done}/{total} checked" },
      tokens: { "--color-text-primary": "rgb(1, 2, 3)", "--text-sm": "20px" },
      // Saved progress on this device wins over the Agent's done flags.
      cardState: { card: ["rollout"] },
    }
  );
  const frame = page.frameLocator("iframe");
  const markup = frame.getByText(`<img src="${target}">`);
  await expect(frame.getByText("Launch checks")).toBeVisible();
  // The frame grows to the card from height reports, which a hidden test
  // window throttles. Click only once it fits, so no click races a resize.
  await expect
    .poll(async () => {
      const box = await page.locator("iframe").boundingBox();
      const content = await frame.locator("body").evaluate((body) => body.scrollHeight);
      return box !== null && box.height >= content;
    })
    .toBe(true);
  await expect(markup).toBeVisible();
  await expect(frame.locator("img")).toHaveCount(0);
  await expect(frame.getByText("1/2 checked")).toBeVisible();
  await expect(
    frame.getByRole("checkbox", { name: "Update changelog" })
  ).not.toBeChecked();
  await expect(frame.getByText("Update changelog")).toHaveCSS("color", "rgb(1, 2, 3)");
  await expect(frame.getByText("Update changelog")).toHaveCSS("font-size", "20px");

  await expect
    .poll(async () => (await messages()).find((m) => m.type === "brand-icons")?.names)
    .toEqual(["linear"]);
  await page.evaluate(() =>
    (window as unknown as { uiPort: MessagePort }).uiPort.postMessage({
      type: "brand-icons",
      icons: {
        linear:
          '<svg data-logo="linear" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/></svg>',
      },
    })
  );
  await expect(frame.locator('[data-logo="linear"]')).toBeVisible();

  await frame.getByText("Update changelog").click();
  await expect(frame.getByRole("checkbox", { name: "Update changelog" })).toBeChecked();
  await expect(frame.getByText("2/2 checked")).toBeVisible();
  expect(
    (await messages()).filter((m) => m.type === "card-state").at(-1)?.value
  ).toEqual({
    card: ["rollout", "notes"],
  });

  await frame.getByRole("button", { name: "Draft notes" }).click();
  await expect
    .poll(async () => (await messages()).find((m) => m.type === "request")?.value)
    .toBe("Draft the release notes");
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
  expect(requests).toEqual([]);
});

test("checklist preserves original ids when duplicate rows save progress", async () => {
  const script = 'comma.card("card", "checklist", comma.data, "grouped");';
  const html = '<section id="card"></section>';
  const data = {
    title: "Two projects",
    groups: [
      { label: "Project A", items: [{ label: "Review" }] },
      { label: "Project B", items: [{ label: "Review" }] },
      { label: "Audit", items: [{ id: "Review#2", label: "Audit" }] },
    ],
  };
  await mount(script, html, data, undefined, { cardState: { card: ["Review#2"] } });
  const frame = page.frameLocator("iframe");
  await expect(frame.getByText("1 of 3 done")).toBeVisible();
  await expect(frame.getByRole("checkbox").nth(1)).not.toBeChecked();
  await expect(frame.getByRole("checkbox").nth(2)).toBeChecked();
  await expect
    .poll(async () => {
      const box = await page.locator("iframe").boundingBox();
      const content = await frame.locator("body").evaluate((body) => body.scrollHeight);
      return box !== null && box.height >= content;
    })
    .toBe(true);
  await frame.getByText("Review", { exact: true }).nth(1).click();
  await expect(frame.getByText("2 of 3 done")).toBeVisible();
  await expect(frame.getByRole("checkbox").nth(0)).not.toBeChecked();
  await expect(frame.getByRole("checkbox").nth(1)).toBeChecked();
  await expect(frame.getByRole("checkbox").nth(2)).toBeChecked();
  await expect(frame.getByText("0/1", { exact: true })).toBeVisible();
  await expect(frame.getByText("1/1", { exact: true })).toHaveCount(2);
  await expect
    .poll(async () => (await messages()).some((m) => m.type === "card-state"))
    .toBe(true);
  const saved = (await messages()).filter((m) => m.type === "card-state").at(-1)!.value;
  await page.reload();
  await mount(script, html, data, undefined, { cardState: saved });
  await expect(frame.getByRole("checkbox").nth(0)).not.toBeChecked();
  await expect(frame.getByRole("checkbox").nth(1)).toBeChecked();
  await expect(frame.getByRole("checkbox").nth(2)).toBeChecked();
  await expect(frame.getByText("2 of 3 done")).toBeVisible();
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
});

test("a status list shows each item's status in its tone and links the item", async () => {
  await mount(
    'comma.card("card", "feed", comma.data.prs);',
    '<section id="card"></section>',
    {
      prs: {
        title: "Open pull requests",
        items: [
          {
            source: "Comma #2076",
            brand: "github",
            title: "Composer typing independent of conversation",
            excerpt: "26/26 checks · approved",
            status: { label: "Clean", tone: "success" },
            href: "https://github.com/AFK-surf/Comma/pull/2076",
          },
          {
            source: "commaboard #2240",
            title: "Cmd+K command palette foundation",
            excerpt: "3 failed checks · review required",
            status: { label: "Blocked", tone: "error" },
            href: "https://github.com/AFK-surf/Comma/pull/2240",
          },
        ],
      },
    },
    undefined,
    {
      tokens: {
        "--color-text-success-primary": "rgb(0, 120, 0)",
        "--color-text-error-primary": "rgb(180, 0, 0)",
      },
    }
  );
  const frame = page.frameLocator("iframe");
  await expect(frame.getByText("Clean", { exact: true })).toHaveCSS(
    "color",
    "rgb(0, 120, 0)"
  );
  await expect(frame.getByText("Blocked", { exact: true })).toHaveCSS(
    "color",
    "rgb(180, 0, 0)"
  );
  // Without a time, the item's source stands alone.
  await expect(frame.getByText("Comma #2076", { exact: true })).toBeVisible();
  await expect(
    frame.getByRole("link", { name: /Cmd\+K command palette foundation/ })
  ).toHaveAttribute("href", "https://github.com/AFK-surf/Comma/pull/2240");
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
});

test("today forecast keeps all seven days visible in narrow and wide cards", async () => {
  await mount(
    'comma.card("card", "forecast", comma.data, "today");',
    '<section id="card"></section>',
    {
      title: "Seven day forecast",
      current: { temperature: 20, condition: "clear", label: "Clear" },
      days: Array.from({ length: 7 }, (_, index) => ({
        label: "Day " + (index + 1),
        condition: "clear",
        conditionLabel: "Clear",
        high: 25,
        low: 15,
      })),
    },
    undefined,
    { tokens: { "--spacing-xl": "16px", "--spacing-xs": "4px", "--text-xs": "12px" } }
  );
  const frame = page.frameLocator("iframe");
  for (const width of [320, 760]) {
    await page.locator("iframe").evaluate((element, size) => {
      element.style.width = size + "px";
    }, width);
    for (let day = 1; day <= 7; day++)
      await expect(frame.getByText("Day " + day, { exact: true })).toBeVisible();
    await expect
      .poll(() =>
        frame.locator("body").evaluate((body) => body.scrollWidth <= body.clientWidth)
      )
      .toBe(true);
  }
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
});

test("rejects card data its template cannot show", async () => {
  await mount(
    'comma.card("card", "checklist", { title: "Launch checks" });',
    '<section id="card"></section>'
  );
  await expect
    .poll(async () => (await messages()).find((m) => m.type === "error")?.reason)
    .toContain("groups");
  await expect(page.frameLocator("iframe").getByText("Launch checks")).toHaveCount(0);
});

test("card progress from another open copy reaches a card whose id is constructor", async () => {
  // A plain object read `constructor` from Object.prototype and crashed the
  // widget. Progress saved in another copy updates the card without an echo.
  await mount(
    'comma.card("constructor", "checklist", comma.data.list);',
    '<section id="constructor"></section>',
    {
      list: {
        title: "Launch checks",
        groups: [
          {
            items: [
              { id: "notes", label: "Update changelog" },
              { id: "rollout", label: "Roll out" },
            ],
          },
        ],
      },
    }
  );
  const frame = page.frameLocator("iframe");
  const rollout = frame.getByRole("checkbox", { name: "Roll out" });
  await expect(rollout).not.toBeChecked();
  await page.evaluate(() =>
    (window as unknown as { uiPort: MessagePort }).uiPort.postMessage({
      type: "card-state",
      value: { constructor: ["rollout"] },
    })
  );
  await expect(rollout).toBeChecked();
  await expect(
    frame.getByRole("checkbox", { name: "Update changelog" })
  ).not.toBeChecked();
  expect((await messages()).filter((m) => m.type === "card-state")).toEqual([]);
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
});

test("keeps card logos from overlapping host requests", async () => {
  await mount(
    `comma.card("first", "feed", {
      title: "First", groups: [{ source: "Linear", brand: "linear", summary: "Update", count: 1 }]
    }, "digest");
    comma.on("add", "click", () => comma.card("second", "feed", {
      title: "Second", groups: [{ source: "GitHub", brand: "github", summary: "Update", count: 1 }]
    }, "digest"));`,
    '<button id="add">Add card</button><section id="first"></section><section id="second"></section>'
  );
  const frame = page.frameLocator("iframe");
  const requested = async () =>
    (await messages())
      .filter((message) => message.type === "brand-icons")
      .map((message) => message.names);
  await expect.poll(requested).toEqual([["linear"]]);
  await frame.getByRole("button", { name: "Add card" }).click();
  await expect.poll(requested).toEqual([["linear"], ["github"]]);

  // The second request answers first while the first remains in flight.
  for (const brand of ["github", "linear"]) {
    await page.evaluate(
      (name) =>
        (window as unknown as { uiPort: MessagePort }).uiPort.postMessage({
          type: "brand-icons",
          icons: {
            [name]:
              '<svg data-logo="' +
              name +
              '" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/></svg>',
          },
        }),
      brand
    );
    await expect(frame.locator('[data-logo="' + brand + '"]')).toBeVisible();
  }
  await expect(frame.locator("[data-logo]")).toHaveCount(2);
  expect((await messages()).filter((message) => message.type === "error")).toEqual([]);
});
