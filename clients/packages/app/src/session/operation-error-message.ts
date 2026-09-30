import { baseLocale, messages, type CommaLocale } from "@comma/i18n";

export class SessionOperationDisplayError extends Error {
  constructor(
    readonly code: string,
    message: string
  ) {
    super(message);
    this.name = "SessionOperationDisplayError";
  }
}

export function sessionOperationDisplayError(
  code: string,
  unsupportedMessage: string,
  locale: CommaLocale = baseLocale
): SessionOperationDisplayError {
  let message: string;
  switch (code) {
    case "invalid_challenge":
      message = messages.auth_verification_code_invalid({}, { locale });
      break;
    case "challenge_expired":
      message = messages.auth_verification_code_expired({}, { locale });
      break;
    case "rate_limited":
      message = messages.auth_rate_limited({}, { locale });
      break;
    case "network_unavailable":
      message = messages.auth_network_unavailable({}, { locale });
      break;
    case "provider_unavailable":
      message = messages.auth_temporarily_unavailable({}, { locale });
      break;
    case "conflict":
      message = messages.auth_attempt_stale({}, { locale });
      break;
    case "unsupported":
      message = unsupportedMessage;
      break;
    default:
      message = messages.auth_sign_in_failed({}, { locale });
  }
  return new SessionOperationDisplayError(code, message);
}
