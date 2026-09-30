export type E2EStatus = "success" | "failure" | "cancelled" | "skipped";

export type ArtifactRecord = {
  runId?: string;
  attempt?: string;
  target?: string;
  status?: E2EStatus;
  branch?: string;
  prNumber?: number;
  finishedAt?: string;
  group?: "report" | "test-results";
  kind?: string;
  path?: string;
  key: string;
  size?: number;
};

export type TargetRecord = {
  target: string;
  status: E2EStatus;
  startedAt?: string;
  finishedAt?: string;
  durationMs?: number;
  summary?: {
    passed: number;
    failed: number;
    flaky: number;
    skipped: number;
  };
  projects?: Array<{
    name: string;
    passed: number;
    failed: number;
    flaky: number;
    skipped: number;
  }>;
  failedTests?: Array<{
    title: string;
    project?: string;
    error?: string;
    location?: string;
  }>;
  reportIndexKey?: string;
  reportRootKey?: string;
  testResultsRootKey?: string;
  artifactCount?: number;
  artifactBytes?: number;
  artifacts?: ArtifactRecord[];
};

export type RunRecord = {
  runId: string;
  attempt: string;
  status: E2EStatus;
  repository?: string;
  branch?: string;
  commitSha?: string;
  commitMessage?: string;
  prNumber?: number;
  workflowName?: string;
  workflowRunId?: string;
  workflowRunAttempt?: string;
  workflowUrl?: string;
  startedAt?: string;
  finishedAt?: string;
  durationMs?: number;
  artifactCount?: number;
  artifactBytes?: number;
  expiresAt?: string;
  targets?: Record<string, TargetRecord>;
  targetOrder?: string[];
};

export type ReportSession = {
  token: string;
  expiresAt: string;
  url: string;
};

export type CleanupPreview = {
  filters: Record<string, unknown>;
  runs: Array<{
    runId: string;
    attempt: string;
    status: E2EStatus;
    branch?: string;
    prNumber?: number;
    finishedAt?: string;
  }>;
  objectCount: number;
  totalBytes: number;
  objects: ArtifactRecord[];
  deletedObjects?: number;
};
