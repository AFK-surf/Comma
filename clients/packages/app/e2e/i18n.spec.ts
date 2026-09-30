import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";

const session = {
  apiBaseUrl: "http://127.0.0.1:65535",
  email: "i18n-e2e@example.com",
  token: "comma_sess_i18n_e2e",
};

test.describe("client locale resolution", () => {
  // Wide enough for every Home rail to stay inline (Tasks folds below a
  // 1037px-wide Home route).
  test.use({ viewport: { width: 1440, height: 900 } });

  test.describe("with an English browser locale", () => {
    test.use({ locale: "en-US" });

    test("renders the English shell and home screen", async ({ page }) => {
      await installBrowserTestSession(page, session);
      await page.goto("/");

      await expect(page.locator("html")).toHaveAttribute("lang", "en");
      await expect(
        page.getByRole("link", { exact: true, name: "Home" })
      ).toHaveAttribute("aria-current", "page");
      await expect(page.getByRole("link", { name: "Inbox" })).toBeVisible();
      await expect(
        page.getByRole("button", { exact: true, name: "Settings" })
      ).toBeVisible();
      await expect(page.getByTestId("comma-window-bar-search")).toHaveText(
        /^Use .+ for search$/
      );
      const home = page.getByTestId("home-responsive-layout");
      await expect(home).toBeVisible();
      await expect(home.getByTestId("home-greet-rail")).toHaveAttribute(
        "aria-label",
        "Greet"
      );
      await expect(home.getByTestId("chat-empty")).toBeVisible();
      // Home has no route header: its identity lives on the region.
      await expect(page.getByRole("region", { name: "Comma assistant" })).toBeVisible();
      await expect(page.getByRole("heading", { level: 1 })).toHaveCount(0);
      await expect(page.getByRole("group", { name: "AI input" })).toBeVisible();
      await expect(home.getByTestId("home-tasks-rail")).toHaveAttribute(
        "aria-label",
        "Tasks"
      );
      await expect(
        home.getByRole("heading", { level: 2, name: "Tasks" })
      ).toBeVisible();
      await expect(
        page.getByRole("heading", { name: "What do you want to do" })
      ).toHaveCount(0);
    });
  });

  test.describe("with a Simplified Chinese browser locale", () => {
    test.use({ locale: "zh-CN" });

    test("renders the Chinese shell without localizing hash routes", async ({
      page,
    }) => {
      await installBrowserTestSession(page, session);
      await page.goto("/");

      await expect(page.locator("html")).toHaveAttribute("lang", "zh-CN");
      await expect(
        page.getByRole("link", { exact: true, name: "主页" })
      ).toHaveAttribute("aria-current", "page");
      await expect(page.getByRole("link", { name: "收件箱" })).toBeVisible();
      await expect(
        page.getByRole("button", { exact: true, name: "设置" })
      ).toBeVisible();
      await expect(page.getByTestId("comma-window-bar-search")).toHaveText(
        /^按 .+ 搜索$/
      );
      const home = page.getByTestId("home-responsive-layout");
      await expect(home).toBeVisible();
      await expect(home.getByTestId("home-greet-rail")).toHaveAttribute(
        "aria-label",
        "问候"
      );
      await expect(home.getByTestId("chat-empty")).toBeVisible();
      // Home has no route header: its identity lives on the region.
      await expect(page.getByRole("region", { name: "Comma 助手" })).toBeVisible();
      await expect(page.getByRole("heading", { level: 1 })).toHaveCount(0);
      await expect(page.getByRole("group", { name: "AI 输入" })).toBeVisible();
      await expect(home.getByTestId("home-tasks-rail")).toHaveAttribute(
        "aria-label",
        "任务"
      );
      await expect(home.getByRole("heading", { level: 2, name: "任务" })).toBeVisible();
      await expect(page.getByRole("heading", { name: "你想做什么" })).toHaveCount(0);

      await page.getByRole("link", { name: "收件箱" }).click();
      await expect(page).toHaveURL(/#\/inbox$/);
    });

    test("switches language from settings and keeps the choice after reload", async ({
      page,
    }) => {
      await installBrowserTestSession(page, session);
      await page.goto("/#/settings");

      await page.getByRole("button", { name: /选择语言/ }).click();
      await page.getByRole("option", { name: "English" }).click();
      await expect(page.locator("html")).toHaveAttribute("lang", "en");
      await expect(
        page.getByRole("heading", { level: 1, name: "General" })
      ).toBeVisible();
      // Settings renders inside the shell, so the rail relabels with it.
      await expect(
        page.getByRole("button", { exact: true, name: "Settings" })
      ).toHaveAttribute("aria-current", "page");
      await expect(page.getByRole("link", { exact: true, name: "Home" })).toBeVisible();

      await page.reload();
      await expect(page.locator("html")).toHaveAttribute("lang", "en");
      await expect(page.getByRole("button", { name: /Select language/ })).toContainText(
        "English"
      );
    });
  });

  test.describe("with an unsupported browser locale", () => {
    test.use({ locale: "fr-FR" });

    test("falls back to English", async ({ page }) => {
      await installBrowserTestSession(page, session);
      await page.goto("/");

      await expect(page.locator("html")).toHaveAttribute("lang", "en");
      await expect(page.getByRole("link", { name: "Inbox" })).toBeVisible();
      const home = page.getByTestId("home-responsive-layout");
      await expect(home).toBeVisible();
      await expect(home.getByTestId("home-greet-rail")).toHaveAttribute(
        "aria-label",
        "Greet"
      );
      await expect(home.getByTestId("chat-empty")).toBeVisible();
      // Home has no route header: its identity lives on the region.
      await expect(page.getByRole("region", { name: "Comma assistant" })).toBeVisible();
      await expect(page.getByRole("heading", { level: 1 })).toHaveCount(0);
      await expect(page.getByRole("group", { name: "AI input" })).toBeVisible();
      await expect(home.getByTestId("home-tasks-rail")).toHaveAttribute(
        "aria-label",
        "Tasks"
      );
      await expect(
        home.getByRole("heading", { level: 2, name: "Tasks" })
      ).toBeVisible();
      await expect(
        page.getByRole("heading", { name: "What do you want to do" })
      ).toHaveCount(0);
    });
  });
});
