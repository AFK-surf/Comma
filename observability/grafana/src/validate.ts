import path from "node:path";

import type { DashboardEnvironment } from "./environments.js";

interface DataSourceRef {
  readonly type?: unknown;
  readonly uid?: unknown;
}

interface CloudMonitoringTarget {
  readonly refId?: unknown;
  readonly datasource?: DataSourceRef;
  readonly promQLQuery?: {
    readonly projectName?: unknown;
    readonly expr?: unknown;
  };
  readonly timeSeriesList?: {
    readonly projectName?: unknown;
    readonly crossSeriesReducer?: unknown;
  };
}

interface DashboardPanel {
  readonly id?: unknown;
  readonly datasource?: DataSourceRef;
  readonly targets?: readonly CloudMonitoringTarget[];
}

export interface DashboardJson {
  readonly uid?: unknown;
  readonly title?: unknown;
  readonly panels?: readonly DashboardPanel[];
}

const rejectedMetricNames = [
  "comma_system_telemetry_series_budget",
  "salix_llm_attempts_duration_seconds",
] as const;

export function validateDashboard(
  dashboard: DashboardJson,
  environment: DashboardEnvironment,
  filename: string,
): readonly string[] {
  const errors: string[] = [];
  if (
    typeof dashboard.uid !== "string" ||
    !dashboard.uid.startsWith(`${environment.uidPrefix}-`)
  ) {
    errors.push(
      `${filename}: dashboard UID must start with ${environment.uidPrefix}-`,
    );
  }

  const panelIds = new Set<number>();
  for (const panel of dashboard.panels ?? []) {
    if (typeof panel.id !== "number") {
      errors.push(`${filename}: panel is missing an explicit numeric ID`);
      continue;
    }
    if (panelIds.has(panel.id)) {
      errors.push(`${filename}: duplicate panel ID ${panel.id}`);
    }
    panelIds.add(panel.id);

    const targets = panel.targets ?? [];
    validateDatasource(
      panel.datasource,
      environment,
      `${filename}: panel ${panel.id}`,
      errors,
      targets.length > 0,
    );
    const refIds = new Set<string>();
    for (const target of targets) {
      if (typeof target.refId !== "string" || target.refId.length === 0) {
        errors.push(
          `${filename}: panel ${panel.id} target is missing an explicit refId`,
        );
      } else if (refIds.has(target.refId)) {
        errors.push(
          `${filename}: panel ${panel.id} has duplicate refId ${target.refId}`,
        );
      } else {
        refIds.add(target.refId);
      }

      validateDatasource(
        target.datasource,
        environment,
        `${filename}: panel ${panel.id} target`,
        errors,
        true,
      );
      if (target.promQLQuery !== undefined) {
        if (
          target.timeSeriesList?.projectName !== "" ||
          target.timeSeriesList.crossSeriesReducer !== ""
        ) {
          errors.push(
            `${filename}: panel ${panel.id} PromQL target is missing the Grafana 13.2 migration compatibility marker`,
          );
        }
        const expression = target.promQLQuery.expr;
        if (target.promQLQuery.projectName !== environment.project) {
          errors.push(
            `${filename}: panel ${panel.id} query must use project ${environment.project}`,
          );
        }
        if (typeof expression !== "string" || expression.length === 0) {
          errors.push(
            `${filename}: panel ${panel.id} target is missing PromQL`,
          );
          continue;
        }
        for (const rejectedName of rejectedMetricNames) {
          if (expression.includes(rejectedName)) {
            errors.push(
              `${filename}: panel ${panel.id} uses rejected metric ${rejectedName}`,
            );
          }
        }
        if (!/namespace(?:_name)?="comma"/.test(expression)) {
          errors.push(
            `${filename}: panel ${panel.id} PromQL must explicitly scope the comma namespace`,
          );
        }
      }
    }
  }
  return errors;
}

export function validateInventory(
  dashboards: readonly {
    readonly environment: DashboardEnvironment;
    readonly filename: string;
    readonly dashboard: DashboardJson;
  }[],
): readonly string[] {
  const errors: string[] = [];
  const dashboardUids = new Set<string>();
  for (const entry of dashboards) {
    errors.push(
      ...validateDashboard(entry.dashboard, entry.environment, entry.filename),
    );
    if (typeof entry.dashboard.uid === "string") {
      if (dashboardUids.has(entry.dashboard.uid)) {
        errors.push(`duplicate dashboard UID ${entry.dashboard.uid}`);
      }
      dashboardUids.add(entry.dashboard.uid);
    }
    if (path.isAbsolute(entry.filename)) {
      errors.push(
        `generated inventory path must be relative: ${entry.filename}`,
      );
    }
  }
  return errors;
}

function validateDatasource(
  datasource: DataSourceRef | undefined,
  environment: DashboardEnvironment,
  location: string,
  errors: string[],
  required = false,
): void {
  if (datasource === undefined) {
    if (required) {
      errors.push(
        `${location} must explicitly use stackdriver datasource ${environment.datasourceUid}`,
      );
    }
    return;
  }
  if (
    datasource.type !== "stackdriver" ||
    datasource.uid !== environment.datasourceUid
  ) {
    errors.push(
      `${location} must use stackdriver datasource ${environment.datasourceUid}`,
    );
  }
}
