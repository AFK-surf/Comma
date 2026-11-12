import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { TaskFile } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const FILES = "/v1/comma/groups/grp-1/task-files";

const taskFile = (name: string, index = 0): TaskFile => ({
  conversation_id: "cnv-1",
  task_title: "Report",
  message_id: "msg-1",
  seq: 3,
  index,
  type: "file",
  file_name: name,
  mime_type: null,
  size: 1_200,
  created_at: 1_000,
});

function setup() {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", {
    data: [{ id: "wsp-1", group_id: "grp-1", name: "Main" }],
  });
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn());
  const query = () => new URL(`http://x${host.api.requests.at(-1)!.path}`).searchParams;
  return { client, time: host.time!, api: host.api, query };
}

describe("a Task's files", () => {
  it("lists one Task's files, and says when Comma still indexes them or cannot read them", async () => {
    const t = setup();
    t.api.on("GET", FILES, {
      data: [taskFile("report.pdf", 1), taskFile("chart.png")],
      next_cursor: null,
    });
    expect(
      await t.client.call("taskFiles.list", { group: "grp-1", conversation: "cnv-1" })
    ).toEqual({
      status: "ready",
      files: [taskFile("report.pdf", 1), taskFile("chart.png")],
      nextCursor: null,
    });
    expect(Object.fromEntries(t.query())).toEqual({
      conversation_id: "cnv-1",
      limit: "200",
    });

    t.api.on("GET", FILES, json(503, { error: "task_files_indexing" }));
    expect(
      await t.client.call("taskFiles.list", { group: "grp-1", conversation: "cnv-1" })
    ).toMatchObject({ status: "indexing", files: [] });

    t.api.on("GET", FILES, json(503, { error: "conversation_unavailable" }));
    expect(
      await t.client.call("taskFiles.list", { group: "grp-1", conversation: "cnv-1" })
    ).toMatchObject({ status: "error", files: [] });
  });

  it("finds files by name in the preferred workspace's Group once the query stays typed", async () => {
    const t = setup();
    t.api.on("GET", FILES, { data: [taskFile("report.pdf")], next_cursor: null });
    const found = t.client.call("search.taskFiles", {
      query: " report ",
      prefer: "wsp-1",
    });
    await t.time.pass(200);
    expect(await found).toEqual({
      status: "ready",
      scope: { groupId: "grp-1", workspaceId: "wsp-1" },
      files: [taskFile("report.pdf")],
    });
    expect(Object.fromEntries(t.query())).toEqual({ q: "report", limit: "20" });

    t.api.on("GET", FILES, json(503, { error: "task_files_indexing" }));
    const indexing = t.client.call("search.taskFiles", { query: "report" });
    await t.time.pass(200);
    expect(await indexing).toMatchObject({ status: "indexing", files: [] });

    t.api.on("GET", FILES, json(400, { error: "invalid_task_files_query" }));
    const refused = t.client.call("search.taskFiles", { query: "%%" });
    await t.time.pass(200);
    expect(await refused).toMatchObject({ status: "invalid", files: [] });
  });
});
