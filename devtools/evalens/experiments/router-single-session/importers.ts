import path from "node:path";

import type { RouterSingleSessionItem } from "./dataset";
import { AGENTLONGBENCH_REVISION, AGENTLONGBENCH_URL } from "./source-data";

const AGENTLONGBENCH_QUESTION_TYPES = [
  "Count Frequency(Tool)",
  "Find Duplicates(Tool)",
  "Find Target Offsets(Tool)",
  "Count Correctness(Env)",
  "Count Frequency(Env)",
  "Find Round with Largest Value(Env)",
  "Weighted Summation(Env)",
  "Intersection",
] as const;

type AgentLongBenchQuestionType = (typeof AGENTLONGBENCH_QUESTION_TYPES)[number];

export type AgentLongBenchMessage = {
  role: string;
  content?: unknown;
  tool_calls?: unknown;
  [key: string]: unknown;
};

type AgentLongBenchSourceItem = {
  id: string;
  sample_id?: number | string;
  question_type: string;
  question: string;
  answer: unknown;
  messages: AgentLongBenchMessage[];
};

type AgentLongBenchContext = {
  knowledgeMode: "knowledge_intensive" | "knowledge_free";
  responseMode: "concise" | "verbose";
  tokenLength: string;
  relativePath: string;
  layout: "ki-c" | "ki-v" | "kf-c" | "kf-v";
};

export async function loadAgentLongBenchItems(input: {
  benchmarkRoot: string;
  tokenLength?: string;
  itemsPerFile?: number;
}): Promise<RouterSingleSessionItem[]> {
  const tokenLength = input.tokenLength ?? "32k";
  const files: string[] = [];
  const glob = new Bun.Glob(`*/${tokenLength}/*/*.jsonl`);
  for await (const file of glob.scan({
    cwd: input.benchmarkRoot,
    onlyFiles: true,
  })) {
    files.push(file.split(path.sep).join(path.posix.sep));
  }
  files.sort();
  if (files.length === 0) {
    throw new Error(
      `AgentLongBench has no ${tokenLength} JSONL files under ${input.benchmarkRoot}`
    );
  }

  const items: RouterSingleSessionItem[] = [];
  for (const relativePath of files) {
    const filePath = path.join(input.benchmarkRoot, relativePath);
    const rows = Bun.JSONL.parse(
      await Bun.file(filePath).text()
    ) as AgentLongBenchSourceItem[];
    if (rows.length < 2) {
      throw new Error(`${relativePath} must contain at least two source rows`);
    }
    const selected =
      input.itemsPerFile === undefined ? rows : rows.slice(0, input.itemsPerFile);
    const context = parseAgentLongBenchContext(relativePath);
    for (const [index, row] of selected.entries()) {
      const prior = rows[(index + 1) % rows.length];
      if (!prior) throw new Error(`${relativePath} is missing a prior row`);
      items.push(buildAgentLongBenchItem({ row, prior, context }));
    }
  }
  return items;
}

function buildAgentLongBenchItem(input: {
  row: AgentLongBenchSourceItem;
  prior: AgentLongBenchSourceItem;
  context: AgentLongBenchContext;
}): RouterSingleSessionItem {
  const { row, prior, context } = input;
  if (row.id === prior.id) {
    throw new Error(`AgentLongBench item ${row.id} cannot use itself as prior history`);
  }
  const questionType = parseQuestionType(row.question_type);
  const expected = agentLongBenchExpected(
    questionType,
    context.responseMode,
    row.answer
  );
  const id = [
    "agentlongbench",
    context.layout,
    context.tokenLength,
    path.basename(context.relativePath, ".jsonl"),
    row.id,
  ]
    .join("-")
    .replaceAll(/[^a-zA-Z0-9._-]/gu, "-")
    .toLowerCase();

  return {
    id,
    input: {
      priorHistory: [
        {
          role: "user",
          content: formatAgentLongBenchHistory(prior, "Earlier unrelated episode"),
          sourceMessageId: `agentlongbench:${context.relativePath}:${prior.id}:history`,
          metadata: {
            sourceItemId: prior.id,
            sourcePath: context.relativePath,
            projection: "all non-system messages flattened with role labels",
          },
        },
      ],
      currentHistory: [
        {
          role: "user",
          content: formatAgentLongBenchHistory(row, "Current episode"),
          sourceMessageId: `agentlongbench:${context.relativePath}:${row.id}:history`,
          metadata: {
            sourceItemId: row.id,
            sourcePath: context.relativePath,
            projection: "all non-system messages flattened with role labels",
          },
        },
      ],
      probe: {
        message: `${row.question}\n${agentLongBenchAnswerInstruction(
          questionType,
          context.responseMode
        )}`,
      },
      officialEpisodes: {
        current: {
          id: row.id,
          question: row.question,
          messages: row.messages,
        },
        prior: {
          id: prior.id,
          question: prior.question,
          messages: prior.messages,
        },
      },
    },
    expected,
    source: {
      dataset: "agentlongbench",
      revision: AGENTLONGBENCH_REVISION,
      itemId: row.id,
      url: AGENTLONGBENCH_URL,
      evaluator: agentLongBenchEvaluatorLabel(questionType, context.responseMode),
      sourcePath: `benchmark/${context.relativePath}`,
    },
    metadata: {
      questionType,
      historyMode: `official ${context.layout}/${context.tokenLength} transcript projection`,
      knowledgeMode: context.knowledgeMode,
      responseMode: context.responseMode,
      tokenLength: context.tokenLength,
      notes:
        "The prior episode is a different official row from the same file. No synthetic answer or routing instruction is injected.",
    },
    schemaVersion: 1,
    kind: "salix.router_single_session_dataset_item",
  } as RouterSingleSessionItem;
}

