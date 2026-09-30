import { test, expect, type Page, type TestInfo } from "@playwright/test";

const token = process.env.SALIX_API_TOKEN || "e2e-admin-token";
const fixture = process.env.SALIX_MODEL_DISCOVERY_URL;
const headers = { authorization: `Bearer ${token}` };
const ids: string[] = [];
async function shot(page: Page, info: TestInfo, name: string) {
  await page.screenshot({
    path: info.outputPath(`${name}.png`),
    fullPage: false,
  });
}
async function connected(page: Page) {
  await expect(page.locator("[data-phx-main]")).toHaveClass(/phx-connected/);
}
async function login(page: Page) {
  await page.goto("/dash/login");
  await page.locator("input[name=token]").fill(token);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await connected(page);
}
async function save(page: Page) {
  await page
    .getByRole("button", { name: "Save template", exact: true })
    .click();
  await expect(
    page.getByText("Template saved.", { exact: true }),
  ).toBeVisible();
  await connected(page);
  await expect(page.locator("#template-form")).toHaveAttribute(
    "data-dirty",
    "false",
  );
}
async function toggle(page: Page, name: string, value: boolean) {
  const input = page.getByRole("checkbox", { name, exact: true });
  if ((await input.isChecked()) !== value)
    await page.getByText(name, { exact: true }).click();
  await expect(input).toBeChecked({ checked: value });
}
async function acceptNextDialog(page: Page, accept: boolean) {
  page.once("dialog", async (d) => {
    if (accept) await d.accept();
    else await d.dismiss();
  });
}

test.beforeEach(async ({ page }) => login(page));
test.afterEach(async ({ request }) => {
  for (const id of ids.splice(0))
    await request.delete(`/v1/admin/templates/${id}`, { headers });
});

test("browser back preserves a cancelled draft", async ({ page }, info) => {
  await page.goto("/dash/templates");
  await connected(page);
  await page
    .getByRole("link", { name: "Add model configuration", exact: true })
    .click();
  await page
    .getByLabel("Configuration alias", { exact: true })
    .fill("Unsaved back navigation");
  let prompted = false;
  page.once("dialog", async (dialog) => {
    prompted = true;
    await dialog.dismiss();
  });
  await page.evaluate(() => history.back());
  await expect.poll(() => prompted).toBe(true);
  await expect(
    page.getByLabel("Configuration alias", { exact: true }),
  ).toHaveValue("Unsaved back navigation");
  await shot(page, info, "60-back-cancelled");
  await acceptNextDialog(page, true);
  await page.evaluate(() => history.back());
  await expect(
    page.getByRole("heading", { name: "Model catalog", exact: true }),
  ).toBeVisible();
});

