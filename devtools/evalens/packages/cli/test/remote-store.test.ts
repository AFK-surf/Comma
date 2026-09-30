import { describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { createRemoteStore, S3ObjectNamespace } from "@evalens/cli/store/remote";
import type {
  AggregateScoresMetadata,
  EvalItemCommitMetadata,
  EvalManifestMetadata,
  MetadataWriter,
  RunItemCommitMetadata,
  RunManifestMetadata,
} from "@evalens/store/metadata";
import { digestCanonicalJson } from "@evalens/core/store/digest";
import { LocalObjectNamespace } from "@evalens/store/local";
import { createRemoteIngestionApp } from "@evalens/server";

const runId = "0197fb0d-1595-72b6-85d4-5c29d8101b20";
const evalId = "0197fb0d-1595-72b6-85d4-5c29d8101b21";
const timing = {
  startedAt: new Date("2026-07-11T00:00:00.000Z"),
  finishedAt: new Date("2026-07-11T00:00:00.010Z"),
  durationMs: 10,
};

describe("RemoteStore", () => {
  test("uses directory-bounded prefixes for direct R2 listings", async () => {
    const prefixes: string[] = [];
    const keys = [
      "experiments/basic/runs/one/manifest.json",
      "experiments/basic-v2/runs/two/manifest.json",
    ];
    const client = {
      async list(options: { prefix: string }) {
        prefixes.push(options.prefix);
        return {
          contents: keys
            .filter((key) => key.startsWith(options.prefix))
            .map((key) => ({ key })),
          isTruncated: false,
        };
      },
    } as unknown as Bun.S3Client;

    const listed = await Array.fromAsync(
      new S3ObjectNamespace(client).list("experiments/basic")
    );
    expect(prefixes).toEqual(["experiments/basic/"]);
    expect(listed).toEqual(["experiments/basic/runs/one/manifest.json"]);
  });

  test("uses the native S3 path for small remote objects", async () => {
    const writes: unknown[] = [];
    const client = {
      file() {
        return {
          async write(data: unknown) {
            writes.push(data);
            return 2;
          },
        };
      },
    } as unknown as Bun.S3Client;

    await new S3ObjectNamespace(client).write("manifest.json", "{}");

    expect(writes).toEqual(["{}"]);
  });

  test("bounds large R2 writes through presigned PUT requests", async () => {
    const presignedOptions: Bun.S3FilePresignOptions[] = [];
    const client = {
      file(key: string) {
        return {
          presign(options: Bun.S3FilePresignOptions) {
            presignedOptions.push(options);
            return `https://r2.example/${key}`;
          },
        };
      },
    } as unknown as Bun.S3Client;
    const requests: Request[] = [];
    const fetcher = Object.assign(
      async (
        input: Parameters<typeof fetch>[0],
        init?: Parameters<typeof fetch>[1]
      ) => {
        requests.push(
          typeof input === "string" || input instanceof URL
            ? new Request(input.toString(), init)
            : new Request(input, init)
        );
        return new Response(null, { status: 200 });
      },
      { preconnect(_url: string | URL) {} }
    ) satisfies typeof fetch;

    const payload = new Blob([new Uint8Array(300 * 1024)]);
    await new S3ObjectNamespace(client, fetcher, 5_000).write(
      "experiments/basic/artifacts.tar",
      payload
    );

    expect(presignedOptions).toEqual([{ method: "PUT", expiresIn: 300 }]);
    expect(requests).toHaveLength(1);
    const request = requests[0]!;
    expect(request.method).toBe("PUT");
    expect(request.signal).toBeInstanceOf(AbortSignal);
    expect((await request.arrayBuffer()).byteLength).toBe(payload.size);
  });

  test("writes facts directly while indexing through the Access-protected API", async () => {
    const outputDir = await mkdtemp(path.join(os.tmpdir(), "evalens-remote-"));
    try {
      const metadata = new RecordingMetadataWriter();
      const api = createRemoteIngestionApp(metadata);
      const accessHeaders: string[] = [];
      const fetcher = Object.assign(
        (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
          const request =
            typeof input === "string" || input instanceof URL
              ? new Request(input.toString(), init)
              : new Request(input, init);
          accessHeaders.push(
            `${request.headers.get("CF-Access-Client-Id")}:${request.headers.get("CF-Access-Client-Secret")}`
          );
          return api.handle(request);
        },
        { preconnect(_url: string | URL) {} }
      ) satisfies typeof fetch;
      const ids = [runId, evalId];
      const artifactBytes = new Uint8Array(17 * 1024 * 1024);
      artifactBytes.fill(7);
      await using store = createRemoteStore({
        url: "http://localhost",
        access: { clientId: "client-id", clientSecret: "client-secret" },
        r2: {
          accountId: "account",
          bucket: "evalens-results",
          accessKeyId: "access-key",
          secretAccessKey: "secret-key",
        },
        fetch: fetcher,
        namespace: new LocalObjectNamespace(outputDir),
        createId: () => ids.shift() ?? Bun.randomUUIDv7(),
      });

      const item = {
        id: "one",
        input: { value: 1 },
        expected: { value: 1 },
        custom: "preserved",
      };
      {
        await using writer = await store.createRun({
          sourceRunId: "0197fb0d-1595-72b6-85d4-5c29d8101b19",
          experimentName: "basic",
          description: "Remote store test",
          datasetName: "cases",
          datasetDigest: "dataset-digest",
          datasetSelectionDigest: "dataset-selection-digest",
          selectedItemIds: ["one"],
          targetItemCount: 1,
          tags: ["test"],
          adapters: [],
          params: { model: "test" },
          paramsDigest: digestCanonicalJson({ model: "test" }),
        });
        {
          await using logger = writer.createItemLogger(item.id);
          logger.logger.info("run log");
        }
        await writer.commitItem(
          item.id,
          {
            status: "completed",
            result: { value: 1 },
            artifacts: new Bun.Archive({ "result.bin": artifactBytes }),
            trajectories: [{ id: "trace", steps: [] }],
            timing,
          },
          "item-digest"
        );
        await writer.finish();
      }

      const run = store.openRun("basic", runId);
      const storedItems = await Array.fromAsync(run.iterateItems<{ value: number }>());
      const result = storedItems[0]?.runResult;
      expect(result?.status).toBe("completed");
      const files =
        result?.status === "completed" ? await result.artifacts?.files() : undefined;
      expect(files?.get("result.bin")?.size).toBe(artifactBytes.byteLength);

      {
        await using writer = await store.createEvaluation(run, {
          evaluators: [{ name: "exact", version: "1" }],
          aggregatorVersion: "1",
          adapters: [],
          params: {},
          paramsDigest: digestCanonicalJson({}),
        });
        await writer.commitItem("one", [
          {
            evaluator: "exact",
            evaluatorVersion: "1",
            status: "completed",
            score: { exact: 1 },
            timing,
          },
        ]);
        await writer.saveAggregate({ exact: 1 });
        await writer.finish();
      }

      expect(metadata.runManifests.at(-1)?.status).toBe("finished");
      expect(metadata.runManifests.at(-1)).toMatchObject({
        sourceRunId: "0197fb0d-1595-72b6-85d4-5c29d8101b19",
        selectedItemIds: ["one"],
      });
      expect(await run.readManifest()).toMatchObject({
        sourceRunId: "0197fb0d-1595-72b6-85d4-5c29d8101b19",
        selectedItemIds: ["one"],
      });
      expect(metadata.runItems).toHaveLength(1);
      expect(metadata.evalManifests.at(-1)?.status).toBe("finished");
      expect(metadata.evalItems).toHaveLength(1);
      expect(metadata.aggregates).toEqual([{ evalId, scores: { exact: 1 } }]);
      expect(
        accessHeaders.every((header) => header === "client-id:client-secret")
      ).toBe(true);
    } finally {
      await rm(outputDir, { recursive: true, force: true });
    }
  });
});

class RecordingMetadataWriter implements MetadataWriter {
  readonly runManifests: RunManifestMetadata[] = [];
  readonly runItems: RunItemCommitMetadata[] = [];
  readonly evalManifests: EvalManifestMetadata[] = [];
  readonly evalItems: EvalItemCommitMetadata[] = [];
  readonly aggregates: AggregateScoresMetadata[] = [];

  upsertRunManifest(metadata: RunManifestMetadata): Promise<void> {
    this.runManifests.push(metadata);
    return Promise.resolve();
  }
  commitRunItem(metadata: RunItemCommitMetadata): Promise<void> {
    this.runItems.push(metadata);
    return Promise.resolve();
  }
  upsertEvalManifest(metadata: EvalManifestMetadata): Promise<void> {
    this.evalManifests.push(metadata);
    return Promise.resolve();
  }
  commitEvalItem(metadata: EvalItemCommitMetadata): Promise<void> {
    this.evalItems.push(metadata);
    return Promise.resolve();
  }
  replaceAggregateScores(metadata: AggregateScoresMetadata): Promise<void> {
    this.aggregates.push(metadata);
    return Promise.resolve();
  }
}
