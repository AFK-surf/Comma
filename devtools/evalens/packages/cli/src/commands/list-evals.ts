import path from "node:path";
import type { CommandModule } from "yargs";

import { loadEvalensConfig } from "../config";
import { createCliQueryClient, parseParamsFilter } from "./query-client";
import {
  addCommonListOptions,
  commonFilters,
  queryHandler,
  type CommonListArguments,
} from "./query-utils";

type ListEvalsArguments = CommonListArguments & {
  "run-id"?: string;
  "eval-params"?: string;
};

export const listEvalsCommand: CommandModule<{}, ListEvalsArguments> = {
  command: "evals",
  describe: "List evaluations as JSON",
  builder: (evaluations) =>
    addCommonListOptions(evaluations)
      .option("run-id", { type: "string", requiresArg: true })
      .option("eval-params", { type: "string", requiresArg: true }),
  handler: queryHandler(async (argv) => {
    const config = await loadEvalensConfig(path.resolve(argv.config));
    await using client = await createCliQueryClient(config);
    const page = await client.listEvaluations({
      ...commonFilters(argv),
      ...(argv["run-id"] ? { runId: argv["run-id"] } : {}),
      ...(argv["run-params"]
        ? { runParams: parseParamsFilter(argv["run-params"]) }
        : {}),
      ...(argv["eval-params"]
        ? { evalParams: parseParamsFilter(argv["eval-params"]) }
        : {}),
      page: 1,
      pageSize: argv.limit,
    });
    return { items: page.items, total: page.total, limit: argv.limit };
  }),
};
