import { expect, test, type Page } from "@playwright/test";
import {
  context,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const person = (id: string, name: string) => ({
  user_id: id,
  name,
  email: `${id}@acme.test`,
  mobile: null,
  role: id === "user-1" ? "owner" : "member",
  joined_at: "2026-09-01T00:00:00Z",
  sso: false,
  sso_provider: null,
});

const membersPage = (people: ReturnType<typeof person>[]) => ({
  viewer: { user_id: "user-1", role: "owner", can_manage: true, can_grant_owner: true },
  members: people,
});

const mei = person("user-1", "Mei Chen");
const priya = person("u-priya", "Priya Raman");
const zed = person("u-zed", "Zed Newman");

const swarmRow = (id: string, name: string) => ({
  id,
  name,
  slug: id,
  salix_group_id: `grp1_acme_${id}`,
  status: "active",
  created_at: "2026-09-01T00:00:00Z",
});

/** A reply the test lets through when it is ready. */
function gate() {
  const { promise: opened, resolve: open } = Promise.withResolvers<void>();
  return { open: () => open(), opened };
}

const reads = (requests: RecordedRequest[], path: string) =>
  requests.filter((request) => request.method === "GET" && request.path === path)
    .length;

const sidebar = (page: Page) =>
  page.getByRole("navigation", { name: "Organization navigation" });

type Watched = Window & { bftShell?: Element | null; bftNavSkeletons?: number };

/**
 * Remembers the mounted shell and counts every time the sidebar skeleton
 * appears from now on. A full page load would also lose both.
 */
async function watchShell(page: Page) {
  await page.evaluate(() => {
    const watched = window as Watched;
    watched.bftShell = document.querySelector(".bft-shell");
    watched.bftNavSkeletons = 0;
    new MutationObserver(() => {
      if (document.querySelector(".bft-nav-skeleton")) {
        watched.bftNavSkeletons = (watched.bftNavSkeletons ?? 0) + 1;
      }
    }).observe(document.body, { childList: true, subtree: true });
  });
}

const shellState = (page: Page) =>
  page.evaluate(() => {
    const watched = window as Watched;
    return {
      sameShell:
        watched.bftShell !== undefined &&
        watched.bftShell === document.querySelector(".bft-shell"),
      navSkeletons: watched.bftNavSkeletons,
    };
  });

const heading = (page: Page, name: string) =>
  page.getByRole("heading", { level: 1, name });

test("moving between pages keeps one shell and reads the org context once", async ({
  page,
}) => {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    switch (request.path) {
      case "/orgs/acme/context":
        return ok(context);
      case "/orgs/acme/members":
        return ok(membersPage([mei, priya]));
      case "/orgs/acme/projects":
        return ok({
          viewer: { can_create: true },
          projects: [swarmRow("p-1", "Support Desk")],
          next_cursor: null,
        });
      default:
        return undefined;
    }
  });

  await page.goto("/orgs/acme/members");
  await expect(page.getByRole("cell", { name: /^Priya Raman/ })).toBeVisible();
  await watchShell(page);
  // The dev server's StrictMode may start (and drop) the first read twice.
  const firstLoad = reads(requests, "/orgs/acme/context");

  await sidebar(page).getByRole("link", { name: "Agent Swarms" }).click();
  await expect(heading(page, "Agent Swarms")).toBeVisible();
  await expect(page.getByRole("link", { name: "Support Desk" }).last()).toBeVisible();
  await sidebar(page).getByRole("link", { name: "Members" }).click();
  await expect(heading(page, "Members")).toBeVisible();
  await sidebar(page).getByRole("link", { name: "Agent Swarms" }).click();
  await expect(heading(page, "Agent Swarms")).toBeVisible();
  await sidebar(page).getByRole("link", { name: "Members" }).click();
  await expect(page.getByRole("cell", { name: /^Priya Raman/ })).toBeVisible();

  expect(reads(requests, "/orgs/acme/context")).toBe(firstLoad);
  expect(await shellState(page)).toEqual({ sameShell: true, navSkeletons: 0 });
});

