import { createHash, createHmac } from "node:crypto";
import { readFile, readdir, stat } from "node:fs/promises";
import { extname, join, relative, sep } from "node:path";
import { pathToFileURL } from "node:url";

type JsonRecord = Record<string, any>;
type Status = "success" | "failure" | "cancelled" | "skipped";
type FailureType =
  | "timeout"
  | "assertion"
  | "network"
  | "browser"
  | "application"
  | "unknown";
type ArtifactGroup = "report" | "test-results";
type ArtifactKind =
  | "html-report"
  | "trace"
  | "screenshot"
  | "video"
  | "json"
  | "html"
  | "file";

interface SummaryCounts {
  passed: number;
  failed: number;
  flaky: number;
  skipped: number;
}

interface ProjectSummary extends SummaryCounts {
  name: string;
}

interface FailedTest {
  title: string;
  project: string;
  error: string;
  failureType?: FailureType;
  location?: string | undefined;
}

interface ReportSummary {
  durationMs: number;
  summary: SummaryCounts;
  projects: ProjectSummary[];
  failedTests: FailedTest[];
}

export interface ArtifactFile {
  absolutePath: string;
  group: ArtifactGroup;
  relativePath: string;
  path: string;
  kind: ArtifactKind;
  size: number;
}

interface ManifestArtifact {
  group: ArtifactGroup;
  kind: ArtifactKind;
  path: string;
  key: string;
  size: number;
}

interface GithubMetadata {
  schemaVersion: number;
  repository: string;
  branch: string;
  commitSha: string;
  commitMessage?: string | undefined;
  prNumber?: number | undefined;
  workflowName: string;
  workflowRunId: string;
  workflowRunAttempt: string;
  workflowUrl?: string | undefined;
  status: Status;
  target: string;
  startedAt: string;
  finishedAt: string;
  durationMs: number;
  summary: SummaryCounts;
  projects: ProjectSummary[];
  failedTests: FailedTest[];
  failureTypes: Record<string, number>;
}

interface TargetManifest extends GithubMetadata {
  runId: string;
  attempt: string;
  objectPrefix: string;
  manifestKey: string;
  reportRootKey: string;
  testResultsRootKey: string;
  reportIndexKey: string;
  retentionDays: number;
  expiresAt?: string | undefined;
  artifacts: ManifestArtifact[];
  artifactBytes: number;
}

interface TargetSummary {
  target: string;
  status: Status;
  startedAt?: string | undefined;
  finishedAt?: string | undefined;
  durationMs: number;
  summary: SummaryCounts;
  projects: ProjectSummary[];
  failedTests: FailedTest[];
  failureTypes: Record<string, number>;
  manifestKey?: string | undefined;
  reportIndexKey?: string | undefined;
  reportRootKey?: string | undefined;
  testResultsRootKey?: string | undefined;
  artifactCount: number;
  artifactBytes: number;
  artifacts: ManifestArtifact[];
}

interface RunRecord {
  schemaVersion: number;
  repository?: string | undefined;
  branch?: string | undefined;
  commitSha?: string | undefined;
  commitMessage?: string | undefined;
  prNumber?: number | undefined;
  workflowName?: string | undefined;
  workflowRunId?: string | undefined;
  workflowRunAttempt?: string | undefined;
  workflowUrl?: string | undefined;
  runId?: string | undefined;
  attempt?: string | undefined;
  status?: Status | undefined;
  failureTypes?: Record<string, number> | undefined;
  startedAt?: string | undefined;
  finishedAt?: string | undefined;
  durationMs?: number | undefined;
  targets?: Record<string, TargetSummary> | undefined;
  artifactBytes?: number | undefined;
  artifactCount?: number | undefined;
}

interface R2Config {
  endpoint: string;
  region: string;
  bucket: string;
  accessKeyId: string;
  secretAccessKey: string;
  prefix: string;
}

interface R2ConfigInput {
  endpoint: string | undefined;
  region: string;
  bucket: string;
  accessKeyId: string | undefined;
  secretAccessKey: string | undefined;
  prefix: string;
}

const supportedStatuses = new Set<Status>([
  "success",
  "failure",
  "cancelled",
  "skipped",
]);
const defaultPrefix = "e2e-reports";

