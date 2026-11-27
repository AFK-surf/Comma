import { useCommaMessages } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";
import { Button } from "@comma/ui/components/Button";
import { InputField } from "@comma/ui/components/input";
import { Login, type LoginCopy } from "@comma/ui/components/login";
import { useEffect, useState } from "react";
import {
  CollabGuestError,
  type CollabGuestClient,
  type CollabGuestInvite,
  type CollabGuestVerifyResult,
} from "./collabGuestApi";

/** Where "Use full Comma" goes: the app's own sign-in, which claims this seat once the invited email signs in. */
export const FULL_COMMA_HREF = "/?from=collab_guest";

/** A page the link cannot open the Task from: what happened, in the app's quiet failure style, as a shared Task's. */
export function CollabGuestStatusScreen({
  kind,
  onRetry,
}: {
  kind: "expired" | "not_found" | "revoked" | "unavailable";
  onRetry?: (() => void) | undefined;
}) {
  const messages = useCommaMessages();

  const title =
    kind === "expired"
      ? messages.collab_guest_expired_title()
      : kind === "not_found"
        ? messages.collab_guest_not_found_title()
        : kind === "revoked"
          ? messages.collab_guest_revoked_title()
          : messages.collab_guest_unavailable_title();

  const body =
    kind === "expired"
      ? messages.collab_guest_expired_body()
      : kind === "not_found"
        ? messages.collab_guest_not_found_body()
        : kind === "revoked"
          ? messages.collab_guest_revoked_body()
          : messages.collab_guest_unavailable_body();

  return (
    <section
      className="flex flex-1 flex-col items-center justify-center gap-md p-xl text-center"
      data-testid={`collab-guest-status-${kind}`}
    >
      <h1 className="text-md font-semibold text-primary">{title}</h1>
      <p className="max-w-(--container-xs) text-sm text-tertiary">{body}</p>
      {kind === "unavailable" && onRetry ? (
        <Button hierarchy="secondary-gray" onPress={onRetry} size="sm">
          {messages.collab_guest_retry()}
        </Button>
      ) : (
        <Button
          hierarchy="secondary-gray"
          onPress={() => window.location.assign(FULL_COMMA_HREF)}
          size="sm"
        >
          {messages.collab_guest_use_full_comma()}
        </Button>
      )}
    </section>
  );
}

/**
 * The invite's sign-in: the app's own login (the email, then its six-digit code), naming who invited the guest to
 * which Task, with the name they will go by asked once beside the email.
 */
