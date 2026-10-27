import { expect, test } from "../../../../e2e/app-shell/support/page";
import { useWebApp } from "../../../../e2e/app-shell/support/web-app";

const app = useWebApp(
  {},
  {
    responses: () => ({
      "/v1/comma/workspaces/other/apps/a1": {
        body: {
          id: "a1",
          slug: "linked-app",
          workspace_id: "other",
          name: "Linked app",
          visibility: "workspace",
          status: "active",
          live_version: null,
          latest_version: null,
          storage: [],
          has_backend: false,
          versions: [],
        },
      },
      "/v1/comma/workspaces/other/apps/a1/link": { body: { link: null } },
      "/v1/comma/workspaces/gone/apps/deleted": {
        status: 404,
        body: { error: "not_found" },
      },
    }),
  }
);

test("a web App link reaches its workspace and opens the App panel", async ({
  page,
}) => {
  await app.open(page);
  // Exercise the document's navigation boundary, including target=_blank and the full hash URL.
  await page.evaluate(() => {
    const anchor = document.createElement("a");
    anchor.href = "https://app-staging.comma.surf/#/apps/other/a1/run";
    anchor.target = "_blank";
    document.body.append(anchor);
    anchor.click();
    anchor.remove();
  });
  await expect(page.getByRole("tab", { name: "Linked app" })).toBeVisible();
  const requests = await app.stub().call("requests");
  expect(requests).toContain("GET /v1/comma/workspaces/other/apps/a1");
});

test("a link to an unavailable workspace or deleted App shows a message", async ({
  page,
}) => {
  await app.open(page);
  await page.evaluate(() => {
    const anchor = document.createElement("a");
    anchor.href = "https://app.comma.surf/#/apps/gone/deleted/run";
    document.body.append(anchor);
    anchor.click();
    anchor.remove();
  });
  await expect(
    page.getByText("This app is not available", { exact: true })
  ).toBeVisible();
  const requests = await app.stub().call("requests");
  expect(requests).toContain("GET /v1/comma/workspaces/gone/apps/deleted");
});

test("an incomplete run address at startup returns to Apps with an error", async ({
  page,
}) => {
  await app.open(page, "/#/apps/gone//run");
  await expect(
    page.getByText("This app is not available", { exact: true })
  ).toBeVisible();
  await expect(page.getByRole("region", { name: "Content" })).toBeVisible();
});
