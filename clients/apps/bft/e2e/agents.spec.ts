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
const triageHref = "/orgs/acme/triage?agent=a-router#triage-worker-configuration";

const row = (id: string, name: string | null, extra = {}) => ({
  id,
  name,
  role: "worker",
  lifecycle: "active",
  runtime: "internal",
  triage: false,
  group_router: false,
  rebindable: false,
  ...extra,
});

const agents = [
  row("a-router", "Front desk", { role: "router", group_router: true }),
  row("a-billing", "Billing specialist", { triage: true }),
  row("a-repro", "Repro engineer", { runtime: "connected", rebindable: true }),
  row("a-docs", "Help center writer", {
    runtime: "compute",
    rebindable: true,
    lifecycle: "provisioning",
  }),
];

const page1 = (role = "admin", list = agents) => ({
  project: { ...project, role },
  status: "ok",
  agents: list,
  next_cursor: null,
  triage_href: triageHref,
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
    binding:
      agent.id === "a-repro"
        ? {
            summary: "Codex · d6d51b1cd455",
            revision: 2,
            location: "connected",
            device_id: "dev-1",
            device_runtime_id: "rt-1",
            provider: "codex",
            workload_id: null,
          }
        : agent.id === "a-docs"
          ? {
              summary: "Pi · w-pi-1",
              revision: 1,
              location: "compute",
              device_id: null,
              device_runtime_id: null,
              provider: "pi",
              workload_id: "w-pi-1",
            }
          : null,
  },
  triage: {
    status: "ok",
    used: agent.triage,
    revision: agent.triage ? 7 : null,
  },
  router_session: agent.role === "router" ? { status: "ok", id: "ses1_current" } : null,
  triage_href: triageHref,
  ...extra,
});

const byId = (id: string) => agents.find((agent) => agent.id === id) as Row;

const targets = {
  devices: [
    {
      id: "dev-1",
      label: "Mac Studio / dev-1",
      runtimes: [
        {
          id: "rt-1",
          label: "codex / rt-1 / codex-cli 1.4.2",
          ready: true,
          status: "ready",
          version: "codex-cli 1.4.2",
          checked_at: "2026-10-02T08:00:00Z",
          issue: null,
        },
        {
          id: "rt-2",
          label: "claude / rt-2 / 2.1.0",
          ready: false,
          status: "readiness_incomplete",
          version: "2.1.0",
          checked_at: null,
          issue: "auth_required",
        },
      ],
    },
  ],
};

const workload = (id: string, extra = {}) => ({
  id,
  label: `Workload ${id}`,
  node: "Mac Studio",
  selectable: true,
  availability: "Ready to select",
  tone: "ok",
  issue: null,
  selection_fence: { generation: id },
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
    const agent = agents.find((candidate) => candidate.id === id);
    if (agent) return ok(detail(agent, {}, role));
    return undefined;
  };

const writes = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.method !== "GET");

test("lists agents with their badges and opens one in the detail rail", async ({
  page,
}) => {
  await open(page, base, standard());

  const main = page.getByRole("main");
  await expect(main.getByRole("heading", { level: 1, name: "Agents" })).toBeVisible();
  await expect(main.getByText("The Router and workers of Support Desk.")).toBeVisible();
  const router = main.getByRole("row", { name: /Front desk/ });
  await expect(router.getByText("Group router")).toBeVisible();
  await expect(router.getByText("Router", { exact: true })).toBeVisible();
  await expect(
    main.getByRole("row", { name: /Billing specialist/ }).getByRole("link", {
      name: "Used by Triage",
    })
  ).toHaveAttribute("href", triageHref);
  await expect(
    main.getByRole("row", { name: /Help center writer/ }).getByText("Setting up")
  ).toBeVisible();
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
  // A Router is never archived.
  await expect(rail.getByRole("button", { name: "Archive" })).toHaveCount(0);

  await rail.getByRole("button", { name: "Close agent details" }).click();
  await expect(page).toHaveURL(new RegExp(`${base}$`));
  await expect(main.getByRole("complementary")).toHaveCount(0);
});

