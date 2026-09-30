import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { MAX_COMPARE_EVALUATIONS } from "@evalens/core/api";
import type { EvalCatalogEntry } from "../data/types";
import type { EvalComparison } from "../data/types";
import { dashboardDataSource } from "../data/source";
import { analyzeCatalogCompatibility } from "../lib/comparison";
import { formatCompatibilityReasons } from "../i18n/compatibility";
import { useLocale } from "../i18n/locale";
import { m } from "../paraglide/messages.js";

const STORAGE_KEY = "evalens.compare-selection";
const STORAGE_VERSION = 1;

export type SelectedEvaluation = {
  id: string;
  entry?: EvalCatalogEntry;
  state: "loading" | "valid" | "invalid";
  reason?: SelectionInvalidReason;
};

export type SelectionInvalidReason =
  | { code: "missing" }
  | { code: "status"; status: EvalCatalogEntry["status"] }
  | { code: "error"; message: string };

export type CandidateCompatibility =
  { compatible: true } | { compatible: false; reason: string };
type AddResult = { ok: true } | { ok: false; message: string };
type CompareSelectionValue = {
  selected: SelectedEvaluation[];
  checkCompatibility(entry: EvalCatalogEntry): Promise<CandidateCompatibility>;
  add(entry: EvalCatalogEntry): Promise<AddResult>;
  remove(id: string): void;
  clear(): void;
  move(id: string, delta: number): void;
  replaceFromUrl(ids: string[]): void;
  loadComparison(
    ids: string[],
    itemPage: number,
    itemPageSize: number,
    referenceEvalId?: string,
    fresh?: boolean
  ): Promise<EvalComparison>;
};

const CompareSelectionContext = createContext<CompareSelectionValue | null>(null);

