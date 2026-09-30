import { baseLocale, messages, type CommaLocale } from "@comma/i18n";
import {
  renderGoogleSignInButton,
  type GoogleCredentialResponse,
} from "../../auth/googleIdentityServices";
import {
  WebCookieSessionAdapter,
  type WebGoogleSignInValue,
} from "./web-cookie-session-adapter";
import type {
  SessionAuthenticatorController,
  SessionLoginChallenge,
} from "../controller";
import { sessionOperationDisplayError } from "../operation-error-message";

type ActiveAttempt = {
  attempt: Parameters<WebCookieSessionAdapter["cancelAuthAttempt"]>[0]["attempt"];
  purpose: "email_login" | "google_link";
};

export class WebCookieLoginController implements SessionAuthenticatorController {
  private activeAttempt: ActiveAttempt | undefined;

  constructor(
    private readonly adapter: WebCookieSessionAdapter,
    private readonly locale: CommaLocale = baseLocale
  ) {}

  async requestEmailLogin(email: string): Promise<SessionLoginChallenge> {
    if (this.activeAttempt?.purpose === "google_link") {
      await this.cancelCurrentAttempt();
    }
    const expected = this.currentAbsenceExpectation();
    const result = await this.adapter.requestEmailLogin({ email, expected });
    if (!result.ok) {
      throw operationError(result.error.code, this.locale);
    }

    this.activeAttempt = {
      attempt: result.value.attempt,
      purpose: "email_login",
    };
    return {
      challengeId: result.value.challengeId,
      ...(result.value.code ? { code: result.value.code } : {}),
      kind: "challenge",
      purpose: "email_login",
    };
  }

  async verifyEmailLogin(input: { challengeId: string; code: string }) {
    const active = this.requireAttempt("email_login");
    const result = await this.adapter.verifyEmailLogin({
      attempt: active.attempt,
      challengeId: input.challengeId,
      code: input.code,
    });
    if (!result.ok) {
      throw operationError(result.error.code, this.locale);
    }
    this.activeAttempt = undefined;
  }

  async verifyGoogleLink(input: { challengeId: string; code: string }) {
    const active = this.requireAttempt("google_link");
    const result = await this.adapter.verifyGoogleLink({
      attempt: active.attempt,
      challengeId: input.challengeId,
      code: input.code,
    });
    if (!result.ok) {
      throw operationError(result.error.code, this.locale);
    }
    this.activeAttempt = undefined;
  }

  async cancelCurrentAttempt() {
    const active = this.activeAttempt;
    if (!active) {
      return;
    }
    const result = await this.adapter.cancelAuthAttempt({
      attempt: active.attempt,
    });
    if (!result.ok && result.error.code !== "conflict") {
      throw operationError(result.error.code, this.locale);
    }
    this.activeAttempt = undefined;
  }

  async mountGoogleControl(input: {
    element: HTMLElement;
    onError(error: Error): void;
    onResult(result: { kind: "signed_in" } | SessionLoginChallenge): void;
  }) {
    if (this.activeAttempt?.purpose === "google_link") {
      await this.cancelCurrentAttempt();
    }

    let active = true;
    const expected = this.currentAbsenceExpectation();
    const preparation = await this.adapter.beginGoogleLogin({ expected });
    if (!preparation.ok) {
      throw operationError(preparation.error.code, this.locale);
    }

    this.activeAttempt = {
      attempt: preparation.value.attempt,
      purpose: "google_link",
    };

    try {
      await renderGoogleSignInButton({
        clientId: preparation.value.clientId,
        element: input.element,
        nonce: preparation.value.nonce,
        onCredential: (response) => {
          if (active) {
            void this.completeGoogleCredential(preparation.value, response, input);
          }
        },
      });
    } catch (error) {
      await this.cancelCurrentAttempt();
      throw error;
    }

    return () => {
      active = false;
    };
  }

  private async completeGoogleCredential(
    preparation: Extract<
      Awaited<ReturnType<WebCookieSessionAdapter["beginGoogleLogin"]>>,
      { ok: true }
    >["value"],
    response: GoogleCredentialResponse,
    callbacks: {
      onError(error: Error): void;
      onResult(result: { kind: "signed_in" } | SessionLoginChallenge): void;
    }
  ) {
    const credential = response.credential?.trim();
    if (!credential) {
      callbacks.onError(
        new Error(messages.auth_google_missing_credential({}, { locale: this.locale }))
      );
      return;
    }

    const result = await this.adapter.completeGoogleLogin({
      attempt: preparation.attempt,
      credential,
      nonce: preparation.nonce,
      providerAttemptId: preparation.providerAttemptId,
    });
    if (!result.ok) {
      callbacks.onError(operationError(result.error.code, this.locale));
      return;
    }

    this.handleGoogleResult(preparation.attempt, result.value, callbacks);
  }

  private handleGoogleResult(
    attempt: ActiveAttempt["attempt"],
    value: WebGoogleSignInValue,
    callbacks: {
      onResult(result: { kind: "signed_in" } | SessionLoginChallenge): void;
    }
  ) {
    if (value.status === "signed_in") {
      this.activeAttempt = undefined;
      callbacks.onResult({ kind: "signed_in" });
      return;
    }

    this.activeAttempt = {
      attempt,
      purpose: "google_link",
    };
    callbacks.onResult({
      challengeId: value.challengeId,
      ...(value.code ? { code: value.code } : {}),
      email: value.email,
      kind: "challenge",
      purpose: "google_link",
    });
  }

  private currentAbsenceExpectation() {
    const snapshot = this.adapter.getSnapshotSync();
    if (snapshot.phase !== "signed_out") {
      throw new Error(messages.auth_attempt_stale({}, { locale: this.locale }));
    }
    return {
      authorityInstanceId: snapshot.authority.authorityInstanceId,
      expectedSessionId: null,
      generation: snapshot.generation,
    };
  }

  private requireAttempt(purpose: ActiveAttempt["purpose"]) {
    const active = this.activeAttempt;
    if (!active || active.purpose !== purpose) {
      throw new Error(messages.auth_attempt_stale({}, { locale: this.locale }));
    }
    return active;
  }
}

function operationError(code: string, locale: CommaLocale) {
  return sessionOperationDisplayError(
    code,
    messages.auth_browser_unsupported({}, { locale }),
    locale
  );
}