export function mapOutcomeToStatus(outcome: unknown): Status {
  if (supportedStatuses.has(outcome as Status)) return outcome as Status;
  return outcome === "cancelled" ? "cancelled" : "failure";
}

function countStatus(project: ProjectSummary | undefined, status: string): void {
  if (!project) return;
  if (status === "expected" || status === "passed") project.passed += 1;
  else if (status === "flaky") project.flaky += 1;
  else if (status === "skipped") project.skipped += 1;
  else project.failed += 1;
}

function lastResult(test: JsonRecord): JsonRecord {
  const results = Array.isArray(test?.results) ? test.results : [];
  return results.at(-1) ?? {};
}

function errorMessage(test: JsonRecord): string {
  const result = lastResult(test);
  const error = result.error ?? result.errors?.[0];
  return String(error?.message ?? error?.value ?? "Test failed");
}

export function classifyFailureMessage(message: unknown): FailureType {
  const normalized = String(message ?? "").toLowerCase();

  if (/timeout|timed out|exceeded/.test(normalized)) return "timeout";
  if (/expect|assert|strict mode|locator/.test(normalized)) return "assertion";
  if (/net::|econn|enotfound|socket|fetch failed|connection/.test(normalized)) {
    return "network";
  }
  if (/browser|page closed|target closed|crash|crashed/.test(normalized)) {
    return "browser";
  }
  if (/console error|uncaught|unhandled|500|404/.test(normalized)) {
    return "application";
  }

  return "unknown";
}

function normalizeFailedTests(failedTests: FailedTest[] = []): FailedTest[] {
  return failedTests.map((test) => ({
    ...test,
    failureType: test.failureType ?? classifyFailureMessage(test.error),
  }));
}

function countFailureTypes(failedTests: FailedTest[] = []): Record<string, number> {
  const counts: Record<string, number> = {};

  for (const test of failedTests) {
    const failureType = test.failureType ?? classifyFailureMessage(test.error);
    counts[failureType] = (counts[failureType] ?? 0) + 1;
  }

  return counts;
}

function visitSpecs(
  suite: JsonRecord,
  visitor: (spec: JsonRecord, suite: JsonRecord) => void
): void {
  for (const spec of suite?.specs ?? []) {
    visitor(spec, suite);
  }

  for (const child of suite?.suites ?? []) {
    visitSpecs(child, visitor);
  }
}

export function summarizePlaywrightReport(report: JsonRecord): ReportSummary {
  const stats = report?.stats ?? {};
  const summary = {
    passed: Number(stats.expected ?? 0),
    failed: Number(stats.unexpected ?? 0),
    flaky: Number(stats.flaky ?? 0),
    skipped: Number(stats.skipped ?? 0),
  };
  const projectsByName = new Map<string, ProjectSummary>();
  const failedTests: FailedTest[] = [];

  for (const suite of report?.suites ?? []) {
    visitSpecs(suite, (spec) => {
      for (const test of spec.tests ?? []) {
        const projectName = test.projectName ?? "default";
        const project = projectsByName.get(projectName) ?? {
          name: projectName,
          passed: 0,
          failed: 0,
          flaky: 0,
          skipped: 0,
        };
        const status = test.status ?? lastResult(test).status ?? "failed";

        countStatus(project, status);
        projectsByName.set(projectName, project);

        if (!["expected", "passed", "skipped"].includes(status)) {
          const error = errorMessage(test);
          failedTests.push({
            title: spec.title ?? "Untitled test",
            project: projectName,
            error,
            failureType: classifyFailureMessage(error),
            ...(spec.file && spec.line
              ? { location: `${spec.file}:${spec.line}` }
              : spec.file
                ? { location: String(spec.file) }
                : {}),
          });
        }
      }
    });
  }

  return {
    durationMs: Number(stats.duration ?? 0),
    summary,
    projects: [...projectsByName.values()],
    failedTests,
  };
}

async function readJsonFile(path: string): Promise<JsonRecord> {
  return JSON.parse(await readFile(path, "utf8"));
}

