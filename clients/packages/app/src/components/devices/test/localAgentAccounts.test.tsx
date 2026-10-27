import type { DevicesValue } from "@comma/core/contract";
import type {
  LocalStationAccounts,
  LocalStationAccountTarget,
  LocalStationRuntimeAccounts,
  LocalStationSetAccountSourceInput,
} from "@comma/native-bridge";
import { flush } from "@comma/test-utils/fake-clock";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, fireEvent, render, screen, within } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { WebSettings } from "../../../test/settingsHarness";

// Settings › Devices on this device: which account its Codex and Claude Code run on, read from and set on its
// station through Main's `localStation` capabilities (RFC43 §3.4). Main's channel is tested in
// apps/electron/src/main/test/local-station.test.ts; the row's markup in DeviceSettings.test.tsx.

const workspaceId = "wsp_local";

type Runtimes = Record<"codex" | "claude", LocalStationRuntimeAccounts>;

const login = (
  fields: Partial<NonNullable<LocalStationRuntimeAccounts["local"]>> = {}
) => ({
  installed: true,
  loggedIn: false,
  email: null,
  usable: false,
  signIn: null,
  ...fields,
});
const runtime = (
  fields: Partial<LocalStationRuntimeAccounts> = {}
): LocalStationRuntimeAccounts => ({
  source: "none",
  chosen: false,
  workspaceAvailable: true,
  workspaceAccounts: [{ name: "Team" }],
  local: null,
  endpoint: null,
  ...fields,
});
/** What the station's check of a model server says: Ollama answers with two models, any other refuses. */
const served = (address: string) =>
  address.includes("ollama.test")
    ? {
        address,
        keyed: false,
        state: "ok",
        detail: "2 models",
        models: ["qwen3:8b", "gemma3"],
      }
    : {
        address,
        keyed: false,
        state: "failed",
        detail: "connection refused",
        models: [],
      };
const view = (runtimes: Runtimes): LocalStationAccounts => ({
  workspaces: [{ workspaceId, name: "Local", runtimes }],
});

/** The bridge error Main sends for `code`. */
const bridgeError = (code: string) =>
  Object.assign(new Error(code), { bridgeError: { code, message: code } });

let runtimes: Runtimes;
let bridge: ReturnType<typeof installNativeBridgeMock>;

beforeEach(() => {
  runtimes = { codex: runtime(), claude: runtime() };
  bridge = installNativeBridgeMock({
    platform: "electron",
    localStation: {
      accounts: vi.fn(async () => view(structuredClone(runtimes))),
      setAccountSource: vi.fn(
        async ({
          runtime: which,
          source,
          endpoint,
          key,
        }: LocalStationSetAccountSourceInput) => {
          runtimes[which] = {
            ...runtimes[which],
            source,
            chosen: true,
            local: source === "local" ? login() : null,
            ...(endpoint
              ? {
                  endpoint: {
                    ...served(endpoint),
                    keyed: !!key || !!runtimes[which].endpoint?.keyed,
                  },
                }
              : {}),
          };
          return view(structuredClone(runtimes));
        }
      ),
      signIn: vi.fn(async ({ runtime: which }: LocalStationAccountTarget) => {
        runtimes[which].local = login({
          signIn: { state: "running", url: null, error: null },
        });
        return view(structuredClone(runtimes));
      }),
      stopSignIn: vi.fn(async ({ runtime: which }: LocalStationAccountTarget) => {
        runtimes[which].local = login();
        return view(structuredClone(runtimes));
      }),
    },
  });
  localStorage.setItem("comma.activeWorkspaceId", workspaceId);
});

afterEach(() => {
  localStorage.clear();
});

async function devices() {
  const value: DevicesValue = {
    workspace: workspaceId,
    devices: [],
    cloud: null,
    hasMore: false,
    loading: false,
    failed: false,
    checks: {},
  };
  const core = createScriptedCore({
    values: (topic) => (topic.topic === "devices" ? value : undefined),
  });
  render(<WebSettings core={core} />);
  await flush();
  const nav = document.querySelector<HTMLElement>('[data-slot="settings-page"] nav')!;
  fireEvent.click(
    [...nav.querySelectorAll("button")].find(
      (button) => button.textContent?.trim() === "Devices"
    )!
  );
  await flush();
}

