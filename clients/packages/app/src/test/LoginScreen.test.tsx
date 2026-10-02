import userEvent from "@testing-library/user-event";
import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { LoginScreen } from "../components/LoginScreen";
import { sessionOperationDisplayError } from "../session/operation-error-message";
import { reportCommaGoogleLoginFailure } from "../analytics/client";
vi.mock("../analytics/client", () => ({ reportCommaGoogleLoginFailure: vi.fn() }));
import type {
  SessionAuthenticatorController,
  SessionGuestController,
  SessionLoginChallenge,
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
    verifyEmailLogin: vi.fn(async () => undefined),
    verifyGoogleLink: vi.fn(async () => undefined),
    ...overrides,
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

  afterEach(() => {
    vi.useRealTimers();
  });

  it("renders the design-system login instead of the legacy panel", () => {
    renderLoginScreen(createStagedAuthenticator());

    expect(screen.getByRole("heading", { name: "Welcome to Comma" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Sign in with Google" })).toBeEnabled();
    expect(
      screen.queryByRole("button", { name: "Sign in with Apple" })
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("heading", { name: "Sign in to Comma" })
    ).not.toBeInTheDocument();
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

  it("retries the same completed code through an explicit recovery action", async () => {
    const verifyEmailLogin = vi
      .fn(async () => undefined)
      .mockRejectedValueOnce(new Error("Sign-in is temporarily unavailable."));
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

  it("keeps email resend unavailable until the 60-second service cooldown", async () => {
    vi.useFakeTimers();
    const authenticator = createStagedAuthenticator();
    renderLoginScreen(authenticator);

    fireEvent.change(screen.getByRole("textbox", { name: "Email" }), {
      target: { value: "person@example.com" },
    });
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Continue with email" }));
      await Promise.resolve();
    });

    expect(screen.getByText("Resend in 60s")).toBeVisible();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(59_000);
    });
    expect(screen.getByText("Resend in 1s")).toBeVisible();
    expect(screen.queryByRole("button", { name: "Resend" })).not.toBeInTheDocument();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(1_000);
    });
    expect(screen.getByRole("button", { name: "Resend" })).toBeEnabled();

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Resend" }));
      await Promise.resolve();
    });
    expect(authenticator.requestEmailLogin).toHaveBeenCalledTimes(2);
    expect(authenticator.requestEmailLogin).toHaveBeenLastCalledWith(
      "person@example.com"
    );
    expect(screen.getByText("Resend in 60s")).toBeVisible();
  });

  it("returns to a recoverable email stage when resend fails", async () => {
    vi.useFakeTimers();
    const requestEmailLogin = vi
      .fn<(email: string) => Promise<SessionLoginChallenge>>()
      .mockResolvedValueOnce({
        challengeId: "challenge-1",
        email: "person@example.com",
        kind: "challenge",
        purpose: "email_login",
      })
      .mockRejectedValueOnce(new Error("Too many attempts. Please wait."))
      .mockResolvedValueOnce({
        challengeId: "challenge-2",
        email: "person@example.com",
        kind: "challenge",
        purpose: "email_login",
      });
    const authenticator = createStagedAuthenticator({ requestEmailLogin });
    renderLoginScreen(authenticator);

    fireEvent.change(screen.getByRole("textbox", { name: "Email" }), {
      target: { value: "person@example.com" },
    });
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Continue with email" }));
      await Promise.resolve();
      await vi.advanceTimersByTimeAsync(60_000);
    });
    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Resend" }));
      await Promise.resolve();
    });

    expect(screen.getByRole("heading", { name: "Welcome to Comma" })).toBeVisible();
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Too many attempts. Please wait."
    );
    expect(screen.getByRole("textbox", { name: "Email" })).toHaveValue(
      "person@example.com"
    );

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "Continue with email" }));
      await Promise.resolve();
    });
    expect(requestEmailLogin).toHaveBeenCalledTimes(3);
    expect(screen.getByRole("heading", { name: "Check your email" })).toBeVisible();
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

  it("cancels the attempt and returns to email entry for a different email", async () => {
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

    expect(authenticator.cancelCurrentAttempt).toHaveBeenCalledOnce();
    expect(
      await screen.findByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();
    expect(screen.getByRole("textbox", { name: "Email" })).toHaveValue(
      "person@example.com"
    );
  });

  it("keeps the active challenge visible when cancellation fails", async () => {
    const authenticator = createStagedAuthenticator({
      cancelCurrentAttempt: vi.fn(async () => {
        throw new Error("Could not cancel this attempt.");
      }),
    });
    const user = userEvent.setup();
    renderLoginScreen(authenticator);

    await user.type(
      screen.getByRole("textbox", { name: "Email" }),
      "person@example.com"
    );
    await user.click(screen.getByRole("button", { name: "Continue with email" }));
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
