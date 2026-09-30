import { expect, test, type Page } from "@playwright/test";
import {
  createE2eSessionProjection,
  reflectedCorsRequestHeaders,
} from "../helpers/session-fixture";
import { installBrowserTestSession } from "../helpers/browser-auth";

/**
 * OAuth IdP logged-out round trip (docs/identity-security.md, PR 7).
 *
 * Covers the review blocker on #1052: between the moment the session
 * becomes signed-in and the top-level navigation back to
 * /oauth2/authorize?resume={handle}, the client must not mount the
 * product tree or fire any product API call — POST /v1/comma/me/bootstrap
 * provisions a default Workspace, so a single stray render is a
 * server-side mutation, not just wasted work.
 */

const apiBaseUrl = "http://127.0.0.1:65535";
const handle = "7b1f4c3a-9d2e-4f5b-8a6c-1e2d3f4a5b6c";
const email = "oauth-e2e@comma.local";
const otpCode = "424242";
const sessionToken = "oauth-e2e-session-token";

const productCallPattern =
  /\/v1\/(workspaces|me\/bootstrap|me\/profile|conversations|billing)/;

function corsHeaders(origin: string | undefined, requested: string | undefined) {
  const headers: Record<string, string> = {
    "access-control-allow-credentials": "true",
    "access-control-allow-headers": reflectedCorsRequestHeaders(
      requested,
      "authorization,content-type,x-comma-session-transport"
    ),
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "cache-control": "no-store",
    "content-type": "application/json",
    vary: "origin",
  };
  if (origin) {
    headers["access-control-allow-origin"] = origin;
  }
  return headers;
}

type HarnessState = {
  productCalls: string[];
  resumeRequests: Array<{ url: string; cookie: string | undefined }>;
};

/**
 * Routes the full auth surface of the fake API origin. Product routes
 * are recorded instead of served: the assertion of this spec is that
 * the recorder stays empty until the resume navigation fires.
 */
async function installOauthHarness(page: Page): Promise<HarnessState> {
  const state: HarnessState = { productCalls: [], resumeRequests: [] };
  const projection = createE2eSessionProjection({ email });

  await page.addInitScript((baseUrl) => {
    localStorage.setItem("comma.apiBaseUrl", baseUrl);
  }, apiBaseUrl);

  await page.route(`${apiBaseUrl}/**`, async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const origin = request.headers().origin;
    const headers = corsHeaders(
      origin,
      request.headers()["access-control-request-headers"]
    );

    if (request.method() === "OPTIONS") {
      await route.fulfill({ status: 204, headers });
      return;
    }

    if (productCallPattern.test(url.pathname)) {
      state.productCalls.push(`${request.method()} ${url.pathname}`);
      await route.fulfill({ status: 500, headers, body: '{"error":"never"}' });
      return;
    }

    if (url.pathname === "/oauth2/authorize") {
      state.resumeRequests.push({
        url: request.url(),
        cookie: request.headers().cookie,
      });
      await route.fulfill({
        status: 200,
        headers: { "content-type": "text/html; charset=utf-8" },
        body: "<title>consent</title><h1 data-testid='resume-landing'>Consent page</h1>",
      });
      return;
    }

    if (url.pathname === "/v1/comma/auth/email/login" && request.method() === "POST") {
      await route.fulfill({
        status: 200,
        headers,
        body: JSON.stringify({ challenge_id: "oauth-e2e-challenge" }),
      });
      return;
    }

    if (url.pathname === "/v1/comma/auth/email/verify" && request.method() === "POST") {
      await route.fulfill({
        status: 200,
        headers: {
          ...headers,
          "set-cookie": `comma_session=${sessionToken}; Path=/; HttpOnly; SameSite=Lax`,
        },
        body: JSON.stringify(projection),
      });
      return;
    }

    if (url.pathname === "/v1/comma/auth/session" && request.method() === "GET") {
      const authed = request.headers().cookie?.includes("comma_session=") ?? false;
      await route.fulfill({
        status: authed ? 200 : 401,
        headers,
        body: authed ? JSON.stringify(projection) : '{"error":"unauthorized"}',
      });
      return;
    }

    await route.fulfill({ status: 404, headers, body: '{"error":"not_found"}' });
  });

  return state;
}

test.use({ locale: "en-US" });

test("logged-out OAuth round trip: login resumes to authorize without product calls", async ({
  page,
}) => {
  const state = await installOauthHarness(page);

  await page.goto(`/login?oauth_handle=${handle}`);

  // The generic notice pill is up and the handle has left the URL for
  // sessionStorage before the user types anything.
  await expect(
    page.getByText("Signing in will take you back to the app you came from.")
  ).toBeVisible();
  await expect(page).not.toHaveURL(/oauth_handle/);
  await expect
    .poll(() =>
      page.evaluate(() => sessionStorage.getItem("comma.oauth_resume_handle"))
    )
    .toBe(handle);

  // Real login boundary: email OTP through the actual login screen.
  await page.getByLabel("Email").fill(email);
  await page.getByRole("button", { name: "Send code" }).click();
  await page.getByLabel("Verification code").fill(otpCode);
  await page.getByRole("button", { name: "Verify code" }).click();

  // The browser must land on the resume URL of the API origin.
  await page.waitForURL(`${apiBaseUrl}/oauth2/authorize?resume=${handle}`);
  await expect(page.getByTestId("resume-landing")).toBeVisible();

  // The session cookie set by the verify response rode along on the
  // top-level resume navigation (Lax + host-only on the API origin).
  expect(state.resumeRequests).toHaveLength(1);
  expect(state.resumeRequests[0]?.cookie).toContain(`comma_session=${sessionToken}`);

  // Single use: the handle did not survive the handoff.
  await expect
    .poll(() =>
      page.evaluate(() => sessionStorage.getItem("comma.oauth_resume_handle"))
    )
    .toBeNull();

  // The heart of the review blocker: zero product API calls between
  // signing in and the resume navigation.
  expect(state.productCalls).toEqual([]);
});

test("already-signed-in visit with a handle resumes without product calls", async ({
  page,
}) => {
  const state = await installOauthHarness(page);
  await installBrowserTestSession(page, { apiBaseUrl, email, token: sessionToken });

  await page.goto(`/login?oauth_handle=${handle}`);

  await page.waitForURL(`${apiBaseUrl}/oauth2/authorize?resume=${handle}`);
  expect(state.resumeRequests).toHaveLength(1);
  expect(state.productCalls).toEqual([]);
});

test("a malformed handle is dropped and never navigates", async ({ page }) => {
  const state = await installOauthHarness(page);

  await page.goto("/login?oauth_handle=javascript:alert(1)");

  await expect(page).not.toHaveURL(/oauth_handle/);
  await expect(
    page.evaluate(() => sessionStorage.getItem("comma.oauth_resume_handle"))
  ).resolves.toBeNull();
  await expect(
    page.getByText("Signing in will take you back to the app you came from.")
  ).toHaveCount(0);
  expect(state.resumeRequests).toEqual([]);
});
