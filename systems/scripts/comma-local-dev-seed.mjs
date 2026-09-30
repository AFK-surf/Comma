import path from "node:path";
import { fileURLToPath } from "node:url";

const defaults = {
  adminToken: "test-token",
  apiBaseUrl: "http://127.0.0.1:4200",
  creditGrantGeneration: 1,
  email: "comma-local@example.com",
  sessionTtlSeconds: 10 * 365 * 24 * 60 * 60,
  redeemCode: "COMMA-LOCAL-DEV-20M",
  workspaceName: "Comma Local Dev",
  bootstrapMaxAttempts: 60,
  bootstrapPollMs: 2_000,
  requestTimeoutMs: 15_000,
};

const dangerousNonLoopbackOptIn = "I_UNDERSTAND_THIS_MUTATES_REMOTE_DATA";

class ApiError extends Error {
  constructor(method, pathName, status, payload) {
    super(
      `${method} ${pathName} returned ${status}: ${JSON.stringify(payload)}`,
    );
    this.status = status;
    this.payload = payload;
  }
}

async function apiRequest(fetchImpl, config, method, pathName, options = {}) {
  const response = await fetchImpl(`${config.apiBaseUrl}${pathName}`, {
    method,
    signal: AbortSignal.timeout(config.requestTimeoutMs),
    headers: {
      authorization: `Bearer ${options.token || config.adminToken}`,
      ...(options.body ? { "content-type": "application/json" } : {}),
    },
    ...(options.body ? { body: JSON.stringify(options.body) } : {}),
  });
  const text = await response.text();
  const payload = text ? JSON.parse(text) : null;

  if (!response.ok) {
    throw new ApiError(method, pathName, response.status, payload);
  }
  return options.includeStatus ? { status: response.status, payload } : payload;
}

function acceptedError(error, expected) {
  return error instanceof ApiError && expected.includes(error.payload?.error);
}

function assertSafeSeedTarget(apiBaseUrl, optIn) {
  let url;

  try {
    url = new URL(apiBaseUrl);
  } catch {
    throw new Error(`Invalid COMMA_LOCAL_API_BASE_URL: ${apiBaseUrl}`);
  }

  const hostname = url.hostname.replace(/^\[|\]$/g, "").toLowerCase();
  const loopback =
    hostname === "localhost" ||
    hostname === "::1" ||
    hostname === "0:0:0:0:0:0:0:1" ||
    hostname === "::ffff:127.0.0.1" ||
    /^127(?:\.\d{1,3}){3}$/.test(hostname);

  if (!loopback && optIn !== dangerousNonLoopbackOptIn) {
    throw new Error(
      `Refusing to seed non-loopback API ${url.origin}. ` +
        "This command creates users, sessions, workspaces, billing grants, and Chat data. " +
        `Set COMMA_LOCAL_DEV_SEED_ALLOW_NON_LOOPBACK=${dangerousNonLoopbackOptIn} only when you explicitly intend to mutate that remote environment.`,
    );
  }
}

async function findOrCreateUser(fetchImpl, config) {
  const email = encodeURIComponent(config.email);
  const page = await apiRequest(
    fetchImpl,
    config,
    "GET",
    `/v1/comma/admin/users?limit=1&email=${email}`,
  );
  const existing = page.data.find(
    (user) => user.email?.toLowerCase() === config.email.toLowerCase(),
  );

  if (existing) return existing;

  return apiRequest(fetchImpl, config, "POST", "/v1/comma/admin/users", {
    body: { email: config.email, name: "Comma Local Developer" },
  });
}

