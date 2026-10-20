/* eslint-disable unicorn/require-post-message-target-origin -- Messages target a MessagePort, not a Window. */
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
import { commands } from "vitest/browser";
import journeysDesigned from "./fixtures/dynamic-ui/journeys-designed-output.json";
import weatherDesigned from "./fixtures/dynamic-ui/weather-designed-output.json";
import weatherIllustrated from "./fixtures/dynamic-ui/weather-illustrated-output.json";
import weatherModel from "./fixtures/dynamic-ui/weather-model-output.json";
import weatherResult from "./fixtures/dynamic-ui/weather-result-output.json";
import weatherSimple from "./fixtures/dynamic-ui/weather-simple-output.json";
import weatherTask from "./fixtures/dynamic-ui/weather-task-output.json";
import { fixtureMount } from "./support/fixture";
import type { FrameElementLocator } from "./support/frames";
import { expect, test, useFixture, type Page } from "./support/page";
import { stepUntil } from "./support/virtual-time";
import { useNodeRealm } from "./support/world";

// The dynamic UI runtime (packages/chat-contract/src/dynamic-ui/runtime.ts)
// as a chat's host runs it: its document in a sandboxed frame of an origin of
// its own, the agent's script in a worker of the frame. The page, the frame
// and its worker are realms of one world: the widget's timers, messages and
// frames move on the test's time, and what the test does to the widget is
// the browser's trusted input. A request a widget leaks to the world's leak
// server fails the test (./fixtures/dynamic-ui/leak.ts). What only Electron
// decides (its network policy for widget resources, the frame's process) is
// apps/electron/e2e/dynamic-ui/runtime.spec.ts.

const leak = useNodeRealm<{ origin: string }>(
  "leak",
  "e2e/app-shell/fixtures/dynamic-ui/leak.ts"
);
useFixture(
  fixtureMount(new URL("./fixtures/focus-ring/src/main.ts", import.meta.url)),
  {
    world: { servers: () => [leak()] },
  }
);
const fixtureUrl = "http://fixture.test/";
const runtimePath = "/__dynamic-ui/runtime";
const runtimeUrl = new URL(runtimePath, location.origin).href;

const fixtures: Record<
  string,
  { script: string; html: string; data: Record<string, unknown> }
> = {
  "journeys-designed-output": journeysDesigned,
  "weather-designed-output": weatherDesigned,
  "weather-illustrated-output": weatherIllustrated,
  "weather-model-output": weatherModel,
  "weather-result-output": weatherResult,
  "weather-simple-output": weatherSimple,
  "weather-task-output": weatherTask,
};

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

type Host = {
  uiMessages: Record<string, unknown>[];
  uiPort: MessagePort;
  commaFrames: {
    post(target: unknown, message: unknown, transfer?: Transferable[]): void;
    names(): string[];
  };
};

let page: Page;
// A URL that only the world's leak server answers.
let target = "";

/** The test's page, its fixture open: the host of the widget. */
async function open(current: Page) {
  page = current;
  target = `${leak().origin}/leak`;
  await page.goto(fixtureUrl);
}

/**
 * Moves page time a frame at a time until `check` passes on what `read` gives
 * (as Playwright's `expect.poll` waits), then checks it once more so a
 * failure reports the value.
 */
async function eventually<T>(read: () => T | Promise<T>, check: (value: T) => void) {
  await stepUntil(async () => {
    try {
      check(await read());
      return true;
    } catch {
      return false;
    }
  });
  check(await read());
}

/** The address of the page's widget frame. */
async function frameUrl() {
  const { frameTree } = (await commands.cdpSend("Page.getFrameTree")) as {
    frameTree: FrameTree;
  };
  const urls: string[] = [];
  const walk = (tree: FrameTree) => {
    urls.push(tree.frame.url);
    for (const child of tree.childFrames ?? []) walk(child);
  };
  walk(frameTree);
  return urls.find((url) => url.includes("/__dynamic-ui/")) ?? urls.at(-1);
}
type FrameTree = { frame: { url: string }; childFrames?: FrameTree[] };

/** Opens the widget as the chat's host does: its frame, then its script, markup and data on the frame's port. */
async function mount(
  agentScript: string,
  agentHtml = '<div class="stack"><p id="result">Initial</p><button id="refresh">Refresh</button></div>',
  initialData: Record<string, unknown> = { city: "Singapore" },
  initialTheme?: Record<string, string>,
  cardInit: Record<string, unknown> = {},
  container?: string
) {
  await page.evaluate(
    ({ script, html, data, icons, theme, cards, slot, src }) => {
      const host = window as unknown as Host;
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
        // The frame has an origin of its own: the world carries what the page posts it.
        host.commaFrames.post(
          frame,
          {
            type: "comma-ui:init",
            payload: { version: 1, html, script, data },
            state: {},
            icons,
            theme,
            ...cards,
          },
          [channel.port2]
        );
      });
      const frame = document.createElement("iframe");
      frame.sandbox.add("allow-scripts");
      frame.src = src;
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
      src: runtimePath,
    }
  );
}
async function messages() {
  return page.evaluate(() => (window as unknown as Host).uiMessages);
}

