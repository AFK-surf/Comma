import type { LineValue } from "@comma/core-client";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import { installUiClock } from "@comma/ui/clock";
import { createVirtualUiClock, type VirtualUiClock } from "@comma/ui/clock/virtual";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { jsonResponse, WebSettings } from "./settingsHarness";

const workspaceId = "wsp_line";
const start = Date.UTC(2026, 10, 10, 12);
const messageUrl = "https://line.me/R/oaMessage/%40comma/?link%20ABCD2345";

let clock: VirtualUiClock;
let restoreClock: () => void;

beforeEach(() => {
  installNativeBridgeMock({ platform: "web" });
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => jsonResponse({ data: [] }))
  );
  clock = createVirtualUiClock({ start });
  restoreClock = installUiClock(clock);
});

afterEach(() => {
  restoreClock();
  vi.unstubAllGlobals();
});

const setting = (id: string) =>
  document.querySelector<HTMLElement>(`[data-setting-id="${id}"]`);

function value({
  configured = true,
  attempt = false,
  link = false,
}: {
  configured?: boolean;
  attempt?: boolean;
  link?: boolean;
}): LineValue {
  return {
    state: {
      configured,
      basic_id: configured ? "@comma" : null,
      connection_active: link,
      pending_claim: attempt
        ? {
            code: "ABCD2345",
            expires_at: Math.floor(start / 1000) + 600,
            message_url: messageUrl,
          }
        : null,
      link: link
        ? {
            line_user_id: "U1234",
            line_display_name: "Alice",
            connection_id: "imc-1",
            connected_at: 1_700_000_000,
          }
        : null,
    },
    error: false,
    busy: false,
  };
}

/** Settings › Channels over a core whose LINE is `line`. */
async function channels(line: LineValue) {
  const calls: [string, unknown][] = [];
  const core = createScriptedCore({
    owns: (name) => /^(telegram|wechat|signal|imessage|line)/.test(name),
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
          : topic.topic === "line"
            ? line
            : undefined,
    calls: (name, params) => {
      calls.push([name, params]);
      return null;
    },
  });
  const user = userEvent.setup();
  render(<WebSettings core={core} />);
  await user.click(await screen.findByRole("button", { name: "Channels" }));
  const named = (name: string) => calls.filter(([n]) => n === name).map(([, p]) => p);
  return { user, named };
}

it("stays hidden unless the server has Comma's LINE account set up", async () => {
  await channels(value({ configured: false }));
  await waitFor(() => expect(setting("telegram.connection")).not.toBeNull());
  expect(setting("line.connection")).toBeNull();
});

it("connects, then shows the code with a QR code and the link that opens LINE", async () => {
  const t = await channels(value({}));
  await waitFor(() =>
    expect(setting("line.connection")).toHaveTextContent("Not connected")
  );
  await t.user.click(
    within(setting("line.connection")!).getByRole("button", { name: "Connect" })
  );
  await waitFor(() =>
    expect(t.named("line.start")).toEqual([{ workspace: workspaceId }])
  );
});

it("shows an attempt's command and QR code, and offers a new code once it expires", async () => {
  const t = await channels(value({ attempt: true }));
  act(() => clock.advance(1_000));
  const panel = await screen.findByTestId("line-code");
  expect(within(panel).getByTestId("line-command")).toHaveTextContent("link ABCD2345");
  expect(panel).toHaveTextContent("@comma");
  expect(
    within(panel).getByRole("figure", { name: "LINE connection QR code" })
  ).toBeVisible();

  act(() => clock.advance(600_000));
  await waitFor(() => expect(screen.queryByTestId("line-code")).toBeNull());
  await t.user.click(
    within(setting("line.connection")!).getByRole("button", { name: "Get a new code" })
  );
  await waitFor(() =>
    expect(t.named("line.start")).toEqual([{ workspace: workspaceId }])
  );
});

it("names the connected LINE account", async () => {
  await channels(value({ link: true }));
  await waitFor(() =>
    expect(setting("line.connection")).toHaveTextContent("Connected")
  );
  expect(setting("line.connection")).toHaveTextContent("Alice");
});
