// Drives the image's browser tools as an agent's runtime does (systems/station/src/agents/browser-mcp.ts): starts the
// Playwright MCP server over stdio with the image's configuration, has it open a page, and looks at the display for
// the window. It passes when the page's text comes back in the tool's answer and the browser's window is over the
// whole display: the size comma-display.service gives the display and the one browser-mcp.json gives the window agree.
// Run in the image, with the display up, as a user that is not root (Chromium's sandbox):
//
//   node browser-mcp-check.mjs
//
// The Coding sandbox image workflow runs it before it publishes an image.
import { execFileSync, spawn } from "node:child_process";

const xdotool = (...args) => execFileSync("xdotool", args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
const [width, height] = xdotool("getdisplaygeometry").trim().split(" ").map(Number);
const DISPLAY = { width, height };
const TITLE = "browser-mcp-check";
const config = process.env.COMMA_BROWSER_MCP_CONFIG ?? "/etc/comma/browser-mcp.json";
const server = spawn("playwright-mcp", ["--config", config], { stdio: ["pipe", "pipe", "inherit"] });
const fail = (why) => {
  console.error(`browser-mcp-check: ${why}`);
  server.kill();
  process.exit(1);
};
setTimeout(() => fail("no answer in 90 s"), 90_000).unref();
server.on("exit", (code) => fail(`the server exited (${code})`));

const waiting = new Map();
let unread = "";
server.stdout.on("data", (chunk) => {
  unread += chunk;
  for (let end = unread.indexOf("\n"); end >= 0; end = unread.indexOf("\n")) {
    const line = unread.slice(0, end).trim();
    unread = unread.slice(end + 1);
    if (!line) continue;
    const message = JSON.parse(line);
    waiting.get(message.id)?.(message);
    waiting.delete(message.id);
  }
});
let ids = 0;
const send = (message) => server.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
const request = (method, params) =>
  new Promise((resolve) => {
    const id = ++ids;
    waiting.set(id, (answer) => (answer.error ? fail(`${method}: ${JSON.stringify(answer.error)}`) : resolve(answer.result)));
    send({ id, method, params });
  });

await request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "browser-mcp-check", version: "0" } });
send({ method: "notifications/initialized" });
const opened = await request("tools/call", { name: "browser_navigate", arguments: { url: `data:text/html,<title>${TITLE}</title><h1>the page is open</h1>` } });
const said = (opened.content ?? []).map((part) => part.text ?? "").join("\n");
if (opened.isError || !said.includes("the page is open")) fail(`browser_navigate did not show the page: ${said}`);

// The browser's window is the one named after the page's title: the root window has the display's size too. The
// name follows the page a moment later, and the browser makes and removes small windows of its own as it goes.
// Chromium makes a window that is asked to be the display's size one pixel smaller each way.
const browserWindow = () => {
  try {
    const [id] = xdotool("search", "--onlyvisible", "--name", TITLE).trim().split("\n");
    const [, at, width, height] = /Position: (\S+)[^]*Geometry: (\d+)x(\d+)/.exec(xdotool("getwindowgeometry", id));
    return { at, width: Number(width), height: Number(height) };
  } catch {
    return undefined;
  }
};
let found = browserWindow();
for (let tries = 0; !found && tries < 40; tries++) {
  await new Promise((resolve) => setTimeout(resolve, 250));
  found = browserWindow();
}
if (!found) fail("the browser's window is not on the display");
const covers = (size, of) => size === of || size === of - 1;
if (found.at !== "0,0" || !covers(found.width, DISPLAY.width) || !covers(found.height, DISPLAY.height))
  fail(`the browser's window is ${found.width}x${found.height} at ${found.at}; the display is ${DISPLAY.width}x${DISPLAY.height}`);

console.log(`browser-mcp-check: the page is open in a ${found.width}x${found.height} window on the ${DISPLAY.width}x${DISPLAY.height} display`);
server.removeAllListeners("exit");
server.kill();
process.exit(0);