test("an agent's address opens the page with it selected; an unknown one says so", async ({
  page,
}) => {
  await open(
    page,
    `${base}/a-billing`,
    standard((request) =>
      request.path === `${api}/a-gone`
        ? failure(404, "agent_not_found", "Agent not found.")
        : undefined
    )
  );

  const main = page.getByRole("main");
  const rail = main.getByRole("complementary", { name: "Billing specialist" });
  await expect(rail.getByText("Follows the default")).toBeVisible();
  await expect(rail.getByText("No system prompt.")).toBeVisible();
  await expect(rail.getByRole("link", { name: "Open Slack triage" })).toHaveAttribute(
    "href",
    triageHref
  );
  await expect(
    main.getByRole("link", { name: "Billing specialist", exact: true })
  ).toHaveAttribute("aria-current", "true");

  await page.goto(`${base}/a-gone`);
  await expect(
    main.getByText("This agent is not part of this Agent Swarm.")
  ).toBeVisible();
  await expect(
    main.getByRole("link", { name: "Front desk", exact: true })
  ).toBeVisible();
});

test("a deep link by Salix agent id highlights the agent's row", async ({ page }) => {
  // The Websites panel links agents by their Salix id.
  await open(
    page,
    `${base}/agt1_a-billing`,
    standard((request) =>
      request.path === `${api}/agt1_a-billing`
        ? ok(detail(byId("a-billing")))
        : undefined
    )
  );

  const main = page.getByRole("main");
  await expect(
    main.getByRole("complementary", { name: "Billing specialist" })
  ).toBeVisible();
  await expect(
    main.getByRole("link", { name: "Billing specialist", exact: true })
  ).toHaveAttribute("aria-current", "true");
  await expect(
    main.getByRole("link", { name: "Front desk", exact: true })
  ).not.toHaveAttribute("aria-current", "true");
});

test("Refresh re-reads the list and the open agent", async ({ page }) => {
  let prompt: string | null = null;
  const requests = await open(
    page,
    `${base}/a-billing`,
    standard((request) =>
      request.path === `${api}/a-billing` && request.method === "GET"
        ? ok(
            detail(byId("a-billing"), {
              agent: { ...detail(byId("a-billing")).agent, system_prompt: prompt },
            })
          )
        : undefined
    )
  );

  const main = page.getByRole("main");
  const rail = main.getByRole("complementary", { name: "Billing specialist" });
  await expect(rail.getByText("No system prompt.")).toBeVisible();
  const reads = (path: string) =>
    requests.filter((request) => request.method === "GET" && request.path === path)
      .length;
  const before = { list: reads(api), agent: reads(`${api}/a-billing`) };
  prompt = "Check invoices first.";
  await main.getByRole("button", { name: "Refresh" }).click();
  await expect(rail.getByText("Check invoices first.")).toBeVisible();
  expect(reads(`${api}/a-billing`)).toBe(before.agent + 1);
  expect(reads(api)).toBe(before.list + 1);
});

