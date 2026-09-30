import path from "node:path";

import type { CodexAppServerHistoryItem } from "@evalens/adapters/codex";
import type { Salix } from "@evalens/adapters/salix";
import { getEncoding } from "js-tiktoken";

import type { RouterSingleSessionPhase } from "./contracts";
import { AgentLongBenchOfficialEpisode, type RouterSingleSessionItem } from "./dataset";
import type { AgentLongBenchMessage } from "./importers";

const CODEX_HISTORY_ENCODING_NAME = "o200k_base";
const codexHistoryEncoding = getEncoding(CODEX_HISTORY_ENCODING_NAME);

export type CodexHistoryWindowStats = {
  strategy: "oldest_message_groups_truncated";
  encoding: typeof CODEX_HISTORY_ENCODING_NAME;
  tokenBudget: number;
  originalEstimatedTokens: number;
  retainedEstimatedTokens: number;
  truncatedEstimatedTokens: number;
  originalMessageGroupCount: number;
  retainedMessageGroupCount: number;
  truncatedMessageGroupCount: number;
  originalItemCount: number;
  retainedItemCount: number;
};

export type CodexWindowedHistory = {
  items: CodexAppServerHistoryItem[];
  stats: CodexHistoryWindowStats;
};

export type SalixWindowedHistory = {
  entries: Salix.TranscriptSeedEntry[];
  stats: CodexHistoryWindowStats;
};

export async function hydrateAgentLongBenchArchive(
  item: RouterSingleSessionItem
): Promise<RouterSingleSessionItem> {
  const descriptor = item.input.officialEpisodeArchive;
  if (!descriptor) return item;
  if (!item.archive) {
    throw new Error(`AgentLongBench item archive is missing: ${item.id}`);
  }
  const files = await item.archive.files();
  const currentFile = files.get(descriptor.currentPath);
  const priorFile = files.get(descriptor.priorPath);
  if (!currentFile || !priorFile) {
    throw new Error(`AgentLongBench item archive is incomplete: ${item.id}`);
  }
  const [currentText, priorText] = await Promise.all([
    currentFile.text(),
    priorFile.text(),
  ]);
  assertSha256(currentText, descriptor.currentSha256, `${item.id}/current`);
  assertSha256(priorText, descriptor.priorSha256, `${item.id}/prior`);
  const { officialEpisodeArchive: _archiveDescriptor, ...input } = item.input;
  return {
    ...item,
    input: {
      ...input,
      officialEpisodes: {
        current: AgentLongBenchOfficialEpisode.parse(JSON.parse(currentText)),
        prior: AgentLongBenchOfficialEpisode.parse(JSON.parse(priorText)),
      },
    },
  };
}

export function salixHistoryForPhase(
  item: RouterSingleSessionItem,
  phase: RouterSingleSessionPhase
): Salix.TranscriptSeedEntry[] {
  if (item.input.officialEpisodes) {
    return officialAgentLongBenchHistory(item, phase);
  }
  return phase === "fresh"
    ? item.input.currentHistory
    : [...item.input.priorHistory, ...item.input.currentHistory];
}

export function codexHistoryForPhase(
  item: RouterSingleSessionItem,
  phase: RouterSingleSessionPhase
): CodexAppServerHistoryItem[] {
  return codexHistoryGroupsForPhase(item, phase).flat();
}

/**
 * Keep the longest chronological suffix that fits the fixed model-visible
 * history budget. A source message is the truncation atom, except that tool
 * outputs are attached to their immediately preceding assistant tool-call
 * group so truncation cannot orphan either side of the exchange.
 */
export function codexWindowedHistoryForPhase(
  item: RouterSingleSessionItem,
  phase: RouterSingleSessionPhase,
  tokenBudget: number
): CodexWindowedHistory {
  if (!Number.isSafeInteger(tokenBudget) || tokenBudget <= 0) {
    throw new Error(`Codex history token budget must be a positive integer`);
  }
  const groups = codexHistoryGroupsForPhase(item, phase);
  const window = codexHistoryWindow(groups, tokenBudget);
  const retainedGroups = groups.slice(window.firstRetainedGroup);
  const items = retainedGroups.flat();
  return {
    items,
    stats: window.stats,
  };
}

