import { loadTeamBenchNativeDataset } from "./dataset";
import { defineSalixNativeExperiment, nativeDescription } from "./experiment";

export default defineSalixNativeExperiment({
  name: "teambench-salix-native",
  description: nativeDescription("Salix"),
  datasetLoader: loadTeamBenchNativeDataset,
});
