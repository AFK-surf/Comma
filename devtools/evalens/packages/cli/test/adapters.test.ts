import { expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { run } from "@evalens/cli/command";
import { EvalensConfigSchema } from "@evalens/cli/config";
import { defineExperiment, EvalManifest, RunManifest } from "@evalens/core";
import { keyspace } from "@evalens/store";

test("declared adapters receive parsed phase config and persist identities", async () => {
  const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-adapters-"));
  try {
    const experiment = defineExperiment({
      name: "adapter-test",
      metadata: { tags: [] },
      adapters: {
        run: ["salix"],
        eval: ["codex"],
      },
      datasetLoader: () => ({
        name: "items",
        items: [{ id: "one", input: "hello", expected: "hello" }],
      }),
      runItem(item, context) {
        expect(context.adapterConfig.salix.tenantId).toBe("evalens");
        expect(context.adapterConfig.salix.token).toBe("salix-token");
        return { result: item.input, trajectories: [] };
      },
      evaluators: [
        {
          name: "configured",
          version: "1",
          evaluate(_item, _output, context) {
            expect(context.adapterConfig.codex.command).toBe("codex-custom");
            return { score: { configured: 1 } };
          },
        },
      ],
      aggregator: {
        version: "1",
        aggregate: () => ({ configured: 1 }),
      },
    });
    const config = EvalensConfigSchema.parse({
      local: { outputDir },
      adapters: {
        salix: { baseUrl: "https://salix.example.com", token: "salix-token" },
        codex: { command: "codex-custom" },
      },
    });

    const { runId, evalId } = await run(experiment, { config });
    const runManifest = RunManifest.parse(
      await Bun.file(
        path.join(outputDir, keyspace.runManifest("adapter-test", runId))
      ).json()
    );
    const evalManifest = EvalManifest.parse(
      await Bun.file(
        path.join(outputDir, keyspace.evalManifest("adapter-test", runId, evalId))
      ).json()
    );
    expect(runManifest.adapters).toEqual([{ name: "salix", version: "1" }]);
    expect(evalManifest.adapters).toEqual([{ name: "codex", version: "1" }]);
  } finally {
    await rm(outputDir, { recursive: true, force: true });
  }
});

test("missing declared adapter config fails before loading the dataset", async () => {
  let datasetLoads = 0;
  const experiment = defineExperiment({
    name: "missing-adapter-test",
    metadata: { tags: [] },
    adapters: { run: ["salix"], eval: [] },
    datasetLoader() {
      datasetLoads += 1;
      return {
        name: "items",
        items: [{ id: "one", input: "hello", expected: "hello" }],
      };
    },
    runItem: (item) => ({ result: item.input, trajectories: [] }),
    evaluators: [
      {
        name: "score",
        version: "1",
        evaluate: () => ({ score: { score: 1 } }),
      },
    ],
    aggregator: { version: "1", aggregate: () => ({ score: 1 }) },
  });
  const config = EvalensConfigSchema.parse({
    local: { outputDir: "unused" },
  });

  await expect(run(experiment, { config })).rejects.toThrow(
    "missing adapter config: salix"
  );
  expect(datasetLoads).toBe(0);
});