async function walkFiles(root: string): Promise<string[]> {
  const files: string[] = [];

  async function walk(dir: string): Promise<void> {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const absolutePath = join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(absolutePath);
      } else if (entry.isFile()) {
        files.push(absolutePath);
      }
    }
  }

  try {
    await walk(root);
  } catch (error) {
    if ((error as NodeJS.ErrnoException)?.code !== "ENOENT") throw error;
  }

  return files;
}

function normalizeRelativePath(path: string): string {
  return path.split(sep).join("/");
}

function classifyArtifact(group: ArtifactGroup, path: string): ArtifactKind {
  const lower = path.toLowerCase();

  if (group === "report" && lower === "index.html") return "html-report";
  if (lower.endsWith(".zip") && lower.includes("trace")) return "trace";
  if (/\.(png|jpe?g|webp)$/.test(lower)) return "screenshot";
  if (/\.(webm|mp4|mov)$/.test(lower)) return "video";
  if (lower.endsWith(".json")) return "json";
  if (lower.endsWith(".html")) return "html";
  return "file";
}

export async function collectArtifactFiles({
  target,
  reportDir,
  resultsDir,
}: {
  target: string;
  reportDir?: string;
  resultsDir?: string;
}): Promise<ArtifactFile[]> {
  const groups: { root: string | undefined; group: ArtifactGroup }[] = [
    { root: reportDir, group: "report" },
    { root: resultsDir, group: "test-results" },
  ];
  const collected: ArtifactFile[] = [];

  for (const group of groups) {
    if (!group.root) continue;

    for (const absolutePath of await walkFiles(group.root)) {
      const fileStat = await stat(absolutePath);
      const relativePath = normalizeRelativePath(relative(group.root, absolutePath));

      collected.push({
        absolutePath,
        group: group.group,
        relativePath,
        path: `${target}/${group.group}/${relativePath}`,
        kind: classifyArtifact(group.group, relativePath),
        size: fileStat.size,
      });
    }
  }

  return collected.toSorted((a, b) => a.path.localeCompare(b.path));
}

function readPullRequestNumber(event: JsonRecord): number | undefined {
  const number = event?.pull_request?.number ?? event?.number;
  return Number.isFinite(Number(number)) ? Number(number) : undefined;
}

function readCommitMessage(event: JsonRecord): string | undefined {
  return (
    event?.pull_request?.title ??
    event?.head_commit?.message ??
    event?.commits?.[0]?.message ??
    undefined
  );
}

export function buildGithubMetadata({
  target,
  status,
  startedAt,
  finishedAt,
  durationMs = 0,
  summary,
  projects,
  failedTests,
  env = process.env,
  event = {},
}: {
  target: string;
  status: Status;
  startedAt: string;
  finishedAt: string;
  durationMs?: number;
  summary: SummaryCounts;
  projects: ProjectSummary[];
  failedTests: FailedTest[];
  env?: NodeJS.ProcessEnv;
  event?: JsonRecord;
}): GithubMetadata {
  const repository = env.GITHUB_REPOSITORY ?? "AFK-surf/Comma";
  const runId = env.GITHUB_RUN_ID ?? "local";
  const runAttempt = env.GITHUB_RUN_ATTEMPT ?? "1";
  const serverUrl = env.GITHUB_SERVER_URL ?? "https://github.com";
  const normalizedFailedTests = normalizeFailedTests(failedTests);

  return {
    schemaVersion: 1,
    repository,
    branch: env.GITHUB_HEAD_REF || env.GITHUB_REF_NAME || "local",
    commitSha: env.GITHUB_SHA ?? "local",
    commitMessage: readCommitMessage(event),
    prNumber: readPullRequestNumber(event),
    workflowName: env.GITHUB_WORKFLOW ?? "local",
    workflowRunId: runId,
    workflowRunAttempt: runAttempt,
    workflowUrl:
      runId === "local"
        ? undefined
        : `${serverUrl}/${repository}/actions/runs/${runId}/attempts/${runAttempt}`,
    status,
    target,
    startedAt,
    finishedAt,
    durationMs,
    summary,
    projects,
    failedTests: normalizedFailedTests,
    failureTypes: countFailureTypes(normalizedFailedTests),
  };
}

function normalizePrefix(prefix?: string): string {
  return (prefix || defaultPrefix).replace(/^\/+|\/+$/g, "") || defaultPrefix;
}

