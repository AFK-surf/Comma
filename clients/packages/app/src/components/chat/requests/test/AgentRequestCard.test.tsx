import type {
  AgentLocationRequest,
  AgentOAuthRequest,
  AgentPhoneRequest,
  AgentPluginRequest,
  AgentRequest,
  PluginRow,
} from "@comma/core-client";
import { act, render, screen, within } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AgentRequestCard } from "../AgentRequestCard";
import { groupAgentRequestsByAnchor } from "../agentRequestAnchor";

const devicePosition = vi.hoisted(() => vi.fn());
vi.mock("../../../apps/miniAppDevices", () => ({ location: devicePosition }));

const NOW = 1_700_000_000_000;

const request = (extra: Partial<AgentOAuthRequest> = {}): AgentOAuthRequest => ({
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

describe("An Agent's location request", () => {
  const asked = (extra: Partial<AgentLocationRequest> = {}): AgentLocationRequest => ({
    id: "cap-2",
    type: "location",
    status: "pending",
    outcome: null,
    expiresAt: NOW + 90_000,
    createdAt: NOW - 1_000,
    sourceMessageId: "msg-1",
    location: { reason: "Find cafes near you." },
    ...extra,
  });

  it("asks the device when the person shares, and sends the position to the core", async () => {
    devicePosition.mockResolvedValue({
      ok: true,
      value: { latitude: 35.67, longitude: 139.76, accuracy: 20 },
    });
    const { core } = show(asked());
    const card = screen.getByTestId("agent-request-card");
    expect(within(card).getByText("Share your location")).toBeTruthy();
    expect(within(card).getByText("Find cafes near you.")).toBeTruthy();
    await userEvent.click(screen.getByRole("button", { name: "Share location" }));
    expect(core.sentTo("agentRequests.shareLocation")).toEqual([
      {
        group: "grp-1",
        conversation: "cnv-1",
        request: "cap-2",
        latitude: 35.67,
        longitude: 139.76,
        accuracy: 20,
      },
    ]);
  });

  it("says when the system refused, sending nothing", async () => {
    devicePosition.mockResolvedValue({ ok: false, code: "denied", message: "No." });
    const { core } = show(asked());
    await userEvent.click(screen.getByRole("button", { name: "Share location" }));
    expect(screen.getByText(/Location is off for Comma/)).toBeTruthy();
    expect(core.sentTo("agentRequests.shareLocation")).toEqual([]);
  });

  it("passes a decline on and closes into a receipt without coordinates", async () => {
    const { core, rerender } = show(asked());
    await userEvent.click(screen.getByRole("button", { name: "Decline" }));
    expect(core.sentTo("agentRequests.decline")).toEqual([
      { group: "grp-1", conversation: "cnv-1", request: "cap-2" },
    ]);
    rerender(
      <AgentRequestCard
        conversationId="cnv-1"
        groupId="grp-1"
        request={asked({ status: "completed", outcome: "declined" })}
      />
    );
    expect(receipt().textContent).toContain("You did not share your location");
  });
});

describe("An Agent's connect-account request", () => {
  it("takes a secret on the card and sends it to the server, closing into a receipt without it", async () => {
    const user = userEvent.setup({ advanceTimers: (ms) => vi.advanceTimersByTime(ms) });
    const { core, rerender } = show(
      request({
        oauth: {
          provider: "secret",
          alias: "openai",
          label: "OpenAI API Key",
          reason: "The script needs it.",
          scopes: [],
          input: { kind: "secret", label: "OpenAI API Key" },
        },
      })
    );
    const card = screen.getByTestId("agent-request-card");
    expect(within(card).queryByRole("timer")).toBeNull();
    const save = within(card).getByRole("button", { name: "Save" });
    expect(
      save.getAttribute("disabled") ?? save.getAttribute("data-disabled")
    ).not.toBeNull();

    const field = within(card).getByLabelText("OpenAI API Key");
    expect(field.getAttribute("type")).toBe("password");
    await user.type(field, "sk-typed{Enter}");
    expect(core.sentTo("agentRequests.fill")).toEqual([
      {
        group: "grp-1",
        conversation: "cnv-1",
        request: "cap-1",
        values: { value: "sk-typed" },
      },
    ]);

    rerender(
      <AgentRequestCard
        conversationId="cnv-1"
        groupId="grp-1"
        request={request({
          status: "completed",
          outcome: "connected",
          oauth: {
            provider: "secret",
            alias: "openai",
            label: "OpenAI API Key",
            reason: "The script needs it.",
            scopes: [],
          },
        })}
      />
    );
    expect(receipt().textContent).toContain("Saved");
    expect(receipt().textContent).toContain("OpenAI API Key");
    expect(receipt().textContent).not.toContain("sk-typed");
  });

  it("shows a CLI login's device code and opens its page", async () => {
    const user = userEvent.setup({ advanceTimers: (ms) => vi.advanceTimersByTime(ms) });
    show(
      request({
        oauth: {
          provider: "cli",
          alias: "gh",
          reason: "Push the branch.",
          scopes: [],
          authorizationUrl: "https://github.com/login/device",
          input: { kind: "device", code: "ABCD-1234" },
        },
      })
    );
    const card = screen.getByTestId("agent-request-card");
    expect(within(card).getByText("Log in to gh CLI")).toBeTruthy();
    expect(within(card).getByText("ABCD-1234")).toBeTruthy();
    await user.click(within(card).getByRole("button", { name: "Copy code and open" }));
    expect(within(card).getByRole("button", { name: "Open again" })).toBeTruthy();
  });

  it("takes the code a CLI login's page gives and passes it on", async () => {
    const user = userEvent.setup({ advanceTimers: (ms) => vi.advanceTimersByTime(ms) });
    const { core } = show(
      request({
        oauth: {
          provider: "cli",
          alias: "gcloud",
          reason: "Deploy.",
          scopes: [],
          authorizationUrl: "https://accounts.google.com/o/oauth2/auth",
          input: { kind: "paste" },
        },
      })
    );
    const card = screen.getByTestId("agent-request-card");
    expect(within(card).getByRole("button", { name: "Submit" })).toBeTruthy();
    await user.type(within(card).getByLabelText("Code from the page"), "4/abc{Enter}");
    expect(core.sentTo("agentRequests.fill")).toEqual([
      {
        group: "grp-1",
        conversation: "cnv-1",
        request: "cap-1",
        values: { value: "4/abc" },
      },
    ]);
  });

  it("asks a Workspace's own app first, then offers its page on the same card", async () => {
    const user = userEvent.setup({ advanceTimers: (ms) => vi.advanceTimersByTime(ms) });
    const { core } = show(
      request({
        oauth: {
          provider: "lark",
          alias: "lark-ann",
          reason: "Send as you.",
          scopes: [],
          input: {
            kind: "app",
            helpUrl: "https://open.larksuite.com/app",
            redirectUri: "https://api.example.com/v1/oauth/lark/callback",
          },
        },
      })
    );
    const card = screen.getByTestId("agent-request-card");
    expect(
      within(card).getByText("https://api.example.com/v1/oauth/lark/callback")
    ).toBeTruthy();
    await user.type(within(card).getByLabelText("App ID"), "cli_own");
    await user.type(within(card).getByLabelText("App Secret"), "own-secret");
    await user.click(within(card).getByRole("button", { name: "Next" }));
    expect(core.sentTo("agentRequests.fill")).toEqual([
      {
        group: "grp-1",
        conversation: "cnv-1",
        request: "cap-1",
        values: { client_id: "cli_own", client_secret: "own-secret" },
      },
    ]);
  });

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

  it("sends a secret with fields to Comma's form, not to a provider's authorization", async () => {
    const open = vi.spyOn(window, "open").mockReturnValue(null);
    show(
      request({
        oauth: {
          provider: "secret",
          alias: "lumen-erp",
          reason: "The ERP needs an app id and a secret.",
          scopes: [],
          authorizationUrl: "https://salix.example.com/oauth/secret/form?state=s",
        },
      })
    );
    const card = screen.getByTestId("agent-request-card");
    expect(within(card).getByText("Fill in lumen-erp")).toBeTruthy();
    expect(within(card).queryByText(/Comma never sees your password/)).toBeNull();
    expect(within(card).getByText(/It never goes through the chat/)).toBeTruthy();
    expect(
      within(card).queryByRole("button", { name: /Authorize in browser/ })
    ).toBeNull();

    await userEvent.click(within(card).getByRole("button", { name: /Open form/ }));
    expect(open).toHaveBeenCalledWith(
      "https://salix.example.com/oauth/secret/form?state=s",
      "_blank",
      "noopener,noreferrer"
    );
    expect(within(card).getByText("Finish filling in the form…")).toBeTruthy();
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

describe("An Agent's request to use a phone", () => {
  const phone = (extra: Partial<AgentPhoneRequest> = {}): AgentPhoneRequest => ({
    id: "cap-p",
    type: "computer_use_start",
    status: "pending",
    outcome: null,
    expiresAt: NOW + 600_000,
    createdAt: NOW - 1_000,
    sourceMessageId: null,
    phone: {
      title: "Pixel 8 · Android 15",
      target: "android:3B162S00P0N00000",
      deviceId: "dev_mac",
    },
    ...extra,
  });

  it("passes its owner's answer on, and says when someone else may not answer", async () => {
    const core = createScriptedCore({
      calls: (name, params) => {
        if (
          name === "agentRequests.decide" &&
          (params as { approved: boolean }).approved
        )
          throw Object.assign(new Error("forbidden"), { code: "forbidden" });
        return null;
      },
    });
    render(
      <AgentRequestCard conversationId="cnv-1" groupId="grp-1" request={phone()} />,
      {
        wrapper: ({ children }) => core.wrap(children),
      }
    );
    const card = screen.getByTestId("agent-request-card");
    expect(within(card).getByText("Use Pixel 8 · Android 15?")).toBeTruthy();
    await userEvent.click(within(card).getByRole("button", { name: "Allow" }));
    expect(core.sentTo("agentRequests.decide")).toEqual([
      { group: "grp-1", conversation: "cnv-1", request: "cap-p", approved: true },
    ]);
    expect(
      await within(card).findByText("Only the phone's owner can answer this.")
    ).toBeTruthy();
    await userEvent.click(within(card).getByRole("button", { name: "Deny" }));
    expect(core.sentTo("agentRequests.decide")).toHaveLength(2);
  });

  it("closes into a receipt of the answer", () => {
    show(phone({ status: "completed", outcome: "allowed" }));
    expect(receipt().textContent).toContain("Allowed in this chat");
  });

  it("asks for a computer's simulator as the simulator it is, of that computer's owner", () => {
    show(
      phone({
        phone: {
          title: "iPhone 17 Pro · iOS 27.2",
          target: "simulator:0702F8CC-2E2A-4D0A-8401-C37FA01E1646",
          deviceId: "dev_mac",
        },
      })
    );
    const card = screen.getByTestId("agent-request-card");
    expect(within(card).getByText("Use iPhone 17 Pro · iOS 27.2?")).toBeTruthy();
    expect(
      within(card).getByText(
        "An agent in this chat asks to see and operate this simulator."
      )
    ).toBeTruthy();
    expect(
      within(card).getByText(
        "Only the owner of the computer the simulator runs on can answer."
      )
    ).toBeTruthy();
  });
});

const row = (extra: Partial<PluginRow> = {}): PluginRow => ({
  id: "notion",
  name: "Notion",
  summary: "",
  brand: "notion",
  category: "Productivity",
  installed: false,
  locked: false,
  mcps: [],
  skills: [],
  activity: "idle",
  ...extra,
});
const catalog = (plugin: PluginRow) => ({
  status: "ready",
  workspace: "wsp-1",
  plugins: [plugin],
  installed: [],
  categories: [],
});

describe("A Router's plugin install request", () => {
  const asked = (extra: Partial<AgentPluginRequest> = {}): AgentPluginRequest => ({
    id: "cap-plugin",
    type: "plugin_install",
    status: "pending",
    outcome: null,
    expiresAt: NOW + 600_000,
    createdAt: NOW - 1_000,
    sourceMessageId: "msg-1",
    plugin: {
      id: "notion",
      name: "Notion",
      reason: "To save the meeting notes in your workspace.",
      brand: "notion",
      workspace: "wsp-1",
    },
    ...extra,
  });
  function showWith(value: AgentPluginRequest, plugin: PluginRow) {
    const core = createScriptedCore({
      values: (topic) =>
        topic.topic === "plugins" && topic.workspace === "wsp-1"
          ? catalog(plugin)
          : undefined,
      calls: () => ({}),
    });
    const view = render(
      <AgentRequestCard conversationId="cnv-1" groupId="grp-1" request={value} />,
      { wrapper: ({ children }) => core.wrap(children) }
    );
    return { core, ...view };
  }

  it("adds the plugin the way the Plugins page does, and closes into the server's receipt", async () => {
    const { core, rerender } = showWith(asked(), row());
    const card = screen.getByTestId("agent-request-card");
    expect(within(card).getByText("Add Notion")).toBeTruthy();
    const add = within(card).getByRole("button", { name: "Add to Comma" });
    expect(
      add.getAttribute("disabled") ?? add.getAttribute("data-disabled")
    ).toBeNull();
    expect(
      within(card).getByText("To save the meeting notes in your workspace.")
    ).toBeTruthy();
    await userEvent.click(add);
    expect(core.sentTo("plugin.install")).toEqual([
      { plugin: "notion", workspace: "wsp-1" },
    ]);
    // Installed, here or on the Plugins page: the server ends the request.
    rerender(
      <AgentRequestCard
        conversationId="cnv-1"
        groupId="grp-1"
        request={asked({ status: "completed", outcome: "installed" })}
      />
    );
    expect(receipt().textContent).toContain("Added Notion");
  });

  it("waits while the install is under way, and shows the scan an install by a scan needs", async () => {
    const { core } = showWith(
      asked(),
      row({ activity: "scanning", scan: { url: "https://open.feishu.cn/scan/abc" } })
    );
    await act(async () => {});
    expect(screen.getByRole("dialog")).toBeTruthy();
    expect(screen.getByText("Adding…")).toBeTruthy();
    // The scan's dialog is modal: the card behind it is hidden from the accessibility tree.
    const add = screen.getByRole("button", { hidden: true, name: "Add to Comma" });
    expect(
      add.getAttribute("disabled") ?? add.getAttribute("data-disabled")
    ).not.toBeNull();
    expect(core.sentTo("plugin.install")).toEqual([]);
  });

  it("keeps the member's scan open after the bot's scan installs the plugin and ends the request", async () => {
    const { core, rerender } = showWith(
      asked(),
      row({ activity: "scanning", scan: { url: "https://open.feishu.cn/scan/bot" } })
    );
    await act(async () => {});
    expect(screen.getByRole("dialog", { name: "Connect Notion" })).toBeTruthy();
    // A new Lark/Feishu install is installed (the server ends the request) before the member's own sign-in.
    rerender(
      <AgentRequestCard
        conversationId="cnv-1"
        groupId="grp-1"
        request={asked({ status: "completed", outcome: "installed" })}
      />
    );
    await act(async () => {
      core.emit(
        "plugins",
        catalog(
          row({
            installed: true,
            activity: "scanning",
            scan: { url: "https://open.feishu.cn/scan/member", step: "member" },
          })
        )
      );
    });
    expect(
      screen.getByRole("dialog", { name: "Let your Routine read Notion" })
    ).toBeTruthy();
    expect(receipt().textContent).toContain("Added Notion");
    await act(async () => {
      core.emit("plugins", catalog(row({ installed: true })));
    });
    expect(screen.queryByRole("dialog")).toBeNull();
  });

  it("lets an install waiting on the browser start again, as the Plugins page does", async () => {
    const { core } = showWith(asked(), row({ activity: "authorizing" }));
    await act(async () => {});
    expect(screen.getByText("Finish authorizing in your browser…")).toBeTruthy();
    await userEvent.click(screen.getByRole("button", { name: "Open again" }));
    expect(core.sentTo("plugin.install")).toEqual([
      { plugin: "notion", workspace: "wsp-1" },
    ]);
  });

  it("passes a decline on, and closes into the receipt the server answers with", async () => {
    const { core, rerender } = showWith(asked(), row());
    await userEvent.click(screen.getByRole("button", { name: "Decline" }));
    expect(core.sentTo("agentRequests.decline")).toEqual([
      { group: "grp-1", conversation: "cnv-1", request: "cap-plugin" },
    ]);
    rerender(
      <AgentRequestCard
        conversationId="cnv-1"
        groupId="grp-1"
        request={asked({ status: "completed", outcome: "declined" })}
      />
    );
    expect(receipt().textContent).toContain("You did not add Notion");
  });
});
