import { keyspace } from "../keys";
import path from "node:path";

import type { ResultDownloadStore } from "../result-store";

export class R2ResultDownloadStore implements ResultDownloadStore {
  constructor(private readonly bucket: R2Bucket) {}

  readRunArtifact(experimentName: string, runId: string, itemId: string) {
    return this.bucket.get(
      path.posix.join(keyspace.runItem(experimentName, runId, itemId), "artifacts.tar")
    );
  }

  async readRunArtifactMetadata(experimentName: string, runId: string, itemId: string) {
    const object = await this.bucket.head(
      path.posix.join(keyspace.runItem(experimentName, runId, itemId), "artifacts.tar")
    );
    if (!object) return null;
    const headers = new Headers();
    object.writeHttpMetadata(headers);
    return {
      size: object.size,
      etag: object.httpEtag,
      ...(headers.get("content-type")
        ? { contentType: headers.get("content-type")! }
        : {}),
    };
  }

  readRunLog(experimentName: string, runId: string, itemId: string) {
    return this.bucket.get(
      path.posix.join(keyspace.runItem(experimentName, runId, itemId), "run.log.jsonl")
    );
  }

  readEvalLog(experimentName: string, runId: string, evalId: string, itemId: string) {
    return this.bucket.get(
      path.posix.join(
        keyspace.evalItem(experimentName, runId, evalId, itemId),
        "eval.log.jsonl"
      )
    );
  }

  readRunResult(experimentName: string, runId: string, itemId: string) {
    return this.bucket.get(
      path.posix.join(
        keyspace.runItem(experimentName, runId, itemId),
        "run_result.json"
      )
    );
  }

  readTrajectories(experimentName: string, runId: string, itemId: string) {
    return this.bucket.get(
      path.posix.join(
        keyspace.runItem(experimentName, runId, itemId),
        "trajectories.json"
      )
    );
  }

  readEvalResults(
    experimentName: string,
    runId: string,
    evalId: string,
    itemId: string
  ) {
    return this.bucket.get(
      path.posix.join(
        keyspace.evalItem(experimentName, runId, evalId, itemId),
        "eval_results.json"
      )
    );
  }
}
