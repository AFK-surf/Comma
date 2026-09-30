import { SalixTripleBranchRunParams } from "./contracts";
import { loadLongMemEvalSingleSessionDataset } from "./dataset";
import {
  defineSalixSingleSessionExperiment,
  longMemEvalDescription,
} from "./experiment";

export default defineSalixSingleSessionExperiment({
  name: "longmemeval-v2-salix-router-single-session",
  description: longMemEvalDescription("Salix Router"),
  datasetTags: ["longmemeval-v2"],
  runParams: SalixTripleBranchRunParams,
  datasetLoader: loadLongMemEvalSingleSessionDataset,
});
