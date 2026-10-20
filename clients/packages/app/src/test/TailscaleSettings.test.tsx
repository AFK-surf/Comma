import type { TailnetStatus, TailnetValue } from "@comma/core-client";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { jsonResponse, WebSettings } from "./settingsHarness";

const workspaceId = "wsp_tailnet";
const loginUrl = "https://login.tailscale.com/a/abc123";

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

function status(extra: Partial<TailnetStatus> = {}): TailnetStatus {
  return {
    enabled: false,
    state: "disabled",
    approved: false,
    login_url: null,
    tailnet: null,
    node_name: null,
    login_name: null,
    node_tags: [],
    addresses: [],
    key_expiry: null,
    error: null,
    settings: {
      tags: ["tag:comma-agent"],
      accept_routes: false,
      expected_tailnet: null,
    },
    updated_at: null,
    ...extra,
  };
}

const value = (
  s: TailnetStatus,
  peers: TailnetValue["peers"] = null
): TailnetValue => ({
  workspace: workspaceId,
  status: s,
  peers,
  error: false,
  busy: false,
});

/** Settings › Tailscale over a core whose tailnet is `shown`; the calls it gets are noted. */
async function tailscale(shown: TailnetValue) {
  const calls: [string, unknown][] = [];
  const core = createScriptedCore({
    owns: (name) => name.startsWith("tailnet"),
    values: (topic) => (topic.topic === "tailnet" ? shown : undefined),
    calls: (name, params) => {
      calls.push([name, params]);
      return name === "tailnet.connect"
        ? status({ enabled: true, state: "needs_login" })
        : null;
    },
  });
  const user = userEvent.setup();
  render(<WebSettings core={core} />);
  await user.click(await screen.findByRole("button", { name: "Tailscale" }));
  await waitFor(() => expect(setting("tailscale.connection")).not.toBeNull());
  const named = (name: string) => calls.filter(([n]) => n === name).map(([, p]) => p);
  return { core, user, named };
}

it("connects with the typed settings, shows the login link while waiting, then the devices", async () => {
  const t = await tailscale(value(status()));
  // The tab wears Tailscale's own mark, not the generic devices glyph.
  expect(
    screen
      .getByRole("button", { name: "Tailscale" })
      .querySelector('[data-provider-logo="tailscale"]')
  ).not.toBeNull();
  expect(setting("tailscale.connection")).toHaveTextContent("Not connected");
  await t.user.click(
    within(setting("tailscale.connection")!).getByRole("button", { name: "Connect" })
  );

  await t.user.clear(await screen.findByRole("textbox", { name: "Tags" }));
  await t.user.type(
    screen.getByRole("textbox", { name: "Tags" }),
    "tag:comma-agent, tag:ops"
  );
  await t.user.type(
    screen.getByRole("textbox", { name: "Tailnet name (optional)" }),
    "acme.com"
  );
  await t.user.click(
    screen.getByRole("checkbox", { name: "Use approved subnet routes" })
  );
  await t.user.click(screen.getByRole("button", { name: "Connect" }));
  await waitFor(() =>
    expect(t.named("tailnet.connect")).toEqual([
      {
        workspace: workspaceId,
        tags: ["tag:comma-agent", "tag:ops"],
        accept_routes: true,
        expected_tailnet: "acme.com",
      },
    ])
  );

  // The node waits for a tailnet admin: the link shows, and the page checks again on request.
  act(() =>
    t.core.emit(
      "tailnet",
      value(status({ enabled: true, state: "needs_login", login_url: loginUrl }))
    )
  );
  expect(await screen.findByTestId("tailscale-login-url")).toHaveTextContent(loginUrl);
  expect(setting("tailscale.connection")).toHaveTextContent("Waiting for approval");
  await t.user.click(
    within(setting("tailscale.connection")!).getByRole("button", {
      name: "Check again",
    })
  );
  await waitFor(() =>
    expect(t.named("tailnet.refresh")).toEqual([{ workspace: workspaceId }])
  );

  // Approved: the link is gone and the devices show.
  act(() =>
    t.core.emit(
      "tailnet",
      value(
        status({
          enabled: true,
          state: "running",
          tailnet: "acme.com",
          node_name: "comma-ws.tail1234.ts.net",
        }),
        [
          {
            name: "nas",
            dns_name: "nas.tail1234.ts.net",
            ips: ["100.64.0.5"],
            os: "linux",
            online: true,
            tags: [],
            routes: [],
          },
        ]
      )
    )
  );
  await waitFor(() => expect(screen.queryByTestId("tailscale-login-url")).toBeNull());
  expect(setting("tailscale.connection")).toHaveTextContent("Connected to acme.com");
  expect(screen.getByRole("list", { name: "Devices" })).toHaveTextContent(
    "nas.tail1234.ts.net"
  );
});

it("disconnects after confirming", async () => {
  const t = await tailscale(
    value(status({ enabled: true, state: "idle", tailnet: "acme.com", approved: true }))
  );
  await t.user.click(screen.getByRole("button", { name: "Disconnect" }));
  const dialog = await screen.findByRole("dialog", { name: "Disconnect Tailscale?" });
  await t.user.click(within(dialog).getByRole("button", { name: "Disconnect" }));
  await waitFor(() =>
    expect(t.named("tailnet.disconnect")).toEqual([{ workspace: workspaceId }])
  );
});
