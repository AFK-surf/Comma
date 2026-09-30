import { describe, expect, it } from "vitest";
import { withoutRedeemCodePlaintext } from "../src/BillingView";

describe("BillingView one-time results", () => {
  it("removes plaintext before a created code enters parent catalog state", () => {
    const catalogCode = withoutRedeemCodePlaintext({
      code: "COMMA-PLAINTEXT-SECRET",
      code_type: "one_time_package",
      display_prefix: "COMMA-PLAI",
      id: "code-1",
      package_code: "comma_monthly",
      package_version: "v1",
      status: "active",
    });

    expect(catalogCode).not.toHaveProperty("code");
    expect(JSON.stringify(catalogCode)).not.toContain("COMMA-PLAINTEXT-SECRET");
  });
});
