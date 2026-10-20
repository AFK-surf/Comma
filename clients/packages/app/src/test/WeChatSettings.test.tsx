import type { WeChatConnection, WeChatValue } from "@comma/core-client";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { jsonResponse, WebSettings } from "./settingsHarness";

const workspaceId = "wsp_wechat";
const card = () =>
  within(document.querySelector<HTMLElement>('[data-setting-id="wechat.connection"]')!);

beforeEach(() => {
  installNativeBridgeMock({ platform: "web" });
  // Settings' own reads outside the channels the core answers.
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => jsonResponse({ data: [] }))
  );
  // jsdom has no canvas; the QR figure still renders around it.
  vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue(null);
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

const attempt = (extra: Partial<WeChatConnection> = {}): WeChatConnection => ({
  connect_id: "attempt-1",
  status: "pending",
  login_status: "wait",
  connection_active: false,
  qrcode_url: "https://weixin.qq.com/test-qr",
  expires_at: 1_900_000_000,
  ...extra,
});

/** Settings › Channels over a core whose WeChat is `wechat`; the calls it gets are noted. */
async function channels(wechat: WeChatValue) {
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
          ? wechat
          : topic.topic === "signal"
            ? { integration: null, number: null, error: false, busy: false }
            : undefined,
    calls: (name, params) => {
      calls.push([name, params]);
      return null;
    },
  });
  const user = userEvent.setup();
  render(<WebSettings core={core} />);
  await user.click(await screen.findByRole("button", { name: "Channels" }));
  await waitFor(() => expect(card().getByText("WeChat")).toBeInTheDocument());
  const named = (name: string) => calls.filter(([n]) => n === name).map(([, p]) => p);
  return { core, user, named };
}

const ready = (state: WeChatValue["state"], extra: Partial<WeChatValue> = {}) => ({
  state,
  error: false,
  busy: false,
  ...extra,
});

it("asks the core to connect, and shows the QR code of the attempt under way", async () => {
  const t = await channels(ready({ connection: null, pending: null }));
  await t.user.click(card().getByRole("button", { name: "Connect" }));
  await waitFor(() =>
    expect(t.named("wechat.start")).toEqual([{ workspace: workspaceId }])
  );
  act(() => t.core.emit("wechat", ready({ connection: null, pending: attempt() })));
  expect(
    await card().findByRole("figure", { name: "WeChat connection QR code" })
  ).toBeInTheDocument();
  await t.user.click(card().getByRole("button", { name: "Cancel connection" }));
  await waitFor(() =>
    expect(t.named("wechat.cancel")).toEqual([{ workspace: workspaceId }])
  );
});

it("takes the pairing code WeChat asks for, and shows the connection", async () => {
  const t = await channels(
    ready({ connection: null, pending: attempt({ login_status: "need_verifycode" }) })
  );
  await t.user.type(
    await card().findByRole("textbox", { name: "Pairing code" }),
    "12a3456"
  );
  await t.user.click(card().getByRole("button", { name: "Confirm code" }));
  await waitFor(() =>
    expect(t.named("wechat.verify")).toEqual([
      { workspace: workspaceId, code: "123456" },
    ])
  );
  act(() =>
    t.core.emit(
      "wechat",
      ready({
        connection: attempt({
          status: "connected",
          login_status: "confirmed",
          connection_active: true,
          qrcode_url: null,
          wechat_id: "alice",
        }),
        pending: null,
      })
    )
  );
  expect(await card().findByText("Connected")).toBeInTheDocument();
  expect(card().getByText("alice")).toBeInTheDocument();
  await t.user.click(card().getByRole("button", { name: "Manage" }));
  await t.user.click(await screen.findByRole("menuitem", { name: "Disconnect" }));
  await waitFor(() =>
    expect(t.named("wechat.disconnect")).toEqual([{ workspace: workspaceId }])
  );
});

it("offers a new QR code for an expired attempt, and Refresh after a failure", async () => {
  const t = await channels(
    ready({ connection: null, pending: attempt({ login_status: "expired" }) })
  );
  expect(
    await card().findByRole("button", { name: "Create new QR code" })
  ).toBeInTheDocument();
  expect(
    card().queryByRole("figure", { name: "WeChat connection QR code" })
  ).toBeNull();
  await t.user.click(card().getByRole("button", { name: "Create new QR code" }));
  await waitFor(() => expect(t.named("wechat.start")).toHaveLength(1));

  act(() =>
    t.core.emit(
      "wechat",
      ready(
        {
          connection: null,
          pending: attempt({ status: "prepared", qrcode_url: null }),
        },
        { error: true }
      )
    )
  );
  await t.user.click((await card().findAllByRole("button", { name: "Refresh" }))[0]!);
  await waitFor(() =>
    expect(t.named("wechat.refresh")).toEqual([{ workspace: workspaceId }])
  );
});
