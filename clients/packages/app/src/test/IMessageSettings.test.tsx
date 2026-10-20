import type { IMessageValue } from "@comma/core-client";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import { installUiClock } from "@comma/ui/clock";
import { createVirtualUiClock, type VirtualUiClock } from "@comma/ui/clock/virtual";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { messagesLink } from "../components/imessage/IMessageSettings";
import { jsonResponse, WebSettings } from "./settingsHarness";

const workspaceId = "wsp_imessage";
const phone = "+14155550123";
const line = "+15559990000";
const start = Date.UTC(2026, 9, 19, 12);

let clock: VirtualUiClock;
let restoreClock: () => void;
let opened: string[];

beforeEach(() => {
  installNativeBridgeMock({ platform: "web" });
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => jsonResponse({ data: [] }))
  );
  opened = [];
  vi.stubGlobal("open", (url: string) => {
    opened.push(url);
    return null;
  });
  clock = createVirtualUiClock({ start });
  restoreClock = installUiClock(clock);
});

afterEach(() => {
  restoreClock();
  vi.unstubAllGlobals();
});

const setting = (id: string) =>
  document.querySelector<HTMLElement>(`[data-setting-id="${id}"]`);

type Shape = {
  configured?: boolean;
  attempt?: { expiresInSeconds: number } | null;
  link?: boolean;
};

function value({
  configured = true,
  attempt = null,
  link = false,
}: Shape): IMessageValue {
  return {
    state: {
      photon_configured: configured,
      connection_active: link,
      photon_online: true,
      pending_claim: attempt
        ? {
            code: "Abc123_xyZ",
            expires_at: Math.floor(start / 1000) + attempt.expiresInSeconds,
            transport: "photon",
            sender_handle: phone,
            line_handle: line,
          }
        : null,
      link: link
        ? {
            sender_handle: phone,
            transport: "photon",
            connection_id: "imc-1",
            connected_at: 1_700_000_000,
          }
        : null,
    },
    error: false,
    busy: false,
  };
}

/** Settings › Channels over a core whose iMessage is `imessage`; `refuse` fails `imessage.start` with that code. */
async function channels(imessage: IMessageValue, refuse?: string) {
  const calls: [string, unknown][] = [];
  const core = createScriptedCore({
    owns: (name) => /^(telegram|wechat|signal|imessage)/.test(name),
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
          : topic.topic === "imessage"
            ? imessage
            : undefined,
    calls: (name, params) => {
      calls.push([name, params]);
      if (name === "imessage.start" && refuse)
        throw Object.assign(new Error(refuse), { code: refuse });
      return null;
    },
  });
  const user = userEvent.setup();
  render(<WebSettings core={core} />);
  await user.click(await screen.findByRole("button", { name: "Channels" }));
  const named = (name: string) => calls.filter(([n]) => n === name).map(([, p]) => p);
  return { core, user, named };
}

it("stays hidden unless the server has Photon iMessage set up", async () => {
  await channels(value({ configured: false }));
  await waitFor(() => expect(setting("telegram.connection")).not.toBeNull());
  expect(setting("imessage.connection")).toBeNull();
});

it("asks for the phone number, checks its format, and starts with the normalized number", async () => {
  const t = await channels(value({}));
  await waitFor(() =>
    expect(setting("imessage.connection")).toHaveTextContent("Not connected")
  );
  await t.user.click(
    within(setting("imessage.connection")!).getByRole("button", { name: "Connect" })
  );
  // The card's content folds open on the UI clock.
  act(() => clock.advance(1_000));
  const field = await screen.findByLabelText(/Your iMessage phone number or email/);
  await t.user.type(field, "4155550123");
  await t.user.click(screen.getByRole("button", { name: "Get code" }));
  expect(
    await screen.findByText(/Enter an iMessage email address or a full phone number/)
  ).toBeVisible();
  expect(t.named("imessage.start")).toEqual([]);

  await t.user.clear(field);
  await t.user.type(field, "+1 (415) 555-0123");
  await t.user.click(screen.getByRole("button", { name: "Get code" }));
  await waitFor(() =>
    expect(t.named("imessage.start")).toEqual([
      { workspace: workspaceId, handle: phone },
    ])
  );
});

