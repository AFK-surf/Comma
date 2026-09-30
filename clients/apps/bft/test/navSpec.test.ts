import { describe, expect, it } from "vitest";
import type { BftCapabilities } from "../src/api";
import { buildOrgNav, flattenNav, isNavItemActive } from "../src/navSpec";

const allOff: BftCapabilities = {
  operations: false,
  triage: false,
  information_flow: false,
  meetings: false,
  settings: false,
};
const projects = [{ id: "p 1", name: "Support Desk" }];

describe("BFT navigation spec", () => {
  it("hides capability-gated items", () => {
    const nav = buildOrgNav({ org: "acme", capabilities: allOff, projects });
    expect(nav.map((item) => item.id)).toEqual([
      "overview",
      "swarms",
      "runners",
      "members",
      "plugins",
    ]);
  });

  it("shows every item and submenu when all capabilities are on", () => {
    const capabilities = Object.fromEntries(
      Object.keys(allOff).map((key) => [key, true])
    ) as unknown as BftCapabilities;
    const nav = buildOrgNav({ org: "acme", capabilities, projects });
    expect(nav.map((item) => item.id)).toEqual([
      "overview",
      "swarms",
      "meetings",
      "triage",
      "data-policy",
      "health",
      "runners",
      "members",
      "plugins",
      "settings",
    ]);
    const swarms = nav.find((item) => item.id === "swarms");
    expect(swarms?.children.map((child) => child.href)).toEqual([
      "/orgs/acme/projects/p%201",
    ]);
    expect(nav.find((item) => item.id === "settings")?.children).toHaveLength(7);
    // Only Overview is served by the SPA; the rest are full-page LiveView links.
    expect(nav.filter((item) => item.spa).map((item) => item.href)).toEqual([
      "/orgs/acme",
    ]);
    // The palette lists sub-pages but not the settings "General" duplicate.
    expect(flattenNav(nav)).toHaveLength(10 + 1 + 6);
  });

  it("matches Overview exactly and other items by prefix", () => {
    const [overview, swarms] = buildOrgNav({
      org: "acme",
      capabilities: allOff,
      projects,
    });
    expect(overview && isNavItemActive(overview, "/orgs/acme")).toBe(true);
    expect(overview && isNavItemActive(overview, "/orgs/acme/projects")).toBe(false);
    expect(swarms && isNavItemActive(swarms, "/orgs/acme/projects/p%201")).toBe(true);
    expect(swarms && isNavItemActive(swarms, "/orgs/acme/projectsx")).toBe(false);
  });
});
