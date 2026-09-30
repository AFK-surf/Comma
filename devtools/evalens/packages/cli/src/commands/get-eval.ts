import path from "node:path";
import type { CommandModule } from "yargs";

import { loadEvalensConfig } from "../config";
import { CliQueryError, createCliQueryClient } from "./query-client";
import { addQueryConfigOption, queryHandler } from "./query-utils";

type GetEvalArguments = { config: string; id: string };

export const getEvalCommand: CommandModule<{}, GetEvalArguments> = {
  command: "eval <id>",
  describe: "Get evaluation metadata as JSON",
  builder: (evaluation) =>
    addQueryConfigOption(evaluation).positional("id", {
      type: "string",
      demandOption: true,
    }),
  handler: queryHandler(async (argv) => {
    const config = await loadEvalensConfig(path.resolve(argv.config));
    await using client = await createCliQueryClient(config);
    const evaluation = await client.getEvaluation(argv.id);
    if (!evaluation) {
      throw new CliQueryError("not_found", "evaluation not found");
    }
    return evaluation;
  }),
};
