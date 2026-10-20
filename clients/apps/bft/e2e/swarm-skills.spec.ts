import { expect, test, type Page } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const base = "/orgs/acme/projects/p-1/skills";
const api = "/orgs/acme/projects/p-1/skills";
const project = { id: "p-1", name: "Support Desk", role: "admin" };

const skill = (
  id: string,
  name: string,
  source: string,
  extra: Record<string, unknown> = {}
) => ({
  id,
  location: `/.runtime/skills/${id}/SKILL.md`,
  name,
  description: `${name} description`,
  source,
  activation: "regular",
  deletable: source !== "system",
  delete_reason: source === "system" ? "read_only" : null,
  ...extra,
});

/** One skill's own read: the list's fields and its `SKILL.md`. */
const detail = (listed: ReturnType<typeof skill>) => ({
  skill: {
    ...listed,
    content: `---\nname: ${listed.name}\n---\n\n## ${listed.name} steps\n\nCheck the changelog.`,
  },
});

const page1 = (extra: Record<string, unknown> = {}) => ({
  project,
  status: "ok",
  agent: { id: "agt_router", name: "Support Router" },
  custom: [
    skill("release-checklist", "Release checklist", "custom"),
    skill("weekly-recap", "Weekly recap", "custom", { activation: "per-message" }),
    skill("incident-review", "Incident review", "imported", {
      deletable: false,
      delete_reason: "managed_at_source",
    }),
  ],
  system: [skill("pdf", "PDF", "system")],
  miniskill_status: "ready",
  agents_href: "/orgs/acme/projects/p-1/agents",
  limits: { max_bytes: 200_000, extensions: [".md", ".markdown"] },
  ...extra,
});

const failure = (status: number, code: string, message: string) => ({
  status,
  body: { ok: false, error: { code, message, details: {} } },
});

type Handler = (
  request: RecordedRequest
) => { status: number; body: unknown } | undefined;

async function open(
  page: Page,
  handle: Handler = () => undefined,
  data = () => page1()
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    const answer = handle(request);
    if (answer) return answer;
    if (request.method === "GET" && request.path === api) return ok(data());
    if (request.method === "GET" && request.path.startsWith(`${api}/`)) {
      const { custom, system } = data();
      const listed = [...custom, ...system].find(
        (item) => request.path === `${api}/${item.id}`
      );
      return listed ? ok(detail(listed)) : undefined;
    }
    return undefined;
  });
  await page.goto(base);
  await expect(page.getByRole("heading", { level: 1, name: "Skills" })).toBeVisible();
  return requests;
}

const main = (page: Page) => page.getByRole("main");
const custom = (page: Page) =>
  main(page).getByRole("list", { name: "Custom skills" }).getByRole("listitem");
const writes = (requests: RecordedRequest[]) =>
  requests.filter((request) => request.method !== "GET");
const created = (notice: string) => ({
  status: 201,
  body: { ok: true, data: { notice } },
});

test("lists custom and system skills and reads one", async ({ page }) => {
  const requests = await open(page);
  await expect(
    main(page).getByText("Reusable playbooks available to Support Desk.")
  ).toBeVisible();
  await expect(main(page).getByText(/Managed through Support Router\./)).toBeVisible();
  await expect(custom(page)).toHaveCount(3);
  await expect(
    custom(page).filter({ hasText: "Weekly recap" }).getByText("Miniskill")
  ).toBeVisible();
  await expect(
    custom(page).filter({ hasText: "Incident review" }).getByText("Imported")
  ).toBeVisible();
  // A skill managed at its source cannot be deleted here.
  await expect(
    custom(page).filter({ hasText: "Incident review" }).getByText("Managed at source")
  ).toBeVisible();
  await expect(main(page).getByRole("button", { name: /^Delete / })).toHaveCount(2);

  const system = main(page).getByRole("list", { name: "System skills" });
  // The list carries no content; a skill's content is read when it opens.
  const reads = () =>
    requests.filter(
      ({ method, path }) => method === "GET" && path.startsWith(`${api}/`)
    );
  expect(reads()).toEqual([]);
  await system.getByRole("button", { name: "View PDF" }).click();
  const dialog = page.getByRole("dialog", { name: "PDF" });
  await expect(dialog.getByText("/.runtime/skills/pdf/SKILL.md")).toBeVisible();
  await expect(dialog.getByText("System skill")).toBeVisible();
  // The body shows without its frontmatter.
  await expect(dialog.getByText("## PDF steps")).toBeVisible();
  await expect(dialog.getByText("name: PDF")).toHaveCount(0);
  await expect(dialog.getByRole("button", { name: "Delete" })).toHaveCount(0);
  await dialog.getByRole("button", { name: "Close" }).click();
  await expect(dialog).toHaveCount(0);
  // Development's strict mode may read twice; only the opened skill is read.
  expect(new Set(reads().map(({ path }) => path))).toEqual(new Set([`${api}/pdf`]));
});

