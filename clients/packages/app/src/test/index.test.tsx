import userEvent from "@testing-library/user-event";
import {
  commaClientAppShortcutOverridesSchema,
  defaultCommaClientSettings,
  type NativeStateBridge,
  type ProductInboxItem,
  type ProductInboxListResult,
  type SurfaceList,
} from "@comma/native-bridge";
import {
  CommaApp,
  CommaAuthGate,
  CommaSessionHostProvider,
  CommaSidebarPanel,
  CommaSidebarProvider,
  CommaWebClientSettingsProvider,
  ProductInboxProjectionProvider,
  commaClientSettingsStorageKey,
  createWebSessionHostController,
  useCommaAuth,
  type ProductInboxProjectionController,
  type SessionHostController,
  type WebSessionHostPorts,
} from "@comma/app";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import { chordKeybinding, sequenceKeybinding, toast } from "@comma/ui";
import type { ReactElement } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { COMMA_SURFACE_PAUSED_ATTRIBUTE } from "../components/commaSurfacePause";
import { createProductInboxProjectionHarness } from "./productInboxProjectionHarness";

vi.mock("tweakpane", () => ({
  Pane: class PaneMock {
    addBinding = vi.fn();
    addBlade = vi.fn();
    addButton = vi.fn(() => ({ on: vi.fn() }));
    addFolder = vi.fn(() => this);
    dispose = vi.fn();
  },
}));

const legacySessionTokenStorageKey = "comma.sessionToken";
const legacyUserAdminStorageKey = "comma.userAdmin";
const legacyUserEmailStorageKey = "comma.userEmail";

let commaTestSession: true | "guest" | undefined;
let nextSessionHostId = 0;
const sessionHostControllers: SessionHostController[] = [];

