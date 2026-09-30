import { describe, expect, it } from "vitest";
import { isAuthorizationReturnUrl } from "../authorization-return";

describe("authorization return protocol", () => {
  it("returns only to the current app flavor and fixed route", () => {
    expect(
      isAuthorizationReturnUrl("comma-dev://authorization/return", "comma-dev")
    ).toBe(true);
    for (const url of [
      "comma://authorization/return",
      "comma-staging://authorization/return",
      "comma-dev://authorization/return?code=secret",
      "comma-dev://authorization/return#redirect",
      "comma-dev://user@authorization/return",
      "https://authorization/return",
      "invalid",
    ])
      expect(isAuthorizationReturnUrl(url, "comma-dev")).toBe(false);
  });
});