function parseAgentLongBenchContext(relativePath: string): AgentLongBenchContext {
  const [layout, tokenLength] = relativePath.split("/");
  if (!isAgentLongBenchLayout(layout) || !tokenLength) {
    throw new Error(`Unsupported AgentLongBench path: ${relativePath}`);
  }
  return {
    layout,
    tokenLength,
    relativePath,
    knowledgeMode: layout.startsWith("ki") ? "knowledge_intensive" : "knowledge_free",
    responseMode: layout.endsWith("-c") ? "concise" : "verbose",
  };
}

function isAgentLongBenchLayout(
  value: string | undefined
): value is AgentLongBenchContext["layout"] {
  return value === "ki-c" || value === "ki-v" || value === "kf-c" || value === "kf-v";
}

function parseQuestionType(value: string): AgentLongBenchQuestionType {
  if (AGENTLONGBENCH_QUESTION_TYPES.includes(value as AgentLongBenchQuestionType)) {
    return value as AgentLongBenchQuestionType;
  }
  throw new Error(`Unsupported AgentLongBench question type: ${value}`);
}

function agentLongBenchExpected(
  questionType: AgentLongBenchQuestionType,
  responseMode: AgentLongBenchContext["responseMode"],
  answer: unknown
): RouterSingleSessionItem["expected"] {
  if (
    questionType === "Count Frequency(Tool)" ||
    questionType === "Count Correctness(Env)" ||
    questionType === "Count Frequency(Env)" ||
    questionType === "Find Round with Largest Value(Env)" ||
    questionType === "Weighted Summation(Env)"
  ) {
    if (typeof answer !== "number") {
      throw new Error(`${questionType} requires a numeric answer`);
    }
    return expected("number", String(answer), [String(answer)]);
  }
  if (questionType === "Find Duplicates(Tool)") {
    if (typeof answer !== "boolean") {
      throw new Error(`${questionType} requires a boolean answer`);
    }
    return expected("boolean", String(answer), [String(answer)]);
  }
  if (questionType === "Find Target Offsets(Tool)") {
    if (!isStringArray(answer) || answer.length !== 2) {
      throw new Error(`${questionType} requires exactly two string answers`);
    }
    return expected("ordered_pair", answer.join(", "), answer);
  }
  if (responseMode === "verbose") {
    if (!isStringArray(answer) || answer.length === 0) {
      throw new Error("Verbose Intersection requires a non-empty string array");
    }
    return expected("token_set_f1", answer.join(", "), answer);
  }
  if (typeof answer !== "string" || answer.length === 0) {
    throw new Error("Concise Intersection requires a string answer");
  }
  return expected("normalized_name", answer, [answer]);
}

function expected(
  match: RouterSingleSessionItem["expected"]["match"],
  answer: string,
  requiredClaims: string[]
): RouterSingleSessionItem["expected"] {
  return { match, answer, requiredClaims, forbiddenClaims: [] };
}

function formatAgentLongBenchHistory(
  row: AgentLongBenchSourceItem,
  heading: string
): string {
  const messages = row.messages.filter((message) => message.role !== "system");
  if (messages.length === 0) {
    throw new Error(`AgentLongBench item ${row.id} has no non-system messages`);
  }
  const rendered = messages.map((message, index) => {
    const content = stringifyContent(message.content);
    const toolCalls =
      message.tool_calls === undefined
        ? ""
        : `\nTOOL_CALLS: ${JSON.stringify(message.tool_calls)}`;
    return `[${index + 1}] ${message.role.toUpperCase()}:\n${content}${toolCalls}`;
  });
  return `${heading} (official AgentLongBench item ${row.id}):\n\n${rendered.join(
    "\n\n"
  )}`;
}

function stringifyContent(value: unknown): string {
  if (typeof value === "string") return value;
  if (value === undefined || value === null) return "";
  return JSON.stringify(value);
}

function agentLongBenchAnswerInstruction(
  questionType: AgentLongBenchQuestionType,
  responseMode: AgentLongBenchContext["responseMode"]
): string {
  if (questionType === "Find Target Offsets(Tool)") {
    return "Return the two values in order as <answer>value1 and value2</answer>.";
  }
  if (questionType === "Intersection" && responseMode === "verbose") {
    return "Return the intersection as a comma-separated list or JSON array inside <answer></answer>.";
  }
  return "Wrap only the final answer in <answer></answer>.";
}

function agentLongBenchEvaluatorLabel(
  questionType: AgentLongBenchQuestionType,
  responseMode: AgentLongBenchContext["responseMode"]
): string {
  if (questionType === "Find Target Offsets(Tool)") {
    return "official ordered pair normalization; exact=1, first-only=0.5";
  }
  if (questionType === "Intersection" && responseMode === "verbose") {
    return "official token-set F1";
  }
  if (questionType === "Intersection") {
    return "official normalized-name accuracy";
  }
  if (questionType === "Find Duplicates(Tool)") {
    return "official boolean accuracy";
  }
  return "official numeric accuracy";
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string");
}
