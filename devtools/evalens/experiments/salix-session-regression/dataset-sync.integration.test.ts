import { afterEach, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import type { EvalensConfig } from "@evalens/cli/config";
import { createDatasetSource, packDataset } from "@evalens/cli/dataset";
import { syncSalixL2Dataset } from "@evalens/cli/dataset-sync";

import { SalixSessionRegressionItem } from "./dataset";

const directories: string[] = [];

afterEach(async () => {
  await Promise.all(
    directories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true }))
  );
});

test("a synced Salix result packs and loads through the regression schema", async () => {
  const configDir = await mkdtemp(path.join(os.tmpdir(), "evalens-sync-load-"));
  directories.push(configDir);
  const config: EvalensConfig = {
    concurrency: 1,
    local: { outputDir: path.join(configDir, "runs") },
    adapters: {
      salix: {
        baseUrl: "https://salix.example.test",
        token: "runtime-token",
        tenantId: "tenant-1",
      },
    },
  };
  const request = (async () =>
    Response.json({
      items: [
        {
          source: {
            agent_id: "agent-1",
            session_id: "session-1",
            group_id: "group-1",
            window_key: "agent-1:session-1:2",
          },
          target: { agent_role: "router", runtime_kind: "internal" },
          window: {
            from_message_id: 2,
            to_message_id: 2,
            message_count: 1,
            round_id: "round-1",
          },
          evaluation: {
            evaluator: "judge",
            evaluator_version: "1",
            outcome: "final",
            evaluated_at: "2026-08-12T00:00:00Z",
            max_confirmed_severity: 0.8,
            findings: [
              {
                metric: "confusion",
                verdict: "confirmed",
                score: 0.8,
                reason: "Repeated backtracking",
              },
            ],
          },
          session_records_status: "available",
          session_records: [
            { id: 1, role: "user", content: "Fix the issue" },
            { id: 2, role: "assistant", content: "Wait, I was wrong." },
          ],
        },
      ],
      next_cursor: "packed-cursor",
      has_more: false,
      snapshot_to: "2026-08-13T00:00:00Z",
      consistency: { mode: "eventual_with_overlap", overlap_seconds: 3600 },
    })) as unknown as typeof fetch;

  await syncSalixL2Dataset({
    name: "salix-regressions",
    config,
    configDir,
    apply: true,
    evaluatedFrom: "2026-08-01T00:00:00Z",
    fetch: request,
  });

  const packed = await packDataset("salix-regressions", configDir);
  const loaded = await createDatasetSource(config, configDir).load({
    name: "salix-regressions",
    digest: packed.digest,
    itemSchema: SalixSessionRegressionItem,
  });

  expect(loaded.items).toHaveLength(1);
  expect(loaded.items[0]!.kind).toBe("salix.session_regression_dataset_item");
  expect(loaded.items[0]!.archive).toBeUndefined();
});
