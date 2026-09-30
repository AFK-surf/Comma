export type Json = Record<string, unknown>;

export class ApiError extends Error {
  readonly status: number;
  readonly body: string;

  constructor(method: string, url: string, status: number, body: string) {
    super(`${method} ${url} failed with ${status}: ${body}`);
    this.status = status;
    this.body = body;
  }
}

export class CommaApi {
  readonly baseUrl: string;
  readonly adminToken?: string;

  constructor(baseUrl: string, opts: { adminToken?: string } = {}) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.adminToken = opts.adminToken;
  }

  health() {
    return this.get("/health");
  }

  createUser(attrs: Json) {
    return this.post("/v1/comma/admin/users", attrs, this.adminToken);
  }

  createSession(userId: string, attrs: Json) {
    return this.post(
      `/v1/comma/admin/users/${encodeURIComponent(userId)}/sessions`,
      attrs,
      this.adminToken,
    );
  }

  listWorkspaces(token: string) {
    return this.get("/v1/comma/workspaces", token);
  }

  async bootstrapWorkspace(
    token: string,
    opts: { maxAttempts?: number; intervalMs?: number } = {},
  ) {
    const maxAttempts = opts.maxAttempts ?? 60;
    const intervalMs = opts.intervalMs ?? 2_000;
    if (!Number.isInteger(maxAttempts) || maxAttempts <= 0) {
      throw new Error("bootstrap maxAttempts must be a positive integer");
    }
    if (!Number.isInteger(intervalMs) || intervalMs < 0) {
      throw new Error("bootstrap intervalMs must be a non-negative integer");
    }

    let lastResponse: { status: number; body: Json } | undefined;

    for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
      lastResponse = await this.requestWithStatus(
        "POST",
        "/v1/comma/me/bootstrap",
        {},
        token,
      );

      const status = lastResponse.body.status;
      const workspace = jsonObject(lastResponse.body.workspace);
      const workspaceId = workspace?.id;

      if (
        lastResponse.status === 200 &&
        status === "ready" &&
        typeof workspaceId === "string" &&
        workspaceId !== ""
      ) {
        const page = await this.listWorkspaces(token);
        assertArray(page.data, "workspace list");
        const readyWorkspace = page.data.find(
          (candidate) => jsonObject(candidate)?.id === workspaceId,
        );
        const readyWorkspaceObject = jsonObject(readyWorkspace);
        if (!readyWorkspaceObject) {
          throw new Error(
            `bootstrapped workspace ${workspaceId} is not visible: ${JSON.stringify(
              page,
            )}`,
          );
        }
        return readyWorkspaceObject;
      }

      if (
        lastResponse.status !== 202 ||
        status !== "provisioning" ||
        typeof workspaceId !== "string" ||
        workspaceId === ""
      ) {
        throw new Error(
          `unexpected Comma workspace bootstrap response: ${JSON.stringify(
            lastResponse,
          )}`,
        );
      }

      if (attempt < maxAttempts) await delay(intervalMs);
    }

    throw new Error(
      `timed out waiting for Comma workspace bootstrap: ${JSON.stringify(
        lastResponse,
      )}`,
    );
  }

  listPlans(token: string) {
    return this.get("/v1/comma/billing/plans", token);
  }

  billingSummary(token: string, workspaceId: string) {
    return this.get(
      `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/billing/summary`,
      token,
    );
  }

  createCheckout(token: string, workspaceId: string, attrs: Json) {
    return this.post(
      `/v1/comma/workspaces/${encodeURIComponent(workspaceId)}/billing/checkout`,
      attrs,
      token,
    );
  }

  ensureAssistantChat(token: string, groupId: string) {
    return this.post(
      `/v1/comma/groups/${encodeURIComponent(groupId)}/assistant-chat`,
      {},
      token,
    );
  }

  sendConversationMessage(
    token: string,
    groupId: string,
    conversationId: string,
    attrs: Json,
  ) {
    return this.post(
      `/v1/comma/groups/${encodeURIComponent(groupId)}/conversations/${encodeURIComponent(
        conversationId,
      )}/messages`,
      attrs,
      token,
    );
  }

  private get(path: string, token?: string) {
    return this.request("GET", path, undefined, token);
  }

  private post(path: string, body: Json, token?: string) {
    return this.request("POST", path, body, token);
  }

  private async request(
    method: string,
    path: string,
    body?: Json,
    token?: string,
  ) {
    return (await this.requestWithStatus(method, path, body, token)).body;
  }

  private async requestWithStatus(
    method: string,
    path: string,
    body?: Json,
    token?: string,
  ): Promise<{ status: number; body: Json }> {
    const url = this.baseUrl + path;
    const headers = new Headers();
    headers.set("accept", "application/json");
    if (body) headers.set("content-type", "application/json");
    if (token) headers.set("authorization", `Bearer ${token}`);

    const response = await fetch(url, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(15_000),
    });
    const text = await response.text();

    if (!response.ok) {
      throw new ApiError(method, url, response.status, text);
    }

    const parsed = text === "" ? {} : JSON.parse(text);
    const parsedObject = jsonObject(parsed);
    if (!parsedObject) {
      throw new Error(`expected JSON object from ${method} ${url}: ${text}`);
    }

    return { status: response.status, body: parsedObject };
  }
}

