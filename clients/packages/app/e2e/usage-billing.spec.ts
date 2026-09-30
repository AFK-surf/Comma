import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";
import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startSessionProjectionStub } from "../../../e2e/helpers/session-fixture";

let stub: Awaited<ReturnType<typeof startSessionProjectionStub>>;
test.afterEach(async () => {
  await stub?.close();
});

// Annual invoices produce monthly credit grants, not monthly subscription renewals.
test("separates annual billing from monthly credit expiry and supports redemption", async ({
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 1440, height: 1100 });
  const annualPlan = {
    plan_key: "comma_value_annual_v1",
    package_code: "comma_value",
    package_version: "annual-v1",
    name: "Comma Value",
    mode: "subscription",
    currency: "usd",
    amount_minor: 20_000,
    billing_period: "year",
    grant_period: "current_period",
    grant_credits: 20_000_000,
  };
  const pack = {
    plan_key: "comma_topup_v1",
    package_code: "comma_topup",
    package_version: "v1",
    name: "Credit pack",
    mode: "payment",
    currency: "usd",
    amount_minor: 1_000,
    grant_credits: 10_000_000,
    billing_period: null,
    grant_period: "current_period",
  };
  let redeemed = false;
  let redeemedCode: string | undefined;
  let confirmedChange: Record<string, unknown> | undefined;
  const upgrade = {
    ...annualPlan,
    plan_key: "comma_pro_annual_v1",
    package_code: "comma_pro",
    name: "Comma Pro",
    amount_minor: 40_000,
    grant_credits: 100_000_000,
  };
  const preview = {
    amount_minor: 1_500,
    currency: "usd",
    effect: "upgrade",
    current_price_id: "price_annual_value",
    proration_date: 1790000000,
    period_end: 1800000000,
  };
  stub = await startSessionProjectionStub({
    email: "billing@example.com",
    userId: "usr_billing",
    handleRequest(request, response, path) {
      let body: unknown = { data: [] };
      if (path === "/v1/comma/workspaces") {
        body = {
          data: [{ id: "wsp_billing", group_id: "grp_billing", name: "Personal" }],
        };
      } else if (path === "/v1/comma/billing/plans") {
        body = {
          data: [
            annualPlan,
            upgrade,
            { ...upgrade, plan_key: "comma_pro_v1", billing_period: "month" },
            pack,
          ],
        };
      } else if (path.endsWith("/billing/summary")) {
        body = {
          billing_account_id: "billing-1",
          current_credits: redeemed ? 22_000_700 : 22_000_000,
          active_subscription: {
            package_code: annualPlan.package_code,
            package_version: annualPlan.package_version,
            status: "active",
            source_id: "sub_annual",
            plan: annualPlan,
          },
          active_grants: [
            {
              id: "grant_month",
              package_code: annualPlan.package_code,
              package_version: annualPlan.package_version,
              remaining_credits: 12_000_000,
              valid_from: "2026-09-07T12:00:00Z",
              expires_at: "2026-10-07T12:00:00Z",
              source_type: "subscription_cycle",
              source_id: "cycle_annual_september",
            },
            {
              id: "grant_pack",
              package_code: pack.package_code,
              package_version: pack.package_version,
              remaining_credits: 10_000_000,
              valid_from: "2026-08-07T12:00:00Z",
              expires_at: "2026-11-07T12:00:00Z",
              source_type: "checkout",
              source_id: "checkout_pack",
            },
            ...(redeemed
              ? [
                  {
                    id: "grant_redeem",
                    package_code: null,
                    package_version: null,
                    remaining_credits: 700,
                    valid_from: "2026-09-07T12:00:00Z",
                    expires_at: null,
                    source_type: "redeem",
                    source_id: "redeem_1",
                  },
                ]
              : []),
          ],
        };
      } else if (path.endsWith("/billing/subscription/preview")) {
        body = preview;
      } else if (path.endsWith("/billing/subscription/change")) {
        let input = "";
        request.on("data", (chunk) => {
          input += chunk;
        });
        request.on("end", () => {
          confirmedChange = JSON.parse(input);
          response.writeHead(200, { "content-type": "application/json" });
          response.end(
            JSON.stringify({ id: "sub_annual", provider: "stripe", effect: "upgraded" })
          );
        });
        return true;
      } else if (path.endsWith("/billing/redeem")) {
        let input = "";
        request.on("data", (chunk) => {
          input += chunk;
        });
        request.on("end", () => {
          redeemedCode = JSON.parse(input).code;
          redeemed = true;
          response.writeHead(200, { "content-type": "application/json" });
          response.end(JSON.stringify({ grant: { remaining_credits: 700 } }));
        });
        return true;
      }
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(body));
      return true;
    },
  });
  await installBrowserTestSession(page, {
    apiBaseUrl: stub.baseUrl,
    email: "billing@example.com",
    token: "comma_sess_billing",
    userId: "usr_billing",
  });
  await page.goto("/#/settings?category=usage-billing");
  await expect(
    page.getByText("$200.00 / year · Active", { exact: true })
  ).toBeVisible();
  await expect(
    page.getByText("Subscription credits expire Oct 7, 2026", { exact: false })
  ).toBeVisible();
  await expect(page.getByText("22,000,000", { exact: true })).toBeVisible();
  await expect(
    page.getByRole("progressbar", { name: "Credits remaining" })
  ).toHaveAttribute("value", "73");
  await page.screenshot({
    path: testInfo.outputPath("usage-billing-annual.png"),
    fullPage: true,
    animations: "disabled",
  });
  const codeInput = page.getByRole("textbox", { name: "Redeem code" });
  const redeemButton = page.getByRole("button", { name: "Redeem", exact: true });
  await codeInput.fill(" AB ");
  await expect(redeemButton).toBeDisabled();
  await codeInput.press("Enter");
  expect(redeemedCode).toBeUndefined();
  await codeInput.fill(" ABC ");
  await expect(redeemButton).toBeEnabled();
  await redeemButton.click();
  await expect(page.getByText("22,000,700", { exact: true })).toBeVisible();
  expect(redeemedCode).toBe("ABC");
  // A manual grant has no original amount in the summary, so no percentage is inferred.
  await expect(page.getByRole("progressbar")).toHaveCount(0);
  await expect(
    page.getByText("Subscription credits expire Oct 7, 2026", { exact: false })
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Upgrade to Comma Pro", exact: true })
  ).toHaveCount(1);
  await page.getByRole("button", { name: "Upgrade to Comma Pro", exact: true }).click();
  const confirmation = page.getByRole("dialog", { name: "Confirm plan change" });
  await expect(confirmation).toContainText("Pay $15.00 now");
  await expect(confirmation).toContainText("not restored if payment fails");
  expect(confirmedChange).toBeUndefined();
  await confirmation.getByRole("button", { name: "Confirm", exact: true }).click();
  await expect.poll(() => confirmedChange?.plan_key).toBe("comma_pro_annual_v1");
  expect(confirmedChange).toMatchObject({
    current_price_id: preview.current_price_id,
    proration_date: preview.proration_date,
    period_end: preview.period_end,
  });
  expect(confirmedChange?.client_request_id).toEqual(expect.any(String));
});