function targetBaseKey(
  prefix: string | undefined,
  runId: string,
  attempt: string,
  target: string
): string {
  return `${normalizePrefix(prefix)}/runs/${runId}/${attempt}/${target}`;
}

function retentionDays(status: Status): number {
  return status === "success" ? 7 : 30;
}

function addDays(iso: string | undefined, days: number): string | undefined {
  if (!iso) return undefined;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return undefined;
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString();
}

function artifactBytes(artifacts: { size?: number }[]): number {
  return artifacts.reduce((total, artifact) => total + Number(artifact.size ?? 0), 0);
}

export function buildTargetManifest({
  metadata,
  files,
  prefix = defaultPrefix,
}: {
  metadata: GithubMetadata;
  files: ArtifactFile[];
  prefix?: string;
}): TargetManifest {
  const runId = metadata.workflowRunId;
  const attempt = metadata.workflowRunAttempt;
  const target = metadata.target;
  const baseKey = targetBaseKey(prefix, runId, attempt, target);
  const artifacts = files.map((file) => {
    const root = file.group === "report" ? "report" : "test-results";

    return {
      group: file.group,
      kind: file.kind,
      path: file.relativePath,
      key: `${baseKey}/${root}/${file.relativePath}`,
      size: file.size,
    };
  });
  const reportIndexKey =
    artifacts.find(
      (artifact) => artifact.group === "report" && artifact.path === "index.html"
    )?.key ?? `${baseKey}/report/index.html`;

  return {
    ...metadata,
    schemaVersion: 1,
    runId,
    attempt,
    objectPrefix: baseKey,
    manifestKey: `${baseKey}/manifest.json`,
    reportRootKey: `${baseKey}/report`,
    testResultsRootKey: `${baseKey}/test-results`,
    reportIndexKey,
    retentionDays: retentionDays(metadata.status),
    expiresAt: addDays(metadata.finishedAt, retentionDays(metadata.status)),
    artifacts,
    artifactBytes: artifactBytes(artifacts),
  };
}

function targetSummaryFromManifest(manifest: TargetManifest): TargetSummary {
  const failedTests = normalizeFailedTests(manifest.failedTests ?? []);

  return {
    target: manifest.target,
    status: manifest.status,
    startedAt: manifest.startedAt,
    finishedAt: manifest.finishedAt,
    durationMs: Number(manifest.durationMs ?? 0),
    summary: manifest.summary ?? { passed: 0, failed: 0, flaky: 0, skipped: 0 },
    projects: manifest.projects ?? [],
    failedTests,
    failureTypes: manifest.failureTypes ?? countFailureTypes(failedTests),
    manifestKey: manifest.manifestKey,
    reportIndexKey: manifest.reportIndexKey,
    reportRootKey: manifest.reportRootKey,
    testResultsRootKey: manifest.testResultsRootKey,
    artifactCount: manifest.artifacts?.length ?? 0,
    artifactBytes: Number(
      manifest.artifactBytes ?? artifactBytes(manifest.artifacts ?? [])
    ),
    artifacts: manifest.artifacts ?? [],
  };
}

function aggregateFailureTypes(
  targets: Record<string, TargetSummary>
): Record<string, number> {
  const counts: Record<string, number> = {};

  for (const target of Object.values(targets)) {
    const failureTypes = target.failureTypes ?? countFailureTypes(target.failedTests);
    for (const [failureType, count] of Object.entries(failureTypes)) {
      counts[failureType] = (counts[failureType] ?? 0) + Number(count ?? 0);
    }
  }

  return counts;
}

function aggregateStatus(targets: Record<string, TargetSummary>): Status {
  const statuses = Object.values(targets).map((target) => target.status);
  if (statuses.includes("failure")) return "failure";
  if (statuses.includes("cancelled")) return "cancelled";
  if (statuses.includes("success")) return "success";
  return "skipped";
}

function minIso(...values: (string | undefined)[]): string | undefined {
  return values
    .filter((value): value is string => Boolean(value))
    .toSorted((a, b) => new Date(a).getTime() - new Date(b).getTime())[0];
}

function maxIso(...values: (string | undefined)[]): string | undefined {
  return values
    .filter((value): value is string => Boolean(value))
    .toSorted((a, b) => new Date(b).getTime() - new Date(a).getTime())[0];
}