it("says why a start was refused", async () => {
  const t = await channels(value({}), "invalid_imessage_handle");
  await waitFor(() => expect(setting("imessage.connection")).not.toBeNull());
  await t.user.click(
    within(setting("imessage.connection")!).getByRole("button", { name: "Connect" })
  );
  // The card's content folds open on the UI clock.
  act(() => clock.advance(1_000));
  await t.user.type(
    await screen.findByLabelText(/Your iMessage phone number or email/),
    phone
  );
  await t.user.click(screen.getByRole("button", { name: "Get code" }));
  expect(
    await screen.findByText(
      "Comma could not use this account. Check the phone number or email and try again."
    )
  ).toBeVisible();
});

it("shows the line, the code and the time left, opens Messages with the code, expires, and connects", async () => {
  const t = await channels(value({ attempt: { expiresInSeconds: 600 } }));
  const panel = await screen.findByTestId("imessage-code");
  expect(within(panel).getByTestId("imessage-line")).toHaveTextContent(line);
  expect(within(panel).getByTestId("imessage-code-value")).toHaveTextContent(
    "Abc123_xyZ"
  );
  expect(panel).toHaveTextContent(`from ${phone}`);
  expect(screen.getByTestId("imessage-expiry")).toHaveTextContent("Expires in 10:00");
  expect(setting("imessage.connection")).toHaveTextContent("Connecting");

  act(() => clock.advance(61_000));
  expect(screen.getByTestId("imessage-expiry")).toHaveTextContent("Expires in 8:59");

  await t.user.click(within(panel).getByRole("button", { name: "Open in Messages" }));
  expect(opened).toEqual([messagesLink(line, "Abc123_xyZ")]);
  expect(opened[0]).toBe("sms:%2B15559990000&body=Abc123_xyZ");

  // Ten minutes on, the code is no use: a new one for the same number, or another number.
  act(() => clock.advance(540_000));
  expect(await screen.findByTestId("imessage-expired")).toHaveTextContent(
    "This code expired"
  );
  expect(setting("imessage.connection")).toHaveTextContent("Needs attention");
  await t.user.click(screen.getByRole("button", { name: "Get a new code" }));
  await waitFor(() =>
    expect(t.named("imessage.start")).toEqual([
      { workspace: workspaceId, handle: phone },
    ])
  );

  // The person texted the code: the core shows the link.
  act(() => t.core.emit("imessage", value({ link: true })));
  await waitFor(() =>
    expect(setting("imessage.connection")).toHaveTextContent("Connected")
  );
  expect(setting("imessage.connection")).toHaveTextContent(phone);
  expect(screen.queryByTestId("imessage-code")).toBeNull();
});

it("cancels an attempt and disconnects a connection", async () => {
  const t = await channels(value({ attempt: { expiresInSeconds: 600 } }));
  await t.user.click(
    within(await waitFor(() => setting("imessage.connection")!)).getByRole("button", {
      name: "Cancel connection",
    })
  );
  await waitFor(() =>
    expect(t.named("imessage.cancel")).toEqual([{ workspace: workspaceId }])
  );

  act(() => t.core.emit("imessage", value({ link: true })));
  await waitFor(() =>
    expect(setting("imessage.connection")).toHaveTextContent("Connected")
  );
  await t.user.click(
    within(setting("imessage.connection")!).getByRole("button", { name: "Manage" })
  );
  await t.user.click(await screen.findByRole("menuitem", { name: "Disconnect" }));
  await waitFor(() =>
    expect(t.named("imessage.disconnect")).toEqual([{ workspace: workspaceId }])
  );
});
