import path from "node:path";
import { z } from "zod";

import type { EvalensLoggerHandle } from "@evalens/core/logger";
import { Trajectories } from "@evalens/core/message";
import {
  type RunManifest,
  RunItemReference,
  type RunResult,
  RunManifest as RunManifestSchema,
} from "@evalens/core/run";
import { Timing } from "@evalens/core/schemas";
import type {
  RunReaderContract,
  RunWriterContract,
  StoredRunItem,
  StoredRunItemState,
} from "@evalens/core/store/contracts";
import { omit } from "@evalens/utils";
import type { RunManifestMetadata } from "./metadata";
import { EvalReader } from "./evaluation";
import { keyspace } from "./keys";
import { writeObject, type ObjectNamespace } from "./namespace";
import type { Store } from "./store";
import { runItemCommitMetadata } from "./metadata-mapping";

const StoredRunResult = z.discriminatedUnion("status", [
  z
    .object({
      status: z.literal("completed"),
      result: z.json(),
      timing: Timing,
    })
    .strict(),
  z
    .object({
      status: z.literal("error"),
      error: z.string(),
      timing: Timing,
    })
    .strict(),
]);

export class RunWriter implements RunWriterContract {
  constructor(
    private readonly store: Store,
    private manifest: RunManifest
  ) {}

  get runId(): string {
    return this.manifest.runId;
  }

  get experimentName(): string {
    return this.manifest.experimentName;
  }

  async initialize(): Promise<void> {
    await this.persistManifest();
  }

  createItemLogger(itemId: string): EvalensLoggerHandle {
    return this.store.createLogger(
      path.posix.join(
        keyspace.runItem(this.experimentName, this.runId, itemId),
        "run.log.jsonl"
      ),
      {
        runId: this.runId,
        experimentName: this.experimentName,
        datasetItemId: itemId,
        scope: "run",
      }
    );
  }

  async commitItem<Result extends z.JSONType>(
    itemId: string,
    result: RunResult<Result>,
    itemDigest: string
  ): Promise<void> {
    if (this.manifest.status !== "running") {
      throw new Error(`cannot commit run item with status ${this.manifest.status}`);
    }
    const reference = RunItemReference.parse({ itemId, itemDigest });
    if (!this.manifest.selectedItemIds.includes(reference.itemId)) {
      throw new Error(
        `run item is outside the manifest selection: ${reference.itemId}`
      );
    }
    const itemKey = keyspace.runItem(this.experimentName, this.runId, reference.itemId);
    if (result.status === "completed" && result.artifacts) {
      await writeObject(
        this.store.namespace,
        path.posix.join(itemKey, "artifacts.tar"),
        result.artifacts
      );
    }
    const trajectories =
      result.status === "completed" ? Trajectories.parse(result.trajectories) : [];
    await writeObject(
      this.store.namespace,
      path.posix.join(itemKey, "trajectories.json"),
      JSON.stringify(trajectories, null, 2)
    );
    const persistedResult =
      result.status === "completed"
        ? omit(result, ["artifacts", "trajectories"])
        : result;
    await writeObject(
      this.store.namespace,
      path.posix.join(itemKey, "run_result.json"),
      JSON.stringify(persistedResult, null, 2)
    );

    // The immutable dataset reference is the commit marker and is written last.
    await writeObject(
      this.store.namespace,
      path.posix.join(itemKey, "item.json"),
      JSON.stringify(reference, null, 2)
    );

    const metadata = runItemCommitMetadata(
      this.runId,
      reference.itemId,
      reference.itemDigest,
      result
    );
    await this.store.indexRun(this.experimentName, this.runId, () =>
      this.store.metadataWriter.commitRunItem(metadata)
    );
  }