test("a hidden annual current plan can clear its downgrade using the historical key", async ({
  page,
}) => {
  const currentPlan = {
    plan_key: "cue_max_annual_v1",
    package_code: "comma_max",
    package_version: "annual-v1",
    name: "Comma Max",
    mode: "subscription",
    currency: "usd",
    amount_minor: 200_000,
    billing_period: "year",
    grant_period: "current_period",
    grant_credits: 200_000_000,
  };
  const pro = {
    ...currentPlan,
    plan_key: "comma_pro_annual_v1",
    package_code: "comma_pro",
    name: "Comma Pro",
    amount_minor: 60_000,
    grant_credits: 60_000_000,
  };
  let confirmed: Record<string, unknown> | undefined;
  stub = await startSessionProjectionStub({
    email: "billing@example.com",
    userId: "usr_billing",
    handleRequest(request, response, path) {
      let body: unknown = { data: [] };
      if (path === "/v1/comma/workspaces")
        body = {
          data: [{ id: "wsp_billing", group_id: "grp_billing", name: "Personal" }],
        };
      else if (path === "/v1/comma/billing/plans")
        body = {
          data: [
            pro,
            {
              ...pro,
              plan_key: "comma_pro_v1",
              package_version: "v1",
              billing_period: "month",
              amount_minor: 6_000,
            },
          ],
        };
      else if (path.endsWith("/billing/summary"))
        body = {
          billing_account_id: "billing-1",
          current_credits: 200_000_000,
          active_grants: [],
          active_subscription: {
            package_code: currentPlan.package_code,
            package_version: currentPlan.package_version,
            status: "active",
            source_id: "sub_hidden",
            plan: currentPlan,
            source_metadata: {
              scheduled_plan: {
                package_code: pro.package_code,
                package_version: pro.package_version,
                effective_at: 1800000000,
              },
            },
          },
        };
      else if (path.endsWith("/billing/subscription/preview"))
        body = {
          amount_minor: 0,
          currency: "usd",
          effect: "keep_current",
          current_price_id: "price_historical_max",
          proration_date: 1790000000,
          period_end: 1800000000,
        };
      else if (path.endsWith("/billing/subscription/change")) {
        let input = "";
        request.on("data", (chunk) => {
          input += chunk;
        });
        request.on("end", () => {
          confirmed = JSON.parse(input);
          response.writeHead(200, { "content-type": "application/json" });
          response.end(
            JSON.stringify({
              id: "sub_hidden",
              provider: "stripe",
              effect: "kept_current",
            })
          );
        });
        return true;
      }
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(body));
      return true;
    },
  });
  await installBrowserTestSession(page, {
    apiBaseUrl: stub.baseUrl,
    email: "billing@example.com",
    token: "comma_sess_billing",
    userId: "usr_billing",
  });
  await page.goto("/#/settings?category=usage-billing");
  const keep = page.getByRole("button", { name: "Keep current plan", exact: true });
  await expect(keep).toBeEnabled();
  await expect(page.getByText("Comma Max", { exact: true })).toBeVisible();
  await expect(
    page.getByText("$2,000.00 / year · Active", { exact: true })
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Monthly", exact: true })
  ).toBeDisabled();
  await keep.click();
  await page
    .getByRole("dialog", { name: "Confirm plan change" })
    .getByRole("button", { name: "Confirm", exact: true })
    .click();
  await expect.poll(() => confirmed?.plan_key).toBe("cue_max_annual_v1");
});

