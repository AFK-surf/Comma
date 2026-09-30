import type { CommandModule } from "yargs";

import { migrateRunCommand } from "./migrate-run";
import { runExperimentCommand } from "./run";

export const runCommand: CommandModule = {
  command: "run",
  describe: "Run experiments or migrate completed run data",
  builder: (run) =>
    run.command(migrateRunCommand).command(runExperimentCommand).demandCommand(1),
  handler: () => {},
};