describe("CommaApp", () => {
  beforeEach(() => {
    commaTestSession = undefined;
    delete (window as Window & { google?: unknown }).google;
    installCommaFetchStub();
  });

  afterEach(() => {
    toast.dismissAll();
    for (const controller of sessionHostControllers.splice(0)) {
      controller.dispose?.();
    }
    window.history.replaceState(null, "", "/");
    window.location.hash = "";
    localStorage.clear();
    vi.unstubAllGlobals();
  });

  it("renders passwordless login before the app shell", async () => {
    renderCommaApp();

    expect(
      await screen.findByRole("heading", { name: "Sign in to Comma" })
    ).toBeInTheDocument();
    expect(screen.queryByRole("complementary", { name: "App sidebar" })).toBeNull();
  });

  it("does not render product drag surfaces above web content", async () => {
    const { container } = renderCommaApp();

    expect(
      await screen.findByRole("heading", { name: "Sign in to Comma" })
    ).toBeInTheDocument();
    expect(container.querySelector(".comma-content")).toBeNull();
    expect(container.querySelector(".comma-window-bar")).toBeNull();
  });

  it("signs in with an email verification code", async () => {
    const fetchMock = installCommaFetchStub(async (url: string) => {
      if (url.endsWith("/v1/comma/auth/email/login")) {
        return jsonResponse({
          challenge_id: "comma_challenge_1",
          code: "123456",
        });
      }

      return jsonResponse({
        expires_at: 4_102_444_800,
        session_id: "11111111-1111-4111-8111-111111111111",
        user: { id: "usr_1", email: "person@example.com" },
      });
    });

    renderCommaApp();

    await userEvent.type(
      await screen.findByRole("textbox", { name: /email/i }),
      "person@example.com"
    );
    await userEvent.click(screen.getByRole("button", { name: "Send code" }));

    expect(
      await screen.findByRole("textbox", { name: /verification code/i })
    ).toHaveValue("123456");
    expect(await screen.findByRole("status")).toHaveTextContent(
      "Verification code sent."
    );

    await userEvent.click(screen.getByRole("button", { name: "Verify code" }));

    expect(
      await screen.findByRole("complementary", { name: "App sidebar" })
    ).toBeInTheDocument();
    expect(localStorage.getItem(legacySessionTokenStorageKey)).toBeNull();
    expect(localStorage.getItem(legacyUserEmailStorageKey)).toBeNull();
    expect(localStorage.getItem(legacyUserAdminStorageKey)).toBeNull();
    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/auth/email/login",
      expect.objectContaining({
        method: "POST",
        credentials: "include",
        body: JSON.stringify({ email: "person@example.com" }),
      })
    );
    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/auth/email/verify",
      expect.objectContaining({
        method: "POST",
        credentials: "include",
        body: expect.stringMatching(
          /^{"challenge_id":"comma_challenge_1","code":"123456","client_kind":"web","client_platform":"(?:android|ios|linux|macos|unknown|windows)"}$/
        ),
      })
    );
  });

  it("replaces a prepared Google attempt when the user chooses email", async () => {
    const google = installGoogleIdentityServicesStub();
    const fetchMock = installCommaFetchStub(async (url: string) => {
      if (url.endsWith("/v1/comma/auth/google/attempt")) {
        return jsonResponse({
          attempt_id: "gat_email_fallback",
          client_id: "comma-web-client.apps.googleusercontent.com",
          nonce: "nonce_email_fallback",
          platform: "web",
        });
      }
      if (url.endsWith("/v1/comma/auth/email/login")) {
        return jsonResponse({
          challenge_id: "comma_challenge_email_fallback",
          code: "123456",
        });
      }
      if (url.endsWith("/v1/comma/auth/email/verify")) {
        return jsonResponse({
          expires_at: 4_102_444_800,
          session_id: "11111111-1111-4111-8111-111111111111",
          user: { id: "usr_1", email: "person@example.com" },
        });
      }
      return jsonResponse({ error: "not found" }, 404);
    });

    renderCommaApp();

    await waitFor(() => expect(google.renderButton).toHaveBeenCalledOnce());
    await userEvent.type(
      screen.getByRole("textbox", { name: /email/i }),
      "person@example.com"
    );
    await userEvent.click(screen.getByRole("button", { name: "Send code" }));

    expect(
      await screen.findByRole("textbox", { name: /verification code/i })
    ).toHaveValue("123456");
    await userEvent.click(screen.getByRole("button", { name: "Verify code" }));
    expect(
      await screen.findByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();
    expect(
      fetchMock.mock.calls.filter(([input]) =>
        String(input).endsWith("/v1/comma/auth/google")
      )
    ).toEqual([]);
  });

  it("signs in through the official Google Identity Services callback", async () => {
    const google = installGoogleIdentityServicesStub();
    const fetchMock = installCommaFetchStub(async (url: string) => {
      if (url.endsWith("/v1/comma/auth/google/attempt")) {
        return jsonResponse({
          attempt_id: "gat_1",
          client_id: "comma-web-client.apps.googleusercontent.com",
          nonce: "nonce_1",
          platform: "web",
        });
      }

      if (url.endsWith("/v1/comma/auth/google")) {
        return jsonResponse({
          expires_at: 4_102_444_800,
          session_id: "11111111-1111-4111-8111-111111111111",
          user: { id: "usr_google", email: "person@gmail.com" },
        });
      }

      return jsonResponse({ error: "not found" }, 404);
    });

    renderCommaApp();

    await waitFor(() => expect(google.renderButton).toHaveBeenCalledOnce());
    google.submitCredential("google_id_token");

    expect(
      await screen.findByRole("complementary", { name: "App sidebar" })
    ).toBeInTheDocument();
    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/auth/google",
      expect.objectContaining({
        method: "POST",
        credentials: "include",
        body: expect.stringMatching(
          /^{"attempt_id":"gat_1","credential":"google_id_token","nonce":"nonce_1","client_kind":"web","client_platform":"(?:android|ios|linux|macos|unknown|windows)"}$/
        ),
      })
    );
    expect(localStorage.getItem(legacySessionTokenStorageKey)).toBeNull();
  });

  it("retries Google Identity Services after the script fails to load", async () => {
    installCommaFetchStub(async (url: string) => {
      if (url.endsWith("/v1/comma/auth/google/attempt")) {
        return jsonResponse({
          attempt_id: "gat_retry",
          client_id: "comma-web-client.apps.googleusercontent.com",
          nonce: "nonce_retry",
          platform: "web",
        });
      }

      return jsonResponse({ error: "not found" }, 404);
    });

    renderCommaApp();

    const firstScript = await waitFor(() => {
      const script = document.getElementById("comma-google-identity-services");
      expect(script).toBeInstanceOf(HTMLScriptElement);
      return script as HTMLScriptElement;
    });
    fireEvent.error(firstScript);

    await userEvent.click(
      await screen.findByRole("button", { name: "Retry Google sign-in" })
    );

    const secondScript = await waitFor(() => {
      const script = document.getElementById("comma-google-identity-services");
      expect(script).toBeInstanceOf(HTMLScriptElement);
      expect(script).not.toBe(firstScript);
      return script as HTMLScriptElement;
    });
    const google = installGoogleIdentityServicesStub();
    fireEvent.load(secondScript);

    await waitFor(() => expect(google.renderButton).toHaveBeenCalledOnce());
  });

  it("replaces a failed Google credential attempt when the user retries", async () => {
    const google = installGoogleIdentityServicesStub();
    let attemptCount = 0;
    let releaseSecondAttempt: (() => void) | undefined;
    const secondAttemptPending = new Promise<void>((resolve) => {
      releaseSecondAttempt = resolve;
    });
    const fetchMock = installCommaFetchStub(async (url: string) => {
      if (url.endsWith("/v1/comma/auth/google/attempt")) {
        attemptCount += 1;
        if (attemptCount === 2) {
          await secondAttemptPending;
        }
        return jsonResponse({
          attempt_id: `gat_retry_${attemptCount}`,
          client_id: "comma-web-client.apps.googleusercontent.com",
          nonce: `nonce_retry_${attemptCount}`,
          platform: "web",
        });
      }

      if (url.endsWith("/v1/comma/auth/google")) {
        return jsonResponse({ error: "invalid_google_credential" }, 401);
      }

      return jsonResponse({ error: "not found" }, 404);
    });

    renderCommaApp();

    await waitFor(() => expect(google.renderButton).toHaveBeenCalledOnce());
    google.submitCredential("rejected_google_id_token");

    await userEvent.click(
      await screen.findByRole("button", { name: "Retry Google sign-in" })
    );

    expect(
      await screen.findByRole("status", { name: "Loading Google sign-in…" })
    ).toBeVisible();
    expect(screen.queryByRole("alert")).toBeNull();
    expect(attemptCount).toBe(2);

    releaseSecondAttempt?.();

    await waitFor(() => expect(google.renderButton).toHaveBeenCalledTimes(2));
    expect(
      fetchMock.mock.calls.filter(([input]) =>
        String(input).endsWith("/v1/comma/auth/google/attempt")
      )
    ).toHaveLength(2);
  });

  it("requires the purpose-bound email code when Google linking needs proof", async () => {
    const google = installGoogleIdentityServicesStub();
    const fetchMock = installCommaFetchStub(async (url: string) => {
      if (url.endsWith("/v1/comma/auth/google/attempt")) {
        return jsonResponse({
          attempt_id: "gat_2",
          client_id: "comma-web-client.apps.googleusercontent.com",
          nonce: "nonce_2",
          platform: "web",
        });
      }

      if (url.endsWith("/v1/comma/auth/google/link/verify")) {
        return jsonResponse({
          expires_at: 4_102_444_800,
          session_id: "11111111-1111-4111-8111-111111111111",
          user: { id: "usr_linked", email: "person@example.com" },
        });
      }

      if (url.endsWith("/v1/comma/auth/google")) {
        return jsonResponse({
          status: "otp_required",
          challenge_id: "challenge_google_link",
          email: "person@example.com",
          code: "654321",
        });
      }

      return jsonResponse({ error: "not found" }, 404);
    });

    renderCommaApp();

    await waitFor(() => expect(google.renderButton).toHaveBeenCalledOnce());
    google.submitCredential("google_id_token_for_link");

    expect(
      await screen.findByRole("heading", { name: "Check your email" })
    ).toBeInTheDocument();
    expect(screen.getByText("person@example.com")).toBeInTheDocument();
    expect(screen.getByRole("textbox", { name: /verification code/i })).toHaveValue(
      "654321"
    );

    await userEvent.click(screen.getByRole("button", { name: "Verify code" }));

    expect(
      await screen.findByRole("complementary", { name: "App sidebar" })
    ).toBeInTheDocument();
    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/auth/google/link/verify",
      expect.objectContaining({
        method: "POST",
        credentials: "include",
        body: expect.stringMatching(
          /^{"challenge_id":"challenge_google_link","code":"654321","client_kind":"web","client_platform":"(?:android|ios|linux|macos|unknown|windows)"}$/
        ),
      })
    );
  });

  it("returns to login when the user signs out from Settings → Profile", async () => {
    seedCommaSession();
    renderCommaApp();

    await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
    await userEvent.click(await screen.findByRole("button", { name: "Profile" }));
    expect(
      await screen.findByText("Sign out of Comma on this device.")
    ).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Sign out" }));

    expect(
      await screen.findByRole("heading", { name: "Sign in to Comma" })
    ).toBeInTheDocument();
    await waitFor(() =>
      expect(fetch).toHaveBeenCalledWith(
        "http://127.0.0.1:4200/v1/comma/auth/logout",
        expect.objectContaining({ method: "POST", credentials: "include" })
      )
    );
  });

  it("unmounts the authenticated tree while browser logout is pending", async () => {
    seedCommaSession();
    let finishLogout!: (response: Response) => void;
    const pendingLogout = new Promise<Response>((resolve) => {
      finishLogout = resolve;
    });
    installCommaFetchStub(undefined, {
      logout: async () => pendingLogout,
    });

    renderCommaApp();

    await userEvent.click(await screen.findByRole("button", { name: "Settings" }));
    await userEvent.click(await screen.findByRole("button", { name: "Profile" }));
    await userEvent.click(await screen.findByRole("button", { name: "Sign out" }));

    expect(screen.getByText("Signing out…")).toBeInTheDocument();
    expect(
      screen.queryByRole("complementary", { name: "App sidebar" })
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("heading", { name: "Sign in to Comma" })
    ).not.toBeInTheDocument();

    finishLogout(jsonResponse({ signed_out: true }));

    expect(
      await screen.findByRole("heading", { name: "Sign in to Comma" })
    ).toBeInTheDocument();
  });

  it("fails closed until an uncertain HttpOnly-cookie logout is reconciled", async () => {
    seedCommaSession();
    const fetchMock = installCommaFetchStub(undefined, {
      logout: async () => jsonResponse({ error: "unavailable" }, 503),
    });
    let currentSignal: AbortSignal | undefined;

    function AuthProbe() {
      const auth = useCommaAuth();
      currentSignal = auth.sessionSignal;
      return (
        <div>
          <output aria-label="auth-email">{auth.userEmail}</output>
          <button onClick={auth.signOut} type="button">
            sign out
          </button>
        </div>
      );
    }

    renderWithSessionHost(
      <CommaAuthGate>
        <AuthProbe />
      </CommaAuthGate>
    );

    await expect(screen.findByLabelText("auth-email")).resolves.toHaveTextContent(
      "person@example.com"
    );
    const originalSignal = currentSignal;
    await userEvent.click(screen.getByRole("button", { name: "sign out" }));

    expect(originalSignal?.aborted).toBe(true);
    expect(
      await screen.findByRole("heading", {
        name: "Comma can’t continue",
      })
    ).toBeInTheDocument();
    expect(screen.queryByLabelText("auth-email")).toBeNull();

    await userEvent.click(screen.getByRole("button", { name: "Try again" }));
    await waitFor(() => {
      expect(currentSignal).not.toBe(originalSignal);
      expect(currentSignal?.aborted).toBe(false);
    });
    expect(screen.getByLabelText("auth-email")).toHaveTextContent("person@example.com");
    expect(
      screen.queryByRole("heading", { name: "Sign in to Comma" })
    ).not.toBeInTheDocument();
    expect(
      fetchMock.mock.calls.filter(([input, init]) => {
        const url =
          typeof input === "string"
            ? input
            : input instanceof URL
              ? input.toString()
              : input.url;
        return (
          (init?.method ?? "GET") === "GET" &&
          requestPath(url) === "/v1/comma/auth/session"
        );
      })
    ).toHaveLength(2);
  });

  it("scrubs legacy renderer auth metadata when the web app mounts", async () => {
    localStorage.setItem(legacySessionTokenStorageKey, "legacy_renderer_secret");
    localStorage.setItem(legacyUserEmailStorageKey, "legacy@example.com");
    localStorage.setItem(legacyUserAdminStorageKey, "true");

    renderCommaApp();

    await waitFor(() => {
      expect(localStorage.getItem(legacySessionTokenStorageKey)).toBeNull();
      expect(localStorage.getItem(legacyUserEmailStorageKey)).toBeNull();
      expect(localStorage.getItem(legacyUserAdminStorageKey)).toBeNull();
    });
  });

  it("renders the Figma shell layout with the Home route", async () => {
    seedCommaSession();
    renderCommaApp();

    expect(
      await screen.findByRole("complementary", { name: "App sidebar" })
    ).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Home" })).toHaveAttribute(
      "aria-current",
      "page"
    );
    const home = screen.getByTestId("home-responsive-layout");
    expect(home).toContainElement(screen.getByTestId("home-greet-rail"));
    expect(home).toContainElement(screen.getByTestId("chat-empty"));
    expect(home).toContainElement(screen.getByTestId("home-tasks-rail"));
    expect(home).toContainElement(screen.getByTestId("home-tasks-section"));
    // Inside the shell Home carries no content header of its own; the chat
    // surface is the labelled region.
    const homeSurface = screen.getByRole("region", { name: "Comma assistant" });
    expect(homeSurface).toHaveAttribute("data-variant", "home");
    expect(screen.getByRole("group", { name: "AI input" })).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 2, name: "Tasks" })
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("heading", { name: "What do you want to do" })
    ).not.toBeInTheDocument();
    expect(document.querySelector(".ai-input-small-shell-motion")).toContainElement(
      screen.getByRole("textbox", { name: "AI prompt" })
    );
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveAttribute(
      "data-placeholder",
      "Do anything"
    );
    expect(screen.queryByRole("button", { name: "Send" })).toBeNull();
    expect(screen.getByRole("button", { name: "Voice input" })).toBeEnabled();
  });

  it("starts the Workspace Chat from the Comma Center prompt", async () => {
    seedCommaSession();
    installNativeBridgeMock({ platform: "web" });
    let releaseWorkspaceChat!: () => void;
    const workspaceChatReady = new Promise<void>((resolve) => {
      releaseWorkspaceChat = resolve;
    });
    const fetchMock = installCommaCenterFetchStub({ workspaceChatReady });
    renderCommaApp();

    await userEvent.type(
      await screen.findByRole("textbox", { name: "AI prompt" }),
      "你好，第二条聊天测试"
    );
    await userEvent.click(screen.getByRole("button", { name: "Send" }));
    releaseWorkspaceChat();

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/groups/grp-web/assistant-chat",
      expect.objectContaining({ method: "POST" })
    );
    await waitFor(() =>
      expect(fetchMock).toHaveBeenCalledWith(
        "http://127.0.0.1:4200/v1/comma/groups/grp-web/conversations/conv-created/messages",
        expect.objectContaining({
          method: "POST",
          body: expect.stringContaining("你好，第二条聊天测试"),
        })
      )
    );
  });

  it("sets platform root attributes from native.info", async () => {
    seedCommaSession();
    installNativeBridgeMock({
      native: {
        info: vi.fn(async () => ({
          appVersion: "0.0.1",
          os: "macos" as const,
          platform: "electron" as const,
        })),
      },
    });

    renderCommaApp();

    await waitFor(() =>
      expect(screen.getByRole("main")).toHaveAttribute("data-platform", "electron")
    );
    expect(screen.getByRole("main")).toHaveAttribute("data-os", "macos");
  });

  it("mounts its own toast stack on the Electron client", async () => {
    // Toasts used to be routed off to a separate native window on Electron
    // macOS, where Main sized a transparent BrowserWindow to the card's border
    // box and clipped its shadow. They now render in this window's own tree, so
    // the stack must exist on the platform that previously suppressed it.
    seedCommaSession();
    installNativeBridgeMock({
      native: {
        info: vi.fn(async () => ({
          appVersion: "0.0.1",
          os: "macos" as const,
          platform: "electron" as const,
        })),
      },
    });

    renderCommaApp();
    await waitFor(() =>
      expect(screen.getByRole("main")).toHaveAttribute("data-platform", "electron")
    );

    act(() => {
      toast.info("Copied message", { description: "Message copied to clipboard" });
    });

    expect(await screen.findByText("Copied message")).toBeInTheDocument();
    expect(document.querySelectorAll("[data-sonner-toaster]")).toHaveLength(1);
    act(() => {
      toast.dismissAll();
    });
  });

  it("opens Search over the current route from the window bar", async () => {
    seedCommaSession();
    renderCommaApp();

    const homeLink = await screen.findByRole("link", { name: "Home" });
    expect(homeLink).toHaveAttribute("aria-current", "page");

    await userEvent.click(screen.getByTestId("comma-window-bar-search"));
    expect(await screen.findByRole("dialog", { name: "Search Comma" })).toBeVisible();
    expect(screen.getByRole("combobox", { name: "Search Comma" })).toHaveFocus();
    expect(window.location.hash).not.toBe("#/search");
  });

  it("keeps the command palette closed for a guest Session", async () => {
    commaTestSession = "guest";
    renderCommaApp();

    expect(await screen.findByTestId("comma-guest-banner")).toBeVisible();
    dispatchCommandPaletteShortcut();

    // A guest has no Tasks to search; the palette never opens.
    await expect(
      screen.findByRole("dialog", { name: "Search Comma" }, { timeout: 200 })
    ).rejects.toThrow();
  });

  it("ignores the Chat Sidebar shortcut in a guest Session", async () => {
    commaTestSession = "guest";
    renderCommaApp();

    expect(await screen.findByTestId("comma-guest-banner")).toBeVisible();
    const chatSidebar = screen.getByTestId("chat-sidebar");
    dispatchPrimaryChord("KeyB", { altKey: true });

    expect(chatSidebar).toHaveAttribute("data-open", "false");
  });

  it("shows the current Search shortcut in the command palette footer", async () => {
    seedAppShortcutOverrides({
      "go-search": sequenceKeybinding("KeyS", "KeyF"),
    });
    seedCommaSession();
    renderCommaApp();

    await userEvent.click(await screen.findByTestId("comma-window-bar-search"));

    const commandHint = screen.getByText("Command Search").parentElement;
    expect(commandHint).not.toBeNull();
    expect(
      Array.from(commandHint!.querySelectorAll("kbd"), (keycap) => keycap.textContent)
    ).toEqual(["S", "F"]);
  });

  it("shows a bounded recent Task history, previews the newest Task, and opens it", async () => {
    seedCommaSession();
    window.location.hash = "#/settings";
    const previewRequests: string[] = [];
    const history = Array.from({ length: 21 }, (_, index) => ({
      group_id: "grp-history",
      id: `cnv-history-${index + 1}`,
      kind: "agent_task" as const,
      status: "completed",
      title: index === 20 ? "Newest history task" : `History task ${index + 1}`,
      updated_at: index + 1,
    }));
    const productInbox = createProductInboxProjectionHarness({
      initial: productInboxResult(
        { groupId: "grp-history", id: "wsp-history", name: "History" },
        [
          ...history,
          {
            group_id: "grp-history",
            id: "cnv-chat",
            kind: "user_chat" as const,
            status: "active",
            title: "Not a Task",
            updated_at: 100,
          },
        ]
      ),
    });
    installCommaFetchStub(async (url: string, init?: RequestInit) => {
      const parsedUrl = new URL(url);
      const method = init?.method ?? "GET";
      if (
        method === "GET" &&
        parsedUrl.pathname ===
          "/v1/comma/groups/grp-history/conversations/cnv-history-21"
      ) {
        previewRequests.push("cnv-history-21");
        return jsonResponse({
          ...history[20]!,
          messages: [
            {
              actor_type: "user",
              content: [{ text: "Can you finish the command palette?", type: "text" }],
              kind: "message",
              message_id: "msg-history-user",
              user_id: "usr-history",
            },
            {
              actor_type: "agent",
              agent_id: "agt-history",
              content: [{ text: "The Task preview is ready.", type: "text" }],
              kind: "message",
              message_id: "msg-history-assistant",
            },
          ],
        });
      }
      return jsonResponse({ error: `unhandled ${method} ${parsedUrl.pathname}` }, 404);
    });
    renderCommaApp(productInbox.controller);

    expect(
      await screen.findByRole("heading", { level: 1, name: "General" })
    ).toBeVisible();
    dispatchCommandPaletteShortcut();
    expect(await screen.findByRole("dialog", { name: "Search Comma" })).toBeVisible();

    const newestTask = await screen.findByRole("option", {
      name: /Newest history task/,
    });
    expect(screen.getAllByRole("option")).toHaveLength(20);
    expect(
      screen.queryByRole("option", { name: /^History task 1(?:\s|$)/ })
    ).toBeNull();
    expect(screen.queryByRole("option", { name: /Not a Task/ })).toBeNull();
    await waitFor(() => expect(newestTask).toHaveAttribute("aria-selected", "true"));
    expect(await screen.findByText("The Task preview is ready.")).toBeVisible();
    expect(previewRequests).toEqual(["cnv-history-21"]);
    expect(productInbox.retain).toHaveBeenCalled();

    await userEvent.click(newestTask);

    await waitFor(() =>
      expect(window.location.hash).toBe(
        "#/tasks/wsp-history/grp-history/cnv-history-21"
      )
    );
  }, 10_000);

  it("loads a Task preview after confirmed pointer intent and cancels the previous preview", async () => {
    seedCommaSession();
    window.location.hash = "#/settings";
    let firstPreviewSignal: AbortSignal | undefined;
    const previewRequests: string[] = [];
    const tasks = [
      {
        group_id: "grp-hover",
        id: "cnv-hover-first",
        kind: "agent_task" as const,
        status: "active",
        title: "First preview",
        updated_at: 2,
      },
      {
        group_id: "grp-hover",
        id: "cnv-hover-second",
        kind: "agent_task" as const,
        status: "active",
        title: "Second preview",
        updated_at: 1,
      },
    ];
    const productInbox = createProductInboxProjectionHarness({
      initial: productInboxResult(
        { groupId: "grp-hover", id: "wsp-hover", name: "Hover" },
        tasks
      ),
    });
    installCommaFetchStub(async (url: string, init?: RequestInit) => {
      const parsedUrl = new URL(url);
      const method = init?.method ?? "GET";
      if (
        method === "GET" &&
        parsedUrl.pathname ===
          "/v1/comma/groups/grp-hover/conversations/cnv-hover-first"
      ) {
        previewRequests.push("cnv-hover-first");
        firstPreviewSignal = init?.signal ?? undefined;
        return new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener(
            "abort",
            () => reject(new DOMException("Aborted", "AbortError")),
            { once: true }
          );
        });
      }
      if (
        method === "GET" &&
        parsedUrl.pathname ===
          "/v1/comma/groups/grp-hover/conversations/cnv-hover-second"
      ) {
        previewRequests.push("cnv-hover-second");
        return jsonResponse({
          group_id: "grp-hover",
          id: "cnv-hover-second",
          kind: "agent_task",
          messages: [
            {
              actor_type: "agent",
              agent_id: "agt-hover",
              content: [{ text: "Second Task preview", type: "text" }],
              kind: "message",
              message_id: "msg-hover-second",
            },
          ],
          status: "active",
          title: "Second preview",
          updated_at: 1,
        });
      }
      return jsonResponse({ error: `unhandled ${method} ${parsedUrl.pathname}` }, 404);
    });
    renderCommaApp(productInbox.controller);

    expect(
      await screen.findByRole("heading", { level: 1, name: "General" })
    ).toBeVisible();
    dispatchCommandPaletteShortcut();
    expect(await screen.findByRole("dialog", { name: "Search Comma" })).toBeVisible();
    await waitFor(() => expect(previewRequests).toEqual(["cnv-hover-first"]));

    const secondPreview = screen.getByRole("option", { name: /Second preview/ });
    fireEvent.pointerMove(secondPreview, { pointerType: "mouse" });

    expect(previewRequests).toEqual(["cnv-hover-first"]);
    expect(firstPreviewSignal?.aborted).toBe(false);
    expect(secondPreview).toHaveAttribute("aria-selected", "true");
    await waitFor(() =>
      expect(previewRequests).toEqual(["cnv-hover-first", "cnv-hover-second"])
    );
    expect(await screen.findByText("Second Task preview")).toBeVisible();
    expect(firstPreviewSignal?.aborted).toBe(true);
  });

  it("keeps the preview aligned when the Task list reorders after hover", async () => {
    seedCommaSession();
    window.location.hash = "#/settings";
    const previewRequests: string[] = [];
    const tasks = [
      {
        group_id: "grp-hover-race",
        id: "cnv-hover-race-first",
        kind: "agent_task" as const,
        status: "active",
        title: "Race first",
        updated_at: 3,
      },
      {
        group_id: "grp-hover-race",
        id: "cnv-hover-race-second",
        kind: "agent_task" as const,
        status: "active",
        title: "Race second",
        updated_at: 2,
      },
      {
        group_id: "grp-hover-race",
        id: "cnv-hover-race-third",
        kind: "agent_task" as const,
        status: "active",
        title: "Race third",
        updated_at: 1,
      },
    ];
    const productInbox = createProductInboxProjectionHarness({
      initial: productInboxResult(
        {
          groupId: "grp-hover-race",
          id: "wsp-hover-race",
          name: "Hover race",
        },
        tasks
      ),
    });
    installCommaFetchStub(async (url: string, init?: RequestInit) => {
      const path = requestPath(url);
      const method = init?.method ?? "GET";
      if (
        method === "GET" &&
        path === "/v1/comma/groups/grp-hover-race/conversations/cnv-hover-race-first"
      ) {
        previewRequests.push("cnv-hover-race-first");
        return jsonResponse({
          ...tasks[0]!,
          messages: [
            {
              actor_type: "agent",
              agent_id: "agt-hover-race",
              content: [{ text: "Race first preview", type: "text" }],
              kind: "message",
              message_id: "msg-hover-race-first",
            },
          ],
        });
      }
      if (
        method === "GET" &&
        path === "/v1/comma/groups/grp-hover-race/conversations/cnv-hover-race-second"
      ) {
        previewRequests.push("cnv-hover-race-second");
        return jsonResponse({
          ...tasks[1]!,
          messages: [
            {
              actor_type: "agent",
              agent_id: "agt-hover-race",
              content: [{ text: "Race second preview", type: "text" }],
              kind: "message",
              message_id: "msg-hover-race-second",
            },
          ],
        });
      }
      return jsonResponse({ error: `unhandled ${method} ${path}` }, 404);
    });
    renderCommaApp(productInbox.controller);

    expect(
      await screen.findByRole("heading", { level: 1, name: "General" })
    ).toBeVisible();
    dispatchCommandPaletteShortcut();
    expect(await screen.findByText("Race first preview")).toBeVisible();

    const secondTask = screen.getByRole("option", { name: /Race second/ });
    fireEvent.pointerMove(secondTask, { pointerType: "mouse" });
    expect(previewRequests).toEqual(["cnv-hover-race-first"]);
    expect(secondTask).toHaveAttribute("aria-selected", "true");
    await waitFor(() =>
      expect(previewRequests).toEqual(["cnv-hover-race-first", "cnv-hover-race-second"])
    );
    expect(await screen.findByText("Race second preview")).toBeVisible();
    await waitFor(() => expect(secondTask).toHaveAttribute("aria-selected", "true"));

    act(() => {
      productInbox.emit(
        productInboxResult(
          {
            groupId: "grp-hover-race",
            id: "wsp-hover-race",
            name: "Hover race",
          },
          [{ ...tasks[2]!, updated_at: 4 }, tasks[0]!, tasks[1]!]
        )
      );
    });

    expect(await screen.findByText("Race second preview")).toBeVisible();
    expect(secondTask).toHaveAttribute("aria-selected", "true");
    expect(screen.queryByText("Race first preview")).toBeNull();
    expect(previewRequests).toEqual(["cnv-hover-race-first", "cnv-hover-race-second"]);
  });

  it("keeps one-character Task queries local and searches two-character terms", async () => {
    seedCommaSession();
    let searchRequests = 0;
    installCommaFetchStub(async (url: string, init?: RequestInit) => {
      const parsedUrl = new URL(url);
      const method = init?.method ?? "GET";
      if (method === "GET" && parsedUrl.pathname === "/v1/comma/workspaces") {
        return jsonResponse({
          data: [{ group_id: "grp-search", id: "wsp-search", name: "Search" }],
        });
      }
      if (
        method === "GET" &&
        parsedUrl.pathname === "/v1/comma/groups/grp-search/conversations/search"
      ) {
        searchRequests += 1;
        expect(parsedUrl.searchParams.get("q")).toBe("智能");
        return jsonResponse({
          data: [
            {
              conversation_id: "cnv-ai",
              highlights: [{ start: 0, end: 2 }],
              matched_field: "title",
              snippet: "智能路线图",
              title: "智能路线图",
            },
          ],
        });
      }
      return jsonResponse({ error: `unhandled ${method} ${parsedUrl.pathname}` }, 404);
    });
    renderCommaApp();

    await userEvent.click(await screen.findByTestId("comma-window-bar-search"));
    const input = screen.getByRole("combobox", { name: "Search Comma" });
    await userEvent.type(input, "智");
    expect(
      screen.getByText("Type at least 2 characters to search tasks")
    ).toBeVisible();
    expect(searchRequests).toBe(0);

    await userEvent.clear(input);
    await userEvent.type(input, "e\u0301");
    expect(
      screen.getByText("Type at least 2 characters to search tasks")
    ).toBeVisible();
    expect(searchRequests).toBe(0);

    await userEvent.clear(input);
    await userEvent.type(input, "智");
    await userEvent.type(input, "能");
    expect(await screen.findByRole("option", { name: /智能路线图/ })).toBeVisible();
    expect(screen.getByText("智能", { selector: "mark" })).toBeVisible();
    expect(searchRequests).toBe(1);
  });

  it("searches indexed Task content, highlights the match, and opens the Task", async () => {
    seedCommaSession();
    const snippet = `…${"前".repeat(48)}archive rollout`;
    const highlightStart = snippet.indexOf("archive");
    installCommaFetchStub(async (url: string, init?: RequestInit) => {
      const path = requestPath(url);
      const method = init?.method ?? "GET";
      if (method === "GET" && path === "/v1/comma/workspaces") {
        return jsonResponse({
          data: [{ group_id: "grp-search", id: "wsp-search", name: "Search" }],
        });
      }
      if (
        method === "GET" &&
        path === "/v1/comma/groups/grp-search/conversations/search"
      ) {
        return jsonResponse({
          data: [
            {
              conversation_id: "cnv-search",
              highlights: [{ start: highlightStart, end: highlightStart + 7 }],
              matched_field: "content",
              snippet,
              title: "Release checklist",
              updated_at: 2,
            },
          ],
        });
      }
      return jsonResponse({ error: `unhandled ${method} ${path}` }, 404);
    });
    renderCommaApp();

    await userEvent.click(await screen.findByTestId("comma-window-bar-search"));
    await userEvent.type(
      screen.getByRole("combobox", { name: "Search Comma" }),
      "archive"
    );

    const releaseChecklist = await screen.findByRole("option", {
      name: /Release checklist/,
    });
    expect(releaseChecklist).toBeVisible();
    const subtitle = releaseChecklist.querySelector(
      '[data-slot="command-palette-item-subtitle"]'
    );
    expect(subtitle).toHaveTextContent(/^…前{12}archive rollout$/u);
    expect(subtitle?.querySelector("mark")).toHaveTextContent("archive");
    expect(
      releaseChecklist.querySelector('[data-slot="command-palette-item-highlight"]')
    ).toBeNull();
    expect(releaseChecklist).not.toHaveAccessibleName(/Tasks/);
    await userEvent.click(releaseChecklist);

    await waitFor(() =>
      expect(window.location.hash).toBe("#/tasks/wsp-search/grp-search/cnv-search")
    );
  });

  it("shows the first content match as a subtitle when the title also matches", async () => {
    seedCommaSession();
    const title = "调研 Cursor 并制作网页";
    const contentSnippet = "已完成中文简报网页，并附带 HTML";
    installCommaFetchStub(async (url: string, init?: RequestInit) => {
      const path = requestPath(url);
      const method = init?.method ?? "GET";
      if (method === "GET" && path === "/v1/comma/workspaces") {
        return jsonResponse({
          data: [{ group_id: "grp-search", id: "wsp-search", name: "Search" }],
        });
      }
      if (
        method === "GET" &&
        path === "/v1/comma/groups/grp-search/conversations/search"
      ) {
        return jsonResponse({
          data: [
            {
              content_match: {
                highlights: [{ start: 7, end: 9 }],
                snippet: contentSnippet,
              },
              conversation_id: "cnv-title-and-content",
              highlights: [{ start: 13, end: 15 }],
              matched_field: "title",
              snippet: title,
              title,
            },
          ],
        });
      }
      return jsonResponse({ error: `unhandled ${method} ${path}` }, 404);
    });
    renderCommaApp();

    await userEvent.click(await screen.findByTestId("comma-window-bar-search"));
    await userEvent.type(
      screen.getByRole("combobox", { name: "Search Comma" }),
      "网页"
    );

    const result = await screen.findByRole("option", { name: /调研 Cursor/ });
    const resultTitle = result.querySelector(
      '[data-slot="command-palette-item-title"]'
    );
    const subtitle = result.querySelector(
      '[data-slot="command-palette-item-subtitle"]'
    );

    expect(resultTitle?.querySelector("mark")).toHaveTextContent("网页");
    expect(subtitle).toHaveTextContent(contentSnippet);
    expect(subtitle?.querySelector("mark")).toHaveTextContent("网页");
  });

  it("shows only Task Search failure without command fallbacks", async () => {
    seedCommaSession();
    installCommaFetchStub(async (url: string, init?: RequestInit) => {
      const path = requestPath(url);
      const method = init?.method ?? "GET";
      if (method === "GET" && path === "/v1/comma/workspaces") {
        return jsonResponse({
          data: [{ group_id: "grp-search", id: "wsp-search", name: "Search" }],
        });
      }
      if (
        method === "GET" &&
        path === "/v1/comma/groups/grp-search/conversations/search"
      ) {
        return jsonResponse({ error: "projection unavailable" }, 503);
      }
      return jsonResponse({ error: `unhandled ${method} ${path}` }, 404);
    });
    renderCommaApp();

    await userEvent.click(await screen.findByTestId("comma-window-bar-search"));
    await userEvent.type(
      screen.getByRole("combobox", { name: "Search Comma" }),
      "font"
    );

    expect(
      await screen.findByText("Unable to search tasks. Try again in a moment.")
    ).toBeVisible();
    expect(screen.queryAllByRole("option")).toHaveLength(0);
  });

  it("shows server-rejected Task queries as actionable validation errors", async () => {
    seedCommaSession();
    installCommaFetchStub(async (url: string, init?: RequestInit) => {
      const path = requestPath(url);
      const method = init?.method ?? "GET";
      if (method === "GET" && path === "/v1/comma/workspaces") {
        return jsonResponse({
          data: [{ group_id: "grp-search", id: "wsp-search", name: "Search" }],
        });
      }
      if (
        method === "GET" &&
        path === "/v1/comma/groups/grp-search/conversations/search"
      ) {
        expect(new URL(url).searchParams.get("q")).toBe("ß".repeat(128));
        return jsonResponse({ error: "q must contain at most 128 characters" }, 400);
      }
      return jsonResponse({ error: `unhandled ${method} ${path}` }, 404);
    });
    renderCommaApp();

    await userEvent.click(await screen.findByTestId("comma-window-bar-search"));
    fireEvent.change(screen.getByRole("combobox", { name: "Search Comma" }), {
      target: { value: "ß".repeat(128) },
    });

    expect(
      await screen.findByText("This search is invalid. Try a shorter query.")
    ).toBeVisible();
    expect(
      screen.queryByText("Unable to search tasks. Try again in a moment.")
    ).not.toBeInTheDocument();
    expect(screen.queryAllByRole("option")).toHaveLength(0);
  });

  it("removes committed Task results as soon as the query request key changes", async () => {
    seedCommaSession();
    let resolveRollout: ((response: Response) => void) | undefined;
    let workspaceRequests = 0;
    const rolloutResponse = new Promise<Response>((resolve) => {
      resolveRollout = resolve;
    });
    installCommaFetchStub(async (url: string, init?: RequestInit) => {
      const parsedUrl = new URL(url);
      const path = parsedUrl.pathname;
      const method = init?.method ?? "GET";
      if (method === "GET" && path === "/v1/comma/workspaces") {
        workspaceRequests += 1;
        return jsonResponse({
          data: [{ group_id: "grp-search", id: "wsp-search", name: "Search" }],
        });
      }
      if (
        method === "GET" &&
        path === "/v1/comma/groups/grp-search/conversations/search"
      ) {
        if (parsedUrl.searchParams.get("q") === "rollout") return rolloutResponse;
        return jsonResponse({
          data: [
            {
              conversation_id: "cnv-search",
              highlights: [{ start: 12, end: 19 }],
              matched_field: "content",
              snippet: "Prepare the archive rollout",
              title: "Release checklist",
            },
          ],
        });
      }
      return jsonResponse({ error: `unhandled ${method} ${path}` }, 404);
    });
    renderCommaApp();

    await userEvent.click(await screen.findByTestId("comma-window-bar-search"));
    const input = screen.getByRole("combobox", { name: "Search Comma" });
    await userEvent.type(input, "archive");
    expect(
      await screen.findByRole("option", { name: /Release checklist/ })
    ).toBeVisible();
    const workspaceRequestsAfterFirstResult = workspaceRequests;

    await userEvent.clear(input);
    await userEvent.type(input, "rollout");
    expect(
      screen.queryByRole("option", { name: /Release checklist/ })
    ).not.toBeInTheDocument();
    expect(screen.getByRole("progressbar", { name: "Searching tasks…" })).toBeVisible();

    await act(async () => {
      resolveRollout?.(jsonResponse({ data: [] }));
      await Promise.resolve();
    });
    expect(await screen.findByText("No results found")).toBeVisible();
    expect(workspaceRequests).toBe(workspaceRequestsAfterFirstResult);
  });

  it("opens the workspace plugin catalog from the shared product sidebar", async () => {
    seedCommaSession();
    installCommaFetchStub(async (url: string, init?: RequestInit) => {
      const path = requestPath(url);
      const method = init?.method ?? "GET";

      if (method === "GET" && path === "/v1/comma/workspaces") {
        return jsonResponse({
          data: [
            {
              group_id: "grp_plugins",
              id: "wsp_plugins",
              name: "Plugin Workspace",
              status: "ready",
            },
          ],
        });
      }

      if (method === "GET" && path === "/v1/comma/workspaces/wsp_plugins/plugins") {
        return jsonResponse({
          data: [
            {
              id: "linear",
              name: "Linear",
              summary: "Plan and track product work",
              description: "Plan and track product work",
              brand: "linear",
              category: "Integrations",
              installed: false,
              locked: false,
              mcps: [],
              skills: [],
            },
          ],
        });
      }

      return jsonResponse({ error: `unhandled ${method} ${path}` }, 404);
    });
    renderCommaApp();

    await userEvent.click(await screen.findByRole("link", { name: "Plugins" }));

    expect(await screen.findByRole("heading", { name: "Plugins" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Add Linear" })).toBeVisible();
    expect(screen.getByRole("link", { name: "Plugins" })).toHaveAttribute(
      "aria-current",
      "page"
    );
    expect(window.location.hash).toBe("#/plugins");
  });

  it("opens Settings as a modal over the surface the user is on", async () => {
    seedCommaSession();
    renderCommaApp();

    const homeBeforeSettings = await screen.findByTestId("home-responsive-layout");
    const windowBar = screen.getByTestId("comma-window-bar");
    const sidebar = screen.getByRole("complementary", { name: "App sidebar" });
    const content = screen.getByRole("region", { name: "Content" });
    const settingsButton = screen.getByRole("button", { name: "Settings" });
    expect(sidebar).toContainElement(settingsButton);
    expect(settingsButton).not.toHaveAttribute("aria-current");
    expect(screen.queryByRole("dialog", { name: "Settings sections" })).toBeNull();

    await userEvent.click(settingsButton);

    expect(
      await screen.findByRole("heading", { level: 1, name: "General" })
    ).toBeVisible();
    // Settings is a modal, not a place: the location the user was on is left
    // exactly as it was.
    expect(["", "#/"]).toContain(window.location.hash);
    const settingsDialog = screen.getByRole("dialog", { name: "Settings sections" });
    expect(content).not.toContainElement(settingsDialog);
    expect(settingsDialog).toContainElement(
      screen.getByRole("heading", { level: 1, name: "General" })
    );
    expect(settingsDialog).toContainElement(
      screen.getByRole("navigation", { name: "Settings sections" })
    );
    expect(screen.getByRole("button", { name: "General" })).toHaveAttribute(
      "data-selected",
      "true"
    );
    expect(screen.getByRole("button", { name: /Select language/ })).toHaveTextContent(
      "English"
    );
    // The shell stays mounted around it: no full-window Settings layout and no
    // way "back to the app".
    expect(windowBar).toBeInTheDocument();
    expect(sidebar).toBeInTheDocument();
    expect(screen.queryByTestId("comma-settings-layout")).toBeNull();
    expect(screen.queryByRole("link", { name: "Back to app" })).toBeNull();
    expect(settingsDialog.closest("[inert]")).toBeNull();
    expect(settingsButton).toHaveAttribute("data-selected", "true");
    // Home keeps painting behind the modal rather than being swapped out.
    expect(screen.getByTestId("home-responsive-layout")).toBe(homeBeforeSettings);
    expect(homeBeforeSettings).toBeVisible();
    expect(homeBeforeSettings.closest("[inert]")).toBeNull();

    await userEvent.click(screen.getByRole("button", { name: "Close settings" }));

    await waitFor(() =>
      expect(screen.queryByRole("dialog", { name: "Settings sections" })).toBeNull()
    );
    expect(["", "#/"]).toContain(window.location.hash);
    expect(screen.getByTestId("home-responsive-layout")).toBe(homeBeforeSettings);
    expect(settingsButton).toHaveAttribute("data-selected", "false");
    expect(screen.getByRole("link", { name: "Home" })).toHaveAttribute(
      "aria-current",
      "page"
    );
  });

  it("keeps Home mounted while Tasks is showing and returns to Home without remounting", async () => {
    seedCommaSession();
    renderCommaApp();

    const home = await screen.findByTestId("home-responsive-layout");
    expect(home).toBeVisible();

    fireEvent.keyDown(window, { code: "KeyG" });
    fireEvent.keyDown(window, { code: "KeyT" });
    await waitFor(() => expect(window.location.hash).toBe("#/tasks"));
    expect(home).toBe(screen.getByTestId("home-responsive-layout"));
    expect(home).not.toBeVisible();
    expect(home.closest(`[${COMMA_SURFACE_PAUSED_ATTRIBUTE}="true"]`)).not.toBeNull();

    await userEvent.click(screen.getByRole("link", { name: "Home" }));
    await waitFor(() => expect(window.location.hash).toBe("#/"));
    expect(screen.getByTestId("home-responsive-layout")).toBe(home);
    expect(home).toBeVisible();
    expect(home.closest("[inert]")).toBeNull();
  });

  it("opens Settings directly without mounting or bootstrapping Home", async () => {
    seedCommaSession();
    window.location.hash = "#/settings";
    const fetchMock = installCommaFetchStub();

    renderCommaApp();

    expect(
      await screen.findByRole("heading", { level: 1, name: "General" })
    ).toBeVisible();
    expect(screen.queryByTestId("home-responsive-layout")).not.toBeInTheDocument();
    // The shell is mounted for every product location; only Home is skipped.
    expect(screen.getByTestId("comma-window-bar")).toBeInTheDocument();
    expect(screen.getByTestId("comma-sidebar-slot")).toBeInTheDocument();
    expect(
      screen.getByRole("dialog", { name: "Settings sections" })
    ).toBeInTheDocument();
    expect(
      fetchMock.mock.calls.some(([input, init]) => {
        const method = init?.method ?? "GET";
        const url = String(input);
        return (
          method === "POST" &&
          (url.endsWith("/v1/comma/me/bootstrap") || url.endsWith("/assistant-chat"))
        );
      })
    ).toBe(false);
  });

  it("keeps the rail toggle shortcut active on Settings", async () => {
    seedAppShortcutOverrides({
      "toggle-left-sidebar": sequenceKeybinding("KeyG", "KeyB"),
    });
    seedCommaSession();
    window.location.hash = "#/settings";
    renderCommaApp();

    expect(
      await screen.findByRole("heading", { level: 1, name: "General" })
    ).toBeVisible();
    const sidebarSlot = screen.getByTestId("comma-sidebar-slot");
    const toggle = screen.getByRole("button", { name: "Collapse sidebar" });
    const content = screen.getByRole("region", { name: "Content" });
    expect(sidebarSlot).toHaveAttribute("data-collapsed", "false");
    expect(toggle).toHaveAttribute("aria-expanded", "true");

    fireEvent.keyDown(window, { code: "KeyG" });
    fireEvent.keyDown(window, { code: "KeyB" });

    await waitFor(() => expect(sidebarSlot).toHaveAttribute("data-collapsed", "true"));
    expect(toggle).toHaveAttribute("aria-expanded", "false");
    expect(content).toHaveAttribute("data-sidebar-collapsed", "true");
    // Settings stays put; only the rail slot gave up its width.
    expect(
      screen.getByRole("dialog", { name: "Settings sections" })
    ).toBeInTheDocument();
    expect(window.location.hash).toBe("#/settings");

    // The modal owns pointer input while it is open, so the toggle behind it
    // only takes clicks again once Settings closes.
    await userEvent.click(screen.getByRole("button", { name: "Close settings" }));
    await waitFor(() =>
      expect(screen.queryByRole("dialog", { name: "Settings sections" })).toBeNull()
    );

    await userEvent.click(toggle);

    expect(sidebarSlot).toHaveAttribute("data-collapsed", "false");
    expect(toggle).toHaveAttribute("aria-expanded", "true");
    expect(content).toHaveAttribute("data-sidebar-collapsed", "false");
  });

  it.each([
    ["Home", "KeyC", "#/"],
    ["Inbox", "KeyI", "#/inbox"],
    ["Tasks", "KeyT", "#/tasks"],
    ["Plugins", "KeyP", "#/plugins"],
  ])(
    "dispatches the divergent Go to %s sequence from the Settings route",
    async (_name, secondCode, targetHash) => {
      seedCommaSession();
      window.location.hash = "#/settings";
      renderCommaApp();

      expect(
        await screen.findByRole("heading", { level: 1, name: "General" })
      ).toBeInTheDocument();

      fireEvent.keyDown(window, { code: "KeyG" });
      fireEvent.keyDown(window, { code: secondCode });

      await waitFor(() => expect(window.location.hash).toBe(targetHash));
    }
  );

  it("opens the Search palette from the Settings route without leaving it", async () => {
    seedCommaSession();
    window.location.hash = "#/settings";
    renderCommaApp();

    expect(
      await screen.findByRole("heading", { level: 1, name: "General" })
    ).toBeInTheDocument();

    const platform = `${
      (navigator as Navigator & { userAgentData?: { platform?: string } }).userAgentData
        ?.platform ?? ""
    } ${navigator.platform} ${navigator.userAgent}`.toLocaleLowerCase();
    const usesCommandAsPrimary =
      platform.includes("mac") ||
      platform.includes("iphone") ||
      platform.includes("ipad");

    fireEvent.keyDown(window, {
      code: "KeyK",
      ctrlKey: !usesCommandAsPrimary,
      metaKey: usesCommandAsPrimary,
    });

    expect(await screen.findByRole("dialog", { name: "Search Comma" })).toBeVisible();
    await waitFor(() =>
      expect(screen.getByRole("combobox", { name: "Search Comma" })).toHaveFocus()
    );
    expect(window.location.hash).toBe("#/settings");
  });

  it("dispatches a customized history chord from the Settings route", async () => {
    seedAppShortcutOverrides({
      "history-back": chordKeybinding("KeyH", { control: true }),
    });
    seedCommaSession();
    renderCommaApp();

    await screen.findByTestId("home-responsive-layout");
    // The rail opens the modal in place, so reach the routed form of Settings
    // the way a deep link does.
    await act(async () => {
      window.location.hash = "#/settings";
    });
    expect(
      await screen.findByRole("dialog", { name: "Settings sections" })
    ).toBeInTheDocument();
    expect(window.location.hash).toBe("#/settings");

    fireEvent.keyDown(window, { code: "KeyH", ctrlKey: true });

    await waitFor(() => expect(["", "#/"]).toContain(window.location.hash));
    expect(screen.queryByRole("dialog", { name: "Settings sections" })).toBeNull();
    expect(screen.getByTestId("home-responsive-layout")).toBeVisible();
  });

  it("shares product sequence candidates across navigation and shell owners", async () => {
    seedAppShortcutOverrides({
      "toggle-left-sidebar": sequenceKeybinding("KeyG", "KeyB"),
    });
    seedCommaSession();
    renderCommaApp();

    const sidebarSlot = await screen.findByTestId("comma-sidebar-slot");
    expect(sidebarSlot).toHaveAttribute("data-collapsed", "false");

    fireEvent.keyDown(window, { code: "KeyG" });
    fireEvent.keyDown(window, { code: "KeyB" });
    await waitFor(() => expect(sidebarSlot).toHaveAttribute("data-collapsed", "true"));

    fireEvent.keyDown(window, { code: "KeyG" });
    fireEvent.keyDown(window, { code: "KeyI" });
    await waitFor(() => expect(window.location.hash).toBe("#/inbox"));

    fireEvent.keyDown(window, { code: "KeyG" });
    fireEvent.keyDown(window, { code: "KeyT" });
    await waitFor(() => expect(window.location.hash).toBe("#/tasks"));

    fireEvent.keyDown(window, { code: "KeyG" });
    fireEvent.keyDown(window, { code: "KeyP" });
    await waitFor(() => expect(window.location.hash).toBe("#/plugins"));

    fireEvent.keyDown(window, { code: "KeyG" });
    fireEvent.keyDown(window, { code: "KeyC" });
    await waitFor(() => expect(window.location.hash).toBe("#/"));
  });

  it("mounts the development layout inspector at the app root", async () => {
    seedCommaSession();
    renderCommaApp();
    await screen.findByRole("complementary", { name: "App sidebar" });
    await vi.dynamicImportSettled();

    fireEvent.keyDown(window, {
      code: "KeyL",
      ctrlKey: true,
      shiftKey: true,
    });

    expect(
      await screen.findByText(/Layout Inspector · hover to inspect/)
    ).toBeInTheDocument();
  });

  it("renders the development runtime workbench as a product-shell-free debug surface", async () => {
    const surfaceList = {
      notch: { available: true, running: false },
      panels: [],
      platform: {
        appVersion: "0.0.1",
        os: "macos" as const,
        platform: "electron" as const,
      },
      views: [],
      windows: [
        {
          bounds: { height: 768, width: 1024, x: 12, y: 24 },
          focused: true,
          id: "win_main",
          lifecycle: "ready" as const,
          owner: { id: "app", kind: "app" as const },
          role: "main-window",
          route: "/",
          state: "normal" as const,
          surfaceId: "win_main",
          visible: true,
        },
        {
          bounds: { height: 760, width: 1180, x: 24, y: 24 },
          focused: false,
          id: "dev_workbench",
          lifecycle: "ready" as const,
          owner: { id: "app", kind: "app" as const },
          role: "dev-workbench",
          route: "/dev/workbench",
          state: "normal" as const,
          surfaceId: "dev_workbench",
          visible: true,
        },
      ],
    } satisfies SurfaceList;

    installNativeBridgeMock({
      native: {
        info: vi.fn(async () => ({
          appVersion: "0.0.1",
          os: "macos" as const,
          platform: "electron" as const,
        })),
      },
      notch: {
        status: vi.fn(async () => ({
          available: true,
          running: false,
        })),
      },
      surfaces: {
        // Workbench snapshots use the state leaf; list remains the public
        // compatibility alias for the same snapshot.
        list: vi.fn(async () => surfaceList),
        onChanged: vi.fn(() => () => undefined),
        state: createTestStateBridge(() => surfaceList),
      },
    });
    window.location.hash = "#/dev/workbench";

    renderCommaApp();

    expect(
      await screen.findByRole("heading", { name: "Runtime Workbench" })
    ).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Sign in to Comma" })).toBeNull();
    expect(screen.queryByRole("complementary", { name: "App sidebar" })).toBeNull();
    expect(await screen.findByText("win_main")).toBeInTheDocument();
    expect(screen.getByText("dev_workbench")).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: /Runtime/ })).toBeInTheDocument();
  });

  it("lets sidebar provider compose concrete sidebar children", () => {
    render(
      <CommaSidebarProvider>
        <CommaSidebarPanel>
          <button type="button">Custom action</button>
        </CommaSidebarPanel>
      </CommaSidebarProvider>
    );

    const slot = screen.getByTestId("comma-sidebar-slot");
    const sidebar = screen.getByRole("complementary", { name: "App sidebar" });
    expect(slot).toHaveAttribute("data-collapsed", "false");
    expect(slot).toHaveStyle({
      "--comma-sidebar-layout-width": "75px",
      "--comma-sidebar-rail-width": "75px",
    });
    expect(slot).toContainElement(sidebar);
    expect(sidebar).toHaveAttribute("data-collapsed", "false");
    expect(screen.getByRole("button", { name: "Custom action" })).toBeInTheDocument();
  });

  it("toggles the sidebar between expanded and collapsed layout widths", async () => {
    seedCommaSession();
    renderCommaApp();

    const toggle = await screen.findByRole("button", { name: "Collapse sidebar" });
    const slot = screen.getByTestId("comma-sidebar-slot");
    const sidebar = screen.getByTestId("comma-sidebar");
    const content = screen.getByRole("region", { name: "Content" });

    expect(slot).toHaveAttribute("data-collapsed", "false");
    expect(sidebar).toHaveAttribute("data-collapsed", "false");
    expect(slot).toHaveStyle({
      "--comma-sidebar-layout-width": "75px",
      "--comma-sidebar-rail-width": "75px",
    });
    expect(content).toHaveAttribute("data-sidebar-collapsed", "false");
    expect(content).toHaveClass("bg-main-panel-bg");
    expect(content).not.toHaveClass("border-[0.5px]");
    expect(content).not.toHaveClass("border-primary");
    expect(toggle).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByRole("button", { name: "Back" })).toBeInTheDocument();

    await userEvent.click(toggle);

    expect(slot).toHaveAttribute("data-collapsed", "true");
    expect(sidebar).toHaveAttribute("data-collapsed", "true");
    // The slot gives up its width; the rail keeps its own and slides under
    // the content panel.
    expect(slot).toHaveStyle({
      "--comma-sidebar-layout-width": "var(--spacing-md)",
      "--comma-sidebar-rail-width": "75px",
    });
    expect(content).toHaveAttribute("data-sidebar-collapsed", "true");
    expect(toggle).toHaveAttribute("aria-expanded", "false");
    // History lives in the window bar now, so collapsing the rail keeps it.
    expect(screen.getByRole("button", { name: "Back" })).toBeInTheDocument();

    await userEvent.click(toggle);

    expect(slot).toHaveAttribute("data-collapsed", "false");
    expect(sidebar).toHaveAttribute("data-collapsed", "false");
    expect(slot).toHaveStyle({
      "--comma-sidebar-layout-width": "75px",
      "--comma-sidebar-rail-width": "75px",
    });
    expect(content).toHaveAttribute("data-sidebar-collapsed", "false");
    expect(toggle).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByRole("button", { name: "Back" })).toBeInTheDocument();
  });

  it("renders the icon rail as primary navigation with Settings at its foot", async () => {
    seedCommaSession();
    renderCommaApp();

    const sidebar = await screen.findByRole("complementary", { name: "App sidebar" });
    const nav = within(sidebar).getByRole("navigation", { name: "Primary" });
    const links = within(nav).getAllByRole("link");

    // Drive needs the Electron host's synchronicity node, so the web rail omits it.
    expect(links).toHaveLength(4);
    ["Home", "Inbox", "Tasks", "Plugins"].forEach((name, index) => {
      expect(links[index]).toHaveAccessibleName(name);
      expect(links[index]).toHaveAttribute("data-slot", "left-rail-item");
      expect(links[index]).toHaveClass("comma-sidebar-link");
    });
    expect(links.map((link) => link.getAttribute("href"))).toEqual([
      "#/",
      "#/inbox",
      "#/tasks",
      "#/plugins",
    ]);
    expect(links.map((link) => link.getAttribute("aria-current"))).toEqual([
      "page",
      null,
      null,
      null,
    ]);
    expect(links.map((link) => link.getAttribute("data-selected"))).toEqual([
      "true",
      "false",
      "false",
      "false",
    ]);
    expect(
      within(nav)
        .getByRole("link", { name: "Inbox" })
        .querySelector('[data-slot="left-rail-item-badge"]')
    ).toBeNull();
    expect(screen.queryByRole("link", { name: "Search" })).toBeNull();
    expect(screen.queryByRole("link", { name: "Comma assistant" })).toBeNull();
    // The profile avatar opens Settings from the foot of the rail, outside
    // primary navigation.
    const settingsButton = within(sidebar).getByRole("button", { name: "Settings" });
    expect(nav).not.toContainElement(settingsButton);
    // Settings opens a modal, so its item is a button with no location of its own.
    expect(settingsButton).not.toHaveAttribute("href");
    expect(settingsButton).toHaveAttribute("data-slot", "left-rail-item");
    expect(settingsButton).toHaveClass("comma-sidebar-link");
    expect(settingsButton).not.toHaveAttribute("aria-current");
    expect(settingsButton).toHaveAttribute("data-selected", "false");
    expect(settingsButton.querySelector(".comma-user-avatar")).toHaveTextContent("PE");

    fireEvent.keyDown(window, { code: "KeyG" });
    fireEvent.keyDown(window, { code: "KeyI" });

    await waitFor(() => expect(window.location.hash).toBe("#/inbox"));
    expect(within(nav).getByRole("link", { name: "Inbox" })).toHaveAttribute(
      "aria-current",
      "page"
    );
    expect(within(nav).getByRole("link", { name: "Home" })).not.toHaveAttribute(
      "aria-current"
    );

    await userEvent.click(settingsButton);

    // The modal marks its rail item selected without taking the route: Inbox
    // is still the location behind it (the rail itself is hidden from the
    // accessibility tree for as long as the modal is open).
    await waitFor(() =>
      expect(settingsButton).toHaveAttribute("data-selected", "true")
    );
    expect(window.location.hash).toBe("#/inbox");
    expect(within(nav).queryByRole("link", { name: "Inbox" })).toBeNull();
    expect(nav.querySelector('a[href="#/inbox"]')).toHaveAttribute(
      "aria-current",
      "page"
    );
  });

  it("hosts history, the Chat Sidebar toggle, recent tasks and the search hint in the window bar", async () => {
    seedCommaSession();
    const { container } = renderCommaApp();

    const windowBar = await screen.findByTestId("comma-window-bar");
    const sidebar = screen.getByRole("complementary", { name: "App sidebar" });
    const content = screen.getByRole("region", { name: "Content" });
    const chatToggle = screen.getByRole("button", { name: "Toggle chat sidebar" });

    expect(windowBar).toHaveClass("comma-window-titlebar-region");
    expect(container.querySelector(".comma-window-frame")).toContainElement(windowBar);
    expect(sidebar).not.toContainElement(windowBar);
    expect(content).not.toContainElement(windowBar);
    // The web shell has no traffic lights, so history leads the row.
    expect(screen.queryByTestId("comma-native-window-controls")).toBeNull();
    for (const name of ["Back", "Forward", "Recent tasks"]) {
      expect(windowBar).toContainElement(screen.getByRole("button", { name }));
    }
    expect(windowBar).toContainElement(chatToggle);
    expect(content).not.toContainElement(chatToggle);
    expect(chatToggle).toHaveClass("comma-chat-sidebar-toggle");
    // The window bar's control is the one Chat Sidebar toggle in the shell.
    expect(screen.getByTestId("chat-sidebar-toggle")).toBe(chatToggle);
    expect(chatToggle).toHaveAttribute("aria-expanded", "false");
    expect(screen.queryByTestId("comma-window-titlebar-controls")).toBeNull();

    const searchHint = screen.getByTestId("comma-window-bar-search");
    expect(windowBar).toContainElement(searchHint);
    expect(searchHint).toHaveTextContent(/^Use .+ for search$/);

    await userEvent.click(searchHint);

    // The hint raises the command palette over the current route; Search is
    // not a location.
    expect(await screen.findByRole("dialog", { name: "Search Comma" })).toBeVisible();
    expect(window.location.hash).not.toBe("#/search");
  });

  it("shows a circular unread badge on the Inbox tab when Inbox has unread items", async () => {
    seedCommaSession();
    const productInbox = createProductInboxProjectionHarness({
      initial: productInboxResult(
        { groupId: "grp-inbox-badge", id: "wsp-inbox-badge", name: "Inbox" },
        [
          {
            group_id: "grp-inbox-badge",
            id: "cnv-review",
            kind: "agent_task",
            status: "needs_review",
            title: "Review draft",
            updated_at: 10,
          },
        ]
      ),
    });
    renderCommaApp(productInbox.controller);

    const sidebar = await screen.findByRole("complementary", { name: "App sidebar" });
    const inbox = within(sidebar).getByRole("link", { name: "Inbox" });
    await waitFor(() =>
      expect(inbox.querySelector('[data-slot="left-rail-item-badge"]')).not.toBeNull()
    );
    expect(
      within(sidebar)
        .getByRole("link", { name: "Home" })
        .querySelector('[data-slot="left-rail-item-badge"]')
    ).toBeNull();

    act(() => {
      productInbox.emit(
        productInboxResult(
          { groupId: "grp-inbox-badge", id: "wsp-inbox-badge", name: "Inbox" },
          [
            {
              group_id: "grp-inbox-badge",
              id: "cnv-done",
              kind: "agent_task",
              status: "completed",
              title: "Done task",
              updated_at: 11,
            },
          ]
        )
      );
    });
    await waitFor(() =>
      expect(inbox.querySelector('[data-slot="left-rail-item-badge"]')).toBeNull()
    );
  });
});

