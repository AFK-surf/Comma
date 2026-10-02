import { expect, test, type Page } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const policy = (overrides: Record<string, unknown> = {}) => ({
  mode: "audit",
  language: "zh",
  audience_modes: ["space", "members"],
  connects: [
    {
      connect_id: "cnx1",
      provider: "slack",
      name: "Acme",
      available: true,
      truncated: false,
      scopes: [
        {
          scope_id: "C_LEGAL",
          kind: "room",
          display_name: "legal",
          observed_at: "2026-09-08T00:00:00Z",
          tags: [],
          audience_mode: "space",
          sealed: false,
          classified: false,
        },
      ],
      clearances: [{ tag: "counsel", principals: ["provider_user|cnx1|U01ABC"] }],
      principals: [{ id: "U_GUEST", observed: "external", override: "internal" }],
    },
    {
      connect_id: "cnx2",
      provider: "feishu",
      name: "Broken",
      available: false,
      truncated: false,
      scopes: [],
      clearances: [],
      principals: [],
    },
  ],
  ...overrides,
});

async function openPolicy(
  page: Page,
  write: (request: RecordedRequest) => { status: number; body: unknown } = () =>
    ok(policy())
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    if (request.path === "/orgs/acme/data-policy/p-1" && request.method === "GET")
      return ok(policy());
    return write(request);
  });
  await page.goto("/orgs/acme/information-flow");
  await expect(
    page.getByRole("heading", { level: 1, name: "Data policy" })
  ).toBeVisible();
  return requests;
}

const writes = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.method !== "GET");

test("shows each workspace's conversations, clearances and placements", async ({
  page,
}) => {
  await openPolicy(page);

  await expect(
    page.getByText("Decisions are being recorded and nothing is being refused.", {
      exact: false,
    })
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: /legal Private channel/ })
  ).toContainText("Default");
  // The clearance shows the person; the encoded key stays out of sight.
  await expect(page.getByText("U01ABC", { exact: true })).toBeVisible();
  await expect(page.getByText("provider_user|cnx1|U01ABC")).toHaveCount(0);
  await expect(page.getByText("Provider says: outside")).toBeVisible();
  // One unavailable workspace degrades one section.
  await expect(page.getByRole("region", { name: "Broken" })).toContainText(
    "could not be read just now"
  );
});

test("mode and language are written with the page's CSRF token", async ({ page }) => {
  const requests = await openPolicy(page, (request) =>
    ok(policy({ mode: (request.body as { mode?: string }).mode ?? "audit" }))
  );

  await page
    .getByRole("button", { name: /When the assistant would carry something across/ })
    .click();
  await page
    .getByRole("option", { name: "Enforce: refuse what does not belong" })
    .click();
  await expect(
    page.getByText("The assistant is refusing to carry information")
  ).toBeVisible();
  await page
    .getByRole("button", { name: /Language the assistant explains a refusal in/ })
    .click();
  await page.getByRole("option", { name: "English" }).click();

  expect(writes(requests)).toMatchObject([
    {
      method: "PATCH",
      path: "/orgs/acme/data-policy/p-1",
      csrf,
      body: { mode: "enforce" },
    },
    {
      method: "PATCH",
      path: "/orgs/acme/data-policy/p-1",
      csrf,
      body: { language: "en" },
    },
  ]);
});

test("classifies a conversation, grants and withdraws a clearance, and clears a placement", async ({
  page,
}) => {
  const requests = await openPolicy(page);

  await page.getByRole("button", { name: /legal Private channel/ }).click();
  const classify = page.getByRole("dialog", { name: "Classify legal" });
  await classify.getByLabel("Tags").fill("counsel, board, ");
  await classify.getByRole("button", { name: /Audience/ }).click();
  await page.getByRole("option", { name: "Only this conversation's members" }).click();
  await classify.getByRole("button", { name: /Leaving this conversation/ }).click();
  await page
    .getByRole("option", { name: "Sealed: never leaves, even confirmed" })
    .click();
  await classify.getByRole("button", { name: "Save" }).click();
  await expect(classify).toHaveCount(0);

  await page.getByRole("button", { name: "Grant clearance" }).first().click();
  const grant = page.getByRole("dialog", { name: "Grant clearance" });
  await grant.getByLabel("Tag").fill("board");
  await grant.getByLabel("Provider user id").fill("U02XYZ");
  await grant.getByRole("button", { name: "Grant clearance" }).click();
  await expect(grant).toHaveCount(0);

  await page.getByRole("button", { name: "Withdraw U01ABC from counsel" }).click();
  await page.getByRole("button", { name: "Placement of U_GUEST" }).click();
  await page.getByRole("option", { name: "Use the provider's answer" }).click();

  await expect.poll(() => writes(requests).length).toBe(4);
  expect(writes(requests)).toMatchObject([
    {
      method: "PUT",
      path: "/orgs/acme/data-policy/p-1/connects/cnx1/scopes/C_LEGAL",
      csrf,
      body: { tags: ["counsel", "board"], audience_mode: "members", sealed: true },
    },
    {
      method: "POST",
      path: "/orgs/acme/data-policy/p-1/connects/cnx1/clearances",
      body: { tag: "board", user: "U02XYZ" },
    },
    {
      method: "DELETE",
      path: "/orgs/acme/data-policy/p-1/connects/cnx1/clearances",
      body: { tag: "counsel", principal: "provider_user|cnx1|U01ABC" },
    },
    {
      method: "PUT",
      path: "/orgs/acme/data-policy/p-1/connects/cnx1/placements/U_GUEST",
      body: { placement: "" },
    },
  ]);
});

