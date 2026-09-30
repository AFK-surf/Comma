import { expect, type Page, test } from "@playwright/test";
import { installBrowserTestSession } from "../helpers/browser-auth";

const testSession = {
  apiBaseUrl: "http://127.0.0.1:4200",
  email: "icons@comma.local",
  token: "comma_sess_icon_e2e",
};

test("app shell icons render through Central Icons at runtime", async ({ page }) => {
  await installBrowserTestSession(page, testSession);

  await page.goto("/");

  await expect(page.getByTestId("home-responsive-layout")).toBeVisible();
  await expectCentralIconSvgs(page, ".comma-sidebar-icon, .comma-input-icon");

  // Tasks renders the real task-board surface; exercise both its status icons
  // and the shell icons instead of relying on the removed EmptyRoute marker.
  await page.getByRole("link", { name: "Tasks" }).click();

  await expect(page.getByTestId("tasks-route")).toBeVisible();
  await expectCentralIconSvgs(
    page,
    '.comma-sidebar-icon, [data-slot="task-board-column-icon"] svg'
  );
});

async function expectCentralIconSvgs(page: Page, selector: string) {
  const summary = await page.locator(selector).evaluateAll((svgs) => ({
    count: svgs.length,
    legacyViewBoxCount: svgs.filter(
      (svg) => svg.getAttribute("viewBox") === "0 0 20 20"
    ).length,
    viewBoxes: Array.from(new Set(svgs.map((svg) => svg.getAttribute("viewBox")))),
  }));

  expect(summary.count).toBeGreaterThan(0);
  expect(summary.legacyViewBoxCount).toBe(0);
  expect(summary.viewBoxes).toEqual(["0 0 24 24"]);
}