test("warns above the composer at 50, 10 and 5 percent and remembers dismissed thresholds", async ({
  page,
}, testInfo) => {
  const chat = await startChatSmokeStub();
  let remaining = 501;
  let grantId = "warning-grant-1";
  const warningPlan = {
    plan_key: "warning-monthly",
    package_code: "warning-monthly",
    package_version: "v1",
    name: "Monthly",
    mode: "subscription",
    currency: "usd",
    amount_minor: 100,
    grant_credits: 1000,
  };
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: chat.baseUrl,
      email: "credit-warning@comma.local",
      token: "comma_sess_credit_warning",
    });
    await page.route(`${chat.baseUrl}/v1/comma/billing/plans`, (route) =>
      route.fulfill({ json: { data: [warningPlan] } })
    );
    await page.route(`${chat.baseUrl}/v1/comma/workspaces/*/billing/summary`, (route) =>
      route.fulfill({
        json: {
          billing_account_id: "billing-warning",
          current_credits: remaining,
          active_grants: [
            {
              id: grantId,
              package_code: warningPlan.package_code,
              package_version: warningPlan.package_version,
              remaining_credits: remaining,
              valid_from: "2026-09-01T00:00:00Z",
              expires_at: null,
              source_type: "subscription_cycle",
              source_id: "warning-cycle",
            },
          ],
        },
      })
    );
    await page.clock.install();
    await page.goto("/");
    const prompt = page
      .getByRole("region", { name: "Content" })
      .getByRole("textbox", { name: "AI prompt" });
    await expect(prompt).toBeVisible();
    const card = page.getByTestId("chat-credit-warning");
    await expect(card).toHaveCount(0);
    for (const balance of [500, 100, 50]) {
      remaining = balance;
      await page.clock.fastForward(60_000);
      await expect(card).toContainText(`${balance / 10}% of usage credits remaining`);
      const cardBox = await card.boundingBox();
      const promptBox = await prompt.boundingBox();
      expect(cardBox!.y + cardBox!.height).toBeLessThanOrEqual(promptBox!.y);
      await expect(card.getByRole("button", { name: "Retry" })).toHaveCount(0);
      await prompt.fill("Keep writing while credits remain");
      await expect(prompt).toContainText("Keep writing while credits remain");
      await expect(
        card.getByRole("button", {
          name: balance === 500 ? "Usage & billing" : "Add credits",
          exact: true,
        })
      ).toBeVisible();
      await page.getByRole("group", { name: "AI input", exact: true }).screenshot({
        path: testInfo.outputPath(`credit-warning-${balance / 10}-percent.png`),
        animations: "disabled",
      });
      await card.getByRole("button", { name: "Close" }).click();
      await expect(card).toHaveCount(0);
      await page.clock.fastForward(60_000);
      await expect(card).toHaveCount(0);
    }
    await page.reload();
    await expect(prompt).toBeVisible();
    await expect(card).toHaveCount(0);
    grantId = "warning-grant-2";
    remaining = 500;
    await page.evaluate(() => window.dispatchEvent(new Event("focus")));
    await expect(card).toContainText("50% of usage credits remaining");
    await card.getByRole("button", { name: "Usage & billing" }).click();
    await expect(page).toHaveURL(/settings\?category=usage-billing/);
  } finally {
    await chat.close();
  }
});
