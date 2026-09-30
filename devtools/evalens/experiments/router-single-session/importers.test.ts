import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { RouterSingleSessionItem } from "./dataset";
import { loadAgentLongBenchItems } from "./importers";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true }))
  );
});

describe("router single-session source importers", () => {
  test("imports AgentLongBench files with deterministic unrelated priors", async () => {
    const root = await temporaryDirectory();
    await writeJsonLines(
      path.join(root, "ki-c/32k/env_response/count_frequency_env.jsonl"),
      [
        agentLongRow("current", "Count Frequency(Env)", 2),
        agentLongRow("prior", "Count Frequency(Env)", 1),
      ]
    );
    await writeJsonLines(path.join(root, "ki-v/32k/final_guess/intersection.jsonl"), [
      agentLongRow("verbose-current", "Intersection", ["A", "B"]),
      agentLongRow("verbose-prior", "Intersection", ["C"]),
    ]);

    const items = await loadAgentLongBenchItems({
      benchmarkRoot: root,
      itemsPerFile: 1,
    });

    expect(items).toHaveLength(2);
    expect(items.map((item) => item.expected.match).sort()).toEqual([
      "number",
      "token_set_f1",
    ]);
    for (const item of items) {
      expect(() => RouterSingleSessionItem.parse(item)).not.toThrow();
      expect(item.input.priorHistory[0]?.sourceMessageId).not.toBe(
        item.input.currentHistory[0]?.sourceMessageId
      );
      expect(item.source.sourcePath).toStartWith("benchmark/");
    }
  });
});

function agentLongRow(id: string, questionType: string, answer: unknown) {
  return {
    id,
    sample_id: id,
    question_type: questionType,
    question: "Fixture question?",
    answer,
    messages: [
      { role: "system", content: "system" },
      { role: "assistant", content: "guess" },
      { role: "user", content: `feedback for ${id}` },
      { role: "tool", content: `tool result for ${id}` },
    ],
  };
}

async function temporaryDirectory(): Promise<string> {
  const directory = await mkdtemp(path.join(os.tmpdir(), "evalens-importer-"));
  temporaryDirectories.push(directory);
  return directory;
}

async function writeJsonLines(filePath: string, rows: unknown[]): Promise<void> {
  await mkdir(path.dirname(filePath), { recursive: true });
  await Bun.write(filePath, `${rows.map((row) => JSON.stringify(row)).join("\n")}\n`);
}