async function bootstrapDefaultWorkspace(fetchImpl, config, token) {
  if (
    !Number.isInteger(config.bootstrapMaxAttempts) ||
    config.bootstrapMaxAttempts <= 0
  ) {
    throw new Error("bootstrapMaxAttempts must be a positive integer");
  }
  if (!Number.isInteger(config.bootstrapPollMs) || config.bootstrapPollMs < 0) {
    throw new Error("bootstrapPollMs must be a non-negative integer");
  }

  let lastResponse = null;

  for (let attempt = 1; attempt <= config.bootstrapMaxAttempts; attempt += 1) {
    const response = await apiRequest(
      fetchImpl,
      config,
      "POST",
      "/v1/comma/me/bootstrap",
      { token, body: {}, includeStatus: true },
    );
    lastResponse = response;

    const workspace = response.payload?.workspace;
    if (
      response.status === 200 &&
      response.payload?.status === "ready" &&
      typeof workspace?.id === "string" &&
      workspace.id !== "" &&
      typeof workspace?.group_id === "string" &&
      workspace.group_id !== ""
    ) {
      return workspace;
    }

    if (
      response.status !== 202 ||
      response.payload?.status !== "provisioning" ||
      typeof workspace?.id !== "string" ||
      workspace.id === ""
    ) {
      throw new Error(
        `Unexpected Comma workspace bootstrap response: ${JSON.stringify(
          response,
        )}`,
      );
    }

    if (attempt < config.bootstrapMaxAttempts) {
      await config.sleepImpl(config.bootstrapPollMs);
    }
  }

  throw new Error(
    `Timed out waiting for Comma workspace bootstrap: ${JSON.stringify(
      lastResponse,
    )}`,
  );
}

async function findOrCreateWorkspace(fetchImpl, config, token) {
  const current = await apiRequest(fetchImpl, config, "GET", "/v1/comma/workspaces", {
    token,
  });
  const existingById = config.workspaceIdExplicit
    ? current.data.find((workspace) => workspace.id === config.workspaceId)
    : undefined;
  const existing =
    existingById ||
    (!config.workspaceIdExplicit &&
      current.data.find(
        (workspace) => workspace.name === config.workspaceName,
      ));

  if (existing) return existing;

  const bootstrapped = await bootstrapDefaultWorkspace(
    fetchImpl,
    config,
    token,
  );

  if (config.workspaceIdExplicit && bootstrapped.id !== config.workspaceId) {
    throw new Error(
      `Requested local workspace ${config.workspaceId} is not the user's default workspace ${bootstrapped.id}.`,
    );
  }

  await apiRequest(
    fetchImpl,
    config,
    "PATCH",
    `/v1/comma/workspaces/${encodeURIComponent(bootstrapped.id)}`,
    { token, body: { name: config.workspaceName } },
  );

  const refreshed = await apiRequest(
    fetchImpl,
    config,
    "GET",
    "/v1/comma/workspaces",
    { token },
  );
  const workspace = refreshed.data.find(
    (candidate) => candidate.id === bootstrapped.id,
  );

  if (!workspace) {
    throw new Error("Bootstrapped local workspace is not visible.");
  }
  if (typeof workspace.group_id !== "string" || workspace.group_id === "") {
    throw new Error("Bootstrapped local workspace has no canonical Group.");
  }
  return workspace;
}

async function ensureCredits(fetchImpl, config, workspace) {
  const redeemCode =
    config.creditGrantGeneration === 1
      ? config.redeemCode
      : `${config.redeemCode}-V${config.creditGrantGeneration}`;
  const versions = await apiRequest(
    fetchImpl,
    config,
    "GET",
    "/v1/comma/admin/billing/package-versions?surface=comma",
  );
  const packageVersion = versions.data.find(
    (version) => version.package_code === "comma_addon_20m",
  );

  if (!packageVersion) {
    throw new Error(
      "Comma 20M local package is missing; release migration did not finish.",
    );
  }

  try {
    await apiRequest(
      fetchImpl,
      config,
      "POST",
      "/v1/comma/admin/billing/redeem-codes",
      {
        body: {
          code: redeemCode,
          code_type: "one_time_package",
          package_code: packageVersion.package_code,
          package_version: packageVersion.version,
          surface: "comma",
          per_account_limit: 1,
          metadata: { source: "comma-local-dev-seed" },
        },
      },
    );
  } catch (error) {
    if (!acceptedError(error, ["redeem_code_exists"])) throw error;
  }

  try {
    await apiRequest(
      fetchImpl,
      config,
      "POST",
      "/v1/comma/admin/billing/redeem-codes/apply",
      {
        body: {
          code: redeemCode,
          billing_account_id: workspace.billing_account_id,
          surface: "comma",
          product_owner_type: "workspace",
          product_owner_id: workspace.id,
          idempotency_key: `comma-local-dev:${workspace.id}:credits-v${config.creditGrantGeneration}`,
          operator: {
            id: "comma-local-dev-seed",
            type: "system",
            reason: "bootstrap deterministic local Chat and Task testing",
          },
        },
      },
    );
  } catch (error) {
    if (!acceptedError(error, ["redeem_code_account_limit_reached"])) {
      throw error;
    }
  }
}