function seedCommaSession() {
  commaTestSession = true;
}

function dispatchCommandPaletteShortcut() {
  dispatchPrimaryChord("KeyK");
}

function dispatchPrimaryChord(code: string, { altKey = false } = {}) {
  const platform = `${
    (navigator as Navigator & { userAgentData?: { platform?: string } }).userAgentData
      ?.platform ?? ""
  } ${navigator.platform} ${navigator.userAgent}`.toLocaleLowerCase();
  const usesCommandAsPrimary =
    platform.includes("mac") ||
    platform.includes("iphone") ||
    platform.includes("ipad");
  fireEvent.keyDown(window, {
    altKey,
    code,
    ctrlKey: !usesCommandAsPrimary,
    metaKey: usesCommandAsPrimary,
  });
}

function renderCommaApp(
  productInboxController: ProductInboxProjectionController = createProductInboxProjectionHarness(
    {
      initial: { items: [], source: "live-sync" },
    }
  ).controller
) {
  return renderWithSessionHost(
    <ProductInboxProjectionProvider controller={productInboxController}>
      <CommaApp />
    </ProductInboxProjectionProvider>
  );
}

function productInboxResult(
  workspace: { groupId: string; id: string; name: string },
  conversations: readonly {
    group_id: string;
    id: string;
    kind: ProductInboxItem["kind"];
    status: string;
    title: string;
    updated_at: number;
  }[]
): ProductInboxListResult {
  return {
    activeWorkspaceId: workspace.id,
    items: conversations.map((conversation) => ({
      conversationId: conversation.id,
      freshness: "fresh",
      groupId: conversation.group_id,
      id: `${workspace.id}:${conversation.id}`,
      kind: conversation.kind,
      source: "salix.conversation",
      status: conversation.status,
      title: conversation.title,
      updatedAt: conversation.updated_at,
      workspaceId: workspace.id,
      workspaceName: workspace.name,
    })),
    source: "live-sync",
    workspaces: [
      { group_id: workspace.groupId, id: workspace.id, name: workspace.name },
    ],
  };
}

