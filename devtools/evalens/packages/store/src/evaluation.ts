import path from "node:path";

import {
  type EvalManifest,
  EvalResult,
  EvalManifest as EvalManifestSchema,
} from "@evalens/core/evaluation";
import type { EvalensLoggerHandle } from "@evalens/core/logger";
import { Score } from "@evalens/core/schemas";
import type {
  EvalReaderContract,
  EvalWriterContract,
} from "@evalens/core/store/contracts";
import { type AggregateScoresMetadata, type EvalManifestMetadata } from "./metadata";
import { evalItemCommitMetadata } from "./metadata-mapping";
import { keyspace } from "./keys";
import { writeObject, type ObjectNamespace } from "./namespace";
import type { Store } from "./store";

export class EvalWriter implements EvalWriterContract {
  constructor(
    private readonly store: Store,
    readonly experimentName: string,
    private manifest: EvalManifest
  ) {}

  get runId(): string {
    return this.manifest.runId;
  }

  get evalId(): string {
    return this.manifest.evalId;
  }

  async initialize(): Promise<void> {
    await this.persistManifest();
  }

  createItemLogger(itemId: string): EvalensLoggerHandle {
    return this.store.createLogger(
      path.posix.join(
        keyspace.evalItem(this.experimentName, this.runId, this.evalId, itemId),
        "eval.log.jsonl"
      ),
      {
        runId: this.runId,
        evalId: this.evalId,
        experimentName: this.experimentName,
        datasetItemId: itemId,
        scope: "eval",
      }
    );
  }

  async commitItem(itemId: string, results: EvalResult[]): Promise<void> {
    this.assertRunning("commit evaluation item");
    const itemKey = keyspace.evalItem(
      this.experimentName,
      this.runId,
      this.evalId,
      itemId
    );
    const storedResults = EvalResult.array().min(1).parse(results);
    // The result array is the eval item commit marker and must be written last.
    await writeObject(
      this.store.namespace,
      path.posix.join(itemKey, "eval_results.json"),
      JSON.stringify(storedResults, null, 2)
    );
    const metadata = evalItemCommitMetadata(this.evalId, this.runId, itemId, results);
    await this.store.indexEval(this.experimentName, this.runId, this.evalId, () =>
      this.store.metadataWriter.commitEvalItem(metadata)
    );
  }

  async saveAggregate(scores: Record<string, number>): Promise<void> {
    this.assertRunning("save evaluation aggregate");
    await writeObject(
      this.store.namespace,
      path.posix.join(
        keyspace.eval(this.experimentName, this.runId, this.evalId),
        "aggregated_eval_results.json"
      ),
      JSON.stringify(scores, null, 2)
    );
    const metadata: AggregateScoresMetadata = { evalId: this.evalId, scores };
    await this.store.indexEval(this.experimentName, this.runId, this.evalId, () =>
      this.store.metadataWriter.replaceAggregateScores(metadata)
    );
  }

  async finish(): Promise<void> {
    if (this.manifest.status === "finished") return;
    if (this.manifest.status !== "running") {
      throw new Error(`cannot finish evaluation with status ${this.manifest.status}`);
    }
    const manifest: EvalManifest = {
      ...this.manifest,
      status: "finished",
      finishedAt: new Date(),
    };
    await this.persistManifest(manifest);
  }

  async fail(error: string): Promise<void> {
    if (this.manifest.status !== "running") return;
    const manifest: EvalManifest = {
      ...this.manifest,
      status: "error",
      error,
      finishedAt: new Date(),
    };
    await this.persistManifest(manifest);
  }

  async [Symbol.asyncDispose](): Promise<void> {
    if (this.manifest.status !== "running") return;
    await this.fail("evaluation did not finish");
  }

  private assertRunning(operation: string): void {
    if (this.manifest.status !== "running") {
      throw new Error(`cannot ${operation} with status ${this.manifest.status}`);
    }
  }

  private async persistManifest(manifest: EvalManifest = this.manifest): Promise<void> {
    await writeObject(
      this.store.namespace,
      keyspace.evalManifest(this.experimentName, this.runId, this.evalId),
      JSON.stringify(manifest, null, 2)
    );
    this.manifest = manifest;
    const metadata: EvalManifestMetadata = {
      ...manifest,
      params: manifest.params,
    };
    await this.store.indexEval(this.experimentName, this.runId, this.evalId, () =>
      this.store.metadataWriter.upsertEvalManifest(metadata)
    );
  }
}

export class EvalReader implements EvalReaderContract {
  constructor(
    private readonly namespace: ObjectNamespace,
    readonly experimentName: string,
    readonly runId: string,
    readonly evalId: string
  ) {}

  async readManifest(): Promise<EvalManifest> {
    return EvalManifestSchema.parse(
      await this.namespace
        .file(keyspace.evalManifest(this.experimentName, this.runId, this.evalId))
        .json()
    );
  }

  async readItemResults(itemId: string): Promise<EvalResult[]> {
    return EvalResult.array()
      .min(1)
      .parse(
        await this.namespace
          .file(
            path.posix.join(
              keyspace.evalItem(this.experimentName, this.runId, this.evalId, itemId),
              "eval_results.json"
            )
          )
          .json()
      );
  }

  async readAggregateScores(): Promise<Record<string, number>> {
    return Score.parse(
      await this.namespace
        .file(
          path.posix.join(
            keyspace.eval(this.experimentName, this.runId, this.evalId),
            "aggregated_eval_results.json"
          )
        )
        .json()
    );
  }
}
