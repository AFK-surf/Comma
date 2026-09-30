import * as common from "@grafana/grafana-foundation-sdk/common";
import * as stat from "@grafana/grafana-foundation-sdk/stat";
import * as text from "@grafana/grafana-foundation-sdk/text";
import * as timeseries from "@grafana/grafana-foundation-sdk/timeseries";

import type { DashboardEnvironment } from "../environments.js";
import { cloudMonitoringDatasource, promqlQuery } from "./datasource.js";

export interface QuerySpec {
  readonly refId: string;
  readonly expression: string;
  readonly legend: string;
}

export interface PanelPosition {
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
}

export function statPanel(
  environment: DashboardEnvironment,
  id: number,
  title: string,
  description: string,
  position: PanelPosition,
  queries: readonly QuerySpec[],
  unit = "short",
): stat.PanelBuilder {
  const panel = new stat.PanelBuilder()
    .id(id)
    .title(title)
    .description(description)
    .datasource(cloudMonitoringDatasource(environment))
    .gridPos(position)
    .unit(unit)
    .noValue("No data")
    .reduceOptions(
      new common.ReduceDataOptionsBuilder().calcs(["lastNotNull"]).fields(""),
    );

  for (const query of queries) {
    panel.withTarget(
      promqlQuery(environment, query.refId, query.expression, query.legend),
    );
  }
  return panel;
}

export function timeSeriesPanel(
  environment: DashboardEnvironment,
  id: number,
  title: string,
  description: string,
  position: PanelPosition,
  queries: readonly QuerySpec[],
  unit = "short",
): timeseries.PanelBuilder {
  const panel = new timeseries.PanelBuilder()
    .id(id)
    .title(title)
    .description(description)
    .datasource(cloudMonitoringDatasource(environment))
    .gridPos(position)
    .unit(unit)
    .noValue("No data")
    .lineWidth(1)
    .fillOpacity(12)
    .showPoints(common.VisibilityMode.Never)
    .legend(
      new common.VizLegendOptionsBuilder()
        .displayMode(common.LegendDisplayMode.List)
        .placement(common.LegendPlacement.Bottom)
        .showLegend(true),
    );

  for (const query of queries) {
    panel.withTarget(
      promqlQuery(environment, query.refId, query.expression, query.legend),
    );
  }
  return panel;
}

export function markdownPanel(
  id: number,
  title: string,
  content: string,
  position: PanelPosition,
): text.PanelBuilder {
  return new text.PanelBuilder()
    .id(id)
    .title(title)
    .gridPos(position)
    .mode(text.TextMode.Markdown)
    .content(content);
}