export function CompareSelectionProvider({ children }: { children: ReactNode }) {
  const { locale } = useLocale();
  const [selected, setSelected] = useState<SelectedEvaluation[]>(() =>
    readStoredSelection().map((id) => ({ id, state: "loading" }))
  );
  const selectedRef = useRef(selected);
  const addQueue = useRef<Promise<void>>(Promise.resolve());
  const externalGeneration = useRef(0);
  const selectionLoads = useRef(new Map<string, Promise<SelectionLoadResult>>());
  const resolvedComparison = useRef<{ key: string; value: EvalComparison } | undefined>(
    undefined
  );
  selectedRef.current = selected;

  const replaceSelection = useCallback((next: SelectedEvaluation[]) => {
    selectedRef.current = next;
    setSelected(next);
  }, []);

  const loadSelectionOnce = useCallback((ids: string[]) => {
    const key = JSON.stringify(ids);
    const existing = selectionLoads.current.get(key);
    if (existing) return existing;
    const operation = loadSelection(ids)
      .then((result) => {
        if (result.comparison) {
          resolvedComparison.current = {
            key: comparisonKey(ids, 1, 200),
            value: result.comparison,
          };
        }
        return result;
      })
      .finally(() => {
        if (selectionLoads.current.get(key) === operation) {
          selectionLoads.current.delete(key);
        }
      });
    selectionLoads.current.set(key, operation);
    return operation;
  }, []);

  const hydrateCurrentSelection = useCallback(
    async (expectedGeneration?: number): Promise<boolean> => {
      while (true) {
        if (
          expectedGeneration !== undefined &&
          externalGeneration.current !== expectedGeneration
        ) {
          return false;
        }
        const loading = selectedRef.current.filter(({ state }) => state === "loading");
        if (loading.length === 0) return true;
        const selectionIds = selectedRef.current.map(({ id }) => id);
        const generationAtStart = externalGeneration.current;
        const result = await loadSelectionOnce(selectionIds);
        if (
          externalGeneration.current !== generationAtStart ||
          (expectedGeneration !== undefined &&
            externalGeneration.current !== expectedGeneration)
        ) {
          return false;
        }
        replaceSelection(result.selection);
      }
    },
    [loadSelectionOnce, replaceSelection]
  );

  useEffect(() => {
    persistSelection(selected.map(({ id }) => id));
  }, [selected]);

  useEffect(() => {
    if (selected.some(({ state }) => state === "loading")) {
      void hydrateCurrentSelection();
    }
  }, [hydrateCurrentSelection, selected]);

  const checkCompatibilityFor = useCallback(
    (
      entry: EvalCatalogEntry,
      selection: SelectedEvaluation[]
    ): CandidateCompatibility => {
      if (entry.status !== "finished") {
        return {
          compatible: false,
          reason: m.selection_non_finished({
            status: localizedStatus(entry.status),
          }),
        };
      }
      if (selection.some(({ id }) => id === entry.id)) return { compatible: true };
      const validEntries = selection
        .filter(({ state }) => state === "valid")
        .flatMap(({ entry }) => (entry ? [entry] : []));
      if (validEntries.length >= MAX_COMPARE_EVALUATIONS) {
        return {
          compatible: false,
          reason: m.selection_limit({ count: MAX_COMPARE_EVALUATIONS }),
        };
      }
      if (validEntries.length > 0) {
        const compatibility = analyzeCatalogCompatibility([...validEntries, entry]);
        if (!compatibility.compatible) {
          return {
            compatible: false,
            reason: m.selection_cannot_add({
              reason: formatCompatibilityReasons(compatibility.reasons),
            }),
          };
        }
      }
      return { compatible: true };
    },
    [locale]
  );

  const checkCompatibility = useCallback(
    async (entry: EvalCatalogEntry) => {
      await hydrateCurrentSelection();
      return checkCompatibilityFor(entry, selectedRef.current);
    },
    [checkCompatibilityFor, hydrateCurrentSelection]
  );

  const add = useCallback(
    (entry: EvalCatalogEntry): Promise<AddResult> => {
      const requestedGeneration = externalGeneration.current;
      const operation = addQueue.current.then(async () => {
        if (
          !(await hydrateCurrentSelection(requestedGeneration)) ||
          externalGeneration.current !== requestedGeneration
        ) {
          return { ok: false, message: m.selection_changed() } as const;
        }
        const beforeValidation = selectedRef.current;
        const compatibility = checkCompatibilityFor(entry, beforeValidation);
        if (!compatibility.compatible) {
          return { ok: false, message: compatibility.reason } as const;
        }
        if (
          externalGeneration.current !== requestedGeneration ||
          selectedRef.current !== beforeValidation
        ) {
          return { ok: false, message: m.selection_changed() } as const;
        }
        if (beforeValidation.some(({ id }) => id === entry.id)) {
          return { ok: true } as const;
        }
        const next = [
          ...beforeValidation,
          { id: entry.id, entry, state: "valid" as const },
        ];
        replaceSelection(next);
        return { ok: true } as const;
      });
      addQueue.current = operation.then(
        () => undefined,
        () => undefined
      );
      return operation;
    },
    [checkCompatibilityFor, hydrateCurrentSelection, replaceSelection]
  );

  const mutateSelection = useCallback(
    (update: (current: SelectedEvaluation[]) => SelectedEvaluation[]) => {
      const current = selectedRef.current;
      const next = update(current);
      if (next === current) return;
      externalGeneration.current += 1;
      replaceSelection(next);
    },
    [replaceSelection]
  );

  const value = useMemo<CompareSelectionValue>(
    () => ({
      selected,
      checkCompatibility,
      add,
      remove: (id) =>
        mutateSelection((current) => {
          const next = current.filter((item) => item.id !== id);
          return next.length === current.length ? current : next;
        }),
      clear: () => mutateSelection((current) => (current.length ? [] : current)),
      move: (id, delta) =>
        mutateSelection((current) => {
          const index = current.findIndex((item) => item.id === id);
          const target = index + delta;
          if (index < 0 || target < 0 || target >= current.length) return current;
          const next = [...current];
          const [item] = next.splice(index, 1);
          if (!item) return current;
          next.splice(target, 0, item);
          return next;
        }),
      replaceFromUrl: (ids) =>
        mutateSelection((current) => {
          const unique = [...new Set(ids)];
          if (unique.length > MAX_COMPARE_EVALUATIONS) return [];
          if (
            unique.length === current.length &&
            unique.every((id, index) => current[index]?.id === id)
          )
            return current;
          const existing = new Map(current.map((item) => [item.id, item]));
          return unique.map((id) => existing.get(id) ?? { id, state: "loading" });
        }),
      loadComparison: (ids, itemPage, itemPageSize, referenceEvalId, fresh) => {
        if (!fresh) {
          const resolved = resolvedComparison.current;
          if (resolved?.key === comparisonKey(ids, itemPage, itemPageSize)) {
            return Promise.resolve(resolved.value);
          }
        }
        if (!fresh && itemPage === 1 && itemPageSize === 200) {
          const pending = selectionLoads.current.get(JSON.stringify(ids));
          if (pending) {
            return pending.then((result) => {
              if (result.comparison) return result.comparison;
              return dashboardDataSource.compareEvaluations(
                ids,
                itemPage,
                itemPageSize,
                referenceEvalId
              );
            });
          }
        }
        return dashboardDataSource.compareEvaluations(
          ids,
          itemPage,
          itemPageSize,
          referenceEvalId
        );
      },
    }),
    [add, checkCompatibility, mutateSelection, selected]
  );

  return (
    <CompareSelectionContext.Provider value={value}>
      {children}
    </CompareSelectionContext.Provider>
  );
}

