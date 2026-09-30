import type { z } from "zod";

import type { EvalResult } from "@evalens/core/evaluation";
import type {
  EvalItemCommitMetadata,
  RunItemCommitMetadata,
} from "./metadata/contracts";
import type { RunResult } from "@evalens/core/run";

export function runItemCommitMetadata<Result extends z.JSONType>(
  runId: string,
  itemId: string,
  itemDigest: string,
  result: RunResult<Result>
): RunItemCommitMetadata {
  return result.status === "error"
    ? {
        runId,
        itemId,
        itemDigest,
        status: result.status,
        error: result.error,
        timing: result.timing,
      }
    : {
        runId,
        itemId,
        itemDigest,
        status: result.status,
        timing: result.timing,
      };
}

export function evalItemCommitMetadata(
  evalId: string,
  runId: string,
  itemId: string,
  results: EvalResult[]
): EvalItemCommitMetadata {
  return {
    evalId,
    runId,
    itemId,
    results: results.map((result) => {
      if (result.status === "completed") {
        return {
          evaluatorName: result.evaluator,
          status: result.status,
          score: result.score,
          explanation: result.explanation,
          timing: result.timing,
        };
      }
      if (result.status === "error") {
        return {
          evaluatorName: result.evaluator,
          status: result.status,
          error: result.error,
          timing: result.timing,
        };
      }
      return {
        evaluatorName: result.evaluator,
        status: result.status,
        reason: result.reason,
      };
    }),
  };
}