  async finish(): Promise<void> {
    if (this.manifest.status === "finished") return;
    if (this.manifest.status !== "running") {
      throw new Error(`cannot finish run with status ${this.manifest.status}`);
    }
    const manifest: RunManifest = {
      ...this.manifest,
      status: "finished",
      finishedAt: new Date(),
    };
    await this.persistManifest(manifest);
  }

  async [Symbol.asyncDispose](): Promise<void> {
    if (this.manifest.status !== "running") return;
    const manifest: RunManifest = {
      ...this.manifest,
      status: "error",
      finishedAt: new Date(),
    };
    await this.persistManifest(manifest);
  }

  private async persistManifest(manifest: RunManifest = this.manifest): Promise<void> {
    await writeObject(
      this.store.namespace,
      keyspace.runManifest(this.experimentName, this.runId),
      JSON.stringify(manifest, null, 2)
    );
    this.manifest = manifest;
    const metadata: RunManifestMetadata = {
      ...manifest,
      params: manifest.params,
    };
    await this.store.indexRun(this.experimentName, this.runId, () =>
      this.store.metadataWriter.upsertRunManifest(metadata)
    );
  }
}

export class RunReader implements RunReaderContract {
  constructor(
    protected readonly namespace: ObjectNamespace,
    readonly experimentName: string,
    readonly runId: string
  ) {}

  async readManifest(): Promise<RunManifest> {
    return RunManifestSchema.parse(
      await this.namespace
        .file(keyspace.runManifest(this.experimentName, this.runId))
        .json()
    );
  }

  async *iterateItems<Result extends z.JSONType>(): AsyncIterable<
    StoredRunItem<Result>
  > {
    const prefix = keyspace.runItems(this.experimentName, this.runId);
    for await (const key of this.namespace.list(prefix)) {
      if (!key.endsWith("/item.json")) continue;
      const itemKey = path.posix.dirname(key);
      const reference = RunItemReference.parse(await this.namespace.file(key).json());
      assertReferenceKey(reference.itemId, itemKey);
      yield {
        ...reference,
        runResult: await this.loadRunResult<Result>(itemKey),
      };
    }
  }

  async *iterateItemStates(): AsyncIterable<StoredRunItemState> {
    const prefix = keyspace.runItems(this.experimentName, this.runId);
    for await (const key of this.namespace.list(prefix)) {
      if (!key.endsWith("/item.json")) continue;
      const itemKey = path.posix.dirname(key);
      const reference = RunItemReference.parse(await this.namespace.file(key).json());
      assertReferenceKey(reference.itemId, itemKey);
      const result = StoredRunResult.parse(
        await this.namespace.file(path.posix.join(itemKey, "run_result.json")).json()
      );
      yield { ...reference, status: result.status };
    }
  }

  openEval(evalId: string): EvalReader {
    return new EvalReader(this.namespace, this.experimentName, this.runId, evalId);
  }

  private async loadRunResult<Result extends z.JSONType>(itemKey: string) {
    const storedResult = StoredRunResult.parse(
      await this.namespace.file(path.posix.join(itemKey, "run_result.json")).json()
    );
    if (storedResult.status === "error") return storedResult;

    const trajectoriesFile = this.namespace.file(
      path.posix.join(itemKey, "trajectories.json")
    );
    const trajectories = Trajectories.parse(await trajectoriesFile.json());

    const artifactsFile = this.namespace.file(
      path.posix.join(itemKey, "artifacts.tar")
    );
    return {
      ...storedResult,
      // z.json() validates the payload, but the experiment-specific generic
      // result type is not persisted as a runtime schema.
      result: storedResult.result as Result,
      trajectories,
      artifacts: (await artifactsFile.exists())
        ? new Bun.Archive(await artifactsFile.bytes())
        : undefined,
    };
  }
}

function assertReferenceKey(itemId: string, itemKey: string): void {
  const keyItemId = path.posix.basename(itemKey);
  if (keyItemId !== itemId) {
    throw new Error(`run item id does not match its object key: ${itemId}`);
  }
}
