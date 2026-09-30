export type DownloadObject =
  | Blob
  | {
      body: ReadableStream;
      httpEtag: string;
      size: number;
      writeHttpMetadata(headers: Headers): void;
    };

export type ResultObjectMetadata = {
  size: number;
  etag?: string;
  contentType?: string;
};

export interface ResultDownloadStore {
  readRunArtifact(
    experimentName: string,
    runId: string,
    itemId: string
  ): Promise<DownloadObject | null>;
  readRunArtifactMetadata(
    experimentName: string,
    runId: string,
    itemId: string
  ): Promise<ResultObjectMetadata | null>;
  readRunLog(
    experimentName: string,
    runId: string,
    itemId: string
  ): Promise<DownloadObject | null>;
  readEvalLog(
    experimentName: string,
    runId: string,
    evalId: string,
    itemId: string
  ): Promise<DownloadObject | null>;
  readRunResult(
    experimentName: string,
    runId: string,
    itemId: string
  ): Promise<DownloadObject | null>;
  readTrajectories(
    experimentName: string,
    runId: string,
    itemId: string
  ): Promise<DownloadObject | null>;
  readEvalResults(
    experimentName: string,
    runId: string,
    evalId: string,
    itemId: string
  ): Promise<DownloadObject | null>;
}