function renderWithSessionHost(element: ReactElement) {
  recordOnboardingCompleted();
  const controller = createWebSessionHostController({
    apiBaseUrl: "http://127.0.0.1:4200",
    ports: createTestWebSessionHostPorts(),
  });
  sessionHostControllers.push(controller);
  return render(
    <CommaWebClientSettingsProvider>
      <CommaSessionHostProvider controller={controller}>
        {element}
      </CommaSessionHostProvider>
    </CommaWebClientSettingsProvider>
  );
}

// The test accounts have finished first-launch onboarding on this device, so
// the shell renders without its overlay. Merged into any settings a test seeds.
function recordOnboardingCompleted() {
  const stored = localStorage.getItem(commaClientSettingsStorageKey);
  const settings = stored
    ? JSON.parse(stored)
    : structuredClone(defaultCommaClientSettings);
  localStorage.setItem(
    commaClientSettingsStorageKey,
    JSON.stringify({
      ...settings,
      onboardingCompletedUserIds: ["usr_1", "usr_google", "usr_linked"],
    })
  );
}

function seedAppShortcutOverrides(appShortcutOverrides: Record<string, unknown>) {
  localStorage.setItem(
    commaClientSettingsStorageKey,
    JSON.stringify({
      ...structuredClone(defaultCommaClientSettings),
      appShortcutOverrides:
        commaClientAppShortcutOverridesSchema.parse(appShortcutOverrides),
    })
  );
}

