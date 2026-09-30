import { useMemo, useState } from "react";

import { formatNumber } from "../lib/format";
import { m } from "../paraglide/messages.js";

type MetricEntry = {
  key: string;
  label: string;
  value: number;
};

type MetricGroup = {
  id: string;
  title: string;
  metrics: MetricEntry[];
};

export function AggregateMetrics({ scores }: { scores: Record<string, number> }) {
  const [filter, setFilter] = useState("");
  const groups = useMemo(() => groupMetrics(scores, filter), [filter, scores]);
  const metricCount = Object.keys(scores).length;
  const visibleMetricCount = groups.reduce(
    (count, group) => count + group.metrics.length,
    0
  );

  return (
    <div className="aggregate-metrics">
      <div className="metric-toolbar">
        <div>
          <h3>{m.eval_aggregate_scores()}</h3>
          <p>
            {m.run_metric_count({ count: metricCount })}
            {filter && visibleMetricCount !== metricCount
              ? ` · ${m.run_metric_visible({ count: visibleMetricCount })}`
              : ""}
          </p>
        </div>
        {metricCount > 8 && (
          <label className="field metric-filter">
            <span>{m.run_metric_filter()}</span>
            <input
              value={filter}
              onChange={(event) => setFilter(event.target.value)}
              placeholder={m.run_metric_filter_placeholder()}
            />
          </label>
        )}
      </div>
      {groups.length > 0 ? (
        <div className="metric-groups">
          {groups.map((group) => (
            <section className="metric-group" key={group.id}>
              <h4>{group.title}</h4>
              <div className="metric-group-grid">
                {group.metrics.map((metric) => (
                  <div className="metric-card" key={metric.key} title={metric.key}>
                    <span>{metric.label}</span>
                    <strong>{formatNumber(metric.value)}</strong>
                  </div>
                ))}
              </div>
            </section>
          ))}
        </div>
      ) : (
        <p className="metric-empty">{m.run_metric_empty()}</p>
      )}
    </div>
  );
}

export function groupMetrics(
  scores: Record<string, number>,
  filter = ""
): MetricGroup[] {
  const query = filter.trim().toLocaleLowerCase();
  const families = new Map<
    string,
    Array<{ key: string; parts: string[]; value: number }>
  >();

  for (const [key, value] of Object.entries(scores).sort(([left], [right]) =>
    left.localeCompare(right)
  )) {
    if (query && !key.toLocaleLowerCase().includes(query)) continue;
    const [family = key, ...parts] = key.split("_").filter(Boolean);
    const metrics = families.get(family) ?? [];
    metrics.push({ key, parts, value });
    families.set(family, metrics);
  }

  return [...families.entries()].map(([family, metrics]) => {
    const sharedSecond = metrics[0]?.parts[0];
    const promoteSecond =
      metrics.length > 1 &&
      sharedSecond !== undefined &&
      metrics.every((metric) => metric.parts[0] === sharedSecond);
    const titleParts = promoteSecond ? [family, sharedSecond] : [family];

    return {
      id: family,
      title: humanizeMetric(titleParts.join("_")),
      metrics: metrics.map((metric) => {
        const labelParts = metric.parts.slice(promoteSecond ? 1 : 0);
        return {
          key: metric.key,
          label: humanizeMetric(
            labelParts.length > 0 ? labelParts.join("_") : metric.key
          ),
          value: metric.value,
        };
      }),
    };
  });
}

function humanizeMetric(value: string): string {
  const text = value.replaceAll("_", " ");
  return text ? `${text[0]!.toUpperCase()}${text.slice(1)}` : value;
}
