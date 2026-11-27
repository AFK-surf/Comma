// The browser a machine brings the station's agents: the Playwright MCP server, an MCP server of its own beside the
// station's (tools/mcp.ts), which each runtime starts over stdio. The coding sandbox image installs it and says so
// with COMMA_BROWSER_MCP_CONFIG, the path of its configuration (systems/runtime-images/coding-sandbox/
// browser-mcp.json): the image's Chromium, as a window on the sandbox's display. A machine that does not say so has
// no browser tools; nothing is looked for or downloaded.
//
// The server starts with the runtime's process; it opens the browser at the first tool call, and the browser stays
// while that process does.
import type { Env } from "./machine-logins.ts";

/// The server's name in each runtime's configuration: Claude Code's tools are `mcp__playwright__browser_*`.
export const BROWSER_MCP_NAME = "playwright";
/// Whether a runtime's tool is one of the browser's, as its live steps name it: Claude Code's `mcp__playwright__…`,
/// Codex's `playwright.…` (agents/live.ts).
export const isBrowserTool = (tool: string): boolean =>
  tool.startsWith(`mcp__${BROWSER_MCP_NAME}__`) || tool.startsWith(`${BROWSER_MCP_NAME}.`);
/// Whether a browser tool is the one that closes the browser (`browser_close`): nothing is on the display after it.
export const isBrowserClose = (tool: string): boolean => isBrowserTool(tool) && tool.endsWith("browser_close");
/// The image puts it on the PATH (`npm install --global @playwright/mcp`).
const COMMAND = "playwright-mcp";
/// Codex gives an MCP call 60 seconds by default, which is also the server's navigation timeout: room for a slow
/// page to answer within its own.
export const BROWSER_MCP_TOOL_TIMEOUT_SECONDS = 120;

export type BrowserMcp = {
  command: string;
  args: string[];
  /// What the server needs of the station's environment, said outright: Codex passes its MCP servers only a few
  /// variables, and a window needs the display.
  env: Record<string, string>;
};

/// The browser server of the machine whose environment is `env`; null when it brings none.
export function browserMcp(env: Env = process.env): BrowserMcp | null {
  const config = env.COMMA_BROWSER_MCP_CONFIG;
  if (!config) return null;
  return { command: COMMAND, args: ["--config", config], env: env.DISPLAY ? { DISPLAY: env.DISPLAY } : {} };
}
