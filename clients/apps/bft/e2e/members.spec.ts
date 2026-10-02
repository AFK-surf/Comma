import { expect, test, type Page } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

type Role = "owner" | "admin" | "member";

const person = (id: string, name: string | null, role: Role, extra = {}) => ({
  user_id: id,
  name,
  email: `${id}@acme.test`,
  mobile: null,
  role,
  joined_at: "2026-09-01T00:00:00Z",
  sso: false,
  sso_provider: null,
  ...extra,
});

const people = [
  person("user-1", "Mei Chen", "owner"),
  person("u-owner", "Olga Owner", "owner"),
  person("u-admin", "Ada Admin", "admin"),
  person("u-priya", "Priya Raman", "member"),
  person("u-phone", "Feishu Phone User", "member", {
    email: null,
    mobile: "+10000000001",
    sso: true,
    sso_provider: "feishu",
  }),
];

const viewer = (role: Role, userId = "user-1") => ({
  user_id: userId,
  role,
  can_manage: role !== "member",
  can_grant_owner: role === "owner",
});

const membersPage = (role: Role, members = people, userId = "user-1") => ({
  viewer: viewer(role, userId),
  members,
});

async function openMembers(
  page: Page,
  role: Role,
  write?: (
    request: RecordedRequest
  ) => { status: number; body: unknown } | { status: number; text: string },
  userId = "user-1"
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    if (request.path === "/orgs/acme/members" && request.method === "GET") {
      return ok(membersPage(role, people, userId));
    }
    return write?.(request);
  });
  await page.goto("/orgs/acme/members");
  await expect(page.getByRole("heading", { level: 1, name: "Members" })).toBeVisible();
  await expect(page.getByRole("cell", { name: /^Priya Raman/ })).toBeVisible();
  return requests;
}

const writes = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.method !== "GET");

test("a role change is confirmed first and sends the CSRF token", async ({ page }) => {
  const requests = await openMembers(page, "owner", () =>
    ok(
      membersPage(
        "owner",
        people.map((member) =>
          member.user_id === "u-priya" ? { ...member, role: "admin" as Role } : member
        )
      )
    )
  );

  await page.getByRole("button", { name: "Role of Priya Raman" }).click();
  await page.getByRole("option", { name: /^Admin/ }).click();

  const dialog = page.getByRole("dialog", { name: "Change role" });
  await expect(dialog).toContainText(
    "Priya Raman will become Admin (currently Member)."
  );
  expect(writes(requests)).toEqual([]);

  await dialog.getByRole("button", { name: /Change role/ }).click();
  await expect(dialog).toBeHidden();
  expect(writes(requests)).toEqual([
    {
      method: "PATCH",
      path: "/orgs/acme/members/u-priya",
      search: "",
      csrf,
      body: { role: "admin" },
    },
  ]);
  // The returned list is what renders.
  await expect(page.getByRole("button", { name: "Role of Priya Raman" })).toContainText(
    "Admin"
  );
});

test("cancelling a role change sends nothing", async ({ page }) => {
  const requests = await openMembers(page, "owner");
  await page.getByRole("button", { name: "Role of Ada Admin" }).click();
  await page.getByRole("option", { name: /^Owner/ }).click();
  const dialog = page.getByRole("dialog", { name: "Change role" });
  await expect(dialog).toContainText("Ada Admin will become Owner");
  await dialog.getByRole("button", { name: /Cancel/ }).click();
  await expect(dialog).toBeHidden();
  expect(writes(requests)).toEqual([]);
  await expect(page.getByRole("button", { name: "Role of Ada Admin" })).toContainText(
    "Admin"
  );
});

test("removal is confirmed first and the server's refusal is shown", async ({
  page,
}) => {
  const requests = await openMembers(page, "owner", (request) =>
    request.path === "/orgs/acme/members/u-owner"
      ? {
          status: 409,
          body: {
            ok: false,
            error: {
              code: "last_owner",
              message: "Can't remove the last owner.",
              details: {},
            },
          },
        }
      : ok(
          membersPage(
            "owner",
            people.filter((member) => member.user_id !== "u-priya")
          )
        )
  );

  await page.getByRole("button", { name: "Remove Priya Raman" }).click();
  const dialog = page.getByRole("dialog", { name: "Remove member" });
  await expect(dialog).toContainText("Priya Raman will lose access to Acme Robotics.");
  expect(writes(requests)).toEqual([]);
  await dialog.getByRole("button", { name: /Remove member/ }).click();
  await expect(dialog).toBeHidden();
  await expect(
    page.getByRole("cell", { name: "Priya Raman", exact: true })
  ).toHaveCount(0);

  await page.getByRole("button", { name: "Remove Olga Owner" }).click();
  await page
    .getByRole("dialog")
    .getByRole("button", { name: /Remove member/ })
    .click();
  await expect(page.getByRole("dialog").getByRole("alert")).toHaveText(
    "Can't remove the last owner."
  );

  expect(
    writes(requests).map((request) => [request.method, request.path, request.csrf])
  ).toEqual([
    ["DELETE", "/orgs/acme/members/u-priya", csrf],
    ["DELETE", "/orgs/acme/members/u-owner", csrf],
  ]);
});

