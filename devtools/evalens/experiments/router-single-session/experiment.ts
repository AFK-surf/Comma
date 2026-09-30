import { SalixAdapter } from "@evalens/adapters/salix";
import {
  defineExperiment,
  type Experiment,
  NoParamsSchema,
  type ParamsSchema,
} from "@evalens/core";
import type { z } from "zod";

import { runCodexSingleSession } from "./codex-runtime";
import {
  CodexTripleBranchRunParams,
  logRunDiagnostics,
  SalixTripleBranchRunParams,
  type RouterSingleSessionResult,
} from "./contracts";
import type { RouterSingleSessionItem } from "./dataset";
import {
  routerSingleSessionAggregator,
  routerSingleSessionEvaluator,
  type RouterSingleSessionEvaluators,
} from "./evaluation";
import { hydrateAgentLongBenchArchive } from "./history";
import { runSalixSingleSession } from "./salix-runtime";

type DefinitionInput<
  RunParams extends ParamsSchema,
  RunAdapter extends "salix" | "codex",
> = Pick<
  Experiment<
    RouterSingleSessionItem,
    RouterSingleSessionResult,
    RunParams,
    typeof NoParamsSchema,
    RouterSingleSessionEvaluators,
    readonly [RunAdapter],
    readonly ["codex"]
  >,
  "name" | "description" | "datasetLoader"
> & {
  runParams: RunParams;
  datasetTags: string[];
  historyTokenBudget?: (params: z.output<RunParams>) => number | undefined;
};

export function defineSalixSingleSessionExperiment<
  RunParams extends typeof SalixTripleBranchRunParams,
>(input: DefinitionInput<RunParams, "salix">) {
  return defineExperiment<
    RouterSingleSessionItem,
    RouterSingleSessionResult,
    RouterSingleSessionEvaluators,
    RunParams,
    typeof NoParamsSchema,
    readonly ["salix"],
    readonly ["codex"]
  >({
    name: input.name,
    description: input.description,
    metadata: { tags: [...SALIX_TAGS, ...input.datasetTags] },
    params: { run: input.runParams, eval: NoParamsSchema },
    adapters: { run: ["salix"], eval: ["codex"] },
    datasetLoader: input.datasetLoader,
    async runItem(item, context) {
      const salix = new SalixAdapter(context.adapterConfig.salix);
      const hydratedItem = await hydrateAgentLongBenchArchive(item);
      const output = await runSalixSingleSession({
        salix,
        item: hydratedItem,
        template: context.adapterConfig.salix.templateId ?? "default",
        dataRoot: context.params.dataRoot,
        timeoutMs: context.params.timeoutMs,
        historyTokenBudget: input.historyTokenBudget?.(context.params),
      });
      logRunDiagnostics(context.logger, output.result);
      return output;
    },
    evaluators: [routerSingleSessionEvaluator],
    aggregator: routerSingleSessionAggregator,
  });
}

export function defineCodexSingleSessionExperiment<
  RunParams extends typeof CodexTripleBranchRunParams,
>(input: DefinitionInput<RunParams, "codex">) {
  return defineExperiment<
    RouterSingleSessionItem,
    RouterSingleSessionResult,
    RouterSingleSessionEvaluators,
    RunParams,
    typeof NoParamsSchema,
    readonly ["codex"],
    readonly ["codex"]
  >({
    name: input.name,
    description: input.description,
    metadata: { tags: [...CODEX_TAGS, ...input.datasetTags] },
    params: { run: input.runParams, eval: NoParamsSchema },
    adapters: { run: ["codex"], eval: ["codex"] },
    datasetLoader: input.datasetLoader,
    async runItem(item, context) {
      const hydratedItem = await hydrateAgentLongBenchArchive(item);
      const output = await runCodexSingleSession({
        item: hydratedItem,
        adapterConfig: context.adapterConfig.codex,
        dataRoot: context.params.dataRoot,
        model: context.params.model,
        reasoningEffort: context.params.reasoningEffort,
        timeoutMs: context.params.timeoutMs,
        historyTokenBudget: input.historyTokenBudget?.(context.params),
      });
      logRunDiagnostics(context.logger, output.result);
      return output;
    },
    evaluators: [routerSingleSessionEvaluator],
    aggregator: routerSingleSessionAggregator,
  });
}

const SALIX_TAGS = [
  "salix",
  "router",
  "router-worker",
  "single-session",
  "triple-branch",
  "isolated-agent-groups",
  "causal",
  "hybrid-eval",
];

const CODEX_TAGS = [
  "codex",
  "single-session",
  "triple-branch",
  "isolated-threads",
  "causal",
  "hybrid-eval",
];

export function agentLongBenchDescription(target: "Salix Router" | "Codex"): string {
  const isolation =
    target === "Salix Router"
      ? "互相隔离的 router-worker agent group"
      : "独立 Codex process/thread";
  return `## 实验目的

评估 ${target} 在 AgentLongBench 32k、256k 或 1M 长会话中的三分支 single-session 表现；运行参数 \`tier\` 选择对应的官方 dataset。

## 实验设定

- 每个 item 并行运行 Fresh、Accumulated、Compacted 三个${isolation}。
- Fresh 保持官方 current episode；Accumulated 与 Compacted 获得相同的 prior + current 历史，只有 Compacted 执行显式压缩。
- 256k tier 的两个长历史分支使用相同的 240k 确定性消息组后缀；32k 和 1M 保持完整官方历史。
- 不根据问题或答案选择证据，返回三分支原始任务分数、保留/污染分数及三个派生指标。`;
}

export function longMemEvalDescription(target: "Salix Router" | "Codex"): string {
  const purpose =
    target === "Salix Router"
      ? "把 LongMemEval-V2 的原始轨迹历史映射为三分支，评估 Salix Router 在跨会话记忆累积与显式压缩下的回答变化。"
      : "以 Codex 作为 LongMemEval-V2 三分支 single-session 对照，测量跨会话历史累积和显式压缩对回答质量的影响。";
  const isolation =
    target === "Salix Router"
      ? "互相隔离的 router-worker agent group"
      : "独立 Codex process/thread";
  const delivery =
    target === "Salix Router"
      ? "通过 Salix transcript seed 路径写入各分支；不向 Router 注入派发规则，只评估 Router 最终回答"
      : "通过 thread/inject_items 按官方顺序注入；三分支使用同一 probe、模型与 reasoning effort";
  return `## 实验目的

${purpose}

## 实验设定

- 每个 item 并行运行 Fresh、Accumulated、Compacted 三个${isolation}。
- Fresh 获得官方有序 small haystack；Accumulated 与 Compacted 在相同 haystack 前加入同一组确定性 prior trajectories。
- 原始 trajectory JSON 不裁剪、不摘要、不做证据选择，${delivery}。
- 只有 Compacted 分支执行显式压缩。`;
}
