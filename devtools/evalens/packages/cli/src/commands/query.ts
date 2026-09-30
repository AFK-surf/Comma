import type { Argv, CommandModule } from "yargs";

import { getEvalCommand } from "./get-eval";
import { getRunCommand } from "./get-run";
import { listEvalsCommand } from "./list-evals";
import { listRunsCommand } from "./list-runs";
import { CliQueryError } from "./query-client";

export const listCommand: CommandModule = {
  command: "list",
  describe: "List runs or evaluations as JSON",
  builder: (list) =>
    configureQueryParser(list)
      .command(listRunsCommand)
      .command(listEvalsCommand)
      .demandCommand(1),
  handler: () => {},
};

export const getCommand: CommandModule = {
  command: "get",
  describe: "Get run or evaluation metadata as JSON",
  builder: (get) =>
    configureQueryParser(get)
      .command(getRunCommand)
      .command(getEvalCommand)
      .demandCommand(1),
  handler: () => {},
};

function configureQueryParser(parser: Argv) {
  return parser
    .exitProcess(false)
    .showHelpOnFail(false)
    .fail((message, error) => {
      throw new CliQueryError("invalid_arguments", error?.message ?? message, false, 2);
    });
}
