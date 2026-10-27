/* eslint-disable unicorn/require-post-message-target-origin -- Messages target a MessagePort, not a Window. */
import { fixtureMount } from "./support/fixture";
import { expect, test, useFixture, type Page } from "./support/page";
import { stepUntil } from "./support/virtual-time";
import { useNodeRealm } from "./support/world";

// The Comma app runtime (packages/chat-contract/src/mini-app/runtime.ts) as a
// host runs it: its document in a sandboxed frame with its policy, the app
// bundle sent over the frame's port. The app's calls come back over the port
// to the host, which answers them. A request the app leaks to the world's
// leak server fails the test (./fixtures/dynamic-ui/leak.ts). What only
// Electron decides (its network guard, the frame's preload) is
// apps/electron/e2e/mini-app/runtime.spec.ts.

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

type Host = {
  appMessages: Record<string, unknown>[];
  appPort?: MessagePort;
  commaFrames: {
    post(target: unknown, message: unknown, transfer?: Transferable[]): void;
  };
};

let page: Page;

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

/** Opens the app as a host does: the frame, `init` with the port, then the bundle's files. */
async function mount(files: Record<string, { mime: string; text: string }>) {
  await page.evaluate(() => {
    const host = window as unknown as Host;
    host.appMessages = [];
    window.addEventListener("message", (event) => {
      const frame = document.querySelector("iframe")!;
      if (
        event.source !== frame.contentWindow ||
        event.data?.type !== "comma-app:ready" ||
        host.appMessages.length
      )
        return;
      host.appMessages.push({ type: "comma-app:ready" });
      const channel = new MessageChannel();
      const port = channel.port1;
      port.addEventListener("message", (incoming) => {
        const message = incoming.data;
        host.appMessages.push(message);
        if (message.type !== "call") return;
        // The host's broker: one answer per operation the test app uses.
        const answers: Record<string, unknown> = {
          "storage.user.put": { version: 1 },
          "chat.draft": null,
        };
        if (message.op in answers)
          port.postMessage({
            type: "result",
            id: message.id,
            ok: true,
            value: answers[message.op],
          });
        else
          port.postMessage({
            type: "result",
            id: message.id,
            ok: false,
            error: { code: "not_granted", message: `${message.op} is not granted` },
          });
      });
      port.start();
      host.commaFrames.post(
        frame,
        {
          type: "comma-app:init",
          init: {
            app: { id: "app-1", name: "Test app", version: 3 },
            viewer: null,
            theme: "dark",
            tokens: { "--color-accent": "rgb(1, 2, 3)" },
            locale: "en-US",
            timeZone: "UTC",
            capabilities: ["chat.draft", "notifications"],
            grants: ["chat.draft"],
            storage: ["user"],
            backend: false,
          },
        },
        [channel.port2]
      );
      host.appPort = port;
    });
    const frame = document.createElement("iframe");
    frame.sandbox.add("allow-scripts", "allow-forms");
    frame.src = "/__mini-app/runtime";
    document.body.append(frame);
  });
  // The bundle follows `init` on the port, once the frame has it.
  await eventually(
    () => page.evaluate(() => Boolean((window as unknown as Host).appPort)),
    (value) => expect(value).toBe(true)
  );
  await page.evaluate((bundle) => {
    const encoder = new TextEncoder();
    (window as unknown as Host).appPort!.postMessage({
      type: "files",
      files: Object.entries(bundle).map(([path, file]) => ({
        path,
        mime: file.mime,
        data: encoder.encode(file.text).buffer,
      })),
    });
  }, files);
}

const messages = () => page.evaluate(() => (window as unknown as Host).appMessages);