test("a page opened again shows its last data at once and reads it again", async ({
  page,
}) => {
  const second = gate();
  let hold = false;
  await injectCsrfToken(page);
  const requests = await routeApi(page, async (request) => {
    switch (request.path) {
      case "/orgs/acme/context":
        return ok(context);
      case "/orgs/acme/members":
        if (!hold) return ok(membersPage([mei, priya]));
        await second.opened;
        return ok(membersPage([mei, priya, zed]));
      case "/orgs/acme/projects":
        return ok({ viewer: { can_create: true }, projects: [], next_cursor: null });
      default:
        return undefined;
    }
  });

  await page.goto("/orgs/acme/members");
  await expect(page.getByRole("cell", { name: /^Priya Raman/ })).toBeVisible();
  await sidebar(page).getByRole("link", { name: "Agent Swarms" }).click();
  await expect(heading(page, "Agent Swarms")).toBeVisible();
  const firstLoad = reads(requests, "/orgs/acme/members");
  hold = true;

  await sidebar(page).getByRole("link", { name: "Members" }).click();
  // The new read is still held: what shows is the cached list, no skeleton.
  await expect
    .poll(() => reads(requests, "/orgs/acme/members"))
    .toBeGreaterThan(firstLoad);
  await expect(page.getByRole("cell", { name: /^Priya Raman/ })).toBeVisible();
  await expect(page.locator(".bft-main .bft-skeleton")).toHaveCount(0);
  await expect(page.getByRole("cell", { name: /^Zed Newman/ })).toHaveCount(0);

  second.open();
  await expect(page.getByRole("cell", { name: /^Zed Newman/ })).toBeVisible();
});

test("after a write, the pages opened next and the sidebar show fresh data", async ({
  page,
}) => {
  let people = [mei, priya];
  let swarms = [swarmRow("p-1", "Support Desk")];
  const afterWrite = gate();
  let wrote = false;
  await injectCsrfToken(page);
  const requests = await routeApi(page, async (request) => {
    if (request.path === "/orgs/acme/context") {
      return ok({ ...context, projects: swarms.map(({ id, name }) => ({ id, name })) });
    }
    if (request.path === "/orgs/acme/members" && request.method === "GET") {
      if (wrote) await afterWrite.opened;
      return ok(membersPage(people));
    }
    if (request.path === "/orgs/acme/members/u-priya" && request.method === "DELETE") {
      people = [mei];
      wrote = true;
      return ok(membersPage(people));
    }
    if (request.path === "/orgs/acme/projects" && request.method === "GET") {
      return ok({ viewer: { can_create: true }, projects: swarms, next_cursor: null });
    }
    if (request.path === "/orgs/acme/projects" && request.method === "POST") {
      const created = swarmRow("p-2", "Billing");
      swarms = [...swarms, created];
      return { status: 201, body: { ok: true, data: created } };
    }
    return undefined;
  });

  await page.goto("/orgs/acme/members");
  await expect(page.getByRole("cell", { name: /^Priya Raman/ })).toBeVisible();
  await watchShell(page);
  const firstLoad = reads(requests, "/orgs/acme/context");
  await sidebar(page).getByRole("link", { name: "Agent Swarms" }).click();
  await expect(heading(page, "Agent Swarms")).toBeVisible();
  await sidebar(page).getByRole("link", { name: "Members" }).click();
  await expect(heading(page, "Members")).toBeVisible();

  await page.getByRole("button", { name: "Remove Priya Raman" }).click();
  const remove = page.getByRole("dialog", { name: "Remove member" });
  await remove.getByRole("button", { name: /Remove member/ }).click();
  await expect(remove).toBeHidden();
  await expect(
    page.getByRole("cell", { name: "Priya Raman", exact: true })
  ).toHaveCount(0);

  // Coming back after the write never shows the list from before it.
  await sidebar(page).getByRole("link", { name: "Agent Swarms" }).click();
  await expect(heading(page, "Agent Swarms")).toBeVisible();
  await sidebar(page).getByRole("link", { name: "Members" }).click();
  await expect(heading(page, "Members")).toBeVisible();
  await expect(page.getByRole("cell", { name: /^Priya Raman/ })).toHaveCount(0);
  afterWrite.open();
  await expect(page.getByRole("cell", { name: /^Mei Chen/ })).toBeVisible();
  await expect(page.getByRole("cell", { name: /^Priya Raman/ })).toHaveCount(0);

  // A new swarm appears in the kept sidebar: the shell reads its context again.
  await sidebar(page).getByRole("link", { name: "Agent Swarms" }).click();
  await page.getByRole("button", { name: "New Agent Swarm" }).click();
  const create = page.getByRole("dialog", { name: "New Agent Swarm" });
  await create.getByLabel("Name").fill("Billing");
  await create.getByRole("button", { name: "Create Agent Swarm" }).click();
  await expect(page).toHaveURL(/\/orgs\/acme\/projects\/p-2$/);
  await expect(sidebar(page).getByRole("link", { name: "Billing" })).toBeVisible();

  // One more read after each write, in place.
  expect(reads(requests, "/orgs/acme/context")).toBe(firstLoad + 2);
  expect(await shellState(page)).toEqual({ sameShell: true, navSkeletons: 0 });
});

