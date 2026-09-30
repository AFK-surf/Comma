import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, stat, utimes } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { z } from "zod";

import { createDatasetSource, packDataset } from "@evalens/cli/dataset";
import { DatasetItem, defineDatasetLoader } from "@evalens/core";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true }))
  );
});

describe("content-addressed datasets", () => {
  test("packs deterministically and includes dotfiles", async () => {
    const configDir = await mkdtemp(path.join(os.tmpdir(), "evalens-dataset-"));
    temporaryDirectories.push(configDir);
    const datasetDir = path.join(configDir, "datasets", "fixture");
    await mkdir(datasetDir, { recursive: true });
    const manifestPath = path.join(datasetDir, "dataset.json");
    await Bun.write(
      manifestPath,
      JSON.stringify({
        name: "fixture",
        items: [{ id: "one", input: null, expected: null }],
      })
    );
    await Bun.write(path.join(datasetDir, ".source-marker"), "pinned");

    const first = await packDataset("fixture", configDir);
    await utimes(manifestPath, new Date(1_000), new Date(2_000));
    const second = await packDataset("fixture", configDir);

    expect(second.digest).toBe(first.digest);
    const archive = new Bun.Archive(await Bun.file(second.filePath).bytes());
    expect((await archive.files()).has(".source-marker")).toBe(true);
  });

  test("packs, verifies, validates, and lazily reads individual item archives", async () => {
    const configDir = await mkdtemp(path.join(os.tmpdir(), "evalens-dataset-"));
    temporaryDirectories.push(configDir);
    const datasetDir = path.join(configDir, "datasets", "fixture");
    await mkdir(path.join(datasetDir, "items"), { recursive: true });
    await Bun.write(
      path.join(datasetDir, "dataset.json"),
      JSON.stringify({
        name: "fixture",
        description: "Fixture dataset",
        items: [
          {
            id: "case-01.alpha_beta",
            input: { value: 1 },
            expected: { value: 2 },
          },
          { id: "two", input: { value: 2 }, expected: { value: 3 } },
        ],
      })
    );
    await Bun.Archive.write(
      path.join(datasetDir, "items", "case-01.alpha_beta.tar"),
      new Bun.Archive({ "workspace.txt": "hello" })
    );
    await Bun.Archive.write(
      path.join(datasetDir, "items", "two.tar"),
      new Bun.Archive({ "workspace.txt": "goodbye" })
    );

    const packed = await packDataset("fixture", configDir);
    expect(packed.filePath).toEndWith(`${packed.digest}.tar`);
    const Item = DatasetItem.extend({
      input: z.object({ value: z.number() }).strict(),
      expected: z.object({ value: z.number() }).strict(),
    });
    const load = defineDatasetLoader({
      name: "fixture",
      digest: packed.digest,
      itemSchema: Item,
    });
    const dataset = await load(
      createDatasetSource(
        { concurrency: 1, local: { outputDir: path.join(configDir, "runs") } },
        configDir
      )
    );

    expect(dataset.description).toBe("Fixture dataset");
    expect(dataset.digest).toBe(packed.digest);
    expect(dataset.items[0]?.input.value).toBe(1);
    await Bun.file(
      path.join(datasetDir, "sha256", packed.digest, "items", "two.tar")
    ).delete();
    const files = await dataset.items[0]?.archive?.files();
    expect(await files?.get("workspace.txt")?.text()).toBe("hello");
    expect(dataset.items[1]?.archive).toBeDefined();
    await expect(dataset.items[1]!.archive!.files()).rejects.toThrow();
  });

  test("rejects non-portable item ids before packing", async () => {
    const configDir = await mkdtemp(path.join(os.tmpdir(), "evalens-dataset-"));
    temporaryDirectories.push(configDir);
    const datasetDir = path.join(configDir, "datasets", "fixture");
    await mkdir(datasetDir, { recursive: true });

    for (const id of [".hidden", "Upper", "\u00e9", "e\u0301", "\u00df"]) {
      await Bun.write(
        path.join(datasetDir, "dataset.json"),
        JSON.stringify({
          name: "fixture",
          items: [{ id, input: null, expected: null }],
        })
      );
      await expect(packDataset("fixture", configDir)).rejects.toThrow(
        "item id must be portable lowercase ASCII"
      );
    }
  });

  test("reports an existing dataset cache lock for manual cleanup", async () => {
    const configDir = await mkdtemp(path.join(os.tmpdir(), "evalens-dataset-"));
    temporaryDirectories.push(configDir);
    const datasetDir = path.join(configDir, "datasets", "fixture");
    await mkdir(datasetDir, { recursive: true });
    await Bun.write(
      path.join(datasetDir, "dataset.json"),
      JSON.stringify({
        name: "fixture",
        items: [{ id: "one", input: null, expected: null }],
      })
    );
    const packed = await packDataset("fixture", configDir);
    const Item = DatasetItem.extend({ input: z.null(), expected: z.null() });
    const load = defineDatasetLoader({
      name: "fixture",
      digest: packed.digest,
      itemSchema: Item,
    });
    const source = createDatasetSource(
      { concurrency: 1, local: { outputDir: path.join(configDir, "runs") } },
      configDir
    );

    const lockDirectory = path.join(datasetDir, "sha256", `${packed.digest}.lock`);
    await mkdir(lockDirectory);
    await expect(load(source)).rejects.toThrow(
      `dataset cache is locked: ${lockDirectory}`
    );
    expect((await stat(lockDirectory)).isDirectory()).toBe(true);
  });

  test("rejects a packed archive whose bytes do not match the reference", async () => {
    const configDir = await mkdtemp(path.join(os.tmpdir(), "evalens-dataset-"));
    temporaryDirectories.push(configDir);
    const archiveDir = path.join(configDir, "datasets", "fixture", "sha256");
    const claimedDigest = "0".repeat(64);
    await mkdir(archiveDir, { recursive: true });
    await Bun.write(path.join(archiveDir, `${claimedDigest}.tar`), "not a tar");
    const Item = DatasetItem.extend({ input: z.json(), expected: z.json() });
    const load = defineDatasetLoader({
      name: "fixture",
      digest: claimedDigest,
      itemSchema: Item,
    });

    expect(
      load(
        createDatasetSource(
          { concurrency: 1, local: { outputDir: path.join(configDir, "runs") } },
          configDir
        )
      )
    ).rejects.toThrow("dataset digest mismatch");
  });
});
