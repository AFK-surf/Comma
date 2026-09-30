import type { z } from "zod";

import type { EvalManifest, EvalResult } from "../evaluation";
import type { EvalensLoggerHandle } from "../logger";
import type { RunItemReference, RunManifest, RunResult } from "../run";

export type CreateRunInput = Omit<
  RunManifest,
  "formatVersion" | "runId" | "createdAt" | "finishedAt" | "status"
>;

export type CreateEvaluationInput = Omit<
  EvalManifest,
  "formatVersion" | "evalId" | "runId" | "createdAt" | "finishedAt" | "status" | "error"
>;

export type StoredRunItem<Result extends z.JSONType> = RunItemReference & {
  runResult: RunResult<Result>;
};

export type StoredRunItemState = RunItemReference & {
  status: RunResult<z.JSONType>["status"];
};

export interface RunWriterContract extends AsyncDisposable {
  readonly runId: string;
  readonly experimentName: string;
  createItemLogger(itemId: string): EvalensLoggerHandle;
  commitItem<Result extends z.JSONType>(
    itemId: string,
    result: RunResult<Result>,
    itemDigest: string
  ): Promise<void>;
  finish(): Promise<void>;
}

export interface EvalWriterContract extends AsyncDisposable {
  readonly experimentName: string;
  readonly runId: string;
  readonly evalId: string;
  createItemLogger(itemId: string): EvalensLoggerHandle;
  commitItem(itemId: string, results: EvalResult[]): Promise<void>;
  saveAggregate(scores: Record<string, number>): Promise<void>;
  finish(): Promise<void>;
  fail(error: string): Promise<void>;
}

export interface EvalReaderContract {
  readonly experimentName: string;
  readonly runId: string;
  readonly evalId: string;
  readManifest(): Promise<EvalManifest>;
  readItemResults(itemId: string): Promise<EvalResult[]>;
  readAggregateScores(): Promise<Record<string, number>>;
}

export interface RunReaderContract {
  readonly experimentName: string;
  readonly runId: string;
  readManifest(): Promise<RunManifest>;
  iterateItemStates(): AsyncIterable<StoredRunItemState>;
  iterateItems<Result extends z.JSONType>(): AsyncIterable<StoredRunItem<Result>>;
  openEval(evalId: string): EvalReaderContract;
}

export interface EvalensStore extends AsyncDisposable {
  createRun(input: CreateRunInput): Promise<RunWriterContract>;
  openRun(experimentName: string, runId: string): RunReaderContract;
  createEvaluation(
    run: RunReaderContract,
    input: CreateEvaluationInput
  ): Promise<EvalWriterContract>;
}
