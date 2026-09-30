import path from "node:path";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";

import { getCommand, listCommand } from "./commands/query";
import { CliQueryError, structuredCliError } from "./commands/query-client";
import { reevalCommand } from "./commands/reeval";
import { rerunCommand } from "./commands/rerun";
import { runCommand } from "./commands/run-group";
import { loadEvalensConfig } from "./config";
import { packDataset, publishDataset } from "./dataset";
import { syncSalixL2Dataset } from "./dataset-sync";

export * from "./config";
export * from "./commands/query-client";
export { parseCliParams, readCliParamsFile } from "./commands/execution-utils";
export { parseCliExperimentRequest, readCliExperimentRequest } from "./commands/run";

export async function runCli(args = hideBin(Bun.argv)) {
  const parser = yargs(args).scriptName("evalens").parserConfiguration({
    "populate--": true,
  });

  return parser
    .command(runCommand)
    .command(rerunCommand)
    .command(reevalCommand)
    .command(listCommand)
    .command(getCommand)
    .command(
      "dataset",
      "Manage content-addressed datasets",
      (yargs) =>
        yargs
          .command(
            "sync <name>",
            "Sync one page of Salix L2 results into a dataset",
            (yargs) =>
              yargs
                .positional("name", { type: "string", demandOption: true })
                .option("config", {
                  type: "string",
                  demandOption: true,
                  requiresArg: true,
                  description: "Path to evalens.config.json",
                })
                .option("apply", { type: "boolean", default: false })
                .option("evaluated-from", { type: "string", requiresArg: true })
                .option("bootstrap-now", { type: "boolean", default: false })
                .option("reset-cursor", { type: "boolean", default: false })
                .option("group-id", { type: "string", requiresArg: true })
                .option("min-severity", {
                  type: "number",
                })
                .option("limit", { type: "number", default: 50 }),
            async (argv) => {
              const configPath = path.resolve(argv.config);
              const config = await loadEvalensConfig(configPath);
              const summary = await syncSalixL2Dataset({
                name: argv.name,
                config,
                configDir: path.dirname(configPath),
                apply: argv.apply,
                evaluatedFrom: argv.evaluatedFrom,
                bootstrapNow: argv.bootstrapNow,
                resetCursor: argv.resetCursor,
                groupId: argv.groupId,
                minSeverity: argv.minSeverity,
                limit: argv.limit,
              });
              console.log(JSON.stringify(summary));
            }
          )
          .command(
            "pack <name>",
            "Pack a local dataset into a content-addressed tar archive",
            (yargs) =>
              yargs
                .positional("name", { type: "string", demandOption: true })
                .option("config", {
                  type: "string",
                  demandOption: true,
                  requiresArg: true,
                  description: "Path to evalens.config.json",
                }),
            async (argv) => {
              const configPath = path.resolve(argv.config);
              await loadEvalensConfig(configPath);
              const packed = await packDataset(argv.name, path.dirname(configPath));
              console.log(`${argv.name}@${packed.digest}`);
              console.log(packed.filePath);
            }
          )
          .command(
            "publish <name>",
            "Publish an existing packed dataset to R2",
            (yargs) =>
              yargs
                .positional("name", { type: "string", demandOption: true })
                .option("digest", {
                  type: "string",
                  demandOption: true,
                  requiresArg: true,
                })
                .option("config", {
                  type: "string",
                  demandOption: true,
                  requiresArg: true,
                  description: "Path to a remote evalens.config.json",
                }),
            async (argv) => {
              const configPath = path.resolve(argv.config);
              const config = await loadEvalensConfig(configPath);
              if (!("remote" in config)) {
                throw new Error("dataset publish requires a remote config");
              }
              const result = await publishDataset(
                argv.name,
                argv.digest,
                path.dirname(configPath),
                config.remote.r2
              );
              console.log(
                result.uploaded
                  ? `uploaded ${result.key}`
                  : `already exists ${result.key}`
              );
            }
          )
          .demandCommand(1),
      () => {}
    )
    .demandCommand(1)
    .strict()
    .help()
    .parseAsync();
}

if (import.meta.main) {
  const args = hideBin(Bun.argv);
  try {
    await runCli(args);
  } catch (error) {
    if (!(error instanceof CliQueryError)) throw error;
    const formatted = structuredCliError(error);
    console.error(JSON.stringify(formatted.body));
    process.exitCode = formatted.exitCode;
  }
}