test("a skill whose content cannot be read says so with a retry", async ({ page }) => {
  let down = true;
  await open(page, (request) => {
    if (request.method !== "GET" || request.path !== `${api}/pdf`) return undefined;
    return down
      ? failure(503, "runtime_unavailable", "The runtime is unreachable right now.")
      : ok(detail(skill("pdf", "PDF", "system")));
  });

  await main(page).getByRole("button", { name: "View PDF" }).click();
  const dialog = page.getByRole("dialog", { name: "PDF" });
  await expect(dialog.getByText("Could not load this skill's content.")).toBeVisible();
  down = false;
  await dialog.getByRole("button", { name: "Retry" }).click();
  await expect(dialog.getByText("## PDF steps")).toBeVisible();
  await expect(dialog.getByText("Could not load this skill's content.")).toHaveCount(0);
});

test("a failed reload after a write keeps the list and says it may be out of date", async ({
  page,
}) => {
  let reloadFails = false;
  await open(page, (request) => {
    if (request.method === "POST" && request.path === api) {
      reloadFails = true;
      return created("Skill created.");
    }
    if (request.method === "GET" && request.path === api && reloadFails)
      return failure(500, "internal", "Internal error");
    return undefined;
  });

  await page.getByRole("button", { name: "New skill" }).click();
  const dialog = page.getByRole("dialog", { name: "New Agent Swarm skill" });
  await dialog.getByLabel("Name").fill("Release Steps");
  await dialog.getByRole("button", { name: "Create skill" }).click();
  await expect(page.getByText("Skill created.")).toBeVisible();

  const stale = main(page)
    .getByRole("alert")
    .filter({ hasText: "Could not refresh. What you see may be out of date." });
  await expect(stale).toBeVisible();
  await expect(custom(page)).toHaveCount(3);

  reloadFails = false;
  await stale.getByRole("button", { name: "Retry" }).click();
  await expect(stale).toHaveCount(0);
  await expect(custom(page)).toHaveCount(3);
});

test("creates a skill and says why one is refused", async ({ page }) => {
  let attempts = 0;
  const requests = await open(page, (request) => {
    if (request.method !== "POST" || request.path !== api) return undefined;
    attempts += 1;
    return attempts === 1
      ? {
          status: 409,
          body: {
            ok: false,
            error: {
              code: "duplicate_skill",
              message: "A skill with that name already exists.",
              details: { fields: { name: ["A skill with that name already exists."] } },
            },
          },
        }
      : created("Skill created.");
  });

  await page.getByRole("button", { name: "New skill" }).click();
  const dialog = page.getByRole("dialog", { name: "New Agent Swarm skill" });
  await dialog.getByLabel("Name").fill("Release Checklist!");
  await expect(
    dialog.getByText("Stored as /.runtime/skills/release-checklist/SKILL.md")
  ).toBeVisible();
  await dialog
    .getByLabel("When should the Agent Swarm use it?")
    .fill("Before releases.");
  await dialog.getByRole("button", { name: /Activation/ }).click();
  await page
    .getByRole("option", { name: "Miniskill: select for each message" })
    .click();
  await dialog.getByLabel("Instructions").fill("Check the changelog.");
  await dialog.getByRole("button", { name: "Create skill" }).click();
  await expect(
    dialog.getByText("A skill with that name already exists.").first()
  ).toBeVisible();

  await dialog.getByLabel("Name").fill("Release Steps");
  await dialog.getByRole("button", { name: "Create skill" }).click();
  await expect(dialog).toHaveCount(0);
  await expect(page.getByText("Skill created.")).toBeVisible();

  expect(writes(requests).map(({ body, csrf: token }) => [body, token])).toEqual([
    [
      {
        name: "Release Checklist!",
        description: "Before releases.",
        instructions: "Check the changelog.",
        activation: "per-message",
      },
      csrf,
    ],
    [
      {
        name: "Release Steps",
        description: "Before releases.",
        instructions: "Check the changelog.",
        activation: "per-message",
      },
      csrf,
    ],
  ]);
});

