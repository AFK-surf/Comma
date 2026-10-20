import userEvent from "@testing-library/user-event";
import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LoginScreen } from "../components/LoginScreen";
import { sessionOperationDisplayError } from "../session/operation-error-message";
import { reportCommaGoogleLoginFailure } from "../analytics/client";
vi.mock("../analytics/client", () => ({ reportCommaGoogleLoginFailure: vi.fn() }));
import type {
  SessionAuthenticatorController,
  SessionGuestController,
  SessionLoginChallenge,
  SessionLoginTiming,
} from "../session/controller";

function createStagedAuthenticator(
  overrides: Partial<SessionAuthenticatorController> = {}
): SessionAuthenticatorController {
  return {
    cancelCurrentAttempt: vi.fn(async () => undefined),
    mountGoogleControl: vi.fn(async () => () => undefined),
    requestGoogleLogin: vi.fn(async () => undefined),
    requestEmailLogin: vi.fn(
      async (email: string): Promise<SessionLoginChallenge> => ({
        challengeId: "challenge-1",
        email,
        kind: "challenge",
        purpose: "email_login",
      })
    ),
    // The core's countdown as it stands just after the first code was sent.
    loginTiming: scriptedLoginTiming({
      challenge: { challengeId: "challenge-1", expired: false, resendInSeconds: 60 },
    }).store,
    verifyEmailLogin: vi.fn(async () => undefined),
    verifyGoogleLink: vi.fn(async () => undefined),
    ...overrides,
  };
}

/** The countdowns as a scripted core gives them: the test says when they move. */
function scriptedLoginTiming(initial: SessionLoginTiming = {}) {
  let value = initial;
  const listeners = new Set<() => void>();
  return {
    store: {
      get: () => value,
      subscribe(listener: () => void) {
        listeners.add(listener);
        return () => void listeners.delete(listener);
      },
    },
    set(next: SessionLoginTiming) {
      act(() => {
        value = next;
        for (const listener of Array.from(listeners)) listener();
      });
    },
  };
}

function renderLoginScreen(
  authenticator: SessionAuthenticatorController,
  locale?: "en" | "zh-CN",
  guest?: SessionGuestController
) {
  return render(
    <CommaI18nProvider {...(locale ? { locale } : {})}>
      <LoginScreen authenticator={authenticator} {...(guest ? { guest } : {})} />
    </CommaI18nProvider>
  );
}

function createGuestController(enabled: boolean): SessionGuestController {
  return {
    availability: vi.fn(async () => enabled),
    beginSignUp: vi.fn(async () => undefined),
    start: vi.fn(async () => undefined),
    subscribeImported: vi.fn(() => () => undefined),
  };
}

