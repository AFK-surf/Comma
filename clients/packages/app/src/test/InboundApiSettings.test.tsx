import type { RouterKey, RouterKeysValue } from "@comma/core-client";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { jsonResponse, WebSettings } from "./settingsHarness";

beforeEach(() => {
  installNativeBridgeMock({ platform: "web" });
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => jsonResponse({ data: [] }))
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
  localStorage.clear();
});

const secret = "salix_gk_e2eSecretValueThatIsShownOnce";
const postMessageUrl =
  "https://salix.example.test/v1/agent-groups/grp_inbound/router/post-message";
const key = (extra: Partial<RouterKey> = {}): RouterKey => ({
  key_id: "gak_e2e",
  name: "Zendesk",
  prefix: secret.slice(0, 15),
  status: "active",
  created_by: "comma_user:usr_inbound",
  created_at: 1_700_000_000,
  post_message_url: postMessageUrl,
  ...extra,
});
const shown = (keys: RouterKey[] | null, error = false): RouterKeysValue => ({
  workspace: "wsp_inbound",
  keys,
  error,
});

/** Settings › Inbound API over a core whose keys are `value`; the calls it gets are noted. */
async function inboundApi(value: RouterKeysValue) {
  const calls: [string, unknown][] = [];
  const core = createScriptedCore({
    owns: (name) => name.startsWith("routerKeys"),
    values: (topic) => (topic.topic === "routerKeys" ? value : undefined),
    calls: (name, params) => {
      calls.push([name, params]);
      return name === "routerKeys.create" ? { ...key(), key: secret } : null;
    },
  });
  const user = userEvent.setup();
  render(<WebSettings core={core} />);
  await user.click(await screen.findByRole("button", { name: "Inbound API" }));
  const named = (name: string) => calls.filter(([n]) => n === name).map(([, p]) => p);
  return { core, user, named };
}

// Settings › System › Inbound API: the plaintext key is shown once, right after creation, and never again.
it("creates a key and shows its secret once, then disables and deletes it", async () => {
  const t = await inboundApi(shown([]));
  expect(await screen.findByText("No inbound API keys yet.")).toBeInTheDocument();

  await t.user.click(screen.getByRole("button", { name: "New key" }));
  const create = await screen.findByRole("dialog", { name: "New key" });
  expect(within(create).getByRole("button", { name: "Create key" })).toBeDisabled();
  await t.user.type(within(create).getByRole("textbox", { name: "Name" }), "Zendesk");
  await t.user.click(within(create).getByRole("button", { name: "Create key" }));
  expect(t.named("routerKeys.create")).toEqual([
    { workspace: "wsp_inbound", name: "Zendesk" },
  ]);

  // The one-time panel carries the plaintext and a ready-to-paste command whose URL is the server-supplied posting
  // endpoint, not this app's API host.
  const created = await screen.findByTestId("inbound-api-created");
  expect(screen.getByTestId("inbound-api-secret")).toHaveTextContent(secret);
  expect(created).toHaveTextContent(`curl -X POST ${postMessageUrl}`);
  act(() => t.core.emit("routerKeys", shown([key()])));
  await t.user.click(within(created).getByRole("button", { name: "Done" }));
  await waitFor(() => expect(screen.queryByTestId("inbound-api-created")).toBeNull());
  expect(screen.queryByText(secret)).toBeNull();

  const row = await screen.findByTestId("inbound-api-key-gak_e2e");
  expect(row).toHaveTextContent("Zendesk");
  expect(row).toHaveTextContent("Active");
  await t.user.click(within(row).getByRole("button", { name: "Key actions" }));
  await t.user.click(await screen.findByRole("menuitem", { name: "Disable key" }));
  await waitFor(() =>
    expect(t.named("routerKeys.setStatus")).toEqual([
      { workspace: "wsp_inbound", key: "gak_e2e", status: "disabled" },
    ])
  );
  act(() => t.core.emit("routerKeys", shown([key({ status: "disabled" })])));
  await waitFor(() =>
    expect(screen.getByTestId("inbound-api-key-gak_e2e")).toHaveTextContent("Disabled")
  );

  await t.user.click(
    within(screen.getByTestId("inbound-api-key-gak_e2e")).getByRole("button", {
      name: "Key actions",
    })
  );
  await t.user.click(await screen.findByRole("menuitem", { name: "Delete key" }));
  await t.user.click(
    within(
      await screen.findByRole("dialog", { name: "Delete this inbound API key?" })
    ).getByRole("button", { name: "Delete key" })
  );
  await waitFor(() =>
    expect(t.named("routerKeys.delete")).toEqual([
      { workspace: "wsp_inbound", key: "gak_e2e" },
    ])
  );
  act(() => t.core.emit("routerKeys", shown([])));
  expect(await screen.findByText("No inbound API keys yet.")).toBeInTheDocument();
});
