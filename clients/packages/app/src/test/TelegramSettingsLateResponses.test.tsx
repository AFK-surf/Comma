import type { TelegramIntegration, TelegramValue } from "@comma/core/contract";
import { flush } from "@comma/test-utils/fake-clock";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen, within } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { WebSettings } from "./settingsHarness";

// Settings › Channels › Telegram over a scripted core. That a login or disconnect goes on in the core while no page
// shows it, how often it reads the login, and what it asks the server are tested in
// packages/core/test/telegram.test.ts.

const workspaceId = "wsp_telegram";
const telegram = () => within(screen.getByRole("region", { name: "Telegram" }));

beforeEach(() => {
  installNativeBridgeMock({ platform: "web" });
  vi.stubGlobal(
    "open",
    vi.fn(() => ({
      closed: false,
      close: vi.fn(),
      location: { href: "" },
      opener: null,
    }))
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
  localStorage.clear();
});

const integration = (linked: boolean): TelegramIntegration => ({
  bot_url: "https://t.me/CommaTestBot",
  bot_username: "CommaTestBot",
  configured: true,
  link: linked
    ? {
        connected_at: 1_788_400_000,
        telegram_user_id: "424242",
        telegram_username: "alice",
        updated_at: 1_788_400_000,
      }
    : null,
  official_login_available: true,
  workspace_id: workspaceId,
  workspace_name: "Workspace A",
});

/**
 * Settings over a core whose Telegram is `value` (the test changes it with `say`); `answer` answers the UI's calls.
 */
async function channels(
  initial: Partial<TelegramValue>,
  answer: (
    name: string,
    params: unknown,
    say: (change: Partial<TelegramValue>) => void
  ) => unknown = () => null
) {
  let value: TelegramValue = {
    workspace: workspaceId,
    state: null,
    attempt: null,
    checks: 0,
    error: false,
    busy: false,
    ...initial,
  };
  const core = createScriptedCore({
    values: (topic) => (topic.topic === "telegram" ? value : undefined),
    calls: (name, params) => answer(name, params, say),
  });
  function say(change: Partial<TelegramValue>) {
    value = { ...value, ...change };
    core.changed("telegram");
  }
  const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
  render(<WebSettings core={core} />);
  await flush();
  const open = async (category: string) => {
    await user.click(screen.getByRole("button", { name: category }));
    await flush();
  };
  await open("Channels");
  return { core, user, open, say };
}

it("keeps a Telegram login under way after leaving Channels, and shows it on return", async () => {
  const t = await channels({ state: integration(false) }, (name, _params, say) => {
    if (name !== "telegram.connect") return null;
    say({ attempt: "workspace-a", busy: true, checks: 0 });
    return { authorizationUrl: "https://oauth.telegram.org/auth?state=workspace-a" };
  });
  await t.user.click(telegram().getByRole("button", { name: "Connect" }));
  await flush();
  expect(telegram().getByRole("button", { name: "Cancel connection" })).toBeEnabled();
  await t.open("General");
  await t.open("Channels");
  // The core still follows the login: the page shows it, and nothing was asked twice.
  expect(telegram().getByRole("button", { name: "Cancel connection" })).toBeEnabled();
  expect(t.core.sentTo("telegram.connect")).toHaveLength(1);
  expect(t.core.sentTo("telegram.cancel")).toEqual([]);
});

it("finishes a Telegram disconnect started before leaving Channels", async () => {
  const t = await channels({ state: integration(true) }, (name, _params, say) => {
    if (name === "telegram.disconnect") say({ busy: true });
    return null;
  });
  expect(screen.getByText("@alice")).toBeInTheDocument();
  await t.user.click(screen.getByRole("button", { name: "Manage" }));
  await flush();
  await t.user.click(screen.getByRole("menuitem", { name: "Disconnect" }));
  await flush();
  expect(t.core.sentTo("telegram.disconnect")).toEqual([{}]);
  await t.open("General");
  // The core finishes the disconnect while Channels is away.
  act(() => t.say({ state: integration(false), busy: false }));
  await t.open("Channels");
  // Settled and disconnected: nothing to report under the title.
  expect(
    screen.getByRole("region", { name: "Telegram" }).querySelector("output")
  ).toBeEmptyDOMElement();
  expect(screen.queryByText("@alice")).toBeNull();
});

it.each(["official login", "closed login", "blocked popup"] as const)(
  "cancels the exact %s attempt and permits retry",
  async (scenario) => {
    const popup = {
      closed: false,
      close: vi.fn(),
      location: { href: "" },
      opener: null,
    };
    vi.stubGlobal(
      "open",
      vi.fn(() => (scenario === "blocked popup" ? null : popup))
    );
    const t = await channels({ state: integration(false) }, (name, params, say) => {
      if (name === "telegram.connect") {
        say({ attempt: "exact-attempt", busy: true, checks: 0 });
        return {
          authorizationUrl: "https://oauth.telegram.org/auth?state=exact-attempt",
        };
      }
      // The core cancels its login with the server; a closed window is a failure.
      if (name === "telegram.cancel")
        say({
          attempt: null,
          busy: false,
          error: (params as { closed?: boolean }).closed === true,
        });
      return null;
    });
    expect(telegram().getByRole("button", { name: "Connect" })).toBeEnabled();
    await t.user.click(telegram().getByRole("button", { name: "Connect" }));
    await flush();
    if (scenario === "blocked popup") {
      expect(
        screen.getByText("Telegram could not be updated. Please try again.")
      ).toBeInTheDocument();
      expect(telegram().getByRole("button", { name: "Connect" })).toBeEnabled();
      expect(t.core.sentTo("telegram.connect")).toEqual([]);
      return;
    }
    expect(popup.location.href).toBe(
      "https://oauth.telegram.org/auth?state=exact-attempt"
    );
    if (scenario === "closed login") {
      popup.closed = true;
      // The core's next read of the login is when the page looks at its window.
      act(() => t.say({ checks: 1 }));
    } else
      await t.user.click(screen.getByRole("button", { name: "Cancel connection" }));
    await flush();
    expect(t.core.sentTo("telegram.cancel")).toEqual([
      scenario === "closed login" ? { closed: true } : {},
    ]);
    expect(screen.queryByRole("button", { name: "Cancel connection" })).toBeNull();
    expect(telegram().getByRole("button", { name: "Connect" })).toBeEnabled();
    // Only the failure leaves a subtitle; a settled card has none.
    const subtitle = screen
      .getByRole("region", { name: "Telegram" })
      .querySelector("output");
    if (scenario === "closed login")
      expect(subtitle).toHaveTextContent(
        "Telegram could not be updated. Please try again."
      );
    else expect(subtitle).toBeEmptyDOMElement();
  }
);
