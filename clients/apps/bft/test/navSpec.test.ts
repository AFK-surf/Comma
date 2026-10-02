import { describe, expect, it } from "vitest";
import type { BftCapabilities } from "../src/api";
import {
  buildOrgNav,
  flattenNav,
  isNavItemActive,
  isNavLinkActive,
} from "../src/navSpec";

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
    // The SPA serves every organization page.
    expect(nav.filter((item) => !item.spa)).toEqual([]);
    const triage = nav.find((item) => item.id === "triage");
    expect(
      triage?.children.map((child) => [child.label, child.href, child.spa])
    ).toEqual([
      ["Overview", "/orgs/acme/triage", true],
      ["Timeline", "/orgs/acme/triage/timeline", true],
      ["Knowledge", "/orgs/acme/triage/knowledge", true],
    ]);
    const meetings = nav.find((item) => item.id === "meetings");
    expect(
      meetings?.children.map((child) => [child.label, child.href, child.spa])
    ).toEqual([
      ["Upcoming", "/orgs/acme/meetings", true],
      ["Past", "/orgs/acme/meetings/past", true],
      ["Settings", "/orgs/acme/meetings/settings", true],
    ]);
    // Each Agent Swarm's overview is an SPA page too.
    expect(swarms?.children.every((child) => child.spa)).toBe(true);
    // The palette lists sub-pages but not the "General", "Upcoming" and
    // "Overview" duplicates of their parent.
    expect(flattenNav(nav)).toHaveLength(10 + 1 + 3 + 2 + 2);
  });

  it("lists the four Settings pages, all in the SPA", () => {
    const nav = buildOrgNav({
      org: "acme",
      capabilities: { ...allOff, settings: true },
      projects,
    });
    const settings = nav.find((item) => item.id === "settings");
    expect(
      settings?.children.map((child) => [child.label, child.href, child.spa])
    ).toEqual([
      ["General", "/orgs/acme/settings", true],
      ["AI models", "/orgs/acme/settings/models", true],
      ["Single sign-on", "/orgs/acme/settings/sso", true],
      ["Integrations", "/orgs/acme/settings/integrations", true],
    ]);
    const integrations = settings?.children[3];
    expect(
      integrations && isNavLinkActive(integrations, "/orgs/acme/settings/integrations/")
    ).toBe(true);
    expect(settings && isNavItemActive(settings, "/orgs/acme/settings/sso")).toBe(true);
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

  it("expands only the Agent Swarm the current page is inside", () => {
    const nav = buildOrgNav({
      org: "acme",
      capabilities: allOff,
      projects: [...projects, { id: "p2", name: "Sales" }],
      pathname: "/orgs/acme/projects/p%201/agents/a1",
    });
    const [active, other] = nav.find((item) => item.id === "swarms")?.children ?? [];
    expect(other?.children).toBeUndefined();
    expect(
      active && isNavLinkActive(active, "/orgs/acme/projects/p%201/agents/a1")
    ).toBe(true);
    const pages = active?.children ?? [];
    expect(
      pages.map((page) => page.href.replace("/orgs/acme/projects/p%201", ""))
    ).toEqual([
      "",
      "/tasks",
      "/agents",
      "/devices",
      "/plugins",
      "/skills",
      "/integrations",
      "/connections",
      "/settings",
    ]);
    // Overview, Tasks, Agents, Devices and Settings are SPA pages; the rest are LiveView.
    expect(pages.filter((page) => page.spa).map((page) => page.id)).toEqual([
      "swarm:p 1:overview",
      "swarm:p 1:tasks",
      "swarm:p 1:agents",
      "swarm:p 1:devices",
      "swarm:p 1:settings",
    ]);
    // The palette lists the swarm's pages under its name, without a duplicate Overview.
    const swarmPages = flattenNav(nav).filter((entry) => entry.parent === active);
    expect(swarmPages).toHaveLength(8);
    expect(swarmPages[0]?.link.label).toBe("Tasks");

    const outside = buildOrgNav({
      org: "acme",
      capabilities: allOff,
      projects,
      pathname: "/orgs/acme/projects/p%2010",
    });
    expect(outside.find((item) => item.id === "swarms")?.children[0]?.children).toBe(
      undefined
    );
  });
});
