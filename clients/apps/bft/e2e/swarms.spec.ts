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

type Target = { kind: string; id: string; name: string };

const deptSwarm = (
  id: string,
  name: string,
  department: { id: string; name: string } | null,
  extra: Target[] = []
) => ({
  id,
  name,
  slug: id.replace(/^p-/, ""),
  salix_group_id: `grp1_acme_${id.replace(/^p-/, "")}`,
  status: "active",
  created_at: "2026-09-01T00:00:00Z",
  department_id: department?.id ?? null,
  department_name: department?.name ?? null,
  extra_targets: extra,
});

const eng = { id: "d-eng", name: "Engineering" };
const prod = { id: "d-prod", name: "Product" };

/** An org with Engineering, Product, an empty Legal department and an unassigned Swarm. */
const departmentPage = (deptTargets: Target[], query = "") => {
  const projects = [
    deptSwarm("p-core", "Core Services", eng),
    deptSwarm("p-web", "Product Web", prod),
    deptSwarm("p-support", "Support Desk", null, [
      { kind: "project", id: "p-core", name: "Core Services" },
    ]),
  ].filter((row) =>
    [row.name, row.department_name ?? ""].some((value) =>
      value.toLowerCase().includes(query.toLowerCase())
    )
  );
  const counts: Record<string, number> = {};
  for (const row of projects) {
    if (row.department_id)
      counts[row.department_id] = (counts[row.department_id] ?? 0) + 1;
  }
  return {
    viewer: { can_create: true, can_manage_departments: true },
    departments: [
      { ...eng, targets: deptTargets },
      { ...prod, targets: [] },
      { id: "d-legal", name: "Legal", targets: [] },
    ],
    catalog_swarms: [
      { id: "p-core", name: "Core Services", department_id: "d-eng" },
      { id: "p-web", name: "Product Web", department_id: "d-prod" },
      { id: "p-support", name: "Support Desk", department_id: null },
    ],
    projects,
    next_cursor: null,
    department_counts: counts,
    unassigned_count: projects.filter((row) => !row.department_id).length,
  };
};

async function openDepartments(
  page: Page,
  onPatch?: (request: RecordedRequest) => void
) {
  await injectCsrfToken(page);
  let deptTargets: Target[] = [{ kind: "self", id: "d-eng", name: "Engineering" }];
  return routeApi(page, (request) => {
    const query = new URLSearchParams(request.search).get("query") ?? "";
    if (request.path === "/orgs/acme/context") return ok(context);
    if (request.path === "/orgs/acme/projects" && request.method === "GET") {
      return ok(departmentPage(deptTargets, query));
    }
    if (request.path === "/orgs/acme/departments/d-eng" && request.method === "PATCH") {
      onPatch?.(request);
      const body = request.body as { targets: { kind: string; id?: string }[] };
      deptTargets = body.targets.map((target) =>
        target.kind === "all_departments"
          ? { kind: "all_departments", id: "org-acme", name: "All departments" }
          : target.kind === "self"
            ? { kind: "self", id: "d-eng", name: "Engineering" }
            : {
                kind: target.kind,
                id: target.id ?? "",
                name:
                  target.id === "d-prod"
                    ? "Product"
                    : target.id === "p-support"
                      ? "Support Desk"
                      : (target.id ?? ""),
              }
      );
      return ok(departmentPage(deptTargets, query));
    }
    return undefined;
  });
}

test("groups Agent Swarms by department and edits department cross-Swarm search grants", async ({
  page,
}) => {
  const requests = await openDepartments(page);

  await page.goto("/orgs/acme/projects");
  await expect(page.getByRole("cell", { name: "This department" })).toBeVisible();
  await expect(page.getByRole("cell", { name: "+ Core Services" })).toBeVisible();

  await page.getByRole("button", { name: "Edit department Engineering" }).click();
  const dialog = page.getByRole("dialog", { name: "Edit Engineering" });
  await dialog
    .getByRole("checkbox", { name: "Select all of Product" })
    .check({ force: true });
  await dialog.getByRole("button", { name: "Save" }).click();

  await expect(
    page.getByRole("cell", { name: "This department, Product" })
  ).toBeVisible();
  expect(requests.filter((r) => r.method === "PATCH").map((r) => r.body)).toEqual([
    {
      name: "Engineering",
      targets: [{ kind: "self" }, { kind: "department", id: "d-prod" }],
    },
  ]);
});

/** Per table row: the columns its visible cells span and its right edge. */
const tableColumns = (page: Page) =>
  page.locator("table.bft-swarms").evaluate((table) =>
    [...table.querySelectorAll("tr")].map((row) => {
      const cells = [...row.children].filter(
        (cell) => getComputedStyle(cell).display !== "none"
      ) as HTMLTableCellElement[];
      const last = cells.at(-1)?.getBoundingClientRect();
      return {
        columns: cells.reduce((sum, cell) => sum + cell.colSpan, 0),
        right: Math.round(last?.right ?? 0),
      };
    })
  );

