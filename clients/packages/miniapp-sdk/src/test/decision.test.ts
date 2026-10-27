import { describe, expect, it } from "vitest";
import { createMockComma } from "../mock";
import type { MiniAppDecisionRequest, MiniAppDecisionResult } from "../sdk";

describe("decision calls in local apps", () => {
  it("uses the shared AI grant and an explicit decision handler", async () => {
    const request: MiniAppDecisionRequest = {
      state: "Schedule a meeting",
      questions: { relevant: { type: "noul", instructions: "Does this need action?" } },
    };
    const answer: MiniAppDecisionResult = {
      model: "local-fixture",
      answers: { relevant: { type: "noul", probability_bp: 9000 } },
    };
    const calls: MiniAppDecisionRequest[] = [];
    const comma = createMockComma({
      capabilities: ["ai.chat"],
      grants: [],
      aiDecide: (args) => {
        calls.push(args);
        return answer;
      },
    });
    expect(comma.supports("ai.decide")).toBe(true);
    await expect(comma.ai.decide(request)).rejects.toMatchObject({
      code: "not_granted",
    });
    expect(calls).toEqual([]);
    comma.mock.setGrants(["ai.chat"]);
    expect(await comma.ai.decide(request)).toEqual(answer);
    expect(await comma.ai.chat([{ role: "user", content: "Hello" }])).toEqual({
      role: "assistant",
      content: "Mock reply to: Hello",
    });
    expect(calls).toEqual([request]);
    comma.mock.setGrants([]);
    await expect(comma.ai.decide(request)).rejects.toMatchObject({
      code: "not_granted",
    });
    await expect(
      comma.ai.chat([{ role: "user", content: "Hello" }])
    ).rejects.toMatchObject({ code: "not_granted" });
    await expect(createMockComma().ai.decide(request)).rejects.toMatchObject({
      code: "unavailable",
    });
    const guest = createMockComma({
      viewer: { id: "guest", name: "Guest", avatarUrl: null, guest: true },
      aiDecide: () => {
        throw new Error("Guests must not reach the model.");
      },
    });
    await expect(guest.ai.decide(request)).rejects.toMatchObject({
      code: "signup_required",
    });
    await expect(
      guest.ai.chat([{ role: "user", content: "Hello" }])
    ).rejects.toMatchObject({ code: "signup_required" });
  });
});
