import type { DevicesValue, ShownDevice } from "@comma/core/contract";
import { flush } from "@comma/test-utils/fake-clock";
import { controlIntersections } from "@comma/test-utils/intersection";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, fireEvent, render, within } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, beforeEach, expect, it } from "vitest";
import { WebSettings } from "../../../test/settingsHarness";

// Settings › Devices' runtime checks over a scripted core. Which computers the core checks (stale ones, once per
// visit, two at a time), a failed check and a check asked again, and a page that lands while a check runs are tested
// in packages/core/test/devices.test.ts.

const workspaceId = "wsp_devices";

// `getByRole({ name })` computes the accessible name of every candidate with jsdom's
// getComputedStyle; over the settings dialog that was most of this file's CPU. Cards and
// buttons are found by their markup and exact label instead.

/** The one device card (an `article` named by its `aria-label`) for `name`. */
function card(name: string) {
  const cards = [
    ...document.querySelectorAll<HTMLElement>('article[data-slot="device-card"]'),
  ].filter((article) => article.getAttribute("aria-label") === name);
  expect(cards).toHaveLength(1);
  return cards[0]!;
}

/** The state its agent row shows on the card of `name`. */
function agentStatus(name: string) {
  return card(name).querySelector(".comma-device__agent-status");
}

/** The one button in `scope` whose text is `label`. */
function buttonIn(scope: HTMLElement, label: string) {
  const buttons = [...scope.querySelectorAll("button")].filter(
    (button) => button.textContent?.trim() === label
  );
  expect(buttons).toHaveLength(1);
  return buttons[0]!;
}

beforeEach(() => {
  installNativeBridgeMock({ platform: "web" });
  localStorage.setItem("comma.activeWorkspaceId", workspaceId);
});

afterEach(() => {
  localStorage.clear();
});

const computer = (
  index: number,
  name: string,
  fresh: boolean,
  fields: Partial<ShownDevice> = {}
): ShownDevice => ({
  device_id: `dev_probe_${index}`,
  name,
  status: "connected",
  allows_operations: true,
  device_runtimes: [
    {
      device_runtime_id: `runtime_probe_${index}`,
      provider: "codex",
      status: "ready",
      fresh,
    },
  ],
  ...fields,
});

/** Settings over a core whose Devices are `value` (the test changes them with `say`). */
async function settings(initial: Partial<DevicesValue>) {
  let value: DevicesValue = {
    workspace: workspaceId,
    devices: [],
    cloud: null,
    hasMore: false,
    loading: false,
    failed: false,
    checks: {},
    ...initial,
  };
  const visits: unknown[] = [];
  const core = createScriptedCore({
    values: (topic) => (topic.topic === "devices" ? value : undefined),
    onSubscribe: (topic) => {
      if (topic.topic === "devices") visits.push(topic.visit);
    },
  });
  const say = (change: Partial<DevicesValue>) => {
    value = { ...value, ...change };
    act(() => core.changed("devices"));
  };
  render(<WebSettings core={core} />);
  await flush();
  const open = async (category: string) => {
    const nav = document.querySelector<HTMLElement>('[data-slot="settings-page"] nav')!;
    fireEvent.click(buttonIn(nav, category));
    await flush();
  };
  return { core, open, say, visits, value: () => value };
}

