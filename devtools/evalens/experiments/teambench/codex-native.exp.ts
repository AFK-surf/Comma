import { loadTeamBenchNativeDataset } from "./dataset";
import { defineCodexNativeExperiment, nativeDescription } from "./experiment";

export default defineCodexNativeExperiment({
  name: "teambench-codex-native",
  description: nativeDescription("Codex"),
  datasetLoader: loadTeamBenchNativeDataset,
});