test("runs local interaction while requests, imports, nested workers and storage stay blocked", async ({
  page: current,
}) => {
  await open(current);
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
  await eventually(
    async () => (await messages()).some((message) => message.type === "request"),
    (value) => expect(value).toBe(true)
  );
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
  await frame.locator("#refresh").focus();
  await frame.locator("#refresh").press("Enter");
  await eventually(
    async () =>
      (await messages()).some((message) => message.value === "Refresh weather"),
    (value) => expect(value).toBe(true)
  );
});

test("button handlers receive clicks on nested labels and SVG icons", async ({
  page: current,
}) => {
  await open(current);
  await mount(
    `let count = 0; comma.on('refresh', 'click', () => comma.text('result', String(++count)));`,
    '<p id="result">0</p><button id="refresh"><span id="label">Refresh</span><comma-icon name="sun"></comma-icon></button>'
  );
  const frame = page.frameLocator("iframe");
  await frameAtRest(frame.locator("#label"));
  await frame.locator("#label").click();
  await expect(frame.locator("#result")).toHaveText("1");
  await frame.locator("#refresh svg").click();
  await expect(frame.locator("#result")).toHaveText("2");
  await frame.locator("#refresh").focus();
  await frame.locator("#refresh").press("Enter");
  await expect(frame.locator("#result")).toHaveText("3");
});