test("runs a bundle from the port, round-trips calls, and has no network or origin", async ({
  page: current,
}) => {
  page = current;
  await page.goto("http://fixture.test/");
  const target = `${leak().origin}/leak`;
  await mount({
    "index.html": {
      mime: "text/html",
      text: '<!doctype html><html lang="en"><head><link rel="stylesheet" href="./style.css"></head><body><p id="out">Loading</p><img id="logo" alt="Logo" src="assets/logo.svg"><script type="module" src="./app.js"></script></body></html>',
    },
    "style.css": { mime: "text/css", text: "#out { color: var(--color-accent); }" },
    "assets/logo.svg": {
      mime: "image/svg+xml",
      text: '<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"></svg>',
    },
    "app.js": {
      mime: "text/javascript",
      text: `
        const results = {};
        const deny = async (name, run) => { try { await run(); results[name] = "allowed"; } catch { results[name] = "blocked"; } };
        // The frame's realm owns \`fetch\` and storage (./support), so the request is XMLHttpRequest's.
        await deny("request", () => new Promise((resolve, reject) => { const request = new XMLHttpRequest(); request.onload = resolve; request.onerror = reject; request.open("GET", ${JSON.stringify(target)}); request.send(); }));
        await deny("websocket", () => new Promise((resolve, reject) => { const socket = new WebSocket(${JSON.stringify(target.replace("http:", "ws:"))}); socket.onopen = resolve; socket.onerror = reject; }));
        await deny("image", () => new Promise((resolve, reject) => { const image = new Image(); image.onload = resolve; image.onerror = reject; image.src = ${JSON.stringify(target)}; }));
        await deny("cookie", () => { document.cookie = "a=b"; if (!document.cookie) throw Error("none"); });
        // A form submits to the app's handler, and the submission goes nowhere.
        const form = document.createElement("form");
        form.action = ${JSON.stringify(target)};
        document.body.append(form);
        results.submit = await new Promise((resolve) => { form.addEventListener("submit", (event) => { event.preventDefault(); resolve("handled"); }); form.requestSubmit(); setTimeout(() => resolve("blocked"), 1000); });
        results.origin = self.origin;
        results.app = comma.app;
        results.theme = document.documentElement.dataset.theme;
        results.asset = comma.asset("./assets/logo.svg") === document.getElementById("logo").src;
        results.put = await comma.storage.user.put("notes", ["a"]);
        try { await comma.notify("Title", "Body"); } catch (error) { results.notify = error.name + ":" + error.code; }
        try { await comma.storage.app.get("x"); } catch (error) { results.appStore = error.code; }
        results.backend = comma.supports("backend.fetch");
        document.getElementById("out").textContent = "Started";
        await comma.chat.draft(JSON.stringify(results));
      `,
    },
  });
  await eventually(
    async () => (await messages()).some((message) => message.op === "chat.draft"),
    (value) => expect(value).toBe(true)
  );
  const all = await messages();
  expect(all.map((message) => message.type)).toContain("started");
  const draft = all.find((message) => message.op === "chat.draft")!;
  expect(JSON.parse((draft.args as { text: string }).text)).toEqual({
    request: "blocked",
    websocket: "blocked",
    image: "blocked",
    cookie: "blocked",
    submit: "handled",
    origin: "null",
    app: { id: "app-1", name: "Test app", version: 3 },
    theme: "dark",
    asset: true,
    put: { version: 1 },
    notify: "CommaError:not_granted",
    appStore: "unsupported",
    backend: false,
  });
  // A call the host answered with an error, and one the SDK refused locally.
  expect(
    all.filter((message) => message.type === "call").map((message) => message.op)
  ).toEqual(["storage.user.put", "notify", "chat.draft"]);
  const frame = page.frameLocator("iframe");
  await expect(frame.locator("#out")).toHaveText("Started");
  await expect(frame.locator("#out")).toHaveCSS("color", "rgb(1, 2, 3)");
});

test("reports a bundle without index.html instead of starting", async ({
  page: current,
}) => {
  page = current;
  await page.goto("http://fixture.test/");
  await mount({ "app.js": { mime: "text/javascript", text: "" } });
  await eventually(
    async () => (await messages()).find((message) => message.type === "error"),
    (value) =>
      expect(value).toEqual({ type: "error", reason: "The bundle has no index.html." })
  );
});
