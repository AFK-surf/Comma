import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import type { EvalensConfig } from "@evalens/cli/config";
import { syncSalixL2Dataset } from "@evalens/cli/dataset-sync";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true }))
  );
});

describe("Salix L2 dataset sync", () => {
  test("adds a redacted item and deduplicates an overlapping result", async () => {
    const fixture = await createFixture();
    let cursor: string | undefined;
    const request = mockFetch((url, headers) => {
      expect(headers.authorization).toBe("Bearer runtime-token");
      cursor = url.searchParams.get("cursor") ?? undefined;
      return page(cursor ? "cursor-2" : "cursor-1");
    });

    const first = await syncSalixL2Dataset({
      ...fixture,
      apply: true,
      evaluatedFrom: "2026-08-01T00:00:00Z",
      fetch: request,
    });
    const second = await syncSalixL2Dataset({
      ...fixture,
      apply: true,
      fetch: request,
    });

    const dataset = await Bun.file(fixture.datasetPath).json();
    const state = await Bun.file(fixture.statePath).json();
    expect(first).toMatchObject({ added: 1, unchanged: 0 });
    expect(second).toMatchObject({ added: 0, unchanged: 1 });
    expect(dataset.items).toHaveLength(1);
    expect(dataset.items[0].id).toMatch(/^salix-l2-[a-f0-9]{64}$/u);
    expect(JSON.stringify(dataset)).toContain("<redacted:secret>");
    expect(JSON.stringify(dataset)).not.toContain("secret-token-value");
    expect(state.cursor).toBe("cursor-2");
    expect(cursor).toBe("cursor-1");
  });

  test("dry-run leaves dataset and cursor untouched", async () => {
    const fixture = await createFixture();
    const summary = await syncSalixL2Dataset({
      ...fixture,
      apply: false,
      evaluatedFrom: "2026-08-01T00:00:00Z",
      fetch: mockFetch(() => page("dry-run")),
    });

    expect(summary).toMatchObject({ added: 1, dryRun: true });
    expect(await Bun.file(fixture.datasetPath).exists()).toBe(false);
    expect(await Bun.file(fixture.statePath).exists()).toBe(false);
  });

  test("requires exactly one first-sync boundary", async () => {
    const fixture = await createFixture();
    await expect(syncSalixL2Dataset({ ...fixture, apply: false })).rejects.toThrow(
      "first sync requires"
    );
    await expect(
      syncSalixL2Dataset({
        ...fixture,
        apply: false,
        evaluatedFrom: "2026-08-01T00:00:00Z",
        bootstrapNow: true,
      })
    ).rejects.toThrow("mutually exclusive");
  });

  test("processes one page even when Salix has more", async () => {
    const fixture = await createFixture();
    let requests = 0;
    const summary = await syncSalixL2Dataset({
      ...fixture,
      apply: true,
      evaluatedFrom: "2026-08-01T00:00:00Z",
      fetch: mockFetch(() => {
        requests += 1;
        return page("next-page", trajectoryResult(), true);
      }),
    });

    expect(requests).toBe(1);
    expect(summary.hasMore).toBe(true);
    expect((await Bun.file(fixture.statePath).json()).cursor).toBe("next-page");
  });

  test("rejects an unavailable snapshot and still advances the cursor", async () => {
    const fixture = await createFixture();
    const result: Record<string, unknown> = trajectoryResult();
    delete result.target;
    delete result.session_records;
    result.session_records_status = "snapshot_unavailable";

    const summary = await syncSalixL2Dataset({
      ...fixture,
      apply: true,
      evaluatedFrom: "2026-08-01T00:00:00Z",
      fetch: mockFetch(() => page("after-rejected", result)),
    });

    expect(summary).toMatchObject({ added: 0, rejected: 1, cursorAdvanced: true });
    expect((await Bun.file(fixture.statePath).json()).cursor).toBe("after-rejected");
  });

  test("keeps resumed filters stable", async () => {
    const fixture = await createFixture();
    const request = mockFetch(() => page("saved-cursor"));
    await syncSalixL2Dataset({
      ...fixture,
      apply: true,
      evaluatedFrom: "2026-08-01T00:00:00Z",
      minSeverity: 0.6,
      fetch: request,
    });

    await expect(
      syncSalixL2Dataset({
        ...fixture,
        apply: false,
        minSeverity: 0.9,
        fetch: request,
      })
    ).rejects.toThrow("sync filters changed");
  });

  test("locks before reading mutable dataset state", async () => {
    const fixture = await createFixture();
    await mkdir(fixture.lockPath, { recursive: true });
    await mkdir(path.dirname(fixture.datasetPath), { recursive: true });
    await Bun.write(fixture.datasetPath, "not-json");

    await expect(
      syncSalixL2Dataset({
        ...fixture,
        apply: true,
        evaluatedFrom: "2026-08-01T00:00:00Z",
      })
    ).rejects.toThrow("dataset sync is locked");
  });

  test("redacts Salix error bodies", async () => {
    const fixture = await createFixture();
    const fetchError = (async () =>
      Response.json(
        { error: "Authorization: Bearer secret-token-value" },
        { status: 503 }
      )) as unknown as typeof fetch;

    await expect(
      syncSalixL2Dataset({
        ...fixture,
        apply: false,
        evaluatedFrom: "2026-08-01T00:00:00Z",
        fetch: fetchError,
      })
    ).rejects.toThrow("<redacted:secret>");
  });
});