it("checks expired devices once per visit, two at a time, and retries on request", async () => {
  const devices = [
    computer(0, "Expired A", false),
    computer(1, "Expired B", false),
    computer(2, "Expired C", false),
    computer(3, "Fresh", true),
    computer(4, "Offline", false, { status: "disconnected" }),
    computer(5, "Read only", false, { allows_operations: false }),
  ];
  // The core checks the stale ones it may: A and B under way, C waiting its turn.
  const t = await settings({
    devices,
    checks: { dev_probe_0: "pending", dev_probe_1: "pending", dev_probe_2: "pending" },
  });
  await t.open("Devices");
  expect(t.visits).toEqual(["1"]);

  // A running check shows itself; a computer with nothing to check offers no check.
  expect(card("Expired A")).toHaveTextContent("Checking…");
  expect(card("Offline").querySelector("button")?.textContent).not.toBe("Check again");
  expect(card("Read only")).not.toHaveTextContent("Check again");

  // B and C pass, A fails.
  const passed = (index: number) =>
    t
      .value()
      .devices.map((device, at) =>
        at === index ? computer(index, device.name, true) : device
      );
  t.say({
    devices: passed(1),
    checks: { dev_probe_0: "pending", dev_probe_2: "pending" },
  });
  t.say({ devices: passed(2), checks: { dev_probe_0: "failed" } });
  await flush();
  expect(within(card("Expired A")).getByRole("alert")).toHaveTextContent(
    "Could not check agents"
  );
  expect(agentStatus("Expired A")).toHaveTextContent("Check expired");

  // Coming back to the window asks the core to read again; the page checks nothing itself.
  act(() => window.dispatchEvent(new Event("focus")));
  await flush();
  expect(t.core.sentTo("devices.refresh")).toEqual([{}]);
  expect(t.core.sentTo("devices.check")).toEqual([]);

  fireEvent.click(buttonIn(card("Expired A"), "Check again"));
  await flush();
  expect(t.core.sentTo("devices.check")).toEqual([{ device: "dev_probe_0" }]);
  t.say({ checks: { dev_probe_0: "pending" } });
  t.say({ devices: passed(0), checks: {} });
  await flush();
  // A passed check leaves nothing to say about the agent.
  expect(agentStatus("Expired A")).toBeNull();
  expect(within(card("Expired A")).queryByRole("alert")).toBeNull();

  // Its readiness runs out: the core shows it stale again.
  t.say({
    devices: t
      .value()
      .devices.map((device, at) =>
        at === 0 ? computer(0, device.name, false) : device
      ),
  });
  await flush();
  expect(agentStatus("Expired A")).toHaveTextContent("Check expired");
  expect(t.core.sentTo("devices.check")).toHaveLength(1);

  // A new visit: the page asks the core for it, and the core checks again.
  await t.open("General");
  await t.open("Devices");
  expect(t.visits).toEqual(["1", "2"]);
  t.say({ checks: { dev_probe_0: "pending" } });
  t.say({ devices: passed(0), checks: {} });
  await flush();
  expect(agentStatus("Expired A")).toBeNull();
});

it("lands a page asked for while a runtime check runs, without undoing the check", async () => {
  const intersections = controlIntersections();
  const checking = computer(0, "Checking computer", false);
  const filler = Array.from({ length: 18 }, (_, index) =>
    computer(index + 10, `Computer ${index + 1}`, false, {
      allows_operations: false,
      device_runtimes: [],
    })
  );
  try {
    const t = await settings({
      devices: [checking, ...filler],
      hasMore: true,
      checks: { dev_probe_0: "pending" },
    });
    await t.open("Devices");
    expect(card("Checking computer")).toHaveTextContent("Checking…");
    // Settings opens in a dialog portal, outside the render container.
    const end = document.querySelector('[data-slot="scroll-area-load-more"]');
    expect(end).not.toBeNull();
    act(() => intersections.reveal(end!));
    await flush();
    expect(t.core.sentTo("devices.more")).toEqual([{}]);
    // The reader leaves the end before the check completes. The requested
    // page must still finish without another arrival at the end.
    act(() => intersections.hide(end!));
    t.say({ devices: [computer(0, "Checking computer", true), ...filler], checks: {} });
    await flush();
    expect(agentStatus("Checking computer")).toBeNull();
    t.say({
      devices: [
        ...t.value().devices,
        computer(1, "Next page computer", false, { device_id: "dev_next" }),
      ],
      hasMore: false,
    });
    await flush();
    expect(card("Next page computer").querySelector("h3")).toHaveTextContent(
      "Next page computer"
    );
    expect(agentStatus("Checking computer")).toBeNull();
    // The next page carries other computers only: the check stands, and the reader never scrolled again.
    expect(t.core.sentTo("devices.more")).toEqual([{}]);
  } finally {
    intersections.restore();
  }
});

const signedInRuntime = (
  provider: string,
  auth: { status?: string; mode?: string }
) => ({
  device_runtime_id: `runtime_${provider}`,
  provider,
  status: "ready",
  fresh: true,
  auth,
});

it("names a runtime's sign-in when the station reports no login mode", async () => {
  const t = await settings({
    devices: [
      computer(0, "Signed in computer", true, {
        device_runtimes: [
          signedInRuntime("claude", { status: "authenticated" }),
          signedInRuntime("codex", { status: "authenticated", mode: "chatgpt" }),
        ],
      }),
    ],
  });
  await t.open("Devices");
  // Sign-in details are in the computer's details, opened from its menu.
  fireEvent.click(
    card("Signed in computer").querySelector(
      'button[aria-label="More actions for Signed in computer"]'
    )!
  );
  await flush();
  const details = [...document.querySelectorAll('[role="menuitem"]')].find(
    (entry) => entry.textContent === "Details"
  );
  fireEvent.click(details!);
  await flush();
  const groups = [...document.querySelectorAll(".comma-device-details__group")];
  const group = (name: string) =>
    groups.find((entry) =>
      entry.querySelector(".comma-device-details__head")?.textContent?.startsWith(name)
    );
  expect(group("Claude Code")).toHaveTextContent("AuthenticationSigned in");
  expect(group("Codex")).toHaveTextContent("AuthenticationChatGPT");
});
