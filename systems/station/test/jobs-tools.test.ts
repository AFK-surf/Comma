// The jobs' and the peer stations' MCP tools: their definitions.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { Jobs } from "../src/jobs/jobs.ts";
import { Store } from "../src/store/store.ts";
import { jobTools } from "../src/tools/jobs.ts";
import { STATION_TOOLS } from "../src/tools/remote.ts";

const dir = mkdtempSync(join(tmpdir(), "jobs-tools-"));
const store = Store.open(":memory:");
const jobs = new Jobs({ store, data: dir, notify: () => {}, link: () => null });
after(async () => {
  await jobs.shutdown();
  store.close();
  rmSync(dir, { recursive: true, force: true });
});

test("job_start, job_list, job_log and job_stop, and the stations' tools: named, described, their inputs objects", () => {
  const tools = [...jobTools(jobs, () => null).map(({ name, description, inputSchema }) => ({ name, description, inputSchema })), ...STATION_TOOLS];
  assert.deepEqual(tools.map((t) => t.name), ["job_start", "job_list", "job_log", "job_stop", "station_list", "station_job", "station_file"]);
  for (const tool of tools) {
    assert.ok(tool.description.length > 0, tool.name);
    assert.equal((tool.inputSchema as { type?: string }).type, "object", tool.name);
  }
});
