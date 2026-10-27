import { describe, expect, it } from "vitest";
import {
  sanitizeAttribution,
  sanitizeVisit,
  websiteLocale,
  websiteRoute,
} from "../src/index";

describe("website page analytics", () => {
  it("records each public page and its language, not a page family", () => {
    expect(websiteRoute("/agent")).toBe("/agent");
    expect(websiteRoute("/zh/pricing")).toBe("/pricing");
    expect(websiteRoute("/docs/agent/chat-apps")).toBe("/docs/agent/chat-apps");
    expect(websiteRoute("/fr/blog/agent-programmable-event-loops")).toBe(
      "/blog/agent-programmable-event-loops"
    );
    expect(websiteRoute("/de/alternatives/openclaw")).toBe("/alternatives/openclaw");
    expect(websiteRoute("/es/")).toBe("/");
    expect(websiteLocale("/zh-tw/docs")).toBe("zh-tw");
    expect(websiteLocale("/docs")).toBe("en");
  });

  it("keeps any other path out of the recorded page", () => {
    expect(websiteRoute("/pricing/anything")).toBe("/other");
    expect(websiteRoute("/docs/Some%20Text")).toBe("/other");
    expect(websiteRoute("/s/secret-token")).toBe("/other");
  });

  it("passes only a visit's referrer host and campaign slugs", () => {
    expect(
      sanitizeVisit({
        referrer_host: "www.google.com",
        utm_source: "hn",
        utm_campaign: "show hn launch",
        gclid: "abc",
        $referrer: "https://www.google.com/search?q=comma",
      })
    ).toEqual({
      referrer_host: "www.google.com",
      $referring_domain: "www.google.com",
      utm_source: "hn",
    });
    expect(sanitizeAttribution({ initial_landing_page: "/docs/quickstart" })).toEqual({
      initial_landing_page: "/docs/quickstart",
    });
  });

  it("names a direct visit the way PostHog's web analytics reads it", () => {
    expect(sanitizeVisit({ referrer_host: "direct" })).toEqual({
      referrer_host: "direct",
      $referring_domain: "$direct",
    });
  });
});
