import { LoadingIndicator } from "@comma/ui";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { commaLogoUrl, getActiveCommaConfig } from "@comma/config";
import { useCommaMessages } from "@comma/i18n/react";
import { Button, Login, Text } from "@comma/ui";
import type { LoginCopy } from "@comma/ui";
import type {
  SessionAuthenticatorController,
  SessionLoginChallenge,
} from "../session/react";
import { SessionOperationDisplayError } from "../session/operation-error-message";

type ChallengePurpose = SessionLoginChallenge["purpose"];

type LoginScreenProps = {
  authenticator: SessionAuthenticatorController;
  revocationPending?: boolean | undefined;
  /**
   * Generic banner shown while an OAuth IdP round trip is pending
   * (docs/identity-security.md). Generic on purpose: the handle is
   * opaque, so the client app's name is unknown here by design.
   */
  oauthResumeNotice?: string | undefined;
};

const RESEND_DELAY_SECONDS = 60;

export function LoginScreen(props: LoginScreenProps) {
  const requestGoogleLogin = props.authenticator.requestGoogleLogin?.bind(
    props.authenticator
  );
  if (requestGoogleLogin) {
    return <StagedLoginScreen {...props} requestGoogleLogin={requestGoogleLogin} />;
  }
  return <LegacyLoginScreen {...props} />;
}

/**
 * Login flow built on the design-system `Login` component. Used on hosts
 * whose authenticator can start Google sign-in directly (Electron Main);
 * browser hosts stay on {@link LegacyLoginScreen} because Google renders its
 * own sign-in control there.
 */
