import { keyspace } from "../keys";
import path from "node:path";

import type { ResultDownloadStore } from "../result-store";

export class LocalResultDownloadStore implements ResultDownloadStore {
  private readonly root: string;

  constructor(outputDir: string) {
    this.root = path.resolve(outputDir);
  }

  readRunArtifact(experimentName: string, runId: string, itemId: string) {
    return this.read(
      path.posix.join(keyspace.runItem(experimentName, runId, itemId), "artifacts.tar"),
      "application/x-tar"
    );
  }

  async readRunArtifactMetadata(experimentName: string, runId: string, itemId: string) {
    const object = await this.readRunArtifact(experimentName, runId, itemId);
    return object instanceof Blob
      ? { size: object.size, ...(object.type ? { contentType: object.type } : {}) }
      : null;
  }

  readRunLog(experimentName: string, runId: string, itemId: string) {
    return this.read(
      path.posix.join(keyspace.runItem(experimentName, runId, itemId), "run.log.jsonl"),
      "application/x-ndjson"
    );
  }

  readEvalLog(experimentName: string, runId: string, evalId: string, itemId: string) {
    return this.read(
      path.posix.join(
        keyspace.evalItem(experimentName, runId, evalId, itemId),
        "eval.log.jsonl"
      ),
      "application/x-ndjson"
    );
  }

  readRunResult(experimentName: string, runId: string, itemId: string) {
    return this.read(
      path.posix.join(
        keyspace.runItem(experimentName, runId, itemId),
        "run_result.json"
      ),
      "application/json"
    );
  }

  readTrajectories(experimentName: string, runId: string, itemId: string) {
    return this.read(
      path.posix.join(
        keyspace.runItem(experimentName, runId, itemId),
        "trajectories.json"
      ),
      "application/json"
    );
  }

  readEvalResults(
    experimentName: string,
    runId: string,
    evalId: string,
    itemId: string
  ) {
    return this.read(
      path.posix.join(
        keyspace.evalItem(experimentName, runId, evalId, itemId),
        "eval_results.json"
      ),
      "application/json"
    );
  }

  private async read(key: string, type: string): Promise<Blob | null> {
    const resolved = path.resolve(this.root, key);
    const relative = path.relative(this.root, resolved);
    if (relative.startsWith("..") || path.isAbsolute(relative)) {
      throw new Error(`result key escapes output directory: ${key}`);
    }
    const file = Bun.file(resolved);
    if (!(await file.exists())) return null;
    return file.slice(0, file.size, type);
  }
}
