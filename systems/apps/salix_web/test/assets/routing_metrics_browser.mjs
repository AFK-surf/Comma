// Rendering evidence only. Data/filter behavior is covered through the LiveView entry point.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { mkdir } from "node:fs/promises";
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.ROUTING_PLAYWRIGHT_MODULE || "playwright");
const cdp = process.env.ROUTING_CDP;
const browser = cdp ? await chromium.connectOverCDP(cdp) : await chromium.launch({ headless: true });
const page = cdp ? await browser.contexts()[0].newPage() : await browser.newPage({ deviceScaleFactor: 2 });
page.setDefaultTimeout(10_000);
page.setDefaultNavigationTimeout(15_000);
const errors = [];
page.on("pageerror", error => errors.push(error.message));
const shots = process.env.ROUTING_SCREENSHOTS;
if (shots) await mkdir(shots, { recursive: true });
try {
  await page.setViewportSize({ width: 1600, height: 1100 });
  const base = process.env.ROUTING_BROWSER_URL;
  await page.goto(`${base}/dash/login`);
  if (new URL(page.url()).pathname === "/dash/login") {
    await page.locator("input[name=token]").fill("test-token");
    await page.locator("button[type=submit]").click();
    await page.waitForURL("**/dash");
  }
  await page.goto(`${base}/dash/tenant/select?tenant_id=${process.env.ROUTING_BROWSER_TENANT}`);
  await page.goto(`${base}/dash/groups/${process.env.ROUTING_BROWSER_GROUP}?tab=model-routing`);
  await page.locator("#routing-metrics-table tbody tr").first().waitFor();
  await page.locator("#routing-metrics").getByText("All routes", { exact: true }).waitFor();
  if (shots) await page.locator("#routing-metrics").screenshot({ path: `${shots}/routing-metrics-desktop.png` });
  await page.getByText("How these numbers are calculated", { exact: true }).click();
  await page.getByText("Estimated cost is not actual spending or a bill.", { exact: true }).waitFor();
  if (shots) await page.locator("#routing-metrics").screenshot({ path: `${shots}/routing-metrics-definitions.png` });
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  if (shots) await page.screenshot({ path: `${shots}/routing-metrics-mobile.png`, fullPage: true });
  assert.deepEqual(errors, []);
} finally {
  await page.close();
  // Closing a CDP-connected Playwright client disconnects it; the shared browser stays open.
  await browser.close();
}