function durationBetween(
  startedAt: string | undefined,
  finishedAt: string | undefined,
  targets: Record<string, TargetSummary>
): number {
  const start = startedAt ? new Date(startedAt).getTime() : Number.NaN;
  const end = finishedAt ? new Date(finishedAt).getTime() : Number.NaN;

  if (Number.isFinite(start) && Number.isFinite(end) && end >= start) {
    return end - start;
  }

  return Object.values(targets).reduce(
    (total, target) => total + Number(target.durationMs ?? 0),
    0
  );
}

export function mergeRunRecord(
  existingRun: RunRecord | undefined,
  manifest: TargetManifest
) {
  const targets: Record<string, TargetSummary> = {
    ...existingRun?.targets,
    [manifest.target]: targetSummaryFromManifest(manifest),
  };
  const startedAt = minIso(existingRun?.startedAt, manifest.startedAt);
  const finishedAt = maxIso(existingRun?.finishedAt, manifest.finishedAt);
  const status = aggregateStatus(targets);

  return {
    schemaVersion: 1,
    repository: manifest.repository ?? existingRun?.repository,
    branch: manifest.branch ?? existingRun?.branch,
    commitSha: manifest.commitSha ?? existingRun?.commitSha,
    commitMessage: manifest.commitMessage ?? existingRun?.commitMessage,
    prNumber: manifest.prNumber ?? existingRun?.prNumber,
    workflowName: manifest.workflowName ?? existingRun?.workflowName,
    workflowRunId: manifest.workflowRunId,
    workflowRunAttempt: manifest.workflowRunAttempt,
    workflowUrl: manifest.workflowUrl ?? existingRun?.workflowUrl,
    runId: manifest.runId,
    attempt: manifest.attempt,
    status,
    failureTypes: aggregateFailureTypes(targets),
    startedAt,
    finishedAt,
    durationMs: durationBetween(startedAt, finishedAt, targets),
    targets,
    targetOrder: Object.keys(targets).toSorted(),
    artifactBytes: Object.values(targets).reduce(
      (total, target) => total + Number(target.artifactBytes ?? 0),
      0
    ),
    artifactCount: Object.values(targets).reduce(
      (total, target) => total + Number(target.artifactCount ?? 0),
      0
    ),
    retentionDays: retentionDays(status),
    expiresAt: addDays(finishedAt, retentionDays(status)),
    updatedAt: new Date().toISOString(),
  };
}

export function buildR2ObjectPlan({
  manifest,
  files,
  prefix = defaultPrefix,
}: {
  manifest: TargetManifest;
  files: ArtifactFile[];
  prefix?: string;
}) {
  const normalizedPrefix = normalizePrefix(prefix);
  const runKey = `${normalizedPrefix}/runs/${manifest.runId}/${manifest.attempt}/run.json`;
  const indexDate = (manifest.finishedAt ?? new Date().toISOString()).slice(0, 10);
  const indexKey = `${normalizedPrefix}/index/${indexDate}/${manifest.runId}-${manifest.attempt}.json`;
  const targetManifestKey = manifest.manifestKey;
  const fileUploads = files.map((file) => {
    const artifact = manifest.artifacts.find(
      (candidate) =>
        candidate.group === file.group && candidate.path === file.relativePath
    );

    if (!artifact) {
      throw new Error(
        `No manifest artifact found for ${file.group}/${file.relativePath}`
      );
    }

    return {
      key: artifact.key,
      absolutePath: file.absolutePath,
      contentType: contentTypeForPath(file.relativePath),
      size: file.size,
    };
  });

  return {
    runKey,
    indexKey,
    targetManifestKey,
    fileUploads,
  };
}

function parseArgs(argv: string[]): Record<string, string> {
  const parsed: Record<string, string> = {};

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg) continue;
    if (!arg.startsWith("--")) continue;
    const key = arg.slice(2);
    const value = argv[index + 1]?.startsWith("--") ? "1" : argv[index + 1];
    parsed[key] = value ?? "1";
    if (value !== "1") index += 1;
  }

  return parsed;
}