const card = () => within(screen.getByRole("article", { name: "This device" }));
/** The row of `name`: its status line and its source dropdown. */
const row = (name: string) => {
  const rows = [
    ...document.querySelectorAll<HTMLElement>(".comma-device__agent"),
  ].filter(
    (element) =>
      element.querySelector(".comma-device__agent-name")?.textContent === name
  );
  expect(rows).toHaveLength(1);
  const element = rows[0]!;
  return {
    element,
    status: () => element.querySelector(".comma-device__agent-status")?.textContent,
    dropdown: () =>
      within(element).getByRole("button", { name: new RegExp(`${name} Account`) }),
  };
};
const options = async (name: string) => {
  fireEvent.click(row(name).dropdown());
  await flush();
  const shown = screen.getAllByRole("option").map((option) => option.textContent);
  fireEvent.keyDown(document.activeElement!, { key: "Escape" });
  await flush();
  return shown;
};
const choose = async (name: string, option: string) => {
  fireEvent.click(row(name).dropdown());
  await flush();
  fireEvent.click(screen.getByRole("option", { name: option }));
  await flush();
};

it("shows each source state with its line and options, and chooses nothing for the person", async () => {
  runtimes = {
    // Both sources available, none chosen.
    codex: runtime(),
    // Only this device's login: the workspace has no shared account.
    claude: runtime({ workspaceAvailable: false, workspaceAccounts: [] }),
  };
  await devices();
  expect(bridge.localStation.accounts).toHaveBeenCalledOnce();

  expect(row("Codex").status()).toBe(
    "Choose the account this device uses for this agent"
  );
  expect(row("Codex").dropdown()).toHaveTextContent("Choose");
  expect(await options("Codex")).toEqual([
    "Workspace account",
    "This device’s login",
    "Local model",
    "Do not use",
  ]);
  expect(row("Claude Code").status()).toContain(
    "The workspace has no shared account yet"
  );
  expect(await options("Claude Code")).toEqual([
    "This device’s login",
    "Local model",
    "Do not use",
  ]);
  // Never chosen is not "Do not use": the placeholder there too.
  expect(row("Claude Code").dropdown()).toHaveTextContent("Choose");

  // The workspace account: one mutation for the choice.
  await choose("Codex", "Workspace account");
  expect(bridge.localStation.setAccountSource).toHaveBeenCalledExactlyOnceWith({
    workspaceId,
    runtime: "codex",
    source: "workspace",
  });
  expect(row("Codex").status()).toBe("Uses the workspace account");
  expect(row("Codex").dropdown()).toHaveTextContent("Workspace account");

  // This device’s login, not signed in: the sign-in, and its cancel while the browser page waits.
  await choose("Claude Code", "This device’s login");
  expect(row("Claude Code").status()).toBe(
    "Claude Code is not signed in on this device"
  );
  fireEvent.click(
    within(row("Claude Code").element).getByRole("button", { name: "Sign in" })
  );
  await flush();
  expect(bridge.localStation.signIn).toHaveBeenCalledExactlyOnceWith({
    workspaceId,
    runtime: "claude",
  });
  fireEvent.click(
    within(row("Claude Code").element).getByRole("button", { name: "Cancel sign-in" })
  );
  await flush();
  expect(bridge.localStation.stopSignIn).toHaveBeenCalledOnce();

  // Signed in in the browser: coming back to the window reads it once.
  runtimes.claude.local = login({
    loggedIn: true,
    usable: true,
    email: "me@example.com",
  });
  act(() => window.dispatchEvent(new Event("focus")));
  await flush();
  expect(row("Claude Code").status()).toBe("Uses this device’s login (me@example.com)");

  // "Do not use", chosen by the person: the station records the choice, and a new read still says so.
  await choose("Codex", "Do not use");
  expect(row("Codex").status()).toBe("This device does not run Codex");
  expect(row("Codex").dropdown()).toHaveTextContent("Do not use");
  act(() => window.dispatchEvent(new Event("focus")));
  await flush();
  expect(row("Codex").status()).toBe("This device does not run Codex");
  expect(bridge.localStation.accounts).toHaveBeenCalledTimes(3);

  // The workspace's shared accounts go away: the line says so, and "Add workspace account" opens the workspace's AI
  // accounts (Models & API).
  runtimes.codex = runtime({
    source: "workspace",
    chosen: true,
    workspaceAvailable: false,
    workspaceAccounts: [],
  });
  act(() => window.dispatchEvent(new Event("focus")));
  await flush();
  expect(row("Codex").status()).toContain("The workspace has no shared account yet");
  fireEvent.click(
    within(row("Codex").element).getByRole("button", {
      name: "Add workspace account",
    })
  );
  await flush();
  // Settings' own navigation: the Model & API page, whatever the address says.
  expect(
    document.querySelector('[data-slot="settings-sidebar-item"][data-selected="true"]')
      ?.textContent
  ).toBe("Model & API");
  expect(window.location.hash).toBe("");
});

