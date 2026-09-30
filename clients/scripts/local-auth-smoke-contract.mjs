export const SESSION_LIFECYCLE_VERSION = "1";

export function cookieSessionHeaders(expectedSessionId, additionalHeaders = {}) {
  if (typeof expectedSessionId !== "string" || expectedSessionId.length === 0) {
    throw new Error("Cookie Session expectation must not be empty.");
  }
  return {
    ...additionalHeaders,
    "x-comma-expected-auth-session-id": expectedSessionId,
    "x-comma-session-lifecycle-version": SESSION_LIFECYCLE_VERSION,
    "x-comma-session-transport": "cookie",
  };
}

export function bearerSessionHeaders(additionalHeaders = {}) {
  return {
    ...additionalHeaders,
    "x-comma-session-transport": "bearer",
  };
}
