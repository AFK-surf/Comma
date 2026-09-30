import type { ObjectNamespace } from "./namespace";
import { RunReader } from "./run";

export class ResultReader {
  constructor(private readonly namespace: ObjectNamespace) {}

  openRun(experimentName: string, runId: string): RunReader {
    return new RunReader(this.namespace, experimentName, runId);
  }
}