describe("LoginScreen on hosts with direct Google sign-in (Electron)", () => {
  beforeEach(() => {
    initializeCommaI18n(["en"]);
  });

  it.each([true, false])(
    "offers guest mode only when the server enables it (%s)",
    async (enabled) => {
      const guest = createGuestController(enabled);
      const user = userEvent.setup();
      renderLoginScreen(createStagedAuthenticator(), undefined, guest);

      await waitFor(() => expect(guest.availability).toHaveBeenCalledOnce());
      if (!enabled) {
        expect(
          screen.queryByRole("button", { name: "Try without an account" })
        ).not.toBeInTheDocument();
        return;
      }
      await user.click(
        await screen.findByRole("button", { name: "Try without an account" })
      );
      expect(guest.start).toHaveBeenCalledOnce();
    }
  );

  it("blocks malformed emails before requesting a code", async () => {
    const authenticator = createStagedAuthenticator();
    const user = userEvent.setup();
    renderLoginScreen(authenticator);

    await user.type(screen.getByRole("textbox", { name: "Email" }), "not-an-email");
    await user.click(screen.getByRole("button", { name: "Continue with email" }));

    expect(authenticator.requestEmailLogin).not.toHaveBeenCalled();
    expect(screen.getByText("Please enter a valid email address.")).toBeVisible();
  });

  it("moves to verification after requesting an email code and verifies on completion", async () => {
    const user = userEvent.setup();
    const authenticator = createStagedAuthenticator();
    renderLoginScreen(authenticator);

    await user.type(
      screen.getByRole("textbox", { name: "Email" }),
      "person@example.com"
    );
    await user.click(screen.getByRole("button", { name: "Continue with email" }));

    expect(authenticator.requestEmailLogin).toHaveBeenCalledWith("person@example.com");
    expect(
      await screen.findByRole("heading", { name: "Check your email" })
    ).toBeVisible();
    expect(screen.getByText("Enter the code sent to person@example.com")).toBeVisible();
    expect(screen.getByText("Resend in 60s")).toBeVisible();

    await user.type(
      screen.getByRole("textbox", { name: "Verification code" }),
      "1ED3F1"
    );

    await waitFor(() => {
      expect(authenticator.verifyEmailLogin).toHaveBeenCalledWith({
        challengeId: "challenge-1",
        code: "1ED3F1",
      });
    });
    expect(authenticator.verifyGoogleLink).not.toHaveBeenCalled();
  });

  it("auto-verifies challenges that arrive with a prefilled code", async () => {
    const authenticator = createStagedAuthenticator({
      requestEmailLogin: vi.fn(
        async (email: string): Promise<SessionLoginChallenge> => ({
          challengeId: "challenge-dev",
          code: "AB12CD",
          email,
          kind: "challenge",
          purpose: "email_login",
        })
      ),
    });
    const user = userEvent.setup();
    renderLoginScreen(authenticator);

    await user.type(screen.getByRole("textbox", { name: "Email" }), "dev@example.com");
    await user.click(screen.getByRole("button", { name: "Continue with email" }));

    await waitFor(() => {
      expect(authenticator.verifyEmailLogin).toHaveBeenCalledWith({
        challengeId: "challenge-dev",
        code: "AB12CD",
      });
    });
  });

  it("shows a verification failure and retries once the code changes", async () => {
    const verifyEmailLogin = vi
      .fn(async () => undefined)
      .mockRejectedValueOnce(
        sessionOperationDisplayError("invalid_challenge", "Unsupported")
      );
    const authenticator = createStagedAuthenticator({ verifyEmailLogin });
    const user = userEvent.setup();
    renderLoginScreen(authenticator);

    await user.type(
      screen.getByRole("textbox", { name: "Email" }),
      "person@example.com"
    );
    await user.click(screen.getByRole("button", { name: "Continue with email" }));

    const codeInput = await screen.findByRole("textbox", {
      name: "Verification code",
    });
    await user.type(codeInput, "BAD111");

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "That verification code is invalid."
    );
    expect(screen.queryByRole("button", { name: "Try again" })).not.toBeInTheDocument();

    await user.type(codeInput, "{backspace}2");

    await waitFor(() => {
      expect(verifyEmailLogin).toHaveBeenCalledWith({
        challengeId: "challenge-1",
        code: "BAD112",
      });
    });
    expect(verifyEmailLogin).toHaveBeenCalledTimes(2);
  });

  it("retries the same completed code through an explicit recovery action when the core allows it", async () => {
    const verifyEmailLogin = vi
      .fn(async () => undefined)
      .mockRejectedValueOnce(new Error("Sign-in is temporarily unavailable."));
    // The core says the check got no answer about the code (session lifecycle tests): the same code may go again.
    const authenticator = createStagedAuthenticator({
      verifyEmailLogin,
      loginTiming: scriptedLoginTiming({
        challenge: {
          challengeId: "challenge-1",
          expired: false,
          resendInSeconds: 60,
          retrySameCode: true,
        },
      }).store,
    });
    const user = userEvent.setup();
    renderLoginScreen(authenticator);

    await user.type(
      screen.getByRole("textbox", { name: "Email" }),
      "person@example.com"
    );
    await user.click(screen.getByRole("button", { name: "Continue with email" }));
    const codeInput = await screen.findByRole("textbox", {
      name: "Verification code",
    });
    await user.type(codeInput, "ABC123");

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Sign-in is temporarily unavailable."
    );
    await user.click(screen.getByRole("button", { name: "Try again" }));

    await waitFor(() => expect(verifyEmailLogin).toHaveBeenCalledTimes(2));
    expect(verifyEmailLogin).toHaveBeenNthCalledWith(1, {
      challengeId: "challenge-1",
      code: "ABC123",
    });
    expect(verifyEmailLogin).toHaveBeenNthCalledWith(2, {
      challengeId: "challenge-1",
      code: "ABC123",
    });
    expect(codeInput).toHaveValue("ABC123");
  });

  it("keeps email resend unavailable while the core counts down its delay", async () => {
    const timing = scriptedLoginTiming();
    const authenticator = createStagedAuthenticator({ loginTiming: timing.store });
    renderLoginScreen(authenticator);

    fireEvent.change(screen.getByRole("textbox", { name: "Email" }), {
      target: { value: "person@example.com" },
    });
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Continue with email" }));
    });
    timing.set({
      challenge: { challengeId: "challenge-1", expired: false, resendInSeconds: 60 },
    });
    expect(screen.getByText("Resend in 60s")).toBeVisible();
    timing.set({
      challenge: { challengeId: "challenge-1", expired: false, resendInSeconds: 1 },
    });
    expect(screen.getByText("Resend in 1s")).toBeVisible();
    expect(screen.queryByRole("button", { name: "Resend" })).not.toBeInTheDocument();

    timing.set({
      challenge: { challengeId: "challenge-1", expired: false, resendInSeconds: 0 },
    });
    expect(screen.getByRole("button", { name: "Resend" })).toBeEnabled();
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Resend" }));
    });
    expect(authenticator.requestEmailLogin).toHaveBeenCalledTimes(2);
    expect(authenticator.requestEmailLogin).toHaveBeenLastCalledWith(
      "person@example.com",
      { resend: true }
    );
  });

  // Whether the address goes back to its code is the core's decision (session lifecycle tests): the screen shows it.
  it("shows the code under way again when the core goes back to it for the address typed after editing", async () => {
    const timing = scriptedLoginTiming({
      challenge: { challengeId: "challenge-1", expired: false, resendInSeconds: 35 },
    });
    const authenticator = createStagedAuthenticator({ loginTiming: timing.store });
    renderLoginScreen(authenticator);
    fireEvent.change(screen.getByRole("textbox", { name: "Email" }), {
      target: { value: "person@example.com" },
    });
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Continue with email" }));
    });
    fireEvent.click(screen.getByRole("button", { name: "Use a different email" }));
    fireEvent.change(screen.getByRole("textbox", { name: "Email" }), {
      target: { value: "Person@EXAMPLE.com" },
    });
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Continue with email" }));
    });
    expect(screen.getByRole("heading", { name: "Check your email" })).toBeVisible();
    expect(screen.getByText("Resend in 35s")).toBeVisible();
    expect(authenticator.requestEmailLogin).toHaveBeenCalledTimes(2);
    expect(authenticator.requestEmailLogin).toHaveBeenLastCalledWith(
      "Person@EXAMPLE.com"
    );
    expect(authenticator.cancelCurrentAttempt).not.toHaveBeenCalled();
    await act(async () => {
      fireEvent.change(screen.getByRole("textbox", { name: "Verification code" }), {
        target: { value: "123456" },
      });
    });
    expect(authenticator.verifyEmailLogin).toHaveBeenCalledWith({
      challengeId: "challenge-1",
      code: "123456",
    });
  });

  it("requests a fresh code when the core says the retained challenge expired", async () => {
    const timing = scriptedLoginTiming();
    const authenticator = createStagedAuthenticator({ loginTiming: timing.store });
    renderLoginScreen(authenticator);
    fireEvent.change(screen.getByRole("textbox", { name: "Email" }), {
      target: { value: "person@example.com" },
    });
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Continue with email" }));
    });
    fireEvent.click(screen.getByRole("button", { name: "Use a different email" }));
    timing.set({
      challenge: { challengeId: "challenge-1", expired: true, resendInSeconds: 0 },
    });
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Continue with email" }));
    });
    expect(authenticator.requestEmailLogin).toHaveBeenCalledTimes(2);
    expect(screen.getByRole("heading", { name: "Check your email" })).toBeVisible();
  });

  it("shows the server wait on email entry while allowing the address to be edited", async () => {
    const timing = scriptedLoginTiming();
    const authenticator = createStagedAuthenticator({
      loginTiming: timing.store,
      requestEmailLogin: vi
        .fn()
        .mockRejectedValue(
          sessionOperationDisplayError("rate_limited", "", "en", 35_000)
        ),
    });
    renderLoginScreen(authenticator);
    fireEvent.change(screen.getByRole("textbox", { name: "Email" }), {
      target: { value: "person@example.com" },
    });
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Continue with email" }));
    });
    timing.set({ cooldown: { email: "person@example.com", seconds: 35 } });
    expect(screen.getByRole("button", { name: "Try again in 35s" })).toBeDisabled();
    expect(screen.getByRole("textbox", { name: "Email" })).toBeEnabled();
    fireEvent.change(screen.getByRole("textbox", { name: "Email" }), {
      target: { value: "other@example.com" },
    });
    expect(screen.getByRole("button", { name: "Continue with email" })).toBeEnabled();
    fireEvent.change(screen.getByRole("textbox", { name: "Email" }), {
      target: { value: "person@example.com" },
    });
    expect(screen.getByRole("button", { name: "Try again in 35s" })).toBeDisabled();
    timing.set({});
    expect(screen.getByRole("button", { name: "Continue with email" })).toBeEnabled();
    expect(authenticator.requestEmailLogin).toHaveBeenCalledOnce();
  });

  it("keeps the original challenge and retry countdown when resend is rate limited", async () => {
    const timing = scriptedLoginTiming();
    const requestEmailLogin = vi
      .fn<(email: string) => Promise<SessionLoginChallenge>>()
      .mockResolvedValueOnce({
        challengeId: "challenge-1",
        email: "person@example.com",
        kind: "challenge",
        purpose: "email_login",
      })
      .mockRejectedValueOnce(
        sessionOperationDisplayError("rate_limited", "", "en", 45_000)
      );
    const authenticator = createStagedAuthenticator({
      loginTiming: timing.store,
      requestEmailLogin,
      // The core keeps the code after the refused resend.
      sharedChallenge: {
        get: () => ({
          challengeId: "challenge-1",
          email: "person@example.com",
          kind: "challenge",
          purpose: "email_login",
        }),
        subscribe: () => () => undefined,
      },
    });
    renderLoginScreen(authenticator);

    fireEvent.change(screen.getByRole("textbox", { name: "Email" }), {
      target: { value: "person@example.com" },
    });
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Continue with email" }));
    });
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Resend" }));
    });
    // The core counts the next resend's wait as the address's retry-after.
    timing.set({
      challenge: { challengeId: "challenge-1", expired: false, resendInSeconds: 45 },
    });

    expect(screen.getByRole("heading", { name: "Check your email" })).toBeVisible();
    expect(screen.getByRole("alert")).toHaveTextContent("Too many attempts");
    expect(screen.getByText("Resend in 45s")).toBeVisible();
    await act(async () => {
      fireEvent.change(screen.getByRole("textbox", { name: "Verification code" }), {
        target: { value: "123456" },
      });
    });
    expect(requestEmailLogin).toHaveBeenCalledTimes(2);
    expect(authenticator.verifyEmailLogin).toHaveBeenCalledWith({
      challengeId: "challenge-1",
      code: "123456",
    });
  });

  it("shows Google progress immediately and allows retry after focus or failure", async () => {
    const attempts: Array<{
      input: Parameters<
        NonNullable<SessionAuthenticatorController["requestGoogleLogin"]>
      >[0];
      resolve: () => void;
    }> = [];
    const requestGoogleLogin = vi.fn(
      (input) =>
        new Promise<void>((resolve) => {
          attempts.push({ input, resolve });
        })
    );
    renderLoginScreen(createStagedAuthenticator({ requestGoogleLogin }));
    const user = userEvent.setup();
    const google = screen.getByRole("button", { name: "Sign in with Google" });
    const email = screen.getByRole("textbox", { name: "Email" });

    await user.click(google);
    expect(google).toHaveAttribute("aria-disabled", "true");
    fireEvent(window, new Event("blur"));
    expect(google).toHaveAttribute("aria-disabled", "true");
    expect(email).toBeEnabled();
    await user.click(google);
    expect(requestGoogleLogin).toHaveBeenCalledOnce();
    await user.type(email, "person@example.com");
    expect(screen.getByRole("button", { name: "Continue with email" })).toBeEnabled();
    fireEvent(window, new Event("focus"));
    expect(google).not.toHaveAttribute("aria-disabled", "true");
    fireEvent(window, new Event("blur"));
    expect(google).not.toHaveAttribute("aria-disabled", "true");

    await user.click(google);
    expect(requestGoogleLogin).toHaveBeenCalledTimes(2);
    fireEvent(window, new Event("blur"));
    await act(async () => {
      attempts[0]!.input.onError(new Error("Old attempt cancelled"));
      attempts[0]!.resolve();
    });
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(google).toHaveAttribute("aria-disabled", "true");
    await act(async () => {
      attempts[1]!.input.onError(
        sessionOperationDisplayError("provider_unavailable", "unsupported")
      );
      attempts[1]!.resolve();
    });
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Comma could not complete sign-in"
    );
    expect(reportCommaGoogleLoginFailure).toHaveBeenCalledWith("provider_unavailable");
    expect(screen.getByRole("button", { name: "Retry Google sign-in" })).toBeEnabled();
    expect(google).not.toHaveAttribute("aria-disabled", "true");
    fireEvent(window, new Event("blur"));
    expect(google).not.toHaveAttribute("aria-disabled", "true");
  });

  it("switches to email while Google is pending and ignores its late challenge", async () => {
    let complete!: () => void;
    const requestGoogleLogin = vi.fn(
      (input) =>
        new Promise<void>((resolve) => {
          complete = () => {
            input.onResult({
              kind: "challenge",
              purpose: "google_link",
              challengeId: "old-google",
              email: "old@example.com",
            });
            resolve();
          };
        })
    );
    const authenticator = createStagedAuthenticator({ requestGoogleLogin });
    renderLoginScreen(authenticator);
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Sign in with Google" }));
    fireEvent(window, new Event("blur"));
    await user.type(
      screen.getByRole("textbox", { name: "Email" }),
      "person@example.com"
    );
    await user.click(screen.getByRole("button", { name: "Continue with email" }));
    await act(async () => complete());
    expect(screen.getByText("Enter the code sent to person@example.com")).toBeVisible();
    await user.type(
      screen.getByRole("textbox", { name: "Verification code" }),
      "123456"
    );
    expect(authenticator.verifyEmailLogin).toHaveBeenCalledWith({
      challengeId: "challenge-1",
      code: "123456",
    });
    expect(authenticator.verifyGoogleLink).not.toHaveBeenCalled();
  });

  it("starts Google sign-in directly and verifies its linking challenge", async () => {
    const requestGoogleLogin = vi.fn(
      async (input: {
        onError(error: Error): void;
        onResult(result: { kind: "signed_in" } | SessionLoginChallenge): void;
      }) => {
        input.onResult({
          challengeId: "challenge-google",
          email: "google-person@example.com",
          kind: "challenge",
          purpose: "google_link",
        });
      }
    );
    const authenticator = createStagedAuthenticator({ requestGoogleLogin });
    const user = userEvent.setup();
    renderLoginScreen(authenticator);

    await user.click(screen.getByRole("button", { name: "Sign in with Google" }));

    expect(requestGoogleLogin).toHaveBeenCalledOnce();
    expect(
      await screen.findByRole("heading", { name: "Check your email" })
    ).toBeVisible();
    expect(
      screen.getByText("Enter the code sent to google-person@example.com")
    ).toBeVisible();
    expect(screen.queryByText(/Resend/)).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Resend" })).not.toBeInTheDocument();

    await user.type(
      screen.getByRole("textbox", { name: "Verification code" }),
      "1ED3F1"
    );

    await waitFor(() => {
      expect(authenticator.verifyGoogleLink).toHaveBeenCalledWith({
        challengeId: "challenge-google",
        code: "1ED3F1",
      });
    });
    expect(authenticator.verifyEmailLogin).not.toHaveBeenCalled();
    expect(authenticator.requestEmailLogin).not.toHaveBeenCalled();
  });

  it("localizes the staged Electron login surface", async () => {
    initializeCommaI18n(["zh-CN"]);
    const authenticator = createStagedAuthenticator();
    const user = userEvent.setup();
    renderLoginScreen(authenticator, "zh-CN");

    expect(screen.getByRole("region", { name: "登录" })).toBeVisible();
    expect(screen.getByRole("heading", { name: "欢迎使用 Comma" })).toBeVisible();
    expect(screen.getByRole("button", { name: "使用 Google 登录" })).toBeEnabled();
    const emailInput = screen.getByRole("textbox", { name: "邮箱" });
    expect(emailInput).toHaveAttribute("placeholder", "你的邮箱地址");

    await user.type(emailInput, "not-an-email");
    await user.click(screen.getByRole("button", { name: "使用邮箱继续" }));
    expect(screen.getByText("请输入有效的邮箱地址。")).toBeVisible();

    await user.clear(emailInput);
    await user.type(emailInput, "person@example.com");
    await user.click(screen.getByRole("button", { name: "使用邮箱继续" }));
    expect(await screen.findByRole("heading", { name: "查看你的邮箱" })).toBeVisible();
    expect(screen.getByText("请输入发送至 person@example.com 的验证码")).toBeVisible();
    expect(screen.getByRole("textbox", { name: "验证码" })).toBeEnabled();
    expect(screen.getByText("60 秒后可重新发送")).toBeVisible();
    expect(screen.getByRole("button", { name: "使用其他邮箱" })).toBeEnabled();
  });

  it("requests a new challenge only after a different email is submitted", async () => {
    const authenticator = createStagedAuthenticator();
    const user = userEvent.setup();
    renderLoginScreen(authenticator);

    await user.type(
      screen.getByRole("textbox", { name: "Email" }),
      "person@example.com"
    );
    await user.click(screen.getByRole("button", { name: "Continue with email" }));
    await screen.findByRole("heading", { name: "Check your email" });

    await user.click(screen.getByRole("button", { name: "Use a different email" }));

    expect(
      await screen.findByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    expect(screen.getByRole("textbox", { name: "Email" })).toHaveValue(
      "person@example.com"
    );
    await user.clear(screen.getByRole("textbox", { name: "Email" }));
    await user.type(
      screen.getByRole("textbox", { name: "Email" }),
      "other@example.com"
    );
    await user.click(screen.getByRole("button", { name: "Continue with email" }));
    expect(
      await screen.findByText("Enter the code sent to other@example.com")
    ).toBeVisible();
    expect(authenticator.requestEmailLogin).toHaveBeenCalledTimes(2);
    expect(authenticator.requestEmailLogin).toHaveBeenLastCalledWith(
      "other@example.com"
    );
  });

  it("keeps a Google linking challenge visible when cancellation fails", async () => {
    const authenticator = createStagedAuthenticator({
      requestGoogleLogin: vi.fn(async ({ onResult }) => {
        onResult({
          kind: "challenge",
          challengeId: "google-link",
          purpose: "google_link",
          email: "person@example.com",
        });
      }),
      cancelCurrentAttempt: vi.fn(async () => {
        throw new Error("Could not cancel this attempt.");
      }),
    });
    const user = userEvent.setup();
    renderLoginScreen(authenticator);

    await user.click(screen.getByRole("button", { name: "Sign in with Google" }));
    await screen.findByRole("heading", { name: "Check your email" });
    await user.click(screen.getByRole("button", { name: "Use a different email" }));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Could not cancel this attempt."
    );
    expect(screen.getByRole("heading", { name: "Check your email" })).toBeVisible();
    expect(screen.queryByRole("textbox", { name: "Email" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Try again" })).not.toBeInTheDocument();
  });
});

describe("LoginScreen on browser hosts", () => {
  beforeEach(() => {
    initializeCommaI18n(["en"]);
  });

  it("starts a guest Session from the browser login when enabled", async () => {
    const authenticator = createStagedAuthenticator();
    delete authenticator.requestGoogleLogin;
    const guest = createGuestController(true);
    const user = userEvent.setup();
    renderLoginScreen(authenticator, undefined, guest);

    await user.click(
      await screen.findByRole("button", { name: "Try without an account" })
    );
    expect(guest.start).toHaveBeenCalledOnce();
  });

  it("keeps the legacy provider-mounted Google flow", () => {
    const authenticator = createStagedAuthenticator();
    delete authenticator.requestGoogleLogin;
    renderLoginScreen(authenticator);

    expect(screen.getByRole("heading", { name: "Sign in to Comma" })).toBeVisible();
    expect(authenticator.mountGoogleControl).toHaveBeenCalledOnce();
    expect(
      screen.queryByRole("heading", { name: "Welcome to Comma" })
    ).not.toBeInTheDocument();
  });
});
