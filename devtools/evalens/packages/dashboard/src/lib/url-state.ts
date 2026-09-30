export type CompareSearch = {
  eval: string[];
  reference?: string;
  itemPage: number;
  catalogPage: number;
  query?: string;
  experiment?: string;
  tag?: string;
  after?: string;
  runParam?: string;
  evalParam?: string;
};

export function parseCompareSearch(search: Record<string, unknown>): CompareSearch {
  const evalIds = Array.isArray(search.eval)
    ? search.eval.map(String)
    : typeof search.eval === "string"
      ? [search.eval]
      : [];
  const uniqueEvalIds = [...new Set(evalIds)];
  const boundedEvalIds =
    uniqueEvalIds.length <= MAX_COMPARE_EVALUATIONS ? uniqueEvalIds : [];
  return {
    eval: boundedEvalIds,
    itemPage: Math.max(1, Number(search.itemPage) || 1),
    catalogPage: Math.max(1, Number(search.catalogPage) || 1),
    ...(typeof search.reference === "string" &&
    boundedEvalIds.includes(search.reference)
      ? { reference: search.reference }
      : {}),
    ...(typeof search.query === "string" && search.query
      ? { query: search.query }
      : {}),
    ...(typeof search.experiment === "string" && search.experiment
      ? { experiment: search.experiment }
      : {}),
    ...(typeof search.tag === "string" && search.tag ? { tag: search.tag } : {}),
    ...(typeof search.after === "string" && search.after
      ? { after: search.after }
      : {}),
    ...(typeof search.runParam === "string" && search.runParam
      ? { runParam: search.runParam }
      : {}),
    ...(typeof search.evalParam === "string" && search.evalParam
      ? { evalParam: search.evalParam }
      : {}),
  };
}
import { MAX_COMPARE_EVALUATIONS } from "@evalens/core/api";
