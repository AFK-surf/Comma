import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { runCli } from "@evalens/cli";
import {
  CliQueryError,
  createCliQueryClient,
  normalizeCliQueryError,
  parseCreatedRange,
  parseParamsFilter,
  structuredCliError,
} from "@evalens/cli/query";
import { LocalQueryNotReadyError } from "@evalens/store/local";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true }))
  );
});

describe("CLI queries", () => {
  test("lists local runs as the stable bounded JSON envelope", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "evalens-query-"));
    temporaryDirectories.push(directory);
    const configPath = path.join(directory, "evalens.config.json");
    await Bun.write(configPath, JSON.stringify({ local: { outputDir: "./runs" } }));
    const lines: string[] = [];
    const originalLog = console.log;
    console.log = (line?: unknown) => lines.push(String(line));
    try {
      await runCli(["list", "runs", "--config", configPath, "--limit", "7"]);
    } finally {
      console.log = originalLog;
    }

    expect(lines).toEqual([JSON.stringify({ items: [], total: 0, limit: 7 })]);
  });

  test("routes run resources without falling through to evaluation handlers", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "evalens-query-route-"));
    temporaryDirectories.push(directory);
    const configPath = path.join(directory, "evalens.config.json");
    await Bun.write(configPath, JSON.stringify({ local: { outputDir: "./runs" } }));

    await expect(
      runCli(["list", "runs", "--config", configPath, "--eval-params", "{}"])
    ).rejects.toMatchObject({
      code: "invalid_arguments",
      exitCode: 2,
    });
    await expect(
      runCli(["get", "run", "missing-run", "--config", configPath])
    ).rejects.toMatchObject({
      code: "not_found",
      message: "run not found",
    });
  });

  test("prints structured usage errors for malformed reserved query commands", async () => {
    const child = Bun.spawn(
      [process.execPath, "packages/cli/src/index.ts", "list", "unknown"],
      {
        cwd: path.resolve(import.meta.dir, "../../.."),
        stdout: "pipe",
        stderr: "pipe",
      }
    );

    const [exitCode, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ]);

    expect(exitCode).toBe(2);
    expect(stdout).toBe("");
    expect(JSON.parse(stderr)).toMatchObject({
      error: {
        code: "invalid_arguments",
        retryable: false,
      },
    });
  });

  test("keeps structured error handling scoped to query commands", async () => {
    const child = Bun.spawn([process.execPath, "packages/cli/src/index.ts", "run"], {
      cwd: path.resolve(import.meta.dir, "../../.."),
      stdout: "pipe",
      stderr: "pipe",
    });

    const [exitCode, stderr] = await Promise.all([
      child.exited,
      new Response(child.stderr).text(),
    ]);

    expect(exitCode).toBe(1);
    expect(stderr).toContain("Not enough non-option arguments");
    expect(stderr).not.toContain('"error":{"code":"invalid_arguments"');
    expect(stderr).not.toContain("YError:");
  });

  test("normalizes local readiness failures at the CLI error boundary", () => {
    expect(normalizeCliQueryError(new LocalQueryNotReadyError())).toMatchObject({
      code: "reindexing",
      retryable: true,
    });
  });

  test("queries remote APIs directly through Treaty with Access headers", async () => {
    const requests: Request[] = [];
    await using client = await createCliQueryClient(
      remoteConfig,
      testFetcher(async (request) => {
        requests.push(request);
        return Response.json({ items: [], page: 1, pageSize: 4, total: 0 });
      })
    );

    await client.listEvaluations({
      runId: "0197fb0d-1595-72b6-85d4-5c29d8101b20",
      runParams: { temperature: 0 },
      evalParams: { strict: true },
      page: 1,
      pageSize: 4,
    });

    const request = requests[0];
    expect(request?.headers.get("CF-Access-Client-Id")).toBe("client-id");
    expect(request?.headers.get("CF-Access-Client-Secret")).toBe("client-secret");
    const url = new URL(request!.url);
    expect(url.pathname).toBe("/api/evaluations");
    expect(url.searchParams.get("runParams")).toBe('{"temperature":0}');
    expect(url.searchParams.get("evalParams")).toBe('{"strict":true}');
    expect(url.searchParams.get("pageSize")).toBe("4");
  });

  test("maps remote query responses directly to CLI errors", async () => {
    await using reindexing = await createCliQueryClient(
      remoteConfig,
      testFetcher(() =>
        Response.json(
          { state: "reindexing", message: "result index is rebuilding" },
          { status: 202 }
        )
      )
    );
    await expect(reindexing.listRuns({ page: 1, pageSize: 1 })).rejects.toEqual(
      new CliQueryError("reindexing", "result index is rebuilding", true)
    );

    await using unauthorized = await createCliQueryClient(
      remoteConfig,
      testFetcher(() => Response.json({ message: "access denied" }, { status: 403 }))
    );
    await expect(unauthorized.listRuns({ page: 1, pageSize: 1 })).rejects.toEqual(
      new CliQueryError("auth_failed", "access denied", false)
    );
  });

  test("returns null for missing remote resources", async () => {
    await using client = await createCliQueryClient(
      remoteConfig,
      testFetcher(() => Response.json({ message: "run not found" }, { status: 404 }))
    );
    await expect(
      client.getRun("0197fb0d-1595-72b6-85d4-5c29d8101b20")
    ).resolves.toBeNull();
  });

  test("validates JSON parameter types and timezone-aware ranges", () => {
    expect(parseParamsFilter('{"model":"gpt-5","temperature":0}')).toEqual({
      model: "gpt-5",
      temperature: 0,
    });
    expect(() => parseParamsFilter("not-json")).toThrow(CliQueryError);
    expect(() => parseParamsFilter('{"nested":{"no":true}}')).toThrow(CliQueryError);
    expect(() => parseCreatedRange("2026-07-14T01:00:00", undefined)).toThrow(
      /timezone/
    );
    expect(() => parseCreatedRange("2026-07-14Z", undefined)).toThrow(/timezone/);
    expect(() => parseCreatedRange("2026-02-30T00:00:00Z", undefined)).toThrow(/valid/);
    expect(() =>
      parseCreatedRange("2026-07-15T00:00:00Z", "2026-07-14T00:00:00Z")
    ).toThrow(/must not be later/);
    expect(
      parseCreatedRange("2026-07-14T00:00:00Z", "2026-07-14T23:59:59+08:00")
    ).toEqual({
      createdAfter: "2026-07-14T00:00:00Z",
      createdBefore: "2026-07-14T23:59:59+08:00",
    });
  });

  test("formats stable machine-readable errors", () => {
    expect(
      structuredCliError(
        new CliQueryError("reindexing", "result index is rebuilding", true)
      )
    ).toEqual({
      exitCode: 1,
      body: {
        error: {
          code: "reindexing",
          message: "result index is rebuilding",
          retryable: true,
        },
      },
    });
  });
});

const remoteConfig = {
  concurrency: 1,
  remote: {
    url: "https://evalens.example.com",
    access: { clientId: "client-id", clientSecret: "client-secret" },
    r2: {
      accountId: "account",
      bucket: "bucket",
      accessKeyId: "access-key",
      secretAccessKey: "secret-key",
    },
  },
} as const;

function testFetcher(
  respond: (request: Request) => Response | Promise<Response>
): typeof fetch {
  return Object.assign(
    async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      const request =
        typeof input === "string" || input instanceof URL
          ? new Request(input.toString(), init)
          : new Request(input, init);
      return respond(request);
    },
    { preconnect(_url: string | URL) {} }
  );
}
