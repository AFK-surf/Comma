import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { run } from "@evalens/cli/command";
import { type DatasetItem, defineExperiment, RunManifest } from "@evalens/core";
import { keyspace } from "@evalens/store";

type TestItem = DatasetItem<{ value: string }, { value: string }>;

const temporaryDirectories: string[] = [];
const localConfig = (outputDir: string) => ({
  concurrency: 1,
  local: { outputDir },
});

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true }))
  );
});

async function createOutputDir() {
  const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-v2-preflight-"));
  temporaryDirectories.push(outputDir);
  return outputDir;
}

function createDefinition(
  items: TestItem[],
  executed: string[] = [],
  tags: string[] = ["test"]
) {
  let loadCount = 0;
  const definition = defineExperiment({
    name: "run-preflight",
    metadata: { tags },
    datasetLoader() {
      loadCount += 1;
      return { name: "preflight-dataset", items };
    },
    runItem(item) {
      executed.push(item.id);
      return { result: { value: item.input.value }, trajectories: [] };
    },
    evaluators: [
      {
        name: "value",
        version: "1",
        evaluate() {
          return { score: { value: 1 } };
        },
      },
    ],
    aggregator: {
      version: "1",
      aggregate() {
        return {};
      },
    },
  });
  return { definition, getLoadCount: () => loadCount };
}

function item(id: string): TestItem {
  return { id, input: { value: id }, expected: { value: id } };
}

describe("run preflight", () => {
  test("deduplicates tags in first-seen order without normalization", async () => {
    const outputDir = await createOutputDir();
    const { definition } = createDefinition(
      [item("one")],
      [],
      ["Alpha", "alpha", " Alpha ", "Alpha", "alpha"]
    );

    const { runId } = await run(definition, { config: localConfig(outputDir) });
    const manifest = RunManifest.parse(
      await Bun.file(
        path.join(outputDir, keyspace.runManifest(definition.name, runId))
      ).json()
    );

    expect(manifest.tags).toEqual(["Alpha", "alpha", " Alpha "]);
  });

  test("rejects invalid tags before creating a run", async () => {
    for (const tags of [[""], ["é".repeat(65)]]) {
      const outputDir = await createOutputDir();
      const { definition, getLoadCount } = createDefinition([item("one")], [], tags);

      await expect(
        run(definition, { config: localConfig(outputDir) })
      ).rejects.toThrow();
      expect(getLoadCount()).toBe(0);
      expect(await readdir(outputDir)).toEqual([]);
    }
  });

  test("deduplicates filters before selecting items", async () => {
    const outputDir = await createOutputDir();
    const executed: string[] = [];
    const { definition, getLoadCount } = createDefinition(
      [item("one"), item("two")],
      executed
    );

    await run(definition, { config: localConfig(outputDir), filter: ["one", "one"] });

    expect(executed).toEqual(["one"]);
    expect(getLoadCount()).toBe(1);
  });

  test("rejects explicit empty and unknown filters before creating a run", async () => {
    for (const filter of [[], ["missing"]]) {
      const outputDir = await createOutputDir();
      const { definition } = createDefinition([item("one")]);

      await expect(
        run(definition, { config: localConfig(outputDir), filter })
      ).rejects.toThrow();
      expect(await readdir(outputDir)).toEqual([]);
    }
  });

  test("rejects filter item ids containing control characters", async () => {
    for (const filter of [["one\0"], ["one\n"]]) {
      const outputDir = await createOutputDir();
      const { definition } = createDefinition([item("one")]);

      await expect(
        run(definition, { config: localConfig(outputDir), filter })
      ).rejects.toThrow("portable lowercase ASCII");
      expect(await readdir(outputDir)).toEqual([]);
    }
  });

  test("rejects an empty dataset before creating a run", async () => {
    const outputDir = await createOutputDir();
    const { definition } = createDefinition([]);

    await expect(run(definition, { config: localConfig(outputDir) })).rejects.toThrow(
      "dataset must contain at least one item"
    );
    expect(await readdir(outputDir)).toEqual([]);
  });

  test("validates selected item ids before creating a run", async () => {
    for (const items of [
      [item("")],
      [item("duplicate"), item("duplicate")],
      [item("é".repeat(129))],
      [item("line\nbreak")],
      [item("nul\0byte")],
      [item("Uppercase")],
      [item(".hidden")],
      [item("e\u0301")],
    ]) {
      const outputDir = await createOutputDir();
      const { definition } = createDefinition(items);

      await expect(
        run(definition, { config: localConfig(outputDir) })
      ).rejects.toThrow();
      expect(await readdir(outputDir)).toEqual([]);
    }
  });
});
