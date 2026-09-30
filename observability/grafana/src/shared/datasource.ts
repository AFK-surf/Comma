import type { DataSourceRef } from "@grafana/grafana-foundation-sdk/common";
import {
  DatasourceVariableBuilder,
  QueryVariableBuilder,
  VariableHide,
  VariableRefresh,
} from "@grafana/grafana-foundation-sdk/dashboard";
import {
  CloudMonitoringQueryBuilder,
  PromQLQueryBuilder,
  QueryType,
  TimeSeriesListBuilder,
} from "@grafana/grafana-foundation-sdk/googlecloudmonitoring";

import {
  datasourceVariableName,
  projectVariableName,
  type DashboardEnvironment,
} from "../environments.js";

// Hidden variables that bind every panel to the installed Cloud Monitoring
// datasource and its project without naming either in the repository.
export function datasourceVariable(): DatasourceVariableBuilder {
  return new DatasourceVariableBuilder(datasourceVariableName)
    .label("Cloud Monitoring datasource")
    .type("stackdriver")
    .hide(VariableHide.HideVariable);
}

export function projectVariable(): QueryVariableBuilder {
  return new QueryVariableBuilder(projectVariableName)
    .label("Cloud Monitoring project")
    .datasource({ type: "stackdriver", uid: `\${${datasourceVariableName}}` })
    .query({ selectedQueryType: "projects", projectName: "" })
    .refresh(VariableRefresh.OnDashboardLoad)
    .hide(VariableHide.HideVariable);
}

export function cloudMonitoringDatasource(
  environment: DashboardEnvironment,
): DataSourceRef {
  return {
    type: "stackdriver",
    uid: environment.datasourceUid,
  };
}

export function promqlQuery(
  environment: DashboardEnvironment,
  refId: string,
  expression: string,
  legend: string,
): CloudMonitoringQueryBuilder {
  return (
    new CloudMonitoringQueryBuilder()
      .refId(refId)
      .queryType(QueryType.PROMQL)
      .aliasBy(legend)
      .datasource(cloudMonitoringDatasource(environment))
      // Grafana Cloud 13.2's Cloud Monitoring backend misclassifies a request
      // containing only promQLQuery as a legacy query. Presence of the SDK's
      // empty TimeSeriesList prevents that migration without executing it.
      // Remove this only after a live /api/ds/query succeeds without the field.
      .timeSeriesList(new TimeSeriesListBuilder())
      .promQLQuery(
        new PromQLQueryBuilder()
          .projectName(environment.project)
          .expr(expression)
          .step("$__interval"),
      )
  );
}