function createTestWebSessionHostPorts(): WebSessionHostPorts {
  return {
    broadcast: {
      open() {
        return {
          close() {},
          publish() {},
          subscribe() {
            return () => {};
          },
        };
      },
    },
    documentOrigin: window.location.origin,
    fetch: (input, init) => globalThis.fetch(input, init),
    locks: {
      async request(_name, signal, work) {
        if (signal.aborted) {
          throw new DOMException("Lock request aborted.", "AbortError");
        }
        return work();
      },
    },
    now: () => Date.now(),
    randomId: () => `index-test-session-host-${++nextSessionHostId}`,
    schedule: (callback, delayMs) => window.setTimeout(callback, delayMs),
    storage: {
      read: (key) => localStorage.getItem(key),
      write: (key, value) => localStorage.setItem(key, value),
    },
    unschedule: (handle) => window.clearTimeout(handle),
  };
}

function installCommaFetchStub(
  handler: (url: string, init?: RequestInit) => Promise<Response> = async (
    url,
    init
  ) => {
    const method = init?.method ?? "GET";
    return jsonResponse({ error: `unhandled ${method} ${requestPath(url)}` }, 404);
  },
  options: {
    logout?: ((url: string, init?: RequestInit) => Promise<Response>) | undefined;
  } = {}
) {
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.toString()
          : input.url;
    const path = requestPath(url);
    const method = init?.method ?? "GET";

    if (method === "GET" && path === "/v1/comma/auth/session") {
      if (!commaTestSession) {
        return jsonResponse({ error: "unauthorized" }, 401);
      }

      return jsonResponse({
        expires_at: 4_102_444_800,
        session_id: "11111111-1111-4111-8111-111111111111",
        user:
          commaTestSession === "guest"
            ? { id: "usr_guest", email: "g-1@guest.comma.invalid", kind: "guest" }
            : {
                id: "usr_1",
                email: "person@example.com",
                name: "Person Example",
              },
      });
    }

    if (method === "POST" && path === "/v1/comma/auth/logout") {
      if (options.logout) {
        return options.logout(url, init);
      }
      commaTestSession = undefined;
      return jsonResponse({ signed_out: true });
    }

    return handler(url, init);
  });

  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

