import { test, expect } from "@playwright/test";
import { build } from "vite";
import { builtinModules, createRequire } from "node:module";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";

const callbackTime = Date.UTC(2026, 0, 15, 12);
let output: string;
let startTokenDance: typeof import("./fixtures/tokendance-loopback").startTokenDance;
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
        entry: resolve("apps/electron/test/fixtures/tokendance-loopback.ts"),
        formats: ["cjs"],
        fileName: () => "authorization.cjs",
      },
      rolldownOptions: {
        platform: "node",
        external: (id) => id.startsWith("node:") || builtinModules.includes(id),
      },
    },
  });
  ({ startTokenDance } = createRequire(resolve("package.json"))(
    join(output, "authorization.cjs")
  ));
});
test.afterAll(async () => {
  await rm(output, { recursive: true, force: true });
});
// Exercise the real temporary listener and callback document in a browser.
// The client core runs the sign-in; the Comma API and TokenDance's key
// exchange are isolated so this never authorizes or charges an account.
test("an accepted callback returns to Comma and closes its browser tab after 1.5 seconds", async ({
  page,
}) => {
  // The callback pages' timers run on the context's clock, held still so only
  // the test moves it.
  await page.clock.install({ time: callbackTime });
  await page.clock.pauseAt(callbackTime);
  const flow = startTokenDance("comma-dev://authorization/return");
  try {
    const authorization = new URL(await flow.opened);
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
    await page.clock.runFor(1700);
    expect(popup.isClosed()).toBe(false);
    expect(flow.returns()).toBe(0);

    const closed = popup.waitForEvent("close");
    await popup.goto(callback.href);
    await expect(popup.getByRole("link", { name: "Return to Comma" })).toHaveAttribute(
      "href",
      "comma-dev://authorization/return"
    );
    expect(flow.returns()).toBe(1);
    await page.clock.runFor(1499);
    expect(popup.isClosed()).toBe(false);
    await page.clock.runFor(1);
    await closed;
    expect(await flow.connected).toBe("saved");
  } finally {
    flow.close();
  }
});
