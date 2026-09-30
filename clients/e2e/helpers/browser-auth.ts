import type { Page } from "@playwright/test";
import {
  createE2eSessionProjection,
  reflectedCorsRequestHeaders,
  registerBrowserSessionFixture,
} from "./session-fixture";

export type BrowserTestSession = {
  apiBaseUrl: string;
  email: string;
  sessionId?: string;
  token: string;
  userId?: string;
};

/**
 * Models the browser auth boundary without exposing a bearer token to page JS:
 * Playwright installs an HttpOnly cookie, while the mocked session endpoint
 * returns only the public user/session projection.
 */
export async function installBrowserTestSession(
  page: Page,
  session: BrowserTestSession
) {
  const apiBaseUrl = session.apiBaseUrl.replace(/\/+$/, "");
  const projection = createE2eSessionProjection(session);
  registerBrowserSessionFixture(apiBaseUrl, session.token, projection);

  await page.addInitScript((baseUrl) => {
    localStorage.setItem("comma.apiBaseUrl", baseUrl);
    localStorage.removeItem("comma.sessionToken");
    localStorage.removeItem("comma.userEmail");
    localStorage.removeItem("comma.userAdmin");
  }, apiBaseUrl);

  await page.context().addCookies([
    {
      httpOnly: true,
      name: "comma_session",
      sameSite: "Lax",
      secure: false,
      url: apiBaseUrl,
      value: session.token,
    },
  ]);

  await page.route(`${apiBaseUrl}/v1/comma/auth/session`, async (route) => {
    const request = route.request();
    const origin = request.headers().origin;
    const headers: Record<string, string> = {
      "access-control-allow-credentials": "true",
      "access-control-allow-headers": reflectedCorsRequestHeaders(
        request.headers()["access-control-request-headers"],
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

    if (request.method() === "OPTIONS") {
      await route.fulfill({ body: "", headers, status: 204 });
      return;
    }

    await route.fulfill({
      body: JSON.stringify(projection),
      headers,
      status: 200,
    });
  });
}
