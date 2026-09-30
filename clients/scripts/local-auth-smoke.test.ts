import { describe, expect, it } from "vitest";
import {
  bearerSessionHeaders,
  cookieSessionHeaders,
} from "./local-auth-smoke-contract.mjs";

describe("local auth smoke Session protocol", () => {
  it("builds Web cookie startup and exact-session headers", () => {
    expect(cookieSessionHeaders("unknown", { accept: "application/json" })).toEqual({
      accept: "application/json",
      "x-comma-expected-auth-session-id": "unknown",
      "x-comma-session-lifecycle-version": "1",
      "x-comma-session-transport": "cookie",
    });

    expect(
      cookieSessionHeaders("11111111-1111-4111-8111-111111111111", {
        "content-type": "application/json",
      })
    ).toMatchObject({
      "x-comma-expected-auth-session-id": "11111111-1111-4111-8111-111111111111",
      "x-comma-session-lifecycle-version": "1",
      "x-comma-session-transport": "cookie",
    });
    expect(() => cookieSessionHeaders("")).toThrow(
      "Cookie Session expectation must not be empty."
    );
  });

  it("builds native bearer headers without Web lifecycle fields", () => {
    expect(
      bearerSessionHeaders({
        authorization: "Bearer comma_sess_test",
      })
    ).toEqual({
      authorization: "Bearer comma_sess_test",
      "x-comma-session-transport": "bearer",
    });
  });
});
