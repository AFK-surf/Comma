import { createFileRoute } from "@tanstack/react-router";
import { RunDetailView } from "../components/RunDetailView";
import { StatePanel } from "../components/Status";
import { dashboardDataSource } from "../data/source";
import { useResource } from "../lib/useResource";
import { useMessages } from "../i18n/locale";

type RunSearch = { eval?: string; page: number };

export const Route = createFileRoute("/runs/$runId")({
  validateSearch: (search: Record<string, unknown>): RunSearch => ({
    eval: typeof search.eval === "string" ? search.eval : undefined,
    page: Math.max(1, Number(search.page) || 1),
  }),
  component: RunRoute,
});

function RunRoute() {
  const m = useMessages();
  const { runId } = Route.useParams();
  const search = Route.useSearch();
  const detail = useResource(async () => {
    const [run, catalog] = await Promise.all([
      dashboardDataSource.getRun(runId),
      dashboardDataSource.listEvaluations({ runId, page: 1, pageSize: 100 }),
    ]);
    if (!run) return null;
    const requestedEvaluation = search.eval
      ? await dashboardDataSource.getEvaluation(search.eval)
      : null;
    const selectedEvaluation =
      requestedEvaluation?.run.id === runId ? requestedEvaluation : catalog.items[0];
    const evaluations = selectedEvaluation
      ? [
          selectedEvaluation,
          ...catalog.items.filter(({ id }) => id !== selectedEvaluation.id),
        ]
      : catalog.items;
    const items = await dashboardDataSource.listRunItems(
      runId,
      selectedEvaluation?.id,
      search.page,
      100
    );
    return {
      run,
      evaluations,
      evaluationTotal: catalog.total,
      ...(selectedEvaluation ? { selectedEvalId: selectedEvaluation.id } : {}),
      items,
    };
  }, [runId, search.eval, search.page]);
  if (detail.status === "loading")
    return (
      <main className="page-shell">
        <StatePanel title={m.run_loading()} detail={m.common_please_wait()} />
      </main>
    );
  if (detail.status === "error")
    return (
      <main className="page-shell">
        <StatePanel title={m.run_load_error()} detail={detail.error} />
      </main>
    );
  if (!detail.data)
    return (
      <main className="page-shell">
        <StatePanel title={m.run_not_found()} detail={m.run_not_found_detail()} />
      </main>
    );
  return <RunDetailView detail={detail.data} />;
}