test("catalog menus, search, navigation and delete confirmation", async ({
  page,
  request,
}, info) => {
  const name = `Interaction audit ${Date.now()}`;
  const response = await request.post("/v1/admin/templates", {
    headers,
    data: { name, model: "audit-model" },
  });
  expect(response.ok()).toBeTruthy();
  const created = await response.json();
  ids.push(created.template_id);
  await page.goto("/dash/templates");
  await connected(page);
  await page.getByLabel("Search configurations", { exact: true }).fill(name);
  const row = page.locator("#global-templates tr").filter({ hasText: name });
  await expect(row).toHaveCount(1);
  await expect(page.locator("#global-templates tr")).toHaveCount(1);
  const before = await row.boundingBox();
  const more = row.getByText("More", { exact: true });
  await more.click();
  await expect(
    page.getByRole("menuitem", { name: "Delete", exact: true }),
  ).toBeVisible();
  await shot(page, info, "01-more-open");
  expect
    .soft(
      Math.abs((await row.boundingBox())!.height - before!.height),
      "More must not move the table row",
    )
    .toBeLessThan(1);
  await page.keyboard.press("Escape");
  await shot(page, info, "02-more-escape");
  expect
    .soft(
      await page
        .getByRole("menuitem", { name: "Delete", exact: true })
        .isVisible(),
      "Escape closes actions",
    )
    .toBe(false);
  await more.press("ArrowDown");
  await expect(
    page.getByRole("menuitem", { name: "Delete", exact: true }),
  ).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(more).toBeFocused();
  if (
    await page
      .getByRole("menuitem", { name: "Delete", exact: true })
      .isVisible()
  )
    await more.click();
  await more.click();
  await page
    .getByRole("heading", { name: "Model catalog", exact: true })
    .click();
  expect
    .soft(
      await page
        .getByRole("menuitem", { name: "Delete", exact: true })
        .isVisible(),
      "Outside click closes actions",
    )
    .toBe(false);
  if (
    await page
      .getByRole("menuitem", { name: "Delete", exact: true })
      .isVisible()
  )
    await more.click();
  await more.click();
  await acceptNextDialog(page, false);
  await page.getByRole("menuitem", { name: "Delete", exact: true }).click();
  await expect(row).toBeVisible();
  await shot(page, info, "03-delete-cancel");
  if (
    !(await page
      .getByRole("menuitem", { name: "Delete", exact: true })
      .isVisible())
  )
    await more.click();
  await acceptNextDialog(page, true);
  await page.getByRole("menuitem", { name: "Delete", exact: true }).click();
  await expect(row).toHaveCount(0);
  await shot(page, info, "04-delete-saved");
  ids.pop();
  await page
    .getByLabel("Search configurations", { exact: true })
    .fill("no matching audit model");
  await expect(
    page.getByText("No matching configurations.", { exact: true }).first(),
  ).toBeVisible();
  await shot(page, info, "05-search-empty");
  await page.getByLabel("Search configurations", { exact: true }).fill("");
  await expect(page.locator("#global-templates tr").first()).toBeVisible();
  await page.getByText("System fallback", { exact: true }).click();
  await shot(page, info, "06-fallback-expanded");
  await page
    .getByRole("link", { name: "Inspect fallback configuration →" })
    .click();
  await expect(page.locator("#template-form")).toBeVisible();
  await page
    .getByRole("link", { name: "← Model catalog", exact: true })
    .click();
  await page
    .getByRole("link", { name: "Manage Router and Worker defaults →" })
    .click();
  await expect(
    page.getByRole("heading", { name: "Agent defaults", exact: true }),
  ).toBeVisible();
  await page.getByRole("link", { name: "Templates", exact: true }).click();
  await page
    .getByRole("link", { name: "Add model configuration", exact: true })
    .click();
  await page.getByRole("link", { name: "Cancel", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Model catalog", exact: true }),
  ).toBeVisible();
});

test("global editor fields, disclosure, validation, flags and dirty navigation", async ({
  page,
  request,
}, info) => {
  test.setTimeout(90000);
  await page.goto("/dash/templates/new");
  await connected(page);
  await shot(page, info, "10-create-empty");
  await page
    .getByRole("button", { name: "Save template", exact: true })
    .click();
  await shot(page, info, "11-required-validation");
  await page.getByLabel("Model ID", { exact: true }).fill("audit-model");
  const alias = `Audit all fields ${Date.now()}`;
  await page.getByLabel("Configuration alias", { exact: true }).fill(alias);
  await page
    .getByLabel("API base URL", { exact: true })
    .fill("http://127.0.0.1:1");
  for (const value of ["responses", "anthropic", "chat_completions", ""])
    await page.getByLabel("API protocol", { exact: true }).selectOption(value);
  await page.getByLabel("API key", { exact: true }).fill("audit-secret");
  await page.getByRole("button", { name: "Fetch models", exact: true }).click();
  await expect(page.getByRole("alert")).toBeVisible();
  await shot(page, info, "12-discovery-failure");
  await toggle(page, "Hide from model selectors", true);
  await save(page);
  ids.push(new URL(page.url()).pathname.split("/").at(-1)!);
  await toggle(page, "Hide from model selectors", false);
  await page.locator("#runtime-options > summary").click();
  await page.getByLabel("Maximum output tokens", { exact: true }).fill("1024");
  await page.getByLabel("Context tokens", { exact: true }).fill("8192");
  await page.getByLabel("Maximum output tokens", { exact: true }).fill("0");
  await page
    .getByRole("button", { name: "Save template", exact: true })
    .click();
  expect(
    await page
      .getByLabel("Maximum output tokens", { exact: true })
      .evaluate((el: HTMLInputElement) => el.validity.valid),
  ).toBe(false);
  await shot(page, info, "13-number-validation");
  await page.getByLabel("Maximum output tokens", { exact: true }).fill("1024");
  await toggle(page, "Main model accepts image input", true);
  await save(page);
  expect
    .soft(
      await page
        .getByRole("checkbox", {
          name: "Hide from model selectors",
          exact: true,
        })
        .isChecked(),
      "Hidden flag can be turned off",
    )
    .toBe(false);
  await page.locator("#runtime-options > summary").click();
  await toggle(page, "Main model accepts image input", false);
  await save(page);
  await page.locator("#runtime-options > summary").click();
  expect
    .soft(
      await page
        .getByRole("checkbox", {
          name: "Main model accepts image input",
          exact: true,
        })
        .isChecked(),
      "Image input can be turned off",
    )
    .toBe(false);
  await shot(page, info, "13-runtime-flags");
  await page.locator("#media-options > summary").click();
  for (const label of [
    "Image generation",
    "Video",
    "Vision describer",
    "Analysis",
  ])
    await page.getByLabel(label, { exact: true }).fill('{"custom":"kept"}');
  await page.locator("#advanced-options > summary").click();
  await page
    .getByLabel("Runtime provider override", { exact: true })
    .fill("openai");
  await page.getByLabel("Purpose", { exact: true }).fill("audit-purpose");
  await page
    .getByLabel("Extra provider parameters", { exact: true })
    .fill('{"timeout_ms":2000}');
  await page
    .getByLabel("Request headers", { exact: true })
    .fill('{"x-audit":"yes"}');
  await page
    .getByLabel("Request headers", { exact: true })
    .scrollIntoViewIfNeeded();
  await shot(page, info, "14-advanced-fields");
  await shot(page, info, "14-all-sections-expanded");
  await page.getByLabel("Analysis", { exact: true }).fill("{invalid");
  await page
    .getByRole("button", { name: "Save template", exact: true })
    .click();
  await expect(
    page.getByText("Enter a valid JSON object.", { exact: true }),
  ).toBeVisible();
  await expect(page.getByText("Template saved.", { exact: true })).toBeHidden();
  await shot(page, info, "15-json-error");
  await page.getByLabel("Analysis", { exact: true }).fill("{}");
  await shot(page, info, "16-json-corrected");
  expect
    .soft(
      await page.getByLabel("Analysis", { exact: true }).isVisible(),
      "Correcting an error must not collapse the active section",
    )
    .toBe(true);
  await save(page);
  await page.locator("#advanced-options > summary").click();
  await page.getByLabel("Purpose", { exact: true }).fill("");
  await page.getByLabel("API key", { exact: true }).fill("audit-replacement");
  await save(page);
  await page.locator("#advanced-options > summary").click();
  expect
    .soft(
      await page.getByLabel("Purpose", { exact: true }).inputValue(),
      "Purpose can be cleared",
    )
    .toBe("");
  await expect(page.getByLabel("API key", { exact: true })).toHaveValue("");
  const stored = await (
    await request.get(`/v1/admin/templates/${ids[0]}`, { headers })
  ).json();
  expect(stored.provider_config.api_key).toBe("audit-replacement");
  expect(stored.provider_config.timeout_ms).toBe(2000);
  await page
    .getByLabel("Configuration alias", { exact: true })
    .fill(alias + " discarded");
  await acceptNextDialog(page, false);
  await page.getByRole("link", { name: "Cancel", exact: true }).click();
  await expect(
    page.getByLabel("Configuration alias", { exact: true }),
  ).toHaveValue(alias + " discarded");
  await shot(page, info, "17-draft-retained");
  await acceptNextDialog(page, true);
  await page
    .getByRole("link", { name: "← Model catalog", exact: true })
    .click();
  await expect(
    page.getByRole("heading", { name: "Model catalog", exact: true }),
  ).toBeVisible();
});

test("catalog pagination and narrow-screen actions", async ({
  page,
  request,
}, info) => {
  test.setTimeout(90000);
  for (let number = 0; number < 51; number++) {
    const response = await request.post("/v1/admin/templates", {
      headers,
      data: {
        name: `Pagination audit ${Date.now()} ${number}`,
        model: "audit-page",
      },
    });
    expect(response.ok()).toBeTruthy();
    ids.push((await response.json()).template_id);
  }
  await page.goto("/dash/templates");
  await connected(page);
  const first = await page.locator("#global-templates tr").first().innerText();
  await page.getByRole("button", { name: "Next page", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "First page", exact: true }),
  ).toBeVisible();
  expect(
    await page.locator("#global-templates tr").first().innerText(),
  ).not.toBe(first);
  await shot(page, info, "40-next-page");
  await page.getByRole("button", { name: "First page", exact: true }).click();
  await expect(page.locator("#global-templates tr").first()).toHaveText(first, {
    useInnerText: true,
  });
  await expect(
    page.getByRole("heading", { name: "Platform billing", exact: true }),
  ).toBeInViewport();
  await expect(
    page.getByRole("navigation", { name: "Breadcrumb", exact: true }),
  ).toBeInViewport();
  await page.setViewportSize({ width: 390, height: 844 });
  const more = page
    .locator("#global-templates tr")
    .first()
    .getByText("More", { exact: true });
  await more.click();
  const menu = page.getByRole("menu");
  await expect(menu).toBeVisible();
  const box = await menu.boundingBox();
  expect(box!.x).toBeGreaterThanOrEqual(0);
  expect(box!.x + box!.width).toBeLessThanOrEqual(390);
  await shot(page, info, "41-narrow-menu");
  await page.keyboard.press("Escape");
});