test("renders calendar line breaks without rejecting the widget", async ({
  page: current,
}) => {
  await open(current);
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

test("rejects hostile markup without requesting resources", async ({
  page: current,
}) => {
  await open(current);
  await mount("", `<img src="${target}"><p>Unsafe</p>`);
  await eventually(
    async () => (await messages()).some((message) => message.type === "error"),
    (value) => expect(value).toBe(true)
  );
});

test("bounds chart allocation and recovers shared state without business calls", async ({
  page: current,
}) => {
  await open(current);
  await mount(
    "comma.chart('trend',{labels:['Mon','Tue'],values:[25,27],type:'line'});comma.onState(state=>comma.text('result',state.filter));",
    '<div class="stack"><p id="result">All</p><comma-chart id="trend"></comma-chart></div>'
  );
  const frame = page.frameLocator("iframe");
  await expect(frame.locator("canvas")).toHaveAttribute("role", "img");
  await expect(frame.locator("canvas")).toHaveAttribute("aria-label", /Mon/);
  await page.evaluate(() =>
    (window as unknown as Host).uiPort.postMessage({
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
  await eventually(
    async () => (await messages()).some((message) => message.type === "height"),
    (value) => expect(value).toBe(true)
  );
});

test("rejects excess chart allocation before starting agent code", async ({
  page: current,
}) => {
  await open(current);
  await mount(
    "comma.request('should not run')",
    "<comma-chart></comma-chart>".repeat(9)
  );
  await eventually(
    async () =>
      (await messages()).some(
        (message) =>
          message.type === "error" &&
          message.reason === "A UI supports at most eight charts"
      ),
    (value) => expect(value).toBe(true)
  );
  expect((await messages()).filter((message) => message.type === "request")).toEqual(
    []
  );
});

test("rejects raw worker update floods", async ({ page: current }) => {
  await open(current);
  await mount(
    "for(let i=0;i<100;i++)postMessage({type:'text',id:'result',value:'flood'})"
  );
  await eventually(
    async () => (await messages()).some((message) => message.type === "error"),
    (value) => expect(value).toBe(true)
  );
});

test("a render pass over a long paginated list counts as one update", async ({
  page: current,
}) => {
  await open(current);
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

test("batched updates keep the data each call saw", async ({ page: current }) => {
  await open(current);
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

test("batched updates keep the message and rate budgets", async ({ page: current }) => {
  await open(current);
  // 39 KB of text in one task leaves as two messages under the 32 KiB budget.
  await mount(
    "for(let i=0;i<10;i++)comma.text('t'+i,'x'.repeat(3900));",
    Array.from({ length: 10 }, (_, i) => `<p id="t${i}"></p>`).join("")
  );
  await expect(page.frameLocator("iframe").locator("#t9")).toHaveText("x".repeat(3900));
  expect((await messages()).filter((item) => item.type === "error")).toEqual([]);
  // One update per task still counts, so a script that updates in a timeout
  // loop is stopped.
  await page.goto(fixtureUrl);
  await mount(
    "let n=0;(function loop(){comma.text('result',String(n++));setTimeout(loop,0);})();"
  );
  await eventually(
    async () =>
      (await messages()).some(
        (item) => item.type === "error" && item.reason === "UI update rate exceeded"
      ),
    (value) => expect(value).toBe(true)
  );
});

test("SDK batches and raw messages obey the UTF-8 byte budget", async ({
  page: current,
}) => {
  await open(current);
  const html = Array.from({ length: 7 }, (_, i) => `<p id="t${i}"></p>`).join("");
  await mount("for(let i=0;i<7;i++)comma.text('t'+i,'汉'.repeat(4000));", html);
  await expect(page.frameLocator("iframe").locator("#t6")).toHaveText(
    "汉".repeat(4000)
  );
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);

  await page.goto(fixtureUrl);
  await mount(
    "postMessage({type:'batch',ops:Array.from({length:7},(_,i)=>({type:'text',id:'t'+i,value:'汉'.repeat(4000)}))});",
    html
  );
  await eventually(
    async () => (await messages()).find((m) => m.type === "error")?.reason,
    (value) => expect(value).toBe("UI message budget exceeded")
  );
});

test("table data stays readable at chat widths and markup remains inert text", async ({
  page: current,
}) => {
  await open(current);
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
    await eventually(
      () =>
        frame.locator("body").evaluate((node) => node.scrollWidth <= node.clientWidth),
      (value) => expect(value).toBe(true)
    );
    await expect(frame.getByRole("cell", { name: "28° / 22°" })).toBeVisible();
    await eventually(
      async () => {
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
      },
      (value) => expect(value).toBe(true)
    );
  }
  await frame.getByRole("button", { name: "切换数据" }).click();
  await expect(
    frame.getByRole("cell", { name: `<img src="${target}">` })
  ).toBeVisible();
  await expect(frame.locator("img")).toHaveCount(0);
});

test("HTML passed to a dynamic table text target fails visibly instead of leaking tags", async ({
  page: current,
}) => {
  await open(current);
  await mount(
    `const target='rows'; comma.text(target,'<tr><td>09/21 Mon</td></tr>');`,
    '<table><tbody id="rows"></tbody></table>'
  );
  await eventually(
    async () =>
      (await messages()).some(
        (item) => item.type === "error" && String(item.reason).includes("comma.table")
      ),
    (value) => expect(value).toBe(true)
  );
  await expect(page.frameLocator("iframe").locator("body")).toBeEmpty();
});

test("table replacement is bounded across all tables and does not accumulate old rows", async ({
  page: current,
}) => {
  await open(current);
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
  await eventually(
    async () =>
      (await messages()).some(
        (item) => item.type === "error" && String(item.reason).includes("node budget")
      ),
    (value) => expect(value).toBe(true)
  );
});

// Captured from the real-model weather evaluation, with the API name updated to Comma.
test("renders the recorded model-generated forecast in narrow and wide chats", async ({
  page: current,
}) => {
  await open(current);
  const artifact = fixtures["weather-model-output"]!;
  await mount(artifact.script, artifact.html, artifact.data);
  const frame = page.frameLocator("iframe");
  await expect(frame.getByRole("cell", { name: "28 / 22" })).toBeVisible();
  for (const width of [320, 760]) {
    await page.locator("iframe").evaluate((node, value) => {
      node.style.width = `${value}px`;
    }, width);
    await eventually(
      async () => {
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
      },
      (value) => expect(value).toBe(true)
    );
    await eventually(
      () =>
        frame.locator("body").evaluate((node) => node.scrollWidth <= node.clientWidth),
      (value) => expect(value).toBe(true)
    );
  }
  expect((await messages()).some((item) => item.type === "error")).toBe(false);
});

test("renders the Worker result delivered as dynamic UI", async ({ page: current }) => {
  await open(current);
  const artifact = fixtures["weather-result-output"]!;
  await mount(artifact.script, artifact.html, artifact.data);
  const frame = page.frameLocator("iframe");
  await expect(frame.locator("body")).toContainText("上海");
  await expect(frame.locator("body")).toContainText("Evaluation weather fixture");
  await expect(frame.locator("body")).toContainText("09/17");
  for (const width of [320, 760]) {
    await page.locator("iframe").evaluate((node, value) => {
      node.style.width = `${value}px`;
    }, width);
    await eventually(
      () =>
        frame.locator("body").evaluate((node) => node.scrollWidth <= node.clientWidth),
      (value) => expect(value).toBe(true)
    );
  }
  expect((await messages()).filter((item) => item.type === "error")).toEqual([]);
});

test("text updates share the DOM budget and remove stale child targets", async ({
  page: current,
}) => {
  await open(current);
  await mount(
    `for(let i=0;i<251;i++)comma.text('n'+i,'value');`,
    Array.from({ length: 500 }, (_, i) => `<span id="n${i}"></span>`).join("")
  );
  await eventually(
    async () =>
      (await messages()).some(
        (item) => item.type === "error" && String(item.reason).includes("node budget")
      ),
    (value) => expect(value).toBe(true)
  );
  await page.goto(fixtureUrl);
  await mount(
    `comma.text('parent','Done');comma.table('old',{columns:['A'],rows:[[1]]});`,
    '<section id="parent"><table id="old"></table></section>'
  );
  await eventually(
    async () =>
      (await messages()).some(
        (item) => item.type === "error" && String(item.reason).includes("Invalid table")
      ),
    (value) => expect(value).toBe(true)
  );
});

test("static Agent HTML renders without script startup errors", async ({
  page: current,
}) => {
  await open(current);
  await mount(
    "",
    '<section class="stack"><h2>Weather fixture</h2><p>28 °C</p></section>'
  );
  await expect(page.frameLocator("iframe").locator("h2")).toHaveText("Weather fixture");
  expect((await messages()).filter((message) => message.type === "error")).toEqual([]);
});

test("a late host listener can initialize an already loaded iframe", async ({
  page: current,
}) => {
  await open(current);
  await page.evaluate((src) => {
    const frame = document.createElement("iframe");
    frame.sandbox.add("allow-scripts");
    frame.src = src;
    document.body.append(frame);
  }, runtimePath);
  await eventually(
    () => page.evaluate(() => (window as unknown as Host).commaFrames.names().length),
    (value) => expect(value).toBe(1)
  );
  await page.evaluate(() => {
    const host = window as unknown as Host & { recovered?: boolean };
    const frame = document.querySelector("iframe")!;
    window.addEventListener("message", (event) => {
      if (event.source !== frame.contentWindow || event.data?.type !== "comma-ui:ready")
        return;
      const channel = new MessageChannel();
      channel.port1.addEventListener("message", (incoming) => {
        if (incoming.data?.type === "ready") host.recovered = true;
      });
      channel.port1.start();
      host.commaFrames.post(
        frame,
        {
          type: "comma-ui:init",
          payload: { version: 1, html: "<p>Recovered</p>", script: "", data: {} },
        },
        [channel.port2]
      );
    });
    host.commaFrames.post(frame, { type: "comma-ui:hello" });
  });
  await eventually(
    () => page.evaluate(() => (window as unknown as { recovered?: boolean }).recovered),
    (value) => expect(value).toBe(true)
  );
  await expect(page.frameLocator("iframe").locator("p")).toHaveText("Recovered");
});

test("widget composition stays readable in wide and narrow light/dark chats", async ({
  page: current,
}) => {
  await open(current);
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
        (window as unknown as Host).uiPort.postMessage({
          type: "theme",
          theme: { scheme },
        }),
      colorScheme
    );
    for (const width of [320, 760]) {
      await page.locator("iframe").evaluate((frame, value) => {
        frame.style.width = `${value}px`;
      }, width);
      // The child renderer applies its viewport resize asynchronously. An old
      // viewport can have no overflow too, so acknowledge the requested width.
      await widget.locator("html").evaluate(
        (root, expectedWidth) =>
          new Promise<void>((resolveResize) => {
            const observer = new ResizeObserver(checkWidth);
            function checkWidth() {
              if (root.clientWidth !== expectedWidth) return;
              observer.disconnect();
              resolveResize();
            }
            observer.observe(root);
            checkWidth();
          }),
        width
      );
      await eventually(
        () =>
          widget
            .locator("body")
            .evaluate((body) => body.scrollWidth <= body.clientWidth),
        (value) => expect(value).toBe(true)
      );
      const [first, second] = await widget.locator(".card").evaluateAll((cards) =>
        cards.map((card) => {
          const { y, height } = card.getBoundingClientRect();
          return { y, height };
        })
      );
      expect(first).toBeDefined();
      expect(second).toBeDefined();
      if (width === 320) expect(second!.y).toBeGreaterThan(first!.y);
      else expect(second!.y).toBe(first!.y);
      await eventually(
        async () => (await page.locator("iframe").boundingBox())!.height,
        (value) => expect(value).toBeGreaterThanOrEqual(second!.y + second!.height + 2)
      );
    }
  }
  await widget.getByRole("button", { name: "刷新天气" }).focus();
  await page.keyboard.press("Enter");
  await eventually(messages, (value) =>
    expect(value).toContainEqual({
      type: "request",
      value: "Refresh this weather forecast",
    })
  );
  expect((await messages()).filter((item: any) => item.type === "error")).toEqual([]);
});

// Unedited outputs from gpt-5.6-terra using the current ui.create contract and evaluation facts.
for (const scenario of ["weather", "journeys"]) {
  test(`renders designed ${scenario} and keeps local interactions functional`, async ({
    page: current,
  }) => {
    await open(current);
    const artifact = fixtures[`${scenario}-designed-output`]!;
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
      await clickForRequest(frame.getByRole("button", { name: "查询更多班次或席别" }));
    }
    for (const colorScheme of ["light", "dark"] as const) {
      await page.emulateMedia({ colorScheme });
      await page.evaluate(
        (scheme) =>
          (window as unknown as Host).uiPort.postMessage({
            type: "theme",
            theme: { scheme },
          }),
        colorScheme
      );
      for (const width of [320, 760]) {
        await page.locator("iframe").evaluate((node, value) => {
          node.style.width = `${value}px`;
        }, width);
        await eventually(
          () =>
            frame
              .locator("body")
              .evaluate((node) => node.scrollWidth <= node.clientWidth),
          (value) => expect(value).toBe(true)
        );
        await eventually(
          async () => {
            const expected = await frame
              .locator("body > div")
              .evaluate((node) => Math.ceil(node.getBoundingClientRect().height + 4));
            return (
              (await page.locator("iframe").evaluate((node) => node.clientHeight)) ===
              Math.max(60, expected)
            );
          },
          (value) => expect(value).toBe(true)
        );
        if (scenario === "weather") {
          await eventually(
            () =>
              frame
                .locator("canvas")
                .evaluate(
                  (node: HTMLCanvasElement) =>
                    Math.abs(
                      node.getContext("2d")!.getTransform().a * node.clientWidth -
                        node.width
                    ) < 1
                ),
            (value) => expect(value).toBe(true)
          );
        }
      }
    }
    expect((await messages()).filter((item) => item.type === "error")).toEqual([]);
  });
}

test("widgets remain immediately visible with legacy entrance classes and interactive controls", async ({
  page: current,
}) => {
  await open(current);
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
  await eventually(
    () => frame.locator("#hero").evaluate((element) => element.getAnimations().length),
    (value) => expect(value).toBe(0)
  );
  await expect(frame.getByRole("img", { name: "晴间多云" })).toBeVisible();
  // The host must resize the initial iframe before the native click scrolls it.
  await eventually(
    async () => (await messages()).some((m) => m.type === "height"),
    (value) => expect(value).toBe(true)
  );
  await frame.getByRole("button", { name: "更新预报" }).click();
  await eventually(
    async () => (await messages()).some((m) => m.type === "request"),
    (value) => expect(value).toBe(true)
  );
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
});

test("renders model-authored weather with semantic icons and motion", async ({
  page: current,
}) => {
  await open(current);
  const artifact = fixtures["weather-illustrated-output"]!;
  await mount(artifact.script, artifact.html, artifact.data);
  const frame = page.frameLocator("iframe");
  await expect(frame.getByRole("img", { name: "晴", exact: true })).toBeVisible();
  await expect(frame.getByRole("img", { name: "小雨", exact: true })).toBeVisible();
  await expect(frame.locator("body")).toContainText("26 / 20°C");
  for (const colorScheme of ["light", "dark"] as const) {
    await page.emulateMedia({ colorScheme });
    await page.evaluate(
      (scheme) =>
        (window as unknown as Host).uiPort.postMessage({
          type: "theme",
          theme: { scheme },
        }),
      colorScheme
    );
    for (const width of [320, 760]) {
      await page.locator("iframe").evaluate((element, value) => {
        element.style.width = `${value}px`;
      }, width);
      await eventually(
        () =>
          frame
            .locator("canvas")
            .evaluate(
              (node: HTMLCanvasElement) =>
                Math.abs(
                  node.getContext("2d")!.getTransform().a * node.clientWidth -
                    node.width
                ) < 1
            ),
        (value) => expect(value).toBe(true)
      );
      await eventually(
        async () => {
          const expected = await frame
            .locator("body > div")
            .evaluate((node) => Math.ceil(node.getBoundingClientRect().height + 4));
          return (
            (await page.locator("iframe").evaluate((node) => node.clientHeight)) ===
            expected
          );
        },
        (value) => expect(value).toBe(true)
      );
      await eventually(
        () =>
          frame
            .locator("body")
            .evaluate((node) => node.scrollWidth <= node.clientWidth),
        (value) => expect(value).toBe(true)
      );
    }
  }
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
});

test("only physical widget wheel input reaches the host scroll channel", async ({
  page: current,
}) => {
  await open(current);
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
  await eventually(
    async () =>
      (await messages())
        .filter((m) => m.type === "wheel")
        .reduce((sum, m) => sum + Number(m.deltaY), 0),
    (value) => expect(value).toBe(120)
  );
  await page.mouse.wheel(0, -80);
  await eventually(
    async () =>
      (await messages())
        .filter((m) => m.type === "wheel")
        .reduce((sum, m) => sum + Number(m.deltaY), 0),
    (value) => expect(value).toBe(40)
  );
  expect(await frame.locator("html").evaluate(() => window.scrollY)).toBe(0);
  await frame.getByRole("button", { name: "Action" }).click();
  await eventually(
    async () => (await messages()).some((m) => m.type === "error"),
    (value) => expect(value).toBe(true)
  );
  expect(
    (await messages())
      .filter((m) => m.type === "wheel")
      .reduce((sum, m) => sum + Number(m.deltaY), 0)
  ).toBe(40);
});

test("a wheel over a widget scrolls the chat and tells the host first", async ({
  page: current,
}) => {
  await open(current);
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
  await eventually(
    () => page.evaluate(() => Boolean((window as { uiPort?: MessagePort }).uiPort)),
    (value) => expect(value).toBe(true)
  );
  await page.evaluate(() => {
    const host = window as unknown as { uiPort: MessagePort; order: string[] };
    host.uiPort.addEventListener("message", (event) => {
      if (event.data?.type === "wheel") host.order.push("wheel");
    });
  });

  await frame.getByText("Widget in chat").hover();
  await page.mouse.wheel(0, 120);

  await eventually(
    () => page.locator("#chat").evaluate((chat) => chat.scrollTop),
    (value) => expect(value).toBeGreaterThan(0)
  );
  // The chat's scroll event comes with the page's next frame.
  await eventually(
    () => page.evaluate(() => (window as unknown as { order: string[] }).order),
    (value) => expect(value).toContain("scroll")
  );
  const order = await page.evaluate(
    () => (window as unknown as { order: string[] }).order
  );
  expect(order.indexOf("wheel")).toBeGreaterThanOrEqual(0);
  expect(order.indexOf("wheel")).toBeLessThan(order.indexOf("scroll"));
  expect(await frame.locator("html").evaluate(() => window.scrollY)).toBe(0);
});

// The height budget assumes the macOS system font, as the browser tests run
// on macOS: Linux fallback fonts wrap the forecast rows taller.
test("keeps a model-authored seven-day forecast compact at chat widths", async ({
  page: current,
}) => {
  await open(current);
  const artifact = fixtures["weather-simple-output"]!;
  await mount(artifact.script, artifact.html, artifact.data);
  const frame = page.frameLocator("iframe");
  await expect(frame.locator("#heroHigh")).toHaveText("29°");
  await expect(frame.locator("#d6")).toHaveText("30° / 22°");
  for (const width of [760, 320]) {
    await page.locator("iframe").evaluate((element, value) => {
      element.style.width = `${value}px`;
    }, width);
    await eventually(
      () =>
        frame.locator("body").evaluate((node) => node.scrollWidth <= node.clientWidth),
      (value) => expect(value).toBe(true)
    );
    await eventually(
      async () => {
        const natural = await frame
          .locator("body > div")
          .evaluate((node) => Math.ceil(node.getBoundingClientRect().height + 4));
        return (
          (await page.locator("iframe").evaluate((node) => node.clientHeight)) ===
          natural
        );
      },
      (value) => expect(value).toBe(true)
    );
    expect((await page.locator("iframe").boundingBox())!.height).toBeLessThan(
      width === 760 ? 340 : 500
    );
  }
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
});

test("renders a real Task weather widget with readable atmospheric contrast", async ({
  page: current,
}) => {
  await open(current);
  const artifact = fixtures["weather-task-output"]!;
  await mount(artifact.script, artifact.html, artifact.data);
  const frame = page.frameLocator("iframe");
  await expect(frame.locator("#todayHigh")).toHaveText("28°");
  for (const colorScheme of ["light", "dark"] as const) {
    await page.emulateMedia({ colorScheme, reducedMotion: "reduce" });
    await page.evaluate(
      (scheme) =>
        (window as unknown as Host).uiPort.postMessage({
          type: "theme",
          theme: { scheme },
        }),
      colorScheme
    );
    for (const width of [760, 320]) {
      await page.locator("iframe").evaluate((node, value) => {
        node.style.width = `${value}px`;
      }, width);
      await eventually(
        () =>
          frame
            .locator("body")
            .evaluate((node) => node.scrollWidth <= node.clientWidth),
        (value) => expect(value).toBe(true)
      );
      const color = await frame
        .locator("#todayHigh")
        .evaluate((node) => getComputedStyle(node).color);
      expect(color).toBe("rgb(255, 255, 255)");
    }
  }
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
});

test("uses Comma palette instead of OS appearance and updates without losing interaction state", async ({
  page: current,
}) => {
  await open(current);
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
    (window as unknown as Host).uiPort.postMessage({
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

test("whole-item links require user activation and leave navigation to the host", async ({
  page: current,
}) => {
  await open(current);
  await mount(
    "",
    '<a href="https://example.test/train"><strong class="metric">18:01 → 19:03</strong><span> G1510</span></a>'
  );
  const link = page.frameLocator("iframe").locator("a");
  await expect(link).toBeVisible();
  await link.evaluate((node: HTMLElement) => node.click());
  expect((await messages()).filter((m) => m.type === "open-link")).toEqual([]);
  await link.click();
  await eventually(
    async () => (await messages()).filter((m) => m.type === "open-link").length,
    (value) => expect(value).toBe(1)
  );
  await link.focus();
  await page.keyboard.press("Enter");
  await eventually(
    async () => (await messages()).filter((m) => m.type === "open-link").length,
    (value) => expect(value).toBe(2)
  );
  expect((await messages()).find((m) => m.type === "open-link")?.url).toBe(
    "https://example.test/train"
  );
  expect(await frameUrl()).toBe(runtimeUrl);
});

test("a right-click on a link asks the host for its link menu", async ({
  page: current,
}) => {
  await open(current);
  await mount("", '<p>Before</p><a href="https://example.test/pr">PR #2300</a>');
  const link = page.frameLocator("iframe").locator("a");
  await expect(link).toBeVisible();
  await page.frameLocator("iframe").locator("p").click({ button: "right" });
  await link.dispatchEvent("contextmenu");
  expect((await messages()).filter((m) => m.type === "link-menu")).toEqual([]);
  await link.click({ button: "right", position: { x: 5, y: 6 } });
  await eventually(
    async () => (await messages()).filter((m) => m.type === "link-menu").length,
    (value) => expect(value).toBe(1)
  );
  const request = (await messages()).find((m) => m.type === "link-menu");
  expect(request?.url).toBe("https://example.test/pr");
  const box = await link.boundingBox();
  const frameBox = await page.locator("iframe").boundingBox();
  // Frame coordinates are relative to the frame's viewport, within a pixel of rounding.
  expect(Math.abs(Number(request?.x) - (box!.x - frameBox!.x + 5))).toBeLessThanOrEqual(
    1
  );
  expect(Math.abs(Number(request?.y) - (box!.y - frameBox!.y + 6))).toBeLessThanOrEqual(
    1
  );
  expect((await messages()).filter((m) => m.type === "open-link")).toEqual([]);
});

test("hovering a card row link tells the host its text and box, and leaving clears it", async ({
  page: current,
}) => {
  await open(current);
  // A feed row is one link that leads with an aria-hidden brand mark.
  const feed = {
    title: "Open pull requests",
    items: [
      {
        source: "GitHub",
        title: "PR #2300",
        excerpt: "CI passed",
        href: "https://example.test/pr",
      },
    ],
  };
  await mount(
    'comma.card("card", "feed", comma.data.feed);',
    '<p id="before">Before</p><section id="card"></section>',
    { feed },
    undefined,
    { seed: "block-1", locale: "en" }
  );
  const frame = page.frameLocator("iframe");
  const link = frame.locator("a");
  await expect(link).toBeVisible();
  await eventually(
    async () => {
      const box = await page.locator("iframe").boundingBox();
      const content = await frame.locator("body").evaluate((body) => body.scrollHeight);
      return box !== null && box.height >= content;
    },
    (value) => expect(value).toBe(true)
  );
  const hovers = async () =>
    (await messages()).filter((message) => message.type === "link-hover");
  await link.dispatchEvent("pointerover");
  expect(await hovers()).toEqual([]);

  await frame.getByText("PR #2300").hover();
  await eventually(
    async () => (await hovers()).length,
    (value) => expect(value).toBe(1)
  );
  // Moving within the row is still the same hover.
  await frame.getByText("CI passed").hover();
  const [hover] = await hovers();
  expect(await hovers()).toHaveLength(1);
  expect(hover?.url).toBe("https://example.test/pr");
  expect(String(hover?.label)).toMatch(/^PR #2300 CI passed/);
  const box = await link.boundingBox();
  const frameBox = await page.locator("iframe").boundingBox();
  // The box is in the frame's own viewport, within a pixel of rounding.
  for (const [measured, expected] of [
    [hover?.x, box!.x - frameBox!.x],
    [hover?.y, box!.y - frameBox!.y],
    [hover?.width, box!.width],
    [hover?.height, box!.height],
  ])
    expect(Math.abs(Number(measured) - Number(expected))).toBeLessThanOrEqual(1);

  await frame.locator("#before").hover();
  await eventually(
    async () => (await hovers()).at(-1),
    (value) =>
      expect(value).toEqual({
        type: "link-hover",
        url: null,
      })
  );
  expect(await hovers()).toHaveLength(2);
});

test("a feed card filters its own rows and shows each row's tags", async ({
  page: current,
}) => {
  await open(current);
  const feed = {
    title: "Recent Inbox",
    filters: [
      { key: "all", label: "All" },
      { key: "unread", label: "Unread" },
      { key: "flagged", label: "Flagged" },
    ],
    items: [
      {
        source: "Google Chat",
        title: "Welcome to Chat!",
        status: { label: "Read" },
        tags: ["Suggested review"],
        href: "https://example.test/mail/1",
        filterKeys: ["all"],
      },
      {
        source: "Figma",
        title: "The Figma agent is ready",
        status: { label: "Unread", tone: "brand" },
        href: "https://example.test/mail/2",
        filterKeys: ["all", "unread"],
      },
    ],
  };
  await mount(
    'comma.card("card", "feed", comma.data.feed);',
    '<section id="card"></section>',
    { feed },
    undefined,
    { seed: "block-1", locale: "en" }
  );
  const frame = page.frameLocator("iframe");
  const rows = frame.locator("li");
  await expect(rows).toHaveCount(2);
  await expect(rows.first()).toContainText("Suggested review");
  // No row carries "flagged", so that choice is left out.
  const choices = frame
    .getByRole("group", { name: "Recent Inbox" })
    .getByRole("button");
  await expect(choices).toHaveText(["All", "Unread"]);
  await eventually(
    async () => {
      const box = await page.locator("iframe").boundingBox();
      const content = await frame.locator("body").evaluate((body) => body.scrollHeight);
      return box !== null && box.height >= content;
    },
    (value) => expect(value).toBe(true)
  );

  await choices.nth(1).click();
  await expect(rows).toHaveCount(1);
  await expect(rows.first()).toContainText("The Figma agent is ready");
  await choices.nth(0).click();
  await expect(rows).toHaveCount(2);
});

test("focusing a link previews it like a hover, and Escape or blur clears it", async ({
  page: current,
}) => {
  await open(current);
  await mount("", '<p>Before</p><a href="https://example.test/pr">PR #2300</a>');
  const link = page.frameLocator("iframe").locator("a");
  await expect(link).toBeVisible();
  const hovers = async () =>
    (await messages()).filter((message) => message.type === "link-hover");

  // The hidden test window never has system focus, so the frame fires no focus
  // events. Emulate a focused frame; its runtime then sees real focus changes.
  await commands.cdpSend("Emulation.setFocusEmulationEnabled", { enabled: true });
  await link.focus();
  await eventually(
    async () => (await hovers()).at(-1),
    (value) =>
      expect(value).toMatchObject({ url: "https://example.test/pr", label: "PR #2300" })
  );
  await page.keyboard.press("Escape");
  await eventually(
    async () => (await hovers()).at(-1),
    (value) =>
      expect(value).toEqual({
        type: "link-hover",
        url: null,
      })
  );

  await link.blur();
  await link.focus();
  await eventually(
    async () => (await hovers()).at(-1),
    (value) => expect(value).toMatchObject({ url: "https://example.test/pr" })
  );
  await link.blur();
  await eventually(
    async () => (await hovers()).at(-1),
    (value) =>
      expect(value).toEqual({
        type: "link-hover",
        url: null,
      })
  );
  expect((await hovers()).map((hover) => hover.url)).toEqual([
    "https://example.test/pr",
    null,
    "https://example.test/pr",
    null,
  ]);
});

test("Worker cannot forge a link activation", async ({ page: current }) => {
  await open(current);
  await mount('postMessage({type:"open-link",url:"https://example.test/forged"})');
  await eventually(
    async () => (await messages()).some((m) => m.type === "error"),
    (value) => expect(value).toBe(true)
  );
  expect((await messages()).filter((m) => m.type === "open-link")).toEqual([]);
});

test("renders Agent data through a card template with host tokens, logos and saved progress", async ({
  page: current,
}) => {
  await open(current);
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
  const fitsContent = () =>
    eventually(
      async () => {
        const box = await page.locator("iframe").boundingBox();
        const content = await frame
          .locator("body")
          .evaluate((body) => body.scrollHeight);
        return box !== null && box.height >= content;
      },
      (value) => expect(value).toBe(true)
    );
  await fitsContent();
  await expect(markup).toBeVisible();
  await expect(frame.locator("img")).toHaveCount(0);
  await expect(frame.getByText("1/2 checked")).toBeVisible();
  await expect(
    frame.getByRole("checkbox", { name: "Update changelog" })
  ).not.toBeChecked();
  await expect(frame.getByText("Update changelog")).toHaveCSS("color", "rgb(1, 2, 3)");
  await expect(frame.getByText("Update changelog")).toHaveCSS("font-size", "20px");

  await eventually(
    async () => (await messages()).find((m) => m.type === "brand-icons")?.names,
    (value) => expect(value).toEqual(["linear"])
  );
  await page.evaluate(() =>
    (window as unknown as Host).uiPort.postMessage({
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

  await clickForRequest(frame.getByRole("button", { name: "Draft notes" }));
  expect((await messages()).find((m) => m.type === "request")?.value).toBe(
    "Draft the release notes"
  );
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
});

test("today forecast keeps all seven days visible in narrow and wide cards", async ({
  page: current,
}) => {
  await open(current);
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
    await eventually(
      () =>
        frame.locator("body").evaluate((body) => body.scrollWidth <= body.clientWidth),
      (value) => expect(value).toBe(true)
    );
  }
  expect((await messages()).filter((m) => m.type === "error")).toEqual([]);
});

test("keeps card logos from overlapping host requests", async ({ page: current }) => {
  await open(current);
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
  await eventually(requested, (value) => expect(value).toEqual([["linear"]]));
  await frame.getByRole("button", { name: "Add card" }).click();
  await eventually(requested, (value) =>
    expect(value).toEqual([["linear"], ["github"]])
  );

  // The second request answers first while the first remains in flight.
  for (const brand of ["github", "linear"]) {
    await page.evaluate(
      (name) =>
        (window as unknown as Host).uiPort.postMessage({
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

/** The widget's frame has the height the runtime last asked for, its document laid out at it. */
async function frameAtRest(inputTarget: FrameElementLocator) {
  await eventually(
    () =>
      page
        .frameLocator("iframe")
        .locator("body")
        .evaluate((body) => {
          const height = Math.min(
            12000,
            Math.max(60, Math.ceil(body.getBoundingClientRect().height))
          );
          return window.innerHeight === height;
        }),
    (value) => expect(value).toBe(true)
  );
  await expect(inputTarget).toBeVisible();
}

/** Clicks a widget button that sends a follow-up request and waits for it. */
async function clickForRequest(button: FrameElementLocator) {
  await frameAtRest(button);
  await button.click();
  await eventually(
    async () => (await messages()).some((m) => m.type === "request"),
    (value) => expect(value).toBe(true)
  );
}