test("a failed context re-read after a write keeps the page and its open dialog", async ({
  page,
}) => {
  let people = [mei, priya];
  let wrote = false;
  const reread = gate();
  await injectCsrfToken(page);
  await routeApi(page, async (request) => {
    if (request.path === "/orgs/acme/context") {
      if (!wrote) return ok(context);
      await reread.opened;
      return { status: 503, body: { ok: false, error: { code: "unavailable" } } };
    }
    if (request.path === "/orgs/acme/members" && request.method === "GET")
      return ok(membersPage(people));
    if (request.path === "/orgs/acme/members/u-priya" && request.method === "DELETE") {
      people = [mei];
      wrote = true;
      return ok(membersPage(people));
    }
    return undefined;
  });

  await page.goto("/orgs/acme/members");
  await page.getByRole("button", { name: "Remove Priya Raman" }).click();
  const remove = page.getByRole("dialog", { name: "Remove member" });
  await remove.getByRole("button", { name: /Remove member/ }).click();
  await expect(remove).toBeHidden();

  // The context re-read is still held: open a dialog and type, then let it fail.
  await page.getByRole("button", { name: "Invite member" }).click();
  const invite = page.getByRole("dialog", { name: "Invite member" });
  await invite.getByRole("textbox", { name: "Email" }).fill("new@acme.test");
  reread.open();
  await page.waitForTimeout(300);

  await expect(invite.getByRole("textbox", { name: "Email" })).toHaveValue(
    "new@acme.test"
  );
  await expect(page.getByRole("cell", { name: /^Mei Chen/ })).toBeVisible();
  await expect(page.getByText("Could not load this page")).toHaveCount(0);
  await expect(sidebar(page).getByRole("link", { name: "Members" })).toBeVisible();
});

test("a failed write does not re-read the context", async ({ page }) => {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    if (request.path === "/orgs/acme/members" && request.method === "GET")
      return ok(membersPage([mei, priya]));
    if (request.method === "DELETE")
      return {
        status: 500,
        body: { ok: false, error: { code: "boom", message: "Removal failed." } },
      };
    return undefined;
  });

  await page.goto("/orgs/acme/members");
  await expect(page.getByRole("cell", { name: /^Priya Raman/ })).toBeVisible();
  const firstLoad = reads(requests, "/orgs/acme/context");
  await page.getByRole("button", { name: "Remove Priya Raman" }).click();
  const remove = page.getByRole("dialog", { name: "Remove member" });
  await remove.getByRole("button", { name: /Remove member/ }).click();
  await expect(remove.getByText("Removal failed.")).toBeVisible();
  await page.waitForTimeout(300);
  expect(reads(requests, "/orgs/acme/context")).toBe(firstLoad);
});

test("a page found missing is checked again after back and forward", async ({
  page,
}) => {
  let missing = true;
  await injectCsrfToken(page);
  await routeApi(page, (request) => {
    switch (request.path) {
      case "/orgs/acme/context":
        return ok(context);
      case "/orgs/acme/members":
        return missing
          ? { status: 404, body: { ok: false, error: { code: "org_not_found" } } }
          : ok(membersPage([mei, priya]));
      case "/orgs/acme/projects":
        return ok({ viewer: { can_create: true }, projects: [], next_cursor: null });
      default:
        return undefined;
    }
  });

  await page.goto("/orgs/acme/projects");
  await expect(heading(page, "Agent Swarms")).toBeVisible();
  await sidebar(page).getByRole("link", { name: "Members" }).click();
  await expect(page.getByText("Organization not found")).toBeVisible();

  await page.goBack();
  await expect(heading(page, "Agent Swarms")).toBeVisible();
  missing = false;
  await page.goForward();
  await expect(page.getByRole("cell", { name: /^Priya Raman/ })).toBeVisible();
});