test("uploads a SKILL.md and checks the file before sending it", async ({ page }) => {
  const requests = await open(page, (request) => {
    if (request.method !== "POST" || request.path !== `${api}/upload`) return undefined;
    const body = request.body as { content: string };
    return body.content.startsWith("---")
      ? created("Skill uploaded.")
      : failure(
          422,
          "invalid_skill_file",
          "SKILL.md must start with YAML frontmatter delimited by ---"
        );
  });
  const input = page.getByLabel("Upload a SKILL.md file");
  const markdown = "---\nname: Weekly recap\n---\n\nSummarize the week.\n";

  await input.setInputFiles({
    name: "notes.txt",
    mimeType: "text/plain",
    buffer: Buffer.from("x"),
  });
  await expect(
    page.getByText("Upload a Markdown file with SKILL.md frontmatter.")
  ).toBeVisible();

  await input.setInputFiles({
    name: "big.md",
    mimeType: "text/markdown",
    buffer: Buffer.alloc(200_001, "x"),
  });
  await expect(page.getByText("SKILL.md must be smaller than 200 KB.")).toBeVisible();

  await input.setInputFiles({
    name: "plain.md",
    mimeType: "text/markdown",
    buffer: Buffer.from("no frontmatter"),
  });
  await expect(
    page.getByText("SKILL.md must start with YAML frontmatter delimited by ---")
  ).toBeVisible();

  await input.setInputFiles({
    name: "SKILL.markdown",
    mimeType: "text/markdown",
    buffer: Buffer.from(markdown),
  });
  await expect(page.getByText("Skill uploaded.")).toBeVisible();

  // Files outside the limits never reach the server.
  expect(writes(requests).map(({ path, body }) => [path, body])).toEqual([
    [`${api}/upload`, { filename: "plain.md", content: "no frontmatter" }],
    [`${api}/upload`, { filename: "SKILL.markdown", content: markdown }],
  ]);
});

test("deletes a custom skill after confirming, from its row or its dialog", async ({
  page,
}) => {
  let custom1 = page1().custom;
  const requests = await open(
    page,
    (request) => {
      if (request.method !== "DELETE") return undefined;
      const id = request.path.split("/").pop();
      custom1 = custom1.filter((item) => item.id !== id);
      return ok({ notice: "Skill deleted." });
    },
    () => page1({ custom: custom1 })
  );

  await page.getByRole("button", { name: "Delete Release checklist" }).click();
  const confirm = page.getByRole("dialog", { name: "Delete skill" });
  await expect(
    confirm.getByText(
      "Delete Release checklist? This Agent Swarm loses it immediately."
    )
  ).toBeVisible();
  await confirm.getByRole("button", { name: "Delete" }).click();
  await expect(page.getByText("Skill deleted.")).toBeVisible();
  await expect(custom(page)).toHaveCount(2);

  await main(page).getByRole("button", { name: "View Weekly recap" }).click();
  await page
    .getByRole("dialog", { name: "Weekly recap" })
    .getByRole("button", { name: "Delete" })
    .click();
  await confirm.getByRole("button", { name: "Delete" }).click();
  await expect(custom(page)).toHaveCount(1);

  expect(
    writes(requests).map(({ method, path, csrf: token }) => [method, path, token])
  ).toEqual([
    ["DELETE", `${api}/release-checklist`, csrf],
    ["DELETE", `${api}/weekly-recap`, csrf],
  ]);
});

test("a swarm member reads skills without write controls", async ({ page }) => {
  await open(page, undefined, () => page1({ project: { ...project, role: "user" } }));
  await expect(custom(page)).toHaveCount(3);
  await expect(page.getByRole("button", { name: "New skill" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Upload" })).toHaveCount(0);
  await expect(main(page).getByRole("button", { name: /^Delete / })).toHaveCount(0);
  await expect(main(page).getByText("Managed at source")).toHaveCount(0);

  await main(page).getByRole("button", { name: "View Release checklist" }).click();
  await expect(
    page
      .getByRole("dialog", { name: "Release checklist" })
      .getByRole("button", { name: "Delete" })
  ).toHaveCount(0);
});

test("without an agent the page points to Agents; an outage still renders", async ({
  page,
}) => {
  let state: "no-agent" | "down" = "no-agent";
  await open(page, undefined, () =>
    state === "no-agent"
      ? page1({ agent: null, custom: [], system: [] })
      : page1({
          status: "unavailable",
          custom: [],
          system: [],
          miniskill_status: "catalog_over_budget",
        })
  );

  await expect(
    main(page).getByRole("heading", { name: "No runtime agent yet" })
  ).toBeVisible();
  await expect(main(page).getByRole("link", { name: "Go to Agents" })).toHaveAttribute(
    "href",
    "/orgs/acme/projects/p-1/agents"
  );
  await expect(page.getByRole("button", { name: "New skill" })).toHaveCount(0);

  state = "down";
  await page.reload();
  await expect(
    main(page).getByText(
      "The runtime is unreachable right now; skills may be incomplete."
    )
  ).toBeVisible();
  await expect(
    main(page).getByText(/Miniskill selection exceeds its request budget/)
  ).toBeVisible();
  await expect(main(page).getByText("No custom skills yet.")).toBeVisible();
  // An outage hides the empty system list rather than claim there is none.
  await expect(main(page).getByText("System skills")).toHaveCount(0);
});

test("the page fits a 900px window", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 700 });
  await open(page);
  await expect(custom(page)).toHaveCount(3);
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth
    )
  ).toBe(0);
});