async function createFixture() {
  const configDir = await mkdtemp(path.join(os.tmpdir(), "evalens-sync-"));
  temporaryDirectories.push(configDir);
  const name = "salix-regressions";
  const config: EvalensConfig = {
    concurrency: 1,
    local: { outputDir: path.join(configDir, "runs") },
    adapters: {
      salix: {
        baseUrl: "https://salix.example.test",
        token: "runtime-token",
        tenantId: "tenant-1",
      },
    },
  };
  return {
    name,
    config,
    configDir,
    datasetPath: path.join(configDir, "datasets", name, "dataset.json"),
    statePath: path.join(configDir, ".evalens", "sync", name, "salix-l2.json"),
    lockPath: path.join(configDir, ".evalens", "locks", `${name}.lock`),
  };
}

function mockFetch(
  response: (url: URL, headers: Record<string, string>) => Record<string, unknown>
): typeof fetch {
  return (async (input, init) =>
    Response.json(
      response(new URL(input.toString()), init?.headers as Record<string, string>)
    )) as typeof fetch;
}

function page(
  nextCursor: string,
  result: unknown = trajectoryResult(),
  hasMore = false
) {
  return {
    items: [result],
    next_cursor: nextCursor,
    has_more: hasMore,
    snapshot_to: "2026-08-13T00:00:00Z",
    consistency: { mode: "eventual_with_overlap", overlap_seconds: 3600 },
  };
}

function trajectoryResult() {
  return {
    source: {
      agent_id: "agent-1",
      session_id: "session-1",
      group_id: "group-1",
      window_key: "agent-1:session-1:2",
    },
    target: { agent_role: "router", runtime_kind: "internal" },
    window: {
      from_message_id: 2,
      to_message_id: 2,
      message_count: 1,
      round_id: "round-1",
    },
    evaluation: {
      evaluator: "judge",
      evaluator_version: "1",
      outcome: "final",
      evaluated_at: "2026-08-12T00:00:00Z",
      max_confirmed_severity: 0.8,
      findings: [
        {
          metric: "confusion",
          verdict: "confirmed",
          score: 0.8,
          reason: "Repeated backtracking with sk-1234567890123456",
        },
      ],
    },
    session_records_status: "available",
    session_records: [
      {
        id: 0,
        role: "assistant",
        content: "Earlier Authorization: Bearer secret-token-value",
      },
      { id: 1, role: "user", content: "Fix the issue" },
      { id: 2, role: "assistant", content: "Wait, I was wrong." },
    ],
  };
}