/**
 * Apply the exact Codex 240k selection policy to Salix source messages.
 *
 * Token estimates are computed from the Codex adapter-boundary representation,
 * then the matching complete source message/tool groups are seeded into Salix.
 * This preserves the same retained source suffix without rewriting Salix
 * transcript entries into Codex protocol objects.
 */
export function salixWindowedHistoryForPhase(
  item: RouterSingleSessionItem,
  phase: RouterSingleSessionPhase,
  tokenBudget: number
): SalixWindowedHistory {
  if (!Number.isSafeInteger(tokenBudget) || tokenBudget <= 0) {
    throw new Error(`Salix matched history token budget must be a positive integer`);
  }
  if (!item.input.officialEpisodes) {
    throw new Error(
      `Salix matched history windows require AgentLongBench official episodes`
    );
  }
  const groups = officialHistoryGroupPairsForPhase(item, phase);
  const codexGroups = groups.map((group) => group.codex);
  const window = codexHistoryWindow(codexGroups, tokenBudget);
  const retainedGroups = groups.slice(window.firstRetainedGroup);
  return {
    entries: retainedGroups.flatMap((group) => group.salix),
    stats: window.stats,
  };
}

function codexHistoryGroupsForPhase(
  item: RouterSingleSessionItem,
  phase: RouterSingleSessionPhase
): CodexAppServerHistoryItem[][] {
  if (item.input.rawHistory) {
    throw new Error(
      `LongMemEval-V2 raw item ${item.id} must be materialized asynchronously`
    );
  }
  const episodes = item.input.officialEpisodes;
  if (episodes) {
    return officialHistoryGroupPairsForPhase(item, phase).map((group) => group.codex);
  }
  const history =
    phase === "fresh"
      ? item.input.currentHistory
      : [...item.input.priorHistory, ...item.input.currentHistory];
  return history.map((turn) => [
    {
      type: "message",
      role:
        turn.role === "assistant"
          ? "assistant"
          : turn.role === "runtime" || turn.role === "summary"
            ? "system"
            : "user",
      content: [
        {
          type: turn.role === "assistant" ? "output_text" : "input_text",
          text: turn.content,
        },
      ],
    },
  ]);
}

function codexHistoryWindow(
  groups: CodexAppServerHistoryItem[][],
  tokenBudget: number
): {
  firstRetainedGroup: number;
  stats: CodexHistoryWindowStats;
} {
  const groupTokens = groups.map(estimatedCodexHistoryTokens);
  const originalEstimatedTokens = groupTokens.reduce(
    (total, tokens) => total + tokens,
    0
  );
  let retainedEstimatedTokens = 0;
  let firstRetainedGroup = groups.length;
  for (let index = groups.length - 1; index >= 0; index -= 1) {
    const nextTokens = groupTokens[index] ?? 0;
    if (retainedEstimatedTokens + nextTokens > tokenBudget) break;
    retainedEstimatedTokens += nextTokens;
    firstRetainedGroup = index;
  }
  const retainedGroups = groups.slice(firstRetainedGroup);
  return {
    firstRetainedGroup,
    stats: {
      strategy: "oldest_message_groups_truncated",
      encoding: CODEX_HISTORY_ENCODING_NAME,
      tokenBudget,
      originalEstimatedTokens,
      retainedEstimatedTokens,
      truncatedEstimatedTokens: originalEstimatedTokens - retainedEstimatedTokens,
      originalMessageGroupCount: groups.length,
      retainedMessageGroupCount: retainedGroups.length,
      truncatedMessageGroupCount: firstRetainedGroup,
      originalItemCount: groups.reduce((total, group) => total + group.length, 0),
      retainedItemCount: retainedGroups.reduce(
        (total, group) => total + group.length,
        0
      ),
    },
  };
}

