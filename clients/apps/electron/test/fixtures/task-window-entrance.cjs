const { app, BrowserWindow } = require("electron");
const { createServer } = require("node:http");
const { readFileSync } = require("node:fs");
const { resolve, extname } = require("node:path");
const ts = require("typescript");
const { runInNewContext } = require("node:vm");
const root = resolve(__dirname, "../../.vite/renderer/main_window");
// Execute the production host-ordering helper against real BrowserWindows.
const filename = resolve(__dirname, "../../src/main/side-chat-test-window.ts");
const compiled = ts.transpileModule(readFileSync(filename, "utf8"), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText;
const hostExports = {};
runInNewContext(compiled, { exports: hostExports });
const { presentSideChatTaskHost } = hostExports;
const addon = require(process.env.COMMA_SIDE_CHAT_BACKDROP_PATH);
const results = [];
app.on("window-all-closed", () => {});
let active;
let server;
const probe = `
window.__taskFrames = [];
function sample(time) {
  const root = document.getElementById('comma-task-window-boot');
  const shell = root?.querySelector('.comma-side-chat-test-shell');
  if (shell) {
    const r = shell.getBoundingClientRect();
    const backdrop = getComputedStyle(root, '::before');
    window.__taskFrames.push({time, expanded: root.dataset.expanded, rect: {x:r.x,y:r.y,width:r.width,height:r.height}, opacity: getComputedStyle(shell).opacity, backdropTransform: backdrop.transform, backdropOpacity: backdrop.opacity, hostTransform: getComputedStyle(root).transform});
  }
  if (window.__taskFrames.length < 120) requestAnimationFrame(sample);
}
requestAnimationFrame(sample);
`;
(async () => {
  await app.whenReady();
  app.setActivationPolicy("accessory");
  server = createServer(async (req, res) => {
    const path = new URL(req.url, "http://localhost").pathname;
    if (path === "/probe.js") {
      res.setHeader("Content-Type", "text/javascript");
      res.end(probe);
      return;
    }
    if (/\/renderComma-[^/]+\.js$/.test(path)) {
      // Import may only start after the entrance. No test modifies animation time.
      const frames = await active.webContents.executeJavaScript("window.__taskFrames");
      results.push({ shownBeforeLoad: active.shownBeforeLoad, frames });
      res.setHeader("Content-Type", "text/javascript");
      res.end("");
      active.destroy();
      if (results.length === 2) {
        process.stdout.write(
          "TASK_ENTRANCE_RESULT=" + JSON.stringify(results) + "\n",
          () => {
            server.close();
            app.quit();
          }
        );
      } else await run();
      return;
    }
    const file = resolve(root, "." + (path === "/" ? "/index.html" : path));
    try {
      let content = readFileSync(file);
      const type = {
        ".js": "text/javascript",
        ".css": "text/css",
        ".html": "text/html",
      }[extname(file)];
      if (type) res.setHeader("Content-Type", type);
      if (path === "/")
        content = content
          .toString()
          .replace(
            '<script type="module"',
            '<script src="/probe.js"></script><script type="module"'
          );
      res.end(content);
    } catch {
      res.statusCode = 404;
      res.end();
    }
  });
  await new Promise((listening) => server.listen(0, "127.0.0.1", listening));
  async function run() {
    active = new BrowserWindow({
      width: 1280,
      height: 800,
      x: 0,
      y: 0,
      show: false,
      frame: false,
      transparent: true,
      backgroundColor: "#00000000",
      hasShadow: false,
      type: "panel",
      webPreferences: { sandbox: true, backgroundThrottling: false },
    });
    presentSideChatTaskHost(active, addon, true);
    active.shownBeforeLoad = active.isVisible();
    await active.loadURL(
      "http://127.0.0.1:" +
        server.address().port +
        "/#/side-chat/test-window?workspaceId=w&groupId=g&conversationId=c&sourceHeight=24&sourceWidth=120&sourceX=40&sourceY=80"
    );
  }
  await run();
})().catch((error) => {
  console.error(error);
  app.exit(1);
});
setTimeout(() => {
  console.error("Task entrance timed out");
  app.exit(1);
}, 20000).unref();