export type BillingFixture = {
  runId: string;
  email: string;
  userId: string;
  token: string;
  workspaceId: string;
  groupId: string;
  billingAccountId: string;
};

export async function createBillingFixture(
  api: CommaApi,
): Promise<BillingFixture> {
  const runId = uniqueRunId();
  const email = `comma-pay-${runId}@example.test`;

  const user = await api.createUser({
    email,
    name: `Comma Payment E2E ${runId}`,
  });
  const userId = stringField(user, "id");

  const session = await api.createSession(userId, { ttl_seconds: 7200 });
  const token = stringField(session, "token");

  const workspace = await api.bootstrapWorkspace(token);

  return {
    runId,
    email,
    userId,
    token,
    workspaceId: stringField(workspace, "id"),
    groupId: stringField(workspace, "group_id"),
    billingAccountId: stringField(workspace, "billing_account_id"),
  };
}

export async function waitForCredits(
  api: CommaApi,
  token: string,
  workspaceId: string,
  predicate: (credits: number) => boolean,
  opts: {
    timeoutMs: number;
    intervalMs?: number;
    label: string;
    logEveryMs?: number;
  },
) {
  const started = Date.now();
  let lastSummary: Json | undefined;
  let lastLogAt = 0;

  while (Date.now() - started < opts.timeoutMs) {
    lastSummary = await api.billingSummary(token, workspaceId);
    const credits = numberField(lastSummary, "current_credits");
    if (predicate(credits)) return { credits, summary: lastSummary };
    lastLogAt = maybeLogWait(opts.label, started, lastLogAt, opts.logEveryMs, {
      credits,
    });
    await delay(opts.intervalMs ?? 2_000);
  }

  throw new Error(
    `timed out waiting for ${opts.label}; last summary=${JSON.stringify(
      lastSummary,
    )}`,
  );
}

export async function tryWaitForCreditDecrease(
  api: CommaApi,
  token: string,
  workspaceId: string,
  before: number,
  timeoutMs: number,
  opts: { label?: string; logEveryMs?: number } = {},
) {
  const started = Date.now();
  let last = before;
  let lastLogAt = 0;
  const label = opts.label ?? "credit decrease";

  while (Date.now() - started < timeoutMs) {
    const summary = await api.billingSummary(token, workspaceId);
    last = numberField(summary, "current_credits");
    if (last < before) return { decreased: true, credits: last, summary };
    lastLogAt = maybeLogWait(label, started, lastLogAt, opts.logEveryMs, {
      credits: last,
    });
    await delay(2_000);
  }

  return { decreased: false, credits: last };
}

export function interactiveEnabled() {
  return Deno.env.get("COMMA_STRIPE_INTERACTIVE") === "1";
}

export function env(name: string, fallback: string) {
  const value = Deno.env.get(name);
  return value && value.trim() !== "" ? value.trim() : fallback;
}

export function stringField(obj: unknown, key: string) {
  if (obj && typeof obj === "object") {
    const value = (obj as Record<string, unknown>)[key];
    if (typeof value === "string" && value !== "") return value;
  }
  throw new Error(`missing string field ${key}: ${JSON.stringify(obj)}`);
}

export function numberField(obj: unknown, key: string) {
  if (obj && typeof obj === "object") {
    const value = (obj as Record<string, unknown>)[key];
    if (typeof value === "number") return value;
    if (
      typeof value === "string" &&
      value !== "" &&
      !Number.isNaN(Number(value))
    ) {
      return Number(value);
    }
  }
  throw new Error(`missing numeric field ${key}: ${JSON.stringify(obj)}`);
}

export function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

export function assertArray(
  value: unknown,
  label: string,
): asserts value is unknown[] {
  if (!Array.isArray(value)) {
    throw new Error(`${label} is not an array: ${JSON.stringify(value)}`);
  }
}

function jsonObject(value: unknown): Json | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Json)
    : undefined;
}

export async function waitForEnter(message: string) {
  const answer = prompt(message);
  if (answer === null) {
    throw new Error("interactive confirmation was cancelled");
  }
}

export async function openUrlIfRequested(url: string) {
  if (Deno.env.get("COMMA_BILLING_E2E_OPEN_CHECKOUT") !== "1") return;

  const command =
    Deno.build.os === "darwin"
      ? ["open", url]
      : Deno.build.os === "windows"
        ? ["cmd", "/c", "start", url]
        : ["xdg-open", url];

  const child = new Deno.Command(command[0], {
    args: command.slice(1),
    stdout: "null",
    stderr: "null",
  }).spawn();
  await child.status;
}

export function uniqueRunId() {
  return `${Date.now().toString(36)}-${crypto.randomUUID().slice(0, 8)}`;
}

export function delay(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function maybeLogWait(
  label: string,
  started: number,
  lastLogAt: number,
  logEveryMs = 30_000,
  fields: Record<string, number>,
) {
  const now = Date.now();
  if (lastLogAt !== 0 && now - lastLogAt < logEveryMs) return lastLogAt;

  const elapsedSeconds = Math.floor((now - started) / 1000);
  const suffix = Object.entries(fields)
    .map(([key, value]) => `${key}=${value}`)
    .join(" ");
  console.log(`WAITING: ${label} elapsed_s=${elapsedSeconds} ${suffix}`);
  return now;
}