function installCommaCenterFetchStub({
  workspaceChatReady,
}: { workspaceChatReady?: Promise<void> } = {}) {
  return installCommaFetchStub(async (url: string, init?: RequestInit) => {
    const path = requestPath(url);
    const method = init?.method ?? "GET";

    if (method === "POST" && path === "/v1/comma/me/bootstrap") {
      return jsonResponse({
        status: "ready",
        workspace: { group_id: "grp-web", id: "ws-web", name: "Web Workspace" },
      });
    }

    if (method === "POST" && path === "/v1/comma/groups/grp-web/assistant-chat") {
      await workspaceChatReady;
      return jsonResponse({
        group_id: "grp-web",
        id: "conv-created",
        kind: "user_chat",
        title: "聊天",
        status: "active",
        updated_at: 2_000,
      });
    }

    if (
      method === "POST" &&
      path === "/v1/comma/groups/grp-web/conversations/conv-created/messages"
    ) {
      return jsonResponse({
        group_id: "grp-web",
        id: "conv-created",
        kind: "user_chat",
        title: "聊天",
        status: "active",
        updated_at: 3_000,
      });
    }

    if (
      method === "GET" &&
      path === "/v1/comma/groups/grp-web/conversations/conv-created"
    ) {
      return jsonResponse({
        group_id: "grp-web",
        id: "conv-created",
        kind: "user_chat",
        title: "聊天",
        status: "active",
        updated_at: 3_000,
      });
    }

    if (
      method === "GET" &&
      path === "/v1/comma/groups/grp-web/conversations/conv-created/messages"
    ) {
      return jsonResponse({ data: [] });
    }

    return jsonResponse({ error: `unhandled ${method} ${path}` }, 404);
  });
}

function requestPath(raw: string) {
  if (raw.startsWith("http://") || raw.startsWith("https://")) {
    return new URL(raw).pathname;
  }
  return raw;
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function installGoogleIdentityServicesStub() {
  let credentialCallback: ((response: { credential?: string }) => void) | undefined;
  const initialize = vi.fn(
    (config: { callback: (response: { credential?: string }) => void }) => {
      credentialCallback = config.callback;
    }
  );
  const renderButton = vi.fn();

  Object.defineProperty(window, "google", {
    configurable: true,
    value: {
      accounts: {
        id: {
          initialize,
          renderButton,
        },
      },
    },
  });

  return {
    initialize,
    renderButton,
    submitCredential(credential: string) {
      if (!credentialCallback) {
        throw new Error("Google Identity Services was not initialized.");
      }
      credentialCallback({ credential });
    },
  };
}

function createTestStateBridge<Snapshot>(
  getSnapshot: () => Promise<Snapshot> | Snapshot
): NativeStateBridge<Snapshot> {
  const get = vi.fn(async () => getSnapshot());

  return Object.assign(get, {
    get,
    subscribe: vi.fn((listener: (snapshot: Snapshot) => void) => {
      void get().then(listener);
      return () => undefined;
    }),
  });
}
