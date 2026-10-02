import type { Page } from "@playwright/test";

export const user = { id: "user-1", name: "Mei Chen", email: "mei@acme.test" };
export const orgs = [{ slug: "acme", name: "Acme Robotics" }];

export const context = {
  user,
  orgs,
  org: { slug: "acme", name: "Acme Robotics", role: "owner" },
  capabilities: {
    operations: true,
    triage: true,
    information_flow: true,
    meetings: true,
    settings: true,
  },
  projects: [{ id: "p-1", name: "Support Desk" }],
};

export const ok = (data: unknown) => ({ status: 200, body: { ok: true, data } });

/** Answers `/dashboard/api/v1/<path>` from `routes`; anything else is a 404. */
export async function stubApi(
  page: Page,
  routes: Record<string, { status: number; body: unknown }>
) {
  await page.route("**/dashboard/api/v1/**", async (route) => {
    const path = new URL(route.request().url()).pathname.replace(
      "/dashboard/api/v1",
      ""
    );
    const reply = routes[path] ?? {
      status: 404,
      body: { ok: false, error: { code: "not_found" } },
    };
    await route.fulfill({ status: reply.status, json: reply.body });
  });
}

export const csrf = "e2e-csrf-token";

/** Phoenix writes the CSRF token into the served page; the dev server does not. */
export async function injectCsrfToken(page: Page, token = csrf) {
  await page.addInitScript((value) => {
    document.addEventListener("DOMContentLoaded", () => {
      const meta = document.createElement("meta");
      meta.name = "csrf-token";
      meta.content = value;
      document.head.appendChild(meta);
    });
  }, token);
}

export interface RecordedRequest {
  method: string;
  path: string;
  search: string;
  csrf: string | undefined;
  body: unknown;
}

type Reply = { status: number; body: unknown } | { status: number; text: string };

/**
 * Answers `/dashboard/api/v1/**` from `handle` (undefined means 404) and
 * records every request with its CSRF header and JSON body.
 */
export async function routeApi(
  page: Page,
  handle: (request: RecordedRequest) => Reply | undefined
) {
  const requests: RecordedRequest[] = [];
  await page.route("**/dashboard/api/v1/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const raw = request.postData();
    const recorded: RecordedRequest = {
      method: request.method(),
      path: url.pathname.replace("/dashboard/api/v1", ""),
      search: url.search,
      csrf: (await request.allHeaders())["x-csrf-token"],
      body: raw ? (JSON.parse(raw) as unknown) : undefined,
    };
    requests.push(recorded);
    const reply = handle(recorded) ?? {
      status: 404,
      body: { ok: false, error: { code: "not_found", message: "Not found" } },
    };
    if ("text" in reply)
      await route.fulfill({ status: reply.status, body: reply.text });
    else await route.fulfill({ status: reply.status, json: reply.body });
  });
  return requests;
}

/** Writes a redirect's flash into the served page, as `SPAController` does. */
export async function injectFlash(page: Page, kind: "info" | "error", text: string) {
  await page.route("**/*", async (route) => {
    if (route.request().resourceType() !== "document") return route.fallback();
    const response = await route.fetch();
    const meta = `<meta name="bft-flash" data-kind="${kind}" content="${text}" />`;
    await route.fulfill({
      response,
      body: (await response.text()).replace("</head>", `${meta}</head>`),
    });
  });
}