function StagedLoginScreen({
  authenticator,
  requestGoogleLogin,
  revocationPending = false,
  oauthResumeNotice,
}: LoginScreenProps & {
  requestGoogleLogin: NonNullable<SessionAuthenticatorController["requestGoogleLogin"]>;
}) {
  const messages = useCommaMessages();
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [challengeId, setChallengeId] = useState("");
  const [challengePurpose, setChallengePurpose] = useState<ChallengePurpose>();
  const [busy, setBusy] = useState(false);
  const [googlePending, setGooglePending] = useState(false);
  const [googleRetryAvailable, setGoogleRetryAvailable] = useState(false);
  const googleAttemptRef = useRef<(() => void) | undefined>(undefined);

  function clearGoogleAttempt() {
    googleAttemptRef.current?.();
    googleAttemptRef.current = undefined;
    setGooglePending(false);
  }

  useEffect(
    () => () => {
      googleAttemptRef.current?.();
      googleAttemptRef.current = undefined;
    },
    []
  );
  const [error, setError] = useState("");
  const [verificationRetryAvailable, setVerificationRetryAvailable] = useState(false);
  const [resendSeconds, setResendSeconds] = useState(RESEND_DELAY_SECONDS);
  const [resendAvailableAt, setResendAvailableAt] = useState(0);
  const [verificationRevision, setVerificationRevision] = useState(0);
  const lastAttemptedCodeRef = useRef("");
  const hasChallenge = Boolean(challengeId);
  const canResend = hasChallenge && challengePurpose === "email_login";

  const loginCopy: LoginCopy = {
    regionLabel: messages.auth_sign_in_region(),
    email: {
      title: messages.auth_welcome_title(),
      subtitle: messages.auth_agent_subtitle(),
      googleAction: googleRetryAvailable
        ? messages.auth_google_retry()
        : messages.auth_sign_in_google(),
      appleAction: messages.auth_sign_in_apple(),
      label: messages.auth_email_label(),
      placeholder: messages.auth_email_address_placeholder(),
      continueAction: messages.auth_continue_email(),
      invalidError: messages.auth_email_invalid(),
    },
    verification: {
      title: messages.auth_check_email_title(),
      instruction: (nextEmail) =>
        messages.auth_enter_code_sent_to({ email: nextEmail }),
      codeLabel: messages.auth_verification_code_label(),
      codeNotReceived: messages.auth_code_not_received(),
      resendAction: messages.auth_resend(),
      resendCountdown: (seconds) => messages.auth_resend_countdown({ seconds }),
      retryAction: messages.auth_try_again(),
      differentEmailAction: messages.auth_use_different_email(),
    },
  };

  useEffect(() => {
    if (!canResend || resendAvailableAt <= 0) {
      return;
    }
    const updateRemainingTime = () => {
      const remaining = Math.max(
        0,
        Math.ceil((resendAvailableAt - Date.now()) / 1_000)
      );
      setResendSeconds(remaining);
      return remaining;
    };
    if (updateRemainingTime() === 0) {
      return;
    }
    const timer = setInterval(() => {
      if (updateRemainingTime() === 0) {
        clearInterval(timer);
      }
    }, 1_000);
    return () => clearInterval(timer);
  }, [canResend, resendAvailableAt]);

  // Verifies as soon as six characters exist, covering both typed completion
  // and challenges that arrive with a prefilled code (local dev). Each code is
  // attempted once; editing the code below six characters re-arms the attempt.
  useEffect(() => {
    if (!hasChallenge || code.length !== 6) {
      lastAttemptedCodeRef.current = "";
      return;
    }
    if (code === lastAttemptedCodeRef.current) {
      return;
    }
    lastAttemptedCodeRef.current = code;

    setBusy(true);
    setError("");
    setVerificationRetryAvailable(false);
    const input = { challengeId, code };
    const verify =
      challengePurpose === "google_link"
        ? authenticator.verifyGoogleLink(input)
        : authenticator.verifyEmailLogin(input);
    void verify
      .catch((nextError: unknown) => {
        setError(nextError instanceof Error ? nextError.message : String(nextError));
        setVerificationRetryAvailable(canRetryCompletedCode(nextError));
      })
      .finally(() => {
        setBusy(false);
      });
  }, [
    authenticator,
    challengeId,
    challengePurpose,
    code,
    hasChallenge,
    verificationRevision,
  ]);

  async function runAuthTask(task: () => Promise<void>): Promise<boolean> {
    setBusy(true);
    setError("");
    setVerificationRetryAvailable(false);
    try {
      await task();
      return true;
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : String(nextError));
      return false;
    } finally {
      setBusy(false);
    }
  }

  function applyChallenge(challenge: SessionLoginChallenge) {
    lastAttemptedCodeRef.current = "";
    setVerificationRetryAvailable(false);
    setChallengeId(challenge.challengeId);
    setChallengePurpose(challenge.purpose);
    setCode(challenge.code ?? "");
    if (challenge.email) {
      setEmail(challenge.email);
    }
    setResendAvailableAt(Date.now() + RESEND_DELAY_SECONDS * 1_000);
    setResendSeconds(RESEND_DELAY_SECONDS);
  }

  function handleContinueWithEmail(nextEmail: string) {
    clearGoogleAttempt();
    setGoogleRetryAvailable(false);
    setEmail(nextEmail);
    void runAuthTask(async () => {
      applyChallenge(await authenticator.requestEmailLogin(nextEmail));
    });
  }

  function handleContinueWithGoogle() {
    clearGoogleAttempt();
    setError("");
    setGoogleRetryAvailable(false);
    setGooglePending(true);
    const onBlur = () => {
      setGooglePending(true);
      window.addEventListener("focus", onFocus, { once: true });
    };
    const onFocus = () => {
      cleanup();
      setGooglePending(false);
    };
    const cleanup = () => {
      window.removeEventListener("blur", onBlur);
      window.removeEventListener("focus", onFocus);
    };
    googleAttemptRef.current = cleanup;
    window.addEventListener("blur", onBlur, { once: true });
    const isCurrent = () => googleAttemptRef.current === cleanup;

    void requestGoogleLogin({
      onError(nextError) {
        if (isCurrent()) {
          setError(nextError.message);
          setGoogleRetryAvailable(true);
          if (nextError instanceof SessionOperationDisplayError) {
            void import("../analytics/client")
              .then(({ reportCommaGoogleLoginFailure }) =>
                reportCommaGoogleLoginFailure(nextError.code)
              )
              .catch(() => undefined);
          }
        }
      },
      onResult(result) {
        if (isCurrent() && result.kind !== "signed_in") {
          applyChallenge(result);
        }
      },
    })
      .catch((nextError: unknown) => {
        if (isCurrent()) {
          setError(nextError instanceof Error ? nextError.message : String(nextError));
          setGoogleRetryAvailable(true);
        }
      })
      .finally(() => {
        if (isCurrent()) clearGoogleAttempt();
      });
  }

  function handleCodeChange(nextCode: string) {
    setCode(nextCode);
    if (error) {
      setError("");
    }
    setVerificationRetryAvailable(false);
  }

  function handleResend() {
    void (async () => {
      const succeeded = await runAuthTask(async () => {
        applyChallenge(await authenticator.requestEmailLogin(email));
      });
      if (!succeeded) {
        lastAttemptedCodeRef.current = "";
        setChallengeId("");
        setChallengePurpose(undefined);
        setCode("");
      }
    })();
  }

  function handleRetry() {
    if (busy || code.length !== 6) {
      return;
    }
    lastAttemptedCodeRef.current = "";
    setError("");
    setVerificationRetryAvailable(false);
    setVerificationRevision((current) => current + 1);
  }

  function handleUseDifferentEmail() {
    void (async () => {
      const succeeded = await runAuthTask(() => authenticator.cancelCurrentAttempt());
      if (!succeeded) {
        return;
      }
      lastAttemptedCodeRef.current = "";
      setChallengeId("");
      setChallengePurpose(undefined);
      setCode("");
      setError("");
    })();
  }

  const externalError = hasChallenge || googleRetryAvailable ? "" : error;
  const externalMessage =
    externalError || (revocationPending ? messages.auth_revocation_pending() : "");

  return (
    <main className="app-login-shell">
      <div className="app-login-stage">
        {oauthResumeNotice && <OauthResumeNotice text={oauthResumeNotice} />}
        {hasChallenge ? (
          <Login
            copy={loginCopy}
            mode="verification"
            email={email}
            code={code}
            disabled={busy}
            {...(error ? { errorMessage: error } : {})}
            {...(canResend ? { onResend: handleResend, resendSeconds } : {})}
            onCodeChange={handleCodeChange}
            {...(verificationRetryAvailable ? { onRetry: handleRetry } : {})}
            onUseDifferentEmail={handleUseDifferentEmail}
          />
        ) : (
          <Login
            copy={loginCopy}
            mode="email"
            email={email}
            disabled={busy}
            onEmailChange={setEmail}
            onContinueWithEmail={handleContinueWithEmail}
            googlePending={googlePending}
            {...(googleRetryAvailable && error ? { googleErrorMessage: error } : {})}
            onContinueWithGoogle={handleContinueWithGoogle}
          />
        )}

        {externalMessage && (
          <output
            aria-atomic="true"
            aria-live={externalError ? "assertive" : "polite"}
            className="app-login-message"
            role={externalError ? "alert" : "status"}
          >
            {externalMessage}
          </output>
        )}
      </div>
    </main>
  );
}

