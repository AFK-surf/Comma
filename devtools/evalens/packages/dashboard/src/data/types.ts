import type {
  DataState,
  EvalCatalogEntry,
  EvalComparison,
  EvalComparisonEntry,
  EvalFilters,
  EvalSummary,
  EvaluatorResultCell,
  ExperimentSummary,
  Page,
  RunFilters,
  RunItemSummary,
  RunSummary,
} from "@evalens/core/api";

export type {
  DataState,
  EvalCatalogEntry,
  EvalComparison,
  EvalComparisonEntry,
  EvalFilters,
  EvalSummary,
  EvaluatorResultCell,
  ExperimentSummary,
  Page,
  RunFilters,
  RunItemSummary,
  RunSummary,
};

export type LifecycleStatus = RunSummary["status"];
export type ParamValue = RunSummary["params"][string];

/** Bounded page composition for the run screen; it is not a query API DTO. */
export interface RunDetail {
  run: RunSummary;
  evaluations: EvalCatalogEntry[];
  evaluationTotal: number;
  selectedEvalId?: string;
  items: Page<RunItemSummary>;
}

export interface DashboardDataSource {
  getState(): Promise<DataState>;
  listExperiments(): Promise<ExperimentSummary[]>;
  listRuns(filters?: RunFilters): Promise<Page<RunSummary>>;
  getRun(runId: string): Promise<RunSummary | null>;
  listEvaluations(filters?: EvalFilters): Promise<Page<EvalCatalogEntry>>;
  getEvaluation(evalId: string): Promise<EvalCatalogEntry | null>;
  listRunItems(
    runId: string,
    evalId?: string,
    page?: number,
    pageSize?: number
  ): Promise<Page<RunItemSummary>>;
  compareEvaluations(
    evalIds: string[],
    itemPage?: number,
    itemPageSize?: number,
    referenceEvalId?: string
  ): Promise<EvalComparison>;
}
