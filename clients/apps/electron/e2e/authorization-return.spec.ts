import { test, expect } from "@playwright/test";
import { build } from "vite";
import { builtinModules, createRequire } from "node:module";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";

let output: string;
let TokenDanceAuthorizationService: typeof import("../src/main/tokendance-authorization").TokenDanceAuthorizationService;
test.beforeAll(async () => {
  output = await mkdtemp(join(tmpdir(), "comma-authorization-return-"));
  // Bundle with the app's JSX runtime, not Playwright's component-test JSX.
  await build({
    configFile: false,
    logLevel: "error",
    oxc: { jsx: { runtime: "automatic" } },
    build: {
      outDir: output,
      minify: false,
      lib: {
        entry: resolve("apps/electron/src/main/tokendance-authorization.ts"),
        formats: ["cjs"],
        fileName: () => "authorization.cjs",
      },
      rolldownOptions: {
        platform: "node",
        external: (id) => id.startsWith("node:") || builtinModules.includes(id),
      },
    },
  });
  ({ TokenDanceAuthorizationService } = createRequire(resolve("package.json"))(
    join(output, "authorization.cjs")
  ));
});
test.afterAll(async () => {
  await rm(output, { recursive: true, force: true });
});
import type { MainSessionBoundApi } from "../src/main/modules/session/main-session-transport";

// Exercise the real temporary listener and callback document in a browser.
// Provider exchange is isolated so this never authorizes or charges an account.
test("an accepted callback returns to Comma and closes its browser tab after 1.5 seconds", async ({
  page,
}) => {
  let authorizationUrl = "";
  let returnCount = 0;
  const service = new TokenDanceAuthorizationService(
    () =>
      ({
        api: { discoverModels: async () => ({ data: [], protocol: "responses" }) },
        isCurrent: () => true,
        assertCurrent: () => {},
      }) as unknown as MainSessionBoundApi,
    async (url) => {
      authorizationUrl = url;
    },
    async () => Response.json({ key: "isolated-provider-key" }),
    undefined,
    {
      url: "comma-dev://authorization/return",
      open: () => {
        returnCount += 1;
      },
    }
  );
  try {
    await service.start({ requestId: "test-return", workspaceId: "isolated" });
    const authorization = new URL(authorizationUrl);
    expect(authorization.searchParams.get("app_url")).toBe("app://comma-dev");
    expect(authorization.searchParams.get("key_name")).toBe("Comma Dev");
    const callback = new URL(authorization.searchParams.get("callback_url")!);
    callback.searchParams.set("code", "isolated-code");
    await page.goto("about:blank");
    const popupPromise = page.waitForEvent("popup");
    await page.evaluate(() => window.open("about:blank"));
    const popup = await popupPromise;
    const wrongState = new URL(callback);
    wrongState.searchParams.set("state", "unrelated");
    await popup.goto(wrongState.href);
    await expect(
      popup.getByRole("heading", { name: "Start again from Comma" })
    ).toBeVisible();
    await popup.waitForTimeout(1700);
    expect(popup.isClosed()).toBe(false);
    expect(returnCount).toBe(0);

    const started = Date.now();
    const closed = popup.waitForEvent("close");
    await popup.goto(callback.href);
    await expect(popup.getByRole("link", { name: "Return to Comma" })).toHaveAttribute(
      "href",
      "comma-dev://authorization/return"
    );
    expect(returnCount).toBe(1);
    await popup.waitForTimeout(700);
    expect(popup.isClosed()).toBe(false);
    await closed;
    expect(Date.now() - started).toBeGreaterThanOrEqual(1400);
  } finally {
    service.dispose();
  }
});
