import { expect, test, type Page } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const swarm = (index: number) => ({
  id: `p-${index}`,
  name: `Swarm ${String(index).padStart(2, "0")}`,
  slug: `swarm-${index}`,
  salix_group_id: `grp1_acme_${index}`,
  status: index === 2 ? "provisioning" : "active",
  created_at: "2026-09-01T00:00:00Z",
});

const all = Array.from({ length: 60 }, (_, index) => swarm(index + 1));

async function openSwarms(
  page: Page,
  options: {
    canCreate?: boolean;
    create?: (request: RecordedRequest) => { status: number; body: unknown };
  } = {}
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    if (request.path === "/orgs/acme/projects" && request.method === "GET") {
      const params = new URLSearchParams(request.search);
      const query = params.get("query") ?? "";
      const matching = all.filter((row) => row.name.includes(query));
      const start = Number(params.get("cursor") ?? 0);
      return ok({
        viewer: { can_create: options.canCreate ?? true },
        projects: matching.slice(start, start + 50),
        next_cursor: start + 50 < matching.length ? String(start + 50) : null,
      });
    }
    if (request.path === "/orgs/acme/projects") return options.create?.(request);
    return undefined;
  });
  await page.goto("/orgs/acme/projects");
  await expect(
    page.getByRole("heading", { level: 1, name: "Agent Swarms" })
  ).toBeVisible();
  return requests;
}

test("lists Agent Swarms, loads more on scroll and filters on the server", async ({
  page,
}) => {
  const requests = await openSwarms(page);

  await expect(page.getByRole("link", { name: "Swarm 01" })).toHaveAttribute(
    "href",
    "/orgs/acme/projects/p-1"
  );
  await expect(
    page.getByRole("cell", { name: "grp1_acme_1", exact: true })
  ).toBeVisible();
  await expect(page.getByText("Setting up")).toBeVisible();
  await expect(page.getByRole("link", { name: "Swarm 60" })).toHaveCount(0);

  await page.getByRole("link", { name: "Swarm 50" }).scrollIntoViewIfNeeded();
  await expect(page.getByRole("link", { name: "Swarm 60" })).toBeVisible();
  expect(requests.map((request) => request.search)).toContain("?cursor=50");

  await page.getByRole("searchbox", { name: "Filter Agent Swarms" }).fill("Swarm 3");
  await expect(page.getByRole("link", { name: "Swarm 30" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Swarm 01" })).toHaveCount(0);
  expect(requests.at(-1)?.search).toBe("?query=Swarm+3");

  await page.getByRole("searchbox", { name: "Filter Agent Swarms" }).fill("nothing");
  await expect(page.getByText("No Agent Swarm matches this filter.")).toBeVisible();
});

test("creates an Agent Swarm, shows field errors inline and opens the new swarm", async ({
  page,
}) => {
  let attempts = 0;
  const requests = await openSwarms(page, {
    create: () => {
      attempts += 1;
      return attempts === 1
        ? {
            status: 422,
            body: {
              ok: false,
              error: {
                code: "invalid_project",
                message: "Couldn't create the Agent Swarm.",
                details: { fields: { slug: ["has already been taken"] } },
              },
            },
          }
        : { status: 201, body: { ok: true, data: { ...swarm(61), name: "Billing" } } };
    },
  });

  await page.getByRole("button", { name: "New Agent Swarm" }).click();
  const dialog = page.getByRole("dialog", { name: "New Agent Swarm" });

  await dialog.getByRole("button", { name: "Create Agent Swarm" }).click();
  await expect(dialog.getByText("Enter a name.")).toBeVisible();

  await dialog.getByLabel("Name").fill("Billing Service");
  await expect(dialog.getByLabel("Slug")).toHaveValue("billing-service");
  await dialog.getByRole("button", { name: "Create Agent Swarm" }).click();
  await expect(dialog.getByText("has already been taken")).toBeVisible();

  await dialog.getByLabel("Slug").fill("billing");
  await dialog.getByRole("button", { name: "Create Agent Swarm" }).click();
  await expect(page).toHaveURL(/\/orgs\/acme\/projects\/p-61$/);

  const writes = requests.filter((request) => request.method === "POST");
  expect(writes.map((request) => request.body)).toEqual([
    { name: "Billing Service", slug: "billing-service" },
    { name: "Billing Service", slug: "billing" },
  ]);
  expect(writes.every((request) => request.csrf === csrf)).toBe(true);
});

test("a member at their limit is not offered a new Agent Swarm", async ({ page }) => {
  await openSwarms(page, { canCreate: false });

  await expect(page.getByRole("link", { name: "Swarm 01" })).toBeVisible();
  await expect(page.getByRole("button", { name: "New Agent Swarm" })).toHaveCount(0);
});

test("fits a 900px window without sideways scrolling", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 700 });
  await openSwarms(page);
  await expect(page.getByRole("link", { name: "Swarm 01" })).toBeVisible();

  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth
  );
  expect(overflow).toBeLessThanOrEqual(0);
});
