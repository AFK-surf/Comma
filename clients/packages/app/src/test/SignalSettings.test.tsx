import type { SignalValue } from "@comma/core-client";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { jsonResponse, WebSettings } from "./settingsHarness";

const workspaceId = "wsp_signal";
const platform = "+15550100001";
const own = "+15550100002";
const command = "comma connect ABCD-EFGH";

beforeEach(() => {
  installNativeBridgeMock({ platform: "web" });
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => jsonResponse({ data: [] }))
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
});

const setting = (id: string) =>
  document.querySelector<HTMLElement>(`[data-setting-id="${id}"]`);

const alice = {
  binding_id: "sgb_alice",
  kind: "user" as const,
  peer: "00000000-0000-4000-8000-000000000011",
  display_name: "Alice",
  bound_at: 1_700_000_000_000,
  number: platform,
};

function value(
  claims: { claim_id: string; expires_at: number }[],
  bindings: NonNullable<SignalValue["integration"]>["bindings"],
  override: string | null = null
): SignalValue {
  return {
    integration: {
      account: { e164: override ?? platform, state: "active" },
      bindings,
      pending_claims: claims,
    },
    number: {
      override: override ? { e164: override, state: "active" } : null,
      platform: { e164: platform, state: "active" },
      effective: { e164: override ?? platform, state: "active" },
    },
    error: false,
    busy: false,
  };
}

/** Settings › Channels over a core whose Signal is `signal`; the calls it gets are noted. */
async function channels(signal: SignalValue) {
  const calls: [string, unknown][] = [];
  const core = createScriptedCore({
    owns: (name) => /^(telegram|wechat|signal)/.test(name),
    values: (topic) =>
      topic.topic === "telegram"
        ? {
            workspace: workspaceId,
            state: null,
            attempt: null,
            checks: 0,
            error: false,
            busy: false,
          }
        : topic.topic === "wechat"
          ? { state: { connection: null, pending: null }, error: false, busy: false }
          : topic.topic === "signal"
            ? signal
            : undefined,
    calls: (name, params) => {
      calls.push([name, params]);
      return name === "signal.newCode"
        ? { claimId: "sgc_1", command, number: platform }
        : null;
    },
  });
  const user = userEvent.setup();
  render(<WebSettings core={core} />);
  await user.click(await screen.findByRole("button", { name: "Channels" }));
  await waitFor(() => expect(setting("signal.connection")).not.toBeNull());
  const named = (name: string) => calls.filter(([n]) => n === name).map(([, p]) => p);
  return { core, user, named };
}

// Settings › Channels › Signal: a connection code is shown once, a connected chat can be disconnected, and the
// workspace number is shown without a way to change it.
it("shows a new code once, the unused code, the new chat, and disconnects a chat", async () => {
  const t = await channels(value([], [alice]));
  await waitFor(() =>
    expect(setting("signal.connection")).toHaveTextContent("Connected")
  );
  await t.user.click(
    within(setting("signal.connection")!).getByRole("button", { name: "New code" })
  );
  await waitFor(() =>
    expect(t.named("signal.newCode")).toEqual([{ workspace: workspaceId }])
  );
  // The core now lists the code as unused: the message to send shows once, with the number to send it to.
  act(() =>
    t.core.emit(
      "signal",
      value([{ claim_id: "sgc_1", expires_at: 1_900_000_000_000 }], [alice])
    )
  );
  expect(await screen.findByTestId("signal-code-message")).toHaveTextContent(command);
  expect(screen.getByTestId("signal-code")).toHaveTextContent(platform);
  await t.user.click(
    within(screen.getByTestId("signal-code")).getByRole("button", { name: "Done" })
  );
  await waitFor(() => expect(screen.queryByText(command)).toBeNull());
  expect(setting("signal.claim.sgc_1")).toHaveTextContent("Unused code");
  expect(setting("signal.connection")).toHaveTextContent("Connecting");

  // The code is sent from a Signal group: the core lists the chat and drops the code.
  act(() =>
    t.core.emit(
      "signal",
      value(
        [],
        [
          alice,
          {
            binding_id: "sgb_team",
            kind: "group",
            peer: "group:team",
            display_name: "Team",
            bound_at: 1_700_000_100_000,
            number: platform,
          },
        ]
      )
    )
  );
  await waitFor(() =>
    expect(setting("signal.chat.sgb_team")).toHaveTextContent("Team")
  );
  expect(setting("signal.claim.sgc_1")).toBeNull();
  expect(setting("signal.connection")).not.toHaveTextContent("Connecting");

  // Disconnect a connected chat after confirmation.
  await t.user.click(
    within(setting("signal.chat.sgb_alice")!).getByRole("button", {
      name: "Disconnect (Alice)",
    })
  );
  await t.user.click(
    within(
      await screen.findByRole("dialog", { name: "Disconnect this Signal chat?" })
    ).getByRole("button", { name: "Disconnect" })
  );
  await waitFor(() =>
    expect(t.named("signal.disconnect")).toEqual([
      { workspace: workspaceId, binding: "sgb_alice" },
    ])
  );

  // The workspace number is shown; changing it is not offered.
  expect(setting("signal.number")).toHaveTextContent(
    `Uses the Comma number ${platform}.`
  );
  expect(within(setting("signal.number")!).queryByRole("button")).toBeNull();
});

it("shows a preset own number the same way, without a way back", async () => {
  await channels(value([], [alice], own));
  await waitFor(() =>
    expect(setting("signal.number")).toHaveTextContent(
      `Uses this workspace's own number ${own}.`
    )
  );
  expect(within(setting("signal.number")!).queryByRole("button")).toBeNull();
});