function canRetryCompletedCode(error: unknown): boolean {
  if (!(error instanceof SessionOperationDisplayError)) {
    return true;
  }
  return (
    error.code === "network_unavailable" ||
    error.code === "provider_unavailable" ||
    error.code === "unknown"
  );
}

function LegacyLoginScreen({
  authenticator,
  revocationPending = false,
  oauthResumeNotice,
}: LoginScreenProps) {
  const messages = useCommaMessages();
  const commaConfig = getActiveCommaConfig();
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [challengeId, setChallengeId] = useState("");
  const [challengePurpose, setChallengePurpose] = useState<ChallengePurpose>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [googleAttemptRevision, setGoogleAttemptRevision] = useState(0);
  const [googleState, setGoogleState] = useState<"loading" | "ready" | "unavailable">(
    "loading"
  );
  const googleButtonRef = useRef<HTMLDivElement>(null);
  const hasChallenge = Boolean(challengeId);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (hasChallenge) {
      await verifyLoginCode();
    } else {
      await requestLoginCode();
    }
  }

  async function requestLoginCode() {
    const trimmedEmail = email.trim();
    if (!trimmedEmail) {
      setError(messages.auth_enter_email());
      return;
    }

    await runAuthTask(async () => {
      const challenge = await authenticator.requestEmailLogin(trimmedEmail);
      setEmail(trimmedEmail);
      applyChallenge(challenge);
      setNotice(messages.auth_verification_code_sent());
    });
  }

  async function verifyLoginCode() {
    const trimmedCode = code.trim();
    if (!challengeId || !trimmedCode) {
      setError(messages.auth_enter_verification_code());
      return;
    }

    await runAuthTask(async () => {
      const input = { challengeId, code: trimmedCode };
      if (challengePurpose === "google_link") {
        await authenticator.verifyGoogleLink(input);
      } else {
        await authenticator.verifyEmailLogin(input);
      }
    });
  }

  useEffect(() => {
    if (hasChallenge) {
      return;
    }

    let active = true;
    let teardown: (() => void) | undefined;
    const element = googleButtonRef.current;
    if (!element) {
      return;
    }

    setGoogleState("loading");
    void authenticator
      .mountGoogleControl({
        element,
        onError(nextError) {
          if (!active) {
            return;
          }
          setError(nextError.message);
          setGoogleState("unavailable");
        },
        onResult(result) {
          if (!active || result.kind === "signed_in") {
            return;
          }
          if (result.email) {
            setEmail(result.email);
          }
          applyChallenge(result);
          setNotice(messages.auth_verification_code_sent());
        },
      })
      .then((nextTeardown) => {
        if (active) {
          teardown = nextTeardown;
          setGoogleState("ready");
        } else {
          nextTeardown();
        }
      })
      .catch(() => {
        if (active) {
          setGoogleState("unavailable");
        }
      });

    return () => {
      active = false;
      teardown?.();
      element.replaceChildren();
    };
  }, [authenticator, googleAttemptRevision, hasChallenge, messages]);

  async function runAuthTask(task: () => Promise<void>) {
    setBusy(true);
    setError("");
    setNotice("");
    try {
      await task();
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : String(nextError));
    } finally {
      setBusy(false);
    }
  }

  function applyChallenge(challenge: SessionLoginChallenge) {
    setChallengeId(challenge.challengeId);
    setChallengePurpose(challenge.purpose);
    setCode(challenge.code ?? "");
  }

  function resetChallenge() {
    void authenticator.cancelCurrentAttempt().catch((nextError: unknown) => {
      setError(nextError instanceof Error ? nextError.message : String(nextError));
    });
    setChallengeId("");
    setChallengePurpose(undefined);
    setCode("");
    setNotice("");
    setError("");
  }

  function retryGoogleSignIn() {
    setError("");
    setNotice("");
    setGoogleState("loading");
    setGoogleAttemptRevision((current) => current + 1);
  }

  return (
    <main className="app-login-shell">
      <div className="app-login-container">
        {oauthResumeNotice && <OauthResumeNotice text={oauthResumeNotice} />}
        <img
          className="app-login-logo"
          src={commaLogoUrl}
          alt={messages.auth_logo_alt({ productName: commaConfig.productName })}
        />

        <section
          className="app-login-panel"
          aria-label={messages.auth_sign_in_region()}
        >
          <Text as="h1" weight="semibold" className="app-login-title">
            {hasChallenge ? messages.auth_check_email_title() : messages.auth_title()}
          </Text>

          {hasChallenge && (
            <div className="app-login-copy-group">
              <Text size="textSm" className="app-login-copy">
                {messages.auth_code_sent_to()}
              </Text>
              <Text size="textSm" weight="medium" className="app-login-email">
                {email}
              </Text>
            </div>
          )}

          <form className="app-login-form" onSubmit={handleSubmit}>
            {!hasChallenge && (
              <>
                <div className="app-login-google-slot" data-state={googleState}>
                  <div
                    ref={googleButtonRef}
                    className="app-login-google-button"
                    data-busy={busy ? "true" : "false"}
                    data-state={googleState}
                    aria-label={messages.auth_continue_google()}
                  />
                  {googleState === "loading" && (
                    <Text
                      as="output"
                      size="textSm"
                      className="app-login-google-placeholder"
                      aria-live="polite"
                    >
                      <LoadingIndicator label={messages.auth_google_loading()} />
                    </Text>
                  )}
                  {googleState === "unavailable" && (
                    <Button
                      type="button"
                      hierarchy="secondary-gray"
                      className="app-login-secondary app-login-google-retry"
                      onPress={retryGoogleSignIn}
                      disabled={busy}
                    >
                      {messages.auth_google_retry()}
                    </Button>
                  )}
                </div>
                <div className="app-login-divider" aria-hidden="true">
                  <span>{messages.auth_or()}</span>
                </div>
              </>
            )}

            {hasChallenge ? (
              <div className="app-login-field">
                <label className="app-sr-only" htmlFor="login-code">
                  {messages.auth_verification_code_label()}
                </label>
                <input
                  id="login-code"
                  className="app-login-input app-login-code-input"
                  value={code}
                  onChange={(event) => setCode(event.target.value)}
                  placeholder={messages.auth_verification_code_placeholder()}
                  inputMode="numeric"
                  autoComplete="one-time-code"
                  maxLength={6}
                  disabled={busy}
                />
              </div>
            ) : (
              <div className="app-login-field">
                <label className="app-sr-only" htmlFor="login-email">
                  {messages.auth_email_label()}
                </label>
                <input
                  id="login-email"
                  className="app-login-input"
                  type="email"
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  placeholder={messages.auth_email_placeholder()}
                  autoComplete="email"
                  disabled={busy}
                  required
                />
              </div>
            )}

            <div className="app-login-actions">
              <Button type="submit" className="app-login-primary" disabled={busy}>
                {hasChallenge ? messages.auth_verify_code() : messages.auth_send_code()}
              </Button>
              {hasChallenge && (
                <Button
                  hierarchy="secondary-gray"
                  className="app-login-secondary"
                  onPress={resetChallenge}
                  disabled={busy}
                >
                  {messages.auth_use_different_email()}
                </Button>
              )}
            </div>
          </form>

          {(error || notice || revocationPending) && (
            <output
              aria-atomic="true"
              aria-live={error ? "assertive" : "polite"}
              className="app-login-message"
              role={error ? "alert" : "status"}
            >
              {error || notice || messages.auth_revocation_pending()}
            </output>
          )}
        </section>
      </div>
    </main>
  );
}

function OauthResumeNotice({ text }: { text: string }) {
  return <output className="app-login-oauth-notice">{text}</output>;
}
