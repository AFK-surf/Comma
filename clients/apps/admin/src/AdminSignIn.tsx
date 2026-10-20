// The screens shown before the dashboard: sign-in (an emailed code, or Google's own button), and the session status
// screens. They show the auth state (auth.ts) and run its commands.
import { commaLogoUrl, getActiveCommaConfig } from "@comma/config";
import { messages } from "@comma/i18n";
import { Button } from "@comma/ui/components/Button";
import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";
import { Text } from "@comma/ui/components/Text";
import { useCallback, type FormEvent } from "react";
import { useAdminCommand, useAdminService } from "./adminRuntime";
import {
  AdminAuth,
  type AuthState,
  type LoginState,
  type SessionProblem,
} from "./auth";

export function AdminSessionScreen({
  state,
}: {
  state: Exclude<AuthState, { phase: "signed_in" }>;
}) {
  switch (state.phase) {
    case "initializing":
      return null;
    case "signed_out":
      return <AdminSignIn login={state.login} />;
    case "signing_out":
      return <SessionBusy text={messages.auth_signing_out()} />;
    case "invalidating":
      return <SessionBusy text={messages.auth_checking_session()} />;
    case "connecting":
      return <Connecting />;
    case "unavailable":
      return <ConnectionUnavailable />;
    case "problem":
      return <SessionProblemScreen problem={state.problem} />;
  }
}

function SessionBusy({ text }: { text: string }) {
  return (
    <main aria-busy="true" className="app-login-shell">
      <output className="app-login-title">{text}</output>
    </main>
  );
}

function Connecting() {
  return (
    <main aria-busy="true" className="app-login-shell">
      <div className="app-login-container">
        <section
          className="app-login-panel"
          aria-label={messages.auth_session_status()}
        >
          <output className="app-login-title" aria-live="polite">
            <LoadingIndicator label={messages.auth_connecting()} />
          </output>
        </section>
      </div>
    </main>
  );
}

function ConnectionUnavailable() {
  const auth = useAdminService(AdminAuth);
  const run = useAdminCommand();
  return (
    <main className="app-login-shell">
      <div className="app-login-container">
        <section
          className="app-login-panel"
          aria-label={messages.auth_session_status()}
        >
          <Text as="h1" weight="semibold" className="app-login-title">
            {messages.auth_connection_unavailable()}
          </Text>
          <div className="app-login-form">
            <p className="app-login-message">{messages.auth_connection_help()}</p>
            <Button className="app-login-primary" onPress={() => run(auth.retry)}>
              {messages.auth_try_again()}
            </Button>
          </div>
        </section>
      </div>
    </main>
  );
}

function problemMessage(problem: SessionProblem) {
  switch (problem) {
    case "session_probe_unavailable":
      return messages.auth_network_unavailable();
    case "credential_mutation_uncertain":
      return messages.auth_session_credential_mutation_uncertain();
    case "protocol_mismatch":
      return messages.auth_session_contract_mismatch();
  }
}

function SessionProblemScreen({ problem }: { problem: SessionProblem }) {
  const auth = useAdminService(AdminAuth);
  const run = useAdminCommand();
  return (
    <main className="app-login-shell">
      <div className="app-login-container">
        <section
          className="app-login-panel"
          aria-label={messages.auth_session_status()}
        >
          <Text as="h1" weight="semibold" className="app-login-title">
            {messages.auth_session_unconfirmed_title()}
          </Text>
          <div className="app-login-form">
            <output aria-live="assertive" className="app-login-message" role="alert">
              {problemMessage(problem)}
            </output>
            <div className="app-login-actions">
              <Button className="app-login-primary" onPress={() => run(auth.retry)}>
                {messages.auth_try_again()}
              </Button>
            </div>
          </div>
        </section>
      </div>
    </main>
  );
}

