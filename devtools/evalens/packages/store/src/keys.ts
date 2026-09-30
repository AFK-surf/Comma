import path from "node:path";

import { ItemId } from "@evalens/core/schemas";

export const keyspace = {
  reindexMarkers(): string {
    return path.posix.join("control", "reindex-markers", "experiments");
  },

  experimentMarkers(experimentName: string): string {
    return path.posix.join(this.reindexMarkers(), experimentName);
  },

  evaluationScope(evalId: string): string {
    return path.posix.join("control", "evaluation-scopes", `${evalId}.json`);
  },

  experiment(experimentName: string): string {
    return path.posix.join("experiments", experimentName);
  },

  run(experimentName: string, runId: string): string {
    return path.posix.join(this.experiment(experimentName), "runs", runId);
  },

  runManifest(experimentName: string, runId: string): string {
    return path.posix.join(this.run(experimentName, runId), "manifest.json");
  },

  runItems(experimentName: string, runId: string): string {
    return path.posix.join(this.run(experimentName, runId), "items");
  },

  runItem(experimentName: string, runId: string, itemId: string): string {
    return path.posix.join(this.runItems(experimentName, runId), ItemId.parse(itemId));
  },

  eval(experimentName: string, runId: string, evalId: string): string {
    return path.posix.join(this.run(experimentName, runId), "evals", evalId);
  },

  evalManifest(experimentName: string, runId: string, evalId: string): string {
    return path.posix.join(this.eval(experimentName, runId, evalId), "manifest.json");
  },

  evalItems(experimentName: string, runId: string, evalId: string): string {
    return path.posix.join(this.eval(experimentName, runId, evalId), "items");
  },

  evalItem(
    experimentName: string,
    runId: string,
    evalId: string,
    itemId: string
  ): string {
    return path.posix.join(
      this.evalItems(experimentName, runId, evalId),
      ItemId.parse(itemId)
    );
  },

  experimentMarkerDirectory(experimentName: string): string {
    return path.posix.join(this.experimentMarkers(experimentName), "experiment");
  },

  experimentMarker(experimentName: string, markerId?: string): string {
    return path.posix.join(
      this.experimentMarkerDirectory(experimentName),
      markerFileName(markerId)
    );
  },

  runMarkerDirectory(experimentName: string, runId: string): string {
    return path.posix.join(
      this.experimentMarkers(experimentName),
      "runs",
      runId,
      "run"
    );
  },

  runMarker(experimentName: string, runId: string, markerId?: string): string {
    return path.posix.join(
      this.runMarkerDirectory(experimentName, runId),
      markerFileName(markerId)
    );
  },

  evalMarkerDirectory(experimentName: string, runId: string, evalId: string): string {
    return path.posix.join(
      this.experimentMarkers(experimentName),
      "runs",
      runId,
      "evals",
      evalId
    );
  },

  evalMarker(
    experimentName: string,
    runId: string,
    evalId: string,
    markerId?: string
  ): string {
    return path.posix.join(
      this.evalMarkerDirectory(experimentName, runId, evalId),
      markerFileName(markerId)
    );
  },
};

function markerFileName(markerId?: string): string {
  return markerId ? `marker-${markerId}.json` : "marker.json";
}
