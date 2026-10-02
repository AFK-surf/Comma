import { describe, expect, it } from "vitest";
import { matchRoute, rootRedirect } from "../src/router";

const user = { id: "u1", name: "Maya Chen", email: null };

describe("BFT router", () => {
  it("opens the first organization in place", () => {
    expect(
      rootRedirect({
        user,
        orgs: [
          { slug: "acme co", name: "Acme" },
          { slug: "globex", name: "Globex" },
        ],
      })
    ).toBe("/orgs/acme%20co");
  });

  it("has nowhere to send users without organizations", () => {
    expect(rootRedirect({ user, orgs: [] })).toBeUndefined();
  });

  it("owns /, /orgs, /orgs/:org and /orgs/:org/projects/:id", () => {
    expect(matchRoute("/")).toEqual({ name: "root" });
    expect(matchRoute("/orgs/")).toEqual({ name: "root" });
    expect(matchRoute("/orgs/acme")).toEqual({ name: "org-overview", org: "acme" });
    expect(matchRoute("/orgs/acme/")).toEqual({ name: "org-overview", org: "acme" });
    expect(matchRoute("/orgs/acme%20co")).toEqual({
      name: "org-overview",
      org: "acme co",
    });
    expect(matchRoute("/orgs/acme/projects/p%201/")).toEqual({
      name: "project-overview",
      org: "acme",
      project: "p 1",
    });
    expect(matchRoute("/orgs/acme/projects/%E0%A4%A")).toEqual({ name: "unknown" });
  });

  it("serves an Agent Swarm's Agents, Devices, Tasks and Settings, and opens its retired pages", () => {
    const at = { org: "acme", project: "p1" };
    expect(matchRoute("/orgs/acme/projects/p1/tasks")).toEqual({
      name: "project-tasks",
      ...at,
    });
    expect(matchRoute("/orgs/acme/projects/p1/settings/")).toEqual({
      name: "project-settings",
      ...at,
    });
    // Schedules is the Scheduled view of Tasks, Access a section of Settings
    // and Websites a panel of the Overview.
    expect(matchRoute("/orgs/acme/projects/p1/schedules")).toEqual({
      name: "project-tasks",
      ...at,
      retired: true,
    });
    expect(matchRoute("/orgs/acme/projects/p1/access")).toEqual({
      name: "project-settings",
      ...at,
      retired: true,
    });
    expect(matchRoute("/orgs/acme/projects/p1/websites")).toEqual({
      name: "project-overview",
      ...at,
      retired: true,
    });
    // An agent's address opens the Agents page with that agent selected.
    expect(matchRoute("/orgs/acme/projects/p1/agents")).toEqual({
      name: "project-agents",
      ...at,
    });
    expect(matchRoute("/orgs/acme/projects/p1/agents/a%201/")).toEqual({
      name: "project-agents",
      ...at,
      agent: "a 1",
    });
    expect(matchRoute("/orgs/acme/projects/p1/agents/a1/config")).toEqual({
      name: "unknown",
    });
    expect(matchRoute("/orgs/acme/projects/p1/devices/")).toEqual({
      name: "project-devices",
      ...at,
    });
    expect(matchRoute("/orgs/acme/projects/p1/devices/dev1")).toEqual({
      name: "unknown",
    });
    // Task detail stays a LiveView page.
    expect(matchRoute("/orgs/acme/projects/p1/tasks/cnv1_a")).toEqual({
      name: "unknown",
    });
  });

  it("serves Members, Runners (the old Fin address), Agent Swarms, Plugins, Meetings and Data policy", () => {
    expect(matchRoute("/orgs/acme/projects/")).toEqual({
      name: "org-swarms",
      org: "acme",
    });
    expect(matchRoute("/orgs/acme/plugins")).toEqual({
      name: "org-plugins",
      org: "acme",
    });
    expect(matchRoute("/orgs/acme/members")).toEqual({
      name: "org-members",
      org: "acme",
    });
    expect(matchRoute("/orgs/acme%20co/fin/")).toEqual({
      name: "org-runners",
      org: "acme co",
    });
    expect(matchRoute("/orgs/acme/information-flow")).toEqual({
      name: "org-data-policy",
      org: "acme",
    });
    expect(matchRoute("/orgs/acme/meetings/")).toEqual({
      name: "org-meetings",
      org: "acme",
      view: "upcoming",
    });
    expect(matchRoute("/orgs/acme/meetings/past")).toEqual({
      name: "org-meetings",
      org: "acme",
      view: "past",
    });
    expect(matchRoute("/orgs/acme/meetings/history")).toEqual({ name: "unknown" });
    expect(matchRoute("/orgs/acme/triage")).toEqual({
      name: "org-triage",
      org: "acme",
      view: "overview",
    });
    expect(matchRoute("/orgs/acme/triage/knowledge/")).toEqual({
      name: "org-triage",
      org: "acme",
      view: "knowledge",
    });
    // The retired Context, Memory and Raw data pages open the Overview.
    for (const page of ["context", "memory", "data"]) {
      expect(matchRoute(`/orgs/acme/triage/${page}`)).toEqual({
        name: "org-triage",
        org: "acme",
        view: "overview",
        retired: true,
      });
    }
    expect(matchRoute("/orgs/acme/triage/settings")).toEqual({ name: "unknown" });
    expect(matchRoute("/orgs/acme/members/u1")).toEqual({ name: "unknown" });
    expect(matchRoute("/orgs/acme/finance")).toEqual({ name: "unknown" });
  });

  it("serves Health at /orgs/:org/operations and its old tab addresses", () => {
    expect(matchRoute("/orgs/acme/operations")).toEqual({
      name: "org-health",
      org: "acme",
    });
    expect(matchRoute("/orgs/acme%20co/operations/")).toEqual({
      name: "org-health",
      org: "acme co",
    });
    expect(matchRoute("/orgs/acme/operations/audit")).toEqual({
      name: "org-health",
      org: "acme",
      tab: "audit",
    });
    expect(matchRoute("/orgs/acme/operations/audit/export")).toEqual({
      name: "unknown",
    });
    expect(matchRoute("/orgs/acme/operationsx")).toEqual({ name: "unknown" });
  });

  it("serves the four Settings pages in place", () => {
    expect(matchRoute("/orgs/acme%20co/settings/")).toEqual({
      name: "org-settings",
      org: "acme co",
      page: "general",
    });
    for (const page of ["models", "sso", "integrations"]) {
      expect(matchRoute(`/orgs/acme/settings/${page}`)).toEqual({
        name: "org-settings",
        org: "acme",
        page,
      });
    }
    // General has one address.
    expect(matchRoute("/orgs/acme/settings/general")).toEqual({ name: "unknown" });
    expect(matchRoute("/orgs/acme/settings/sso/extra")).toEqual({ name: "unknown" });
  });

  it("opens retired Settings addresses as sections of their new page", () => {
    for (const section of ["oauth", "composio", "signal", "feishu"]) {
      expect(matchRoute(`/orgs/acme/settings/${section}`)).toEqual({
        name: "org-settings",
        org: "acme",
        page: "integrations",
        legacySection: section,
      });
    }
    expect(matchRoute("/orgs/acme/settings/models/templates")).toEqual({
      name: "org-settings",
      org: "acme",
      page: "models",
      legacySection: "templates",
    });
    expect(matchRoute("/orgs/acme/settings/subscriptions/")).toEqual({
      name: "org-settings",
      org: "acme",
      page: "models",
      legacySection: "accounts",
    });
    // Object keys are not sections.
    expect(matchRoute("/orgs/acme/settings/toString")).toEqual({ name: "unknown" });
  });

  it("serves the CLI login approval outside any organization", () => {
    expect(matchRoute("/cli/device-login")).toEqual({ name: "cli-login" });
    expect(matchRoute("/cli/device-login/ABCD2345/")).toEqual({
      name: "cli-login",
      code: "ABCD2345",
    });
    expect(matchRoute("/cli/device-login/ABCD2345/approve")).toEqual({
      name: "unknown",
    });
  });
});