function AdminSignIn({ login }: { login: LoginState }) {
  const auth = useAdminService(AdminAuth);
  const run = useAdminCommand();
  const hasChallenge = login.step.kind === "code";
  const canResend = login.step.kind === "code" && login.step.purpose === "email_login";
  const retryWait =
    !hasChallenge &&
    login.retryWait &&
    login.retryWait.seconds > 0 &&
    login.retryWait.email.trim().toLowerCase() === login.email.trim().toLowerCase()
      ? login.retryWait.seconds
      : 0;
  const { busy, error, notice } = login;
  const googleSlot = useCallback(
    (element: HTMLDivElement | null) => {
      if (!element) return;
      const stop = run(auth.showGoogleButton(element));
      return () => {
        stop();
        element.replaceChildren();
      };
    },
    [auth, run]
  );

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    run(hasChallenge ? auth.verifyCode : auth.requestCode);
  };

  return (
    <main className="app-login-shell">
      <div className="app-login-container">
        <img
          className="app-login-logo"
          src={commaLogoUrl}
          alt={messages.auth_logo_alt({
            productName: getActiveCommaConfig().productName,
          })}
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
                {login.email}
              </Text>
            </div>
          )}

          <form className="app-login-form" onSubmit={submit}>
            {!hasChallenge && (
              <>
                <div className="app-login-google-slot" data-state={login.google}>
                  <div
                    ref={googleSlot}
                    className="app-login-google-button"
                    data-busy={busy ? "true" : "false"}
                    data-state={login.google}
                    aria-label={messages.auth_continue_google()}
                  />
                  {login.google === "loading" && (
                    <Text
                      as="output"
                      size="textSm"
                      className="app-login-google-placeholder"
                      aria-live="polite"
                    >
                      <LoadingIndicator label={messages.auth_google_loading()} />
                    </Text>
                  )}
                  {login.google === "unavailable" && (
                    <Button
                      type="button"
                      hierarchy="secondary-gray"
                      className="app-login-secondary app-login-google-retry"
                      onPress={() => run(auth.retryGoogle)}
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
                  value={login.code}
                  onChange={(event) => run(auth.setCode(event.target.value))}
                  placeholder={messages.auth_verification_code_placeholder()}
                  inputMode="numeric"
                  autoComplete="one-time-code"
                  maxLength={6}
                  disabled={busy}
                />
                {canResend ? (
                  <p className="app-login-message">
                    {messages.auth_code_not_received()}{" "}
                    {login.resendSeconds > 0 ? (
                      <span>
                        {messages.auth_resend_countdown({
                          seconds: login.resendSeconds,
                        })}
                      </span>
                    ) : (
                      <Button
                        hierarchy="link-gray"
                        size="sm"
                        onPress={() => run(auth.resendCode)}
                        disabled={busy}
                      >
                        {messages.auth_resend()}
                      </Button>
                    )}
                  </p>
                ) : null}
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
                  value={login.email}
                  onChange={(event) => run(auth.setEmail(event.target.value))}
                  placeholder={messages.auth_email_placeholder()}
                  autoComplete="email"
                  disabled={busy}
                  required
                />
              </div>
            )}

            <div className="app-login-actions">
              <Button
                type="submit"
                className="app-login-primary"
                disabled={busy || retryWait > 0}
              >
                {hasChallenge
                  ? messages.auth_verify_code()
                  : retryWait > 0
                    ? messages.auth_retry_countdown({ seconds: retryWait })
                    : messages.auth_send_code()}
              </Button>
              {hasChallenge && (
                <Button
                  hierarchy="secondary-gray"
                  className="app-login-secondary"
                  onPress={() => run(auth.useDifferentEmail)}
                  disabled={busy}
                >
                  {messages.auth_use_different_email()}
                </Button>
              )}
            </div>
          </form>

          {(error || notice) && (
            <output
              aria-atomic="true"
              aria-live={error ? "assertive" : "polite"}
              className="app-login-message"
              role={error ? "alert" : "status"}
            >
              {error || notice}
            </output>
          )}
        </section>
      </div>
    </main>
  );
}