/** The model server dialog's address field, and its Save. */
const address = () => screen.getByRole("textbox", { name: "Address" });
const save = async () => {
  fireEvent.click(screen.getByRole("button", { name: "Save" }));
  await flush();
};

it("runs an agent on a model server of this device: its address asked first, the station's check shown, and changed", async () => {
  // Codex has an address on the station from before; Claude Code none.
  runtimes.codex = runtime({ endpoint: served("http://ollama.test/v1") });
  await devices();

  // No address yet: asked before anything is chosen.
  await choose("Claude Code", "Local model");
  expect(bridge.localStation.setAccountSource).not.toHaveBeenCalled();
  expect(
    screen.getByRole("dialog", { name: "Local model for Claude Code" })
  ).toHaveTextContent("Anthropic Messages");
  fireEvent.change(address(), { target: { value: "ollama.test" } });
  await save();
  expect(screen.getByRole("dialog", { name: /^Local model for/ })).toHaveTextContent(
    "Enter an address that starts with http:// or https://."
  );
  expect(address()).toHaveAttribute("aria-invalid", "true");
  expect(bridge.localStation.setAccountSource).not.toHaveBeenCalled();
  fireEvent.change(address(), { target: { value: " http://ollama.test " } });
  // A proxy that asks for a key (CLIProxyAPI): given with the address.
  fireEvent.change(screen.getByLabelText(/^API key \(optional\)/), {
    target: { value: "sk-local" },
  });
  await save();
  expect(bridge.localStation.setAccountSource).toHaveBeenCalledExactlyOnceWith({
    workspaceId,
    runtime: "claude",
    source: "endpoint",
    endpoint: "http://ollama.test",
    key: "sk-local",
  });
  expect(screen.queryByRole("dialog", { name: /^Local model for/ })).toBeNull();
  expect(row("Claude Code").status()).toBe(
    "Uses the local model at http://ollama.test (2 models) Change address"
  );
  expect(row("Claude Code").dropdown()).toHaveTextContent("Local model");

  // Changed to a server that does not answer: the row says why.
  fireEvent.click(
    within(row("Claude Code").element).getByRole("button", { name: "Change address" })
  );
  await flush();
  expect(address()).toHaveValue("http://ollama.test");
  // The station has its key: the field stays empty and keeps it.
  expect(screen.getByLabelText(/^API key \(optional\)/)).toHaveAttribute(
    "placeholder",
    "Saved: leave empty to keep it"
  );
  fireEvent.change(address(), { target: { value: "http://lmstudio.test" } });
  await save();
  expect(bridge.localStation.setAccountSource).toHaveBeenLastCalledWith({
    workspaceId,
    runtime: "claude",
    source: "endpoint",
    endpoint: "http://lmstudio.test",
  });
  expect(row("Claude Code").status()).toBe(
    "Cannot use http://lmstudio.test: connection refused Change address"
  );

  // An address the station has: chosen at once, without asking again.
  await choose("Codex", "Local model");
  expect(bridge.localStation.setAccountSource).toHaveBeenLastCalledWith({
    workspaceId,
    runtime: "codex",
    source: "endpoint",
  });
  expect(screen.queryByRole("dialog", { name: /^Local model for/ })).toBeNull();
  expect(row("Codex").status()).toContain("http://ollama.test/v1 (2 models)");
});

it("reads again after a refused choice, and shows a failed read in the agents section with its retry", async () => {
  await devices();
  // The workspace's accounts went away before the choice (409): its state is read again, not shown as a failure.
  vi.mocked(bridge.localStation.setAccountSource).mockRejectedValueOnce(
    bridgeError("LOCAL_STATION_CONFLICT")
  );
  runtimes.codex = runtime({ workspaceAvailable: false, workspaceAccounts: [] });
  await choose("Codex", "Workspace account");
  expect(card().queryByRole("alert")).toBeNull();
  expect(row("Codex").status()).toContain("The workspace has no shared account yet");

  // The station does not answer: one note in the agents section, and its retry reads again.
  vi.mocked(bridge.localStation.accounts).mockRejectedValueOnce(
    bridgeError("LOCAL_STATION_UNAVAILABLE")
  );
  act(() => window.dispatchEvent(new Event("focus")));
  await flush();
  const agents = within(card().getByRole("region", { name: "Agents" }));
  const note = agents.getByRole("alert");
  expect(note).toHaveTextContent("Cannot read the agent settings of this device.");
  fireEvent.click(within(note).getByRole("button", { name: "Try again" }));
  await flush();
  expect(card().queryByRole("alert")).toBeNull();
});
