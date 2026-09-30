import { describe, expect, it } from "vitest";

import { environments } from "../src/environments.js";
import { dashboardDefinitions } from "../src/inventory.js";
import type { DashboardJson } from "../src/validate.js";
import { validateDashboard, validateInventory } from "../src/validate.js";

const staging = environments[0];
if (staging === undefined) {
  throw new Error("staging environment is required");
}

describe("query contract", () => {
  it("rejects known schema, datasource, identity, and namespace regressions", () => {
    const invalidCases: readonly {
      readonly name: string;
      readonly dashboard: DashboardJson;
      readonly message: string;
    }[] = [
      {
        name: "legacy series name",
        dashboard: fixture(
          'comma_system_telemetry_series_budget{namespace="comma"}',
        ),
        message: "uses rejected metric comma_system_telemetry_series_budget",
      },
      {
        name: "legacy LLM duration name",
        dashboard: fixture(
          'salix_llm_attempts_duration_seconds{namespace="comma"}',
        ),
        message: "uses rejected metric salix_llm_attempts_duration_seconds",
      },
      {
        name: "missing namespace",
        dashboard: fixture("rate(comma_system_http_requests_total[5m])"),
        message: "PromQL must explicitly scope the comma namespace",
      },
      {
        name: "platform query missing namespace",
        dashboard: fixture("up"),
        message: "PromQL must explicitly scope the comma namespace",
      },
      {
        name: "missing explicit datasource",
        dashboard: {
          uid: "comma-staging-fixture",
          panels: [
            {
              id: 1,
              targets: [
                {
                  refId: "A",
                  promQLQuery: {
                    projectName: "${gcp_project}",
                    expr: 'up{namespace="comma"}',
                  },
                },
              ],
            },
          ],
        },
        message: "must explicitly use stackdriver datasource ${gcm_datasource}",
      },
      {
        name: "wrong datasource",
        dashboard: fixture('up{namespace="comma"}', "example-prod-datasource"),
        message: "must use stackdriver datasource ${gcm_datasource}",
      },
      {
        name: "missing Grafana PromQL migration compatibility marker",
        dashboard: fixture('up{namespace="comma"}', "${gcm_datasource}", false),
        message: "is missing the Grafana 13.2 migration compatibility marker",
      },
      {
        name: "duplicate panel identity",
        dashboard: {
          uid: "comma-staging-fixture",
          panels: [
            fixturePanel(1, "A", 'up{namespace="comma"}'),
            fixturePanel(1, "B", 'up{namespace="comma"}'),
          ],
        },
        message: "duplicate panel ID 1",
      },
      {
        name: "duplicate query identity",
        dashboard: {
          uid: "comma-staging-fixture",
          panels: [
            {
              ...fixturePanel(1, "A", 'up{namespace="comma"}'),
              targets: [
                fixtureTarget("A", 'up{namespace="comma"}'),
                fixtureTarget("A", 'up{namespace="comma"}'),
              ],
            },
          ],
        },
        message: "duplicate refId A",
      },
    ];

    for (const invalidCase of invalidCases) {
      expect(
        validateDashboard(
          invalidCase.dashboard,
          staging,
          `${invalidCase.name}.json`,
        ).join("\n"),
      ).toContain(invalidCase.message);
    }
  });

  it("rejects duplicate dashboard identities across the inventory", () => {
    const dashboard = fixture('up{namespace="comma"}');
    expect(
      validateInventory([
        { environment: staging, filename: "staging/a.json", dashboard },
        { environment: staging, filename: "staging/b.json", dashboard },
      ]).join("\n"),
    ).toContain("duplicate dashboard UID comma-staging-fixture");
  });

  it("keeps required health as No data and uses counter/histogram operators", () => {
    const dashboards = dashboardDefinitions.map(
      (definition) => definition.build(staging) as DashboardJson,
    );
    const serialized = JSON.stringify(dashboards);
    const expressions = collectExpressions(dashboards);

    expect(serialized).not.toContain("or vector(0)");
    expect(
      expressions.filter((expression) =>
        expression.includes("_duration_seconds_bucket"),
      ),
    ).toSatisfy((items: readonly string[]) =>
      items.every(
        (expression) =>
          expression.includes("rate(") &&
          expression.includes("histogram_quantile("),
      ),
    );
    expect(
      expressions.filter((expression) => expression.includes("_total")),
    ).toSatisfy((items: readonly string[]) =>
      items.every(
        (expression) =>
          expression.includes("rate(") || expression.includes("increase("),
      ),
    );
    expect(serialized).toContain("No data");
    expect(serialized).toContain("Lazy failure series");
  });
});

function fixture(
  expression: string,
  datasourceUid = "${gcm_datasource}",
  includePromqlCompat = true,
): DashboardJson {
  return {
    uid: "comma-staging-fixture",
    panels: [
      {
        ...fixturePanel(1, "A", expression, includePromqlCompat),
        datasource: { type: "stackdriver", uid: datasourceUid },
      },
    ],
  };
}

function fixturePanel(
  id: number,
  refId: string,
  expression: string,
  includePromqlCompat = true,
) {
  return {
    id,
    datasource: { type: "stackdriver", uid: "${gcm_datasource}" },
    targets: [fixtureTarget(refId, expression, includePromqlCompat)],
  };
}

function fixtureTarget(
  refId: string,
  expression: string,
  includePromqlCompat = true,
) {
  return {
    refId,
    datasource: { type: "stackdriver", uid: "${gcm_datasource}" },
    promQLQuery: { projectName: "${gcp_project}", expr: expression },
    ...(includePromqlCompat
      ? { timeSeriesList: { projectName: "", crossSeriesReducer: "" } }
      : {}),
  };
}

function collectExpressions(dashboards: readonly DashboardJson[]): string[] {
  const expressions: string[] = [];
  for (const dashboard of dashboards) {
    for (const panel of dashboard.panels ?? []) {
      for (const target of panel.targets ?? []) {
        if (typeof target.promQLQuery?.expr === "string") {
          expressions.push(target.promQLQuery.expr);
        }
      }
    }
  }
  return expressions;
}
