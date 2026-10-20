import { expect, test, type Page } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const base = "/orgs/acme/projects/p-1/agents";
const api = "/orgs/acme/projects/p-1/agents";
const project = { id: "p-1", name: "Support Desk", role: "admin" };

const row = (id: string, name: string | null, extra = {}) => ({
  id,
  name,
  role: "router",
  lifecycle: "active",
  ...extra,
});

const router = row("a-router", "Front desk");
// A Worker made before Workers were retired; the list leaves it out.
const billing = row("a-billing", "Billing specialist", { role: "worker" });

const page1 = (role = "admin") => ({
  project: { ...project, role },
  status: "ok",
  agents: [router],
  next_cursor: null,
  triage_href: "/orgs/acme/triage",
});

type Row = ReturnType<typeof row>;

const detail = (agent: Row, extra: Record<string, unknown> = {}, role = "admin") => ({
  project: { ...project, role },
  agent: {
    ...agent,
    created_at: "2026-09-20T08:00:00Z",
    runtime_id: `agt1_${agent.id}`,
    model: agent.role === "router" ? "claude-sonnet-4-5" : null,
    system_prompt: agent.role === "router" ? "Answer politely." : null,
    read_only: agent.role !== "router",
  },
  router_session: agent.role === "router" ? { status: "ok", id: "ses1_current" } : null,
  triage_href: agent.role === "router" ? "/orgs/acme/triage" : null,
  ...extra,
});

const failure = (status: number, code: string, message: string, fields = {}) => ({
  status,
  body: { ok: false, error: { code, message, details: { fields } } },
});

type Handler = (
  request: RecordedRequest
) => { status: number; body: unknown } | undefined;

async function open(page: Page, path: string, handle: Handler) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) =>
    request.path === "/orgs/acme/context" ? ok(context) : handle(request)
  );
  await page.goto(path);
  return requests;
}

/** The list and each agent's detail; `extra` answers anything else first. */
const standard =
  (extra: Handler = () => undefined, role = "admin"): Handler =>
  (request) => {
    const answer = extra(request);
    if (answer) return answer;
    if (request.method !== "GET") return undefined;
    if (request.path === api) return ok(page1(role));
    const id = request.path.slice(api.length + 1);
    const agent = [router, billing].find((candidate) => candidate.id === id);
    if (agent) return ok(detail(agent, {}, role));
    return undefined;
  };

const writes = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.method !== "GET");

test("lists the Router, says where Tasks run and opens the Router in the rail", async ({
  page,
}) => {
  await open(page, base, standard());

  const main = page.getByRole("main");
  await expect(main.getByRole("heading", { level: 1, name: "Agents" })).toBeVisible();
  await expect(main.getByText("The Router of Support Desk.")).toBeVisible();
  const list = main.getByRole("region", { name: "All agents" });
  await expect(list.getByRole("row")).toHaveCount(2);
  const routerRow = list.getByRole("row", { name: /Front desk/ });
  await expect(routerRow.getByText("Router", { exact: true })).toBeVisible();
  await expect(routerRow.getByText("Active")).toBeVisible();
  await expect(list).toContainText(
    "Tasks run on this Agent Swarm at its default place and default Task model."
  );
  await expect(
    list.getByRole("link", { name: "Change them in Settings" })
  ).toHaveAttribute("href", "/orgs/acme/projects/p-1/settings");
  await expect(
    page
      .getByRole("navigation", { name: "Organization navigation" })
      .getByRole("link", { name: "Agents", exact: true })
  ).toHaveAttribute("aria-current", "page");

  await main.getByRole("link", { name: "Front desk", exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`${base}/a-router$`));
  const rail = main.getByRole("complementary", { name: "Front desk" });
  await expect(rail.getByText("claude-sonnet-4-5")).toBeVisible();
  await expect(rail.getByText("Answer politely.")).toBeVisible();
  await expect(rail.getByText("agt1_a-router")).toBeVisible();
  await expect(rail.getByText("ses1_current")).toBeVisible();
  await expect(rail.getByRole("button", { name: "Configure" })).toBeVisible();

  await rail.getByRole("button", { name: "Close agent details" }).click();
  await expect(page).toHaveURL(new RegExp(`${base}$`));
  await expect(main.getByRole("complementary")).toHaveCount(0);
});

test("a retired Worker's address opens it read-only as history", async ({ page }) => {
  // A Task's participants link to the Worker that ran it.
  await open(page, `${base}/a-billing`, standard());

  const main = page.getByRole("main");
  const rail = main.getByRole("complementary", { name: "Billing specialist" });
  await expect(
    rail.getByText("Workers are retired. This Worker is kept as history.")
  ).toBeVisible();
  await expect(rail.getByText("Worker", { exact: true })).toBeVisible();
  await expect(rail.getByText("Follows the default")).toBeVisible();
  await expect(rail.getByText("No system prompt.")).toBeVisible();
  await expect(rail.getByRole("button", { name: "Configure" })).toHaveCount(0);
  await expect(
    main.getByRole("link", { name: "Front desk", exact: true })
  ).toBeVisible();
});

