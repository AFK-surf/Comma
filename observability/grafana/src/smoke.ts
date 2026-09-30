import { GoogleAuth } from "google-auth-library";

import { environments } from "./environments.js";
import { dashboardDefinitions } from "./inventory.js";
import type { DashboardJson } from "./validate.js";

interface PrometheusResponse {
  readonly status?: unknown;
  readonly data?: { readonly result?: readonly unknown[] };
  readonly error?: unknown;
}

interface SmokeQuery {
  readonly name: string;
  readonly expression: string;
  readonly required: boolean;
}

// These are availability/capacity contracts, not event counters. Empty results are a failure.
const requiredQueries = new Set([
  "comma-staging-platform-overview/101/A",
  "comma-staging-platform-overview/102/A",
  "comma-staging-platform-overview/102/B",
  "comma-staging-platform-overview/103/A",
  "comma-staging-platform-overview/123/A",
  "comma-staging-telemetry-pipeline/201/A",
  "comma-staging-telemetry-pipeline/202/A",
  "comma-staging-telemetry-pipeline/203/A",
  "comma-staging-telemetry-pipeline/230/A",
  "comma-staging-telemetry-pipeline/230/B",
  "comma-staging-bft/301/A",
  "comma-staging-comma-product/401/A",
  "comma-staging-salix-runtime/501/A",
  "comma-staging-billing/601/A",
]);

const staging = requireStagingEnvironment();
// The live project id is release configuration, not repository content.
const stagingProject = process.env.GCP_PROJECT_ID_STAGING;
if (stagingProject === undefined || stagingProject === "") {
  throw new Error("GCP_PROJECT_ID_STAGING is required");
}

const queries = collectQueries();
const missingRequired = [...requiredQueries].filter(
  (requiredName) => !queries.some((query) => query.name === requiredName),
);
if (missingRequired.length > 0) {
  throw new Error(
    `required smoke identities are missing: ${missingRequired.join(", ")}`,
  );
}

const auth = new GoogleAuth({
  scopes: ["https://www.googleapis.com/auth/monitoring.read"],
});
const client = await auth.getClient();
let failed = false;

for (const query of queries) {
  try {
    const response = await client.request<PrometheusResponse>({
      url: `https://monitoring.googleapis.com/v1/projects/${stagingProject}/location/global/prometheus/api/v1/query`,
      params: { query: query.expression },
    });
    const status = response.data.status;
    const count = Array.isArray(response.data.data?.result)
      ? response.data.data.result.length
      : 0;
    const valid = status === "success";
    const passed = valid && (!query.required || count > 0);
    console.log(
      `${query.name}\tstatus=${String(status)}\tcount=${count}\trequired=${query.required}`,
    );
    failed ||= !passed;
  } catch (error) {
    const status = isHttpError(error)
      ? String(error.response?.status ?? "request-error")
      : "request-error";
    console.error(
      `${query.name}\tstatus=${status}\tcount=0\trequired=${query.required}`,
    );
    failed = true;
  }
}

if (failed) {
  process.exitCode = 1;
}

function collectQueries(): readonly SmokeQuery[] {
  const queries: SmokeQuery[] = [];
  for (const definition of dashboardDefinitions) {
    const dashboard = definition.build(staging) as DashboardJson;
    const dashboardUid = String(dashboard.uid);
    for (const panel of dashboard.panels ?? []) {
      for (const target of panel.targets ?? []) {
        const expression = target.promQLQuery?.expr;
        if (
          typeof panel.id !== "number" ||
          typeof target.refId !== "string" ||
          typeof expression !== "string"
        ) {
          continue;
        }
        const name = `${dashboardUid}/${panel.id}/${target.refId}`;
        queries.push({ name, expression, required: requiredQueries.has(name) });
      }
    }
  }
  return queries;
}

function requireStagingEnvironment() {
  const environment = environments.find(
    (candidate) => candidate.name === "staging",
  );
  if (environment === undefined) {
    throw new Error("staging dashboard environment is required");
  }
  return environment;
}

function isHttpError(
  error: unknown,
): error is { readonly response?: { readonly status?: unknown } } {
  return typeof error === "object" && error !== null && "response" in error;
}
