import type { TriggerRunInput, TriggerRunResponse } from "@evalens/core/api";

export interface QueryIndexGuard {
  ensureAll(): Promise<boolean>;
  ensureExperiment(experimentName: string): Promise<boolean>;
  ensureRun(runId: string): Promise<boolean>;
  ensureEvaluations(evalIds: string[]): Promise<boolean>;
}

export interface RunDispatcher {
  listExperiments(): Array<{ name: string; description?: string }>;
  trigger(experimentName: string, input: TriggerRunInput): Promise<TriggerRunResponse>;
}
