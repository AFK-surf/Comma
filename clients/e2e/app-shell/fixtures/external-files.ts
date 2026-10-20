// Files of hosts outside the run that the app shows (a provider's logo): the
// test server answers them as the host would (vitest.config.ts,
// servedExternalFiles), through CDP before any network, and a test page's
// request for one is the run's own (./../support/page.ts). Any other host
// outside the run fails (vite/app-shell-origin.ts).
export const externalFiles: Record<string, { contentType: string; body: string }> = {
  "https://assets.comma.test/custom-crm.svg": {
    contentType: "image/svg+xml",
    body: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="#5f6ad3"/></svg>',
  },
};
