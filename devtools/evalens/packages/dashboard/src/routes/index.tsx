import { createFileRoute } from "@tanstack/react-router";
import { ChevronLeft, ChevronRight, Search, X } from "lucide-react";
import { useCallback, useState } from "react";
import { RunTable } from "../components/RunTable";
import { StatePanel } from "../components/Status";
import { dashboardDataSource } from "../data/source";
import type { LifecycleStatus } from "../data/types";
import { useResource } from "../lib/useResource";
import { useMessages } from "../i18n/locale";

type RunsSearch = {
  page: number;
  experiment?: string;
  status?: LifecycleStatus;
  query?: string;
  tag?: string;
  after?: string;
  param?: string;
};
export const Route = createFileRoute("/")({
  validateSearch: (search: Record<string, unknown>): RunsSearch => ({
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
    ...(typeof search.param === "string" && search.param
      ? { param: search.param }
      : {}),
  }),
  component: RunsPage,
});

function RunsPage() {
  const m = useMessages();
  const navigate = Route.useNavigate();
  const search = Route.useSearch();
  const [draft, setDraft] = useState(search.query ?? "");
  const experiments = useResource(() => dashboardDataSource.listExperiments(), []);
  const load = useCallback(
    () =>
      dashboardDataSource.listRuns({
        page: search.page,
        pageSize: 25,
        experimentName: search.experiment,
        status: search.status,
        query: search.query,
        tag: search.tag,
        createdAfter: search.after ? new Date(search.after).toISOString() : undefined,
        params: parseParamFilter(search.param),
      }),
    [search]
  );
  const runs = useResource(load, [load]);
  const update = (patch: Partial<RunsSearch>) =>
    navigate({ search: (current) => ({ ...current, ...patch }) });
  const clear = () => {
    setDraft("");
    navigate({ search: { page: 1 } });
  };
  return (
    <main className="page-shell">
      <header className="page-heading">
        <div>
          <h1>{m.runs_title()}</h1>
          <p>{m.runs_description()}</p>
        </div>
      </header>
      <form
        className="filter-band runs-filter"
        onSubmit={(event) => {
          event.preventDefault();
          update({ query: draft || undefined, page: 1 });
        }}
      >
        <label className="field">
          <span>{m.common_experiment()}</span>
          <select
            value={search.experiment ?? ""}
            onChange={(e) =>
              update({ experiment: e.target.value || undefined, page: 1 })
            }
          >
            <option value="">{m.runs_all_experiments()}</option>
            {experiments.status === "ready" &&
              experiments.data.map((item) => (
                <option key={item.name} value={item.name}>
                  {item.name} ({item.runCount})
                </option>
              ))}
          </select>
        </label>
        <label className="field">
          <span>{m.common_status()}</span>
          <select
            value={search.status ?? ""}
            onChange={(e) =>
              update({
                status: (e.target.value || undefined) as LifecycleStatus | undefined,
                page: 1,
              })
            }
          >
            <option value="">{m.runs_all_statuses()}</option>
            <option value="finished">{m.status_finished()}</option>
            <option value="running">{m.status_running()}</option>
            <option value="error">{m.status_error()}</option>
          </select>
        </label>
        <label className="field">
          <span>{m.common_tag()}</span>
          <input
            value={search.tag ?? ""}
            onChange={(e) => update({ tag: e.target.value || undefined, page: 1 })}
            placeholder={m.runs_exact_tag()}
          />
        </label>
        <label className="field search-field">
          <span>{m.runs_search_label()}</span>
          <div className="input-action">
            <input
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              placeholder={m.runs_search_placeholder()}
              type="search"
            />
            <button
              aria-label={m.common_search()}
              className="icon-button"
              type="submit"
            >
              <Search size={16} />
            </button>
          </div>
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
          <span>{m.common_run_params()}</span>
          <input
            placeholder={m.runs_run_param_placeholder()}
            value={search.param ?? ""}
            onChange={(event) =>
              update({ param: event.target.value || undefined, page: 1 })
            }
          />
        </label>
        <button className="secondary-button" onClick={clear} type="button">
          <X size={14} /> {m.common_clear()}
        </button>
      </form>
      <section className="list-section">
        <div className="section-heading list-heading">
          <div>
            <h2>{m.runs_title()}</h2>
            <p>
              {runs.status === "ready"
                ? m.common_total({ count: runs.data.total })
                : m.common_loading()}
            </p>
          </div>
        </div>
        {runs.status === "loading" ? (
          <StatePanel title={m.runs_loading()} detail={m.common_please_wait()} />
        ) : runs.status === "error" ? (
          <StatePanel title={m.runs_load_error()} detail={runs.error} />
        ) : runs.data.items.length === 0 ? (
          <StatePanel title={m.runs_empty()} detail={m.runs_empty_detail()} />
        ) : (
          <RunTable runs={runs.data.items} />
        )}
        {runs.status === "ready" && runs.data.total > runs.data.pageSize && (
          <div className="pagination">
            <button
              aria-label={m.runs_previous_page()}
              className="icon-button"
              disabled={runs.data.page <= 1}
              onClick={() => update({ page: runs.data.page - 1 })}
            >
              <ChevronLeft size={16} />
            </button>
            <span>
              {m.common_page({
                page: runs.data.page,
                pages: Math.ceil(runs.data.total / runs.data.pageSize),
              })}
            </span>
            <button
              aria-label={m.runs_next_page()}
              className="icon-button"
              disabled={runs.data.page * runs.data.pageSize >= runs.data.total}
              onClick={() => update({ page: runs.data.page + 1 })}
            >
              <ChevronRight size={16} />
            </button>
          </div>
        )}
      </section>
    </main>
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