export async function seedLocalDev(options = {}) {
  const workspaceIdFromEnv = process.env.COMMA_LOCAL_WORKSPACE_ID;
  const creditGrantGenerationFromEnv =
    process.env.COMMA_LOCAL_CREDIT_GRANT_GENERATION;
  const config = {
    ...defaults,
    adminToken: process.env.COMMA_LOCAL_ADMIN_TOKEN || defaults.adminToken,
    apiBaseUrl: process.env.COMMA_LOCAL_API_BASE_URL || defaults.apiBaseUrl,
    creditGrantGeneration: creditGrantGenerationFromEnv
      ? Number(creditGrantGenerationFromEnv)
      : defaults.creditGrantGeneration,
    email: process.env.COMMA_LOCAL_EMAIL || defaults.email,
    workspaceId: workspaceIdFromEnv,
    ...options,
  };
  config.workspaceIdExplicit =
    options.workspaceId !== undefined || Boolean(workspaceIdFromEnv);
  config.email = config.email.trim().toLowerCase();
  config.sleepImpl =
    options.sleepImpl ||
    ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  config.dangerousAllowNonLoopback =
    options.dangerousAllowNonLoopback ??
    process.env.COMMA_LOCAL_DEV_SEED_ALLOW_NON_LOOPBACK;
  config.apiBaseUrl = config.apiBaseUrl.replace(/\/$/, "");
  assertSafeSeedTarget(config.apiBaseUrl, config.dangerousAllowNonLoopback);
  if (
    !Number.isInteger(config.requestTimeoutMs) ||
    config.requestTimeoutMs <= 0
  ) {
    throw new Error("requestTimeoutMs must be a positive integer");
  }
  if (
    !Number.isSafeInteger(config.creditGrantGeneration) ||
    config.creditGrantGeneration <= 0
  ) {
    throw new Error("creditGrantGeneration must be a positive safe integer");
  }
  if (
    !Number.isSafeInteger(config.sessionTtlSeconds) ||
    config.sessionTtlSeconds <= 0
  ) {
    throw new Error("sessionTtlSeconds must be a positive safe integer");
  }
  const fetchImpl = config.fetchImpl || fetch;

  const user = await findOrCreateUser(fetchImpl, config);
  const session = await apiRequest(
    fetchImpl,
    config,
    "POST",
    `/v1/comma/admin/users/${encodeURIComponent(user.id)}/sessions`,
    {
      body: {
        local_dev: true,
        ttl_seconds: config.sessionTtlSeconds,
      },
    },
  );
  const workspace = await findOrCreateWorkspace(
    fetchImpl,
    config,
    session.token,
  );

  if (typeof workspace.group_id !== "string" || workspace.group_id === "") {
    throw new Error(`Workspace ${workspace.id} has no canonical Group.`);
  }

  await ensureCredits(fetchImpl, config, workspace);

  const conversation = await apiRequest(
    fetchImpl,
    config,
    "POST",
    `/v1/comma/groups/${encodeURIComponent(workspace.group_id)}/assistant-chat`,
    { token: session.token, body: {} },
  );

  return {
    apiBaseUrl: config.apiBaseUrl,
    conversationId: conversation.id,
    email: user.email,
    groupId: workspace.group_id,
    mailpitUrl: "http://127.0.0.1:8025",
    sessionToken: session.token,
    workspaceId: workspace.id,
  };
}

function isMainModule() {
  return Boolean(
    process.argv[1] &&
    fileURLToPath(import.meta.url) === path.resolve(process.argv[1]),
  );
}

if (isMainModule()) {
  seedLocalDev()
    .then((result) => {
      console.log(JSON.stringify(result, null, 2));
    })
    .catch((error) => {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
    });
}