export function CollabGuestOtpGate({
  client,
  invite,
  onVerified,
  onExpired,
}: {
  client: CollabGuestClient;
  invite: CollabGuestInvite;
  onVerified: (result: CollabGuestVerifyResult) => void;
  onExpired: () => void;
}) {
  const messages = useCommaMessages();
  const [step, setStep] = useState<"email" | "code">("email");
  const [email, setEmail] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [code, setCode] = useState("");
  const [challengeId, setChallengeId] = useState<string | null>(null);
  const [resendSeconds, setResendSeconds] = useState(0);
  const [submitting, setSubmitting] = useState(false);
  const [errorText, setErrorText] = useState<string | null>(null);

  useEffect(() => {
    if (resendSeconds <= 0) return;
    return uiClock.after(1000, () => {
      setResendSeconds((s) => (s > 0 ? s - 1 : 0));
    });
  }, [resendSeconds]);

  const mapOtpError = (error: unknown): string => {
    if (error instanceof CollabGuestError) {
      if (error.code === "invite_expired") {
        onExpired();
        return messages.collab_guest_expired_body();
      }
      if (error.code === "email_mismatch") {
        return messages.collab_guest_otp_error_email_mismatch();
      }
      if (error.code === "rate_limited") {
        return messages.collab_guest_otp_error_rate_limited({
          seconds: String(error.retryAfterSeconds ?? 60),
        });
      }
      if (error.code === "invalid_code") {
        return messages.collab_guest_otp_error_invalid_code();
      }
      if (error.code === "challenge_expired") {
        return messages.collab_guest_otp_error_challenge_expired();
      }
    }
    return messages.collab_guest_otp_error_generic();
  };

  const requestOtp = async (address: string) => {
    if (submitting) return;
    setSubmitting(true);
    setErrorText(null);
    try {
      const challenge = await client.requestOtp(address.trim() || undefined);
      setChallengeId(challenge.challenge_id);
      setResendSeconds(Math.max(0, Math.round(challenge.resend_after_seconds)));
      setCode("");
      setStep("code");
    } catch (error) {
      setErrorText(mapOtpError(error));
    } finally {
      setSubmitting(false);
    }
  };

  const verifyOtp = async (nextCode: string) => {
    if (submitting || !challengeId) return;
    setSubmitting(true);
    setErrorText(null);
    try {
      const trimmedName = displayName.trim();
      const verified = await client.verifyOtp({
        challengeId,
        code: nextCode,
        ...(trimmedName ? { name: trimmedName } : {}),
      });
      onVerified(verified);
    } catch (error) {
      setErrorText(mapOtpError(error));
    } finally {
      setSubmitting(false);
    }
  };

  const copy: LoginCopy = {
    regionLabel: messages.collab_guest_otp_title(),
    email: {
      title: messages.collab_guest_invited_title({ host: invite.host_name }),
      subtitle: invite.title,
      googleAction: messages.auth_sign_in_google(),
      appleAction: messages.auth_sign_in_apple(),
      label: messages.collab_guest_otp_email_label(),
      placeholder: invite.email_hint || messages.collab_guest_otp_email_placeholder(),
      continueAction: submitting
        ? messages.collab_guest_otp_sending()
        : messages.collab_guest_otp_send_code(),
      invalidError: messages.auth_email_invalid(),
    },
    verification: {
      title: messages.auth_check_email_title(),
      instruction: (address) => messages.auth_enter_code_sent_to({ email: address }),
      codeLabel: messages.auth_verification_code_label(),
      codeNotReceived: messages.auth_code_not_received(),
      resendAction: messages.auth_resend(),
      resendCountdown: (seconds) => messages.auth_resend_countdown({ seconds }),
      retryAction: messages.auth_try_again(),
      differentEmailAction: messages.auth_use_different_email(),
    },
  };

  return (
    <main className="app-login-shell" data-testid="collab-guest-otp-gate">
      <div className="app-login-stage">
        {step === "email" ? (
          <Login
            continueDisabled={submitting}
            copy={copy}
            email={email}
            {...(errorText ? { errorMessage: errorText } : {})}
            fields={
              <InputField
                autoComplete="name"
                className="w-full"
                label={messages.collab_guest_otp_name_label()}
                maxLength={80}
                onChange={(event) => setDisplayName(event.target.value)}
                placeholder={messages.collab_guest_otp_name_placeholder()}
                suppressFocusRing
                value={displayName}
              />
            }
            mode="email"
            onContinueWithEmail={(address) => void requestOtp(address)}
            onEmailChange={(next) => {
              setEmail(next);
              setErrorText(null);
            }}
            secondaryAction={{
              label: messages.collab_guest_use_full_comma(),
              onPress: () => window.location.assign(FULL_COMMA_HREF),
            }}
          />
        ) : (
          <Login
            code={code}
            copy={copy}
            disabled={submitting}
            email={email.trim() || invite.email_hint}
            {...(errorText ? { errorMessage: errorText } : {})}
            mode="verification"
            onCodeChange={(next) => {
              setCode(next);
              if (errorText) setErrorText(null);
            }}
            onCodeComplete={(next) => void verifyOtp(next)}
            onResend={() => void requestOtp(email)}
            onUseDifferentEmail={() => {
              setStep("email");
              setErrorText(null);
            }}
            resendSeconds={resendSeconds}
          />
        )}
      </div>
    </main>
  );
}
