import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useEffect, useRef, useState } from "react";
import { CompareView } from "../components/CompareView";
import { StatePanel } from "../components/Status";
import { dashboardDataSource } from "../data/source";
import { useResource } from "../lib/useResource";
import { useCompareSelection } from "../selection/CompareSelection";
import { parseCompareSearch } from "../lib/url-state";
import { useMessages } from "../i18n/locale";

export const Route = createFileRoute("/compare")({
  validateSearch: parseCompareSearch,
  component: CompareRoute,
});
function CompareRoute() {
  const m = useMessages();
  const navigate = Route.useNavigate();
  const search = Route.useSearch();
  const { selected, replaceFromUrl, loadComparison } = useCompareSelection();
  const selectedIds = selected
    .filter(({ state }) => state === "valid")
    .map(({ id }) => id);
  const selectedKey = JSON.stringify(selectedIds);
  const urlKey = JSON.stringify(search.eval);
  const appliedUrlKey = useRef<string | null>(null);
  const seedFromSelection = useRef(search.eval.length === 0);
  const [resolvingUrlKey, setResolvingUrlKey] = useState<string | null>(null);
  const [version, setVersion] = useState(0);
  const load = useCallback(
    () =>
      loadComparison(search.eval, search.itemPage, 200, search.reference, version > 0),
    [loadComparison, search.eval, search.itemPage, search.reference, version]
  );
  const comparison = useResource(load, [load]);
  const catalog = useResource(
    () =>
      dashboardDataSource.listEvaluations({
        status: "finished",
        page: search.catalogPage,
        pageSize: 100,
        query: search.query,
        experimentName: search.experiment,
        tag: search.tag,
        createdAfter: search.after ? new Date(search.after).toISOString() : undefined,
        runParams: parseParamFilter(search.runParam),
        evalParams: parseParamFilter(search.evalParam),
      }),
    [
      search.catalogPage,
      search.query,
      search.experiment,
      search.tag,
      search.after,
      search.runParam,
      search.evalParam,
    ]
  );
  useEffect(() => {
    if (seedFromSelection.current && search.eval.length === 0) return;
    if (appliedUrlKey.current !== urlKey) {
      appliedUrlKey.current = urlKey;
      setResolvingUrlKey(urlKey);
      replaceFromUrl(search.eval);
    }
  }, [replaceFromUrl, search.eval, urlKey]);
  useEffect(() => {
    if (
      seedFromSelection.current &&
      selected.every(({ state }) => state !== "loading")
    ) {
      seedFromSelection.current = false;
      if (selectedIds.length === 0) return;
      void navigate({
        replace: true,
        search: (current) => ({
          ...current,
          eval: selectedIds,
          itemPage: 1,
        }),
      });
    }
  }, [navigate, selected, selectedIds, selectedKey]);
  useEffect(() => {
    if (
      resolvingUrlKey !== urlKey ||
      selected.some(({ state }) => state === "loading")
    ) {
      return;
    }
    setResolvingUrlKey(null);
    if (selectedKey === urlKey) return;
    void navigate({
      replace: true,
      search: (current) => ({
        ...current,
        eval: selectedIds,
        itemPage: 1,
        reference:
          current.reference && selectedIds.includes(current.reference)
            ? current.reference
            : undefined,
      }),
    });
  }, [navigate, resolvingUrlKey, selected, selectedIds, selectedKey, urlKey]);
  if (
    search.eval.length > 0 &&
    (resolvingUrlKey === urlKey || selectedKey !== urlKey)
  ) {
    return (
      <main className="page-shell">
        <StatePanel title={m.compare_loading()} detail={m.common_please_wait()} />
      </main>
    );
  }
  if (comparison.status === "loading")
    return (
      <main className="page-shell">
        <StatePanel title={m.compare_loading()} detail={m.common_please_wait()} />
      </main>
    );
  if (comparison.status === "error")
    return (
      <main className="page-shell">
        <StatePanel title={m.compare_load_error()} detail={comparison.error} />
      </main>
    );
  return (
    <CompareView
      catalog={
        catalog.status === "ready"
          ? catalog.data
          : { items: [], page: 1, pageSize: 100, total: 0 }
      }
      comparison={comparison.data}
      onChange={(evalIds, reference) => {
        replaceFromUrl(evalIds);
        void navigate({
          search: (current) => ({
            ...current,
            eval: evalIds,
            itemPage: 1,
            reference: reference && evalIds.includes(reference) ? reference : undefined,
          }),
        });
      }}
      filters={search}
      onFilter={(filters) =>
        navigate({ search: (current) => ({ ...current, ...filters, catalogPage: 1 }) })
      }
      onCatalogPage={(catalogPage) =>
        navigate({ search: (current) => ({ ...current, catalogPage }) })
      }
      onPage={(itemPage) =>
        navigate({ search: (current) => ({ ...current, itemPage }) })
      }
      onReload={() => setVersion((value) => value + 1)}
      reference={search.reference}
    />
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