async function buildSummary(
  jsonReportPath: string | undefined,
  fallbackStatus: Status
): Promise<ReportSummary> {
  if (jsonReportPath) {
    try {
      return summarizePlaywrightReport(await readJsonFile(jsonReportPath));
    } catch (error) {
      if ((error as NodeJS.ErrnoException)?.code !== "ENOENT") throw error;
    }
  }

  return {
    durationMs: 0,
    summary: {
      passed: fallbackStatus === "success" ? 1 : 0,
      failed: fallbackStatus === "failure" ? 1 : 0,
      flaky: 0,
      skipped: fallbackStatus === "skipped" ? 1 : 0,
    },
    projects: [],
    failedTests: [],
  };
}

async function readGithubEvent(env: NodeJS.ProcessEnv): Promise<JsonRecord> {
  if (!env.GITHUB_EVENT_PATH) return {};

  try {
    return await readJsonFile(env.GITHUB_EVENT_PATH);
  } catch {
    return {};
  }
}

function r2Config(env: NodeJS.ProcessEnv): R2ConfigInput {
  return {
    endpoint: env.E2E_REPORTS_R2_ENDPOINT,
    region: env.E2E_REPORTS_R2_REGION || "auto",
    bucket: env.E2E_REPORTS_R2_BUCKET ?? "",
    accessKeyId: env.E2E_REPORTS_R2_ACCESS_KEY_ID,
    secretAccessKey: env.E2E_REPORTS_R2_SECRET_ACCESS_KEY,
    prefix: normalizePrefix(env.E2E_REPORTS_R2_PREFIX || defaultPrefix),
  };
}

export function missingR2Config(env = process.env) {
  const cfg = r2Config(env);
  return (
    [
      ["E2E_REPORTS_R2_ENDPOINT", cfg.endpoint],
      ["E2E_REPORTS_R2_BUCKET", cfg.bucket],
      ["E2E_REPORTS_R2_ACCESS_KEY_ID", cfg.accessKeyId],
      ["E2E_REPORTS_R2_SECRET_ACCESS_KEY", cfg.secretAccessKey],
    ] satisfies [string, string | undefined][]
  )
    .filter(([, value]) => !value)
    .map(([name]) => name);
}

function completeR2Config(config: R2ConfigInput): R2Config {
  const missing = missingR2Config({
    E2E_REPORTS_R2_ENDPOINT: config.endpoint,
    E2E_REPORTS_R2_BUCKET: config.bucket,
    E2E_REPORTS_R2_ACCESS_KEY_ID: config.accessKeyId,
    E2E_REPORTS_R2_SECRET_ACCESS_KEY: config.secretAccessKey,
  });
  if (missing.length > 0) {
    throw new Error(`Missing R2 config: ${missing.join(", ")}`);
  }

  return config as R2Config;
}

function sha256Hex(value: string | Buffer): string {
  return createHash("sha256").update(value).digest("hex");
}

function hmac(
  key: string | Buffer,
  value: string,
  encoding?: BufferEncoding
): Buffer | string {
  const digest = createHmac("sha256", key).update(value).digest();
  return encoding ? digest.toString(encoding) : digest;
}

function padTimestamp(value: number): string {
  return String(value).padStart(2, "0");
}

function awsTimestamp(date = new Date()): { amzDate: string; dateStamp: string } {
  const year = date.getUTCFullYear();
  const month = padTimestamp(date.getUTCMonth() + 1);
  const day = padTimestamp(date.getUTCDate());
  const hours = padTimestamp(date.getUTCHours());
  const minutes = padTimestamp(date.getUTCMinutes());
  const seconds = padTimestamp(date.getUTCSeconds());

  return {
    amzDate: `${year}${month}${day}T${hours}${minutes}${seconds}Z`,
    dateStamp: `${year}${month}${day}`,
  };
}