export function useCompareSelection() {
  const value = useContext(CompareSelectionContext);
  if (!value)
    throw new Error("useCompareSelection must be used inside CompareSelectionProvider");
  return value;
}

export function parseStoredSelection(value: string | null): string[] {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value) as unknown;
    if (
      !parsed ||
      typeof parsed !== "object" ||
      !("version" in parsed) ||
      !("evalIds" in parsed)
    )
      return [];
    const record = parsed as { version: unknown; evalIds: unknown };
    if (record.version !== STORAGE_VERSION || !Array.isArray(record.evalIds)) return [];
    const ids = [
      ...new Set(
        record.evalIds.filter(
          (id): id is string => typeof id === "string" && id.length > 0
        )
      ),
    ];
    return ids.length <= MAX_COMPARE_EVALUATIONS ? ids : [];
  } catch {
    return [];
  }
}

function persistSelection(evalIds: string[]) {
  try {
    globalThis.localStorage?.setItem(
      STORAGE_KEY,
      JSON.stringify({ version: STORAGE_VERSION, evalIds })
    );
  } catch {
    // Storage may be unavailable in private or embedded contexts.
  }
}

function readStoredSelection(): string[] {
  try {
    return parseStoredSelection(globalThis.localStorage?.getItem(STORAGE_KEY) ?? null);
  } catch {
    return [];
  }
}

type SelectionLoadResult = {
  selection: SelectedEvaluation[];
  comparison?: EvalComparison;
};

async function loadSelection(ids: string[]): Promise<SelectionLoadResult> {
  try {
    const comparison = await dashboardDataSource.compareEvaluations(ids, 1, 200);
    const byId = new Map(comparison.evaluations.map((entry) => [entry.id, entry]));
    const entries = ids.flatMap((id) => {
      const entry = byId.get(id);
      return entry ? [entry] : [];
    });
    if (
      entries.length !== ids.length ||
      entries.some(({ status }) => status !== "finished") ||
      !analyzeCatalogCompatibility(entries).compatible
    ) {
      return { selection: [], comparison };
    }
    return {
      selection: entries.map((entry) => ({ id: entry.id, entry, state: "valid" })),
      comparison,
    };
  } catch {
    return { selection: [] };
  }
}

function comparisonKey(ids: string[], itemPage: number, itemPageSize: number): string {
  return JSON.stringify([ids, itemPage, itemPageSize]);
}

function localizedStatus(status: EvalCatalogEntry["status"]): string {
  if (status === "finished") return m.status_finished();
  if (status === "running") return m.status_running();
  return m.status_error();
}