test("private model save, reopen, edit and remove", async ({ page }, info) => {
  const alias = `Private audit ${Date.now()}`;
  await page.goto("/dash/templates/new?scope=tenant");
  await connected(page);
  await page.getByLabel("Model ID", { exact: true }).fill("audit-private");
  await page.getByLabel("Configuration alias", { exact: true }).fill(alias);
  await save(page);
  try {
    await page
      .getByRole("link", { name: "← Model catalog", exact: true })
      .click();
    const row = page
      .locator("#private-templates tr")
      .filter({ hasText: alias });
    await expect(row).toBeVisible();
    await row.getByRole("link", { name: "audit-private", exact: true }).click();
    await page.getByLabel("Source", { exact: true }).selectOption("codex");
    await page
      .getByRole("button", { name: "Fetch models", exact: true })
      .click();
    await expect(
      page
        .getByLabel("Search models", { exact: true })
        .or(page.getByRole("alert")),
    ).toBeVisible({ timeout: 20000 });
    if (await page.getByLabel("Search models", { exact: true }).isVisible()) {
      await page
        .locator('[aria-label="Available models"]')
        .scrollIntoViewIfNeeded();
    } else {
      await page.getByRole("alert").scrollIntoViewIfNeeded();
    }
    await shot(page, info, "50-private-subscription-discovery");
    await save(page);
    await expect(page.getByLabel("Source", { exact: true })).toHaveValue(
      "codex",
    );
    await page
      .getByRole("link", { name: "Manage subscriptions →", exact: true })
      .click();
    await expect(page).toHaveURL(/\/dash\/account-pool/);
    await page.getByRole("link", { name: "Templates", exact: true }).click();
    await page
      .locator("#private-templates tr")
      .filter({ hasText: alias })
      .getByRole("link", { name: "Edit", exact: true })
      .click();
    await page
      .getByRole("link", { name: "Manage defaults →", exact: true })
      .click();
    await expect(
      page.getByRole("heading", { name: "Agent defaults", exact: true }),
    ).toBeVisible();
  } finally {
    await page.goto("/dash/templates");
    await connected(page);
    const row = page
      .locator("#private-templates tr")
      .filter({ hasText: alias });
    await row.getByText("More", { exact: true }).click();
    await acceptNextDialog(page, true);
    await page.getByRole("menuitem", { name: "Delete", exact: true }).click();
    await expect(row).toHaveCount(0);
  }
});