test("an admin is never offered the owner role", async ({ page }) => {
  await openMembers(page, "admin", undefined, "u-admin");

  // Owners are not editable by an admin, nor is the admin's own row.
  await expect(page.getByRole("button", { name: "Role of Olga Owner" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Remove Olga Owner" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Role of Ada Admin" })).toHaveCount(0);

  await page.getByRole("button", { name: "Role of Priya Raman" }).click();
  await expect(page.getByRole("option")).toHaveText([/^Admin/, /^Member/]);
  await page.keyboard.press("Escape");

  await page.getByRole("button", { name: "Invite member" }).click();
  const dialog = page.getByRole("dialog", { name: "Invite member" });
  await dialog.getByRole("button", { name: /Role/ }).click();
  await expect(page.getByRole("option")).toHaveText([/^Admin/, /^Member/]);
});

test("an invite sends email and role; a refused token asks for a reload", async ({
  page,
}) => {
  let refuse = true;
  const requests = await openMembers(page, "owner", () => {
    if (refuse) return { status: 403, text: "Invalid CSRF token" };
    return ok(membersPage("owner", [...people, person("u-new", null, "admin")]));
  });

  await page.getByRole("button", { name: "Invite member" }).click();
  const dialog = page.getByRole("dialog", { name: "Invite member" });
  await dialog.getByRole("textbox", { name: "Email" }).fill(" new@acme.test ");
  await dialog.getByRole("button", { name: /Role/ }).click();
  await page.getByRole("option", { name: /^Admin/ }).click();
  await dialog.getByRole("button", { name: /^Invite/ }).click();
  await expect(dialog.getByRole("alert")).toHaveText(
    "Your session token is missing or expired. Reload the page and try again."
  );

  refuse = false;
  await dialog.getByRole("button", { name: /^Invite/ }).click();
  await expect(dialog).toBeHidden();
  await expect(
    page.getByRole("cell", { name: "u-new@acme.test" }).first()
  ).toBeVisible();
  expect(writes(requests).at(-1)).toEqual({
    method: "POST",
    path: "/orgs/acme/members",
    search: "",
    csrf,
    body: { email: "new@acme.test", role: "admin" },
  });
});

test("a member sees the list without write actions", async ({ page }) => {
  await openMembers(page, "member", undefined, "u-priya");

  await expect(page.getByRole("button", { name: "Invite member" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /^Role of / })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /^Remove / })).toHaveCount(0);
  await expect(page.getByRole("row")).toHaveCount(people.length + 1);
  await expect(page.getByText("Feishu SSO")).toBeVisible();
  await expect(page.getByRole("link", { name: /Members/ })).toHaveAttribute(
    "aria-current",
    "page"
  );
});

test("the Members sidebar link opens the page in place", async ({ page }) => {
  await injectCsrfToken(page);
  await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    if (request.path === "/orgs/acme/members") return ok(membersPage("owner"));
    if (request.path === "/orgs/acme/runners") {
      return ok({
        viewer: { can_manage: true },
        runners: [],
        total_count: 0,
        cursor: null,
        next_cursor: null,
        poll_interval_ms: 5000,
      });
    }
    return undefined;
  });
  await page.goto("/orgs/acme/fin");
  await expect(page.getByRole("heading", { level: 1, name: "Runners" })).toBeVisible();
  await page.evaluate(() => {
    (window as unknown as { bftMarker: boolean }).bftMarker = true;
  });
  await page.getByRole("link", { name: /Members/ }).click();
  await expect(page.getByRole("heading", { level: 1, name: "Members" })).toBeVisible();
  expect(
    await page.evaluate(() => (window as unknown as { bftMarker?: boolean }).bftMarker)
  ).toBe(true);
});