test("a dot tag is withdrawn through the clearances route", async ({ page }) => {
  const base = policy();
  const dotted = {
    ...base,
    connects: base.connects.map((connect, index) =>
      index === 0
        ? {
            ...connect,
            clearances: [{ tag: "..", principals: ["provider_user|cnx1|U01ABC"] }],
          }
        : connect
    ),
  };
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    return ok(dotted);
  });
  await page.goto("/orgs/acme/information-flow");
  await page.getByRole("button", { name: "Withdraw U01ABC from .." }).click();
  await expect.poll(() => writes(requests).length).toBe(1);
  expect(writes(requests)[0]).toMatchObject({
    method: "DELETE",
    path: "/orgs/acme/data-policy/p-1/connects/cnx1/clearances",
    body: { tag: "..", principal: "provider_user|cnx1|U01ABC" },
  });
});

test("a fresh read replaces a write's copy after switching swarms", async ({
  page,
}) => {
  await injectCsrfToken(page);
  let reads = 0;
  await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context")
      return ok({
        ...context,
        projects: [
          { id: "p-1", name: "Support Desk" },
          { id: "p-2", name: "Sales Assistant" },
        ],
      });
    if (request.path === "/orgs/acme/data-policy/p-1" && request.method === "GET")
      // Someone else turns checking off after this page's first read.
      return ok(policy({ mode: (reads += 1) === 1 ? "audit" : "off" }));
    if (request.path === "/orgs/acme/data-policy/p-2") return ok(policy());
    return ok(policy({ mode: "enforce" }));
  });
  await page.goto("/orgs/acme/information-flow");

  await page
    .getByRole("button", { name: /When the assistant would carry something across/ })
    .click();
  await page
    .getByRole("option", { name: "Enforce: refuse what does not belong" })
    .click();
  await expect(
    page.getByText("The assistant is refusing to carry information")
  ).toBeVisible();

  await page.getByRole("button", { name: "Agent Swarm" }).click();
  await page.getByRole("option", { name: "Sales Assistant" }).click();
  await expect(page.getByText("Decisions are being recorded")).toBeVisible();
  await page.getByRole("button", { name: "Agent Swarm" }).click();
  await page.getByRole("option", { name: "Support Desk" }).click();
  await expect(page.getByText("Nothing on this page has any effect")).toBeVisible();
  await expect(
    page.getByText("The assistant is refusing to carry information")
  ).toHaveCount(0);
});

test("a refused change shows the server's message", async ({ page }) => {
  await openPolicy(page, () => ({
    status: 422,
    body: {
      ok: false,
      error: {
        code: "invalid_data_policy",
        message: "A tag cannot be empty or contain the | character.",
      },
    },
  }));
  await page.getByRole("button", { name: "Grant clearance" }).first().click();
  const grant = page.getByRole("dialog", { name: "Grant clearance" });
  await grant.getByLabel("Tag").fill("a|b");
  await grant.getByLabel("Provider user id").fill("U1");
  await grant.getByRole("button", { name: "Grant clearance" }).click();
  await expect(
    grant.getByText("A tag cannot be empty or contain the | character.")
  ).toBeVisible();
});

test("members see the admins-only state and nothing is requested", async ({ page }) => {
  const requests = await routeApi(page, (request) =>
    request.path === "/orgs/acme/context"
      ? ok({
          ...context,
          org: { ...context.org, role: "member" },
          capabilities: { ...context.capabilities, information_flow: false },
        })
      : undefined
  );
  await page.goto("/orgs/acme/information-flow");
  await expect(page.getByRole("heading", { name: "Admins only" })).toBeVisible();
  expect(
    requests.filter((request) => request.path.includes("data-policy"))
  ).toHaveLength(0);
});

test("fits a 900px window without sideways scrolling", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 700 });
  await openPolicy(page);
  await expect(page.getByText("Provider says: outside")).toBeVisible();
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth
  );
  expect(overflow).toBeLessThanOrEqual(0);
});
