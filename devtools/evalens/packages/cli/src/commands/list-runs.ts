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

export const listRunsCommand: CommandModule<{}, CommonListArguments> = {
  command: "runs",
  describe: "List runs as JSON",
  builder: addCommonListOptions,
  handler: queryHandler(async (argv) => {
    const config = await loadEvalensConfig(path.resolve(argv.config));
    await using client = await createCliQueryClient(config);
    const page = await client.listRuns({
      ...commonFilters(argv),
      ...(argv["run-params"] ? { params: parseParamsFilter(argv["run-params"]) } : {}),
      page: 1,
      pageSize: argv.limit,
    });
    return { items: page.items, total: page.total, limit: argv.limit };
  }),
};
