import path from "node:path";
import type { CommandModule } from "yargs";

import { loadEvalensConfig } from "../config";
import { CliQueryError, createCliQueryClient } from "./query-client";
import { addQueryConfigOption, queryHandler } from "./query-utils";

type GetRunArguments = { config: string; id: string };

export const getRunCommand: CommandModule<{}, GetRunArguments> = {
  command: "run <id>",
  describe: "Get run metadata as JSON",
  builder: (run) =>
    addQueryConfigOption(run).positional("id", {
      type: "string",
      demandOption: true,
    }),
  handler: queryHandler(async (argv) => {
    const config = await loadEvalensConfig(path.resolve(argv.config));
    await using client = await createCliQueryClient(config);
    const run = await client.getRun(argv.id);
    if (!run) throw new CliQueryError("not_found", "run not found");
    return run;
  }),
};
