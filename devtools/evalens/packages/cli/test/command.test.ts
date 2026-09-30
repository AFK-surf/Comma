import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { z } from "zod";

import { migrateRunBetweenStores, reeval, rerun, run } from "@evalens/cli/command";
import {
  type DatasetItem,
  defineExperiment,
  type EvalensStore,
  EvalManifest,
  type RunResult,
  type RunWriterContract,
  RunManifest,
  UPSTREAM_RUN_FAILED_REASON,
} from "@evalens/core";
import { keyspace } from "@evalens/store";
import { createLocalStore } from "@evalens/store/local";

type TestItem = DatasetItem<{ answer: string }, { answer: string }>;

const temporaryDirectories: string[] = [];

const objectPath = (outputDir: string, key: string) => path.join(outputDir, key);
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

describe("commands", () => {
  test("routes run migrate separately from normal experiment execution", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-v2-"));
    temporaryDirectories.push(outputDir);
    const sourceConfigPath = path.join(outputDir, "source.config.json");
    const targetConfigPath = path.join(outputDir, "target.config.json");
    const stderrPath = path.join(outputDir, "cli.stderr.log");
    await Bun.write(sourceConfigPath, JSON.stringify(localConfig(outputDir)));
    await Bun.write(targetConfigPath, JSON.stringify(localConfig(outputDir)));
    const child = Bun.spawn(
      [
        process.execPath,
        "packages/cli/src/index.ts",
        "run",
        "migrate",
        "an-experiment",
        "--from-run",
        Bun.randomUUIDv7(),
        "--source-config",
        sourceConfigPath,
        "--target-config",
        targetConfigPath,
      ],
      {
        cwd: path.resolve(import.meta.dir, "../../.."),
        stderr: Bun.file(stderrPath),
      }
    );

    expect(await child.exited).not.toBe(0);
    expect(await Bun.file(stderrPath).text()).toContain(
      "run migrate requires a remote target config"
    );
  });

  test("CLI exits nonzero after persisting a run item error", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-v2-"));
    temporaryDirectories.push(outputDir);
    const configPath = path.join(outputDir, "evalens.config.json");
    const stderrPath = path.join(outputDir, "cli.stderr.log");
    await Bun.write(configPath, JSON.stringify(localConfig(outputDir)));
    const child = Bun.spawn(
      [
        process.execPath,
        "packages/cli/src/index.ts",
        "run",
        "packages/cli/test/fixtures/run-error.exp.ts",
        "--config",
        configPath,
      ],
      {
        cwd: path.resolve(import.meta.dir, "../../.."),
        stderr: Bun.file(stderrPath),
      }
    );

    expect(await child.exited).not.toBe(0);
    expect(await Bun.file(stderrPath).text()).toContain(
      "Experiment run completed with 1 item error(s)"
    );
  });

  test("runs every item before evaluating persisted run results", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-v2-"));
    temporaryDirectories.push(outputDir);
    const events: string[] = [];

    const definition = defineExperiment({
      name: "two-phase",
      description: "Exercises the successful two-phase path.",
      metadata: { tags: ["test"] },
      datasetLoader() {
        return {
          name: "test-dataset",
          items: [
            {
              id: "one",
              input: { answer: "yes" },
              expected: { answer: "yes" },
              archive: new Bun.Archive({ "fixture.txt": "one" }),
            },
            {
              id: "two",
              input: { answer: "no" },
              expected: { answer: "no" },
              archive: new Bun.Archive({ "fixture.txt": "two" }),
            },
          ] satisfies TestItem[],
        };
      },
      runItem(item, context) {
        events.push(`run:${item.id}`);
        context.logger.info("running item");
        return {
          result: { answer: item.input.answer },
          trajectories: [],
          artifacts: new Bun.Archive({
            "answer.txt": item.input.answer,
          }),
        };
      },
      evaluators: [
        {
          name: "answer",
          version: "1",
          async evaluate(item, runOutput, context) {
            events.push(`eval:${item.id}`);
            context.logger.info("evaluating item");
            expect(await item.archive?.files()).toHaveProperty("size", 1);
            expect(runOutput.artifacts).toBeDefined();
            expect(await runOutput.artifacts?.files()).toHaveProperty("size", 1);
            expect(runOutput.trajectories).toEqual([]);
            return {
              score: {
                answer: runOutput.result.answer === item.expected.answer ? 1 : 0,
              },
            };
          },
        },
      ],
      aggregator: {
        version: "1",
        aggregate(results) {
          return {
            answer: results.answer.reduce(
              (total, result) => total + (result.score.answer ?? 0),
              0
            ),
          };
        },
      },
    });

    const first = await run(definition, { config: localConfig(outputDir) });

    expect(events.slice(0, 2)).toEqual(["run:one", "run:two"]);
    expect(events.slice(2).sort()).toEqual(["eval:one", "eval:two"]);
    const runRoot = objectPath(outputDir, keyspace.run(definition.name, first.runId));
    const runItemRoot = objectPath(
      outputDir,
      keyspace.runItem(definition.name, first.runId, "one")
    );
    const evalItemRoot = objectPath(
      outputDir,
      keyspace.evalItem(definition.name, first.runId, first.evalId, "one")
    );
    const runManifest = RunManifest.parse(
      await Bun.file(path.join(runRoot, "manifest.json")).json()
    );
    expect(runManifest.formatVersion).toBe(2);
    expect(runManifest.status).toBe("finished");
    expect(runManifest.datasetName).toBe("test-dataset");
    expect(runManifest.datasetSelectionDigest).not.toBe(runManifest.datasetDigest);
    expect(runManifest.description).toBe("Exercises the successful two-phase path.");
    expect(await Bun.file(path.join(runItemRoot, "run_result.json")).json()).toEqual({
      status: "completed",
      result: { answer: "yes" },
      timing: {
        startedAt: expect.any(String),
        finishedAt: expect.any(String),
        durationMs: expect.any(Number),
      },
    });
    expect(await Bun.file(path.join(runRoot, "dataset.json")).exists()).toBe(false);
    expect(await Bun.file(path.join(runItemRoot, "trajectories.json")).json()).toEqual(
      []
    );
    expect(await Bun.file(path.join(runItemRoot, "item.json")).json()).toMatchObject({
      itemId: "one",
      itemDigest: expect.any(String),
    });
    expect(await Bun.file(path.join(runItemRoot, "dataset_item.json")).exists()).toBe(
      false
    );
    expect(
      await Bun.file(path.join(runItemRoot, "dataset_item_archive.tar")).exists()
    ).toBe(false);
    expect(await Bun.file(path.join(runItemRoot, "run.log.jsonl")).text()).toContain(
      '"msg":"running item"'
    );
    expect(await Bun.file(path.join(evalItemRoot, "eval.log.jsonl")).text()).toContain(
      '"msg":"evaluating item"'
    );
    expect(await Bun.file(path.join(evalItemRoot, "eval_results.json")).json()).toEqual(
      [
        {
          evaluator: "answer",
          evaluatorVersion: "1",
          status: "completed",
          score: { answer: 1 },
          timing: {
            startedAt: expect.any(String),
            finishedAt: expect.any(String),
            durationMs: expect.any(Number),
          },
        },
      ]
    );

    events.length = 0;
    const second = await reeval(definition, {
      config: localConfig(outputDir),
      runId: first.runId,
    });

    expect(events.sort()).toEqual(["eval:one", "eval:two"]);
    const evalManifest = EvalManifest.parse(
      await Bun.file(
        objectPath(
          outputDir,
          keyspace.evalManifest(definition.name, first.runId, second.evalId)
        )
      ).json()
    );
    expect(evalManifest.formatVersion).toBe(1);
    expect(evalManifest.aggregatorVersion).toBe("1");
    expect(evalManifest.evaluators).toEqual([{ name: "answer", version: "1" }]);
    expect(evalManifest.status).toBe("finished");
    expect(evalManifest.error).toBeUndefined();

    const metadata = new Database(path.join(outputDir, ".evalens", "index.sqlite"), {
      readonly: true,
    });
    expect(metadata.query("SELECT COUNT(*) AS count FROM runs").get()).toEqual({
      count: 1,
    });
    expect(metadata.query("SELECT COUNT(*) AS count FROM run_items").get()).toEqual({
      count: 2,
    });
    expect(metadata.query("SELECT COUNT(*) AS count FROM evals").get()).toEqual({
      count: 2,
    });
    expect(
      metadata
        .query(
          "SELECT dataset_digest, dataset_selection_digest, params_digest FROM runs WHERE run_id = ?"
        )
        .get(first.runId)
    ).toEqual({
      dataset_digest: runManifest.datasetDigest,
      dataset_selection_digest: runManifest.datasetSelectionDigest,
      params_digest: runManifest.paramsDigest,
    });
    metadata.close();
  });

  test("migrates a complete run and selected evaluations through Store writers", async () => {
    const sourceDir = await mkdtemp(path.join(os.tmpdir(), "evalens-migrate-source-"));
    const targetDir = await mkdtemp(path.join(os.tmpdir(), "evalens-migrate-target-"));
    temporaryDirectories.push(sourceDir, targetDir);

    const definition = defineExperiment({
      name: "migrate-complete-run",
      description: "Exercises immutable cross-Store migration.",
      metadata: { tags: ["migration", "test"] },
      datasetLoader() {
        return {
          name: "migrate-dataset",
          items: [
            {
              id: "one",
              input: { answer: "yes" },
              expected: { answer: "yes" },
              archive: new Bun.Archive({ "fixture.txt": "source fixture" }),
            },
          ] satisfies TestItem[],
        };
      },
      runItem(item) {
        return {
          result: { answer: item.input.answer },
          trajectories: [
            {
              id: "lane-one",
              steps: [
                { type: "user", content: "question", timestamp: new Date() },
                {
                  type: "assistant",
                  content: "yes",
                  timestamp: new Date(),
                },
              ],
            },
          ],
          artifacts: new Bun.Archive({ "answer.txt": item.input.answer }),
        };
      },
      evaluators: [
        {
          name: "answer",
          version: "1",
          evaluate(item, output) {
            return {
              score: {
                answer: output.result.answer === item.expected.answer ? 1 : 0,
              },
              explanation: "exact match",
            };
          },
        },
      ],
      aggregator: {
        version: "1",
        aggregate(results) {
          return { answer: results.answer[0]?.score.answer ?? 0 };
        },
      },
    });

    const source = await run(definition, { config: localConfig(sourceDir) });
    await using sourceStore = await createLocalStore({ outputDir: sourceDir });
    await using targetStore = await createLocalStore({ outputDir: targetDir });
    let transientCommitFailures = 1;
    const retryingTargetStore: EvalensStore = {
      async createRun(input) {
        const writer = await targetStore.createRun(input);
        return new (class implements RunWriterContract {
          readonly runId = writer.runId;
          readonly experimentName = writer.experimentName;

          createItemLogger(itemId: string) {
            return writer.createItemLogger(itemId);
          }

          async commitItem<Result extends z.JSONType>(
            itemId: string,
            result: RunResult<Result>,
            itemDigest: string
          ) {
            if (transientCommitFailures > 0) {
              transientCommitFailures -= 1;
              throw Object.assign(new Error("transient R2 timeout"), {
                code: "ConnectionClosed",
              });
            }
            await writer.commitItem(itemId, result, itemDigest);
          }

          async finish() {
            await writer.finish();
          }

          async [Symbol.asyncDispose]() {
            await writer[Symbol.asyncDispose]();
          }
        })();
      },
      openRun(experimentName, runId) {
        return targetStore.openRun(experimentName, runId);
      },
      createEvaluation(run, input) {
        return targetStore.createEvaluation(run, input);
      },
      async [Symbol.asyncDispose]() {},
    };
    const migrated = await migrateRunBetweenStores({
      experimentName: definition.name,
      sourceRunId: source.runId,
      evalIds: [source.evalId],
      sourceStore,
      targetStore: retryingTargetStore,
    });

    expect(transientCommitFailures).toBe(0);
    expect(migrated).toEqual({
      sourceRunId: source.runId,
      runId: expect.any(String),
      itemCount: 1,
      evaluations: [
        {
          sourceEvalId: source.evalId,
          evalId: expect.any(String),
        },
      ],
    });
    expect(migrated.runId).not.toBe(source.runId);
    expect(migrated.evaluations[0]?.evalId).not.toBe(source.evalId);

    const sourceRun = sourceStore.openRun(definition.name, source.runId);
    const targetRun = targetStore.openRun(definition.name, migrated.runId);
    const sourceManifest = await sourceRun.readManifest();
    const targetManifest = await targetRun.readManifest();
    expect(targetManifest).toMatchObject({
      sourceRunId: source.runId,
      experimentName: sourceManifest.experimentName,
      description: sourceManifest.description,
      datasetName: sourceManifest.datasetName,
      datasetDigest: sourceManifest.datasetDigest,
      datasetSelectionDigest: sourceManifest.datasetSelectionDigest,
      selectedItemIds: sourceManifest.selectedItemIds,
      targetItemCount: 1,
      status: "finished",
      tags: sourceManifest.tags,
      params: sourceManifest.params,
      paramsDigest: sourceManifest.paramsDigest,
      adapters: sourceManifest.adapters,
    });

    const [sourceItem] = await Array.fromAsync(
      sourceRun.iterateItems<{ answer: string }>()
    );
    const [targetItem] = await Array.fromAsync(
      targetRun.iterateItems<{ answer: string }>()
    );
    expect(targetItem).toMatchObject({
      itemId: sourceItem?.itemId,
      itemDigest: sourceItem?.itemDigest,
    });
    expect(targetItem?.runResult).toMatchObject({
      status: "completed",
      result: { answer: "yes" },
      timing: sourceItem?.runResult.timing,
      trajectories:
        sourceItem?.runResult.status === "completed"
          ? sourceItem.runResult.trajectories
          : [],
    });
    expect(
      targetItem?.runResult.status === "completed"
        ? await targetItem.runResult.artifacts?.files()
        : undefined
    ).toHaveProperty("size", 1);

    const targetEval = targetRun.openEval(migrated.evaluations[0]!.evalId);
    const sourceEval = sourceRun.openEval(source.evalId);
    expect(await targetEval.readItemResults("one")).toEqual(
      await sourceEval.readItemResults("one")
    );
    expect(await targetEval.readAggregateScores()).toEqual(
      await sourceEval.readAggregateScores()
    );
    expect(await targetEval.readManifest()).toMatchObject({
      runId: migrated.runId,
      status: "finished",
      evaluators: [{ name: "answer", version: "1" }],
      aggregatorVersion: "1",
    });
  });

  test("rejects migration before creating a target run when an item failed", async () => {
    const sourceDir = await mkdtemp(path.join(os.tmpdir(), "evalens-migrate-source-"));
    const targetDir = await mkdtemp(path.join(os.tmpdir(), "evalens-migrate-target-"));
    temporaryDirectories.push(sourceDir, targetDir);
    const definition = defineExperiment({
      name: "migrate-incomplete-run",
      metadata: { tags: ["test"] },
      datasetLoader() {
        return {
          name: "migrate-incomplete-dataset",
          items: [
            {
              id: "failed",
              input: { answer: "no" },
              expected: { answer: "yes" },
            },
          ] satisfies TestItem[],
        };
      },
      runItem() {
        throw new Error("adapter failed");
      },
      evaluators: [
        {
          name: "answer",
          version: "1",
          evaluate() {
            return { score: { answer: 0 } };
          },
        },
      ],
      aggregator: {
        version: "1",
        aggregate() {
          return { answer: 0 };
        },
      },
    });
    const source = await run(definition, { config: localConfig(sourceDir) });
    await using sourceStore = await createLocalStore({ outputDir: sourceDir });
    await using targetStore = await createLocalStore({ outputDir: targetDir });

    await expect(
      migrateRunBetweenStores({
        experimentName: definition.name,
        sourceRunId: source.runId,
        sourceStore,
        targetStore,
      })
    ).rejects.toThrow("only complete runs can be migrated");
    expect(
      await Bun.file(
        objectPath(targetDir, keyspace.experiment(definition.name))
      ).exists()
    ).toBe(false);
  });

  test("derives a complete run by inheriting completed items and rerunning the rest", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-v2-"));
    temporaryDirectories.push(outputDir);
    const runCalls: string[] = [];
    const evalCalls: string[] = [];
    const loadedTiers: string[] = [];
    let failRetryItem = true;

    const definition = defineExperiment({
      name: "derived-rerun",
      description: "Exercises completed-item inheritance.",
      metadata: { tags: ["test"] },
      params: {
        run: z.strictObject({ tier: z.enum(["32k", "256k", "1m"]) }),
      },
      datasetLoader(_source, params) {
        loadedTiers.push(params.tier);
        return {
          name: "derived-rerun-dataset",
          items: ["inherited-one", "retry", "inherited-two"].map((id) => ({
            id,
            input: { answer: id },
            expected: { answer: id },
            archive: new Bun.Archive({ "fixture.txt": id }),
          })) satisfies TestItem[],
        };
      },
      runItem(item, context) {
        runCalls.push(item.id);
        context.logger.info({ itemId: item.id }, "running item");
        if (item.id === "retry" && failRetryItem) {
          failRetryItem = false;
          throw new Error("retry this item in the derived run");
        }
        return {
          result: { answer: item.input.answer },
          trajectories: [],
          artifacts: new Bun.Archive({ "answer.txt": item.input.answer }),
        };
      },
      evaluators: [
        {
          name: "answer",
          version: "1",
          evaluate(item, runOutput) {
            evalCalls.push(item.id);
            return {
              score: {
                answer: runOutput.result.answer === item.expected.answer ? 1 : 0,
              },
            };
          },
        },
      ],
      aggregator: {
        version: "1",
        aggregate(results) {
          return { answer: results.answer.length };
        },
      },
    });

    const source = await run(definition, {
      config: localConfig(outputDir),
      params: { run: { tier: "256k" } },
    });
    expect(source.itemErrorCount).toBe(1);
    expect(loadedTiers).toEqual(["256k"]);
    expect(runCalls.sort()).toEqual(["inherited-one", "inherited-two", "retry"]);
    expect(evalCalls.sort()).toEqual(["inherited-one", "inherited-two"]);

    const sourceCompletedResult = await Bun.file(
      path.join(
        objectPath(
          outputDir,
          keyspace.runItem(definition.name, source.runId, "inherited-one")
        ),
        "run_result.json"
      )
    ).json();
    await rm(
      objectPath(outputDir, keyspace.runItem(definition.name, source.runId, "retry")),
      { recursive: true }
    );

    runCalls.length = 0;
    evalCalls.length = 0;
    const derived = await rerun(definition, {
      config: localConfig(outputDir),
      sourceRunId: source.runId,
    });

    expect(derived).toMatchObject({
      sourceRunId: source.runId,
      inheritedItemCount: 2,
      rerunItemCount: 1,
      itemErrorCount: 0,
    });
    expect(loadedTiers).toEqual(["256k", "256k"]);
    expect(runCalls).toEqual(["retry"]);
    expect(evalCalls.sort()).toEqual(["inherited-one", "inherited-two", "retry"]);

    const derivedRoot = objectPath(
      outputDir,
      keyspace.run(definition.name, derived.runId)
    );
    const derivedManifest = RunManifest.parse(
      await Bun.file(path.join(derivedRoot, "manifest.json")).json()
    );
    expect(derivedManifest).toMatchObject({
      status: "finished",
      sourceRunId: source.runId,
      targetItemCount: 3,
      selectedItemIds: ["inherited-one", "retry", "inherited-two"],
    });

    const inheritedRoot = objectPath(
      outputDir,
      keyspace.runItem(definition.name, derived.runId, "inherited-one")
    );
    expect(await Bun.file(path.join(inheritedRoot, "run_result.json")).json()).toEqual(
      sourceCompletedResult
    );
    expect(await Bun.file(path.join(inheritedRoot, "artifacts.tar")).exists()).toBe(
      true
    );
    expect(
      await Bun.file(path.join(inheritedRoot, "dataset_item_archive.tar")).exists()
    ).toBe(false);
    expect(await Bun.file(path.join(inheritedRoot, "run.log.jsonl")).text()).toContain(
      `"sourceRunId":"${source.runId}"`
    );

    const metadata = new Database(path.join(outputDir, ".evalens", "index.sqlite"), {
      readonly: true,
    });
    expect(
      metadata
        .query(
          "SELECT status, COUNT(*) AS count FROM run_items WHERE run_id = ? GROUP BY status"
        )
        .all(derived.runId)
    ).toEqual([{ status: "completed", count: 3 }]);
    expect(
      metadata
        .query("SELECT COUNT(*) AS count FROM evaluator_results WHERE run_id = ?")
        .get(derived.runId)
    ).toEqual({ count: 3 });
    metadata.close();

    runCalls.length = 0;
    evalCalls.length = 0;
    const forced = await rerun(definition, {
      config: localConfig(outputDir),
      sourceRunId: derived.runId,
      rerunItemIds: ["inherited-one"],
    });

    expect(forced).toMatchObject({
      sourceRunId: derived.runId,
      inheritedItemCount: 2,
      rerunItemCount: 1,
      itemErrorCount: 0,
    });
    expect(loadedTiers).toEqual(["256k", "256k", "256k"]);
    expect(runCalls).toEqual(["inherited-one"]);
    expect(evalCalls.sort()).toEqual(["inherited-one", "inherited-two", "retry"]);
  });

  test("rejects a rerun when the current dataset no longer matches the source", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-v2-"));
    temporaryDirectories.push(outputDir);
    let answer = "original";

    const definition = defineExperiment({
      name: "rerun-dataset-drift",
      metadata: { tags: ["test"] },
      datasetLoader() {
        return {
          name: "rerun-dataset-drift-dataset",
          items: [
            { id: "one", input: { answer }, expected: { answer } },
          ] satisfies TestItem[],
        };
      },
      runItem(item) {
        return { result: { answer: item.input.answer }, trajectories: [] };
      },
      evaluators: [
        {
          name: "answer",
          version: "1",
          evaluate() {
            return { score: { answer: 1 } };
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

    const source = await run(definition, { config: localConfig(outputDir) });
    answer = "changed";

    await expect(
      rerun(definition, {
        config: localConfig(outputDir),
        sourceRunId: source.runId,
      })
    ).rejects.toThrow("source run dataset digest mismatch");

    const runsRoot = objectPath(
      outputDir,
      path.posix.join(keyspace.experiment(definition.name), "runs")
    );
    expect(await readdir(runsRoot)).toEqual([source.runId]);
  });

  test("rejects duplicate evaluator names before evaluation", () => {
    expect(() =>
      defineExperiment({
        name: "duplicate-evaluators",
        metadata: { tags: ["test"] },
        datasetLoader() {
          return {
            name: "test-dataset",
            items: [
              {
                id: "one",
                input: { answer: "yes" },
                expected: { answer: "yes" },
              },
            ] satisfies TestItem[],
          };
        },
        runItem(item) {
          return { result: { answer: item.input.answer }, trajectories: [] };
        },
        evaluators: [
          {
            name: "duplicate",
            version: "1",
            evaluate() {
              return { score: { value: 1 } };
            },
          },
          {
            name: "duplicate",
            version: "2",
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
      })
    ).toThrow("duplicate evaluator name: duplicate");
  });

  test("skips failed runs and aggregates only completed evaluator outputs", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-v2-"));
    temporaryDirectories.push(outputDir);
    const evaluatorCalls: string[] = [];
    let aggregatedResults: Record<string, string[]> = {};

    const definition = defineExperiment({
      name: "result-envelopes",
      metadata: { tags: ["test"] },
      datasetLoader() {
        return {
          name: "result-envelopes-dataset",
          items: ["run-error", "eval-error", "completed"].map((id) => ({
            id,
            input: { answer: id },
            expected: { answer: id },
          })) satisfies TestItem[],
        };
      },
      runItem(item) {
        if (item.id === "run-error") throw new Error("run exploded");
        return { result: { answer: item.input.answer }, trajectories: [] };
      },
      evaluators: [
        {
          name: "primary",
          version: "1",
          evaluate(item) {
            evaluatorCalls.push(`primary:${item.id}`);
            if (item.id === "eval-error") throw new Error("eval exploded");
            return { score: { primary: 1 } };
          },
        },
        {
          name: "secondary",
          version: "1",
          evaluate(item) {
            evaluatorCalls.push(`secondary:${item.id}`);
            return { score: { secondary: 1 } };
          },
        },
        {
          name: "always_error",
          version: "1",
          evaluate(item) {
            evaluatorCalls.push(`always_error:${item.id}`);
            throw new Error("always fails");
          },
        },
      ],
      aggregator: {
        version: "1",
        aggregate(results) {
          aggregatedResults = Object.fromEntries(
            Object.entries(results).map(([evaluator, entries]) => [
              evaluator,
              entries.map(({ itemId }) => itemId).sort(),
            ])
          );
          return {};
        },
      },
    });

    const ids = await run(definition, { config: localConfig(outputDir) });
    expect(ids.itemErrorCount).toBe(1);
    const runRoot = objectPath(outputDir, keyspace.run(definition.name, ids.runId));
    const evalRoot = objectPath(
      outputDir,
      keyspace.eval(definition.name, ids.runId, ids.evalId)
    );
    const readEvalResults = async (itemId: string) => {
      const stored = await Bun.file(
        path.join(
          objectPath(
            outputDir,
            keyspace.evalItem(definition.name, ids.runId, ids.evalId, itemId)
          ),
          "eval_results.json"
        )
      ).json();
      return stored;
    };

    expect(evaluatorCalls.sort()).toEqual([
      "always_error:completed",
      "always_error:eval-error",
      "primary:completed",
      "primary:eval-error",
      "secondary:completed",
      "secondary:eval-error",
    ]);
    expect(
      await Bun.file(
        path.join(
          objectPath(
            outputDir,
            keyspace.runItem(definition.name, ids.runId, "run-error")
          ),
          "run_result.json"
        )
      ).json()
    ).toEqual({
      status: "error",
      error: "run exploded",
      timing: {
        startedAt: expect.any(String),
        finishedAt: expect.any(String),
        durationMs: expect.any(Number),
      },
    });
    expect(
      await Bun.file(
        path.join(
          objectPath(
            outputDir,
            keyspace.runItem(definition.name, ids.runId, "run-error")
          ),
          "trajectories.json"
        )
      ).json()
    ).toEqual([]);
    expect(await readEvalResults("run-error")).toEqual([
      {
        evaluator: "primary",
        evaluatorVersion: "1",
        status: "skipped",
        reason: UPSTREAM_RUN_FAILED_REASON,
      },
      {
        evaluator: "secondary",
        evaluatorVersion: "1",
        status: "skipped",
        reason: UPSTREAM_RUN_FAILED_REASON,
      },
      {
        evaluator: "always_error",
        evaluatorVersion: "1",
        status: "skipped",
        reason: UPSTREAM_RUN_FAILED_REASON,
      },
    ]);
    expect(await readEvalResults("eval-error")).toEqual([
      {
        evaluator: "primary",
        evaluatorVersion: "1",
        status: "error",
        error: "eval exploded",
        timing: {
          startedAt: expect.any(String),
          finishedAt: expect.any(String),
          durationMs: expect.any(Number),
        },
      },
      {
        evaluator: "secondary",
        evaluatorVersion: "1",
        status: "completed",
        score: { secondary: 1 },
        timing: {
          startedAt: expect.any(String),
          finishedAt: expect.any(String),
          durationMs: expect.any(Number),
        },
      },
      {
        evaluator: "always_error",
        evaluatorVersion: "1",
        status: "error",
        error: "always fails",
        timing: {
          startedAt: expect.any(String),
          finishedAt: expect.any(String),
          durationMs: expect.any(Number),
        },
      },
    ]);
    expect(aggregatedResults).toEqual({
      primary: ["completed"],
      secondary: ["completed", "eval-error"],
      always_error: [],
    });
    expect(
      RunManifest.parse(await Bun.file(path.join(runRoot, "manifest.json")).json())
        .status
    ).toBe("finished");
    const manifest = EvalManifest.parse(
      await Bun.file(path.join(evalRoot, "manifest.json")).json()
    );
    expect(manifest.status).toBe("finished");
    expect(manifest.error).toBeUndefined();
  });

  test("turns invalid evaluator scores into errors and allows an empty aggregate", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-v2-"));
    temporaryDirectories.push(outputDir);
    let aggregateInputLengths: number[] = [];

    const definition = defineExperiment({
      name: "invalid-evaluator-scores",
      metadata: { tags: ["test"] },
      datasetLoader() {
        return {
          name: "invalid-evaluator-scores-dataset",
          items: [
            { id: "one", input: { answer: "yes" }, expected: { answer: "yes" } },
          ] satisfies TestItem[],
        };
      },
      runItem(item) {
        return { result: { answer: item.input.answer }, trajectories: [] };
      },
      evaluators: [
        {
          name: "empty",
          version: "1",
          evaluate() {
            return { score: {} };
          },
        },
        {
          name: "empty_key",
          version: "1",
          evaluate() {
            return { score: { "": 1 } };
          },
        },
        {
          name: "long_key",
          version: "1",
          evaluate() {
            return { score: { ["a".repeat(129)]: 1 } };
          },
        },
        {
          name: "nonfinite",
          version: "1",
          evaluate() {
            return { score: { value: Number.NaN } };
          },
        },
      ],
      aggregator: {
        version: "1",
        aggregate(results) {
          aggregateInputLengths = Object.values(results).map(
            (entries) => entries.length
          );
          return {};
        },
      },
    });

    const ids = await run(definition, { config: localConfig(outputDir) });
    const evalRoot = objectPath(
      outputDir,
      keyspace.eval(definition.name, ids.runId, ids.evalId)
    );
    const stored = await Bun.file(
      path.join(
        objectPath(
          outputDir,
          keyspace.evalItem(definition.name, ids.runId, ids.evalId, "one")
        ),
        "eval_results.json"
      )
    ).json();
    const results = stored;

    expect(results).toHaveLength(4);
    for (const result of results) {
      expect(result).toMatchObject({
        evaluatorVersion: "1",
        status: "error",
        error: expect.any(String),
        timing: {
          startedAt: expect.any(String),
          finishedAt: expect.any(String),
          durationMs: expect.any(Number),
        },
      });
    }
    expect(aggregateInputLengths).toEqual([0, 0, 0, 0]);
    expect(
      EvalManifest.parse(await Bun.file(path.join(evalRoot, "manifest.json")).json())
        .status
    ).toBe("finished");
  });

  test("marks evaluation error when aggregate scores are invalid", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-v2-"));
    temporaryDirectories.push(outputDir);
    const definition = defineExperiment({
      name: "invalid-aggregate-scores",
      metadata: { tags: ["test"] },
      datasetLoader() {
        return {
          name: "invalid-aggregate-scores-dataset",
          items: [
            { id: "one", input: { answer: "yes" }, expected: { answer: "yes" } },
          ] satisfies TestItem[],
        };
      },
      runItem(item) {
        return { result: { answer: item.input.answer }, trajectories: [] };
      },
      evaluators: [
        {
          name: "answer",
          version: "1",
          evaluate() {
            return { score: { answer: 1 } };
          },
        },
      ],
      aggregator: {
        version: "1",
        aggregate() {
          return { "": Number.POSITIVE_INFINITY };
        },
      },
    });

    let aggregationError: unknown;
    try {
      await run(definition, { config: localConfig(outputDir) });
    } catch (error) {
      aggregationError = error;
    }
    expect(aggregationError).toBeInstanceOf(Error);

    const runsRoot = objectPath(
      outputDir,
      path.posix.join(keyspace.experiment(definition.name), "runs")
    );
    const [runId] = await readdir(runsRoot);
    if (!runId) throw new Error("expected persisted run");
    const [evalId] = await readdir(path.join(runsRoot, runId, "evals"));
    if (!evalId) throw new Error("expected persisted eval");
    const manifest = EvalManifest.parse(
      await Bun.file(
        objectPath(outputDir, keyspace.evalManifest(definition.name, runId, evalId))
      ).json()
    );
    expect(manifest.status).toBe("error");
    expect(manifest.error).toBe((aggregationError as Error).message);
    expect(manifest.evaluators).toEqual([{ name: "answer", version: "1" }]);
  });

  test("reeval rejects running and error runs without creating an eval", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-v2-"));
    temporaryDirectories.push(outputDir);
    const definition = defineExperiment({
      name: "reeval-lifecycle",
      metadata: { tags: ["test"] },
      datasetLoader() {
        return {
          name: "reeval-lifecycle-dataset",
          items: [
            { id: "one", input: { answer: "yes" }, expected: { answer: "yes" } },
          ] satisfies TestItem[],
        };
      },
      runItem(item) {
        return { result: { answer: item.input.answer }, trajectories: [] };
      },
      evaluators: [
        {
          name: "answer",
          version: "1",
          evaluate() {
            return { score: { answer: 1 } };
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
    const ids = await run(definition, { config: localConfig(outputDir) });
    const runRoot = objectPath(outputDir, keyspace.run(definition.name, ids.runId));
    const manifestPath = path.join(runRoot, "manifest.json");
    const evalRoot = path.join(runRoot, "evals");
    const initialEvalIds = await readdir(evalRoot);

    for (const status of ["running", "error"] as const) {
      const manifest = RunManifest.parse(await Bun.file(manifestPath).json());
      manifest.status = status;
      await Bun.write(manifestPath, JSON.stringify(manifest, null, 2));

      await expect(
        reeval(definition, { config: localConfig(outputDir), runId: ids.runId })
      ).rejects.toThrow(`status ${status}`);
      expect(RunManifest.parse(await Bun.file(manifestPath).json()).status).toBe(
        status
      );
      expect(await readdir(evalRoot)).toEqual(initialEvalIds);
    }
  });
});
