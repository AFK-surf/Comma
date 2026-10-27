import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeWorkspace, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// The Apps gallery shows each app's cover (its first screen) on its card, and an app without one its icon glyph. A
// cover is read once: a page switch back shows it in the same frame as its card, with no second read.

const app = (id: string, name: string, cover: boolean) => ({
  id,
  slug: id.slice(-8),
  workspace_id: chatSmokeWorkspace.id,
  name,
  description: "",
  icon_url: null,
  cover_url: cover ? `/v1/comma/apps/${id}/cover?v=2` : null,
  repo: null,
  visibility: "workspace",
  status: "active",
  live_version: 2,
  latest_version: 2,
  author: { name: "Ada" },
  capabilities: [],
  egress: [],
  secrets: [],
  grants: [],
  installed: false,
  install: null,
  storage: [],
  has_backend: false,
});

// A 1 × 1 PNG.
const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64"
);

test("the Apps gallery shows covers, read once and shown at once after a page switch", async ({
  page,
}) => {
  let coverReads = 0;
  const stub = await startChatSmokeStub({
    extraRoutes: async (_req, url, res) => {
      if (url.pathname === `/v1/comma/workspaces/${chatSmokeWorkspace.id}/apps`) {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            data: [
              app("app_wheel000", "Lucky wheel", true),
              app("app_plain000", "Plain app", false),
            ],
          })
        );
        return true;
      }
      if (url.pathname === "/v1/comma/apps/app_wheel000/cover") {
        coverReads += 1;
        res.writeHead(200, { "content-type": "image/png" });
        res.end(png);
        return true;
      }
      return false;
    },
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "apps@comma.local",
      token: "comma_sess_apps",
    });
    await page.goto("/#/apps");
    const cards = page.getByTestId("apps-card");
    await expect(
      cards.filter({ hasText: "Lucky wheel" }).getByTestId("apps-card-cover")
    ).toHaveAttribute("src", /^data:image\/png;base64,/);
    await expect(
      cards.filter({ hasText: "Plain app" }).getByTestId("apps-card-cover")
    ).toHaveCount(0);

    await page.evaluate(() => {
      location.hash = "#/";
    });
    await expect(cards).toHaveCount(0);

    // The first commit that shows the cards already shows the cover.
    const coverWithCard = await page.evaluate(
      () =>
        new Promise<boolean>((resolve) => {
          const observer = new MutationObserver(() => {
            if (!document.querySelector('[data-testid="apps-card"]')) return;
            observer.disconnect();
            resolve(document.querySelector('[data-testid="apps-card-cover"]') !== null);
          });
          observer.observe(document.body, { childList: true, subtree: true });
          location.hash = "#/apps";
        })
    );
    expect(coverWithCard).toBe(true);
    expect(coverReads).toBe(1);
  } finally {
    await stub.close();
  }
});
