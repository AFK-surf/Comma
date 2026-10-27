import { describe, expect, it } from "vitest";
import { getCommaConfig, parseMiniAppRunLink } from "../src/index";

describe("App run addresses", () => {
  it.each([
    "https://app.comma.surf",
    "https://app-staging.comma.surf",
    "http://localhost",
    getCommaConfig("dev").webBaseUrl,
    "https://preview.example.test",
  ])("preserves the workspace and App at %s", (origin) => {
    expect(
      parseMiniAppRunLink(`${origin}/?outer=1#/apps/other/app%20one/run/?version=2`, [
        "https://preview.example.test",
      ])
    ).toEqual({
      kind: "run",
      workspace_id: "other",
      app_id: "app one",
      route: "/apps/other/app%20one/run?version=2",
    });
  });
  it.each([
    "https://evil.test/#/apps/w/a/run",
    "https://app.comma.surf.evil.test/#/apps/w/a/run",
    "https://user@app.comma.surf/#/apps/w/a/run",
    "https://app.comma.surf/apps/w/a/run",
    "https://app.comma.surf/other#/apps/w/a/run",
    "https://app.comma.surf/#https://evil.test/apps/w/a/run",
    "https://app.comma.surf/#/apps/w/a/window",
    "https://app.comma.surf/#/apps/w/a/runner",
    "not a URL",
  ])("leaves ordinary URLs alone: %s", (url) => {
    expect(parseMiniAppRunLink(url)).toBeUndefined();
  });
  it.each([
    "/apps/w/run",
    "/apps/w//run",
    "/apps//a/run",
    "/apps/w/%ZZ/run",
    "/apps/w/a%2Fb/run",
  ])("reports an invalid App address: %s", (route) => {
    expect(parseMiniAppRunLink(`https://app.comma.surf/#${route}`)).toEqual({
      kind: "invalid",
    });
  });
});
