import type { Argv } from "yargs";

import {
  CliQueryError,
  normalizeCliQueryError,
  parseCreatedRange,
} from "./query-client";

export function addQueryConfigOption<T>(parser: Argv<T>) {
  return parser.option("config", {
    type: "string",
    demandOption: true,
    requiresArg: true,
    description: "Path to evalens.config.json",
  });
}

export function addCommonListOptions<T>(parser: Argv<T>) {
  return addQueryConfigOption(parser)
    .option("experiment", { type: "string", requiresArg: true })
    .option("status", {
      choices: ["running", "finished", "error"] as const,
      requiresArg: true,
    })
    .option("tag", { type: "string", requiresArg: true })
    .option("run-params", { type: "string", requiresArg: true })
    .option("created-after", { type: "string", requiresArg: true })
    .option("created-before", { type: "string", requiresArg: true })
    .option("limit", {
      type: "number",
      default: 20,
      requiresArg: true,
      coerce(value: number) {
        if (!Number.isInteger(value) || value < 1 || value > 100) {
          throw new CliQueryError(
            "invalid_arguments",
            "limit must be an integer between 1 and 100",
            false,
            2
          );
        }
        return value;
      },
    });
}

export type CommonListArguments = {
  config: string;
  experiment?: string;
  status?: "running" | "finished" | "error";
  tag?: string;
  "run-params"?: string;
  "created-after"?: string;
  "created-before"?: string;
  limit: number;
};

export function commonFilters(argv: CommonListArguments) {
  return {
    ...(argv.experiment ? { experimentName: argv.experiment } : {}),
    ...(argv.status ? { status: argv.status } : {}),
    ...(argv.tag ? { tag: argv.tag } : {}),
    ...parseCreatedRange(argv["created-after"], argv["created-before"]),
  };
}

export function queryHandler<TArguments, TResult>(
  handler: (argv: TArguments) => Promise<TResult>
) {
  return async (argv: TArguments) => {
    try {
      console.log(JSON.stringify(await handler(argv)));
    } catch (error) {
      throw normalizeCliQueryError(error);
    }
  };
}