test("pages in more agents and retries a failed later page", async ({ page }) => {
  let failing = true;
  const requests = await open(page, base, (request) => {
    if (request.path !== api) return undefined;
    if (request.search !== "?cursor=page-2")
      return ok({ ...page1(), next_cursor: "page-2" });
    return failing
      ? failure(503, "runtime_unavailable", "Could not load more agents.")
      : ok({ ...page1(), agents: [row("a-late", "Late worker")], next_cursor: null });
  });

  const main = page.getByRole("main");
  await expect(main.getByRole("alert")).toContainText("Could not load more agents.");
  failing = false;
  await main.getByRole("button", { name: "Retry" }).click();
  await expect(main.getByRole("link", { name: "Late worker" })).toBeVisible();
  expect(
    requests.filter((request) => request.search === "?cursor=page-2")
  ).toHaveLength(2);
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

test("New agent creates an internal worker and leaves a notice", async ({ page }) => {
  let created = false;
  const requests = await open(
    page,
    base,
    standard((request) => {
      if (request.path === api && request.method === "POST") {
        created = true;
        return {
          status: 201,
          body: {
            ok: true,
            data: {
              id: "a-new",
              notice: "Agent creation accepted. Refresh the list after provisioning.",
            },
          },
        };
      }
      if (request.path === api && created)
        return ok(page1("admin", [...agents, row("a-new", "worker-1")]));
      return undefined;
    })
  );

  await page.getByRole("button", { name: "New agent" }).click();
  const dialog = page.getByRole("dialog", { name: "New agent" });
  await dialog.getByLabel("Name").fill("worker-1");
  await dialog.getByRole("button", { name: "Create agent" }).click();

  await expect(dialog).toHaveCount(0);
  await expect(
    page.getByText("Agent creation accepted. Refresh the list after provisioning.")
  ).toBeVisible();
  await expect(page.getByRole("link", { name: "worker-1" })).toBeVisible();
  expect(writes(requests)).toEqual([
    expect.objectContaining({
      method: "POST",
      path: api,
      csrf,
      body: { type: "internal", name: "worker-1" },
    }),
  ]);
});

test("an external agent runs on a ready Connected Device runtime", async ({ page }) => {
  const requests = await open(
    page,
    base,
    standard((request) => {
      if (request.path === `${api}/targets`) return ok(targets);
      if (request.path === api && request.method === "POST")
        return request.body &&
          (request.body as { target: { device_runtime_id: string } }).target
            .device_runtime_id === ""
          ? failure(422, "invalid_target", "Select an external runtime.")
          : {
              status: 201,
              body: { ok: true, data: { id: "a-x", notice: "Accepted." } },
            };
      return undefined;
    })
  );

  await page.getByRole("button", { name: "New agent" }).click();
  const dialog = page.getByRole("dialog", { name: "New agent" });
  await dialog.getByLabel("Name").fill("codex-worker");
  await dialog.getByRole("button", { name: /Type/ }).click();
  await page.getByRole("option", { name: /External agent/ }).click();

  await dialog.getByRole("button", { name: /Connected Device$/ }).click();
  await page.getByRole("option", { name: "Mac Studio / dev-1" }).click();
  // The server names what is missing.
  await dialog.getByRole("button", { name: "Create agent" }).click();
  await expect(dialog.getByRole("alert")).toHaveText("Select an external runtime.");

  await dialog.getByRole("button", { name: /External runtime/ }).click();
  await page.getByRole("option", { name: /claude \/ rt-2/ }).click();
  await expect(
    dialog.getByText("This runtime is not ready. Select a ready runtime before saving.")
  ).toBeVisible();
  await dialog.getByRole("button", { name: /External runtime/ }).click();
  await page.getByRole("option", { name: /codex \/ rt-1/ }).click();
  const readiness = dialog.getByTestId("runtime-readiness");
  await expect(readiness).toContainText("codex-cli 1.4.2");
  await expect(readiness).not.toContainText("not ready");

  await dialog.getByRole("button", { name: "Create agent" }).click();
  await expect(dialog).toHaveCount(0);
  expect(writes(requests).at(-1)).toEqual(
    expect.objectContaining({
      csrf,
      body: {
        type: "external",
        name: "codex-worker",
        target: {
          kind: "connected_runtime",
          device_id: "dev-1",
          device_runtime_id: "rt-1",
        },
      },
    })
  );
});

test("the Compute Workload picker filters, pages and sends the selection fence", async ({
  page,
}) => {
  const requests = await open(
    page,
    base,
    standard((request) => {
      if (request.path === `${api}/workloads`) {
        const params = new URLSearchParams(request.search);
        if (params.get("cursor") === "next")
          return ok({
            status: "ok",
            items: [workload("w-claude-2")],
            next_cursor: null,
          });
        if (params.get("provider") !== "claude")
          return ok({ status: "ok", items: [], next_cursor: null });
        return ok({
          status: "ok",
          items: [
            workload("w-claude-1"),
            ...(params.get("include_unavailable")
              ? [
                  workload("w-claude-busy", {
                    selectable: false,
                    availability: "Runtime not ready",
                    tone: "warn",
                    issue: "code=resource_capacity_exhausted / stage=import_admission",
                  }),
                ]
              : []),
          ],
          next_cursor: "next",
        });
      }
      if (request.path === api && request.method === "POST")
        return {
          status: 201,
          body: { ok: true, data: { id: "a-x", notice: "Accepted." } },
        };
      return undefined;
    })
  );

  await page.getByRole("button", { name: "New agent" }).click();
  const dialog = page.getByRole("dialog", { name: "New agent" });
  await dialog.getByRole("button", { name: /Type/ }).click();
  await page.getByRole("option", { name: /External agent/ }).click();
  await dialog.getByRole("button", { name: /Run on/ }).click();
  await page.getByRole("option", { name: "Compute Workload" }).click();
  await expect(dialog.getByText("No matching Compute Workloads.")).toBeVisible();

  await dialog.getByRole("button", { name: /Provider/ }).click();
  await page.getByRole("option", { name: "Claude" }).click();
  const choices = dialog.getByRole("group", { name: "Compute Workloads" });
  await expect(choices.getByRole("radio")).toHaveCount(1);
  await dialog.getByText("Show unavailable workloads").click();
  await expect(choices.getByRole("radio", { name: /w-claude-busy/ })).toBeDisabled();
  await expect(choices).toContainText("code=resource_capacity_exhausted");

  await choices.getByRole("radio", { name: /w-claude-1/ }).check();
  // The next page replaces the list, which drops a selection it does not hold.
  await dialog.getByRole("button", { name: "Next page" }).click();
  await expect(choices.getByRole("radio", { name: /w-claude-2/ })).toBeVisible();
  await expect(choices.getByRole("radio", { name: /w-claude-1/ })).toHaveCount(0);
  await choices.getByRole("radio", { name: /w-claude-2/ }).check();

  await dialog.getByRole("button", { name: "Create agent" }).click();
  await expect(dialog).toHaveCount(0);
  expect(writes(requests).at(-1)?.body).toEqual({
    type: "external",
    name: "",
    target: {
      kind: "compute_workload",
      workload_id: "w-claude-2",
      selection_fence: { generation: "w-claude-2" },
    },
  });
  const searches = requests
    .filter((request) => request.path === `${api}/workloads`)
    .map((request) => request.search);
  expect(searches).toContain("?provider=claude&include_unavailable=true");
  expect(searches).toContain("?provider=claude&include_unavailable=true&cursor=next");
});

test("Configure offers the org's models and keeps an untouched model", async ({
  page,
}) => {
  const router = byId("a-router");
  const requests = await open(
    page,
    `${base}/a-router`,
    standard((request) => {
      if (request.path === `${api}/a-router/config`)
        return ok({
          agent: { id: "a-router", name: "Front desk", role: "router" },
          template_id: "tmpl-gone",
          system_prompt: "Answer politely.",
          available: true,
          models: [
            {
              id: "",
              label: "Default (gpt-5)",
              disabled: false,
              group: "Platform billing",
            },
            {
              id: "tmpl-gone",
              label: "deepseek-flash (current; unavailable for selection)",
              disabled: true,
              group: "Platform billing",
            },
            {
              id: "tmpl-gpt",
              label: "gpt-5",
              disabled: false,
              group: "Platform billing",
            },
            {
              id: "tmpl-codex",
              label: "gpt-5.6-sol — Team",
              disabled: false,
              group: "BYOK",
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
  await page.getByRole("option", { name: "Default (gpt-5)" }).click();
  await dialog.getByRole("button", { name: "Save configuration" }).click();
  await expect(dialog).toHaveCount(0);

  expect(writes(requests).map((request) => request.body)).toEqual([
    { system_prompt: "" },
    { system_prompt: "Route politely." },
    { template_id: "", system_prompt: "Answer politely." },
  ]);
  expect(writes(requests).every((request) => request.csrf === csrf)).toBe(true);
});

test("Rebind sends the revision it showed; a changed binding is refused", async ({
  page,
}) => {
  const repro = byId("a-repro");
  let stale = true;
  const requests = await open(
    page,
    `${base}/a-repro`,
    standard((request) => {
      if (request.path === `${api}/targets`) return ok(targets);
      if (request.path === `${api}/a-repro/runtime`)
        return stale
          ? failure(
              409,
              "stale_binding",
              "The binding changed. Reopen the form and try again."
            )
          : ok({ ...detail(repro), notice: "Agent runtime rebound." });
      return undefined;
    })
  );

  const rail = page.getByRole("complementary", { name: "Repro engineer" });
  await expect(rail.getByText("Codex · d6d51b1cd455")).toBeVisible();
  await rail.getByRole("button", { name: "Rebind runtime" }).click();
  const dialog = page.getByRole("dialog", {
    name: "Rebind runtime for Repro engineer",
  });
  await expect(
    dialog.getByText("Target for new sessions: Codex · d6d51b1cd455")
  ).toBeVisible();
  await expect(dialog.getByRole("button", { name: /Connected Device$/ })).toContainText(
    "Mac Studio / dev-1"
  );
  await expect(dialog.getByRole("button", { name: /External runtime/ })).toContainText(
    "codex / rt-1"
  );

  await dialog.getByRole("button", { name: "Save runtime" }).click();
  await expect(dialog.getByRole("alert")).toHaveText(
    "The binding changed. Reopen the form and try again."
  );
  stale = false;
  await dialog.getByRole("button", { name: "Save runtime" }).click();
  await expect(dialog).toHaveCount(0);
  await expect(page.getByText("Agent runtime rebound.")).toBeVisible();
  expect(writes(requests).at(-1)).toEqual(
    expect.objectContaining({
      method: "PUT",
      csrf,
      body: {
        expected_binding_revision: 2,
        target: {
          kind: "connected_runtime",
          device_id: "dev-1",
          device_runtime_id: "rt-1",
        },
      },
    })
  );
});

test("archiving the Triage Worker confirms its impact and the Triage revision", async ({
  page,
}) => {
  const billing = byId("a-billing");
  let assigned = false;
  let archived = false;
  const requests = await open(
    page,
    `${base}/a-billing`,
    standard((request) => {
      if (request.path === `${api}/a-billing` && request.method === "GET")
        return ok(
          detail(
            { ...billing, triage: assigned },
            {
              triage: {
                status: "ok",
                used: assigned,
                revision: assigned ? 7 : null,
              },
            }
          )
        );
      if (request.path === `${api}/a-billing/archive`) {
        if (!(request.body as { triage_revision?: number }).triage_revision) {
          // Triage chose this Worker after the dialog opened.
          assigned = true;
          return failure(
            409,
            "triage_confirmation_required",
            "This Worker is now assigned to Triage. Open Archive again to review the impact."
          );
        }
        archived = true;
        return ok({ redirect: base, notice: "Agent archived." });
      }
      if (request.path === api && archived)
        return ok(
          page1(
            "admin",
            agents.filter((agent) => agent.id !== "a-billing")
          )
        );
      return undefined;
    })
  );

  const rail = page.getByRole("complementary", { name: "Billing specialist" });
  await rail.getByRole("button", { name: "Archive" }).click();
  const dialog = page.getByRole("dialog", { name: "Archive agent" });
  await expect(dialog).toContainText("Archive Billing specialist?");
  await dialog.getByRole("button", { name: "Archive", exact: true }).click();
  await expect(dialog.getByRole("alert")).toContainText("Open Archive again");
  await expect(dialog.getByText(/used by Triage in Support Desk/)).toBeVisible();
  await expect(
    dialog.getByRole("link", { name: "Choose another Worker in Triage" })
  ).toHaveAttribute("href", triageHref);

  await dialog.getByRole("button", { name: "Archive and pause Triage" }).click();
  await expect(page).toHaveURL(new RegExp(`${base}$`));
  await expect(page.getByText("Agent archived.")).toBeVisible();
  await expect(page.getByRole("link", { name: "Billing specialist" })).toHaveCount(0);
  expect(writes(requests).map((request) => request.body)).toEqual([
    {},
    { triage_revision: 7 },
  ]);
});

test("an admin starts a new Router session; a stale one shows the current", async ({
  page,
}) => {
  const router = byId("a-router");
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
  // Each agent reads until its write is refused; the re-read then fails.
  const refused = { router: false, billing: false };
  const unavailable = failure(503, "runtime_unavailable", "Salix is unavailable.");
  await open(
    page,
    `${base}/a-router`,
    standard((request) => {
      if (request.path === `${api}/a-router` && request.method === "GET")
        return refused.router ? unavailable : ok(detail(byId("a-router")));
      if (request.path === `${api}/a-router/router-session`) {
        refused.router = true;
        return failure(
          409,
          "stale_router_session",
          "The Router session was already switched. The current session is shown below."
        );
      }
      if (request.path === `${api}/a-billing` && request.method === "GET")
        return refused.billing ? unavailable : ok(detail(byId("a-billing")));
      if (request.path === `${api}/a-billing/archive`) {
        refused.billing = true;
        return failure(
          409,
          "triage_confirmation_required",
          "This Worker is now assigned to Triage. Open Archive again to review the impact."
        );
      }
      return undefined;
    })
  );

  const main = page.getByRole("main");
  const router = main.getByRole("complementary", { name: "Front desk" });
  await router.getByRole("button", { name: "Start new session" }).click();
  const confirm = page.getByRole("dialog", {
    name: "Start a new canonical Router session",
  });
  await confirm.getByRole("button", { name: "Start new session" }).click();
  await expect(confirm.getByRole("alert")).toContainText("already switched");
  await expect(confirm.getByRole("alert")).not.toContainText("unavailable");
  await expect(router.getByText("ses1_current")).toBeVisible();
  await confirm.getByRole("button", { name: "Cancel" }).click();

  await main.getByRole("link", { name: "Billing specialist", exact: true }).click();
  const billing = main.getByRole("complementary", { name: "Billing specialist" });
  await billing.getByRole("button", { name: "Archive" }).click();
  const archive = page.getByRole("dialog", { name: "Archive agent" });
  await archive.getByRole("button", { name: "Archive and pause Triage" }).click();
  await expect(archive.getByRole("alert")).toContainText("Open Archive again");
  await expect(archive.getByRole("alert")).not.toContainText("unavailable");
});

test("a swarm member reads agents without any write", async ({ page }) => {
  await open(page, `${base}/a-repro`, standard(undefined, "user"));

  const main = page.getByRole("main");
  await expect(
    main.getByRole("link", { name: "Front desk", exact: true })
  ).toBeVisible();
  await expect(main.getByRole("button", { name: "New agent" })).toHaveCount(0);
  const rail = main.getByRole("complementary", { name: "Repro engineer" });
  await expect(rail.getByText("Codex · d6d51b1cd455")).toBeVisible();
  for (const action of ["Configure", "Rebind runtime", "Archive"]) {
    await expect(rail.getByRole("button", { name: action })).toHaveCount(0);
  }
});

test("the page and its rail fit a 900px window", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 700 });
  await open(page, `${base}/a-repro`, standard());
  await expect(
    page.getByRole("complementary", { name: "Repro engineer" })
  ).toBeVisible();
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth > window.innerWidth
  );
  expect(overflow).toBe(false);
  const rail = await page.getByRole("complementary").boundingBox();
  expect((rail?.x ?? 0) + (rail?.width ?? 0)).toBeLessThanOrEqual(900);
});
