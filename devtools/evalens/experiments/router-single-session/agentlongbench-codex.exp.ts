import { CodexAgentLongBenchRunParams } from "./contracts";
import { loadAgentLongBenchDataset } from "./dataset";
import {
  agentLongBenchDescription,
  defineCodexSingleSessionExperiment,
} from "./experiment";

export default defineCodexSingleSessionExperiment({
  name: "agentlongbench-codex-single-session",
  description: agentLongBenchDescription("Codex"),
  datasetTags: ["agentlongbench", "tier-parametrized"],
  runParams: CodexAgentLongBenchRunParams,
  datasetLoader: (source, params) => loadAgentLongBenchDataset[params.tier](source),
  historyTokenBudget: ({ tier }) => (tier === "256k" ? 240_000 : undefined),
});
