import { describe, expect, it } from "vitest";

import { buildPlatformOverview } from "../src/dashboards/platform-overview.js";
import { buildSalixRuntime } from "../src/dashboards/salix-runtime.js";
import { environments } from "../src/environments.js";
import { businessAlertShadowContracts } from "../src/shadow-contracts.js";

const staging = environments[0];
if (staging === undefined) {
  throw new Error("staging environment is required");
}

interface QueryPanel {
  readonly id?: number;
  readonly description?: string;
  readonly targets?: readonly {
    readonly promQLQuery?: { readonly expr?: string };
  }[];
}

interface QueryDashboard {
  readonly panels?: readonly QueryPanel[];
}

describe("business alert shadow contracts", () => {
  it("combines each candidate threshold with a same-window traffic floor", () => {
    const contracts = businessAlertShadowContracts;

    expect(contracts.evaluationWindow).toBe("15m");
    expect(contracts.imIngress5xx.breachExpression).toContain(
      'route="/v1/im/*"',
    );
    expect(contracts.imIngress5xx.breachExpression).toContain(
      'status_class="5xx"',
    );
    expect(contracts.imIngress5xx.breachExpression).not.toContain("4xx");
    expect(contracts.imIngress5xx.breachExpression).toContain("> 0.05");
    expect(contracts.imIngress5xx.breachExpression).toContain(">= 20");

    expect(contracts.llmLogicalRequestError.breachExpression).toContain(
      'outcome="error"',
    );
    expect(contracts.llmLogicalRequestError.breachExpression).toContain(
      "> 0.1",
    );
    expect(contracts.llmLogicalRequestError.breachExpression).toContain(
      ">= 10",
    );

    expect(contracts.llmTtft.breachExpression).toContain(
      "histogram_quantile(0.95",
    );
    expect(contracts.llmTtft.breachExpression).toContain("> 30");
    expect(contracts.llmTtft.breachExpression).toContain(">= 20");

    // Meeting conditions are counts, so they carry no threshold or minimum
    // volume — but they make the same recovery claim and must construct it
    // the same way.
    for (const expression of [
      contracts.meetingRuntimeLost.breachExpression,
      contracts.meetingStuckNonterminal.breachExpression,
      contracts.meetingDeliveryError.breachExpression,
    ]) {
      expect(expression).toContain('component="salix_meet"');
      expect(expression).toContain("[30m]");
      expect(expression).toContain("> 0");
    }

    for (const expression of [
      contracts.imIngress5xx.breachExpression,
      contracts.llmLogicalRequestError.breachExpression,
      contracts.llmTtft.breachExpression,
      contracts.meetingRuntimeLost.breachExpression,
      contracts.meetingStuckNonterminal.breachExpression,
      contracts.meetingDeliveryError.breachExpression,
    ]) {
      expect(expression).toContain("or on(workload) (0 *");
    }
    expect(JSON.stringify(contracts)).not.toContain("or vector(0)");
  });

  it("wires the exact managed staging rule queries into their semantic owner dashboards", () => {
    const platform = buildPlatformOverview(staging) as QueryDashboard;
    const salix = buildSalixRuntime(staging) as QueryDashboard;

    expect(panelExpression(platform, 151)).toBe(
      businessAlertShadowContracts.imIngress5xx.breachExpression,
    );
    expect(panelExpression(salix, 561)).toBe(
      businessAlertShadowContracts.llmLogicalRequestError.breachExpression,
    );
    expect(panelExpression(salix, 562)).toBe(
      businessAlertShadowContracts.llmTtft.breachExpression,
    );

    expect(findPanel(platform, 151).description).toContain(
      "comma_alerting:im_ingress_5xx",
    );
    expect(panelExpression(salix, 590)).toBe(
      businessAlertShadowContracts.meetingRuntimeLost.breachExpression,
    );
    expect(panelExpression(salix, 591)).toBe(
      businessAlertShadowContracts.meetingStuckNonterminal.breachExpression,
    );
    expect(panelExpression(salix, 592)).toBe(
      businessAlertShadowContracts.meetingDeliveryError.breachExpression,
    );

    expect(findPanel(salix, 561).description).toContain("comma-stg-llm-error");
    expect(findPanel(salix, 562).description).toContain("bfsralwg6q1hcd");
    expect(findPanel(salix, 590).description).toContain(
      "comma-stg-meeting-runtime-lost",
    );
    expect(findPanel(salix, 591).description).toContain(
      "comma-stg-meeting-stuck",
    );
    expect(findPanel(salix, 592).description).toContain(
      "comma-stg-meeting-delivery-error",
    );
  });
});

function panelExpression(
  dashboard: QueryDashboard,
  id: number,
): string | undefined {
  return findPanel(dashboard, id).targets?.[0]?.promQLQuery?.expr;
}

function findPanel(dashboard: QueryDashboard, id: number): QueryPanel {
  const panel = dashboard.panels?.find((candidate) => candidate.id === id);
  if (panel === undefined) {
    throw new Error(`panel ${id} is required`);
  }
  return panel;
}
