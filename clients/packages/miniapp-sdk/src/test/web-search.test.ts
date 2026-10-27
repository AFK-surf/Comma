import { describe, expect, it } from "vitest";
import { createMockComma } from "../mock";

describe("web search in local apps", () => {
  it("uses supplied results and checks the grant and query", async () => {
    const results = [
      { title: "Example", url: "https://example.test", text: "An excerpt" },
    ];
    const queries: string[] = [];
    const comma = createMockComma({
      capabilities: ["web.search"],
      grants: [],
      webSearch: (query) => {
        queries.push(query);
        return results;
      },
    });
    expect(comma.supports("web.search")).toBe(true);
    await expect(comma.web.search("Example")).rejects.toMatchObject({
      code: "not_granted",
    });
    comma.mock.setGrants(["web.search"]);
    await expect(comma.web.search(" ")).rejects.toMatchObject({ code: "invalid" });
    expect(await comma.web.search(" Example ")).toEqual(results);
    expect(queries).toEqual(["Example"]);
    expect(await createMockComma().web.search("Example")).toEqual([]);
    const guest = createMockComma({
      viewer: { id: "guest", name: "Guest", avatarUrl: null, guest: true },
      grants: [],
    });
    await expect(guest.web.search("Example")).rejects.toMatchObject({
      code: "signup_required",
    });
  });
});
