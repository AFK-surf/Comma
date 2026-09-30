export const webBaseURL =
  process.env.COMMA_PLAYWRIGHT_WEB_BASE_URL?.replace(/\/$/, "") ??
  "http://127.0.0.1:4173";
