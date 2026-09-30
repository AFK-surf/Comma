import type { CodexAdapterConfig } from "@evalens/adapters/config";
import { CodexCliAdapter } from "@evalens/adapters/codex";
import type { DatasetItem, Evaluator, RunOutput } from "@evalens/core";
import { z, type JSONType } from "zod";

const CodexEvaluationResult = z
  .object({
    score: z.number().min(0).max(1),
    explanation: z.string().optional(),
  })
  .strict();

export type CodexEvaluatorOptions<
  Item extends DatasetItem<unknown, unknown>,
  Result extends JSONType,
> = {
  name?: string;
  version?: string;
  rubric:
    string | ((item: Item, output: RunOutput<Result>) => string | Promise<string>);
  model?: string;
};

export function codexEvaluator<
  Item extends DatasetItem<unknown, unknown>,
  Result extends JSONType,
  Params extends Readonly<Record<string, JSONType>>,
>(
  options: CodexEvaluatorOptions<Item, Result>
): Evaluator<
  Item,
  Result,
  Params,
  { codex: CodexAdapterConfig },
  string,
  string,
  { score: { score: number }; explanation?: string }
> {
  return {
    name: options.name ?? "codex-judge",
    version: options.version ?? "1",
    async evaluate(item, output, context) {
      const rubric =
        typeof options.rubric === "string"
          ? options.rubric
          : await options.rubric(item, output);
      const adapter = new CodexCliAdapter({
        ...context.adapterConfig.codex,
        model: options.model,
      });
      const result = await adapter.runTask({
        task: [
          "Evaluate the result according to the rubric.",
          "Return only JSON with numeric score from 0 to 1 and optional explanation.",
          `Rubric: ${rubric}`,
          `Dataset item: ${JSON.stringify(item)}`,
          `Run output: ${JSON.stringify(output)}`,
        ].join("\n\n"),
      });
      if (result.exitCode !== 0) {
        throw new Error(
          result.codexErrorMessage ??
            `codex evaluator failed with exit code ${result.exitCode}`
        );
      }
      const { score, explanation } = CodexEvaluationResult.parse(
        JSON.parse(result.finalAnswer)
      );
      return {
        score: { score },
        ...(explanation ? { explanation } : {}),
      };
    },
  };
}