test("department rows keep the table's columns at every width", async ({ page }) => {
  await openDepartments(page);
  await page.goto("/orgs/acme/projects");
  await expect(
    page.getByRole("button", { name: "Edit department Engineering" })
  ).toBeVisible();

  // Each width hides more columns (runtime id, search, created, slug); every
  // row keeps the header's columns and right edge.
  const seen: number[] = [];
  for (const width of [1440, 760, 580, 440]) {
    await page.setViewportSize({ width, height: 900 });
    const rows = await tableColumns(page);
    expect(rows.length).toBeGreaterThan(4);
    for (const row of rows) expect(row).toEqual(rows[0]);
    seen.push(rows[0]?.columns ?? 0);
    await expect(
      page.getByRole("button", { name: "Edit department Engineering" })
    ).toBeVisible();
  }
  expect(seen[0]).toBe(6);
  expect(seen.toSorted((a, b) => b - a)).toEqual(seen);
  expect(seen.at(-1)).toBeLessThan(5);
});

test("a department change keeps the list's filter", async ({ page }) => {
  const requests = await openDepartments(page);
  await page.goto("/orgs/acme/projects");
  await page.getByRole("searchbox", { name: "Filter Agent Swarms" }).fill("Core");
  await expect(page.getByRole("link", { name: "Product Web" })).toBeHidden();

  await page.getByRole("button", { name: "Edit department Engineering" }).click();
  const dialog = page.getByRole("dialog", { name: "Edit Engineering" });
  await dialog.getByRole("button", { name: "Save" }).click();
  await expect(dialog).toBeHidden();

  const patch = requests.find((r) => r.method === "PATCH");
  expect(new URLSearchParams(patch?.search).get("query")).toBe("Core");
  await expect(page.getByRole("link", { name: "Core Services" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Product Web" })).toBeHidden();
  await expect(
    page.getByRole("searchbox", { name: "Filter Agent Swarms" })
  ).toHaveValue("Core");
});

test("the search picker lines up group names and selects every unassigned Swarm", async ({
  page,
}) => {
  const requests = await openDepartments(page);
  await page.goto("/orgs/acme/projects");
  await page.getByRole("button", { name: "Edit department Engineering" }).click();
  const dialog = page.getByRole("dialog", { name: "Edit Engineering" });

  const titleLeft = (name: string) =>
    dialog
      .locator(".bft-model-group-title", { hasText: new RegExp(`^${name}$`) })
      .evaluate((node) => Math.round(node.getBoundingClientRect().left));
  const product = await titleLeft("Product");
  expect(await titleLeft("Legal")).toBe(product);
  expect(await titleLeft("Unassigned")).toBe(product);

  await dialog
    .getByRole("checkbox", { name: "Select all of Unassigned" })
    .check({ force: true });
  await dialog.getByRole("button", { name: "Save" }).click();
  await expect(dialog).toBeHidden();

  expect(requests.filter((r) => r.method === "PATCH").map((r) => r.body)).toEqual([
    {
      name: "Engineering",
      targets: [{ kind: "self" }, { kind: "project", id: "p-support" }],
    },
  ]);
});

test("All departments locks department groups, keeps unassigned Swarms editable, and saves", async ({
  page,
}) => {
  const requests = await openDepartments(page);
  await page.goto("/orgs/acme/projects");
  await page.getByRole("button", { name: "Edit department Engineering" }).click();
  const dialog = page.getByRole("dialog", { name: "Edit Engineering" });

  // Select All departments: This department and peer departments become checked & disabled
  // with Auto-included badge; Unassigned remains independently selectable.
  await dialog
    .getByRole("checkbox", { name: /All departments/ })
    .check({ force: true });
  await expect(dialog.getByRole("checkbox", { name: /This department/ })).toBeChecked();
  await expect(
    dialog.getByRole("checkbox", { name: /This department/ })
  ).toBeDisabled();
  await expect(
    dialog.getByRole("checkbox", { name: "Select all of Product" })
  ).toBeChecked();
  await expect(
    dialog.getByRole("checkbox", { name: "Select all of Product" })
  ).toBeDisabled();
  await expect(dialog.getByText("Auto-included")).toHaveCount(2);

  await dialog
    .getByRole("checkbox", { name: "Select all of Unassigned" })
    .check({ force: true });

  // Unchecking All departments unlocks departments while preserving the unassigned selection.
  await dialog
    .getByRole("checkbox", { name: /All departments/ })
    .uncheck({ force: true });
  await expect(dialog.getByRole("checkbox", { name: /This department/ })).toBeEnabled();
  await expect(
    dialog.getByRole("checkbox", { name: "Select all of Product" })
  ).toBeEnabled();
  await expect(
    dialog.getByRole("checkbox", { name: "Select all of Unassigned" })
  ).toBeChecked();

  // Re-check All departments and save.
  await dialog
    .getByRole("checkbox", { name: /All departments/ })
    .check({ force: true });
  await dialog.getByRole("button", { name: "Save" }).click();
  await expect(dialog).toBeHidden();

  await expect(
    page.getByRole("cell", { name: "All departments, Support Desk" })
  ).toBeVisible();
  expect(requests.filter((r) => r.method === "PATCH").map((r) => r.body)).toEqual([
    {
      name: "Engineering",
      targets: [{ kind: "all_departments" }, { kind: "project", id: "p-support" }],
    },
  ]);
});
