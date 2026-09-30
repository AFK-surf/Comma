export const SESSION_LIFECYCLE_VERSION: "1";

export function cookieSessionHeaders(
  expectedSessionId: string,
  additionalHeaders?: Record<string, string>
): Record<string, string>;

export function bearerSessionHeaders(
  additionalHeaders?: Record<string, string>
): Record<string, string>;
