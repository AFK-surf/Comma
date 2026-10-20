import { expect, test } from "./electron-test";
import type { ServerResponse } from "node:http";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { startSessionProjectionStub } from "../../../e2e/helpers/session-fixture";

const BILLING_E2E_EMAIL = "billing-return-e2e@example.com";
const WORKSPACE_ID = "billing-return-workspace";

const proPlan = {
  plan_key: "comma_pro_plus_v1",
  package_code: "comma_pro_plus",
  package_version: "v1",
  mode: "subscription",
  name: "Comma Pro Plus",
  currency: "usd",
  amount_minor: 8_000,
  grant_credits: 80_000_000,
  billing_period: "month",
  grant_period: "current_period",
};

// The Stripe webhook is server state: the summary flips once it "lands".
let subscribed = false;
let sessionStub: Awaited<ReturnType<typeof startSessionProjectionStub>>;

test.describe("billing return", () => {
  test.beforeAll(async () => {
    sessionStub = await startSessionProjectionStub({
      email: BILLING_E2E_EMAIL,
      handleRequest: (request, response, path) => {
        if (request.method !== "GET") return false;
        if (path === "/v1/comma/billing/plans") {
          writeJson(response, { data: [proPlan] });
          return true;
        }
        if (path === "/v1/comma/workspaces") {
          writeJson(response, {
            data: [
              { id: WORKSPACE_ID, group_id: "billing-return-group", name: "Personal" },
            ],
          });
          return true;
        }
        if (path === `/v1/comma/workspaces/${WORKSPACE_ID}/billing/summary`) {
          writeJson(response, {
            billing_account_id: "billing-return-account",
            current_credits: subscribed ? 80_000_000 : 0,
            active_grants: [],
            active_subscription: subscribed
              ? {
                  package_code: proPlan.package_code,
                  package_version: proPlan.package_version,
                  source_id: "sub_billing_return",
                  status: "active",
                  plan: proPlan,
                }
              : null,
          });
          return true;
        }
        return false;
      },
    });
  });

  test.afterAll(async () => {
    await sessionStub.close();
  });

  test.beforeEach(() => {
    subscribed = false;
  });

  test(
    "shows the new plan when checkout returns to an already open Usage & billing",
    { tag: "@shared-app" },
    async ({ sharedElectron: { app, mainWindow, signIn, useApi, userDataDir } }) => {
      useApi(sessionStub.server);
      await signIn({ email: BILLING_E2E_EMAIL, userId: sessionStub.userId });
      try {
        await mainWindow.evaluate(() => {
          window.location.hash = "#/settings?category=usage-billing";
        });
        await expect(
          mainWindow.getByRole("heading", { level: 1, name: "Usage & billing" })
        ).toBeVisible();
        await expect(mainWindow.getByText("No subscription")).toBeVisible();
        // A marker that only survives an in-place hash move, not a page load.
        await mainWindow.evaluate(() => {
          (window as unknown as { billingReturnMarker?: true }).billingReturnMarker =
            true;
        });

        subscribed = true;
        // What macOS hands Main when the return page opens the app's URL scheme.
        await app.evaluate(({ app: electronApp }) => {
          electronApp.emit("second-instance", {}, [
            process.execPath,
            "comma-dev://billing/return?status=success",
          ]);
        });

        // The catalog already lists the plan; the plan row and balance must change.
        await expect(mainWindow.getByText("No subscription")).toBeHidden();
        await expect(mainWindow.getByText("80,000,000", { exact: true })).toBeVisible();
        expect(
          await mainWindow.evaluate(
            () =>
              (window as unknown as { billingReturnMarker?: true }).billingReturnMarker
          )
        ).toBe(true);
        // Read once, the parameter leaves the hash for the next return.
        await expect
          .poll(() => mainWindow.evaluate(() => window.location.hash))
          .toBe("#/settings?category=usage-billing");
      } catch (error) {
        await attachMainLog(userDataDir);
        throw error;
      }
    }
  );
});

async function attachMainLog(userDataPath: string) {
  const mainLog = await readFile(join(userDataPath, "logs", "main.log"), "utf8").catch(
    () => undefined
  );
  if (mainLog === undefined) return;
  await test.info().attach("main.log", { body: mainLog, contentType: "text/plain" });
}

function writeJson(response: ServerResponse, body: unknown) {
  response.writeHead(200, {
    "cache-control": "no-store",
    "content-type": "application/json",
  });
  response.end(JSON.stringify(body));
}
