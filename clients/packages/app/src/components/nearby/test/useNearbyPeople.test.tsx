import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import type { NearbyState } from "@comma/native-bridge";
import { flush } from "@comma/test-utils/fake-clock";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen, within } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import userEvent from "@testing-library/user-event";
import { beforeEach, expect, it, vi } from "vitest";
import { useNearbyPeople } from "../useNearbyPeople";

/** The settings page's use: an item that opens the list, and the list. */
function Host() {
  const nearby = useNearbyPeople("ws-a");
  if (!nearby.available) return null;
  return (
    <>
      <button onClick={nearby.open} type="button">
        Add someone nearby
      </button>
      {nearby.dialog}
    </>
  );
}

const inviteUrl = `https://comma.example/#/settings?category=task-requests&invite=${"t".repeat(43)}`;
const found: NearbyState = {
  revision: 2,
  available: true,
  scan: "done",
  peers: [{ id: "b-mac", name: "Bo’s Comma", via: "airdrop" }],
  asks: [],
  offers: [],
};

beforeEach(() => {
  initializeCommaI18n(["en"]);
});

function mount(state: NearbyState) {
  const bridge = installNativeBridgeMock({ os: "macos", platform: "electron" });
  let publish: ((state: NearbyState) => void) | undefined;
  vi.mocked(bridge.nearby.state.subscribe).mockImplementation((listener) => {
    publish = listener;
    listener(state);
    return () => undefined;
  });
  vi.mocked(bridge.nearby.find).mockResolvedValue(state);
  vi.mocked(bridge.nearby.ask).mockResolvedValue(state);
  const core = createScriptedCore({
    calls: (name) => (name === "taskRequests.createInvite" ? { inviteUrl } : null),
  });
  render(
    core.wrap(
      <CommaI18nProvider locale="en">
        <Host />
      </CommaI18nProvider>
    )
  );
  return { bridge, core, publish: (next: NearbyState) => act(() => publish?.(next)) };
}

it("looks for Comma nearby and sends the picked person a new invite", async () => {
  const { bridge, core, publish } = mount(found);
  await userEvent.click(screen.getByRole("button", { name: "Add someone nearby" }));
  expect(bridge.nearby.find).toHaveBeenCalledOnce();
  const dialog = screen.getByRole("dialog");
  expect(within(dialog).getByText("Bo")).toBeVisible();

  await userEvent.click(within(dialog).getByRole("button", { name: "Connect" }));
  await act(flush);
  expect(core.sentTo("taskRequests.createInvite")).toEqual([
    { workspace: "ws-a", mode: "review" },
  ]);
  expect(bridge.nearby.ask).toHaveBeenCalledWith({ inviteUrl, peerId: "b-mac" });

  publish({ ...found, revision: 3, asks: [{ peerId: "b-mac", status: "accepted" }] });
  expect(within(dialog).getByText("Connected")).toBeVisible();
});

it("is absent where this computer cannot look for people nearby", () => {
  mount({ ...found, available: false });
  expect(screen.queryByRole("button", { name: "Add someone nearby" })).toBeNull();
});