function estimatedCodexHistoryTokens(items: CodexAppServerHistoryItem[]): number {
  return codexHistoryEncoding.encode(JSON.stringify(items)).length;
}

type OfficialHistoryGroupPair = {
  codex: CodexAppServerHistoryItem[];
  salix: Salix.TranscriptSeedEntry[];
};

function officialHistoryGroupPairsForPhase(
  item: RouterSingleSessionItem,
  phase: RouterSingleSessionPhase
): OfficialHistoryGroupPair[] {
  const episodes = item.input.officialEpisodes;
  if (!episodes) {
    throw new Error(`AgentLongBench item ${item.id} has no official episodes`);
  }
  const selected =
    phase === "fresh" ? [episodes.current] : [episodes.prior, episodes.current];
  return selected.flatMap((episode) => {
    const groups: OfficialHistoryGroupPair[] = [];
    for (const [index, message] of episode.messages.entries()) {
      const codex = officialMessageToCodexItems(message, episode.id, index);
      const salix = officialAgentLongBenchMessage(message, episode.id, index);
      const previous = groups.at(-1);
      if (
        message.role === "tool" &&
        previous?.codex.some((historyItem) => historyItem.type === "function_call")
      ) {
        previous.codex.push(...codex);
        previous.salix.push(salix);
      } else {
        groups.push({ codex, salix: [salix] });
      }
    }
    return groups;
  });
}

export function rawTrajectoryIdsForPhase(
  item: RouterSingleSessionItem,
  phase: RouterSingleSessionPhase
): string[] {
  const raw = item.input.rawHistory;
  if (!raw) throw new Error(`Item ${item.id} has no raw trajectory history`);
  return phase === "fresh"
    ? [...raw.currentTrajectoryIds]
    : [...raw.priorTrajectoryIds, ...raw.currentTrajectoryIds];
}

export async function readRawTrajectory(
  dataRoot: string,
  trajectoryId: string
): Promise<string> {
  if (
    trajectoryId === "." ||
    trajectoryId === ".." ||
    trajectoryId.includes("/") ||
    trajectoryId.includes("\\")
  ) {
    throw new Error(`Unsafe LongMemEval-V2 trajectory id: ${trajectoryId}`);
  }
  const filePath = path.join(
    dataRoot,
    "trajectory-pool",
    trajectoryId,
    "trajectory.json"
  );
  const file = Bun.file(filePath);
  if (!(await file.exists())) {
    throw new Error(`Missing LongMemEval-V2 trajectory: ${filePath}`);
  }
  return file.text();
}

export function officialAgentLongBenchHistory(
  item: RouterSingleSessionItem,
  phase: RouterSingleSessionPhase
): Salix.TranscriptSeedEntry[] {
  const episodes = item.input.officialEpisodes;
  if (!episodes) {
    throw new Error(`AgentLongBench item ${item.id} has no official episodes`);
  }
  const selected =
    phase === "fresh" ? [episodes.current] : [episodes.prior, episodes.current];
  return selected.flatMap((episode) =>
    episode.messages.map((message, index) =>
      officialAgentLongBenchMessage(message, episode.id, index)
    )
  );
}

export function sha256Text(value: string): string {
  return new Bun.CryptoHasher("sha256").update(value).digest("hex");
}

function assertSha256(content: string, expected: string, label: string): void {
  const actual = sha256Text(content);
  if (actual !== expected) {
    throw new Error(
      `AgentLongBench archive digest mismatch for ${label}: expected ${expected}, received ${actual}`
    );
  }
}