test("model discovery choices, search and reconfirmation", async ({
  page,
}, info) => {
  test.skip(
    !fixture,
    "Set SALIX_MODEL_DISCOVERY_URL to the local model fixture.",
  );
  await page.goto("/dash/templates/new");
  await connected(page);
  await page.getByLabel("API base URL", { exact: true }).fill(fixture!);
  await page.getByLabel("API key", { exact: true }).fill("local-dev-only");
  await page
    .getByLabel("API protocol", { exact: true })
    .selectOption("chat_completions");
  await page.getByRole("button", { name: "Fetch models", exact: true }).click();
  await expect(page.getByLabel("Search models", { exact: true })).toBeVisible();
  await page
    .locator('[aria-label="Available models"]')
    .scrollIntoViewIfNeeded();
  await shot(page, info, "20-model-choices");
  await page.getByLabel("Search models", { exact: true }).fill("no-match");
  await expect(
    page.getByText(
      "No matching models. Try another search or enter a model ID.",
      { exact: true },
    ),
  ).toBeVisible();
  await shot(page, info, "21-model-search-empty");
  await page.getByLabel("Search models", { exact: true }).fill("claude");
  await page
    .getByRole("button", {
      name: "Claude · 本地验收 local/claude-demo",
      exact: true,
    })
    .click();
  await expect(page.getByLabel("Search models", { exact: true })).toBeHidden();
  await shot(page, info, "22-model-chosen");
  await page.getByRole("button", { name: "Change model", exact: true }).click();
  await page
    .getByRole("button", { name: "Close choices", exact: true })
    .click();
  await page.getByLabel("API base URL", { exact: true }).fill(fixture! + "/v1");
  await expect(
    page.getByRole("button", { name: "Keep this model ID", exact: true }),
  ).toBeVisible();
  await shot(page, info, "23-connection-changed");
  await page
    .getByRole("button", { name: "Keep this model ID", exact: true })
    .click();
  if (!(await page.getByLabel("Model ID", { exact: true }).isVisible()))
    await page.locator("#manual-model > summary").click();
  await page.getByLabel("Model ID", { exact: true }).fill("manual/audit");
  await expect(page.getByLabel("Model ID", { exact: true })).toBeVisible();
  await shot(page, info, "24-manual-id");
  await acceptNextDialog(page, true);
  await page.getByRole("link", { name: "Cancel", exact: true }).click();
});

