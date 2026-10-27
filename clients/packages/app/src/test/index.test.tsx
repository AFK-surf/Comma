import type {
  CoreClient,
  ProductInboxItem,
  ProductInboxListResult,
  SessionAttempt,
  SessionValue,
  TaskSearchValue,
} from "@comma/core-client";
import { CoreProvider, type TaskConversationValue } from "@comma/core-client";
import {
  idleConversationChannelState,
  normalizeServerMessages,
} from "@comma/core/chat";
import type { CommaConversation } from "@comma/core/api-schemas";
import userEvent from "@testing-library/user-event";
import { advance, flush } from "@comma/test-utils/fake-clock";
import {
  createScriptedCore,
  delegateScriptedCore,
} from "@comma/test-utils/scripted-core";
import {
  commaClientAppShortcutOverridesSchema,
  defaultCommaClientSettings,
  type NativeStateBridge,
  type SurfaceList,
} from "@comma/native-bridge";
import type {
  SessionAuthAttemptRef,
  SessionLifecycleSnapshot,
  SessionProblemCode,
  SessionProblemOperation,
  SignedInSessionSnapshot,
  SignedOutSessionSnapshot,
} from "@comma/session-contract";
import {
  CommaApp,
  CommaAuthGate,
  CommaSessionHostProvider,
  CommaSidebarPanel,
  CommaSidebarProvider,
  CommaWebClientSettingsProvider,
  commaClientSettingsStorageKey,
  createCoreSessionHostController,
  useCommaAuth,
  type SessionHostController,
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
import {
  chordKeybinding,
  sequenceKeybinding,
} from "@comma/ui/components/settings-shortcut";
import { toast } from "@comma/ui/components/toast";
import { motionDuration } from "@comma/ui/tokens";
import type { ReactElement } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { COMMA_SURFACE_PAUSED_ATTRIBUTE } from "../components/commaSurfacePause";
import { TaskPanelApp } from "../task-panel";
import { createProductInboxProjectionHarness } from "./productInboxProjectionHarness";
import { stubProperty } from "@comma/test-utils/stub-property";

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

const sessionHostControllers: SessionHostController[] = [];
/** The client core the app rendered in this test talks to (scripted). */
let app: AppCore;
let user: ReturnType<typeof userEvent.setup>;

describe("CommaApp", () => {
  beforeEach(() => {
    user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    app = createAppCore();
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
    await settle();

    expect(
      screen.getByRole("heading", { name: "Sign in to Comma" })
    ).toBeInTheDocument();
    expect(screen.queryByRole("complementary", { name: "App sidebar" })).toBeNull();
  });

  it("signs in with an email verification code", async () => {
    app.emailLogin({ challengeId: "comma_challenge_1", code: "123456", who: person });

    renderCommaApp();
    await settle();

    await user.type(
      screen.getByRole("textbox", { name: /email/i }),
      "person@example.com"
    );
    await user.click(screen.getByRole("button", { name: "Send code" }));
    await settle();

    // The code arrives with the request's answer and fills in once it renders.
    await waitFor(() =>
      expect(screen.getByRole("textbox", { name: /verification code/i })).toHaveValue(
        "123456"
      )
    );
    expect(screen.getByRole("status")).toHaveTextContent("Verification code sent.");

    await user.click(screen.getByRole("button", { name: "Verify code" }));
    await settle();

    expect(
      screen.getByRole("complementary", { name: "App sidebar" })
    ).toBeInTheDocument();
    expect(localStorage.getItem(legacySessionTokenStorageKey)).toBeNull();
    expect(localStorage.getItem(legacyUserEmailStorageKey)).toBeNull();
    expect(localStorage.getItem(legacyUserAdminStorageKey)).toBeNull();
    const signedOut = {
      authorityInstanceId: "core-web",
      expectedSessionId: null,
      generation: 0,
    };
    expect(app.sentTo("session.email.request")).toEqual([
      { email: "person@example.com", expected: signedOut },
    ]);
    expect(app.sentTo("session.email.verify")).toEqual([
      {
        attempt: { attemptId: "attempt-1", expected: signedOut },
        challengeId: "comma_challenge_1",
        code: "123456",
      },
    ]);
  });

  it("replaces a prepared Google attempt when the user chooses email", async () => {
    const google = installGoogleIdentityServicesStub();
    app.answer("session.google.attempt", () =>
      app.googleAttempt("gat_email_fallback", "nonce_email_fallback")
    );
    app.emailLogin({
      challengeId: "comma_challenge_email_fallback",
      code: "123456",
      who: person,
    });

    renderCommaApp();
    await settle();

    expect(google.renderButton).toHaveBeenCalledOnce();
    await user.type(
      screen.getByRole("textbox", { name: /email/i }),
      "person@example.com"
    );
    await user.click(screen.getByRole("button", { name: "Send code" }));
    await settle();

    // The code arrives with the request's answer and fills in once it renders.
    await waitFor(() =>
      expect(screen.getByRole("textbox", { name: /verification code/i })).toHaveValue(
        "123456"
      )
    );
    await user.click(screen.getByRole("button", { name: "Verify code" }));
    await settle();
    expect(screen.getByRole("complementary", { name: "App sidebar" })).toBeVisible();
    expect(app.sentTo("session.google.complete")).toEqual([]);
  });

  it("signs in through the official Google Identity Services callback", async () => {
    const google = installGoogleIdentityServicesStub();
    app.answer("session.google.attempt", () => app.googleAttempt("gat_1", "nonce_1"));
    app.answer("session.google.complete", () => ({
      ok: true,
      value: {
        status: "signed_in",
        snapshot: app.signIn({ id: "usr_google", email: "person@gmail.com" }),
      },
    }));

    renderCommaApp();
    await settle();

    expect(google.renderButton).toHaveBeenCalledOnce();
    google.submitCredential("google_id_token");
    await settle();

    expect(
      screen.getByRole("complementary", { name: "App sidebar" })
    ).toBeInTheDocument();
    expect(app.sentTo("session.google.complete")).toEqual([
      {
        attempt: {
          attemptId: "attempt-1",
          expected: {
            authorityInstanceId: "core-web",
            expectedSessionId: null,
            generation: 0,
          },
        },
        credential: "google_id_token",
        nonce: "nonce_1",
        providerAttemptId: "gat_1",
      },
    ]);
    expect(localStorage.getItem(legacySessionTokenStorageKey)).toBeNull();
  });

  it("retries Google Identity Services after the script fails to load", async () => {
    app.answer("session.google.attempt", () =>
      app.googleAttempt("gat_retry", "nonce_retry")
    );

    renderCommaApp();
    await settle();

    const firstScript = document.getElementById("comma-google-identity-services");
    expect(firstScript).toBeInstanceOf(HTMLScriptElement);
    fireEvent.error(firstScript!);
    await settle();

    await user.click(screen.getByRole("button", { name: "Retry Google sign-in" }));
    await settle();

    const secondScript = document.getElementById("comma-google-identity-services");
    expect(secondScript).toBeInstanceOf(HTMLScriptElement);
    expect(secondScript).not.toBe(firstScript);
    const google = installGoogleIdentityServicesStub();
    fireEvent.load(secondScript!);
    await settle();

    expect(google.renderButton).toHaveBeenCalledOnce();
  });

  it("replaces a failed Google credential attempt when the user retries", async () => {
    const google = installGoogleIdentityServicesStub();
    const secondAttempt = deferred<void>();
    let attemptCount = 0;
    app.answer("session.google.attempt", async () => {
      attemptCount += 1;
      const count = attemptCount;
      if (count === 2) await secondAttempt.promise;
      return app.googleAttempt(`gat_retry_${count}`, `nonce_retry_${count}`);
    });
    // The server refused the credential (401): the core answers a sign-in that cannot go on.
    app.answer("session.google.complete", () => {
      app.signOut("no_session");
      return refused("sign_in_with_google", "unknown");
    });

    renderCommaApp();
    await settle();

    expect(google.renderButton).toHaveBeenCalledOnce();
    google.submitCredential("rejected_google_id_token");
    await settle();

    await user.click(screen.getByRole("button", { name: "Retry Google sign-in" }));
    await settle();

    expect(
      screen.getByRole("status", { name: "Loading Google sign-in…" })
    ).toBeVisible();
    expect(screen.queryByRole("alert")).toBeNull();
    expect(attemptCount).toBe(2);

    secondAttempt.resolve();
    await settle();

    expect(google.renderButton).toHaveBeenCalledTimes(2);
    expect(app.sentTo("session.google.attempt")).toHaveLength(2);
  });

  it("requires the purpose-bound email code when Google linking needs proof", async () => {
    const google = installGoogleIdentityServicesStub();
    app.answer("session.google.attempt", () => app.googleAttempt("gat_2", "nonce_2"));
    // The Google account must be linked first: the same attempt now waits on the emailed code.
    app.answer(
      "session.google.complete",
      ({ attempt }: { attempt: SessionAuthAttemptRef }) => ({
        ok: true,
        value: {
          status: "otp_required",
          attempt: app.begin(
            "google",
            {
              challengeId: "challenge_google_link",
              purpose: "google_link",
              email: "person@example.com",
            },
            attempt
          ),
          challengeId: "challenge_google_link",
          code: "654321",
          email: "person@example.com",
        },
      })
    );
    app.answer("session.google.linkVerify", () => ({
      ok: true,
      value: app.signIn({ id: "usr_linked", email: "person@example.com" }),
    }));

    renderCommaApp();
    await settle();

    expect(google.renderButton).toHaveBeenCalledOnce();
    google.submitCredential("google_id_token_for_link");
    await settle();

    expect(
      screen.getByRole("heading", { name: "Check your email" })
    ).toBeInTheDocument();
    expect(screen.getByText("person@example.com")).toBeInTheDocument();
    expect(screen.getByRole("textbox", { name: /verification code/i })).toHaveValue(
      "654321"
    );

    await user.click(screen.getByRole("button", { name: "Verify code" }));
    await settle();

    expect(
      screen.getByRole("complementary", { name: "App sidebar" })
    ).toBeInTheDocument();
    expect(app.sentTo("session.google.linkVerify")).toEqual([
      {
        attempt: {
          attemptId: "attempt-1",
          expected: {
            authorityInstanceId: "core-web",
            expectedSessionId: null,
            generation: 0,
          },
        },
        challengeId: "challenge_google_link",
        code: "654321",
      },
    ]);
  });

  it("returns to login when the user signs out from Settings → Profile", async () => {
    seedCommaSession();
    renderCommaApp();
    await settle();

    await user.click(screen.getByRole("button", { name: "Settings" }));
    await settle();
    await user.click(screen.getByRole("button", { name: "Profile" }));
    await settle();
    expect(screen.getByText("Sign out of Comma on this device.")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Sign out" }));
    await settle();

    expect(
      screen.getByRole("heading", { name: "Sign in to Comma" })
    ).toBeInTheDocument();
    expect(app.sentTo("session.signOut")).toEqual([
      {
        expected: {
          authorityInstanceId: "core-web",
          expectedAudience: "http://127.0.0.1",
          expectedSessionId: testSessionId,
          generation: 1,
        },
      },
    ]);
  });

  it("unmounts the authenticated tree while browser logout is pending", async () => {
    seedCommaSession();
    const logout = deferred<void>();
    app.answer("session.signOut", async () => {
      app.signingOut();
      await logout.promise;
      return { ok: true, value: app.signOut("user_signed_out") };
    });

    renderCommaApp();
    await settle();

    await user.click(screen.getByRole("button", { name: "Settings" }));
    await settle();
    await user.click(screen.getByRole("button", { name: "Profile" }));
    await settle();
    await user.click(screen.getByRole("button", { name: "Sign out" }));
    await settle();

    expect(screen.getByText("Signing out…")).toBeInTheDocument();
    expect(
      screen.queryByRole("complementary", { name: "App sidebar" })
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("heading", { name: "Sign in to Comma" })
    ).not.toBeInTheDocument();

    logout.resolve();
    await settle();

    expect(
      screen.getByRole("heading", { name: "Sign in to Comma" })
    ).toBeInTheDocument();
  });

  it("fails closed until an uncertain HttpOnly-cookie logout is reconciled", async () => {
    seedCommaSession();
    // The server could not say whether it signed out (503): the core fails closed, holding the Cookie's session.
    app.answer("session.signOut", () => {
      app.signingOut();
      app.failClosed("session_probe_unavailable", "sign_out");
      return refused("sign_out", "unknown");
    });
    // The person retries: the core finds the Cookie's session again.
    app.answer("session.recover", () => {
      app.signIn(person);
      return null;
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
      app.wrap(
        <CommaAuthGate>
          <AuthProbe />
        </CommaAuthGate>
      )
    );
    await settle();

    expect(screen.getByLabelText("auth-email")).toHaveTextContent("person@example.com");
    const originalSignal = currentSignal;
    await user.click(screen.getByRole("button", { name: "sign out" }));
    await settle();

    expect(originalSignal?.aborted).toBe(true);
    expect(
      screen.getByRole("heading", {
        name: "Comma can’t continue",
      })
    ).toBeInTheDocument();
    expect(screen.queryByLabelText("auth-email")).toBeNull();
    expect(app.sentTo("session.recover")).toEqual([]);

    await user.click(screen.getByRole("button", { name: "Try again" }));
    await settle();

    expect(currentSignal).not.toBe(originalSignal);
    expect(currentSignal?.aborted).toBe(false);
    expect(screen.getByLabelText("auth-email")).toHaveTextContent("person@example.com");
    expect(
      screen.queryByRole("heading", { name: "Sign in to Comma" })
    ).not.toBeInTheDocument();
    expect(app.sentTo("session.recover")).toEqual([{}]);
  });

  it("scrubs legacy renderer auth metadata when the web app mounts", async () => {
    localStorage.setItem(legacySessionTokenStorageKey, "legacy_renderer_secret");
    localStorage.setItem(legacyUserEmailStorageKey, "legacy@example.com");
    localStorage.setItem(legacyUserAdminStorageKey, "true");

    renderCommaApp();
    await settle();

    expect(localStorage.getItem(legacySessionTokenStorageKey)).toBeNull();
    expect(localStorage.getItem(legacyUserEmailStorageKey)).toBeNull();
    expect(localStorage.getItem(legacyUserAdminStorageKey)).toBeNull();
  });

  it("renders the Figma shell layout with the Home route", async () => {
    seedCommaSession();
    renderCommaApp();
    await settle();

    expect(
      screen.getByRole("complementary", { name: "App sidebar" })
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
      "Type / for commands, @ for context"
    );
    expect(screen.queryByRole("button", { name: "Send" })).toBeNull();
    expect(screen.getByRole("button", { name: "Voice input" })).toBeEnabled();
  });

  it("opens and sends to the workspace named by a Quick Chat Home link", async () => {
    seedCommaSession();
    scriptChat(app);
    const requested: unknown[] = [];
    app.topic("workspaceChat", (topic) => {
      requested.push(topic.workspace);
      const workspaceId = String(topic.workspace ?? "default");
      return {
        status: "ready",
        kept: false,
        chat: {
          workspaceId,
          groupId: `group-${workspaceId}`,
          conversationId: `chat-${workspaceId}`,
        },
      };
    });
    window.location.hash = "#/?workspace=second";
    renderCommaApp();
    await settle();
    expect(requested).toEqual(["second"]);
    await user.type(screen.getByRole("textbox", { name: "AI prompt" }), "Follow up");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await settle();
    expect(app.sentTo("chatView.send")).toEqual([
      expect.objectContaining({
        workspace: "second",
        group: "group-second",
        conversation: "chat-second",
        text: "Follow up",
      }),
    ]);
    fireEvent.keyDown(window, { code: "KeyG" });
    fireEvent.keyDown(window, { code: "KeyT" });
    await settle();
    expect(window.location.hash).toBe("#/tasks");
    expect(requested).toEqual(["second"]);
  });

  it("starts the Workspace Chat from the Comma Center prompt", async () => {
    seedCommaSession();
    installNativeBridgeMock({ platform: "web" });
    const workspaceChat = deferred<void>();
    scriptChat(app);
    app.answer("chat.resolveWorkspaceChat", async () => {
      await workspaceChat.promise;
      return {
        conversationId: "conv-created",
        groupId: "grp-web",
        status: "ready",
        workspaceId: "ws-web",
      };
    });
    renderCommaApp();
    await settle();

    await user.type(
      screen.getByRole("textbox", { name: "AI prompt" }),
      "你好，第二条聊天测试"
    );
    await user.click(screen.getByRole("button", { name: "Send" }));
    workspaceChat.resolve();
    await settle();

    expect(app.sentTo("chat.resolveWorkspaceChat")).not.toEqual([]);
    expect(app.sentTo("chatView.send")).toEqual([
      expect.objectContaining({
        conversation: "conv-created",
        group: "grp-web",
        text: "你好，第二条聊天测试",
        workspace: "ws-web",
      }),
    ]);
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
    await settle();

    expect(screen.getByRole("main")).toHaveAttribute("data-platform", "electron");
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
    await settle();
    expect(screen.getByRole("main")).toHaveAttribute("data-platform", "electron");

    act(() => {
      toast.info("Copied message", { description: "Message copied to clipboard" });
    });
    await flush();

    expect(screen.getByText("Copied message")).toBeInTheDocument();
    expect(document.querySelectorAll("[data-sonner-toaster]")).toHaveLength(1);
    act(() => {
      toast.dismissAll();
    });
  });

  it("keeps the command palette closed for a guest Session", async () => {
    seedCommaSession(guestUser);
    renderCommaApp();
    await settle();

    expect(screen.getByTestId("comma-guest-banner")).toBeVisible();
    dispatchCommandPaletteShortcut();
    await advance(200);

    // A guest has no Tasks to search; the palette never opens.
    expect(screen.queryByRole("dialog", { name: "Search Comma" })).toBeNull();
  });

  it("ignores the Chat Sidebar shortcut in a guest Session", async () => {
    seedCommaSession(guestUser);
    renderCommaApp();
    await settle();

    expect(screen.getByTestId("comma-guest-banner")).toBeVisible();
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
    await settle();

    await user.click(screen.getByTestId("comma-window-bar-search"));
    await settle();

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
    scriptTaskPreviews(previewRequests, (conversationId) => {
      if (conversationId === "cnv-history-21") {
        return {
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
        };
      }
      return new Promise(() => {});
    });
    renderCommaApp(productInbox.controller);
    await settle();

    expect(screen.getByRole("heading", { level: 1, name: "General" })).toBeVisible();
    dispatchCommandPaletteShortcut();
    await settle();
    expect(screen.getByRole("dialog", { name: "Search Comma" })).toBeVisible();

    const newestTask = screen.getByRole("option", {
      name: /Newest history task/,
    });
    const taskGroup = screen.getByRole("group", { name: "Tasks" });
    expect(within(taskGroup).getAllByRole("option")).toHaveLength(20);
    expect(
      screen.queryByRole("option", { name: /^History task 1(?:\s|$)/ })
    ).toBeNull();
    expect(screen.queryByRole("option", { name: /Not a Task/ })).toBeNull();
    expect(newestTask).toHaveAttribute("aria-selected", "true");
    expect(screen.getByText("The Task preview is ready.")).toBeVisible();
    expect(previewRequests).toEqual(["cnv-history-21"]);
    expect(productInbox.retain).toHaveBeenCalled();

    await user.click(newestTask);
    await settle();

    expect(window.location.hash).toBe("#/tasks/wsp-history/grp-history/cnv-history-21");
  });

  it("lists app actions after the recent Tasks with their shortcuts", async () => {
    seedCommaSession();
    renderCommaApp();
    await settle();

    dispatchCommandPaletteShortcut();
    await settle();

    const actions = screen.getByRole("group", { name: "Actions" });
    expect(
      within(actions)
        .getAllByRole("option")
        .map(
          (option) =>
            option.querySelector('[data-slot="command-palette-item-title"]')
              ?.textContent
        )
    ).toEqual([
      "Go to Comma assistant",
      "Go to Inbox",
      "Go to Tasks",
      "Go to Drive",
      "Go to Plugin",
      "Go to Settings",
      "Toggle left sidebar",
      "Toggle right sidebar",
    ]);
    const inbox = within(actions).getByRole("option", { name: /Go to Inbox/ });
    expect(
      Array.from(inbox.querySelectorAll("kbd"), (keycap) => keycap.textContent)
    ).toEqual(["G", "I"]);
  });

  it("puts the actions a query names first and runs the chosen one", async () => {
    seedCommaSession();
    window.location.hash = "#/settings";
    scriptTaskSearch({});
    renderCommaApp();
    await settle();

    dispatchCommandPaletteShortcut();
    await settle();
    await user.type(screen.getByRole("combobox", { name: "Search Comma" }), "inbox");
    await settle();

    const inbox = screen.getByRole("option", { name: /Go to Inbox/ });
    expect(screen.getAllByRole("option")).toEqual([inbox]);
    expect(inbox).toHaveAttribute("aria-selected", "true");
    expect(screen.getByText("Inbox", { selector: "mark" })).toBeVisible();

    await user.keyboard("{Enter}");
    await settle();

    expect(screen.queryByRole("dialog", { name: "Search Comma" })).toBeNull();
    expect(window.location.hash).toBe("#/inbox");
  });

  it("toggles the right sidebar from the palette", async () => {
    seedCommaSession();
    scriptTaskSearch({});
    renderCommaApp();
    await settle();
    const chatSidebar = screen.getByTestId("chat-sidebar");
    expect(chatSidebar).toHaveAttribute("data-open", "false");

    dispatchCommandPaletteShortcut();
    await settle();
    await user.type(
      screen.getByRole("combobox", { name: "Search Comma" }),
      "right sidebar"
    );
    await settle();
    await user.click(screen.getByRole("option", { name: /Toggle right sidebar/ }));
    await settle();

    expect(screen.queryByRole("dialog", { name: "Search Comma" })).toBeNull();
    expect(chatSidebar).toHaveAttribute("data-open", "true");
  });

  it("loads a Task preview after confirmed pointer intent, and shows only the Task now selected", async () => {
    seedCommaSession();
    window.location.hash = "#/settings";
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
    let answerFirst!: (conversation: CommaConversation) => void;
    scriptTaskPreviews(previewRequests, (conversationId) => {
      if (conversationId === "cnv-hover-first") {
        return new Promise<CommaConversation>((resolve) => {
          answerFirst = resolve;
        });
      }
      if (conversationId === "cnv-hover-second") {
        return {
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
        };
      }
      return new Promise(() => {});
    });
    renderCommaApp(productInbox.controller);
    await settle();

    expect(screen.getByRole("heading", { level: 1, name: "General" })).toBeVisible();
    dispatchCommandPaletteShortcut();
    await settle();
    expect(screen.getByRole("dialog", { name: "Search Comma" })).toBeVisible();
    expect(previewRequests).toEqual(["cnv-hover-first"]);

    const secondPreview = screen.getByRole("option", { name: /Second preview/ });
    fireEvent.pointerMove(secondPreview, { pointerType: "mouse" });

    expect(previewRequests).toEqual(["cnv-hover-first"]);
    expect(secondPreview).toHaveAttribute("aria-selected", "true");
    // The palette takes the pointer's rest on a row as intent once it has stayed there.
    await advance(motionDuration.pointerIntent);
    expect(previewRequests).toEqual(["cnv-hover-first", "cnv-hover-second"]);
    expect(screen.getByText("Second Task preview")).toBeVisible();

    // The first Task's answer comes late: the preview stays the selected Task's.
    act(() =>
      answerFirst({
        group_id: "grp-hover",
        id: "cnv-hover-first",
        kind: "agent_task",
        messages: [
          {
            actor_type: "agent",
            agent_id: "agt-hover",
            content: [{ text: "First Task preview", type: "text" }],
            kind: "message",
            message_id: "msg-hover-first",
          },
        ],
        status: "active",
        title: "First preview",
      })
    );
    await settle();
    expect(screen.getByText("Second Task preview")).toBeVisible();
    expect(screen.queryByText("First Task preview")).toBeNull();
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
    scriptTaskPreviews(previewRequests, (conversationId) => {
      if (conversationId === "cnv-hover-race-first") {
        return {
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
        };
      }
      if (conversationId === "cnv-hover-race-second") {
        return {
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
        };
      }
      return new Promise(() => {});
    });
    renderCommaApp(productInbox.controller);
    await settle();

    expect(screen.getByRole("heading", { level: 1, name: "General" })).toBeVisible();
    dispatchCommandPaletteShortcut();
    await settle();
    expect(screen.getByText("Race first preview")).toBeVisible();

    const secondTask = screen.getByRole("option", { name: /Race second/ });
    fireEvent.pointerMove(secondTask, { pointerType: "mouse" });
    expect(previewRequests).toEqual(["cnv-hover-race-first"]);
    expect(secondTask).toHaveAttribute("aria-selected", "true");
    await advance(motionDuration.pointerIntent);
    expect(previewRequests).toEqual(["cnv-hover-race-first", "cnv-hover-race-second"]);
    expect(screen.getByText("Race second preview")).toBeVisible();
    expect(secondTask).toHaveAttribute("aria-selected", "true");

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
    await settle();

    expect(screen.getByText("Race second preview")).toBeVisible();
    expect(secondTask).toHaveAttribute("aria-selected", "true");
    expect(screen.queryByText("Race first preview")).toBeNull();
    expect(previewRequests).toEqual(["cnv-hover-race-first", "cnv-hover-race-second"]);
  });

  it("keeps one-character Task queries local and searches two-character terms", async () => {
    seedCommaSession();
    const searched = scriptTaskSearch({
      智能: {
        status: "ready",
        scope: { groupId: "grp-search", workspaceId: "wsp-search" },
        results: [
          {
            conversation_id: "cnv-ai",
            highlights: [{ start: 0, end: 2 }],
            matched_field: "title",
            snippet: "智能路线图",
            title: "智能路线图",
          },
        ],
      },
    });
    renderCommaApp();
    await settle();

    await user.click(screen.getByTestId("comma-window-bar-search"));
    await settle();
    const input = screen.getByRole("combobox", { name: "Search Comma" });
    await user.type(input, "智");
    await settle();
    expect(
      screen.getByText("Type at least 2 characters to search tasks")
    ).toBeVisible();
    expect(searched()).toEqual([]);

    await user.clear(input);
    await user.type(input, "é");
    await settle();
    expect(
      screen.getByText("Type at least 2 characters to search tasks")
    ).toBeVisible();
    expect(searched()).toEqual([]);

    await user.clear(input);
    await user.type(input, "智");
    await settle();
    await user.type(input, "能");
    await settle();
    expect(screen.getByRole("option", { name: /智能路线图/ })).toBeVisible();
    expect(screen.getByText("智能", { selector: "mark" })).toBeVisible();
    expect(searched()).toEqual(["智能"]);
  });

  it("searches indexed Task content, highlights the match, and opens the Task", async () => {
    seedCommaSession();
    const snippet = `…${"前".repeat(48)}archive rollout`;
    const highlightStart = snippet.indexOf("archive");
    scriptTaskSearch({
      archive: {
        status: "ready",
        scope: { groupId: "grp-search", workspaceId: "wsp-search" },
        results: [
          {
            conversation_id: "cnv-search",
            highlights: [{ start: highlightStart, end: highlightStart + 7 }],
            matched_field: "content",
            snippet,
            title: "Release checklist",
            updated_at: 2,
          },
        ],
      },
    });
    renderCommaApp();
    await settle();

    await user.click(screen.getByTestId("comma-window-bar-search"));
    await settle();
    await user.type(screen.getByRole("combobox", { name: "Search Comma" }), "archive");
    await settle();

    const releaseChecklist = screen.getByRole("option", {
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
    await user.click(releaseChecklist);
    await settle();

    expect(window.location.hash).toBe("#/tasks/wsp-search/grp-search/cnv-search");
  });

  it("shows the first content match as a subtitle when the title also matches", async () => {
    seedCommaSession();
    const title = "调研 Cursor 并制作网页";
    const contentSnippet = "已完成中文简报网页，并附带 HTML";
    scriptTaskSearch({
      网页: {
        status: "ready",
        scope: { groupId: "grp-search", workspaceId: "wsp-search" },
        results: [
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
      },
    });
    renderCommaApp();
    await settle();

    await user.click(screen.getByTestId("comma-window-bar-search"));
    await settle();
    await user.type(screen.getByRole("combobox", { name: "Search Comma" }), "网页");
    await settle();

    const result = screen.getByRole("option", { name: /调研 Cursor/ });
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

  it("shows server-rejected Task queries as actionable validation errors", async () => {
    seedCommaSession();
    // The server refused the query (400): the core calls it invalid.
    const searched = scriptTaskSearch({
      ["ß".repeat(128)]: { status: "invalid", scope: null, results: [] },
    });
    renderCommaApp();
    await settle();

    await user.click(screen.getByTestId("comma-window-bar-search"));
    await settle();
    fireEvent.change(screen.getByRole("combobox", { name: "Search Comma" }), {
      target: { value: "ß".repeat(128) },
    });
    await settle();

    expect(
      screen.getByText("This search is invalid. Try a shorter query.")
    ).toBeVisible();
    expect(
      screen.queryByText("Unable to search tasks. Try again in a moment.")
    ).not.toBeInTheDocument();
    expect(screen.queryAllByRole("option")).toHaveLength(0);
    expect(searched()).toEqual(["ß".repeat(128)]);
  });

  it("removes committed Task results as soon as the query request key changes", async () => {
    seedCommaSession();
    const rollout = deferred<TaskSearchValue>();
    scriptTaskSearch({
      archive: {
        status: "ready",
        scope: { groupId: "grp-search", workspaceId: "wsp-search" },
        results: [
          {
            conversation_id: "cnv-search",
            highlights: [{ start: 12, end: 19 }],
            matched_field: "content",
            snippet: "Prepare the archive rollout",
            title: "Release checklist",
          },
        ],
      },
      rollout: rollout.promise,
    });
    renderCommaApp();
    await settle();

    await user.click(screen.getByTestId("comma-window-bar-search"));
    await settle();
    const input = screen.getByRole("combobox", { name: "Search Comma" });
    await user.type(input, "archive");
    await settle();
    expect(screen.getByRole("option", { name: /Release checklist/ })).toBeVisible();

    await user.clear(input);
    await user.type(input, "rollout");
    await settle();
    expect(
      screen.queryByRole("option", { name: /Release checklist/ })
    ).not.toBeInTheDocument();
    expect(screen.getByRole("progressbar", { name: "Searching tasks…" })).toBeVisible();

    rollout.resolve({
      status: "ready",
      scope: { groupId: "grp-search", workspaceId: "wsp-search" },
      results: [],
    });
    await settle();
    expect(screen.getByText("No results found")).toBeVisible();
  });

  it("opens the workspace plugin catalog from the shared product sidebar", async () => {
    seedCommaSession();
    app.topic("plugins", () => ({
      status: "ready",
      workspace: "wsp_plugins",
      plugins: [
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
          activity: "idle",
        },
      ],
      installed: [],
      categories: [{ id: "integrations", name: null, plugins: ["linear"] }],
    }));
    renderCommaApp();
    await settle();

    await user.click(screen.getByRole("link", { name: "Plugins" }));
    await settle();

    expect(screen.getByRole("heading", { name: "Plugins" })).toBeVisible();
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
    await settle();

    const homeBeforeSettings = screen.getByTestId("home-responsive-layout");
    const windowBar = screen.getByTestId("comma-window-bar");
    const sidebar = screen.getByRole("complementary", { name: "App sidebar" });
    const content = screen.getByRole("region", { name: "Content" });
    const settingsButton = screen.getByRole("button", { name: "Settings" });
    expect(sidebar).toContainElement(settingsButton);
    expect(settingsButton).not.toHaveAttribute("aria-current");
    expect(screen.queryByRole("dialog", { name: "Settings sections" })).toBeNull();

    await user.click(settingsButton);
    await settle();

    expect(screen.getByRole("heading", { level: 1, name: "General" })).toBeVisible();
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

    await user.click(screen.getByRole("button", { name: "Close settings" }));
    await settle();

    expect(screen.queryByRole("dialog", { name: "Settings sections" })).toBeNull();
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
    await settle();

    const home = screen.getByTestId("home-responsive-layout");
    expect(home).toBeVisible();

    fireEvent.keyDown(window, { code: "KeyG" });
    fireEvent.keyDown(window, { code: "KeyT" });
    await settle();
    expect(window.location.hash).toBe("#/tasks");
    expect(home).toBe(screen.getByTestId("home-responsive-layout"));
    // The browser skips the retained Home's rendering (jsdom does not render,
    // so it cannot say Home is unseen).
    const pausedHome = home.closest<HTMLElement>(
      `[${COMMA_SURFACE_PAUSED_ATTRIBUTE}="true"]`
    );
    expect(pausedHome).not.toBeNull();
    expect(pausedHome!.style.contentVisibility).toBe("hidden");

    await user.click(screen.getByRole("link", { name: "Home" }));
    await settle();
    expect(window.location.hash).toBe("#/");
    expect(screen.getByTestId("home-responsive-layout")).toBe(home);
    expect(home).toBeVisible();
    expect(home.closest("[inert]")).toBeNull();
  });

  it("runs the session's owners only in the window that shows the product", async () => {
    seedCommaSession();
    window.location.hash = "#/apps/wsp_app_window/app_window/window";
    const tasks = createProductInboxProjectionHarness({
      initial: { items: [], source: "live-sync" },
    });
    // The app itself stays loading: this window is about what runs beside it.
    app.answer("miniApps.session.open", () => new Promise(() => undefined));

    renderCommaApp(tasks.controller);
    await settle();

    // A window that shows one app follows no Tasks (the Notch's list and its
    // Workers' feeds) and reads no plugin notices.
    expect(screen.getByTestId("app-window-route")).toBeInTheDocument();
    expect(tasks.retain).not.toHaveBeenCalled();
    expect(app.subscribed()).not.toContain("pluginNotices");

    window.location.hash = "#/";
    await settle();

    expect(screen.getByTestId("home-responsive-layout")).toBeInTheDocument();
    expect(tasks.retain).toHaveBeenCalled();
    expect(app.subscribed()).toContain("pluginNotices");
  });

  it("opens Settings directly without mounting or bootstrapping Home", async () => {
    seedCommaSession();
    window.location.hash = "#/settings";

    renderCommaApp();
    await settle();

    expect(screen.getByRole("heading", { level: 1, name: "General" })).toBeVisible();
    expect(screen.queryByTestId("home-responsive-layout")).not.toBeInTheDocument();
    // The shell is mounted for every product location; only Home is skipped.
    expect(screen.getByTestId("comma-window-bar")).toBeInTheDocument();
    expect(screen.getByTestId("comma-sidebar-slot")).toBeInTheDocument();
    expect(
      screen.getByRole("dialog", { name: "Settings sections" })
    ).toBeInTheDocument();
    // Home's workspace is not provisioned, nor its chat looked up or made.
    expect(app.subscribed()).not.toContain("onboardingWorkspace");
    expect(app.sentTo("chat.resolveWorkspaceChat")).toEqual([]);
  });

  it("keeps the rail toggle shortcut active on Settings", async () => {
    seedAppShortcutOverrides({
      "toggle-left-sidebar": sequenceKeybinding("KeyG", "KeyB"),
    });
    seedCommaSession();
    window.location.hash = "#/settings";
    renderCommaApp();
    await settle();

    expect(screen.getByRole("heading", { level: 1, name: "General" })).toBeVisible();
    const sidebarSlot = screen.getByTestId("comma-sidebar-slot");
    const toggle = screen.getByRole("button", { name: "Collapse sidebar" });
    const content = screen.getByRole("region", { name: "Content" });
    expect(sidebarSlot).toHaveAttribute("data-collapsed", "false");
    expect(toggle).toHaveAttribute("aria-expanded", "true");

    fireEvent.keyDown(window, { code: "KeyG" });
    fireEvent.keyDown(window, { code: "KeyB" });
    await settle();

    expect(sidebarSlot).toHaveAttribute("data-collapsed", "true");
    expect(toggle).toHaveAttribute("aria-expanded", "false");
    expect(content).toHaveAttribute("data-sidebar-collapsed", "true");
    // Settings stays put; only the rail slot gave up its width.
    expect(
      screen.getByRole("dialog", { name: "Settings sections" })
    ).toBeInTheDocument();
    expect(window.location.hash).toBe("#/settings");

    // The modal owns pointer input while it is open, so the toggle behind it
    // only takes clicks again once Settings closes.
    await user.click(screen.getByRole("button", { name: "Close settings" }));
    await settle();
    expect(screen.queryByRole("dialog", { name: "Settings sections" })).toBeNull();

    await user.click(toggle);

    expect(sidebarSlot).toHaveAttribute("data-collapsed", "false");
    expect(toggle).toHaveAttribute("aria-expanded", "true");
    expect(content).toHaveAttribute("data-sidebar-collapsed", "false");
  });

  it("dispatches a customized history chord from the Settings route", async () => {
    seedAppShortcutOverrides({
      "history-back": chordKeybinding("KeyH", { control: true }),
    });
    seedCommaSession();
    renderCommaApp();
    await settle();

    expect(screen.getByTestId("home-responsive-layout")).toBeInTheDocument();
    // The rail opens the modal in place, so reach the routed form of Settings
    // the way a deep link does.
    await act(async () => {
      window.location.hash = "#/settings";
    });
    await settle();
    expect(
      screen.getByRole("dialog", { name: "Settings sections" })
    ).toBeInTheDocument();
    expect(window.location.hash).toBe("#/settings");

    fireEvent.keyDown(window, { code: "KeyH", ctrlKey: true });
    // jsdom goes back in two queued tasks, the second queued while the first runs (a timer 1 ms on).
    await advance(1);

    expect(["", "#/"]).toContain(window.location.hash);
    expect(screen.queryByRole("dialog", { name: "Settings sections" })).toBeNull();
    expect(screen.getByTestId("home-responsive-layout")).toBeVisible();
  });

  it("mounts the development layout inspector at the app root", async () => {
    seedCommaSession();
    renderCommaApp();
    await settle();
    expect(screen.getByRole("complementary", { name: "App sidebar" })).toBeVisible();

    fireEvent.keyDown(window, {
      code: "KeyL",
      ctrlKey: true,
      shiftKey: true,
    });
    await settle();

    expect(screen.getByText(/Layout Inspector · hover to inspect/)).toBeInTheDocument();
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
    await settle();

    expect(
      screen.getByRole("heading", { name: "Runtime Workbench" })
    ).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Sign in to Comma" })).toBeNull();
    expect(screen.queryByRole("complementary", { name: "App sidebar" })).toBeNull();
    expect(screen.getByText("win_main")).toBeInTheDocument();
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
    await settle();

    const toggle = screen.getByRole("button", { name: "Collapse sidebar" });
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

    await user.click(toggle);

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

    await user.click(toggle);

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

  it("runs an app alone in its own window, without the product shell", async () => {
    seedCommaSession();
    app.answer("miniApps.session.open", () => ({
      session: "mas-1",
      app: {
        id: "a1",
        name: "Habit tracker",
        author: { name: "Ada" },
        status: "active",
        capabilities: [],
        egress: [],
        grants: [],
      },
      version: 2,
      digest: "d",
      guest: false,
      viewer: { id: "v", name: "Ada", avatarUrl: null, guest: false },
      capabilities: [],
      grants: [],
      storage: [],
    }));
    window.location.hash = "#/apps/ws-1/a1/window";
    renderCommaApp();
    await settle();

    expect(screen.getByTestId("app-window-route")).toBeInTheDocument();
    // The app's own bar is the window's title bar: no second bar above it.
    expect(
      within(screen.getByTestId("app-window-route"))
        .getByTestId("mini-app-chrome")
        .querySelector("header")
    ).toHaveClass("comma-window-titlebar-region");
    expect(await screen.findByText("Habit tracker")).toBeInTheDocument();
    expect(screen.queryByTestId("comma-window-bar")).toBeNull();
    expect(screen.queryByRole("complementary", { name: "App sidebar" })).toBeNull();
  });

  it("runs an app alone in a Telegram panel that a Telegram app button opened", async () => {
    seedCommaSession();
    const opened: unknown[] = [];
    app.answer("miniApps.session.open", (params) => {
      opened.push(params);
      return {
        session: "mas-1",
        app: {
          id: "a1",
          name: "Habit tracker",
          author: { name: "Ada" },
          status: "active",
          capabilities: [],
          egress: [],
          grants: [],
        },
        version: 2,
        digest: "d",
        guest: false,
        viewer: { id: "v", name: "Ada", avatarUrl: null, guest: false },
        capabilities: [],
        grants: [],
        storage: [],
      };
    });
    renderWithSessionHost(
      app.wrap(
        <TaskPanelApp target={{ groupId: "grp-1", workspaceId: "ws-1", appId: "a1" }} />
      )
    );
    await settle();

    expect(screen.getByTestId("mini-app-panel")).toBeInTheDocument();
    expect(await screen.findByText("Habit tracker")).toBeInTheDocument();
    expect(opened).toEqual([
      expect.objectContaining({
        app: "a1",
        via: { workspace: "ws-1" },
        platform: "web",
      }),
    ]);
  });

  it("renders the icon rail as primary navigation with Settings at its foot", async () => {
    seedCommaSession();
    renderCommaApp();
    await settle();

    const sidebar = screen.getByRole("complementary", { name: "App sidebar" });
    const nav = within(sidebar).getByRole("navigation", { name: "Primary" });
    const links = within(nav).getAllByRole("link");

    // The web reads the Workspace's Drive too, so its rail has Drive.
    expect(links).toHaveLength(6);
    ["Home", "Inbox", "Tasks", "Drive", "Apps", "Plugins"].forEach((name, index) => {
      expect(links[index]).toHaveAccessibleName(name);
      expect(links[index]).toHaveAttribute("data-slot", "left-rail-item");
      expect(links[index]).toHaveClass("comma-sidebar-link");
    });
    expect(links.map((link) => link.getAttribute("href"))).toEqual([
      "#/",
      "#/inbox",
      "#/tasks",
      "#/drive",
      "#/apps",
      "#/plugins",
    ]);
    expect(links.map((link) => link.getAttribute("aria-current"))).toEqual([
      "page",
      null,
      null,
      null,
      null,
      null,
    ]);
    expect(links.map((link) => link.getAttribute("data-selected"))).toEqual([
      "true",
      "false",
      "false",
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
    await settle();

    expect(window.location.hash).toBe("#/inbox");
    expect(within(nav).getByRole("link", { name: "Inbox" })).toHaveAttribute(
      "aria-current",
      "page"
    );
    expect(within(nav).getByRole("link", { name: "Home" })).not.toHaveAttribute(
      "aria-current"
    );

    await user.click(settingsButton);
    await settle();

    // The modal marks its rail item selected without taking the route: Inbox
    // is still the location behind it (the rail itself is hidden from the
    // accessibility tree for as long as the modal is open).
    expect(settingsButton).toHaveAttribute("data-selected", "true");
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
    await settle();

    const windowBar = screen.getByTestId("comma-window-bar");
    const sidebar = screen.getByRole("complementary", { name: "App sidebar" });
    const content = screen.getByRole("region", { name: "Content" });
    const chatToggle = within(windowBar).getByRole("button", { name: "New tab" });

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

    await user.click(searchHint);
    await settle();

    // The hint raises the command palette over the current route; Search is
    // not a location.
    expect(screen.getByRole("dialog", { name: "Search Comma" })).toBeVisible();
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
    await settle();

    const sidebar = screen.getByRole("complementary", { name: "App sidebar" });
    const inbox = within(sidebar).getByRole("link", { name: "Inbox" });
    expect(inbox.querySelector('[data-slot="left-rail-item-badge"]')).not.toBeNull();
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
    await settle();
    expect(inbox.querySelector('[data-slot="left-rail-item-badge"]')).toBeNull();
  });
});

type TestUser = { id: string; email: string; name?: string; kind?: "guest" };

/** The account a seeded session holds. */
const person: TestUser = {
  id: "usr_1",
  email: "person@example.com",
  name: "Person Example",
};
const guestUser: TestUser = {
  id: "usr_guest",
  email: "g-1@guest.comma.invalid",
  kind: "guest",
};

function seedCommaSession(who: TestUser = person) {
  app.signIn(who);
}

const authority = { authorityInstanceId: "core-web", kind: "web_cookie" } as const;
const testSessionId = "11111111-1111-4111-8111-111111111111";

type Answer = (params: never) => unknown;

/** A `session.*` call's typed failure, as the lifecycle answers it. */
function refused(operation: string, code: string, recovery = "none") {
  return {
    ok: false,
    error: { code, operation, recovery, retryable: recovery !== "none" },
  };
}
type AppCore = ReturnType<typeof createAppCore>;

/**
 * The client core as the app sees it. Its `session` topic is the web lifecycle's snapshot (signed out until a test
 * signs someone in), and the `session.*` calls answer as that lifecycle does against a server that accepts them;
 * a test answers other calls (`answer`) and topics (`topic`) itself. Everything else it says nothing of. The task
 * list is the projection harness's, which hands this script what it does not own.
 */
function createAppCore() {
  let revision = 0;
  let generation = 0;
  let attempts = 0;
  let attempt: SessionAttempt | null = null;
  const header = () => ({
    authority,
    cleanup: { revocation: "idle" as const },
    contractVersion: 1 as const,
    revision: ++revision,
  });
  const signedIn = (who: TestUser): SignedInSessionSnapshot => ({
    ...header(),
    generation: ++generation,
    phase: "signed_in",
    principal: {
      ...(who.name ? { displayName: who.name } : {}),
      email: who.email,
      ...(who.kind ? { kind: who.kind } : {}),
      userId: who.id,
    },
    session: {
      audience: "http://127.0.0.1",
      expiresAtEpochSeconds: 4_102_444_800,
      sessionId: testSessionId,
    },
  });
  const signedOut = (
    reason: SignedOutSessionSnapshot["reason"]
  ): SignedOutSessionSnapshot => ({
    ...header(),
    generation,
    phase: "signed_out",
    principal: null,
    reason,
    session: null,
  });
  let lifecycle: SessionLifecycleSnapshot = signedOut("no_session");
  const value = (): SessionValue => ({
    ...(lifecycle.phase === "signed_in"
      ? {
          phase: "signed_in" as const,
          userId: lifecycle.principal.userId,
          audience: lifecycle.session.audience,
          sessionId: lifecycle.session.sessionId,
        }
      : { phase: lifecycle.phase === "signed_out" ? "signed_out" : "unknown" }),
    lifecycle,
    attempt,
    guestImports: 0,
  });
  const answers = new Map<string, Answer>();
  const topics = new Map<string, (topic: Record<string, unknown>) => unknown>();
  const subscribed: string[] = [];
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "session" ? value() : topics.get(String(topic.topic))?.(topic),
    calls: (name, params) => answers.get(name)?.(params as never) ?? null,
    onSubscribe: (topic) => subscribed.push(String(topic.topic)),
  });
  const publish = <S extends SessionLifecycleSnapshot>(next: S): S => {
    lifecycle = next;
    if (next.phase !== "authenticating") attempt = null;
    core.changed("session");
    return next;
  };
  /** A sign-in starts (or `ref`'s goes on, waiting on `challenge`): every tab sees it under way. */
  const begin = (
    method: SessionAttempt["method"],
    challenge?: SessionAttempt["challenge"],
    ref: SessionAuthAttemptRef = {
      attemptId: `attempt-${++attempts}`,
      expected: {
        authorityInstanceId: authority.authorityInstanceId,
        expectedSessionId: null,
        generation,
      },
    }
  ): SessionAuthAttemptRef => {
    attempt = { ref, method, ...(challenge ? { challenge } : {}) };
    publish({
      ...header(),
      generation,
      phase: "authenticating",
      principal: null,
      session: null,
    });
    return ref;
  };
  const script = {
    ...core,
    /** Answers the call `name` with `answer` (its params in, its result out). */
    answer<P>(name: string, answer: (params: P) => unknown) {
      answers.set(name, answer as Answer);
    },
    /** Says `name`'s value (by its params) with `say`. */
    topic(name: string, say: (topic: Record<string, unknown>) => unknown) {
      topics.set(name, say);
    },
    snapshot: () => lifecycle,
    /** The topics the app subscribed to, by name, in order. */
    subscribed: () => [...subscribed],
    signIn: (who: TestUser) => publish(signedIn(who)),
    signOut: (reason: SignedOutSessionSnapshot["reason"]) => publish(signedOut(reason)),
    /** The lifecycle could not tell what the Cookie holds after `operation`. */
    failClosed: (code: SessionProblemCode, operation: SessionProblemOperation) =>
      publish({
        ...header(),
        generation,
        phase: "indeterminate",
        principal: null,
        problem: {
          code,
          operation,
          recovery:
            code === "credential_mutation_uncertain" ? "reconcile" : "retry_operation",
          retryable: code !== "credential_mutation_uncertain",
        } as never,
        session: null,
      }),
    signingOut: () =>
      publish({
        ...header(),
        generation,
        phase: "signing_out",
        principal: null,
        session: null,
      }),
    begin,
    /** The emailed code sign-in: the challenge `request` answers, and who `verify` signs in. */
    emailLogin({
      challengeId,
      code,
      who,
    }: {
      challengeId: string;
      code: string;
      who: TestUser;
    }) {
      script.answer("session.email.request", ({ email }: { email: string }) => ({
        ok: true,
        value: {
          attempt: begin("email", { challengeId, purpose: "email_login", email }),
          challengeId,
          code,
        },
      }));
      script.answer("session.email.verify", () => ({
        ok: true,
        value: script.signIn(who),
      }));
    },
    /** A Google attempt the page's button is rendered with. */
    googleAttempt(providerAttemptId: string, nonce: string) {
      return {
        ok: true,
        value: {
          attempt: begin("google"),
          clientId: "comma-web-client.apps.googleusercontent.com",
          nonce,
          providerAttemptId,
        },
      };
    },
  };
  // The server offers no Google sign-in and no guest sessions until a test says otherwise.
  script.answer("session.google.attempt", () =>
    refused("sign_in_with_google", "provider_unavailable", "retry_operation")
  );
  script.answer("session.guest.availability", () => false);
  // Home's workspace chat is still being found.
  script.answer("chat.resolveWorkspaceChat", () => new Promise(() => undefined));
  script.answer("session.reconcile", () => ({ ok: true, value: lifecycle }));
  script.answer("session.cancelAuth", () => ({
    ok: true,
    value: script.signOut("no_session"),
  }));
  script.answer("session.signOut", () => {
    script.signingOut();
    return { ok: true, value: script.signOut("user_signed_out") };
  });
  return script;
}

/**
 * The command palette's Task search as the core answers it: each query in `answers` (a promise: when the test
 * settles it), any other one never (the person typed on before the core asked). Returns the queries the UI sent.
 */
function scriptTaskSearch(
  answers: Record<string, TaskSearchValue | Promise<TaskSearchValue>>
) {
  app.answer("search.tasks", ({ query }: { query: string }) =>
    Object.hasOwn(answers, query) ? answers[query] : new Promise(() => undefined)
  );
  return () =>
    app.sentTo("search.tasks").map((params) => (params as { query: string }).query);
}

/** A view's conversation, as its key. */
const keyOf = (view: Record<string, unknown>) =>
  `${String(view.group)}/${String(view.conversation)}`;

/**
 * The window's chat on the scripted core: each conversation a window shows is ready and empty, with the draft it was
 * given; a send is accepted (the test reads it from `chatView.send`).
 */
function scriptChat(core: AppCore) {
  const session = { sessionId: testSessionId, audience: "http://127.0.0.1" };
  const drafts = new Map<string, string>();
  let revision = 0;
  let draftEpoch = 0;
  core.topic("chatView", (view: Record<string, unknown>) => ({
    session,
    revision,
    draftEpoch,
    lease: { leaseId: "lease", subscriberId: `${String(view.surface)}:${keyOf(view)}` },
    state: {
      ...idleConversationChannelState,
      connection: "live" as const,
      conversation: {
        group_id: String(view.group),
        id: String(view.conversation),
        kind: "user_chat" as const,
        status: "active",
        title: "聊天",
      },
      draft: drafts.get(keyOf(view)) ?? "",
      status: "ready" as const,
    },
  }));
  const changed = () => {
    revision += 1;
    queueMicrotask(() => core.changed("chatView"));
    return { revision, draftEpoch };
  };
  core.answer(
    "chatView.setDraft",
    (input: { group: string; conversation: string; draft: string }) => {
      drafts.set(keyOf(input), input.draft);
      draftEpoch += 1;
      return changed();
    }
  );
  core.answer("chatView.send", (input: { group: string; conversation: string }) => {
    drafts.set(keyOf(input), "");
    draftEpoch += 1;
    return changed();
  });
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

/**
 * Lets what the app started finish without moving the clock: the modules of its lazy screens, the scripted core's
 * answers and values, and React's work.
 */
async function settle() {
  for (let round = 0; round < 3; round += 1) {
    await act(() => vi.dynamicImportSettled());
    await flush();
  }
}

/**
 * The core's task conversation previews as these tests script them: each Task the app asks for is read once with
 * `read` (its id goes into `requested`), and answered with its messages as the core projects them.
 */
function scriptTaskPreviews(
  requested: string[],
  read: (conversationId: string) => CommaConversation | Promise<CommaConversation>
) {
  const answers = new Map<string, TaskConversationValue>();
  app.topic("taskConversation", (topic) => {
    const id = String(topic.conversation);
    if (!requested.includes(id)) {
      requested.push(id);
      void Promise.resolve(read(id)).then((conversation) => {
        answers.set(id, {
          status: "ready",
          messages: normalizeServerMessages(
            conversation.messages ?? [],
            [],
            conversation.kind
          ),
        });
        app.changed("taskConversation");
      });
    }
    return answers.get(id) ?? { status: "loading" };
  });
}

function renderCommaApp(
  productInboxController: CoreClient = createProductInboxProjectionHarness({
    initial: { items: [], source: "live-sync" },
  }).controller
) {
  // The task list is the projection harness's; the rest of the core is this test's script.
  delegateScriptedCore(productInboxController, app.client);
  return renderWithSessionHost(
    app.wrap(
      <CoreProvider client={productInboxController}>
        <CommaApp />
      </CoreProvider>
    )
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
  // The page shows the session the core runs, as the web app does.
  const controller = createCoreSessionHostController({
    apiBaseUrl: "http://127.0.0.1",
    core: app.client,
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

/** The page's own requests (a Task preview reads its conversation itself): `handler` answers them. */
function installCommaFetchStub(
  handler: (url: string, init?: RequestInit) => Promise<Response> = async (
    url,
    init
  ) => {
    const method = init?.method ?? "GET";
    return jsonResponse({ error: `unhandled ${method} ${requestPath(url)}` }, 404);
  }
) {
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.toString()
          : input.url;
    return handler(url, init);
  });

  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
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

/** A promise the test settles (`resolve`) when it chooses. */
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

function installGoogleIdentityServicesStub() {
  let credentialCallback: ((response: { credential?: string }) => void) | undefined;
  const initialize = vi.fn(
    (config: { callback: (response: { credential?: string }) => void }) => {
      credentialCallback = config.callback;
    }
  );
  const renderButton = vi.fn();

  stubProperty(window, "google", {
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
