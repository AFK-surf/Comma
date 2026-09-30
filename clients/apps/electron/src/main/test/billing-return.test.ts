import { describe, expect, it } from "vitest";
import {
  billingSettingsRoute,
  billingSettingsRouteForReturn,
  findBillingReturnUrl,
  parseBillingReturnUrl,
} from "../billing-return";

describe("billing return deep links", () => {
  it("accepts only the exact channel scheme and billing return route", () => {
    expect(
      parseBillingReturnUrl("comma-dev://billing/return?status=success", "comma-dev")
    ).toEqual({
      status: "success",
      url: "comma-dev://billing/return?status=success",
    });
    expect(
      parseBillingReturnUrl("comma://billing/return?status=success", "comma-dev")
    ).toBeUndefined();
    expect(
      parseBillingReturnUrl("comma-dev://plugins/return?status=success", "comma-dev")
    ).toBeUndefined();
    expect(
      parseBillingReturnUrl("comma-dev://billing/return?status=unknown", "comma-dev")
    ).toBeUndefined();
    expect(
      parseBillingReturnUrl("comma-dev://billing/return?status=portal", "comma-dev")
    ).toMatchObject({ status: "portal" });
    expect(
      parseBillingReturnUrl(
        "comma-dev://billing/return?status=subscription",
        "comma-dev"
      )
    ).toMatchObject({ status: "subscription" });
  });

  it("finds a billing return among second-instance arguments", () => {
    expect(
      findBillingReturnUrl(
        ["/Applications/Comma Dev.app", "comma-dev://billing/return?status=cancel"],
        "comma-dev"
      )
    ).toMatchObject({ status: "cancel" });
    expect(billingSettingsRoute).toBe("/settings?category=usage-billing");
    expect(billingSettingsRouteForReturn("success")).toBe(
      "/settings?category=usage-billing&billing-return=success"
    );
  });
});