function officialMessageToCodexItems(
  message: AgentLongBenchMessage,
  episodeId: string,
  index: number
): CodexAppServerHistoryItem[] {
  const content = officialMessageContent(message);
  if (message.role === "tool") {
    if (typeof message.tool_call_id !== "string") {
      throw new Error(
        `AgentLongBench tool message ${episodeId}:${index} has no tool_call_id`
      );
    }
    return [
      {
        type: "function_call_output",
        call_id: message.tool_call_id,
        output: content,
      },
    ];
  }
  assertOfficialMessageRole(message, episodeId, index);
  const items: CodexAppServerHistoryItem[] = [];
  if (content || message.role !== "assistant" || message.tool_calls === undefined) {
    items.push({
      type: "message",
      role: message.role,
      content: [
        {
          type: message.role === "assistant" ? "output_text" : "input_text",
          text: content,
        },
      ],
    });
  }
  if (message.role === "assistant" && message.tool_calls !== undefined) {
    const calls = parseOfficialToolCalls(message.tool_calls);
    items.push(
      ...calls.map((call) => ({
        type: "function_call",
        call_id: call.id,
        name: call.name,
        arguments: JSON.stringify(call.args),
      }))
    );
  }
  return items;
}

function officialAgentLongBenchMessage(
  message: AgentLongBenchMessage,
  episodeId: string,
  index: number
): Salix.TranscriptSeedEntry {
  const content = officialMessageContent(message);
  const sourceRefs = {
    dataset: "agentlongbench",
    episode_id: episodeId,
    source_index: index,
    source_role: message.role,
  };
  if (message.role === "system") {
    return {
      role: "runtime",
      type: "agentlongbench.system",
      content,
      sourceRefs,
    };
  }
  if (message.role === "user") return { role: "user", content, sourceRefs };
  if (message.role === "assistant") {
    return {
      role: "assistant",
      content,
      sourceRefs,
      ...(message.tool_calls === undefined
        ? {}
        : { toolCalls: parseOfficialToolCalls(message.tool_calls) }),
    };
  }
  if (message.role === "tool") {
    if (typeof message.tool_call_id !== "string") {
      throw new Error(
        `AgentLongBench tool message ${episodeId}:${index} has no tool_call_id`
      );
    }
    return {
      role: "tool",
      content,
      sourceRefs,
      toolCallId: message.tool_call_id,
      toolName: typeof message.name === "string" ? message.name : undefined,
    };
  }
  throw new Error(
    `Unsupported AgentLongBench message role ${message.role} at ${episodeId}:${index}`
  );
}

function officialMessageContent(message: AgentLongBenchMessage): string {
  return typeof message.content === "string"
    ? message.content
    : message.content == null
      ? ""
      : JSON.stringify(message.content);
}

function assertOfficialMessageRole(
  message: AgentLongBenchMessage,
  episodeId: string,
  index: number
): asserts message is AgentLongBenchMessage & {
  role: "system" | "user" | "assistant";
} {
  if (
    message.role !== "system" &&
    message.role !== "user" &&
    message.role !== "assistant"
  ) {
    throw new Error(
      `Unsupported AgentLongBench message role ${message.role} at ${episodeId}:${index}`
    );
  }
}

function parseOfficialToolCalls(
  value: unknown
): NonNullable<Salix.TranscriptSeedEntry["toolCalls"]> {
  if (!Array.isArray(value)) {
    throw new Error("AgentLongBench assistant tool_calls must be an array");
  }
  return value.map((call, index) => {
    if (!call || typeof call !== "object") {
      throw new Error(`AgentLongBench tool call ${index} is not an object`);
    }
    const record = call as Record<string, unknown>;
    const fn = record.function;
    if (!fn || typeof fn !== "object") {
      throw new Error(`AgentLongBench tool call ${index} has no function object`);
    }
    const functionRecord = fn as Record<string, unknown>;
    if (typeof record.id !== "string" || typeof functionRecord.name !== "string") {
      throw new Error(`AgentLongBench tool call ${index} has no id or function name`);
    }
    const rawArguments = functionRecord.arguments;
    const args =
      typeof rawArguments === "string"
        ? (JSON.parse(rawArguments) as unknown)
        : rawArguments;
    if (!args || typeof args !== "object" || Array.isArray(args)) {
      throw new Error(`AgentLongBench tool call ${index} arguments are not an object`);
    }
    return {
      id: record.id,
      name: functionRecord.name,
      args: args as Record<string, string | number | boolean | null>,
    };
  });
}
