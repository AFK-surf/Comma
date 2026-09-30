import {
  reindexScopeKey,
  type ReindexScope,
} from "@evalens/store/metadata/index-service";

type LocalIndexState = {
  getIndexState(): "ready" | "rebuilding";
  getRunExperimentName(runId: string): string | undefined;
  getEvaluationScopes(evalIds: string[]): Array<{
    evalId: string;
    runId: string;
    experimentName: string;
  }>;
};

type LocalIndexReconciler = {
  bootstrap(): Promise<void>;
  repairMarkedScopes(scope: ReindexScope): Promise<void>;
  repairRunMarkers(runId: string): Promise<void>;
  findEvaluationScopes(
    evalIds: string[]
  ): Promise<Array<{ evalId: string; runId: string; experimentName: string }>>;
};

export class LocalIndexGuard {
  private bootstrap?: Promise<boolean>;
  private readonly repairs = new Map<string, Promise<boolean>>();

  constructor(
    private readonly writer: LocalIndexState,
    private readonly indexService: LocalIndexReconciler,
    private readonly warn: (message: string, error: unknown) => void = (
      message,
      error
    ) => console.warn(message, error)
  ) {}

  ensureAll(): Promise<boolean> {
    return this.ensureScope({ type: "all" });
  }

  ensureExperiment(experimentName: string): Promise<boolean> {
    return this.ensureScope({ type: "experiment", experimentName });
  }

  ensureRun(runId: string): Promise<boolean> {
    const experimentName = this.writer.getRunExperimentName(runId);
    return experimentName
      ? this.ensureScope({ type: "run", experimentName, runId })
      : this.ensureUnknownRun(runId);
  }

  async ensureEvaluations(evalIds: string[]): Promise<boolean> {
    if (this.writer.getIndexState() !== "ready") return this.ensureBootstrapped();
    const uniqueIds = [...new Set(evalIds)];
    const indexedScopes = this.writer.getEvaluationScopes(uniqueIds);
    const indexedIds = new Set(indexedScopes.map(({ evalId }) => evalId));
    let locatedScopes: typeof indexedScopes;
    try {
      locatedScopes = await this.indexService.findEvaluationScopes(
        uniqueIds.filter((evalId) => !indexedIds.has(evalId))
      );
    } catch (error) {
      this.warn("local result index evaluation scope lookup failed", error);
      return false;
    }
    const scopes = [...indexedScopes, ...locatedScopes];
    const results = await Promise.all(
      scopes.map(({ experimentName, runId, evalId }) =>
        this.ensureScope({ type: "eval", experimentName, runId, evalId })
      )
    );
    return results.every(Boolean);
  }

  private ensureUnknownRun(runId: string): Promise<boolean> {
    const operationKey = `unknown-run:${runId}`;
    const pending = this.repairs.get(operationKey);
    if (pending) return pending;
    let operation: Promise<boolean>;
    operation = this.indexService
      .repairRunMarkers(runId)
      .then(() => true)
      .catch((error) => {
        this.warn("local result index repair failed for run scope", error);
        return false;
      })
      .finally(() => {
        if (this.repairs.get(operationKey) === operation) {
          this.repairs.delete(operationKey);
        }
      });
    this.repairs.set(operationKey, operation);
    return operation;
  }

  private async ensureScope(
    scope: ReindexScope,
    operationKey = reindexScopeKey(scope)
  ): Promise<boolean> {
    if (this.writer.getIndexState() !== "ready") return this.ensureBootstrapped();
    const pending = this.repairs.get(operationKey);
    if (pending) return pending;
    let operation: Promise<boolean>;
    operation = (async () => {
      await this.indexService.repairMarkedScopes(scope);
      return true;
    })()
      .catch((error) => {
        this.warn("local result index rebuild failed", error);
        return false;
      })
      .finally(() => {
        if (this.repairs.get(operationKey) === operation) {
          this.repairs.delete(operationKey);
        }
      });
    this.repairs.set(operationKey, operation);
    return operation;
  }

  private ensureBootstrapped(): Promise<boolean> {
    if (this.bootstrap) return this.bootstrap;
    this.bootstrap = this.indexService
      .bootstrap()
      .then(() => true)
      .catch((error) => {
        this.warn("local result index bootstrap failed", error);
        return false;
      })
      .finally(() => {
        this.bootstrap = undefined;
      });
    return this.bootstrap;
  }
}