for (const width of [1440, 768, 390])
  test(`private editor sources and all disclosures at ${width}px`, async ({
    page,
  }, info) => {
    await page.setViewportSize({ width, height: 900 });
    await page.goto("/dash/templates/new");
    await connected(page);
    await page
      .getByRole("link", { name: "Use private scope", exact: true })
      .click();
    await expect(page.getByLabel("Source", { exact: true })).toBeVisible();
    await page
      .getByRole("link", { name: "Use global scope", exact: true })
      .click();
    await page
      .getByRole("link", { name: "Use private scope", exact: true })
      .click();
    for (const source of ["codex", "claude", ""]) {
      await page.getByLabel("Source", { exact: true }).selectOption(source);
      await expect(page.getByLabel("API key", { exact: true })).toBeVisible({
        visible: source === "",
      });
      await shot(page, info, `30-source-${source || "api"}-${width}`);
    }
    for (const section of [
      "runtime-options",
      "media-options",
      "advanced-options",
    ])
      await page.locator(`#${section} > summary`).click();
    await page
      .getByLabel("Image generation source", { exact: true })
      .selectOption("codex");
    await shot(page, info, `31-image-codex-${width}`);
    await expect(
      page.getByLabel("Image generation", { exact: true }),
    ).toBeHidden();
    await page
      .getByLabel("Image generation source", { exact: true })
      .selectOption("");
    await expect(
      page.getByLabel("Image generation", { exact: true }),
    ).toBeVisible();
    await shot(page, info, `32-all-open-${width}`);
    const overflow = await page
      .locator("#dash-content")
      .evaluate((el) => el.scrollWidth - el.clientWidth);
    expect
      .soft(overflow, "Editor has no horizontal clipping")
      .toBeLessThanOrEqual(1);
    await page
      .getByRole("button", { name: "Save template", exact: true })
      .scrollIntoViewIfNeeded();
    const saveBox = await page
      .getByRole("button", { name: "Save template", exact: true })
      .boundingBox();
    expect(saveBox!.x + saveBox!.width).toBeLessThanOrEqual(width);
    await page
      .getByLabel("Request headers", { exact: true })
      .scrollIntoViewIfNeeded();
    await shot(page, info, `33-bottom-fields-${width}`);
    await acceptNextDialog(page, true);
    await page.getByRole("link", { name: "Cancel", exact: true }).click();
  });
