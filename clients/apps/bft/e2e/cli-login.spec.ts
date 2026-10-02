import { expect, test, type Page } from "@playwright/test";
import { csrf, injectCsrfToken, ok, routeApi, type RecordedRequest } from "./support";

const orgs = [
  { id: "o-1", slug: "acme", name: "Acme Robotics" },
  { id: "o-2", slug: "globex", name: "Globex Research" },
];

const request = (status: string, granted: typeof orgs = []) => ({
  user_code: "ABCD2345",
  status,
  client_name: "bft CLI on mei-mbp",
  created_at: new Date(Date.now() - 120_000).toISOString(),
  expires_at: new Date(Date.now() + 7 * 24 * 3600_000).toISOString(),
  granted_orgs: granted,
});

type Reply = { status: number; body: unknown } | undefined;

async function openLogin(
  page: Page,
  path: string,
  write: (request: RecordedRequest) => Reply = () => undefined,
  current = () => request("pending")
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (call) => {
    if (call.method !== "GET") return write(call);
    if (call.path === "/cli/device-login/ABCD2345")
      return ok({ request: current(), orgs });
    if (call.path.startsWith("/cli/device-login/")) return ok({ request: null, orgs });
    return undefined;
  });
  await page.goto(path);
  return requests;
}

test("a typed code is normalized and opens its request", async ({ page }) => {
  await openLogin(page, "/cli/device-login");
  await expect(page.getByRole("navigation")).toHaveCount(0);
  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page.getByText("Enter the user code shown in the CLI.")).toBeVisible();

  await page.getByRole("textbox", { name: "User code" }).fill(" abcd-2345 ");
  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page).toHaveURL(/\/cli\/device-login\/ABCD2345$/);
  await expect(page.getByText("bft CLI on mei-mbp")).toBeVisible();
  await expect(page.getByText("Waiting for approval")).toBeVisible();
});

test("an unknown code says so and offers the code form again", async ({ page }) => {
  await openLogin(page, "/cli/device-login/ZZZZ9999");
  await expect(page.getByRole("alert")).toHaveText(
    "This CLI login request was not found. Check the code and try again."
  );
  await expect(page.getByRole("textbox", { name: "User code" })).toBeVisible();
});

test("approval grants only the chosen organizations, with the CSRF token", async ({
  page,
}) => {
  const requests = await openLogin(page, "/cli/device-login/ABCD2345", (call) =>
    call.path.endsWith("/approve")
      ? ok({ request: request("approved", [orgs[1]!]), orgs })
      : undefined
  );
  const approve = page.getByRole("button", { name: "Approve access" });
  await expect(approve).toBeDisabled();
  // The styled box covers the input; click its label like a user does.
  await page.locator(".bft-checklist").getByText("Globex Research").click();
  await approve.click();

  await expect(page.getByText("Approved. Return to the terminal")).toBeVisible();
  await expect(page.getByRole("listitem")).toHaveText(["Globex Research"]);
  const writes = requests.filter((call) => call.method !== "GET");
  expect(writes).toEqual([
    {
      method: "POST",
      path: "/cli/device-login/ABCD2345/approve",
      search: "",
      csrf,
      body: { org_ids: ["o-2"] },
    },
  ]);
});

test("a refused write shows the reason and the request as it is now", async ({
  page,
}) => {
  let status = "pending";
  await openLogin(
    page,
    "/cli/device-login/ABCD2345",
    (call) => {
      if (!call.path.endsWith("/deny")) return undefined;
      status = "expired";
      return {
        status: 409,
        body: {
          ok: false,
          error: { code: "cli_login_expired", message: "This CLI login has expired." },
        },
      };
    },
    () => request(status)
  );
  await page.getByRole("button", { name: "Deny access" }).click();
  await expect(page.getByRole("alert")).toHaveText("This CLI login has expired.");
  await expect(
    page.getByText("Expired. Start a new login from the terminal.")
  ).toBeVisible();
  await expect(page.getByRole("button", { name: "Approve access" })).toHaveCount(0);
});
