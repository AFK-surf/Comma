import type { AgentRequest } from "@comma/core-client";
import { act, render, screen, within } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AgentRequestCard } from "../AgentRequestCard";
import { groupAgentRequestsByAnchor } from "../agentRequestAnchor";

const NOW = 1_700_000_000_000;

const request = (extra: Partial<AgentRequest> = {}): AgentRequest => ({
  id: "cap-1",
  type: "oauth_authorization",
  status: "pending",
  outcome: null,
  expiresAt: NOW + 90_000,
  createdAt: NOW - 1_000,
  sourceMessageId: "msg-1",
  oauth: {
    provider: "github",
    alias: "github",
    reason: "An app keeps its code in GitHub.",
    scopes: ["repo", "read:org"],
    authorizationUrl: "https://github.com/login/oauth/authorize?state=s",
  },
  ...extra,
});

function show(value: AgentRequest) {
  const core = createScriptedCore();
  const view = render(
    <AgentRequestCard conversationId="cnv-1" groupId="grp-1" request={value} />,
    { wrapper: ({ children }) => core.wrap(children) }
  );
  return { core, ...view };
}

const receipt = () => screen.getByTestId("agent-request-receipt");

// jsdom tests run on the fake clock setup-clock.ts installs: set its time, and move it.
beforeEach(() => {
  vi.setSystemTime(NOW);
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("An Agent's connect-account request", () => {
  it("asks with the Agent's reason, opens the provider's page, and waits for the browser", async () => {
    const open = vi.spyOn(window, "open").mockReturnValue(null);
    show(request());
    const card = screen.getByTestId("agent-request-card");
    expect(within(card).getByText("Connect GitHub")).toBeTruthy();
    expect(within(card).getByText("An app keeps its code in GitHub.")).toBeTruthy();
    expect(within(card).getByText("repo, read:org")).toBeTruthy();
    expect(within(card).getByRole("timer").textContent).toBe("Expires in 1:30");

    await userEvent.click(
      within(card).getByRole("button", { name: /Authorize in browser/ })
    );
    expect(open).toHaveBeenCalledWith(
      "https://github.com/login/oauth/authorize?state=s",
      "_blank",
      "noopener,noreferrer"
    );
    // The card waits for the browser and can open the page again.
    expect(within(card).getByText("Finish authorizing in your browser…")).toBeTruthy();
    expect(within(card).getByRole("button", { name: /Open again/ })).toBeTruthy();
  });

  it("passes a decline on to the core", async () => {
    const { core } = show(request());
    await userEvent.click(screen.getByRole("button", { name: "Decline" }));
    expect(core.sentTo("agentRequests.decline")).toEqual([
      { group: "grp-1", conversation: "cnv-1", request: "cap-1" },
    ]);
  });

  it("closes into a receipt of how it ended", () => {
    const { rerender } = show(
      request({
        status: "completed",
        outcome: "connected",
        oauth: {
          provider: "github",
          alias: "github",
          reason: "An app keeps its code in GitHub.",
          scopes: [],
          account: "octocat",
        },
      })
    );
    expect(receipt().textContent).toContain("Connected GitHub");
    expect(receipt().textContent).toContain("octocat");
    expect(screen.queryByRole("button")).toBeNull();

    rerender(
      <AgentRequestCard
        conversationId="cnv-1"
        groupId="grp-1"
        request={request({ status: "completed", outcome: "declined" })}
      />
    );
    expect(receipt().textContent).toContain("You did not connect GitHub");

    rerender(
      <AgentRequestCard
        conversationId="cnv-1"
        groupId="grp-1"
        request={request({ status: "cancelled" })}
      />
    );
    expect(receipt().textContent).toContain("The Agent withdrew this request");
  });

  it("expires on screen when its deadline passes, though the server has not said so", () => {
    show(request({ expiresAt: NOW + 2_000 }));
    expect(screen.getByRole("timer").textContent).toBe("Expiring soon · 0:02");
    act(() => vi.advanceTimersByTime(2_000));
    expect(receipt().textContent).toContain("The request expired");
  });
});

describe("Where a request's card sits", () => {
  const messages = [
    { messageId: "msg-1", role: "user" },
    { messageId: "reply-1", role: "assistant" },
    { messageId: "msg-2", role: "user" },
  ];

  it("under the Agent's reply to the message its turn served, else on the newest turn", () => {
    const answered = request({ id: "cap-1", sourceMessageId: "msg-1" });
    const waiting = request({ id: "cap-2", sourceMessageId: "msg-2" });
    expect(groupAgentRequestsByAnchor([waiting, answered], messages)).toEqual([
      { messageId: "reply-1", requests: [answered] },
      { messageId: undefined, requests: [waiting] },
    ]);
  });

  it("leaves out a finished request whose turn is not loaded, rather than on the newest turn", () => {
    const waiting = request({ id: "cap-1", sourceMessageId: "msg-2" });
    const older = request({
      id: "cap-2",
      sourceMessageId: "msg-0",
      status: "completed",
      outcome: "connected",
    });
    const unsourced = request({
      id: "cap-3",
      sourceMessageId: null,
      status: "expired",
    });
    expect(groupAgentRequestsByAnchor([waiting, older, unsourced], messages)).toEqual([
      { messageId: undefined, requests: [waiting] },
    ]);
  });
});
