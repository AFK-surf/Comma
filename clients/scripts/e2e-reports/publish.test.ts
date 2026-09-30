import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  buildR2ObjectPlan,
  buildGithubMetadata,
  buildTargetManifest,
  collectArtifactFiles,
  mapOutcomeToStatus,
  mergeRunRecord,
  summarizePlaywrightReport,
} from "./publish.ts";

let tempDirs: string[] = [];

afterEach(async () => {
  await Promise.all(tempDirs.map((dir) => rm(dir, { recursive: true, force: true })));
  tempDirs = [];
});

describe("e2e report publisher", () => {
  it("maps GitHub step outcomes to dashboard statuses", () => {
    expect(mapOutcomeToStatus("success")).toBe("success");
    expect(mapOutcomeToStatus("failure")).toBe("failure");
    expect(mapOutcomeToStatus("cancelled")).toBe("cancelled");
    expect(mapOutcomeToStatus("skipped")).toBe("skipped");
    expect(mapOutcomeToStatus("timed_out")).toBe("failure");
  });

  it("summarizes Playwright JSON report stats and failed tests", () => {
    const report = {
      stats: { expected: 2, unexpected: 1, flaky: 1, skipped: 3, duration: 1500 },
      suites: [
        {
          title: "root",
          specs: [
            {
              title: "opens app",
              file: "e2e/p0/web-smoke.spec.ts",
              line: 12,
              tests: [
                {
                  projectName: "web",
                  status: "unexpected",
                  results: [{ error: { message: "Timeout 8000ms exceeded" } }],
                },
              ],
            },
          ],
        },
      ],
    };

    expect(summarizePlaywrightReport(report)).toEqual({
      durationMs: 1500,
      summary: { passed: 2, failed: 1, flaky: 1, skipped: 3 },
      projects: [{ name: "web", passed: 0, failed: 1, flaky: 0, skipped: 0 }],
      failedTests: [
        {
          title: "opens app",
          project: "web",
          error: "Timeout 8000ms exceeded",
          failureType: "timeout",
          location: "e2e/p0/web-smoke.spec.ts:12",
        },
      ],
    });
  });

  it("collects report and test-result files with stable R2 paths", async () => {
    const dir = await mkdtemp(join(tmpdir(), "comma-e2e-report-"));
    tempDirs.push(dir);
    const reportDir = join(dir, "playwright-report", "web");
    const resultsDir = join(dir, "test-results", "playwright-web");
    await mkdir(reportDir, { recursive: true });
    await mkdir(resultsDir, { recursive: true });
    await writeFile(join(reportDir, "index.html"), "<html></html>");
    await writeFile(join(resultsDir, "trace.zip"), "trace");

    const files = await collectArtifactFiles({
      target: "web",
      reportDir,
      resultsDir,
    });

    expect(files.map((file) => file.path)).toEqual([
      "web/report/index.html",
      "web/test-results/trace.zip",
    ]);
    expect(files.map((file) => file.kind)).toEqual(["html-report", "trace"]);
  });

  it("builds GitHub metadata from Actions environment and event payload", () => {
    const metadata = buildGithubMetadata({
      target: "electron",
      status: "failure",
      startedAt: "2026-06-15T12:00:00.000Z",
      finishedAt: "2026-06-15T12:01:00.000Z",
      durationMs: 60_000,
      summary: { passed: 0, failed: 1, flaky: 0, skipped: 0 },
      projects: [{ name: "electron", passed: 0, failed: 1, flaky: 0, skipped: 0 }],
      failedTests: [{ title: "opens app", project: "electron", error: "Timeout" }],
      env: {
        GITHUB_REPOSITORY: "AFK-surf/Comma",
        GITHUB_REF_NAME: "feature/e2e",
        GITHUB_SHA: "abcdef123456",
        GITHUB_WORKFLOW: "Client Checks",
        GITHUB_RUN_ID: "9001",
        GITHUB_RUN_ATTEMPT: "3",
        GITHUB_SERVER_URL: "https://github.com",
      },
      event: {
        pull_request: { number: 11, title: "Add E2E report publisher" },
      },
    });

    expect(metadata.repository).toBe("AFK-surf/Comma");
    expect(metadata.durationMs).toBe(60_000);
    expect(metadata.prNumber).toBe(11);
    expect(metadata.failureTypes).toEqual({ timeout: 1 });
    expect(metadata.workflowUrl).toBe(
      "https://github.com/AFK-surf/Comma/actions/runs/9001/attempts/3"
    );
    expect(metadata.commitMessage).toBe("Add E2E report publisher");
  });

  it("builds target manifests and R2 keys using the agreed layout", async () => {
    const dir = await mkdtemp(join(tmpdir(), "comma-e2e-report-"));
    tempDirs.push(dir);
    const reportDir = join(dir, "playwright-report", "web");
    const resultsDir = join(dir, "test-results", "playwright-web");
    await mkdir(join(reportDir, "data"), { recursive: true });
    await mkdir(resultsDir, { recursive: true });
    await writeFile(join(reportDir, "index.html"), "<html></html>");
    await writeFile(join(reportDir, "data", "trace.zip"), "trace");
    await writeFile(join(resultsDir, "failed.png"), "png");

    const files = await collectArtifactFiles({ target: "web", reportDir, resultsDir });
    const metadata = buildGithubMetadata({
      target: "web",
      status: "failure",
      startedAt: "2026-06-15T12:00:00.000Z",
      finishedAt: "2026-06-15T12:01:00.000Z",
      durationMs: 60_000,
      summary: { passed: 2, failed: 1, flaky: 0, skipped: 0 },
      projects: [{ name: "web", passed: 2, failed: 1, flaky: 0, skipped: 0 }],
      failedTests: [
        {
          title: "opens app",
          project: "web",
          error: "Timeout",
          failureType: "timeout",
        },
      ],
      env: {
        GITHUB_REPOSITORY: "AFK-surf/Comma",
        GITHUB_REF_NAME: "main",
        GITHUB_SHA: "abc123",
        GITHUB_WORKFLOW: "Client Checks",
        GITHUB_RUN_ID: "9001",
        GITHUB_RUN_ATTEMPT: "2",
      },
    });

    const manifest = buildTargetManifest({
      metadata,
      files,
      prefix: "e2e-reports",
    });
    const plan = buildR2ObjectPlan({ manifest, files, prefix: "e2e-reports" });

    expect(plan.runKey).toBe("e2e-reports/runs/9001/2/run.json");
    expect(plan.indexKey).toBe("e2e-reports/index/2026-06-15/9001-2.json");
    expect(plan.targetManifestKey).toBe("e2e-reports/runs/9001/2/web/manifest.json");
    expect(plan.fileUploads.map((upload) => upload.key)).toEqual([
      "e2e-reports/runs/9001/2/web/report/data/trace.zip",
      "e2e-reports/runs/9001/2/web/report/index.html",
      "e2e-reports/runs/9001/2/web/test-results/failed.png",
    ]);
    expect(manifest.reportIndexKey).toBe(
      "e2e-reports/runs/9001/2/web/report/index.html"
    );
    expect(manifest.artifacts.find((artifact) => artifact.kind === "trace")?.path).toBe(
      "data/trace.zip"
    );
  });

  it("merges target uploads into one run record and aggregates status", () => {
    const existing = {
      schemaVersion: 1,
      runId: "9001",
      attempt: "2",
      status: "success",
      startedAt: "2026-06-15T12:00:00.000Z",
      finishedAt: "2026-06-15T12:01:00.000Z",
      targets: {
        web: {
          target: "web",
          status: "success",
          durationMs: 1000,
          summary: { passed: 1, failed: 0, flaky: 0, skipped: 0 },
          artifactCount: 2,
          artifactBytes: 20,
        },
      },
    };
    const electronManifest = {
      schemaVersion: 1,
      repository: "AFK-surf/Comma",
      branch: "main",
      commitSha: "abc123",
      workflowName: "Client Checks",
      workflowRunId: "9001",
      workflowRunAttempt: "2",
      runId: "9001",
      attempt: "2",
      target: "electron",
      status: "failure",
      startedAt: "2026-06-15T12:00:30.000Z",
      finishedAt: "2026-06-15T12:02:00.000Z",
      durationMs: 90_000,
      summary: { passed: 0, failed: 1, flaky: 0, skipped: 0 },
      projects: [],
      failedTests: [],
      failureTypes: {},
      artifacts: [{ size: 5 }],
      artifactBytes: 5,
    };

    const merged = mergeRunRecord(
      existing as unknown as Parameters<typeof mergeRunRecord>[0],
      electronManifest as unknown as Parameters<typeof mergeRunRecord>[1]
    );

    expect(merged.status).toBe("failure");
    expect(merged.durationMs).toBe(120_000);
    expect(Object.keys(merged.targets).toSorted()).toEqual(["electron", "web"]);
    expect(merged.targets.electron?.artifactCount).toBe(1);
    expect(merged.failureTypes).toEqual({});
    expect(merged.artifactBytes).toBe(25);
  });
});
