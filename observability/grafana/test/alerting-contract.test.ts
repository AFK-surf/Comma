
import { describe, expect, it } from "vitest";

import {
  businessAlertRules,
  terraformAlertingProjection,
  validateTerraformAlertingProjection,
} from "../src/alerting/resources.js";
import { businessAlertShadowContracts } from "../src/shadow-contracts.js";

describe("Grafana staging alerting contract", () => {
  it("keeps the Terraform projection and its active rules locally valid", () => {
    expect(validateTerraformAlertingProjection()).toEqual([]);
    expect(terraformAlertingProjection).toMatchObject({
      schema_version: 1,
      folder_uid: "fcvt5g",
      rule_group_name: "comma-business-slo-1m",
      interval_seconds: 60,
    });
  });

  it("promotes exactly the reviewed shadow PromQL without adding production", () => {
    const byUid = new Map(businessAlertRules.map((rule) => [rule.uid, rule]));
    // comma-stg-im-5xx is intentionally absent: the IM ingress condition moved to
    // the Cloud Monitoring policy comma_alerting:im_ingress_5xx on 2026-08-12.
    expect([...byUid.keys()]).toEqual([
      "comma-stg-llm-error",
      "bfsralwg6q1hcd",
      "comma-stg-meeting-runtime-lost",
      "comma-stg-meeting-stuck",
      "comma-stg-meeting-delivery-error",
    ]);
    expect(queryExpression(byUid.get("comma-stg-llm-error"))).toBe(
      businessAlertShadowContracts.llmLogicalRequestError.breachExpression,
    );
    expect(queryExpression(byUid.get("bfsralwg6q1hcd"))).toBe(
      businessAlertShadowContracts.llmTtft.breachExpression,
    );
    expect(queryExpression(byUid.get("comma-stg-meeting-runtime-lost"))).toBe(
      businessAlertShadowContracts.meetingRuntimeLost.breachExpression,
    );
    expect(queryExpression(byUid.get("comma-stg-meeting-stuck"))).toBe(
      businessAlertShadowContracts.meetingStuckNonterminal.breachExpression,
    );
    expect(queryExpression(byUid.get("comma-stg-meeting-delivery-error"))).toBe(
      businessAlertShadowContracts.meetingDeliveryError.breachExpression,
    );

    for (const rule of businessAlertRules) {
      expect(rule.is_paused).toBe(false);
      expect(rule.labels).toMatchObject({
        environment: "staging",
        priority: "P2",
        source: "grafana",
        team: "comma",
      });
      expect(JSON.stringify(rule)).not.toContain("production");
    }
  });

});

function queryExpression(rule: unknown): unknown {
  return (
    rule as {
      readonly data: readonly [
        {
          readonly model: { readonly promQLQuery: { readonly expr: unknown } };
        },
      ];
    }
  ).data[0].model.promQLQuery.expr;
}
