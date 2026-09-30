import { expect, test } from "@playwright/test";

test.use({ storageState: process.env.COMMA_SELFHOST_STATE_PATH });

test("reinitialization preserves the session, chat history, and completed task", async ({
  page,
}) => {
  expect(process.env.COMMA_SELFHOST_STATE_PATH).toBeTruthy();
  await page.goto("/#/tasks");
  await expect(page.getByRole("complementary", { name: "App sidebar" })).toBeVisible();
  await page
    .getByText("本地 Task 链路验证", { exact: true })
    .filter({ visible: true })
    .first()
    .click();
  await expect(
    page
      .getByText(/LOCAL_TASK_DONE/)
      .filter({ visible: true })
      .first()
  ).toBeVisible();
  await page.getByRole("link", { name: "Home", exact: true }).click();
  await expect(
    page
      .getByText(/LOCAL_CHAT_OK/)
      .filter({ visible: true })
      .first()
  ).toBeVisible();
});
