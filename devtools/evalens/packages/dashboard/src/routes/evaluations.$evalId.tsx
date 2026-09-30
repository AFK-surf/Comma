import { Link, createFileRoute } from "@tanstack/react-router";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { StatePanel, Status } from "../components/Status";
import { dashboardDataSource } from "../data/source";
import {
  compactId,
  formatDate,
  formatDateTitle,
  formatNumber,
  formatParam,
  formatPercent,
  middleEllipsis,
} from "../lib/format";
import { useResource } from "../lib/useResource";
import { AddEvaluationButton } from "../components/AddEvaluationButton";
import { useMessages } from "../i18n/locale";

export const Route = createFileRoute("/evaluations/$evalId")({
  validateSearch: (search: Record<string, unknown>) => ({
    page: Math.max(1, Number(search.page) || 1),
  }),
  component: EvalDetailPage,
});
function EvalDetailPage() {
  const m = useMessages();
  const { evalId } = Route.useParams();
  const { page } = Route.useSearch();
  const navigate = Route.useNavigate();
  const resource = useResource(async () => {
    const evaluation = await dashboardDataSource.getEvaluation(evalId);
    if (!evaluation) return null;
    const items = await dashboardDataSource.listRunItems(
      evaluation.run.id,
      evalId,
      page,
      100
    );
    return { evaluation, items };
  }, [evalId, page]);
  if (resource.status === "loading")
    return (
      <main className="page-shell">
        <StatePanel title={m.eval_loading()} detail={m.common_please_wait()} />
      </main>
    );
  if (resource.status === "error" || !resource.data)
    return (
      <main className="page-shell">
        <StatePanel
          title={m.eval_not_found()}
          detail={resource.status === "error" ? resource.error : evalId}
        />
      </main>
    );
  const { evaluation, items } = resource.data;
  const counts = evaluation.resultCounts;
  return (
    <main className="page-shell">
      <header className="page-heading">
        <div>
          <Link
            className="back-link"
            params={{ runId: evaluation.run.id }}
            search={{ eval: evaluation.id, page: 1 }}
            to="/runs/$runId"
          >
            {m.eval_run_link({ id: compactId(evaluation.run.id) })}
          </Link>
          <h1>{m.eval_title_value({ id: compactId(evaluation.id) })}</h1>
          <p title={formatDateTitle(evaluation.createdAt)}>
            {evaluation.run.experimentName} · {formatDate(evaluation.createdAt)}
          </p>
        </div>
        <div className="heading-actions">
          <Status value={evaluation.status} />
          <AddEvaluationButton entry={evaluation} />
        </div>
      </header>
      <section className="summary-band">
        <dl className="summary-grid">
          <div>
            <dt>{m.common_dataset()}</dt>
            <dd>
              {evaluation.run.datasetName}
              <span
                className="cell-subline mono digest-value"
                title={evaluation.run.datasetDigest}
              >
                {middleEllipsis(evaluation.run.datasetDigest)}
              </span>
            </dd>
          </div>
          <div>
            <dt>{m.eval_aggregator()}</dt>
            <dd>{evaluation.aggregatorVersion}</dd>
          </div>
          <div>
            <dt>{m.eval_evaluators()}</dt>
            <dd>
              {evaluation.evaluators
                .map(({ name, version }) => `${name} v${version}`)
                .join(", ")}
            </dd>
          </div>
          <div>
            <dt>{m.common_eval_params()}</dt>
            <dd>
              {Object.entries(evaluation.params).map(([key, value]) => (
                <span className="score-line" key={key}>
                  {key}: {formatParam(value)}
                </span>
              ))}
            </dd>
          </div>
        </dl>
      </section>
      <section className="content-section">
        <div className="section-heading">
          <h2>{m.eval_aggregate_scores()}</h2>
        </div>
        <div className="metric-row">
          {Object.entries(evaluation.aggregateScores).map(([key, value]) => (
            <div className="metric" key={key}>
              <span>{key}</span>
              <strong>{formatNumber(value)}</strong>
            </div>
          ))}
        </div>
      </section>
      <section className="content-section">
        <div className="section-heading">
          <h2>{m.eval_coverage()}</h2>
          <p>{m.eval_coverage_detail({ count: counts.target })}</p>
        </div>
        <div className="metric-row">
          <div className="metric">
            <span>{m.status_completed()}</span>
            <strong>{counts.completed}</strong>
          </div>
          <div className="metric">
            <span>{m.status_error()}</span>
            <strong>{counts.error}</strong>
          </div>
          <div className="metric">
            <span>{m.status_skipped()}</span>
            <strong>{counts.skipped}</strong>
          </div>
          <div className="metric">
            <span>{m.eval_coverage()}</span>
            <strong>
              {counts.target === 0
                ? "-"
                : formatPercent(counts.completed / counts.target)}
            </strong>
          </div>
        </div>
      </section>
      <section className="content-section">
        <div className="section-heading">
          <h2>{m.eval_item_scores()}</h2>
          <p>{m.eval_run_items_count({ count: items.total })}</p>
        </div>
        <div className="table-scroll">
          <table className="data-table">
            <thead>
              <tr>
                <th>{m.common_item()}</th>
                <th>{m.eval_run_status()}</th>
                {evaluation.evaluators.map(({ name, version }) => (
                  <th key={name}>
                    {name}
                    <span className="cell-subline">v{version}</span>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {items.items.map((item) => (
                <tr key={item.id}>
                  <td>
                    <b>{item.id}</b>
                    <span className="cell-subline mono">{item.digest}</span>
                  </td>
                  <td>
                    {item.status === "completed"
                      ? m.status_completed()
                      : m.status_error()}
                  </td>
                  {evaluation.evaluators.map(({ name }) => {
                    const result = item.evaluatorResults.find(
                      ({ evaluatorName }) => evaluatorName === name
                    );
                    return (
                      <td key={name}>
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
        {items.total > items.pageSize && (
          <div className="pagination">
            <button
              aria-label={m.eval_previous_items()}
              className="icon-button"
              disabled={items.page <= 1}
              onClick={() => navigate({ search: { page: items.page - 1 } })}
            >
              <ChevronLeft size={16} />
            </button>
            <span>
              {m.common_page({
                page: items.page,
                pages: Math.ceil(items.total / items.pageSize),
              })}
            </span>
            <button
              aria-label={m.eval_next_items()}
              className="icon-button"
              disabled={items.page * items.pageSize >= items.total}
              onClick={() => navigate({ search: { page: items.page + 1 } })}
            >
              <ChevronRight size={16} />
            </button>
          </div>
        )}
      </section>
      {evaluation.error && (
        <section className="content-section">
          <div className="inline-empty error-copy">{evaluation.error}</div>
        </section>
      )}
    </main>
  );
}
