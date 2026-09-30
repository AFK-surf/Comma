import { Link, createFileRoute } from "@tanstack/react-router";
import { ChevronLeft, ChevronRight, Search, X } from "lucide-react";
import { useCallback, useState } from "react";
import { AddEvaluationButton } from "../components/AddEvaluationButton";
import { StatePanel, Status } from "../components/Status";
import { dashboardDataSource } from "../data/source";
import type { LifecycleStatus } from "../data/types";
import {
  compactId,
  formatDate,
  formatDateTitle,
  formatNumber,
  formatParam,
} from "../lib/format";
import { useResource } from "../lib/useResource";
import { useMessages } from "../i18n/locale";

type EvaluationsSearch = {
  page: number;
  experiment?: string;
  status?: LifecycleStatus;
  query?: string;
  tag?: string;
  after?: string;
  before?: string;
  runParam?: string;
  evalParam?: string;
};
export const Route = createFileRoute("/evaluations/")({
  validateSearch: (search: Record<string, unknown>): EvaluationsSearch => ({
    page: Math.max(1, Number(search.page) || 1),
    ...(typeof search.experiment === "string" && search.experiment
      ? { experiment: search.experiment }
      : {}),
    ...(search.status === "running" ||
    search.status === "finished" ||
    search.status === "error"
      ? { status: search.status }
      : {}),
    ...(typeof search.query === "string" && search.query
      ? { query: search.query }
      : {}),
    ...(typeof search.tag === "string" && search.tag ? { tag: search.tag } : {}),
    ...(typeof search.after === "string" && search.after
      ? { after: search.after }
      : {}),
    ...(typeof search.before === "string" && search.before
      ? { before: search.before }
      : {}),
    ...(typeof search.runParam === "string" && search.runParam
      ? { runParam: search.runParam }
      : {}),
    ...(typeof search.evalParam === "string" && search.evalParam
      ? { evalParam: search.evalParam }
      : {}),
  }),
  component: EvaluationsPage,
});