function awsEncode(value: string): string {
  return encodeURIComponent(value).replace(
    /[!'()*]/g,
    (char) => `%${char.charCodeAt(0).toString(16).toUpperCase()}`
  );
}

function canonicalQuery(url: URL): string {
  const params: [string, string][] = [];
  url.searchParams.forEach((value, key) => {
    params.push([key, value]);
  });

  return params
    .toSorted(([leftKey, leftValue], [rightKey, rightValue]) =>
      leftKey === rightKey
        ? leftValue.localeCompare(rightValue)
        : leftKey.localeCompare(rightKey)
    )
    .map(([key, value]) => `${awsEncode(key)}=${awsEncode(value)}`)
    .join("&");
}

function signingKey(
  secretAccessKey: string,
  dateStamp: string,
  region: string
): Buffer {
  const dateKey = hmac(`AWS4${secretAccessKey}`, dateStamp) as Buffer;
  const regionKey = hmac(dateKey, region) as Buffer;
  const serviceKey = hmac(regionKey, "s3") as Buffer;
  return hmac(serviceKey, "aws4_request") as Buffer;
}

function signAwsV4({
  method,
  url,
  headers = {},
  body = "",
  config,
  now = new Date(),
}: {
  method: string;
  url: string;
  headers?: Record<string, string>;
  body?: string | Buffer;
  config: R2Config;
  now?: Date;
}): Record<string, string> {
  const parsedUrl = new URL(url);
  const { amzDate, dateStamp } = awsTimestamp(now);
  const payloadHash = sha256Hex(body);
  const normalizedHeaders = {
    ...Object.fromEntries(
      Object.entries(headers).map(([key, value]) => [key.toLowerCase(), String(value)])
    ),
    host: parsedUrl.host,
    "x-amz-content-sha256": payloadHash,
    "x-amz-date": amzDate,
  };
  const sortedHeaders = Object.entries(normalizedHeaders).toSorted(([left], [right]) =>
    left.localeCompare(right)
  );
  const signedHeaders = sortedHeaders.map(([key]) => key).join(";");
  const canonicalHeaders = sortedHeaders
    .map(([key, value]) => `${key}:${String(value).trim()}\n`)
    .join("");
  const canonicalRequest = [
    method,
    parsedUrl.pathname || "/",
    canonicalQuery(parsedUrl),
    canonicalHeaders,
    signedHeaders,
    payloadHash,
  ].join("\n");
  const scope = `${dateStamp}/${config.region}/s3/aws4_request`;
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    amzDate,
    scope,
    sha256Hex(canonicalRequest),
  ].join("\n");
  const signature = hmac(
    signingKey(config.secretAccessKey, dateStamp, config.region),
    stringToSign,
    "hex"
  );

  return {
    ...normalizedHeaders,
    authorization: `AWS4-HMAC-SHA256 Credential=${config.accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
  };
}

function encodeKeyForUrl(key: string): string {
  return key.split("/").map(awsEncode).join("/");
}

function objectUrl(config: R2Config, key: string): string {
  return `${config.endpoint.replace(/\/+$/, "")}/${awsEncode(config.bucket)}/${encodeKeyForUrl(key)}`;
}

function contentTypeForPath(path: string): string {
  const ext = extname(path).toLowerCase();
  const types: Record<string, string> = {
    ".css": "text/css; charset=utf-8",
    ".gif": "image/gif",
    ".html": "text/html; charset=utf-8",
    ".jpeg": "image/jpeg",
    ".jpg": "image/jpeg",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".map": "application/json; charset=utf-8",
    ".mov": "video/quicktime",
    ".mp4": "video/mp4",
    ".png": "image/png",
    ".svg": "image/svg+xml",
    ".txt": "text/plain; charset=utf-8",
    ".webm": "video/webm",
    ".webp": "image/webp",
    ".zip": "application/zip",
  };

  return types[ext] ?? "application/octet-stream";
}

class R2Client {
  private readonly config: R2Config;
  private readonly fetchImpl: typeof fetch;

  constructor(config: R2Config, fetchImpl: typeof fetch = fetch) {
    this.config = config;
    this.fetchImpl = fetchImpl;
  }

  async request(
    method: "GET" | "PUT",
    key: string,
    { body = "", contentType }: { body?: string | Buffer; contentType?: string } = {}
  ): Promise<Response> {
    const url = objectUrl(this.config, key);
    const headers: Record<string, string> = {};

    if (contentType) headers["content-type"] = contentType;

    const signedHeaders = signAwsV4({
      method,
      url,
      headers,
      body,
      config: this.config,
    });

    const init: RequestInit = {
      method,
      headers: signedHeaders,
    };
    if (method !== "GET") init.body = body as BodyInit;
    return this.fetchImpl(url, init);
  }

  async getJson(key: string): Promise<RunRecord | undefined> {
    const response = await this.request("GET", key);
    if (response.status === 404) return undefined;
    if (!response.ok) {
      throw new Error(
        `R2 GET ${key} failed with ${response.status}: ${await response.text()}`
      );
    }

    return (await response.json()) as RunRecord;
  }

  async putObject(
    key: string,
    body: string | Buffer,
    contentType: string
  ): Promise<void> {
    const response = await this.request("PUT", key, { body, contentType });
    if (!response.ok) {
      throw new Error(
        `R2 PUT ${key} failed with ${response.status}: ${await response.text()}`
      );
    }
  }

  async putJson(key: string, value: unknown): Promise<void> {
    await this.putObject(
      key,
      Buffer.from(`${JSON.stringify(value, null, 2)}\n`),
      "application/json; charset=utf-8"
    );
  }
}

export async function publishToR2({
  metadata,
  files,
  env = process.env,
  fetchImpl = fetch,
}: {
  metadata: GithubMetadata;
  files: ArtifactFile[];
  env?: NodeJS.ProcessEnv;
  fetchImpl?: typeof fetch;
}): Promise<
  | { skipped: true; missing: string[] }
  | {
      skipped: false;
      run: ReturnType<typeof mergeRunRecord>;
      keys: { run: string; index: string; manifest: string };
      uploadedFiles: number;
    }
> {
  const missing = missingR2Config(env);
  if (missing.length > 0) {
    console.log(`E2E reports R2 upload skipped: missing ${missing.join(", ")}.`);
    return { skipped: true, missing };
  }

  const config = completeR2Config(r2Config(env));
  const manifest = buildTargetManifest({
    metadata,
    files,
    prefix: config.prefix,
  });
  const plan = buildR2ObjectPlan({ manifest, files, prefix: config.prefix });
  const client = new R2Client(config, fetchImpl);
  const existingRun = await client.getJson(plan.runKey);
  const run = mergeRunRecord(existingRun, manifest);
  const index = {
    ...run,
    runKey: plan.runKey,
    indexKey: plan.indexKey,
  };

  for (const upload of plan.fileUploads) {
    await client.putObject(
      upload.key,
      await readFile(upload.absolutePath),
      upload.contentType
    );
  }

  await client.putJson(plan.targetManifestKey, manifest);
  await client.putJson(plan.runKey, run);
  await client.putJson(plan.indexKey, index);

  return {
    skipped: false,
    run,
    keys: {
      run: plan.runKey,
      index: plan.indexKey,
      manifest: plan.targetManifestKey,
    },
    uploadedFiles: plan.fileUploads.length,
  };
}

export async function main(
  argv = process.argv.slice(2),
  env = process.env
): ReturnType<typeof publishToR2> {
  const args = parseArgs(argv);
  const target = args.target;
  const status = mapOutcomeToStatus(args.status ?? env.COMMA_E2E_REPORT_STATUS);

  if (!target) throw new Error("--target is required");

  const finishedAt = new Date().toISOString();
  const summary = await buildSummary(args["json-report"], status);
  const startedAt =
    env.COMMA_E2E_REPORT_STARTED_AT ??
    new Date(new Date(finishedAt).getTime() - summary.durationMs).toISOString();
  const collectOptions: { target: string; reportDir?: string; resultsDir?: string } = {
    target,
  };
  if (args["report-dir"]) collectOptions.reportDir = args["report-dir"];
  if (args["results-dir"]) collectOptions.resultsDir = args["results-dir"];
  const files = await collectArtifactFiles(collectOptions);
  const event = await readGithubEvent(env);
  const metadata = buildGithubMetadata({
    target,
    status,
    startedAt,
    finishedAt,
    durationMs: summary.durationMs,
    summary: summary.summary,
    projects: summary.projects,
    failedTests: summary.failedTests,
    env,
    event,
  });
  const result = await publishToR2({ metadata, files, env });

  if (!result.skipped) {
    console.log(
      `Published ${files.length} E2E report files for ${target} ${status}: ${result.keys.run}`
    );
  }

  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
