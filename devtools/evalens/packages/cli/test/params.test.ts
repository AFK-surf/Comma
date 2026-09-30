import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { z } from "zod";

import {
  parseCliParams,
  readCliExperimentRequest,
  readCliParamsFile,
  runCli,
} from "@evalens/cli";
import { run } from "@evalens/cli/command";
import {
  type DatasetItem,
  defineExperiment,
  EvalManifest,
  type EvaluatorOutput,
  Params,
  type ParamsSchema,
  RunManifest,
  type RunOutput,
} from "@evalens/core";
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
  const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-v2-params-"));
  temporaryDirectories.push(outputDir);
  return outputDir;
}

describe("experiment params", () => {
  test("infers schema outputs and persists parsed defaults and transforms", async () => {
    const outputDir = await createOutputDir();
    let datasetParams: unknown;
    const runParams = z.strictObject({
      model: z.string().transform((value) => value.toUpperCase()),
      temperature: z.number().default(0),
    });
    const evalParams = z.strictObject({
      judge: z.string(),
      attempts: z.number().int().positive(),
    });

    const definition = defineExperiment({
      name: "params",
      metadata: { tags: ["test"] },
      params: { run: runParams, eval: evalParams },
      datasetLoader(_source, params) {
        datasetParams = params;
        return {
          name: "params-dataset",
          items: [
            { id: "one", input: { value: "ok" }, expected: { value: "ok" } },
          ] satisfies TestItem[],
        };
      },
      runItem(item, context) {
        const model: string = context.params.model;
        const temperature: number = context.params.temperature;
        // @ts-expect-error Params are inferred from the run schema.
        expect(context.params.judge).toBeUndefined();
        expect({ model, temperature }).toEqual({ model: "GPT-5", temperature: 0 });
        return { result: { value: item.input.value }, trajectories: [] };
      },
      evaluators: [
        {
          name: "judge",
          version: "1",
          evaluate(_item, _result, context) {
            // @ts-expect-error Evaluators receive a status-free completed RunOutput.
            expect(_result.status).toBeUndefined();
            // @ts-expect-error Persisted run timing is not part of RunOutput.
            expect(_result.timing).toBeUndefined();
            const judge: string = context.params.judge;
            const attempts: number = context.params.attempts;
            expect({ judge, attempts }).toEqual({ judge: "gpt-5", attempts: 2 });
            return { score: { value: 1 } };
          },
        },
      ],
      aggregator: {
        version: "1",
        aggregate(results) {
          for (const result of results.judge) {
            const { itemId } = result;
            expect(itemId).toBe("one");
            // @ts-expect-error The keyed aggregator view does not repeat its evaluator name.
            expect(result.evaluator).toBeUndefined();
            // @ts-expect-error Aggregators receive status-free completed outputs.
            expect(result.status).toBeUndefined();
            // @ts-expect-error Persisted evaluator timing is not aggregator input.
            expect(result.timing).toBeUndefined();
            const value: number = result.score.value;
            expect(value).toBe(1);
            // @ts-expect-error Score keys are inferred from the evaluator output.
            expect(result.score.unknown).toBeUndefined();
          }
          // @ts-expect-error Evaluator names are inferred from the evaluator tuple.
          expect(results.unknown).toBeUndefined();
          return {};
        },
      },
    });

    const ids = await run(definition, {
      config: localConfig(outputDir),
      params: {
        run: { model: "gpt-5" },
        eval: { judge: "gpt-5", attempts: 2 },
      },
    });
    const runRoot = path.join(outputDir, keyspace.run(definition.name, ids.runId));

    expect(datasetParams).toEqual({ model: "GPT-5", temperature: 0 });
    expect(
      RunManifest.parse(await Bun.file(path.join(runRoot, "manifest.json")).json())
        .params
    ).toEqual({ model: "GPT-5", temperature: 0 });
    expect(
      EvalManifest.parse(
        await Bun.file(
          path.join(
            outputDir,
            keyspace.evalManifest(definition.name, ids.runId, ids.evalId)
          )
        ).json()
      ).params
    ).toEqual({ judge: "gpt-5", attempts: 2 });
  });

  test("rejects invalid params before running dataset items", async () => {
    const outputDir = await createOutputDir();
    let datasetLoaded = false;
    const runParams = z.strictObject({ model: z.string() });
    const evalParams = z.strictObject({ judge: z.string() });
    const definition = defineExperiment({
      name: "invalid-params",
      metadata: { tags: [] },
      params: { run: runParams, eval: evalParams },
      datasetLoader() {
        datasetLoaded = true;
        return { name: "unused", items: [] };
      },
      runItem() {
        return { result: { value: "unused" }, trajectories: [] };
      },
      evaluators: [
        {
          name: "unused",
          version: "1",
          evaluate() {
            return { score: { unused: 1 } };
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

    await expect(
      run(definition, {
        config: localConfig(outputDir),
        params: { run: { model: 42 } as unknown as { model: string } },
      })
    ).rejects.toThrow();
    expect(datasetLoaded).toBe(false);

    await expect(
      run(definition, {
        config: localConfig(outputDir),
        params: {
          run: { model: "gpt-5" },
          eval: { judge: 42 } as unknown as { judge: string },
        },
      })
    ).rejects.toThrow();
    expect(datasetLoaded).toBe(false);
  });

  test("validates top-level param keys before creating a run", async () => {
    for (const key of ["", "é".repeat(129)]) {
      const outputDir = await createOutputDir();
      let datasetLoaded = false;
      const definition = defineExperiment({
        name: "param-keys",
        metadata: { tags: [] },
        params: { run: z.record(z.string(), z.string()) },
        datasetLoader() {
          datasetLoaded = true;
          return { name: "unused", items: [] satisfies TestItem[] };
        },
        runItem() {
          return { result: { value: "unused" }, trajectories: [] };
        },
        evaluators: [
          {
            name: "unused",
            version: "1",
            evaluate() {
              return { score: { unused: 1 } };
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

      await expect(
        run(definition, {
          config: localConfig(outputDir),
          params: { run: { [key]: "value" } },
        })
      ).rejects.toThrow();
      expect(datasetLoaded).toBe(false);
      expect(await readdir(outputDir)).toEqual([]);
    }
  });

  test("uses strict empty schemas when params schemas are omitted", async () => {
    const outputDir = await createOutputDir();
    const definition = defineExperiment({
      name: "no-params",
      metadata: { tags: [] },
      datasetLoader() {
        return { name: "unused", items: [] };
      },
      runItem(_item, context) {
        expect(context.params).toEqual({});
        return { result: { value: "unused" }, trajectories: [] };
      },
      evaluators: [
        {
          name: "unused",
          version: "1",
          evaluate() {
            return { score: { unused: 1 } };
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

    await expect(
      run(definition, {
        config: localConfig(outputDir),
        params: { run: { unexpected: true } as never },
      })
    ).rejects.toThrow();
  });

  test("parses namespaced CLI params and comma-separated flat arrays", () => {
    const parsed = parseCliParams([
      "--run.model",
      "gpt-5",
      "--run.temperature",
      "0.5",
      "--eval.judge",
      "gpt-5-mini",
      "--eval.thresholds=0.5,0.8",
      "--eval.flags=true,false,null",
    ]);
    expect(parsed).toEqual({
      run: { model: "gpt-5", temperature: 0.5 },
      eval: {
        judge: "gpt-5-mini",
        thresholds: [0.5, 0.8],
        flags: [true, false, null],
      },
    });
    expect(Params.parse((parsed as { eval: Record<string, unknown> }).eval)).toEqual({
      judge: "gpt-5-mini",
      thresholds: [0.5, 0.8],
      flags: [true, false, null],
    });
  });

  test("reads workflow params from one JSON file without scalar reinterpretation", async () => {
    const outputDir = await createOutputDir();
    const paramsFile = path.join(outputDir, "params.json");
    const params = {
      run: {
        values: [1, 2],
        comma: "a,b",
        nullText: "null",
      },
      eval: { model: "gpt-5" },
    };
    await Bun.write(paramsFile, JSON.stringify(params));

    expect(await readCliParamsFile(paramsFile)).toEqual(params);
  });

  test("reads the complete workflow request without shell or argv reinterpretation", async () => {
    const outputDir = await createOutputDir();
    const requestFile = path.join(outputDir, "request.json");
    const request = {
      filter: ["case-a", "case-b"],
      run: { comma: "a,b", nullText: "null" },
      eval: { values: [1, 2] },
    };
    await Bun.write(requestFile, JSON.stringify(request));

    expect(await readCliExperimentRequest(requestFile)).toEqual(request);

    await Bun.write(
      requestFile,
      JSON.stringify({ ...request, filter: ["case\ud800"] })
    );
    await expect(readCliExperimentRequest(requestFile)).rejects.toThrow();
  });

  test("treats an omitted workflow filter as all items and rejects an empty filter", async () => {
    const outputDir = await createOutputDir();
    const requestFile = path.join(outputDir, "request.json");
    const request = { run: { model: "gpt-5" }, eval: {} };
    await Bun.write(requestFile, JSON.stringify(request));

    expect(await readCliExperimentRequest(requestFile)).toEqual(request);

    await Bun.write(requestFile, JSON.stringify({ ...request, filter: [] }));
    await expect(readCliExperimentRequest(requestFile)).rejects.toThrow();
  });

  test("runs the full dataset when a workflow request omits its filter", async () => {
    const outputDir = await createOutputDir();
    const configFile = path.join(outputDir, "evalens.config.json");
    const requestFile = path.join(outputDir, "request.json");
    const runsDir = path.join(outputDir, "runs");
    await Bun.write(
      configFile,
      JSON.stringify({ concurrency: 1, local: { outputDir: "runs" } })
    );
    await Bun.write(requestFile, JSON.stringify({ run: {}, eval: {} }));

    await runCli([
      "run",
      path.resolve("examples/basic.exp.ts"),
      "--config",
      configFile,
      "--request-file",
      requestFile,
    ]);

    const experimentDir = path.join(runsDir, "experiments", "basic", "runs");
    const [runId] = (await readdir(experimentDir)).filter(
      (name) => !name.startsWith(".")
    );
    if (!runId) throw new Error("CLI did not persist a run");
    expect(
      (await readdir(path.join(experimentDir, runId, "items"))).filter(
        (name) => !name.startsWith(".")
      )
    ).toHaveLength(2);
  });

  test("rejects object and nested-array param values at runtime", () => {
    expect(Params.safeParse({ options: { strict: true } }).success).toBe(false);
    expect(Params.safeParse({ values: [[1, 2]] }).success).toBe(false);
    expect(
      Params.safeParse(
        (
          parseCliParams(["--eval.options", '{"strict":true}']) as {
            eval: Record<string, unknown>;
          }
        ).eval
      ).success
    ).toBe(false);
  });
});

// @ts-expect-error Params schema outputs must be top-level JSON-safe records.
const invalidParamsSchema: ParamsSchema = z.strictObject({ createdAt: z.date() });
void invalidParamsSchema;

// @ts-expect-error Param values cannot be objects.
const nestedObjectParamsSchema: ParamsSchema = z.strictObject({
  options: z.object({ strict: z.boolean() }),
});
void nestedObjectParamsSchema;

// @ts-expect-error Param arrays cannot contain arrays.
const nestedArrayParamsSchema: ParamsSchema = z.strictObject({
  values: z.array(z.array(z.number())),
});
void nestedArrayParamsSchema;

const inconsistentScores = defineExperiment({
  name: "inconsistent-scores",
  metadata: { tags: [] },
  datasetLoader() {
    return {
      name: "inconsistent-scores-dataset",
      items: [
        { id: "one", input: { value: "one" }, expected: { value: "one" } },
      ] satisfies TestItem[],
    };
  },
  runItem(item) {
    return { result: { value: item.input.value }, trajectories: [] };
  },
  // @ts-expect-error Direct evaluator branches must return one consistent score shape.
  evaluators: [
    {
      name: "inconsistent",
      version: "1",
      evaluate(item) {
        if (item.id === "one") return { score: { first: 1 } };
        return { score: { second: 1 } };
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
void inconsistentScores;

const invalidRunOutput: RunOutput<{ value: string }> = {
  result: { value: "one" },
  // @ts-expect-error Run status is owned by the framework envelope.
  status: "completed",
};
void invalidRunOutput;

const invalidEvaluatorOutput: EvaluatorOutput = {
  score: { value: 1 },
  // @ts-expect-error Evaluator status is owned by the framework envelope.
  status: "completed",
};
void invalidEvaluatorOutput;
