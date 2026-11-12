import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import type { NearbyState } from "@comma/native-bridge";
import { flush } from "@comma/test-utils/fake-clock";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import userEvent from "@testing-library/user-event";
import { beforeEach, expect, it, vi } from "vitest";
import { NearbyInvites } from "../NearbyInvites";

const workspace = { id: "ws-b", groupId: "grp-b", name: "Bo's workspace" };
const invite = "t".repeat(43);
const requestId = "11111111-1111-4111-8111-111111111111";
const held: NearbyState = {
  revision: 1,
  available: true,
  scan: "idle",
  peers: [],
  asks: [],
  offers: [{ invite, requestId, senderName: "Ada’s Comma", surfaceId: "win_main" }],
};

beforeEach(() => {
  initializeCommaI18n(["en"]);
});

/** `accepted` holds the core's answer to acceptInvite until the test settles it. */
function mount(state: NearbyState, accepted?: Promise<unknown>) {
  const bridge = installNativeBridgeMock({
    os: "macos",
    platform: "electron",
    self: { role: "main-window", windowId: "win_main" },
  });
  vi.mocked(bridge.nearby.state.subscribe).mockImplementation((listener) => {
    listener(state);
    return () => undefined;
  });
  vi.mocked(bridge.nearby.answer).mockResolvedValue({ ...state, offers: [] });
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "workspace"
        ? { status: "ready", workspace, selected: true }
        : undefined,
    calls: (name) =>
      name === "taskRequests.invitePreview"
        ? {
            workspace: {
              id: "ws-a",
              name: "Ada's workspace",
              owner: { id: "u1", name: "Ada Lin", email: "ada@example.com" },
            },
            own: false,
            back: { workspace: { id: "ws-b", name: "Bo's workspace" }, mode: "review" },
            expiresAt: null,
          }
        : name === "taskRequests.acceptInvite"
          ? (accepted ?? { reciprocal: true })
          : null,
  });
  render(
    core.wrap(<CommaI18nProvider locale="en">{<NearbyInvites />}</CommaI18nProvider>)
  );
  return { bridge, core };
}

it("shows whose invite came over AirDrop, accepts it in the core, then answers the offer", async () => {
  const { bridge, core } = mount(held);
  await act(flush);
  expect(
    screen.getByRole("heading", { name: "Ada Lin wants to connect" })
  ).toBeVisible();
  expect(screen.getByText("ada@example.com")).toBeVisible();
  expect(core.sentTo("taskRequests.invitePreview")).toEqual([
    { invite, workspace: "ws-b" },
  ]);

  await userEvent.click(screen.getByRole("button", { name: "Connect" }));
  await act(flush);
  // Accepting in Bo's workspace lets Ada send back to it.
  expect(core.sentTo("taskRequests.acceptInvite")).toEqual([
    { invite, workspace: "ws-b" },
  ]);
  expect(bridge.nearby.answer).toHaveBeenCalledWith({ accept: true, requestId });
  expect(screen.getByRole("heading", { name: "Connected" })).toBeVisible();
});

it("declines the offer when the card is closed", async () => {
  const { bridge, core } = mount(held);
  await act(flush);
  await userEvent.click(screen.getByRole("button", { name: "Close" }));
  expect(bridge.nearby.answer).toHaveBeenCalledWith({ accept: false, requestId });
  expect(core.sentTo("taskRequests.acceptInvite")).toEqual([]);
});

it("keeps the offer while Connect is accepting", async () => {
  let settle!: (value: unknown) => void;
  const { bridge } = mount(
    held,
    new Promise((resolve) => {
      settle = resolve;
    })
  );
  await act(flush);
  // Connect starts accepting; closing meanwhile must not decline what the core is accepting.
  await userEvent.click(screen.getByRole("button", { name: "Connect" }));
  expect(screen.getByRole("button", { name: "Close" })).toBeDisabled();
  expect(bridge.nearby.answer).not.toHaveBeenCalled();
  await act(async () => {
    settle({ reciprocal: true });
    await flush();
  });
  expect(bridge.nearby.answer).toHaveBeenCalledTimes(1);
  expect(bridge.nearby.answer).toHaveBeenCalledWith({ accept: true, requestId });
});

it("says the connection is one way when they cannot send back", async () => {
  const { bridge } = mount(held, Promise.resolve({ reciprocal: false }));
  await act(flush);
  await userEvent.click(screen.getByRole("button", { name: "Connect" }));
  await act(flush);
  expect(bridge.nearby.answer).toHaveBeenCalledWith({ accept: true, requestId });
  expect(
    screen.getByText(
      "You can now send Ada Lin task requests. They can send you some once you give them an invite."
    )
  ).toBeVisible();
});

it("leaves an offer for another window alone", async () => {
  const { core } = mount({
    ...held,
    offers: [{ ...held.offers[0]!, surfaceId: "win_other" }],
  });
  await act(flush);
  expect(screen.queryByRole("heading")).toBeNull();
  expect(core.sentTo("taskRequests.invitePreview")).toEqual([]);
});
