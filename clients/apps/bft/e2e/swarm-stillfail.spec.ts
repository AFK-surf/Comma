import { expect, test, type Page } from "@playwright/test";
import { context, csrf, injectCsrfToken, ok, routeApi } from "./support";

const base = "/orgs/acme/projects/p-1/stillfail";
const api = "/orgs/acme/projects/p-1/stillfail";

const station = (id: string, name: string, connected: boolean) => ({
  id,
  name,
  workspace_id: `ws_${id}`,
  connected,
  connected_at: Date.UTC(2026, 10, 18, 6, 0),
});

const usage = (key: string, calls: number, cost: number) => ({
  key,
  calls,
  input: calls * 1_000,
  cache_read: 0,
  cache_write: 0,
  output: calls * 100,
  cost,
});

const hypershell = station("dev_sf1", "Hypershell · Tokyo", true);
const design = station("dev_sf2", "Design · Office Mac", false);
const byStation: Record<string, ReturnType<typeof usage>[]> = {
  dev_sf1: [usage("lin@example.com", 40, 3.5)],
  dev_sf2: [usage("wu@example.com", 12, 1.25)],
};

async function open(page: Page, role = "admin", initial = [hypershell, design]) {
  // The swarm's stations as the server holds them: a disconnect removes one.
  const stations = [...initial];
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    if (request.method === "GET" && request.path === api) {
      const device = new URLSearchParams(request.search).get("device_id");
      return ok({
        project: { id: "p-1", name: "Support Desk", role },
        days: 30,
        stations,
        usage: device
          ? byStation[device]
          : stations.flatMap((kept) => byStation[kept.id] ?? []),
      });
    }
    if (request.method === "DELETE" && request.path === `${api}/stations/dev_sf2`) {
      stations.splice(
        stations.findIndex((gone) => gone.id === "dev_sf2"),
        1
      );
      return ok({ notice: "The still.fail station was disconnected." });
    }
    return undefined;
  });
  await page.goto(base);
  await expect(
    page.getByRole("cell", { name: "Hypershell · Tokyo", exact: true })
  ).toBeVisible();
  return requests;
}

test("an admin disconnects one still.fail workspace and keeps the others", async ({
  page,
}) => {
  const requests = await open(page);
  // Its usage is the one shown when it goes.
  await page.getByRole("button", { name: "Workspace" }).click();
  await page.getByRole("option", { name: "Design · Office Mac" }).click();
  await expect(page.getByRole("table").nth(1)).not.toContainText("lin@example.com");

  await page.getByRole("button", { name: "Disconnect Design · Office Mac" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("The other stations stay connected.");
  await dialog.getByRole("button", { name: "Disconnect" }).click();

  await expect(
    page.getByText("The still.fail station was disconnected.")
  ).toBeVisible();
  const removed = requests.filter((request) => request.method === "DELETE");
  expect(removed.map((request) => [request.path, request.csrf])).toEqual([
    [`${api}/stations/dev_sf2`, csrf],
  ]);

  // The page is read again: one workspace left, so no picker and no "Remove all",
  // and the usage is that workspace's.
  await expect(
    page.getByRole("cell", { name: "Design · Office Mac", exact: true })
  ).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Workspace" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Remove all" })).toHaveCount(0);
  const left = page.getByRole("table").nth(1);
  await expect(left).toContainText("lin@example.com");
  await expect(left).not.toContainText("wu@example.com");
});

test("usage shows every workspace, or the one picked", async ({ page }) => {
  const requests = await open(page);
  const table = page.getByRole("table").nth(1);
  await expect(table).toContainText("lin@example.com");
  await expect(table).toContainText("wu@example.com");

  await page.getByRole("button", { name: "Workspace" }).click();
  await page.getByRole("option", { name: "Design · Office Mac" }).click();

  await expect(table).toContainText("wu@example.com");
  await expect(table).not.toContainText("lin@example.com");
  expect(requests.some((request) => request.search === "?device_id=dev_sf2")).toBe(
    true
  );
});

test("a member sees the workspaces without disconnecting; one workspace needs no picker", async ({
  page,
}) => {
  await open(page, "member", [hypershell]);
  await expect(page.getByRole("button", { name: /^Disconnect/ })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Workspace" })).toHaveCount(0);
});
