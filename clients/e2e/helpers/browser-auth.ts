import { expect, type Page } from "@playwright/test";
import { defaultCommaClientSettings } from "@comma/native-bridge";
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
  /**
   * Every signed-in account meets the first-launch intro card until this
   * device records it as seen. Sessions start with it recorded, so a spec
   * lands on the shell; intro specs pass `false` to meet it.
   */
  onboardingCompleted?: boolean;
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
  if (session.onboardingCompleted !== false) {
    await recordOnboardingCompleted(page, [projection.user.id]);
  }

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

  // The app language is an account setting on the profile. A test backend
  // that serves the profile still answers; one that cannot (or rejects the
  // language write) is backed by this page's account, which survives reloads.
  let accountLocale: string | null = null;
  let lastProfile: Record<string, unknown> = {
    avatar_id: null,
    email: session.email,
    id: projection.user.id,
    name: null,
  };
  await page.route(`${apiBaseUrl}/v1/comma/me/profile`, async (route) => {
    const request = route.request();
    const origin = request.headers().origin;
    const headers: Record<string, string> = {
      "access-control-allow-credentials": "true",
      "access-control-allow-headers": reflectedCorsRequestHeaders(
        request.headers()["access-control-request-headers"],
        "authorization,content-type,x-comma-session-transport"
      ),
      "access-control-allow-methods": "GET,PATCH,OPTIONS",
      "cache-control": "no-store",
      "content-type": "application/json",
      vary: "origin",
      ...(origin ? { "access-control-allow-origin": origin } : {}),
    };
    if (request.method() === "OPTIONS") {
      await route.fulfill({ body: "", headers, status: 204 });
      return;
    }
    if (request.method() === "PATCH") {
      const patch = (request.postDataJSON() ?? {}) as { locale?: string };
      if (patch.locale) accountLocale = patch.locale;
    }
    try {
      const upstream = await route.fetch();
      if (upstream.ok())
        lastProfile = (await upstream.json()) as Record<string, unknown>;
    } catch {
      // No test backend at this address; the page's account answers.
    }
    await route.fulfill({
      body: JSON.stringify({
        ...lastProfile,
        ...(accountLocale ? { locale: accountLocale } : {}),
      }),
      headers,
      status: 200,
    });
  });
}

/**
 * Records the first-launch introduction as seen on this device for the given
 * user ids, as the app does when a user finishes it. Merged into whatever a
 * spec or an earlier load stored, so reloads keep later user changes.
 */
export async function recordOnboardingCompleted(
  page: Page,
  userIds: readonly string[]
) {
  await page.addInitScript(
    ({ defaults, ids }) => {
      const key = "comma.client-settings";
      const stored = localStorage.getItem(key);
      const settings = stored ? JSON.parse(stored) : defaults;
      const completed: string[] = settings.onboardingCompletedUserIds ?? [];
      const missing = ids.filter((id) => !completed.includes(id));
      if (missing.length === 0) return;
      localStorage.setItem(
        key,
        JSON.stringify({
          ...settings,
          onboardingCompletedUserIds: [...completed, ...missing],
        })
      );
    },
    { defaults: defaultCommaClientSettings, ids: [...userIds] }
  );
}

/**
 * Closes the web's first-launch intro card the way a user does. For specs
 * that start from legacy renderer stores: recording it up front would write
 * the client settings those stores are migrated into.
 */
export async function dismissWebIntro(page: Page) {
  const card = page.getByRole("complementary", { name: "Comma on the web" });
  await card.getByRole("button", { name: "Close" }).click();
  await expect(card).toHaveCount(0);
}
