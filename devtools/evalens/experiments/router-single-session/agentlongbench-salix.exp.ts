import { SalixAgentLongBenchRunParams } from "./contracts";
import { loadAgentLongBenchDataset } from "./dataset";
import {
  agentLongBenchDescription,
  defineSalixSingleSessionExperiment,
} from "./experiment";

export default defineSalixSingleSessionExperiment({
  name: "agentlongbench-salix-router-single-session",
  description: agentLongBenchDescription("Salix Router"),
  datasetTags: ["agentlongbench", "tier-parametrized"],
  runParams: SalixAgentLongBenchRunParams,
  datasetLoader: (source, params) => loadAgentLongBenchDataset[params.tier](source),
  historyTokenBudget: ({ tier }) => (tier === "256k" ? 240_000 : undefined),
});