test("an agent's address opens the page with it selected; an unknown one says so", async ({
  page,
}) => {
  await open(
    page,
    `${base}/a-router`,
    standard((request) =>
      request.path === `${api}/a-gone`
        ? failure(404, "agent_not_found", "Agent not found.")
        : undefined
    )
  );

  const main = page.getByRole("main");
  await expect(main.getByRole("complementary", { name: "Front desk" })).toBeVisible();
  await expect(
    main.getByRole("link", { name: "Front desk", exact: true })
  ).toHaveAttribute("aria-current", "true");

  await page.goto(`${base}/a-gone`);
  await expect(
    main.getByText("This agent is not part of this Agent Swarm.")
  ).toBeVisible();
  await expect(
    main.getByRole("link", { name: "Front desk", exact: true })
  ).not.toHaveAttribute("aria-current", "true");
});

test("a deep link by Salix agent id highlights the agent's row", async ({ page }) => {
  // The Websites panel links agents by their Salix id.
  await open(
    page,
    `${base}/agt1_a-router`,
    standard((request) =>
      request.path === `${api}/agt1_a-router` ? ok(detail(router)) : undefined
    )
  );

  const main = page.getByRole("main");
  await expect(main.getByRole("complementary", { name: "Front desk" })).toBeVisible();
  await expect(
    main.getByRole("link", { name: "Front desk", exact: true })
  ).toHaveAttribute("aria-current", "true");
});

test("Refresh re-reads the list and the open agent", async ({ page }) => {
  let prompt = "Answer politely.";
  const requests = await open(
    page,
    `${base}/a-router`,
    standard((request) =>
      request.path === `${api}/a-router` && request.method === "GET"
        ? ok(
            detail(router, {
              agent: { ...detail(router).agent, system_prompt: prompt },
            })
          )
        : undefined
    )
  );

  const main = page.getByRole("main");
  const rail = main.getByRole("complementary", { name: "Front desk" });
  await expect(rail.getByText("Answer politely.")).toBeVisible();
  const reads = (path: string) =>
    requests.filter((request) => request.method === "GET" && request.path === path)
      .length;
  const before = { list: reads(api), agent: reads(`${api}/a-router`) };
  prompt = "Route politely.";
  await main.getByRole("button", { name: "Refresh" }).click();
  await expect(rail.getByText("Route politely.")).toBeVisible();
  expect(reads(`${api}/a-router`)).toBe(before.agent + 1);
  expect(reads(api)).toBe(before.list + 1);
});

test("an outage is said in place with a retry", async ({ page }) => {
  let down = true;
  await open(page, base, (request) =>
    request.path === api
      ? ok(
          down
            ? { ...page1(), status: "unavailable", agents: [], triage_href: null }
            : page1()
        )
      : undefined
  );

  const main = page.getByRole("main");
  await expect(main.getByText("Agent list is temporarily unavailable.")).toBeVisible();
  down = false;
  await main.getByRole("button", { name: "Retry" }).click();
  await expect(
    main.getByRole("link", { name: "Front desk", exact: true })
  ).toBeVisible();
});

test("Configure offers the org's models and keeps an untouched model", async ({
  page,
}) => {
  const gpt5 = { kind: "catalog", model: "gpt-5", reasoning_effort: "high" };
  const requests = await open(
    page,
    `${base}/a-router`,
    standard((request) => {
      if (request.path === `${api}/a-router/config`)
        return ok({
          agent: { id: "a-router", name: "Front desk", role: "router" },
          model_key: "catalog:deepseek-flash",
          system_prompt: "Answer politely.",
          available: true,
          models: [
            {
              key: "",
              choice: null,
              label: "Default (gpt-5)",
              disabled: false,
              group: "Platform billing",
            },
            {
              key: "catalog:deepseek-flash",
              choice: { kind: "catalog", model: "deepseek-flash" },
              label: "deepseek-flash (current; unavailable for selection)",
              disabled: true,
              group: "Platform billing",
            },
            {
              key: "catalog:gpt-5",
              choice: gpt5,
              label: "gpt-5",
              disabled: false,
              group: "Platform billing",
            },
            {
              key: "runtime:codex:gpt-5.6-sol",
              choice: { kind: "runtime", provider: "codex", model: "gpt-5.6-sol" },
              label: "gpt-5.6-sol (Codex)",
              disabled: false,
              group: "Organization accounts",
            },
          ],
        });
      if (request.path === `${api}/a-router` && request.method === "PATCH") {
        const body = request.body as { system_prompt: string };
        return body.system_prompt === ""
          ? failure(422, "invalid_agent", "Could not save the configuration.", {
              system_prompt: ["An existing system prompt cannot be cleared."],
            })
          : ok({ ...detail(router), notice: "Agent configuration saved." });
      }
      return undefined;
    })
  );

  const rail = page.getByRole("complementary", { name: "Front desk" });
  await rail.getByRole("button", { name: "Configure" }).click();
  const dialog = page.getByRole("dialog", { name: "Configure Front desk" });
  const model = dialog.getByRole("button", { name: /Model/ });
  await expect(model).toContainText(
    "deepseek-flash (current; unavailable for selection)"
  );

  await dialog.getByLabel("System prompt").fill("");
  await dialog.getByRole("button", { name: "Save configuration" }).click();
  await expect(
    dialog.getByText("An existing system prompt cannot be cleared.")
  ).toBeVisible();

  await dialog.getByLabel("System prompt").fill("Route politely.");
  await dialog.getByRole("button", { name: "Save configuration" }).click();
  await expect(dialog).toHaveCount(0);
  await expect(page.getByText("Agent configuration saved.")).toBeVisible();

  await rail.getByRole("button", { name: "Configure" }).click();
  await dialog.getByRole("button", { name: /Model/ }).click();
  await expect(
    page.getByRole("option", { name: /current; unavailable/ })
  ).toBeDisabled();
  await page.getByRole("option", { name: "gpt-5", exact: true }).click();
  await dialog.getByRole("button", { name: "Save configuration" }).click();
  await expect(dialog).toHaveCount(0);

  await rail.getByRole("button", { name: "Configure" }).click();
  await dialog.getByRole("button", { name: /Model/ }).click();
  await page.getByRole("option", { name: "Default (gpt-5)" }).click();
  await dialog.getByRole("button", { name: "Save configuration" }).click();
  await expect(dialog).toHaveCount(0);

  // The chosen option's model choice is sent back; the default sends null.
  expect(writes(requests).map((request) => request.body)).toEqual([
    { system_prompt: "" },
    { system_prompt: "Route politely." },
    { model: gpt5, system_prompt: "Answer politely." },
    { model: null, system_prompt: "Answer politely." },
  ]);
  expect(writes(requests).every((request) => request.csrf === csrf)).toBe(true);
});

