import { CodexTripleBranchRunParams } from "./contracts";
import { loadLongMemEvalSingleSessionDataset } from "./dataset";
import {
  defineCodexSingleSessionExperiment,
  longMemEvalDescription,
} from "./experiment";

export default defineCodexSingleSessionExperiment({
  name: "longmemeval-v2-codex-single-session",
  description: longMemEvalDescription("Codex"),
  datasetTags: ["longmemeval-v2"],
  runParams: CodexTripleBranchRunParams,
  datasetLoader: loadLongMemEvalSingleSessionDataset,
});
