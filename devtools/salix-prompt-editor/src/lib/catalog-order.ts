import type { Category, PromptDocument } from "../../shared/schema";

export type PromptStageId = "router" | "worker" | "other-system" | "tools" | "skills";

export type PromptStage = {
  id: PromptStageId;
  category: Category;
  label: string;
  shortLabel: string;
  description: string;
  documents: PromptDocument[];
};

const stageDefinitions: ReadonlyArray<Omit<PromptStage, "documents">> = [
  {
    id: "router",
    category: "system",
    label: "Router System Prompt",
    shortLabel: "Router",
    description: "生产 compose 顺序；02A / 02B 是互斥 runtime 分支",
  },
  {
    id: "worker",
    category: "system",
    label: "Worker System Prompt",
    shortLabel: "Worker",
    description: "生产 compose 顺序；02A / 02B 是互斥 runtime 分支",
  },
  {
    id: "other-system",
    category: "system",
    label: "Other System Prompts",
    shortLabel: "Other System",
    description: "共用规则与专项运行时",
  },
  {
    id: "tools",
    category: "tool",
    label: "Tool Prompts",
    shortLabel: "Tools",
    description: "工具描述、flags 与 schema",
  },
  {
    id: "skills",
    category: "skill",
    label: "Skill Prompts",
    shortLabel: "Skills",
    description: "SKILL.md 与引用文件",
  },
];

const promptTitles = {
  common: "SalixAgent.ToolPolicy.common_system_prompt",
  routerSource: "SalixAgent.ToolPolicy.router_source_prompt",
  routerExternalSource: "SalixAgent.ToolPolicy.router_external_source_prompt",
  workerSource: "SalixAgent.ToolPolicy.worker_source_prompt",
  workerExternalSource: "SalixAgent.ToolPolicy.worker_external_source_prompt",
  collaborationCommon: "SalixAgent.MultiAgentCollaborationPrompt.common",
  collaborationRouter: "SalixAgent.MultiAgentCollaborationPrompt.router",
  collaborationWorker: "SalixAgent.MultiAgentCollaborationPrompt.worker",
  dynamic: "SalixAgent.ToolPolicy.dynamic_sections",
  routerSlack: "SalixAgent.ToolPolicy.router_slack_mentions_prompt",
  routerLanguage: "SalixAgent.ToolPolicy.router_message_language_prompt",
} as const;

const routerComposition = [
  promptTitles.common,
  promptTitles.routerSource,
  promptTitles.routerExternalSource,
  promptTitles.collaborationCommon,
  promptTitles.collaborationRouter,
  promptTitles.dynamic,
  promptTitles.routerSlack,
  promptTitles.routerLanguage,
];

const workerComposition = [
  promptTitles.common,
  promptTitles.workerSource,
  promptTitles.workerExternalSource,
  promptTitles.collaborationCommon,
  promptTitles.collaborationWorker,
  promptTitles.dynamic,
];

const compositionLabels: Partial<
  Record<"router" | "worker", Partial<Record<string, string>>>
> = {
  router: {
    [promptTitles.common]: "01 · Base · Router / Worker shared",
    [promptTitles.routerSource]: "02A · Source · internal / javascript",
    [promptTitles.routerExternalSource]: "02B · Source · external",
    [promptTitles.collaborationCommon]: "03 · Collaboration base · shared",
    [promptTitles.collaborationRouter]: "04 · Router collaboration",
    [promptTitles.dynamic]: "05–08 · Tool → agent config → skills → instructions",
    [promptTitles.routerSlack]: "09 · Slack mentions",
    [promptTitles.routerLanguage]: "10 · Message language",
  },
  worker: {
    [promptTitles.common]: "01 · Base · Router / Worker shared",
    [promptTitles.workerSource]: "02A · Source · internal / javascript",
    [promptTitles.workerExternalSource]: "02B · Source · external",
    [promptTitles.collaborationCommon]: "03 · Collaboration base · shared",
    [promptTitles.collaborationWorker]: "04 · Worker collaboration",
    [promptTitles.dynamic]: "05–08 · Tool → agent config → skills → instructions",
  },
};

export function buildPromptStages(documents: PromptDocument[]): PromptStage[] {
  const byTitle = new Map(documents.map((document) => [document.title, document]));
  const resolveComposition = (titles: readonly string[]) =>
    titles.flatMap((title) => {
      const document = byTitle.get(title);
      return document ? [document] : [];
    });
  const routerDocuments = resolveComposition(routerComposition);
  const workerDocuments = resolveComposition(workerComposition);
  const composedIds = new Set(
    [...routerDocuments, ...workerDocuments].map((document) => document.id),
  );

  const documentsByStage: Record<PromptStageId, PromptDocument[]> = {
    router: routerDocuments,
    worker: workerDocuments,
    "other-system": documents.filter(
      (document) => document.category === "system" && !composedIds.has(document.id),
    ),
    tools: documents.filter((document) => document.category === "tool"),
    skills: documents.filter((document) => document.category === "skill"),
  };

  return stageDefinitions.map((definition) => ({
    ...definition,
    documents: documentsByStage[definition.id],
  }));
}

export function promptCompositionLabel(
  stageId: PromptStageId,
  document: PromptDocument,
): string | undefined {
  if (stageId !== "router" && stageId !== "worker") return undefined;
  return compositionLabels[stageId]?.[document.title];
}

export function promptStageAnchor(stageId: PromptStageId): string {
  return `prompt-stage-${stageId}`;
}