test("an admin starts a new Router session; a stale one shows the current", async ({
  page,
}) => {
  let session = "ses1_current";
  const requests = await open(
    page,
    `${base}/a-router`,
    standard((request) => {
      if (request.path === `${api}/a-router` && request.method === "GET")
        return ok(detail(router, { router_session: { status: "ok", id: session } }));
      if (request.path === `${api}/a-router/router-session`) {
        session = "ses1_other";
        return failure(
          409,
          "stale_router_session",
          "The Router session was already switched. The current session is shown below."
        );
      }
      return undefined;
    })
  );

  const rail = page.getByRole("complementary", { name: "Front desk" });
  await rail.getByRole("button", { name: "Start new session" }).click();
  const dialog = page.getByRole("dialog", {
    name: "Start a new canonical Router session",
  });
  await dialog.getByRole("button", { name: "Start new session" }).click();
  await expect(dialog.getByRole("alert")).toContainText("already switched");
  await expect(rail.getByText("ses1_other")).toBeVisible();
  expect(writes(requests)[0]).toEqual(
    expect.objectContaining({ csrf, body: { expected_session_id: "ses1_current" } })
  );
});

test("a refused write keeps its message when the re-read fails", async ({ page }) => {
  // The Router reads until its write is refused; the re-read then fails.
  let refused = false;
  await open(
    page,
    `${base}/a-router`,
    standard((request) => {
      if (request.path === `${api}/a-router` && request.method === "GET")
        return refused
          ? failure(503, "runtime_unavailable", "Salix is unavailable.")
          : ok(detail(router));
      if (request.path === `${api}/a-router/router-session`) {
        refused = true;
        return failure(
          409,
          "stale_router_session",
          "The Router session was already switched. The current session is shown below."
        );
      }
      return undefined;
    })
  );

  const main = page.getByRole("main");
  const rail = main.getByRole("complementary", { name: "Front desk" });
  await rail.getByRole("button", { name: "Start new session" }).click();
  const confirm = page.getByRole("dialog", {
    name: "Start a new canonical Router session",
  });
  await confirm.getByRole("button", { name: "Start new session" }).click();
  await expect(confirm.getByRole("alert")).toContainText("already switched");
  await expect(confirm.getByRole("alert")).not.toContainText("unavailable");
  await expect(rail.getByText("ses1_current")).toBeVisible();
});

test("a swarm member reads the Router without any write", async ({ page }) => {
  await open(page, `${base}/a-router`, standard(undefined, "user"));

  const rail = page
    .getByRole("main")
    .getByRole("complementary", { name: "Front desk" });
  await expect(rail.getByText("ses1_current")).toBeVisible();
  for (const action of ["Configure", "Start new session"]) {
    await expect(rail.getByRole("button", { name: action })).toHaveCount(0);
  }
});

test("the page and its rail fit a 900px window", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 700 });
  await open(page, `${base}/a-router`, standard());
  await expect(page.getByRole("complementary", { name: "Front desk" })).toBeVisible();
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth > window.innerWidth
  );
  expect(overflow).toBe(false);
  const rail = await page.getByRole("complementary").boundingBox();
  expect((rail?.x ?? 0) + (rail?.width ?? 0)).toBeLessThanOrEqual(900);
});
