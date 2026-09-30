import { Link, createFileRoute, useNavigate } from "@tanstack/react-router";
import { Download } from "lucide-react";
import { useEffect, useState } from "react";
import { StatePanel } from "../components/Status";
import { dashboardDataSource } from "../data/source";
import { m } from "../paraglide/messages.js";
import { useLocale } from "../i18n/locale";
import {
  TrajectoryViewer,
  type TrajectoryMode,
  type TrajectoryViewState,
} from "../trajectory/TrajectoryViewer";
import {
  defaultTrajectoryMode,
  formatTrajectoryParseError,
  parseTrajectories,
  type ParsedTrajectories,
} from "../trajectory/model";

type TrajectorySearch = {
  mode?: TrajectoryMode;
  lane: string[];
  q: string;
  matchesOnly: boolean;
  raw: boolean;
};

export const Route = createFileRoute("/runs/$runId_/items/$itemId/trajectory")({
  validateSearch: (search: Record<string, unknown>): TrajectorySearch => ({
    mode:
      search.mode === "merged" || search.mode === "grouped" ? search.mode : undefined,
    lane: Array.isArray(search.lane)
      ? search.lane.filter((value): value is string => typeof value === "string")
      : typeof search.lane === "string"
        ? [search.lane]
        : [],
    q: typeof search.q === "string" ? search.q : "",
    matchesOnly: search.matchesOnly === true || search.matchesOnly === "true",
    raw: search.raw === true || search.raw === "true",
  }),
  component: TrajectoryRoute,
});

type LoadState =
  | { status: "loading" }
  | { status: "empty"; src: string }
  | { status: "not-found" }
  | {
      status: "ready";
      parsed: ParsedTrajectories;
      rawValue: unknown;
      src: string;
    }
  | { status: "error"; error: string; src?: string };

function TrajectoryRoute() {
  useLocale();
  const { runId, itemId } = Route.useParams();
  const search = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });
  const [state, setState] = useState<LoadState>({ status: "loading" });

  useEffect(() => {
    const controller = new AbortController();
    setState({ status: "loading" });
    void loadTrajectories(runId, itemId, controller.signal).then(
      (result) =>
        setState(
          result === null
            ? { status: "not-found" }
            : result.parsed.trajectories.length === 0
              ? { status: "empty", src: result.src }
              : { status: "ready", ...result }
        ),
      (error: unknown) =>
        setState({
          status: "error",
          error: error instanceof Error ? error.message : String(error),
          src:
            error && typeof error === "object" && "src" in error
              ? String(error.src)
              : undefined,
        })
    );
    return () => controller.abort();
  }, [runId, itemId]);

  useEffect(() => {
    if (state.status !== "ready" || (search.mode && search.lane.length > 0)) return;
    const mode = search.mode ?? defaultTrajectoryMode(state.parsed.trajectories.length);
    const lane = search.lane.length
      ? search.lane
      : state.parsed.trajectories.slice(0, 4).map(({ id }) => id);
    void navigate({
      search: {
        mode,
        lane,
        q: search.q,
        matchesOnly: search.matchesOnly,
        raw: search.raw,
      },
      replace: true,
    });
  }, [navigate, search, state]);

  const updateSearch = (next: TrajectoryViewState) =>
    navigate({
      search: {
        mode: next.mode,
        lane: next.lanes,
        q: next.query,
        matchesOnly: next.matchesOnly,
        raw: next.raw,
      },
      replace: true,
    });

  return (
    <main className="page-shell trajectory-page">
      <header className="page-heading compact-heading trajectory-heading">
        <div>
          <Link
            className="back-link"
            params={{ runId }}
            search={{ page: 1 }}
            to="/runs/$runId"
          >
            {m.trajectory_back()}
          </Link>
          <h1>{m.trajectory_title()}</h1>
          <p>
            <span className="mono">{runId}</span> /{" "}
            <span className="mono">{itemId}</span>
          </p>
        </div>
        {(state.status === "ready" ||
          state.status === "empty" ||
          state.status === "error") &&
          state.src && (
            <a className="secondary-button" href={state.src}>
              <Download size={14} /> {m.trajectory_download()}
            </a>
          )}
      </header>
      {state.status === "loading" ? (
        <StatePanel
          title={m.trajectory_loading()}
          detail={m.trajectory_loading_detail()}
        />
      ) : state.status === "empty" ? (
        <StatePanel
          title={m.trajectory_missing()}
          detail={m.trajectory_missing_detail()}
        />
      ) : state.status === "not-found" ? (
        <StatePanel
          title={m.trajectory_item_missing()}
          detail={m.trajectory_item_missing_detail()}
        />
      ) : state.status === "error" ? (
        <section className="trajectory-parse-error">
          <StatePanel
            title={m.trajectory_error()}
            detail={m.trajectory_error_detail()}
          />
          <pre>{state.error}</pre>
        </section>
      ) : (
        <TrajectoryViewer
          parsed={state.parsed}
          rawValue={state.rawValue}
          state={{
            mode:
              search.mode ?? defaultTrajectoryMode(state.parsed.trajectories.length),
            lanes: search.lane,
            query: search.q,
            matchesOnly: search.matchesOnly,
            raw: search.raw,
          }}
          onStateChange={updateSearch}
        />
      )}
    </main>
  );
}

async function loadTrajectories(runId: string, itemId: string, signal: AbortSignal) {
  const run = await dashboardDataSource.getRun(runId);
  if (!run) throw new Error(m.run_not_found());
  const src = `/api/results/downloads/experiments/${encodeURIComponent(run.experimentName)}/runs/${encodeURIComponent(runId)}/items/${encodeURIComponent(itemId)}/trajectories`;
  const response = await fetch(src, { signal });
  if (response.status === 404) return null;
  if (!response.ok) {
    throw Object.assign(
      new Error(m.trajectory_request_failed({ status: response.status })),
      { src }
    );
  }
  const text = await response.text();
  let rawValue: unknown;
  try {
    rawValue = JSON.parse(text);
  } catch (error) {
    throw Object.assign(
      new Error(
        m.trajectory_invalid_json({
          message: error instanceof Error ? error.message : String(error),
        })
      ),
      { src }
    );
  }
  try {
    return { parsed: parseTrajectories(rawValue), rawValue, src };
  } catch (error) {
    throw Object.assign(new Error(formatTrajectoryParseError(error)), { src });
  }
}
