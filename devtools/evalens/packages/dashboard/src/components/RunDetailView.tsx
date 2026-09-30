import { Link, useNavigate } from "@tanstack/react-router";
import { ChevronLeft, ChevronRight, Download } from "lucide-react";
import { useMemo, useState } from "react";
import type { EvalCatalogEntry, RunDetail } from "../data/types";
import {
  aggregateMetricIdentityKey,
  parseAggregateMetricIdentityKey,
} from "@evalens/core/api";
import {
  compactId,
  formatDate,
  formatDateTitle,
  formatDuration,
  formatNumber,
  formatParam,
  middleEllipsis,
} from "../lib/format";
import { Status } from "./Status";
import { Chart } from "./Chart";
import { AddEvaluationButton } from "./AddEvaluationButton";
import { AggregateMetrics } from "./AggregateMetrics";
import { useLocale } from "../i18n/locale";
import { m } from "../paraglide/messages.js";

export function RunDetailView({ detail }: { detail: RunDetail }) {
  useLocale();
  const navigate = useNavigate();
  const [historyFilter, setHistoryFilter] = useState("");
  const selectedEval = detail.evaluations.find(
    ({ id }) => id === detail.selectedEvalId
  );
  const selectedEntry: EvalCatalogEntry | undefined = selectedEval
    ? {
        ...selectedEval,
        run: {
          id: detail.run.id,
          experimentName: detail.run.experimentName,
          datasetName: detail.run.datasetName,
          datasetDigest: detail.run.datasetDigest,
          datasetSelectionDigest: detail.run.datasetSelectionDigest,
          tags: detail.run.tags,
          params: detail.run.params,
          createdAt: detail.run.createdAt,
        },
      }
    : undefined;
  const evaluatorColumns = selectedEval?.evaluators ?? [];
  const root = `/api/results/downloads/experiments/${encodeURIComponent(detail.run.experimentName)}/runs/${encodeURIComponent(detail.run.id)}`;
  const filteredHistory = useMemo(() => {
    const query = historyFilter.trim().toLowerCase();
    if (!query) return detail;
    return {
      ...detail,
      evaluations: detail.evaluations.filter((evaluation) =>
        JSON.stringify({
          createdAt: evaluation.createdAt,
          params: evaluation.params,
          adapters: evaluation.adapters,
          evaluators: evaluation.evaluators,
        })
          .toLowerCase()
          .includes(query)
      ),
    };
  }, [detail, historyFilter]);
  const goItems = (page: number) =>
    navigate({
      to: "/runs/$runId",
      params: { runId: detail.run.id },
      search: { eval: detail.selectedEvalId, page },
    });
  return (
    <main className="page-shell">
      <header className="page-heading compact-heading">
        <div>
          <Link className="back-link" search={{ page: 1 }} to="/">
            {m.nav_runs()}
          </Link>
          <h1>{detail.run.experimentName}</h1>
          <p className="mono">{detail.run.id}</p>
        </div>
        <Status value={detail.run.status} />
      </header>
      <section className="summary-band">
        <dl className="summary-grid">
          <div>
            <dt>{m.common_dataset()}</dt>
            <dd>
              {detail.run.datasetName}
              <span
                className="cell-subline mono digest-value"
                title={detail.run.datasetDigest}
              >
                {middleEllipsis(detail.run.datasetDigest)}
              </span>
            </dd>
          </div>
          <div>
            <dt>{m.common_created()}</dt>
            <dd title={formatDateTitle(detail.run.createdAt)}>
              {formatDate(detail.run.createdAt)}
            </dd>
          </div>
          <div>
            <dt>{m.common_updated()}</dt>
            <dd title={formatDateTitle(detail.run.updatedAt)}>
              {formatDate(detail.run.updatedAt)}
            </dd>
          </div>
          <div>
            <dt>{m.common_items()}</dt>
            <dd>
              {m.runs_item_counts({
                completed: detail.run.itemCounts.completed,
                errors: detail.run.itemCounts.error,
              })}
            </dd>
          </div>
          <div>
            <dt>{m.common_run_params()}</dt>
            <dd className="inline-values">
              {Object.entries(detail.run.params).map(([key, value]) => (
                <span key={key}>
                  <b>{key}</b> {formatParam(value)}
                </span>
              ))}
            </dd>
          </div>
          <div>
            <dt>{m.run_adapters()}</dt>
            <dd className="inline-values">
              {detail.run.adapters.map(({ name, version }) => (
                <span key={name}>
                  <b>{name}</b> v{version}
                </span>
              ))}
            </dd>
          </div>
        </dl>
      </section>
      <section className="content-section">
        <div className="section-heading controls-heading">
          <div>
            <h2>{m.run_evaluations()}</h2>
            <p>{m.common_recorded({ count: detail.evaluationTotal })}</p>
          </div>
          {selectedEntry && <AddEvaluationButton entry={selectedEntry} />}
        </div>
        {detail.evaluations.length > 0 && (
          <div className="evaluation-layout">
            <div className="evaluation-list">
              {detail.evaluations.map((evaluation) => (
                <button
                  className={
                    evaluation.id === selectedEval?.id ? "eval-row active" : "eval-row"
                  }
                  key={evaluation.id}
                  onClick={() =>
                    navigate({
                      to: "/runs/$runId",
                      params: { runId: detail.run.id },
                      search: { eval: evaluation.id, page: 1 },
                    })
                  }
                >
                  <span>
                    <b>{compactId(evaluation.id)}</b>
                    <small title={formatDateTitle(evaluation.createdAt)}>
                      {formatDate(evaluation.createdAt)}
                    </small>
                  </span>
                  <Status value={evaluation.status} />
                </button>
              ))}
            </div>
            <div className="evaluation-main">
              {selectedEval && (
                <>
                  <div className="evaluation-strip">
                    <Status value={selectedEval.status} />
                    <Link
                      className="primary-link"
                      params={{ evalId: selectedEval.id }}
                      search={{ page: 1 }}
                      to="/evaluations/$evalId"
                    >
                      {m.run_open_evaluation()}
                    </Link>
                    <span>
                      {m.eval_aggregator()} <b>{selectedEval.aggregatorVersion}</b>
                    </span>
                    {Object.entries(selectedEval.params).map(([key, value]) => (
                      <span key={key}>
                        <b>{key}</b> {formatParam(value)}
                      </span>
                    ))}
                  </div>
                  <AggregateMetrics scores={selectedEval.aggregateScores} />
                </>
              )}
            </div>
          </div>
        )}
      </section>
      {detail.evaluations.length > 1 && (
        <section className="content-section">
          <div className="section-heading controls-heading">
            <div>
              <h2>{m.run_history()}</h2>
              <p>{m.run_history_detail()}</p>
            </div>
            <label className="field compact-field">
              <span>{m.run_history_filter()}</span>
              <input
                value={historyFilter}
                onChange={(event) => setHistoryFilter(event.target.value)}
                placeholder={m.run_history_placeholder()}
              />
            </label>
          </div>
          <Chart option={historyOption(filteredHistory)} />
        </section>
      )}
      <section className="content-section">
        <div className="section-heading">
          <h2>{m.run_items()}</h2>
          <p>{m.run_items_count({ count: detail.items.total })}</p>
        </div>
        <div className="table-scroll">
          <table className="data-table item-table">
            <thead>
              <tr>
                <th>{m.common_item()}</th>
                <th>{m.run_result_status()}</th>
                <th>{m.run_duration()}</th>
                <th>{m.run_data()}</th>
                {evaluatorColumns.map((e) => (
                  <th key={e.name}>
                    {e.name}
                    <span className="cell-subline">v{e.version}</span>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {detail.items.items.map((item) => (
                <tr key={item.id}>
                  <td>
                    <b>{item.id}</b>
                    <span className="cell-subline mono">{item.digest}</span>
                  </td>
                  <td>
                    <Status
                      value={item.status === "completed" ? "finished" : "error"}
                    />
                    {item.error && (
                      <span className="cell-subline error-copy">{item.error}</span>
                    )}
                  </td>
                  <td>{formatDuration(item.durationMs)}</td>
                  <td>
                    <div className="download-links">
                      <Link
                        search={{
                          src: `${root}/items/${encodeURIComponent(item.id)}/run-result`,
                          title: m.run_viewer_title({
                            id: item.id,
                            kind: m.run_result(),
                          }),
                          kind: "json",
                        }}
                        to="/viewer"
                      >
                        {m.run_result()}
                      </Link>
                      <Link
                        params={{ runId: detail.run.id, itemId: item.id }}
                        search={{
                          lane: [],
                          q: "",
                          matchesOnly: false,
                          raw: false,
                        }}
                        to="/runs/$runId/items/$itemId/trajectory"
                      >
                        {m.run_trajectory()}
                      </Link>
                      <Link
                        search={{
                          src: `${root}/items/${encodeURIComponent(item.id)}/log`,
                          title: m.run_viewer_title({
                            id: item.id,
                            kind: m.run_log(),
                          }),
                          kind: "log",
                        }}
                        to="/viewer"
                      >
                        {m.run_log()}
                      </Link>
                      <a href={`${root}/items/${encodeURIComponent(item.id)}/artifact`}>
                        <Download size={12} /> {m.run_artifact()}
                      </a>
                      <Link
                        search={{
                          src: `${root}/items/${encodeURIComponent(item.id)}/artifact/metadata`,
                          title: m.run_viewer_title({
                            id: item.id,
                            kind: m.run_artifact_metadata(),
                          }),
                          kind: "json",
                        }}
                        to="/viewer"
                      >
                        {m.run_metadata()}
                      </Link>
                      {selectedEval && (
                        <>
                          <Link
                            search={{
                              src: `${root}/evals/${selectedEval.id}/items/${encodeURIComponent(item.id)}/results`,
                              title: m.run_viewer_title({
                                id: item.id,
                                kind: m.run_eval_result(),
                              }),
                              kind: "json",
                            }}
                            to="/viewer"
                          >
                            {m.run_eval_result()}
                          </Link>
                          <Link
                            search={{
                              src: `${root}/evals/${selectedEval.id}/items/${encodeURIComponent(item.id)}/log`,
                              title: m.run_viewer_title({
                                id: item.id,
                                kind: m.run_eval_log(),
                              }),
                              kind: "log",
                            }}
                            to="/viewer"
                          >
                            {m.run_eval_log()}
                          </Link>
                        </>
                      )}
                    </div>
                  </td>
                  {evaluatorColumns.map((e) => {
                    const result = item.evaluatorResults.find(
                      (r) => r.evaluatorName === e.name
                    );
                    return (
                      <td key={e.name}>
                        {result ? (
                          <>
                            <span className={`result-label result-${result.status}`}>
                              {result.status === "completed"
                                ? m.status_completed()
                                : result.status === "skipped"
                                  ? m.status_skipped()
                                  : m.status_error()}
                            </span>
                            {Object.entries(result.scores).map(([key, value]) => (
                              <span className="score-line" key={key}>
                                {key} <b>{formatNumber(value)}</b>
                              </span>
                            ))}
                            {result.message && (
                              <span className="result-message">{result.message}</span>
                            )}
                          </>
                        ) : (
                          "-"
                        )}
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {detail.items.total > detail.items.pageSize && (
          <div className="pagination">
            <button
              aria-label={m.eval_previous_items()}
              className="icon-button"
              disabled={detail.items.page <= 1}
              onClick={() => goItems(detail.items.page - 1)}
            >
              <ChevronLeft size={16} />
            </button>
            <span>
              {m.common_page({
                page: detail.items.page,
                pages: Math.ceil(detail.items.total / detail.items.pageSize),
              })}
            </span>
            <button
              aria-label={m.eval_next_items()}
              className="icon-button"
              disabled={detail.items.page * detail.items.pageSize >= detail.items.total}
              onClick={() => goItems(detail.items.page + 1)}
            >
              <ChevronRight size={16} />
            </button>
          </div>
        )}
      </section>
    </main>
  );
}

function historyOption(detail: RunDetail) {
  const evaluations = [...detail.evaluations].sort(
    (a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime()
  );
  const aggregateIdentities = [
    ...new Set(
      evaluations.flatMap(({ aggregateScores, aggregatorVersion }) =>
        Object.keys(aggregateScores).map((scoreKey) =>
          aggregateMetricIdentityKey({ aggregatorVersion, scoreKey })
        )
      )
    ),
  ];
  return {
    tooltip: { trigger: "axis" },
    legend: { type: "scroll", top: 8 },
    grid: { left: 52, right: 24, top: 50, bottom: 50 },
    xAxis: {
      type: "category",
      data: evaluations.map(({ createdAt }) => formatDate(createdAt)),
      axisLabel: { rotate: 20 },
    },
    yAxis: { type: "value", scale: true },
    series: aggregateIdentities.map((identity) => {
      const { aggregatorVersion, scoreKey } = parseAggregateMetricIdentityKey(identity);
      return {
        name: m.chart_aggregate_series({
          version: aggregatorVersion,
          score: scoreKey,
        }),
        type: "line",
        connectNulls: false,
        data: evaluations.map((evaluation) =>
          evaluation.status === "finished" &&
          evaluation.aggregatorVersion === aggregatorVersion
            ? (evaluation.aggregateScores[scoreKey] ?? null)
            : null
        ),
      };
    }),
  };
}
