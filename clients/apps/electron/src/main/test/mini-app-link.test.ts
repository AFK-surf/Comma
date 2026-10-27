import { describe, expect, it } from "vitest";
import { miniAppLinkRoute } from "../mini-app-link";

const token = "a".repeat(43);

describe("Mini App link", () => {
  it("opens the link route only for this app's scheme and a well-formed token", () => {
    expect(
      miniAppLinkRoute(`comma-staging://apps/link/${token}`, "comma-staging")
    ).toBe(`/apps/link/${token}`);
    for (const url of [
      `comma://apps/link/${token}`,
      `https://apps/link/${token}`,
      `comma-staging://apps/link/${token}/extra`,
      `comma-staging://apps/link/${token}?next=/settings`,
      "comma-staging://apps/link/short",
      `comma-staging://user@apps/link/${token}`,
      `comma-staging://tasks/link/${token}`,
      "not a url",
    ]) {
      expect(miniAppLinkRoute(url, "comma-staging")).toBeUndefined();
    }
  });
});

it("dispatches web App addresses to Main instead of an external browser", async () => {
  const { dispatchMiniAppRunLink } = await import("../mini-app-link");
  const routes: string[] = [];
  let unavailable = 0;
  const dispatch = (url: string) =>
    dispatchMiniAppRunLink(
      url,
      [],
      (route) => routes.push(route),
      () => unavailable++
    );
  expect(dispatch("https://app-staging.comma.surf/#/apps/other/app/run")).toBe(true);
  expect(routes).toEqual(["/apps/other/app/run"]);
  expect(dispatch("https://app.comma.surf/#/apps/other/run")).toBe(true);
  expect(unavailable).toBe(1);
  expect(dispatch("https://example.com/#/apps/other/app/run")).toBe(false);
});