function EvaluationsPage() {
  const m = useMessages();
  const search = Route.useSearch();
  const navigate = Route.useNavigate();
  const [draft, setDraft] = useState(search.query ?? "");
  const experiments = useResource(() => dashboardDataSource.listExperiments(), []);
  const load = useCallback(
    () =>
      dashboardDataSource.listEvaluations({
        page: search.page,
        pageSize: 25,
        experimentName: search.experiment,
        status: search.status,
        query: search.query,
        tag: search.tag,
        createdAfter: search.after ? new Date(search.after).toISOString() : undefined,
        createdBefore: search.before
          ? new Date(search.before).toISOString()
          : undefined,
        runParams: parseParamFilter(search.runParam),
        evalParams: parseParamFilter(search.evalParam),
      }),
    [search]
  );
  const evaluations = useResource(load, [load]);
  const update = (patch: Partial<EvaluationsSearch>) =>
    navigate({ search: (current) => ({ ...current, ...patch }) });
  return (
    <main className="page-shell">
      <header className="page-heading">
        <div>
          <h1>{m.evaluations_title()}</h1>
          <p>{m.evaluations_description()}</p>
        </div>
      </header>
      <form
        className="evaluation-filter-band"
        onSubmit={(event) => {
          event.preventDefault();
          update({ query: draft || undefined, page: 1 });
        }}
      >
        <label className="field">
          <span>{m.common_experiment()}</span>
          <select
            value={search.experiment ?? ""}
            onChange={(event) =>
              update({ experiment: event.target.value || undefined, page: 1 })
            }
          >
            <option value="">{m.evaluations_all_experiments()}</option>
            {experiments.status === "ready" &&
              experiments.data.map((item) => (
                <option key={item.name} value={item.name}>
                  {item.name}
                </option>
              ))}
          </select>
        </label>
        <label className="field">
          <span>{m.common_status()}</span>
          <select
            value={search.status ?? ""}
            onChange={(event) =>
              update({
                status: (event.target.value || undefined) as
                  LifecycleStatus | undefined,
                page: 1,
              })
            }
          >
            <option value="">{m.evaluations_all_statuses()}</option>
            <option value="finished">{m.status_finished()}</option>
            <option value="running">{m.status_running()}</option>
            <option value="error">{m.status_error()}</option>
          </select>
        </label>
        <label className="field">
          <span>{m.common_tag()}</span>
          <input
            value={search.tag ?? ""}
            onChange={(event) =>
              update({ tag: event.target.value || undefined, page: 1 })
            }
            placeholder={m.evaluations_exact_tag()}
          />
        </label>
        <label className="field">
          <span>{m.common_created_after()}</span>
          <input
            type="datetime-local"
            value={search.after ?? ""}
            onChange={(event) =>
              update({ after: event.target.value || undefined, page: 1 })
            }
          />
        </label>
        <label className="field">
          <span>{m.common_created_before()}</span>
          <input
            type="datetime-local"
            value={search.before ?? ""}
            onChange={(event) =>
              update({ before: event.target.value || undefined, page: 1 })
            }
          />
        </label>
        <label className="field">
          <span>{m.common_run_params()}</span>
          <input
            value={search.runParam ?? ""}
            onChange={(event) =>
              update({ runParam: event.target.value || undefined, page: 1 })
            }
            placeholder={m.runs_run_param_placeholder()}
          />
        </label>
        <label className="field">
          <span>{m.common_eval_params()}</span>
          <input
            value={search.evalParam ?? ""}
            onChange={(event) =>
              update({ evalParam: event.target.value || undefined, page: 1 })
            }
            placeholder={m.evaluations_eval_param_placeholder()}
          />
        </label>
        <label className="field search-field">
          <span>{m.evaluations_search_label()}</span>
          <div className="input-action">
            <input
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              placeholder={m.evaluations_search_placeholder()}
            />
            <button
              aria-label={m.evaluations_search_action()}
              className="icon-button"
              type="submit"
            >
              <Search size={15} />
            </button>
          </div>
        </label>
        <button
          className="secondary-button"
          onClick={() => {
            setDraft("");
            navigate({ search: { page: 1 } });
          }}
          type="button"
        >
          <X size={14} /> {m.common_clear()}
        </button>
      </form>
      <section className="list-section">
        <div className="section-heading">
          <h2>{m.evaluations_all()}</h2>
          <p>
            {evaluations.status === "ready"
              ? m.common_total({ count: evaluations.data.total })
              : m.common_loading()}
          </p>
        </div>
        {evaluations.status === "loading" ? (
          <StatePanel title={m.evaluations_loading()} detail={m.common_please_wait()} />
        ) : evaluations.status === "error" ? (
          <StatePanel title={m.evaluations_load_error()} detail={evaluations.error} />
        ) : evaluations.data.items.length === 0 ? (
          <StatePanel
            title={m.evaluations_empty()}
            detail={m.evaluations_empty_detail()}
          />
        ) : (
          <div className="table-scroll">
            <table className="data-table evaluations-table">
              <thead>
                <tr>
                  <th>{m.evaluations_table_run()}</th>
                  <th>{m.common_evaluation()}</th>
                  <th>{m.common_status()}</th>
                  <th>{m.common_versions()}</th>
                  <th>{m.common_run_params()}</th>
                  <th>{m.common_eval_params()}</th>
                  <th>{m.evaluations_table_scores()}</th>
                  <th>{m.common_created()}</th>
                  <th>{m.common_compare()}</th>
                </tr>
              </thead>
              <tbody>
                {evaluations.data.items.map((evaluation) => (
                  <tr key={evaluation.id}>
                    <td>
                      <b>{evaluation.run.experimentName}</b>
                      <span className="cell-subline mono" title={evaluation.run.id}>
                        {compactId(evaluation.run.id)}
                      </span>
                    </td>
                    <td>
                      <Link
                        className="primary-link mono"
                        params={{ evalId: evaluation.id }}
                        search={{ page: 1 }}
                        to="/evaluations/$evalId"
                      >
                        {compactId(evaluation.id)}
                      </Link>
                    </td>
                    <td>
                      <Status value={evaluation.status} />
                    </td>
                    <td>
                      <span className="score-line">
                        {m.eval_aggregator()}{" "}
                        {m.common_version_value({
                          version: evaluation.aggregatorVersion,
                        })}
                      </span>
                      {evaluation.evaluators.map(({ name, version }) => (
                        <span className="cell-subline" key={name}>
                          {name} v{version}
                        </span>
                      ))}
                    </td>
                    <td>
                      <Params values={evaluation.run.params} />
                    </td>
                    <td>
                      <Params values={evaluation.params} />
                    </td>
                    <td>
                      {Object.entries(evaluation.aggregateScores).map(
                        ([key, value]) => (
                          <span className="score-line" key={key}>
                            {key} <b>{formatNumber(value)}</b>
                          </span>
                        )
                      )}
                    </td>
                    <td
                      className="nowrap"
                      title={formatDateTitle(evaluation.createdAt)}
                    >
                      {formatDate(evaluation.createdAt)}
                    </td>
                    <td>
                      <AddEvaluationButton compact entry={evaluation} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {evaluations.status === "ready" &&
          evaluations.data.total > evaluations.data.pageSize && (
            <div className="pagination">
              <button
                aria-label={m.evaluations_previous_page()}
                className="icon-button"
                disabled={evaluations.data.page <= 1}
                onClick={() => update({ page: evaluations.data.page - 1 })}
              >
                <ChevronLeft size={16} />
              </button>
              <span>
                {m.common_page({
                  page: evaluations.data.page,
                  pages: Math.ceil(evaluations.data.total / evaluations.data.pageSize),
                })}
              </span>
              <button
                aria-label={m.evaluations_next_page()}
                className="icon-button"
                disabled={
                  evaluations.data.page * evaluations.data.pageSize >=
                  evaluations.data.total
                }
                onClick={() => update({ page: evaluations.data.page + 1 })}
              >
                <ChevronRight size={16} />
              </button>
            </div>
          )}
      </section>
    </main>
  );
}

function Params({ values }: { values: Record<string, unknown> }) {
  return (
    <div className="param-list">
      {Object.entries(values).map(([key, value]) => (
        <span key={key}>
          <b>{key}</b> {formatParam(value)}
        </span>
      ))}
    </div>
  );
}
function parseParamFilter(value?: string) {
  if (!value) return undefined;
  const separator = value.indexOf("=");
  if (separator <= 0) return undefined;
  const key = value.slice(0, separator);
  const raw = value.slice(separator + 1);
  if (raw === "null") return { [key]: null };
  if (raw === "true" || raw === "false") return { [key]: raw === "true" };
  const number = Number(raw);
  return { [key]: raw !== "" && Number.isFinite(number) ? number : raw };
}
