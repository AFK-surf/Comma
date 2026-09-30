import { expect, test } from "@playwright/test";

// Run against an isolated instance with the test-only model override.
test("production Compose logs in, provisions a workspace, and serves its source", async ({
  page,
  request,
  context,
}) => {
  const email = `selfhost-${Date.now()}@example.com`;
  const mailpit = process.env.COMMA_SELFHOST_MAILPIT_URL || "http://localhost:8025";
  const requests: string[] = [];
  page.on("request", (req) => requests.push(req.url()));
  await page.goto("/");
  await page.getByRole("textbox", { name: /email/i }).fill(email);
  await page.getByRole("button", { name: "Send code" }).click();

  let code = "";
  await expect
    .poll(
      async () => {
        const messages = await (await request.get(`${mailpit}/api/v1/messages`)).json();
        const message = messages.messages?.find(
          (item: { To?: { Address: string }[] }) =>
            item.To?.some((to) => to.Address === email)
        );
        if (!message) return false;
        const body = await (
          await request.get(`${mailpit}/api/v1/message/${message.ID}`)
        ).json();
        code = (body.Text as string).match(/\b\d{6}\b/)?.[0] || "";
        return code.length === 6;
      },
      { timeout: 30_000 }
    )
    .toBe(true);
  await page.getByRole("textbox", { name: /verification code/i }).fill(code);
  await page.getByRole("button", { name: "Verify code" }).click();
  await expect(page.getByRole("complementary", { name: "App sidebar" })).toBeVisible({
    timeout: 90_000,
  });
  expect(
    (await context.cookies()).some(
      (cookie) => cookie.name === "comma_session" && cookie.httpOnly
    )
  ).toBe(true);
  await page.reload();
  await expect(page.getByRole("complementary", { name: "App sidebar" })).toBeVisible();
  expect(
    requests.filter((url) => /https?:\/\/(salix|app)(-staging)?\.comma\.surf/.test(url))
  ).toEqual([]);
  await page.getByRole("textbox", { name: "AI prompt" }).fill("Hello from selfhost");
  await page.getByRole("button", { name: /^Send(?: message)?$/ }).click();
  await expect(page.getByText(/LOCAL_CHAT_OK/).first()).toBeVisible({
    timeout: 60_000,
  });
  await page.reload();
  await expect(page.getByText(/LOCAL_CHAT_OK/).first()).toBeVisible();
  await page.getByRole("textbox", { name: "AI prompt" }).fill("LOCAL_CREATE_TASK");
  await page.getByRole("button", { name: /^Send(?: message)?$/ }).click();
  await expect(page.getByText(/任务已经交给本地 Worker/).first()).toBeVisible({
    timeout: 60_000,
  });
  await page.getByRole("link", { name: "Tasks", exact: true }).click();
  await page
    .getByText("本地 Task 链路验证", { exact: true })
    .filter({ visible: true })
    .first()
    .click({ timeout: 60_000 });
  await expect(page.getByText(/LOCAL_TASK_DONE/).first()).toBeVisible({
    timeout: 60_000,
  });
  if (process.env.COMMA_SELFHOST_STATE_PATH) {
    await context.storageState({ path: process.env.COMMA_SELFHOST_STATE_PATH });
  }
  const source = page.getByRole("link", { name: "Source · AGPL-3.0" });
  await expect(source).toHaveAttribute("href", "/source.tar.gz");
  expect((await request.head("/source.tar.gz")).ok()).toBe(true);
  expect(await (await request.get("/LICENSE")).text()).toContain(
    "GNU AFFERO GENERAL PUBLIC LICENSE"
  );
});

test("the configured owner can use Admin without a comma.surf identity", async ({
  page,
  request,
}) => {
  const admin = process.env.COMMA_SELFHOST_ADMIN_URL || "http://localhost:8082";
  const mailpit = process.env.COMMA_SELFHOST_MAILPIT_URL || "http://localhost:8025";
  const email = "selfhost-owner@example.com";
  const prior = await (await request.get(`${mailpit}/api/v1/messages`)).json();
  const priorIds = new Set(prior.messages.map((message: { ID: string }) => message.ID));
  await page.goto(admin);
  await page.getByRole("textbox", { name: /email/i }).fill(email);
  await page.getByRole("button", { name: "Send code" }).click();
  let code = "";
  await expect
    .poll(async () => {
      const messages = await (await request.get(`${mailpit}/api/v1/messages`)).json();
      const message = messages.messages?.find(
        (item: { ID: string; To?: { Address: string }[] }) =>
          !priorIds.has(item.ID) && item.To?.some((to) => to.Address === email)
      );
      if (!message) return false;
      const body = await (
        await request.get(`${mailpit}/api/v1/message/${message.ID}`)
      ).json();
      code = (body.Text as string).match(/\b\d{6}\b/)?.[0] || "";
      return code.length === 6;
    })
    .toBe(true);
  await page.getByRole("textbox", { name: /verification code/i }).fill(code);
  await page.getByRole("button", { name: "Verify code" }).click();
  await expect(
    page.getByRole("complementary", { name: "Admin navigation" })
  ).toBeVisible();
});
