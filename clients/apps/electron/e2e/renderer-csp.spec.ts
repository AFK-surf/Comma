import { expect, test } from "@playwright/test";
import { resolve } from "node:path";

// Run a same-origin script under the real renderer document's policy. DevTools
// evaluation bypasses CSP, so the probe must execute as a page script.
test("renderer permits WebAssembly compilation and rejects JavaScript eval", async ({
  page,
}) => {
  await page.route("http://renderer-csp.test/**", async (route) => {
    const pathname = new URL(route.request().url()).pathname;
    if (pathname === "/") {
      await route.fulfill({
        contentType: "text/html",
        path: resolve(__dirname, "../src/renderer/index.html"),
      });
    } else if (pathname === "/src/main.tsx") {
      await route.fulfill({
        contentType: "text/javascript",
        body: `
          const result = { wasm: false, evalBlocked: false };
          try {
            await WebAssembly.compile(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]));
            result.wasm = true;
          } catch {}
          try { eval("1 + 1"); } catch (error) {
            result.evalBlocked = error instanceof EvalError;
          }
          document.querySelector("#root").textContent = JSON.stringify(result);
        `,
      });
    } else {
      await route.fulfill({ status: 204, body: "" });
    }
  });
  await page.goto("http://renderer-csp.test/");
  await expect(page.locator("#root")).toHaveText(
    JSON.stringify({ wasm: true, evalBlocked: true })
  );
});
