// Opt in with SALIX_ROUTING_BROWSER=1. The test owns the local dashboard and tenant.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { mkdir, readFile } from "node:fs/promises";
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.ROUTING_PLAYWRIGHT_MODULE || "playwright");
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, deviceScaleFactor: 2 });
const shots = process.env.ROUTING_SCREENSHOTS;
if (shots) await mkdir(shots, { recursive: true });
const capture = async name => {
  if (shots) await page.locator("#model-routing-form").screenshot({ path: `${shots}/${name}.png` });
};
const table = {
  mode: "routes", schema_version: 2,
  entries: [{ key: "quick-edit", description: "Small, localized edits / 小修改",
    model: { kind: "catalog", model: "deepseek-flash", reasoning_effort: "high", allow_paid: true } }],
};
const file = content => ({ name: "routes.json", mimeType: "application/json", buffer: Buffer.from(content) });
const errors = [];
page.on("pageerror", error => errors.push(error.message));
try {
  const base = process.env.ROUTING_BROWSER_URL;
  await page.goto(`${base}/dash/login`);
  await page.locator("input[name=token]").fill("test-token");
  await page.locator("button[type=submit]").click();
  await page.waitForURL("**/dash");
  await page.goto(`${base}/dash/tenant/select?tenant_id=${process.env.ROUTING_BROWSER_TENANT}`);
  await page.goto(`${base}/dash/groups/${process.env.ROUTING_BROWSER_GROUP}?tab=model-routing`);
  await page.waitForSelector(".phx-connected");
  await page.getByRole("button", { name: "Refresh models", exact: true }).waitFor();
  await capture("routing-import-empty");

  const chooserPromise = page.waitForEvent("filechooser");
  await page.getByRole("button", { name: "Import JSON", exact: true }).click();
  await (await chooserPromise).setFiles(file(JSON.stringify(table)));
  await page.locator("#routing-key-0[value=quick-edit]").waitFor();
  await page.getByText("Unsaved changes", { exact: true }).waitFor();
  assert.equal(await page.locator("#routing-enabled").isChecked(), false);
  assert.equal(await page.locator("#routing-model-0 option:checked").textContent(), "DeepSeek V4.1 Flash · Pay-per-use");
  await capture("routing-import-draft");

  // A download contains the edited draft, including text not yet saved.
  const description = "Documentation and small code changes / 文档与小修改";
  await page.locator("#routing-description-0").fill(description);
  await page.locator("#routing-description-0").blur();
  const downloadPromise = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export JSON", exact: true }).click();
  const download = await downloadPromise;
  assert.equal(download.suggestedFilename(), "model-routing.json");
  const json = await readFile(await download.path(), "utf8");
  const expected = structuredClone(table);
  expected.entries[0].description = description;
  assert.deepEqual(JSON.parse(json), expected);

  await page.locator("#routing-import-file").setInputFiles(file("{"));
  await page.getByRole("alert").filter({ hasText: "Invalid route table" }).waitFor();
  assert.equal(await page.locator("#routing-description-0").inputValue(), description);
  await capture("routing-import-invalid");

  await page.locator("#routing-import-file").setInputFiles(file(" ".repeat(65537)));
  await page.getByRole("alert").filter({ hasText: "no larger than 64 KiB" }).waitFor();
  await page.getByRole("button", { name: "Discard changes", exact: true }).click();
  await page.locator("#routing-key-0").waitFor({ state: "detached" });
  // The same file can be selected again after a successful or rejected import.
  await page.locator("#routing-import-file").setInputFiles(file(json));
  await page.locator("#routing-key-0[value=quick-edit]").waitFor();
  assert.equal(await page.locator("#routing-description-0").inputValue(), description);
  await page.setViewportSize({ width: 390, height: 844 });
  await capture("routing-import-mobile");
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await page.getByText("Changes apply after you save.", { exact: true }).waitFor();
  await page.reload();
  await page.locator("#routing-key-0[value=quick-edit]").waitFor();
  assert.equal(await page.locator("#routing-model-0 option:checked").textContent(), "DeepSeek V4.1 Flash · Pay-per-use");
  assert.equal(await page.locator("#routing-effort-0").inputValue(), "high");
  await page.setViewportSize({ width: 1440, height: 1000 });
  await capture("routing-paid-saved");
  assert.deepEqual(errors, []);
  console.log("Paid model without a Profile pin, save/reload, file transfer, invalid files and mobile layout passed.");
} finally {
  await browser.close();
}
