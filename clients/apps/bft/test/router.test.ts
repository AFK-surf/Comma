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
    ).toEqual({ kind: "replace", path: "/orgs/acme%20co" });
  });

  it("sends users without organizations to the LiveView org list", () => {
    expect(rootRedirect({ user, orgs: [] })).toEqual({ kind: "assign", href: "/orgs" });
  });

  it("owns only / and /orgs/:org", () => {
    expect(matchRoute("/")).toEqual({ name: "root" });
    expect(matchRoute("/orgs/acme")).toEqual({ name: "org-overview", org: "acme" });
    expect(matchRoute("/orgs/acme/")).toEqual({ name: "org-overview", org: "acme" });
    expect(matchRoute("/orgs/acme%20co")).toEqual({
      name: "org-overview",
      org: "acme co",
    });
    expect(matchRoute("/orgs")).toEqual({ name: "unknown" });
    expect(matchRoute("/orgs/acme/projects")).toEqual({ name: "unknown" });
  });
});
