import { ArrowDown, ArrowUp, Plus, RefreshCw, Trash2 } from "lucide-react";
import { Link } from "@tanstack/react-router";
import { useEffect, useMemo, useState } from "react";
import { MAX_COMPARE_EVALUATIONS } from "@evalens/core/api";
import type { EvalCatalogEntry, EvalComparison, Page } from "../data/types";
import {
  analyzeCatalogCompatibility,
  analyzeCompatibility,
  metricId,
  scoreFor,
} from "../lib/comparison";
import { compactId, formatDate, formatDuration, formatNumber } from "../lib/format";
import { Status } from "./Status";
import { Chart } from "./Chart";
import { formatCompatibilityReasons } from "../i18n/compatibility";
import { useLocale } from "../i18n/locale";
import { m } from "../paraglide/messages.js";

export function CompareView({
  comparison,
  catalog,
  reference,
  onChange,
  onReload,
  filters,
  onFilter,
  onPage,
  onCatalogPage,
}: {
  comparison: EvalComparison;
  catalog: Page<EvalCatalogEntry>;
  reference?: string;
  onChange: (ids: string[], reference?: string) => void;
  onReload: () => void;
  filters: {
    query?: string;
    experiment?: string;
    tag?: string;
    after?: string;
    runParam?: string;
    evalParam?: string;
  };
  onFilter: (filters: Record<string, string | undefined>) => void;
  onPage: (page: number) => void;
  onCatalogPage: (page: number) => void;
}) {
  const { locale } = useLocale();
  const [candidate, setCandidate] = useState("");
  const [message, setMessage] = useState("");
  const [itemSort, setItemSort] = useState("id");
  const ids = comparison.evaluations.map(({ id }) => id);
  const compatibility = useMemo(() => analyzeCompatibility(comparison), [comparison]);
  const candidateCompatibility = useMemo<
    Map<string, { compatible: true } | { compatible: false; reason: string }>
  >(
    () =>
      new Map(
        catalog.items.map((entry) => {
          if (entry.status !== "finished") {
            return [
              entry.id,
              {
                compatible: false,
                reason: m.selection_non_finished({ status: entry.status }),
              },
            ] as const;
          }
          if (ids.length === 0) {
            return [entry.id, { compatible: true }] as const;
          }
          if (ids.length >= MAX_COMPARE_EVALUATIONS) {
            return [
              entry.id,
              {
                compatible: false,
                reason: m.selection_limit({ count: MAX_COMPARE_EVALUATIONS }),
              },
            ] as const;
          }
          const check = analyzeCatalogCompatibility([...comparison.evaluations, entry]);
          return [
            entry.id,
            check.compatible
              ? { compatible: true }
              : {
                  compatible: false,
                  reason: m.compare_cannot({
                    reason: formatCompatibilityReasons(check.reasons),
                  }),
                },
          ] as const;
        })
      ),
    [catalog.items, comparison.evaluations, ids.length, locale]
  );
  useEffect(() => setMessage(""), [locale]);
  const add = () => {
    if (!candidate || ids.includes(candidate)) return;
    setMessage("");
    const check = candidateCompatibility.get(candidate);
    if (!check?.compatible) {
      setMessage(check?.reason ?? m.compare_select_detail());
      return;
    }
    onChange([...ids, candidate], reference);
    setCandidate("");
  };
  const move = (index: number, delta: number) => {
    const next = [...ids];
    const [id] = next.splice(index, 1);
    if (!id) return;
    next.splice(index + delta, 0, id);
    onChange(next, reference);
  };
  const itemRows = commonRows(comparison).sort((left, right) =>
    compareRows(left, right, itemSort, comparison, compatibility.itemMetrics)
  );
  return (
    <main className="page-shell compare-page">
      <header className="page-heading">
        <div>
          <h1>{m.compare_title()}</h1>
          <p>
            {m.compare_summary({
              evaluations: ids.length,
              items: comparison.sharedItemCount,
            })}
          </p>
        </div>
        <button className="secondary-button" onClick={onReload}>
          <RefreshCw size={14} /> {m.common_refresh()}
        </button>
      </header>
      <section className="selector-filters">
        <Filter
          label={m.common_search()}
          placeholder={m.compare_search_placeholder()}
          value={filters.query}
          onChange={(query) => onFilter({ query })}
        />
        <Filter
          label={m.common_experiment()}
          placeholder={m.compare_exact_experiment()}
          value={filters.experiment}
          onChange={(experiment) => onFilter({ experiment })}
        />
        <Filter
          label={m.common_tag()}
          placeholder={m.compare_exact_tag()}
          value={filters.tag}
          onChange={(tag) => onFilter({ tag })}
        />
        <Filter
          label={m.common_created_after()}
          type="datetime-local"
          value={filters.after}
          onChange={(after) => onFilter({ after })}
        />
        <Filter
          label={m.common_run_params()}
          placeholder={m.runs_run_param_placeholder()}
          value={filters.runParam}
          onChange={(runParam) => onFilter({ runParam })}
        />
        <Filter
          label={m.common_eval_params()}
          placeholder={m.evaluations_eval_param_placeholder()}
          value={filters.evalParam}
          onChange={(evalParam) => onFilter({ evalParam })}
        />
      </section>
      <section className="selector-band">
        <label className="field">
          <span>{m.compare_add_finished()}</span>
          <select value={candidate} onChange={(e) => setCandidate(e.target.value)}>
            <option value="">{m.compare_select_placeholder()}</option>
            {groupCatalog(
              catalog.items.filter(
                ({ id, status }) => status === "finished" && !ids.includes(id)
              ),
              candidateCompatibility
            )}
          </select>
        </label>
        <button className="primary-button" disabled={!candidate} onClick={add}>
          <Plus size={14} /> {m.compare_add()}
        </button>
        {message && <span className="error-copy">{message}</span>}
        {catalog.total > catalog.pageSize && (
          <div className="selector-pagination">
            <button
              className="icon-button"
              disabled={catalog.page <= 1}
              onClick={() => onCatalogPage(catalog.page - 1)}
            >
              <ArrowUp size={14} />
            </button>
            <span>
              {catalog.page} / {Math.ceil(catalog.total / catalog.pageSize)}
            </span>
            <button
              className="icon-button"
              disabled={catalog.page * catalog.pageSize >= catalog.total}
              onClick={() => onCatalogPage(catalog.page + 1)}
            >
              <ArrowDown size={14} />
            </button>
          </div>
        )}
      </section>
      {ids.length === 0 ? (
        <div className="state-panel">
          <strong>{m.compare_select_title()}</strong>
          <span>{m.compare_select_detail()}</span>
        </div>
      ) : (
        <>
          <section className="selected-evals">
            {comparison.evaluations.map((evaluation, index) => (
              <div className="selected-eval" key={evaluation.id}>
                <div>
                  <b>{evaluation.run.experimentName}</b>
                  <span>
                    {compactId(evaluation.run.id)} / {compactId(evaluation.id)}
                  </span>
                </div>
                <Status value={evaluation.status} />
                <label>
                  <input
                    checked={reference === evaluation.id}
                    name="reference"
                    onChange={() => onChange(ids, evaluation.id)}
                    type="radio"
                  />{" "}
                  {m.common_reference()}
                </label>
                <button
                  className="icon-button"
                  disabled={index === 0}
                  onClick={() => move(index, -1)}
                  title={m.compare_move_left()}
                >
                  <ArrowUp size={14} />
                </button>
                <button
                  className="icon-button"
                  disabled={index === ids.length - 1}
                  onClick={() => move(index, 1)}
                  title={m.compare_move_right()}
                >
                  <ArrowDown size={14} />
                </button>
                <button
                  className="icon-button"
                  onClick={() =>
                    onChange(
                      ids.filter((id) => id !== evaluation.id),
                      reference === evaluation.id ? undefined : reference
                    )
                  }
                  title={m.common_remove()}
                >
                  <Trash2 size={14} />
                </button>
              </div>
            ))}
          </section>
          {!compatibility.compatible && (
            <div className="compat-warning">
              <b>{m.compare_no_metric()}</b>{" "}
              {formatCompatibilityReasons(compatibility.reasons)}
            </div>
          )}
          {compatibility.aggregateKeys.length > 0 && (
            <section className="content-section">
              <div className="section-heading">
                <h2>{m.eval_aggregate_scores()}</h2>
                <p>{reference ? m.compare_absolute_delta() : m.compare_absolute()}</p>
              </div>
              <div className="aggregate-chart-grid">
                {compatibility.aggregateKeys.map((key) => (
                  <section className="aggregate-chart-card" key={key}>
                    <h3>{key}</h3>
                    <Chart option={aggregateMetricOption(comparison, key, reference)} />
                  </section>
                ))}
              </div>
            </section>
          )}
          {itemRows.length > 0 && (
            <section className="content-section">
              <div className="section-heading controls-heading">
                <div>
                  <h2>{m.compare_item_title()}</h2>
                  <p>{m.compare_item_detail()}</p>
                </div>
                <label className="field compact-field">
                  <span>{m.common_sort()}</span>
                  <select
                    value={itemSort}
                    onChange={(event) => setItemSort(event.target.value)}
                  >
                    <option value="id">{m.compare_sort_item()}</option>
                    <option value="spread">{m.compare_sort_spread()}</option>
                    {comparison.evaluations.flatMap((evaluation) => [
                      <option
                        key={`duration:${evaluation.id}`}
                        value={`duration:${evaluation.id}`}
                      >
                        {m.compare_sort_duration({
                          experiment: compactId(evaluation.id),
                        })}
                      </option>,
                      <option
                        key={`status:${evaluation.id}`}
                        value={`status:${evaluation.id}`}
                      >
                        {m.compare_sort_status({
                          experiment: compactId(evaluation.id),
                        })}
                      </option>,
                      ...compatibility.itemMetrics.map((metric) => (
                        <option
                          key={`score:${evaluation.id}:${metricId(metric)}`}
                          value={`score:${evaluation.id}:${metricId(metric)}`}
                        >
                          {m.compare_sort_score({
                            experiment: compactId(evaluation.id),
                            score: metric.scoreKey,
                          })}
                        </option>
                      )),
                    ])}
                  </select>
                </label>
              </div>
              <div className="table-scroll">
                <table className="data-table compare-table">
                  <thead>
                    <tr>
                      <th>{m.common_item()}</th>
                      {comparison.evaluations.map((evaluation) => (
                        <th key={evaluation.id}>{compactId(evaluation.id)}</th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {itemRows.map((row) => (
                      <tr key={row.id}>
                        <td>
                          <Link
                            className="primary-link"
                            params={{ runId: comparison.evaluations[0]!.run.id }}
                            search={{ eval: comparison.evaluations[0]!.id, page: 1 }}
                            to="/runs/$runId"
                          >
                            {row.id}
                          </Link>
                          <span className="cell-subline mono">{row.digest}</span>
                        </td>
                        {row.items.map((item, index) => (
                          <td key={comparison.evaluations[index]!.id}>
                            {compatibility.itemMetrics.map((metric) => (
                              <span className="score-line" key={metricId(metric)}>
                                {metric.scoreKey}:{" "}
                                <b>
                                  {scoreFor(item, metric) === undefined
                                    ? "-"
                                    : formatNumber(scoreFor(item, metric)!)}
                                </b>
                                {reference &&
                                comparison.evaluations[index]!.id !== reference
                                  ? deltaLabel(
                                      item,
                                      row.items[
                                        comparison.evaluations.findIndex(
                                          ({ id }) => id === reference
                                        )
                                      ],
                                      metric
                                    )
                                  : ""}
                              </span>
                            ))}
                            {item.evaluatorResults.map((result) =>
                              result.message ? (
                                <span
                                  className="result-message"
                                  key={result.evaluatorName}
                                >
                                  {result.message}
                                </span>
                              ) : null
                            )}
                            <span className="cell-subline">
                              {item.status === "completed"
                                ? m.status_completed()
                                : m.status_error()}{" "}
                              · {formatDuration(item.durationMs)}
                            </span>
                          </td>
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </section>
          )}
          {comparison.sharedItemCount > comparison.itemPageSize && (
            <div className="pagination">
              <button
                aria-label={m.eval_previous_items()}
                className="icon-button"
                disabled={comparison.itemPage <= 1}
                onClick={() => onPage(comparison.itemPage - 1)}
              >
                <ArrowUp size={14} />
              </button>
              <span>
                {m.common_page({
                  page: comparison.itemPage,
                  pages: Math.ceil(
                    comparison.sharedItemCount / comparison.itemPageSize
                  ),
                })}
              </span>
              <button
                aria-label={m.eval_next_items()}
                className="icon-button"
                disabled={
                  comparison.itemPage * comparison.itemPageSize >=
                  comparison.sharedItemCount
                }
                onClick={() => onPage(comparison.itemPage + 1)}
              >
                <ArrowDown size={14} />
              </button>
            </div>
          )}
        </>
      )}
    </main>
  );
}

function Filter({
  label,
  value,
  onChange,
  placeholder,
  type = "text",
}: {
  label: string;
  value?: string;
  onChange: (value?: string) => void;
  placeholder?: string;
  type?: string;
}) {
  return (
    <label className="field">
      <span>{label}</span>
      <input
        placeholder={placeholder}
        type={type}
        value={value ?? ""}
        onChange={(event) => onChange(event.target.value || undefined)}
      />
    </label>
  );
}

function groupCatalog(
  entries: EvalCatalogEntry[],
  compatibility: Map<
    string,
    { compatible: true } | { compatible: false; reason: string }
  >
) {
  const groups = new Map<string, EvalCatalogEntry[]>();
  for (const entry of entries) {
    const label = `${entry.run.experimentName} / ${compactId(entry.run.id)}`;
    groups.set(label, [...(groups.get(label) ?? []), entry]);
  }
  return [...groups].map(([label, evaluations]) => (
    <optgroup key={label} label={label}>
      {evaluations.map((entry) => {
        const check = compatibility.get(entry.id);
        const reason = check?.compatible === false ? check.reason : undefined;
        return (
          <option
            disabled={Boolean(reason)}
            key={entry.id}
            title={reason}
            value={entry.id}
          >
            {compactId(entry.id)} · {formatDate(entry.createdAt)}
            {reason ? ` - ${reason}` : ""}
          </option>
        );
      })}
    </optgroup>
  ));
}

function rowSpread(
  row: ReturnType<typeof commonRows>[number],
  metrics: ReturnType<typeof analyzeCompatibility>["itemMetrics"]
) {
  const values = row.items.flatMap((item) =>
    metrics.flatMap((metric) => {
      const value = scoreFor(item, metric);
      return value === undefined ? [] : [value];
    })
  );
  return values.length < 2 ? 0 : Math.max(...values) - Math.min(...values);
}

function compareRows(
  left: ReturnType<typeof commonRows>[number],
  right: ReturnType<typeof commonRows>[number],
  sort: string,
  comparison: EvalComparison,
  metrics: ReturnType<typeof analyzeCompatibility>["itemMetrics"]
) {
  if (sort === "id") return left.id.localeCompare(right.id);
  if (sort === "spread") return rowSpread(right, metrics) - rowSpread(left, metrics);
  const [kind, evalId, ...identityParts] = sort.split(":");
  const index = comparison.evaluations.findIndex(({ id }) => id === evalId);
  if (index < 0) return 0;
  if (kind === "duration")
    return right.items[index]!.durationMs - left.items[index]!.durationMs;
  if (kind === "status")
    return left.items[index]!.status.localeCompare(right.items[index]!.status);
  if (kind === "score") {
    const identity = identityParts.join(":");
    const metric = metrics.find((candidate) => metricId(candidate) === identity);
    if (!metric) return 0;
    return (
      (scoreFor(right.items[index]!, metric) ?? Number.NEGATIVE_INFINITY) -
      (scoreFor(left.items[index]!, metric) ?? Number.NEGATIVE_INFINITY)
    );
  }
  return 0;
}

export function aggregateMetricOption(
  comparison: EvalComparison,
  key: string,
  reference?: string
) {
  const ref = comparison.evaluations.find(({ id }) => id === reference);
  const evaluationLabels = aggregateEvaluationLabels(comparison.evaluations);
  return {
    tooltip: { trigger: "axis", axisPointer: { type: "shadow" } },
    grid: { left: 52, right: 18, top: 20, bottom: 52 },
    xAxis: {
      type: "category",
      data: evaluationLabels,
      axisLabel: { interval: 0, lineHeight: 14 },
    },
    yAxis: { type: "value", scale: true },
    series: [
      {
        name: key,
        type: "bar",
        barMaxWidth: 48,
        data: comparison.evaluations.map((evaluation) => {
          const value = evaluation.aggregateScores[key];
          const referenceValue = ref?.aggregateScores[key];
          const delta =
            value !== undefined && referenceValue !== undefined
              ? value - referenceValue
              : undefined;
          return {
            value,
            itemStyle: {
              opacity: 0.82,
              ...(evaluation.id === reference
                ? { borderColor: "#124e57", borderWidth: 2 }
                : {}),
            },
            label: {
              show: true,
              position: "top",
              formatter:
                value === undefined
                  ? "–"
                  : delta === undefined
                    ? formatNumber(value, 2)
                    : `${formatNumber(value, 2)} (${delta >= 0 ? "+" : ""}${formatNumber(delta, 2)})`,
            },
          };
        }),
      },
    ],
  };
}

export function aggregateEvaluationLabels(
  evaluations: EvalComparison["evaluations"]
): string[] {
  const experimentTokens = evaluations.map(({ run }) =>
    run.experimentName.split("-").filter(Boolean)
  );
  const sharedPrefixLength = commonTokenPrefixLength(experimentTokens);
  const labels = experimentTokens.map((tokens) => {
    const distinguishingTokens = tokens.slice(sharedPrefixLength);
    return axisScenarioLabel(
      distinguishingTokens.length > 0 ? distinguishingTokens : tokens
    );
  });
  const labelCounts = new Map<string, number>();
  for (const label of labels) {
    labelCounts.set(label, (labelCounts.get(label) ?? 0) + 1);
  }
  return labels.map((label, index) =>
    labelCounts.get(label) === 1
      ? label
      : `${label}\n${compactId(evaluations[index]!.id)}`
  );
}

function commonTokenPrefixLength(values: string[][]): number {
  if (values.length === 0) return 0;
  const shortestLength = Math.min(...values.map((value) => value.length));
  let length = 0;
  while (
    length < shortestLength &&
    values.every((value) => value[length] === values[0]![length])
  ) {
    length += 1;
  }
  return length;
}

function axisScenarioLabel(tokens: string[]): string {
  if (tokens.length <= 1) return tokens[0] ?? "evaluation";
  const dimension = tokens.slice(0, -1).join(" ");
  const compactDimension =
    dimension === "preprovisioned worker" ? "with worker" : dimension;
  return `${compactDimension}\n${tokens.at(-1)}`;
}
function commonRows(comparison: EvalComparison) {
  const first = comparison.evaluations[0];
  if (!first) return [];
  const maps = comparison.evaluations.map(
    ({ items }) => new Map(items.map((item) => [item.id, item]))
  );
  return first.items.flatMap((item) => {
    const items = maps.map((map) => map.get(item.id));
    return items.every(Boolean)
      ? [{ id: item.id, digest: item.digest, items: items as typeof first.items }]
      : [];
  });
}
function deltaLabel(
  item: Parameters<typeof scoreFor>[0],
  reference: Parameters<typeof scoreFor>[0] | undefined,
  metric: Parameters<typeof scoreFor>[1]
) {
  if (!reference) return "";
  const value = scoreFor(item, metric);
  const ref = scoreFor(reference, metric);
  if (value === undefined || ref === undefined) return "";
  const delta = value - ref;
  return ` (${delta > 0 ? "+" : ""}${formatNumber(delta)})`;
}
