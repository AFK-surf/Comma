import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Coding, CodingRefused, type Repo } from "../src/tasks/coding.ts";
import { newSessionAtomic } from "../src/sessions/lifecycle.ts";
import { Tasks } from "../src/tasks/tasks.ts";
import { threadHistory } from "../src/sessions/conversations.ts";
import { readArchiveBackwards } from "../src/store/archive.ts";
import { addMultiSessionTaskColumns } from "../src/store/schema.ts";
import type { Json } from "../src/store/rows.ts";
import { canonicalUsagePerson, usageTurns } from "../src/store/usage.ts";
import { Rig, settle, testClock } from "./hub-fakes.ts";

function promptsOf(rig: Rig, session: string): string[] {
  return [...rig.claude.sessions, ...rig.codex.sessions]
    .filter((s) => s.options.route === session)
    .flatMap((s) => [...s.prompts, ...s.steers]);
}

function heard(rig: Rig, session: string, needle: string): boolean {
  return (
    promptsOf(rig, session).some((p) => p.includes(needle)) ||
    rig.store.pendingMessages(session).some((p) => p.message.text.includes(needle))
  );
}

function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "Test",
      GIT_AUTHOR_EMAIL: "test@example.com",
      GIT_COMMITTER_NAME: "Test",
      GIT_COMMITTER_EMAIL: "test@example.com",
    },
  }).trim();
}

test("TASK_SURFACE skips local hub.shared(); only Salix task.put with deliver_to_slots wakes target slots", async (t) => {
  const b = new Rig();
  t.after(() => b.close());
  const posted: Json[] = [];
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async (req: Json): Promise<Json> => {
    if (req.method === "task.post") {
      posted.push(req);
      return { seq: 10 + posted.length };
    }
    return {};
  });

  const lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_multi_1",
    slot: "lead",
    start: { requester: "usr_alice", person: "usr_alice", runtime: "claude", slot: "lead", is_primary: true },
  });
  const reviewer = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_multi_1",
    slot: "reviewer",
    join: true,
    start: { requester: "usr_alice", person: "usr_alice", runtime: "claude", slot: "reviewer", is_primary: false },
  });

  assert.equal(lead.slot, "lead");
  assert.equal(reviewer.slot, "reviewer");
  assert.equal(lead.thread, reviewer.thread);

  // Directed delivery to lead only: lead answers, and hub.shared() must NOT locally wake reviewer.
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_multi_1",
    through: 1,
    roster: [
      { slot: "lead", is_primary: true, role: "Lead" },
      { slot: "reviewer", is_primary: false, role: "Reviewer" },
    ],
    messages: [
      {
        seq: 1,
        id: "msg_1",
        author: { kind: "person", id: "usr_alice" },
        text: "Lead: draft the patch",
        declared: null,
        at: 1,
        deliver_to_slots: ["lead"],
      },
    ],
  });
  await settle();

  assert.ok(heard(b, lead.session, "Lead: draft the patch"));
  // Lead posts its reply through chat_post: hub.shared() must NOT locally wake reviewer,
  // and terminal task.post must report exact answered_through_seq = 1.
  await b.call(lead.session, "chat_post", {
    to: lead.thread,
    text: "Patch drafted",
    kind: "all_done",
    done: "drafted",
  });
  await settle();
  assert.equal(promptsOf(b, reviewer.session).length, 0, "reviewer must not be woken by lead's local post");
  assert.equal(posted.length, 1);
  assert.equal(posted[0]!.answered_through_seq, 1, "terminal task.post reports exact answered_through_seq");

  // Directed delivery to reviewer only: wakes reviewer, not lead again.
  const leadPromptsBefore = promptsOf(b, lead.session).length;
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_multi_1",
    through: 2,
    messages: [
      {
        seq: 2,
        id: "msg_2",
        author: { kind: "person", id: "usr_alice" },
        text: "Reviewer: check edge cases",
        declared: null,
        at: 2,
        deliver_to_slots: ["reviewer"],
      },
    ],
  });
  await settle();

  assert.equal(promptsOf(b, lead.session).length, leadPromptsBefore, "lead is not woken for reviewer-only message");
  assert.ok(heard(b, reviewer.session, "Reviewer: check edge cases"));
});

test("legacy in-place upgrade backfills lead slot without restarting primary, and join refuses when no primary exists", async (t) => {
  const b = new Rig();
  t.after(() => b.close());
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async () => ({}));

  // Refuse join when thread does not exist at all.
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_missing",
        slot: "reviewer",
        join: true,
        start: { requester: "usr_alice", runtime: "claude" },
      }),
    /no active primary session/,
  );

  // Create a legacy single-session thread, then delete its task_session_slots row to simulate pre-PR2 DB state.
  const primary = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_legacy",
    start: { requester: "usr_alice", runtime: "claude" },
  });
  const thread = b.store.sessionThreads(primary.session)[0]!.thread;
  b.store.db.prepare("DELETE FROM task_session_slots WHERE thread = ?").run(thread.id);
  assert.deepEqual(b.store.taskSlots(thread.id), []);

  // Joining a secondary slot upgrades in place without restarting primary.
  const secondary = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_legacy",
    slot: "tester",
    join: true,
    start: { requester: "usr_alice", runtime: "claude" },
  });
  assert.equal(secondary.slot, "tester");
  assert.notEqual(secondary.session, primary.session);

  const slots = b.store.taskSlots(thread.id);
  assert.deepEqual(
    slots.map((s) => ({ slot: s.slot, session: s.session, isPrimary: s.isPrimary })),
    [
      { slot: "lead", session: primary.session, isPrimary: true },
      { slot: "tester", session: secondary.session, isPrimary: false },
    ],
  );
});

test("isolated task attachments are fetched once to read-only cache and copied per target session", async (t) => {
  const b = new Rig();
  t.after(() => b.close());
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);

  const payload = Buffer.from("shared attachment body");
  let fileFetchCount = 0;
  tasks.attachHost("salix", async (req: Json): Promise<Json> => {
    if (req.method === "task.file") {
      fileFetchCount++;
      return { name: "spec.txt", size: payload.length, offset: 0, data: payload.toString("base64") };
    }
    return { seq: 99 };
  });

  const lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_files",
    slot: "lead",
    start: { requester: "usr_alice", runtime: "claude", slot: "lead", is_primary: true },
  });
  const reviewer = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_files",
    slot: "reviewer",
    join: true,
    start: { requester: "usr_alice", runtime: "claude", slot: "reviewer", is_primary: false },
  });

  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_files",
    through: 1,
    messages: [
      {
        seq: 1,
        id: "msg_file_1",
        author: { kind: "person", id: "usr_alice" },
        text: "Both check spec.txt",
        files: [{ index: 0, name: "spec.txt", size: payload.length }],
        declared: null,
        at: 1,
        deliver_to_slots: ["lead", "reviewer"],
      },
    ],
  });
  await settle();

  assert.equal(fileFetchCount, 1, "attachment fetched only once across multiple target slots");

  const leadFile = join(b.session(lead.session).workspace, "uploads", "task-1-0-spec.txt");
  const revFile = join(b.session(reviewer.session).workspace, "uploads", "task-1-0-spec.txt");
  assert.ok(existsSync(leadFile), "lead received its own copy");
  assert.ok(existsSync(revFile), "reviewer received its own copy");
  assert.deepEqual(readFileSync(leadFile), payload);
  assert.deepEqual(readFileSync(revFile), payload);

  // Verify cache file is 0444 (read-only) and modifying lead's copy does not affect reviewer's copy.
  const cacheFile = join(b.hub.config().dataDir, "task-files", "1", "task-1-0-spec.txt");
  assert.equal(statSync(cacheFile).mode & 0o777, 0o444);
  writeFileSync(leadFile, "mutated by lead");
  assert.deepEqual(readFileSync(revFile), payload, "reviewer copy is isolated from lead mutations");

  // Verify each session's prompt references its own workspace copy path.
  assert.ok(heard(b, lead.session, leadFile));
  assert.ok(heard(b, reviewer.session, revFile));
});

test("actor format includes Task Roster and bounded catch-up (<=20 messages, filenames only, stops at delivered)", async (t) => {
  const b = new Rig();
  t.after(() => b.close());
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async () => ({ seq: 100 }));

  await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_catchup",
    slot: "lead",
    start: { requester: "usr_alice", runtime: "claude", slot: "lead", is_primary: true },
  });
  const reviewer = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_catchup",
    slot: "reviewer",
    join: true,
    start: { requester: "usr_alice", runtime: "claude", slot: "reviewer", is_primary: false },
  });

  // Send 25 messages to lead only.
  const messages: Json[] = [];
  for (let i = 1; i <= 25; i++) {
    messages.push({
      seq: i,
      id: `m_${i}`,
      author: { kind: "person", id: "usr_alice" },
      text: `Context update #${i}`,
      declared: null,
      at: i,
      deliver_to_slots: ["lead"],
    });
  }
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_catchup",
    through: 25,
    roster: [
      { slot: "lead", is_primary: true, role: "Implementer" },
      { slot: "reviewer", is_primary: false, role: "Reviewer" },
    ],
    messages,
  });
  await settle();

  // Now wake reviewer with seq 26: reviewer should see Roster + bounded catch-up of last 20 messages (#6..#25), NOT #1..#5.
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_catchup",
    through: 26,
    messages: [
      {
        seq: 26,
        id: "m_26",
        author: { kind: "person", id: "usr_alice" },
        text: "Reviewer: please audit",
        declared: null,
        at: 26,
        deliver_to_slots: ["reviewer"],
      },
    ],
  });
  await settle();

  const prompt = promptsOf(b, reviewer.session).at(-1)!;
  assert.ok(prompt.includes("[Task Roster]"), "prompt includes Task roster");
  assert.ok(prompt.includes("reviewer"), "roster includes reviewer");
  assert.ok(prompt.includes("Context update #25"), "catch-up includes newest unseen message");
  assert.ok(prompt.includes("Context update #6"), "catch-up includes 20th newest unseen message");
  assert.ok(!prompt.includes("Context update #5\n"), "catch-up caps at 20 messages");
  assert.ok(!prompt.includes("Context update #1\n"), "catch-up drops older messages past 20");
});

test("task.status {all: true} aggregates slot states and task.history returns task_usage", async (t) => {
  const b = new Rig();
  t.after(() => b.close());
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async () => ({ seq: 10 }));

  const lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_status",
    slot: "lead",
    start: { requester: "usr_alice", runtime: "claude", slot: "lead", is_primary: true },
  });
  const reviewer = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_status",
    slot: "reviewer",
    join: true,
    start: { requester: "usr_alice", runtime: "claude", slot: "reviewer", is_primary: false },
  });

  const allStatus = await tasks.handle("salix", { method: "task.status", task: "cnv_status", all: true });
  assert.equal(allStatus.state, "idle");
  assert.equal(allStatus.pending, 0);
  assert.equal(allStatus.slots.length, 2);
  assert.deepEqual(
    allStatus.slots.map((s: Json) => s.slot),
    ["lead", "reviewer"],
  );

  const hist = await tasks.handle("salix", { method: "task.history", task: "cnv_status", slot: "reviewer" });
  assert.ok(hist.task_usage, "multi-session task.history includes task_usage");
  assert.ok(hist.task_usage.by_slot.lead, "task_usage includes lead slot");
  assert.ok(hist.task_usage.by_slot.reviewer, "task_usage includes reviewer slot");
  assert.equal(hist.task_usage.by_slot.lead.session, lead.session);
  assert.equal(hist.task_usage.by_slot.reviewer.session, reviewer.session);
  assert.equal(hist.task_usage.partial, undefined, "clean idle slots do not mark partial");
});

test("R1 regressions: task_usage null/unreadable safety, standing_unknown on error, and retired secondary session does not hijack primary", async (t) => {
  const b = new Rig();
  t.after(() => b.close());
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async () => ({ seq: 10 }));

  const lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_reg",
    slot: "lead",
    start: { requester: "usr_alice", runtime: "claude", slot: "lead", is_primary: true },
  });
  const reviewer = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_reg",
    slot: "reviewer",
    join: true,
    start: { requester: "usr_alice", runtime: "claude", slot: "reviewer", is_primary: false },
  });

  // Item 1: null usage on an idle slot is safe and NOT partial; throwing history marks partial + unreadable.
  const origHistory = b.hub.history.bind(b.hub);
  b.hub.history = (key: string): any => {
    if (key === lead.session) {
      return {
        entries: [],
        usage: { modelCalls: 2, inputTokens: 100, cachedTokens: 20, outputTokens: 40, model: "claude-opus" },
      };
    }
    return { entries: [], usage: null };
  };
  const hNull = await tasks.handle("salix", { method: "task.history", task: "cnv_reg" });
  assert.equal(hNull.task_usage.modelCalls, 2);
  assert.equal(hNull.task_usage.inputTokens, 100);
  assert.equal(hNull.task_usage.by_slot.reviewer.usage, null);
  assert.equal(hNull.task_usage.partial, undefined, "clean null usage must not set partial");

  b.hub.history = (key: string): any => {
    if (key === reviewer.session) throw new Error("corrupt transcript");
    return {
      entries: [],
      usage: { modelCalls: 2, inputTokens: 100, cachedTokens: 20, outputTokens: 40, model: "claude-opus" },
    };
  };
  const hBad = await tasks.handle("salix", { method: "task.history", task: "cnv_reg" });
  assert.equal(hBad.task_usage.partial, true);
  assert.equal(hBad.task_usage.by_slot.reviewer.unreadable, true);
  assert.equal(hBad.task_usage.by_slot.reviewer.usage, null);
  assert.equal(hBad.task_usage.inputTokens, 100);
  b.hub.history = origHistory;

  // Item 2: coding.standing() throwing surfaces standing_unknown: true in both all:true and single-slot status.
  const leadWs = b.session(lead.session).workspace;
  b.hub.coding = {
    get: (ws: string) => (ws === leadWs ? ({ owner: "org", name: "app", base_ref: "main", branch: "comma/t1", worktree: ws, clone: "/tmp/c" } as any) : null),
    standing: async (ws: string) => {
      if (ws === leadWs) throw new Error("git crashed");
      return null;
    },
  } as any;
  const stAll = await tasks.handle("salix", { method: "task.status", task: "cnv_reg", all: true });
  assert.equal(stAll.standing_unknown, true);
  assert.equal(stAll.slots.find((s: Json) => s.slot === "lead").standing_unknown, true);
  const stOne = await tasks.handle("salix", { method: "task.status", task: "cnv_reg", slot: "lead" });
  assert.equal(stOne.standing_unknown, true);
  b.hub.coding = null;

  // Item 4: a message authored by a retired secondary session with deliver_to_slots: ["lead"] must still wake lead!
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_reg",
    through: 1,
    messages: [
      {
        seq: 1,
        id: "m_retired",
        author: { kind: "agent", id: "agt_1", session: "ember:retired-secondary-old" },
        text: "Handoff from retired secondary to lead",
        declared: null,
        at: 1,
        deliver_to_slots: ["lead"],
      },
    ],
  });
  await settle();
  assert.ok(heard(b, lead.session, "Handoff from retired secondary to lead"), "retired secondary session must not hijack lead identity");
});

test("Coding isolated worktrees: non-prefix branch, mutex, base priority, crash-safe recovery, unmerged standing, pushNow/PR refusal", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "coding-multi-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  // Create bare remote repo with main branch.
  const remote = join(dir, "remote.git");
  mkdirSync(remote);
  git(remote, ["init", "--bare", "-b", "main"]);

  const seed = join(dir, "seed");
  mkdirSync(seed);
  git(seed, ["init", "-b", "main"]);
  writeFileSync(join(seed, "README.md"), "hello\n");
  git(seed, ["add", "README.md"]);
  git(seed, ["commit", "-m", "initial"]);
  git(seed, ["remote", "add", "origin", remote]);
  git(seed, ["push", "-u", "origin", "main"]);

  const coding = new Coding({ reposDir: join(dir, "repos"), remote: () => remote });
  const primaryParent = join(dir, "s-lead");
  const secParent = join(dir, "s-reviewer");
  const primaryWs = join(primaryParent, "workspace");
  const secWs = join(secParent, "workspace");

  const primaryRepo: Repo = { owner: "org", name: "app", base_ref: "main", branch: "comma/task-42" };
  const secRepo: Repo = {
    owner: "org",
    name: "app",
    base_ref: "main",
    branch: "comma-sessions/task-42/reviewer",
    isolated: true,
    primary_branch: "comma/task-42",
  };

  // Make primary and add a local unpushed commit on primary branch.
  await coding.checkout("s-lead", primaryWs, primaryRepo);
  writeFileSync(join(primaryWs, "primary.txt"), "from primary\n");
  git(primaryWs, ["add", "primary.txt"]);
  git(primaryWs, ["commit", "-m", "primary local commit"]);

  // Make secondary: should base off local refs/heads/comma/task-42 (includes primary.txt!).
  await coding.checkout("s-reviewer", secWs, secRepo);
  assert.equal(git(secWs, ["rev-parse", "--abbrev-ref", "HEAD"]), "comma-sessions/task-42/reviewer");
  assert.ok(existsSync(join(secWs, "primary.txt")), "secondary bases on local primary_branch first");

  // Add a commit on secondary -> standing reports unmerged: true.
  writeFileSync(join(secWs, "review.txt"), "review notes\n");
  git(secWs, ["add", "review.txt"]);
  git(secWs, ["commit", "-m", "secondary commit"]);
  const secHead = git(secWs, ["rev-parse", "HEAD"]);

  const st = await coding.standing(secWs);
  assert.equal(st?.unmerged, true);
  assert.equal(st?.dirty, false);

  // Isolated worktree refuses push and pullRequest with CodingRefused.
  await assert.rejects(() => coding.push(secWs), CodingRefused);
  await assert.rejects(() => coding.pullRequest(secWs, {}), CodingRefused);

  // Crash-safe recovery: delete coding.json while .git exists; checkout() must recover coding.json and preserve local commit!
  rmSync(join(secParent, "coding.json"));
  await coding.checkout("s-reviewer", secWs, secRepo);
  assert.ok(existsSync(join(secParent, "coding.json")));
  assert.equal(git(secWs, ["rev-parse", "HEAD"]), secHead, "crash recovery must not reset local commits");

  // Unrelated branch refusal: if workspace is on another branch and coding.json is missing, checkout() refuses.
  git(secWs, ["checkout", "-b", "unrelated-branch"]);
  rmSync(join(secParent, "coding.json"));
  await assert.rejects(() => coding.checkout("s-reviewer", secWs, secRepo), /refusing to overwrite/);
});

test("usage attribution uses canonical person ID for primary & secondary Task sessions (never agt_...@agents.salix)", async (t) => {
  assert.equal(canonicalUsagePerson("usr_alice"), "usr_alice");
  assert.equal(canonicalUsagePerson("slack:task:usr_alice"), "usr_alice");
  assert.equal(canonicalUsagePerson("agt_router@agents.salix"), null);
  assert.equal(canonicalUsagePerson("   "), null);

  const b = new Rig();
  t.after(() => b.close());
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async () => ({ seq: 5 }));

  const lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_usage",
    slot: "lead",
    start: {
      requester: "agt_router@agents.salix",
      person: "usr_alice",
      runtime: "claude",
      slot: "lead",
      is_primary: true,
    },
  });
  const sec = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_usage",
    slot: "reviewer",
    join: true,
    start: {
      requester: "agt_router@agents.salix",
      person: "usr_alice",
      runtime: "claude",
      slot: "reviewer",
      is_primary: false,
    },
  });

  // Record synthetic usage turns on both sessions via store/entries or verify sessions.person column + usageTurns.
  const leadRow = b.store.db.prepare("SELECT person FROM sessions WHERE key = ?").get(lead.session) as { person: string | null };
  const secRow = b.store.db.prepare("SELECT person FROM sessions WHERE key = ?").get(sec.session) as { person: string | null };
  assert.equal(leadRow.person, "usr_alice");
  assert.equal(secRow.person, "usr_alice");

  // Trigger a turn on both sessions and check usageTurns person attribution.
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_usage",
    through: 1,
    messages: [
      {
        seq: 1,
        id: "m_u1",
        author: { kind: "agent", id: "agt_router" },
        text: "Run audit",
        declared: null,
        at: 1,
        deliver_to_slots: ["lead", "reviewer"],
      },
    ],
  });
  await settle();

  const leadTurns = usageTurns(b.store.db, lead.session);
  const secTurns = usageTurns(b.store.db, sec.session);
  assert.ok(leadTurns.length >= 1, "lead recorded at least one usage turn");
  assert.ok(secTurns.length >= 1, "secondary recorded at least one usage turn");
  for (const turn of [...leadTurns, ...secTurns]) {
    assert.equal(turn.of.person, "usr_alice", "Task usage turn must be attributed to canonical person, never synthetic agent");
  }
});

test("R1-2/3/10/11/12: answered_by_slot, visible_to_slots isolation, task_arrivals pending, non-prefix attachment rewrite, 16KiB cap, non-join non-lead refusal", async (t) => {
  const b = new Rig();
  t.after(() => b.close());
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async () => ({ seq: 10 }));

  const lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r1_all",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const rev = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r1_all",
    slot: "reviewer",
    join: true,
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });

  // Item 12: non-join invite with non-"lead" slot on existing thread is rejected.
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_r1_all",
        slot: "rogue",
        start: { requester: "r@test", runtime: "claude", slot: "rogue", is_primary: false },
      }),
    /join: true/,
  );

  // Item 2: answered_by_slot {lead: 5, reviewer: 1} with thread answered=1 keeps seq 4 delivered to reviewer while skipping lead!
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r1_all",
    through: 5,
    answered: 1,
    answered_by_slot: { lead: 5, reviewer: 1 },
    messages: [
      {
        seq: 4,
        id: "m_r1_4",
        author: { kind: "agent", id: "agt_router" },
        text: "Only reviewer needs seq 4",
        declared: null,
        at: 4,
        deliver_to_slots: ["lead", "reviewer"],
      },
      {
        seq: 5,
        id: "m_r1_5",
        author: { kind: "agent", id: "agt_router" },
        text: "Lead-only private note",
        declared: null,
        at: 5,
        deliver_to_slots: [],
        visible_to_slots: ["lead"],
      },
    ],
  });
  await settle();
  assert.ok(!heard(b, lead.session, "Only reviewer needs seq 4"), "lead already answered through 5");
  assert.ok(heard(b, rev.session, "Only reviewer needs seq 4"), "reviewer must receive seq 4 because reviewer answered only through 1");

  // Item 3: visible_to_slots hides lead-only message from reviewer catch-up AND threadHistory!
  const threadRow = b.store.latestThread(lead.session)!.thread;
  const leadHist = await threadHistory(b.hub, lead.session, threadRow, "ember", "cnv_r1_all", {});
  const revHist = await threadHistory(b.hub, rev.session, threadRow, "ember", "cnv_r1_all", {});
  assert.ok(leadHist.includes("Lead-only private note"), "lead sees lead-only message");
  assert.ok(!revHist.includes("Lead-only private note"), "reviewer must NOT see lead-only message in threadHistory");

  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r1_all",
    through: 6,
    roster: [
      { slot: "lead", primary: true, label: "@lead", role: "x".repeat(17_000) },
      { slot: "reviewer", primary: false, label: "@reviewer", role: "y".repeat(17_000) },
    ],
    messages: [
      {
        seq: 6,
        id: "m_r1_6",
        author: { kind: "agent", id: "agt_router" },
        text: "Reviewer wakeup after private note",
        declared: null,
        at: 6,
        deliver_to_slots: ["reviewer"],
      },
    ],
  });
  await settle();
  assert.ok(!heard(b, rev.session, "Lead-only private note"), "reviewer catch-up context must filter out lead-only message");

  // Item 12: 17 KiB role keeps total task context <= 16 KiB UTF-8!
  const revPrompt = promptsOf(b, rev.session).join("\n");
  const rosterStart = revPrompt.indexOf("[Task Roster]");
  assert.ok(rosterStart >= 0, "roster present in prompt");
  const msgStart = revPrompt.indexOf("Reviewer wakeup after private note", rosterStart);
  assert.ok(msgStart > rosterStart, "message follows roster");
  const contextSlice = revPrompt.slice(rosterStart, msgStart);
  assert.ok(Buffer.byteLength(contextSlice, "utf8") <= 16 * 1024 + 64, `task context must stay <= 16 KiB, got ${Buffer.byteLength(contextSlice, "utf8")}`);

  // Item 10-Station / R2-8 / R3-C2: pending task_arrival_counts index is counted in task.status {all: true}
  // after upgrade rebuild from task_arrivals, with zero TEMP B-TREE in EXPLAIN QUERY PLAN.
  const thread = threadRow.id;
  b.store.db.prepare(
    "INSERT INTO task_arrivals (thread, seq, message) VALUES (?, ?, ?)",
  ).run(
    thread,
    99,
    JSON.stringify({ seq: 99, text: "queued", deliver_to_slots: ["reviewer"] }),
  );
  // Simulate pre-upgrade DB: rebuild task_arrival_slots & task_arrival_counts from task_arrivals.
  addMultiSessionTaskColumns(b.store.db);
  const plan = b.store.db
    .prepare("EXPLAIN QUERY PLAN SELECT slot, pending_count FROM task_arrival_counts WHERE thread = ?")
    .all(thread) as Array<{ detail?: string }>;
  assert.ok(
    !plan.some((p) => (p.detail ?? "").toUpperCase().includes("TEMP B-TREE")),
    `task_arrival_counts query must not use TEMP B-TREE: ${JSON.stringify(plan)}`,
  );
  const status = await tasks.handle("salix", {
    method: "task.status",
    task: "cnv_r1_all",
    session: lead.session,
    all: true,
  });
  const revSlotStatus = (status.slots as Array<{ slot: string; pending: number }>).find((s) => s.slot === "reviewer");
  assert.ok(revSlotStatus && revSlotStatus.pending >= 1, "pending task_arrivals must be counted in slot pending");
});

test("R1-8/14: primary local branch preserved (no -B reset), corrupt transcript sets partial: true, mid-session model switch splits models", async (t) => {
  // Part A: Primary local branch ahead of origin is NOT reset on checkout.
  const dir = mkdtempSync(join(tmpdir(), "coding-primary-preserve-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const remote = join(dir, "remote.git");
  mkdirSync(remote);
  git(remote, ["init", "--bare", "-b", "main"]);
  const seed = join(dir, "seed");
  mkdirSync(seed);
  git(seed, ["init", "-b", "main"]);
  writeFileSync(join(seed, "README.md"), "v1\n");
  git(seed, ["add", "README.md"]);
  git(seed, ["commit", "-m", "init"]);
  git(seed, ["remote", "add", "origin", remote]);
  git(seed, ["push", "-u", "origin", "main"]);

  const coding = new Coding({ reposDir: join(dir, "repos"), remote: () => remote });
  const ws1 = join(dir, "p1", "workspace");
  const primaryRepo: Repo = { owner: "org", name: "app", base_ref: "main", branch: "comma/preserve-1" };
  await coding.checkout("s-p1", ws1, primaryRepo);
  writeFileSync(join(ws1, "local.txt"), "unpushed work\n");
  git(ws1, ["add", "local.txt"]);
  git(ws1, ["commit", "-m", "unpushed local commit"]);
  const localHead = git(ws1, ["rev-parse", "HEAD"]);

  // Remove worktree directory and prune, keeping local refs/heads/comma/preserve-1 intact.
  const bareDir = git(ws1, ["rev-parse", "--git-common-dir"]);
  rmSync(ws1, { recursive: true, force: true });
  git(bareDir, ["worktree", "prune"]);
  const ws2 = join(dir, "p2", "workspace");
  await coding.checkout("s-p2", ws2, primaryRepo);
  assert.equal(git(ws2, ["rev-parse", "HEAD"]), localHead, "primary checkout must preserve existing local branch commits");

  // Part B: Mid-session model switch splits models[A] and models[B], and missing transcript for ran session marks partial: true.
  const b = new Rig();
  t.after(() => b.close());
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async () => ({ seq: 1 }));

  const lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_models",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const rev = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_models",
    slot: "reviewer",
    join: true,
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });

  // Write a real Claude JSONL transcript with two different models for lead inside profile.home/projects/test/rt_lead.jsonl.
  const leadProfile = b.hub.config().profiles.find((p) => p.id === b.store.getSession(lead.session)!.profile)!;
  const projDir = join(leadProfile.home, "projects", "test");
  mkdirSync(projDir, { recursive: true });
  const tFile = join(projDir, "rt_lead.jsonl");
  writeFileSync(
    tFile,
    [
      JSON.stringify({
        type: "assistant",
        message: { id: "msg_m1", model: "claude-sonnet-4", usage: { input_tokens: 100, cache_read_input_tokens: 10, output_tokens: 40 } },
      }),
      JSON.stringify({
        type: "assistant",
        message: { id: "msg_m2", model: "claude-opus-4", usage: { input_tokens: 200, cache_read_input_tokens: 20, output_tokens: 80 } },
      }),
    ].join("\n") + "\n",
  );
  b.store.setRuntimeSessionId(lead.session, "rt_lead");
  // Give reviewer a runtime_session_id with no transcript file on disk -> must mark partial: true!
  b.store.setRuntimeSessionId(rev.session, "rt_rev_missing");

  const hist = await tasks.handle("salix", {
    method: "task.history",
    task: "cnv_models",
    session: lead.session,
    limit: 1,
  });
  const tu = hist.task_usage as {
    partial?: boolean;
    inputTokens?: number;
    models?: Record<string, { modelCalls: number; inputTokens: number; outputTokens: number }>;
  };
  assert.equal(tu.partial, true, "missing transcript for a session that has run must mark partial: true");
  assert.equal(tu.inputTokens, 330);
  assert.equal(tu.models?.["claude-sonnet-4"]?.inputTokens, 110);
  assert.equal(tu.models?.["claude-sonnet-4"]?.modelCalls, 1);
  assert.equal(tu.models?.["claude-opus-4"]?.inputTokens, 220);
  assert.equal(tu.models?.["claude-opus-4"]?.modelCalls, 1);
});

test("R2-2/5/11/12: explicit answered_through_seq=0, paginated & archived visible_to_slots, email person key, custom primary alias & non-join secondary refusal", async (t) => {
  const b = new Rig();
  t.after(() => b.close());
  const posted: Json[] = [];
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async (req: Json): Promise<Json> => {
    if (req.method === "task.post") {
      posted.push(req);
      return { seq: 10 + posted.length };
    }
    return {};
  });

  // Custom primary alias ("architect") + secondary ("reviewer").
  const lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r2",
    slot: "architect",
    start: { requester: "r@test", person: "alice@example.com", runtime: "claude", slot: "architect", is_primary: true },
  });
  const rev = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r2",
    slot: "reviewer",
    join: true,
    start: { requester: "r@test", person: "alice@example.com", runtime: "claude", slot: "reviewer", is_primary: false },
  });

  // R2-12: non-join invite targeting existing secondary is rejected EVEN with replace: true!
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_r2",
        slot: "reviewer",
        replace: true,
        start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
      }),
    /join: true/,
  );
  // Custom primary alias IS accepted by join: false idempotent invite.
  const leadAgain = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r2",
    slot: "architect",
    start: { requester: "r@test", runtime: "claude", slot: "architect", is_primary: true },
  });
  assert.equal(leadAgain.session, lead.session);

  // R2-2: terminal post with 0 delivered messages explicitly sends answered_through_seq: 0.
  const threadRow = b.store.latestThread(lead.session)!.thread;
  await tasks.post(
    { channel: threadRow.channel, threadTs: threadRow.threadTs },
    "Finishing immediately",
    [],
    { session: lead.session, declared: "all_done", milestones: null },
  );
  assert.equal(posted[0]?.answered_through_seq, 0, "terminal post with 0 deliveries must explicitly send answered_through_seq: 0");

  // R2-5 + R2-11: seq 1 visible to both (author has email), seq 2 restricted to architect only.
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r2",
    through: 2,
    messages: [
      {
        seq: 1,
        id: "m_pub",
        author: { kind: "person", id: "usr_alice", email: "alice@example.com" },
        text: "Shared visible seq 1",
        declared: null,
        at: 1,
        deliver_to_slots: [],
      },
      {
        seq: 2,
        id: "m_priv",
        author: { kind: "agent", id: "agt_router" },
        text: "Architect-only secret seq 2",
        declared: null,
        at: 2,
        deliver_to_slots: [],
        visible_to_slots: ["architect"],
      },
    ],
  });

  // R2-11: person author uses canonical email matching start.person.
  const allMsgs = b.store.messagesBefore(threadRow.id, null, 10);
  const msg1 = allMsgs.find((m) => m.text === "Shared visible seq 1")!;
  const msg2 = allMsgs.find((m) => m.text === "Architect-only secret seq 2")!;
  assert.equal(msg1.author, "alice@example.com");

  // R2-5: limit=1 for reviewer skips architect-only seq 2 and returns visible seq 1 (not "No earlier messages.")!
  const revPage = await threadHistory(b.hub, rev.session, threadRow, "ember", "cnv_r2", { limit: 1 });
  assert.ok(revPage.includes("Shared visible seq 1"), "limit=1 must skip invisible seq 2 and return seq 1");
  assert.ok(!revPage.includes("Architect-only secret seq 2"));

  // R2-5: updateEntryVisibility corrects visibility when authoritative put arrives for same seq.
  b.store.updateEntryVisibility(threadRow.id, msg2.ts!, ["architect", "reviewer"]);
  const revAfterUpdate = await threadHistory(b.hub, rev.session, threadRow, "ember", "cnv_r2", { limit: 1 });
  assert.ok(revAfterUpdate.includes("Architect-only secret seq 2"));
  b.store.updateEntryVisibility(threadRow.id, msg2.ts!, ["architect"]);

  // R2-5: archive thread and confirm visible_to_slots survives JSONL archive roundtrip!
  b.store.setArchived(lead.session, true, "test");
  b.store.setArchived(rev.session, true, "test");
  const revArchived = await threadHistory(b.hub, rev.session, threadRow, "ember", "cnv_r2", { limit: 1 });
  assert.ok(revArchived.includes("Shared visible seq 1"), "archived threadHistory preserves visible pagination");
  assert.ok(!revArchived.includes("Architect-only secret seq 2"), "archived threadHistory preserves visible_to_slots isolation");
});

test("R3-B3/C2: join: true rejects when no active primary exists, and messagesBeforeForSlotPaged enforces scan cap with nextBefore cursor", async (t) => {
  const b = new Rig();
  t.after(() => b.close());
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async () => ({ seq: 1 }));

  // R3-B3: join: true with no active primary must throw no_active_primary (never create orphan secondary).
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_no_primary",
        slot: "reviewer",
        join: true,
        start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
      }),
    /no_active_primary/,
  );

  // R3-C2: messagesBeforeForSlotPaged enforces maxScan cap and returns nextBefore cursor.
  const lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_scan_cap",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const rev = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_scan_cap",
    slot: "reviewer",
    join: true,
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  const threadRow = b.store.latestThread(lead.session)!.thread;
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_scan_cap",
    through: 6,
    messages: [1, 2, 3, 4, 5, 6].map((seq) => ({
      seq,
      id: `m_cap_${seq}`,
      author: { kind: "agent", id: "agt_router" },
      text: `Lead secret ${seq}`,
      declared: null,
      at: seq,
      deliver_to_slots: [],
      visible_to_slots: ["lead"],
    })),
  });
  const paged = b.store.messagesBeforeForSlotPaged(threadRow.id, null, 2, "reviewer", 3);
  assert.equal(paged.messages.length, 0);
  assert.ok(typeof paged.nextBefore === "string" && paged.nextBefore.length > 0, "scan cap must return nextBefore cursor");
  assert.ok(rev.session);
});

test("R4-3/10/11/12: primary recovery keeps secondary alive, same-station echo rewrites attachment to task-files, DB reopen excludes answered arrivals, 2000-line archive decodes <= 500", async (t) => {
  const b = new Rig();
  t.after(() => b.close());
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async () => ({ seq: 1 }));

  // R4-3: Primary deleted while secondary remains -> non-join invite creates NEW primary and preserves secondary!
  const lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r4_all",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const rev = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r4_all",
    slot: "reviewer",
    join: true,
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  const threadRow = b.store.latestThread(lead.session)!.thread;
  // Simulate primary slot deleted while secondary remains bound
  b.store.db.prepare("DELETE FROM task_session_slots WHERE thread = ? AND slot = 'lead'").run(threadRow.id);
  b.store.db.prepare("DELETE FROM thread_sessions WHERE thread = ? AND session = ?").run(threadRow.id, lead.session);

  const recoveredLead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r4_all",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  assert.notEqual(recoveredLead.session, rev.session, "primary recovery must create a new primary session, never adopt secondary");
  const slotsAfter = b.store.taskSlots(threadRow.id);
  assert.ok(slotsAfter.some((s) => s.slot === "reviewer" && s.session === rev.session), "secondary session must stay alive");
  assert.ok(slotsAfter.some((s) => s.slot === "lead" && s.session === recoveredLead.session && s.isPrimary));

  // R4-10: Same-station echo with existing entry updates attachment to /task-files/ so secondary gets its own uploads copy!
  const leadWs = b.store.getSession(recoveredLead.session)!.workspace;
  mkdirSync(join(leadWs, "out"), { recursive: true });
  const srcFile = join(leadWs, "out", "spec.txt");
  writeFileSync(srcFile, "hello spec");
  b.store.insertMessage({
    thread: threadRow.id,
    ts: "5.000000",
    authorKind: "agent",
    author: "salix/lead",
    text: "Sharing spec",
    attachments: [{ name: "spec.txt", path: srcFile, size: 10 }],
  });
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r4_all",
    through: 5,
    messages: [
      {
        seq: 5,
        id: "m_r4_5",
        author: { kind: "agent", id: "agt_w", session: recoveredLead.session },
        text: "Sharing spec",
        declared: null,
        at: 5,
        files: [{ index: 0, name: "spec.txt", size: 10 }],
        deliver_to_slots: ["reviewer"],
      },
    ],
  });
  await settle();
  const updatedEntry = b.store.messageAt(threadRow.id, "5.000000")!;
  assert.ok(updatedEntry.attachments[0]?.path.includes("/task-files/"), "same-station echo must rewrite entry attachment to /task-files/");
  const revWs = b.store.getSession(rev.session)!.workspace;
  assert.ok(heard(b, rev.session, join(revWs, "uploads", "task-5-0-spec.txt")), "reviewer must receive its own workspace uploads path");

  // R4-11: SQLite reopen rebuild excludes arrivals with seq <= slot.answered!
  b.store.db.prepare("UPDATE task_session_slots SET answered = 9 WHERE thread = ? AND slot = 'reviewer'").run(threadRow.id);
  b.store.db
    .prepare("INSERT OR REPLACE INTO task_arrivals (thread, seq, message) VALUES (?, ?, ?)")
    .run(threadRow.id, 9, JSON.stringify({ seq: 9, text: "already answered", deliver_to_slots: ["reviewer"] }));
  addMultiSessionTaskColumns(b.store.db);
  const countRow = b.store.db
    .prepare("SELECT pending_count FROM task_arrival_counts WHERE thread = ? AND slot = 'reviewer'")
    .get(threadRow.id) as { pending_count: number } | undefined;
  assert.equal(countRow?.pending_count ?? 0, 0, "reopen rebuild must exclude seq <= answered");

  // R4-12: 2000-line archive decodes <= 500 lines for bounded reverse pagination!
  const lead2 = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r4_arch",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const archThread = b.store.latestThread(lead2.session)!.thread;
  for (let i = 1; i <= 2000; i++) {
    b.store.insertMessage({
      thread: archThread.id,
      ts: String(i),
      authorKind: "agent",
      author: "agt_router",
      text: `msg ${i}`,
      visibleToSlots: i <= 10 ? ["lead", "reviewer"] : ["lead"],
    });
  }
  b.store.setArchived(lead2.session, true, "test");
  const archPath = join(b.store.archiveDir(), "threads", `${archThread.id}.jsonl.zst`);
  const bounded = readArchiveBackwards(archPath, Number.MAX_SAFE_INTEGER, 500);
  assert.ok(bounded.decoded <= 500, `expected <= 500 decoded lines, got ${bounded.decoded}`);
  assert.equal(bounded.exhausted, false, "2000-line archive with maxDecode=500 must report exhausted=false");
  const revPage = b.store.messagesBeforeForSlotPaged(archThread.id, null, 5, "reviewer", 500);
  assert.equal(revPage.messages.length, 0);
  assert.ok(typeof revPage.nextBefore === "string" && revPage.nextBefore.startsWith("n:"), "nextBefore cursor must be raw entry.n cursor");
});

test("R5-2/4/7/8/10: non-terminal post sends answered_through_seq, idempotent invite advances answered, unique task-seq-idx attachment cache, single-session task.leave, milestone-heavy archive pagination", async (t) => {
  const b = new Rig();
  t.after(() => b.close());
  const posted: Json[] = [];
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async (req: Json): Promise<Json> => {
    if (req.method === "task.post") {
      posted.push(req);
      return { seq: 100 + posted.length };
    }
    return {};
  });

  const lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r5",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const rev = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r5",
    slot: "reviewer",
    join: true,
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  const threadRow = b.store.latestThread(lead.session)!.thread;

  // R5-2: non-terminal progress post explicitly includes answered_through_seq (even when 0)!
  await tasks.post(
    { channel: threadRow.channel, threadTs: threadRow.threadTs },
    "Progress update",
    [],
    { session: rev.session, declared: null, milestones: null },
  );
  assert.equal(posted[0]?.answered_through_seq, 0, "non-terminal progress post must include answered_through_seq");

  // R5-4: idempotent invite with higher answered=9 advances Station slot answered to 9!
  const revAgain = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r5",
    slot: "reviewer",
    join: true,
    answered: 9,
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  assert.equal(revAgain.session, rev.session);
  assert.equal(b.store.taskSlotOf(threadRow.id, rev.session)?.answered, 9);

  // R5-7: same-name same-size files (AAA vs BBB) get unique task-<seq>-<idx>-<name> cache paths without collision!
  const leadWs = b.store.getSession(lead.session)!.workspace;
  const revWs = b.store.getSession(rev.session)!.workspace;
  mkdirSync(join(leadWs, "tmp"), { recursive: true });
  mkdirSync(join(revWs, "tmp"), { recursive: true });
  const fileA = join(leadWs, "tmp", "note.txt");
  const fileB = join(revWs, "tmp", "note.txt");
  writeFileSync(fileA, "AAA");
  writeFileSync(fileB, "BBB");
  b.store.insertMessage({
    thread: threadRow.id,
    ts: "11.000000",
    authorKind: "agent",
    author: "salix/lead",
    text: "File A",
    attachments: [{ name: "note.txt", path: fileA, size: 3 }],
  });
  b.store.insertMessage({
    thread: threadRow.id,
    ts: "12.000000",
    authorKind: "agent",
    author: "salix/rev",
    text: "File B",
    attachments: [{ name: "note.txt", path: fileB, size: 3 }],
  });
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r5",
    through: 12,
    messages: [
      {
        seq: 11,
        id: "m_fa",
        author: { kind: "agent", id: "agt_w", session: lead.session },
        text: "File A",
        declared: null,
        at: 11,
        files: [{ index: 0, name: "note.txt", size: 3 }],
        deliver_to_slots: ["reviewer"],
      },
      {
        seq: 12,
        id: "m_fb",
        author: { kind: "agent", id: "agt_w", session: rev.session },
        text: "File B",
        declared: null,
        at: 12,
        files: [{ index: 0, name: "note.txt", size: 3 }],
        deliver_to_slots: ["lead"],
      },
    ],
  });
  await settle();
  assert.equal(readFileSync(join(revWs, "uploads", "task-11-0-note.txt"), "utf8"), "AAA");
  assert.equal(readFileSync(join(leadWs, "uploads", "task-12-0-note.txt"), "utf8"), "BBB");

  // R5-8: task.leave with explicit session quits ONLY that session, keeping sibling alive!
  await tasks.handle("salix", { method: "task.leave", task: "cnv_r5", session: rev.session });
  const remainingSlots = b.store.taskSlots(threadRow.id);
  assert.equal(remainingSlots.length, 1);
  assert.equal(remainingSlots[0]?.session, lead.session);

  // R5-10: 1 visible message followed by 500 standalone milestones in archived thread -> threadHistory finds it via n:<minN> cursor!
  const leadMs = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r5_ms",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const msThread = b.store.latestThread(leadMs.session)!.thread;
  b.store.insertMessage({
    thread: msThread.id,
    ts: "1.000000",
    authorKind: "agent",
    author: "agt_router",
    text: "Early visible needle",
  });
  for (let i = 2; i <= 502; i++) {
    b.store.insertMessage({
      thread: msThread.id,
      ts: `${i}.000000`,
      authorKind: "agent",
      author: "agt_w",
      text: "",
      milestones: [`step ${i}`],
      visibleToSlots: ["other_slot"],
    });
  }
  b.store.setArchived(leadMs.session, true, "test");
  const page1 = await threadHistory(b.hub, leadMs.session, msThread, "ember", "cnv_r5_ms", { limit: 1 });
  const match = page1.match(/before=(n:\d+)/);
  assert.ok(match, `expected raw n: cursor in page1, got: ${page1}`);
  const page2 = await threadHistory(b.hub, leadMs.session, msThread, "ember", "cnv_r5_ms", { before: match![1], limit: 1 });
  assert.ok(page2.includes("Early visible needle"), `second page must find visible message, got: ${page2}`);
});

test("R6-4/8: claim_token fences concurrent create rollback, and 2000-line cold archive beforeTs uses O(log N) binary search", async (t) => {
  const b = new Rig();
  t.after(() => b.close());
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async () => ({ seq: 1 }));

  // R6-4 Part A: Concurrent creates A & B share primary session S -> A's rollback keeps S alive!
  const leadA = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r6_claim",
    slot: "lead",
    claim_token: "op_A",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const leadB = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r6_claim",
    slot: "lead",
    claim_token: "op_B",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  assert.equal(leadA.session, leadB.session);
  const leaveA = await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r6_claim",
    session: leadA.session,
    claim_token: "op_A",
  });
  assert.equal(leaveA.kept, true, "shared primary session must be kept when concurrent create B holds claim");
  const threadClaim = b.store.latestThread(leadB.session)!.thread;
  assert.equal(b.store.taskSlots(threadClaim.id).length, 1);

  // R6-4 Part B: Exclusive create op_C starts lead + reviewer, then rolls back BOTH cleanly!
  const leadC = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r6_excl",
    slot: "lead",
    claim_token: "op_C",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const revC = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r6_excl",
    slot: "reviewer",
    join: true,
    claim_token: "op_C",
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  const threadExcl = b.store.latestThread(leadC.session)!.thread;
  await tasks.handle("salix", { method: "task.leave", task: "cnv_r6_excl", session: leadC.session, claim_token: "op_C" });
  await tasks.handle("salix", { method: "task.leave", task: "cnv_r6_excl", session: revC.session, claim_token: "op_C" });
  assert.equal(b.store.taskSlots(threadExcl.id).length, 0, "exclusive create rollback must quit both lead and reviewer");

  // R6-8: 2000-line cold archive beforeTs binary search returns exact predecessor in O(log N) decodes!
  const leadArch = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r6_bsearch",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const archThread = b.store.latestThread(leadArch.session)!.thread;
  for (let i = 1; i <= 2000; i++) {
    b.store.insertMessage({
      thread: archThread.id,
      ts: `${i}.000000`,
      authorKind: "agent",
      author: "agt_router",
      text: `Archived message #${i}`,
    });
  }
  b.store.setArchived(leadArch.session, true, "test");

  const p1501 = await threadHistory(b.hub, leadArch.session, archThread, "ember", "cnv_r6_bsearch", { before: "1502.000000", limit: 1 });
  assert.ok(p1501.includes("Archived message #1501"), `expected #1501, got: ${p1501}`);
  const p1500 = await threadHistory(b.hub, leadArch.session, archThread, "ember", "cnv_r6_bsearch", { before: "1501.000000", limit: 1 });
  assert.ok(p1500.includes("Archived message #1500"), `expected #1500, got: ${p1500}`);
  const p1499 = await threadHistory(b.hub, leadArch.session, archThread, "ember", "cnv_r6_bsearch", { before: "1500.000000", limit: 1 });
  assert.ok(p1499.includes("Archived message #1499"), `expected #1499, got: ${p1499}`);

  const archPath = join(b.store.archiveDir(), "threads", `${archThread.id}.jsonl.zst`);
  const n1500 = b.store.entryNByTs(archThread.id, "1500.000000");
  assert.ok(typeof n1500 === "number" && n1500 > 0);
  const probe = readArchiveBackwards(archPath, n1500!, 500, () => true);
  assert.equal(probe.entries.length, 1);
  assert.ok(probe.decoded <= 30, `O(log N) binary search + 1 entry should decode <= 30 lines, got ${probe.decoded}`);
});

test("R7-1/4/8: task.put returns present_slots, SQLite claim_token survives restart & slot rollback, entry_ts_index handles out-of-order ts and 2000 null-ts gaps", async (t) => {
  const b = new Rig();
  t.after(() => b.close());
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async () => ({ seq: 1 }));

  // R7-1: task.put returns authoritative present_slots
  const lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r7_put",
    slot: "lead",
    claim_token: "op_B",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const putAns = await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r7_put",
    through: 1,
    messages: [{ seq: 1, ts: "1.000000", author: { kind: "person", id: "u1" }, text: "hello" }],
  });
  assert.deepEqual(putAns.present_slots, [{ slot: "lead", session: lead.session }]);

  // R7-4a: Simulate Station restart (fresh Tasks instance over same SQLite DB) ->
  // A replays invite with op_A then leaves with op_A -> claim_shared=1 in SQLite keeps B's primary alive!
  const restartedTasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(restartedTasks);
  restartedTasks.attachHost("salix", async () => ({ seq: 1 }));

  const leadReplayA = await restartedTasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r7_put",
    slot: "lead",
    claim_token: "op_A",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  assert.equal(leadReplayA.session, lead.session);
  const leaveA = await restartedTasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r7_put",
    session: leadReplayA.session,
    claim_token: "op_A",
  });
  assert.equal(leaveA.kept, true, "restarted Station must keep shared session in SQLite");
  const threadPut = b.store.latestThread(lead.session)!.thread;
  assert.equal(b.store.taskSlots(threadPut.id).length, 1);

  // R7-4b: Timed-out secondary `qa` (host doesn't know session id) rolled back by (task, slot, claim_token)
  const qa = await restartedTasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r7_put",
    slot: "qa",
    join: true,
    claim_token: "op_qa_timeout",
    start: { requester: "r@test", runtime: "claude", slot: "qa", is_primary: false },
  });
  assert.ok(typeof qa.session === "string");
  assert.equal(b.store.taskSlots(threadPut.id).length, 2);
  const leaveQa = await restartedTasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r7_put",
    slot: "qa",
    claim_token: "op_qa_timeout",
  });
  assert.equal(leaveQa.kept, false);
  assert.equal(leaveQa.removed, true);
  assert.deepEqual(
    b.store.taskSlots(threadPut.id).map((s) => s.slot),
    ["lead"],
    "slot+claim_token leave must quit qa while keeping lead",
  );

  // R7-8a: Out-of-order timestamps [1, 3, 2] in cold archive accurately locate before="2.000000"
  const leadOoo = await restartedTasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r7_ooo",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const oooThread = b.store.latestThread(leadOoo.session)!.thread;
  b.store.insertMessage({ thread: oooThread.id, ts: "1.000000", authorKind: "agent", author: "agt_r", text: "msg-one" });
  b.store.insertMessage({ thread: oooThread.id, ts: "3.000000", authorKind: "agent", author: "agt_r", text: "msg-three" });
  b.store.insertMessage({ thread: oooThread.id, ts: "2.000000", authorKind: "agent", author: "agt_r", text: "msg-two" });
  b.store.setArchived(leadOoo.session, true, "test");

  const histOoo = await threadHistory(b.hub, leadOoo.session, oooThread, "ember", "cnv_r7_ooo", {
    before: "2.000000",
    limit: 5,
  });
  assert.ok(histOoo.includes("msg-one") && histOoo.includes("msg-three"), `expected msg-one & msg-three before 2.000000, got: ${histOoo}`);
  assert.ok(!histOoo.includes("msg-two"), `must not include msg-two itself, got: ${histOoo}`);

  // R7-8b: 2000 null-ts entries (edits) between timestamped messages -> <= 25 decoded lines!
  const leadGap = await restartedTasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r7_gap",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const gapThread = b.store.latestThread(leadGap.session)!.thread;
  b.store.insertMessage({ thread: gapThread.id, ts: "10.000000", authorKind: "agent", author: "agt_r", text: "early-msg" });
  for (let i = 1; i <= 2000; i++) {
    b.store.editMessage(gapThread.surface, gapThread.channel, gapThread.threadTs, "10.000000", `early-msg-v${i}`);
  }
  b.store.insertMessage({ thread: gapThread.id, ts: "20.000000", authorKind: "agent", author: "agt_r", text: "mid-msg" });
  b.store.insertMessage({ thread: gapThread.id, ts: "30.000000", authorKind: "agent", author: "agt_r", text: "late-msg" });
  b.store.setArchived(leadGap.session, true, "test");

  const nLate = b.store.entryNByTs(gapThread.id, "30.000000");
  assert.ok(typeof nLate === "number" && nLate > 2000);
  const gapPath = join(b.store.archiveDir(), "threads", `${gapThread.id}.jsonl.zst`);
  const gapProbe = readArchiveBackwards(gapPath, nLate!, 500, (e) => e.kind === "message");
  assert.equal(gapProbe.entries.length, 1);
  assert.equal(gapProbe.entries[0]!.ts, "20.000000");
  assert.ok(gapProbe.decoded <= 25, `2000 null-ts gap binary search on entry.n must decode <= 25 lines, got ${gapProbe.decoded}`);

  // R8 P1-1 + R28 P0-1: Because task.put above did NOT pass confirmed_claims for op_B,
  // lead remained uncommitted; after op_A left (kept: true), last uncommitted holder op_B
  // leaving cleanly removes it with { ok: true, removed: true, kept: false }!
  const leaveB = await restartedTasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r7_put",
    session: lead.session,
    claim_token: "op_B",
  });
  assert.deepEqual(leaveB, { ok: true, removed: true, kept: false });
  assert.equal(b.store.taskSlots(threadPut.id).length, 0);

  // R8 P1-5: Upgrade boundary: pre-upgrade hot messages (missing from entry_ts_index) + post-upgrade message 3 ->
  // archiving atomically backfills all hot messages and sets ts_indexed = 1!
  const leadUpg = await restartedTasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r8_upgrade",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const upgThread = b.store.latestThread(leadUpg.session)!.thread;
  b.store.insertMessage({ thread: upgThread.id, ts: "1.000000", authorKind: "agent", author: "agt_r", text: "pre-upg-1" });
  b.store.insertMessage({ thread: upgThread.id, ts: "2.000000", authorKind: "agent", author: "agt_r", text: "pre-upg-2" });
  // Simulate pre-upgrade DB where messages 1 & 2 were not in entry_ts_index yet
  b.store.db.prepare("DELETE FROM entry_ts_index WHERE thread = ?").run(upgThread.id);
  b.store.insertMessage({ thread: upgThread.id, ts: "3.000000", authorKind: "agent", author: "agt_r", text: "post-upg-3" });
  b.store.setArchived(leadUpg.session, true, "test");

  assert.ok(typeof b.store.entryNByTs(upgThread.id, "2.000000") === "number");
  assert.ok(typeof b.store.entryNByTs(upgThread.id, "3.000000") === "number");
  const histUpg = await threadHistory(b.hub, leadUpg.session, upgThread, "ember", "cnv_r8_upgrade", {
    before: "2.000000",
    limit: 5,
  });
  assert.ok(histUpg.includes("pre-upg-1"), `expected pre-upg-1 before 2.000000, got: ${histUpg}`);
  assert.ok(!histUpg.includes("pre-upg-2"));

  // R9 P0-4: Legacy single-session task upgraded in-place via `join: true` sets claim_committed=1
  // on backfilled primary so fenced task.leave NEVER quits the legacy primary!
  const legacyLead = await restartedTasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r9_legacy_upgrade",
    start: { requester: "r@test", runtime: "claude" },
  });
  const legacyThread = b.store.latestThread(legacyLead.session)!.thread;
  // Simulate pre-multi-session legacy DB where task_session_slots had no row yet
  b.store.db.prepare("DELETE FROM task_session_slots WHERE thread = ?").run(legacyThread.id);
  const legacySec = await restartedTasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r9_legacy_upgrade",
    slot: "reviewer",
    join: true,
    claim_token: "op_sec",
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  assert.ok(typeof legacySec.session === "string");
  const leadSlotRow = b.store.db
    .prepare("SELECT claim_committed FROM task_session_slots WHERE thread = ? AND slot = 'lead'")
    .get(legacyThread.id) as { claim_committed: number } | undefined;
  assert.equal(leadSlotRow?.claim_committed, 1, "legacy in-place upgrade must mark primary claim_committed=1");
  const fencedLeaveLead = await restartedTasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r9_legacy_upgrade",
    slot: "lead",
    claim_token: "op_sec",
  });
  assert.equal(fencedLeaveLead.kept, true);

  // R10 P1-1 & P1-4: Atomic claim persistence on new slot + Store.leaveTaskSlotFenced emits
  // session & thread change events ONLY when a session is actually removed (silent on kept: true).
  const leadEv = await restartedTasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r10_events",
    slot: "lead",
    claim_token: "op_r10_1",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const evThread = b.store.latestThread(leadEv.session)!.thread;
  const initialClaims = b.store.db
    .prepare("SELECT claim_token FROM task_session_claims WHERE thread = ? AND slot = 'lead'")
    .all(evThread.id) as { claim_token: string }[];
  assert.deepEqual(
    initialClaims.map((r) => r.claim_token),
    ["op_r10_1"],
    "new slot invite must atomically persist task_session_claims",
  );

  // Second concurrent holder shares the same slot
  await restartedTasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r10_events",
    slot: "lead",
    claim_token: "op_r10_2",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });

  const observed: { type: string; key?: string; id?: number }[] = [];
  const unsub = b.store.subscribe((c) => {
    if (c.type === "session") observed.push({ type: "session", key: c.key });
    else if (c.type === "thread") observed.push({ type: "thread", id: c.id });
  });
  try {
    // First holder leaves -> kept: true, MUST emit NO store change events
    const leaveFirst = await restartedTasks.handle("salix", {
      method: "task.leave",
      task: "cnv_r10_events",
      session: leadEv.session,
      claim_token: "op_r10_1",
    });
    assert.equal(leaveFirst.kept, true);
    assert.equal(observed.length, 0, "kept fenced leave must not emit store change events");

    // Last holder leaves -> actually removed, MUST emit both session and thread events
    const leaveLast = await restartedTasks.handle("salix", {
      method: "task.leave",
      task: "cnv_r10_events",
      session: leadEv.session,
      claim_token: "op_r10_2",
    });
    assert.equal(leaveLast.kept, false);
    assert.equal(leaveLast.removed, true);
    assert.ok(
      observed.some((e) => e.type === "session" && e.key === leadEv.session),
      "removing session via leaveTaskSlotFenced must emit session change event",
    );
    assert.ok(
      observed.some((e) => e.type === "thread" && e.id === evThread.id),
      "removing session via leaveTaskSlotFenced must emit thread change event",
    );
  } finally {
    unsub();
  }

  // R10 P1-1 fault injection: if task_session_claims INSERT fails inside joinTaskSlotAtomic,
  // thread_sessions, task_session_slots, and task_session_claims MUST ALL roll back to 0 rows!
  const leadFault = await restartedTasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r10_atomic_rollback",
    slot: "lead",
    claim_token: "op_fault_lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const faultThread = b.store.latestThread(leadFault.session)!.thread;

  b.store.db.exec(`
    CREATE TEMP TRIGGER fail_claim_insert
    BEFORE INSERT ON task_session_claims
    WHEN NEW.slot = 'qa'
    BEGIN
      SELECT RAISE(ABORT, 'injected claim insert failure');
    END;
  `);
  try {
    await assert.rejects(
      () =>
        restartedTasks.handle("salix", {
          method: "task.invite",
          task: "cnv_r10_atomic_rollback",
          slot: "qa",
          join: true,
          claim_token: "op_fault_qa",
          start: { requester: "r@test", runtime: "claude", slot: "qa", is_primary: false },
        }),
      /injected claim insert failure/,
    );
  } finally {
    b.store.db.exec("DROP TRIGGER IF EXISTS temp.fail_claim_insert");
  }

  // Only the primary session remains in thread_sessions, task_session_slots, task_session_claims;
  // 0 rows exist for the rolled-back `qa` secondary across all three tables!
  const membersAfterFault = b.store.threadSessions(faultThread.id);
  assert.equal(membersAfterFault.length, 1, "rolled-back join must not leave orphan thread_sessions row");
  assert.equal(membersAfterFault[0]!.session, leadFault.session);
  const qaSlotRows = b.store.db
    .prepare("SELECT * FROM task_session_slots WHERE thread = ? AND slot = 'qa'")
    .all(faultThread.id);
  assert.equal(qaSlotRows.length, 0, "rolled-back join must leave 0 task_session_slots rows for qa");
  const qaClaimRows = b.store.db
    .prepare("SELECT * FROM task_session_claims WHERE thread = ? AND slot = 'qa'")
    .all(faultThread.id);
  assert.equal(qaClaimRows.length, 0, "rolled-back join must leave 0 task_session_claims rows for qa");

  // R11 P1-1: 3 consecutive claim INSERT failures (1 secondary + 2 fresh primary invites)
  // MUST leave listSessions count unchanged, threads count unchanged, and emit 0 store events!
  const sessionsBeforeR11 = b.store.listSessions().length;
  const threadsBeforeR11 = (b.store.db.prepare("SELECT COUNT(*) AS c FROM threads").get() as { c: number }).c;
  const r11Events: unknown[] = [];
  const unsubR11 = b.store.subscribe((c) => r11Events.push(c));

  b.store.db.exec(`
    CREATE TEMP TRIGGER fail_all_r11_claims
    BEFORE INSERT ON task_session_claims
    BEGIN
      SELECT RAISE(ABORT, 'injected r11 atomic rollback');
    END;
  `);
  try {
    // 1. Secondary join failure
    await assert.rejects(
      () =>
        restartedTasks.handle("salix", {
          method: "task.invite",
          task: "cnv_r10_atomic_rollback",
          slot: "reviewer",
          join: true,
          claim_token: "op_r11_sec",
          start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
        }),
      /injected r11 atomic rollback/,
    );
    // 2. First fresh primary failure
    await assert.rejects(
      () =>
        restartedTasks.handle("salix", {
          method: "task.invite",
          task: "cnv_r11_fresh_primary_1",
          slot: "lead",
          claim_token: "op_r11_p1",
          start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
        }),
      /injected r11 atomic rollback/,
    );
    // 3. Second fresh primary failure
    await assert.rejects(
      () =>
        restartedTasks.handle("salix", {
          method: "task.invite",
          task: "cnv_r11_fresh_primary_2",
          slot: "lead",
          claim_token: "op_r11_p2",
          start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
        }),
      /injected r11 atomic rollback/,
    );
  } finally {
    b.store.db.exec("DROP TRIGGER IF EXISTS temp.fail_all_r11_claims");
    unsubR11();
  }

  assert.equal(b.store.listSessions().length, sessionsBeforeR11, "failed atomic invites must not leak sessions");
  const threadsAfterR11 = (b.store.db.prepare("SELECT COUNT(*) AS c FROM threads").get() as { c: number }).c;
  assert.equal(threadsAfterR11, threadsBeforeR11, "failed atomic invites must not leak threads");
  assert.deepEqual(r11Events, [], "failed atomic invites must emit 0 store change events");

  // R12 P0-1: task.put WITHOUT deliver_to_slots but WITH visible_to_slots: [] MUST create 0 deliveries
  const visLead = await restartedTasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r12_visible_intersect",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const visThread = b.store.latestThread(visLead.session)!.thread;
  await restartedTasks.handle("salix", {
    method: "task.put",
    task: "cnv_r12_visible_intersect",
    through: 1,
    messages: [
      {
        seq: 1,
        author: { kind: "person", id: "usr_1", name: "Alice" },
        text: "restricted app event",
        at: 1000,
        visible_to_slots: [],
      },
    ],
  });
  const visDeliveries = b.store.db
    .prepare("SELECT COUNT(*) AS c FROM deliveries WHERE thread = ? AND session = ?")
    .get(visThread.id, visLead.session) as { c: number };
  assert.equal(visDeliveries.c, 0, "visible_to_slots: [] without deliver_to_slots must create 0 deliveries");

  // R12 P0-2: newSessionAtomic uses exclusive mkdirSync on sessionDir, retries on EEXIST,
  // and NEVER deletes a pre-existing directory on key collision!
  const collidingKey = "ember:colliding-existing-dir";
  const sessionsRoot = join(b.hub.config().dataDir, "sessions", "ember");
  const existingDir = join(sessionsRoot, "colliding-existing-dir");
  mkdirSync(existingDir, { recursive: true });
  const sentinelPath = join(existingDir, "important.txt");
  writeFileSync(sentinelPath, "do-not-delete");

  let draws = 0;
  const keyGen = () => {
    draws += 1;
    return draws === 1 ? collidingKey : "ember:fresh-noncolliding-dir";
  };
  await assert.rejects(
    async () => {
      newSessionAtomic(
        b.hub,
        { runtime: "claude", createdBy: "r@test", host: "salix" },
        () => {
          throw new Error("simulated persist failure");
        },
        undefined,
        keyGen,
      );
    },
    /simulated persist failure/,
  );
  assert.equal(draws, 2, "newSessionAtomic must retry key generation on EEXIST");
  assert.equal(readFileSync(sentinelPath, "utf8"), "do-not-delete", "pre-existing directory must remain 100% intact");

  // R13 P1-3: arrival slots intersect deliver_to_slots ∩ visible_to_slots (empty intersection -> 0 rows)
  // both on enqueueArrival AND on rebuildTaskArrivalSlots!
  const p13Lead = await restartedTasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r13_arrival_intersect",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  await restartedTasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r13_arrival_intersect",
    slot: "reviewer",
    join: true,
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  await restartedTasks.handle("salix", {
    method: "task.put",
    task: "cnv_r13_arrival_intersect",
    through: 1,
    messages: [
      {
        seq: 1,
        author: { kind: "person", id: "usr_1", name: "Alice" },
        text: "attachment with empty visibility intersection",
        at: 1000,
        deliver_to_slots: ["lead"],
        visible_to_slots: [],
        files: [{ index: 0, name: "secret.txt", size: 4 }],
      },
    ],
  });
  const stBeforeRebuild = await restartedTasks.handle("salix", {
    method: "task.status",
    task: "cnv_r13_arrival_intersect",
    session: p13Lead.session,
    all: true,
  });
  const slotsBefore = stBeforeRebuild.slots as { slot: string; pending: number }[];
  assert.equal(slotsBefore.find((s) => s.slot === "lead")?.pending, 0);
  assert.equal(slotsBefore.find((s) => s.slot === "reviewer")?.pending, 0);

  addMultiSessionTaskColumns(b.store.db);
  const stAfterRebuild = await restartedTasks.handle("salix", {
    method: "task.status",
    task: "cnv_r13_arrival_intersect",
    session: p13Lead.session,
    all: true,
  });
  const slotsAfter = stAfterRebuild.slots as { slot: string; pending: number }[];
  assert.equal(slotsAfter.find((s) => s.slot === "lead")?.pending, 0);
  assert.equal(slotsAfter.find((s) => s.slot === "reviewer")?.pending, 0);
});

test("R19 P1-4: task_invite_decisions persists permanent refusal by invite_id across Station restart, replays without creating sessions, allows fresh invite_id, and cleans up on task.leave", async (t) => {
  const b = new Rig();
  t.after(() => b.close());
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);

  const lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r19_inv_dec",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const threadRow = b.store.latestThread(lead.session)!.thread;

  // Permanent refusal with invite_id="inv_refused_1" (missing requester -> permanent refusal)
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_r19_inv_dec",
        slot: "reviewer",
        join: true,
        invite_id: "inv_refused_1",
        start: { requester: "", runtime: "claude", slot: "reviewer", is_primary: false },
      }),
    /start needs its requester/,
  );

  assert.equal(b.store.threadSessions(threadRow.id).length, 1);

  // Reopen Station Tasks on the same SQLite DB (simulating Station restart) and replay the
  // SAME invite_id even with valid start params -> MUST replay original refusal and create 0 new sessions!
  const restarted = new Tasks(b.hub, () => null);
  await assert.rejects(
    () =>
      restarted.handle("salix", {
        method: "task.invite",
        task: "cnv_r19_inv_dec",
        slot: "reviewer",
        join: true,
        invite_id: "inv_refused_1",
        start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
      }),
    /start needs its requester/,
  );
  assert.equal(b.store.threadSessions(threadRow.id).length, 1);

  // A fresh invite_id="inv_fresh_2" on the same slot is NOT blocked!
  const rev = await restarted.handle("salix", {
    method: "task.invite",
    task: "cnv_r19_inv_dec",
    slot: "reviewer",
    join: true,
    invite_id: "inv_fresh_2",
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  assert.ok(typeof rev.session === "string" && rev.session.length > 0);
  assert.equal(b.store.threadSessions(threadRow.id).length, 2);

  // task.leave cleans up task_invite_decisions for that (group_id, conversation_id)
  await restarted.handle("salix", { method: "task.leave", task: "cnv_r19_inv_dec" });
  const remaining = b.store.db
    .prepare("SELECT COUNT(*) AS n FROM task_invite_decisions WHERE group_id = ? AND conversation_id = ?")
    .get("salix", "cnv_r19_inv_dec") as { n: number };
  assert.equal(remaining.n, 0);

  // R20 P1-3: if persisting into task_invite_decisions fails (e.g. SQLite trigger/lock error),
  // Station MUST throw SQLITE_BUSY (transient) and NEVER reply as a settled permanent refusal!
  const lead2 = await restarted.handle("salix", {
    method: "task.invite",
    task: "cnv_r20_persist_fail",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  assert.ok(lead2.session);
  b.store.db.exec(`
    CREATE TEMP TRIGGER fail_invite_decision_insert
    BEFORE INSERT ON task_invite_decisions
    BEGIN
      SELECT RAISE(ABORT, 'simulated disk lock');
    END;
  `);
  await assert.rejects(
    () =>
      restarted.handle("salix", {
        method: "task.invite",
        task: "cnv_r20_persist_fail",
        slot: "reviewer",
        join: true,
        invite_id: "inv_persist_fail_1",
        start: { requester: "", runtime: "claude", slot: "reviewer", is_primary: false },
      }),
    /SQLITE_BUSY: failed to persist invite decision/,
  );
  b.store.db.exec("DROP TRIGGER fail_invite_decision_insert;");
});

test("R24 P1: Station rejects join:true when existing slot session has conflicting model, while idempotently returning same session on matching model", async (t) => {
  const b = new Rig();
  t.after(() => b.close());
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async () => ({}));

  const lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r24_conflict",
    slot: "lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  assert.ok(lead.session);

  const rev = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r24_conflict",
    slot: "reviewer",
    join: true,
    invite_id: "inv_r24_s1",
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  assert.ok(rev.session);
  b.store.db.prepare("UPDATE sessions SET model = ? WHERE key = ?").run("m1", rev.session);
  // Salix commits reviewer binding via task.put (flips claim_committed = 1)
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r24_conflict",
    answered_by_slot: { lead: 0, reviewer: 0 },
    messages: [],
    through: 0,
  });

  // Conflicting model m2 MUST throw slot_config_conflict and NEVER return S1!
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_r24_conflict",
        slot: "reviewer",
        join: true,
        invite_id: "inv_r24_m2_conflict",
        start: { requester: "r@test", runtime: "claude", model: "m2", slot: "reviewer", is_primary: false },
      }),
    /slot_config_conflict/,
  );

  // Conflicting runtime codex MUST also throw slot_config_conflict!
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_r24_conflict",
        slot: "reviewer",
        join: true,
        invite_id: "inv_r24_rt_conflict",
        start: { requester: "r@test", runtime: "codex", slot: "reviewer", is_primary: false },
      }),
    /slot_config_conflict/,
  );

  // Matching model m1 still idempotently returns the exact same S1!
  const revSame = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r24_conflict",
    slot: "reviewer",
    join: true,
    invite_id: "inv_r24_m1_same",
    start: { requester: "r@test", runtime: "claude", model: "m1", slot: "reviewer", is_primary: false },
  });
  assert.equal(revSame.session, rev.session);
  assert.equal(b.store.getSession(rev.session)?.model, "m1");

  // R25 P1-4: Default-config slot (model=null, effort=null) MUST reject explicit model/effort
  // requests with slot_config_conflict while preserving null columns, and still reuse on empty!
  const qa = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r24_conflict",
    slot: "qa",
    join: true,
    invite_id: "inv_r25_qa_default",
    start: { requester: "r@test", runtime: "claude", slot: "qa", is_primary: false },
  });
  assert.ok(qa.session);
  assert.equal(b.store.getSession(qa.session)?.model, null);
  assert.equal(b.store.getSession(qa.session)?.effort, null);
  // Salix commits qa binding via task.put (flips claim_committed = 1)
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r24_conflict",
    answered_by_slot: { lead: 0, reviewer: 0, qa: 0 },
    messages: [],
    through: 0,
  });

  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_r24_conflict",
        slot: "qa",
        join: true,
        invite_id: "inv_r25_qa_m2",
        start: { requester: "r@test", runtime: "claude", model: "m2", slot: "qa", is_primary: false },
      }),
    /slot_config_conflict/,
  );

  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_r24_conflict",
        slot: "qa",
        join: true,
        invite_id: "inv_r25_qa_high",
        start: { requester: "r@test", runtime: "claude", effort: "high", slot: "qa", is_primary: false },
      }),
    /slot_config_conflict/,
  );

  assert.equal(b.store.getSession(qa.session)?.model, null);
  assert.equal(b.store.getSession(qa.session)?.effort, null);

  const qaSame = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r24_conflict",
    slot: "qa",
    join: true,
    invite_id: "inv_r25_qa_empty",
    start: { requester: "r@test", runtime: "claude", slot: "qa", is_primary: false },
  });
  assert.equal(qaSame.session, qa.session);

  // R27 P0-1 & P0-2: Unified ownership & revocation contract (NO authoritative_unbound blind-kill):
  // (1) Uncommitted session S_A(m1) owned by inv_r27_A blocks B(inv_r27_B, m2) with transient
  //     slot_invite_pending (NOT recorded in task_invite_decisions, 0 stop on S_A).
  // (2) Once A fence-revokes S_A via task.leave(claim_token: "inv_r27_A"), B cleanly creates S_B(m2).
  // (3) Once task.put commits S_B (claim_committed = 1) and delivers a message to S_B, a late
  //     A(inv_r27_A_late) NEVER stops S_B or drops its undelivered message, and throws slot_config_conflict.
  // (4) Shared/committed session S_B reused by Y(inv_r27_Y) refuses fenced leave(claim_token: "inv_r27_Y")!
  const orphan = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r24_conflict",
    slot: "orphan_slot",
    join: true,
    claim_token: "inv_r27_A",
    invite_id: "inv_r27_A",
    start: { requester: "r@test", runtime: "claude", slot: "orphan_slot", is_primary: false },
  });
  assert.ok(orphan.session);
  b.store.db.prepare("UPDATE sessions SET model = ? WHERE key = ?").run("m1", orphan.session);

  // B(inv_r27_B, m2) arrives while S_A is still uncommitted -> transient slot_invite_pending, NOT persisted!
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_r24_conflict",
        slot: "orphan_slot",
        join: true,
        claim_token: "inv_r27_B",
        invite_id: "inv_r27_B",
        start: { requester: "r@test", runtime: "claude", model: "m2", slot: "orphan_slot", is_primary: false },
      }),
    /slot_invite_pending/,
  );
  const decisionRow = b.store.db
    .prepare("SELECT decision FROM task_invite_decisions WHERE invite_id = ?")
    .get("inv_r27_B") as { decision: string } | undefined;
  assert.equal(decisionRow, undefined);

  const threadBefore = b.store.latestThread(lead.session)!.thread;
  assert.equal(b.store.taskSlotOf(threadBefore.id, orphan.session)?.slot, "orphan_slot");

  // A fence-revokes its own uncommitted orphan S_A using claim_token == inv_r27_A
  await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r24_conflict",
    slot: "orphan_slot",
    session: orphan.session,
    claim_token: "inv_r27_A",
  });
  assert.equal(b.store.taskSlotOf(threadBefore.id, orphan.session), null);

  // Now B(inv_r27_B, m2) retries and cleanly creates S_B!
  const replaced = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r24_conflict",
    slot: "orphan_slot",
    join: true,
    claim_token: "inv_r27_B",
    invite_id: "inv_r27_B",
    start: { requester: "r@test", runtime: "claude", slot: "orphan_slot", is_primary: false },
  });
  assert.ok(replaced.session);
  assert.notEqual(replaced.session, orphan.session);
  b.store.db.prepare("UPDATE sessions SET model = ? WHERE key = ?").run("m2", replaced.session);

  // Commit S_B via task.put with exact confirmed_claims (flips claim_committed = 1) and delivers message
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r24_conflict",
    answered_by_slot: { lead: 0, reviewer: 0, qa: 0, orphan_slot: 0 },
    confirmed_claims: [{ slot: "orphan_slot", session: replaced.session, claim_token: "inv_r27_B" }],
    messages: [
      {
        seq: 1,
        text: "hello orphan_slot",
        author: { kind: "person", id: "u1" },
        deliver_to_slots: ["orphan_slot"],
      },
    ],
    through: 1,
  });

  // Late A(inv_r27_A_late, m1) MUST NOT stop committed S_B and throws slot_config_conflict!
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_r24_conflict",
        slot: "orphan_slot",
        join: true,
        claim_token: "inv_r27_A_late",
        invite_id: "inv_r27_A_late",
        start: { requester: "r@test", runtime: "claude", model: "m1", slot: "orphan_slot", is_primary: false },
      }),
    /slot_config_conflict/,
  );
  assert.equal(b.store.taskSlotOf(threadBefore.id, replaced.session)?.slot, "orphan_slot");

  // Shared/committed S_B reused by Y(inv_r27_Y, m2) -> fenced leave(claim_token: "inv_r27_Y") MUST keep S_B!
  const reusedY = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r24_conflict",
    slot: "orphan_slot",
    join: true,
    claim_token: "inv_r27_Y",
    invite_id: "inv_r27_Y",
    start: { requester: "r@test", runtime: "claude", model: "m2", slot: "orphan_slot", is_primary: false },
  });
  assert.equal(reusedY.session, replaced.session);

  const fencedOutcome = b.store.leaveTaskSlotFenced(threadBefore.id, replaced.session, "orphan_slot", "inv_r27_Y");
  assert.equal(fencedOutcome.kept, true);
  assert.equal(fencedOutcome.removed, false);
  assert.equal(fencedOutcome.sessionToStop, null);
  assert.equal(b.store.taskSlotOf(threadBefore.id, replaced.session)?.slot, "orphan_slot");

  // R28 P0-1: Exact {slot, session, claim_token} confirmation — stale task.put with bare slot name
  // MUST NOT commit uncommitted orphan A or deliver messages to it; A's fenced leave returns
  // { ok: true, removed: true, kept: false }; only exact confirmed_claims commits B and delivers messages!
  const orphanR28 = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r24_conflict",
    slot: "r28_slot",
    join: true,
    claim_token: "inv_r28_A",
    invite_id: "inv_r28_A",
    start: { requester: "r@test", runtime: "claude", slot: "r28_slot", is_primary: false },
  });
  assert.ok(orphanR28.session);

  // Old task.put naming bare r28_slot in answered_by_slot + deliver_to_slots WITHOUT confirmed_claims
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r24_conflict",
    answered_by_slot: { lead: 0, r28_slot: 0 },
    messages: [
      {
        seq: 10,
        text: "stale put for r28_slot",
        author: { kind: "person", id: "u1" },
        deliver_to_slots: ["r28_slot"],
      },
    ],
    through: 10,
  });

  // claim_committed MUST remain 0 and orphan A MUST have 0 deliveries!
  const r28RowAfterStale = b.store.db
    .prepare("SELECT claim_committed FROM task_session_slots WHERE thread = ? AND slot = ? AND session = ?")
    .get(threadBefore.id, "r28_slot", orphanR28.session) as { claim_committed: number };
  assert.equal(r28RowAfterStale.claim_committed, 0);
  const r28DeliveriesStale = b.store.db
    .prepare("SELECT COUNT(*) AS c FROM task_slot_deliveries WHERE thread = ? AND slot = ? AND session = ?")
    .get(threadBefore.id, "r28_slot", orphanR28.session) as { c: number };
  assert.equal(r28DeliveriesStale.c, 0);

  // A revokes its uncommitted orphan with its own claim_token -> { ok: true, removed: true, kept: false }!
  const leaveOrphanR28 = await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r24_conflict",
    slot: "r28_slot",
    session: orphanR28.session,
    claim_token: "inv_r28_A",
  });
  assert.deepEqual(leaveOrphanR28, { ok: true, removed: true, kept: false });

  // B creates session on r28_slot, then exact confirmed_claims commits B and delivers message seq 11!
  const boundR28 = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r24_conflict",
    slot: "r28_slot",
    join: true,
    claim_token: "inv_r28_B",
    invite_id: "inv_r28_B",
    start: { requester: "r@test", runtime: "claude", slot: "r28_slot", is_primary: false },
  });
  assert.ok(boundR28.session);

  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r24_conflict",
    answered_by_slot: { lead: 0, r28_slot: 0 },
    confirmed_claims: [{ slot: "r28_slot", session: boundR28.session, claim_token: "inv_r28_B" }],
    messages: [
      {
        seq: 11,
        text: "confirmed message for B",
        author: { kind: "person", id: "u1" },
        deliver_to_slots: ["r28_slot"],
      },
    ],
    through: 11,
  });

  const r28RowAfterConfirm = b.store.db
    .prepare("SELECT claim_committed FROM task_session_slots WHERE thread = ? AND slot = ? AND session = ?")
    .get(threadBefore.id, "r28_slot", boundR28.session) as { claim_committed: number };
  assert.equal(r28RowAfterConfirm.claim_committed, 1);
  const r28DeliveriesConfirmed = b.store.db
    .prepare("SELECT COUNT(*) AS c FROM task_slot_deliveries WHERE thread = ? AND slot = ? AND session = ?")
    .get(threadBefore.id, "r28_slot", boundR28.session) as { c: number };
  assert.equal(r28DeliveriesConfirmed.c, 1);

  // R29 P0-3: Concurrent creates A & B share primary S (task_session_claims holds both A and B):
  // (a) Wrong token Z MUST NOT commit S (S absent from committed_slots, 0 deliveries);
  // (b) Holder B in task_session_claims commits S (S appears in committed_slots, message delivered)!
  const sharedA = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r29_shared_claims",
    slot: "lead",
    claim_token: "create:r29_A",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const sharedB = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r29_shared_claims",
    slot: "lead",
    claim_token: "create:r29_B",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  assert.equal(sharedB.session, sharedA.session);
  const sharedThread = b.store.latestThread(sharedA.session)!.thread;

  const putWrongToken = await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r29_shared_claims",
    confirmed_claims: [{ slot: "lead", session: sharedA.session, claim_token: "create:r29_WRONG_Z" }],
    messages: [{ seq: 1, text: "hello wrong token", author: { kind: "person", id: "u1" } }],
    through: 1,
  });
  assert.deepEqual(putWrongToken.present_slots, [{ slot: "lead", session: sharedA.session }]);
  assert.deepEqual(putWrongToken.committed_slots, []);
  const wrongDeliv = b.store.db
    .prepare("SELECT COUNT(*) AS c FROM task_slot_deliveries WHERE thread = ? AND session = ?")
    .get(sharedThread.id, sharedA.session) as { c: number };
  assert.equal(wrongDeliv.c, 0);

  const putHolderB = await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r29_shared_claims",
    confirmed_claims: [{ slot: "lead", session: sharedA.session, claim_token: "create:r29_B" }],
    messages: [{ seq: 2, text: "hello holder B", author: { kind: "person", id: "u1" } }],
    through: 2,
  });
  assert.deepEqual(putHolderB.committed_slots, [{ slot: "lead", session: sharedA.session }]);
  const holderBDeliv = b.store.db
    .prepare("SELECT COUNT(*) AS c FROM task_slot_deliveries WHERE thread = ? AND session = ?")
    .get(sharedThread.id, sharedA.session) as { c: number };
  assert.equal(holderBDeliv.c, 1);

  // R31 P1-4: Missing thread (disk loss) -> fenced task.leave returns explicit idempotent
  // { ok: true, removed: false, kept: false }, while unfenced whole-thread task.leave keeps {}.
  const missingFencedByToken = await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r31_missing_thread",
    slot: "reviewer",
    claim_token: "inv_r31_missing",
  });
  assert.deepEqual(missingFencedByToken, { ok: true, removed: false, kept: false });

  const missingFencedBySession = await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r31_missing_thread",
    session: "ses_r31_gone",
  });
  assert.deepEqual(missingFencedBySession, { ok: true, removed: false, kept: false });

  const missingUnfenced = await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r31_missing_thread",
  });
  assert.deepEqual(missingUnfenced, {});

  // R32 P0-2: claim_token without slot or session MUST throw parameter error both when
  // thread is missing AND when a multi-session thread exists, never touching existing slots.
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.leave",
        task: "cnv_r32_missing_bad_leave",
        claim_token: "tok_only",
      }),
    /slot or session is required when claim_token is set/,
  );

  const r32Lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r32_fenced_validation",
    slot: "lead",
    claim_token: "inv_r32_lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const r32Rev = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r32_fenced_validation",
    slot: "reviewer",
    join: true,
    claim_token: "inv_r32_rev",
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  const r32Thread = b.store.latestThread(r32Lead.session)!.thread;

  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.leave",
        task: "cnv_r32_fenced_validation",
        claim_token: "inv_r32_rev",
      }),
    /slot or session is required when claim_token is set/,
  );
  // Both lead and reviewer remain active and untouched!
  const r32SlotsAfterBad = b.store.taskSlots(r32Thread.id);
  assert.equal(r32SlotsAfterBad.length, 2);
  assert.ok(r32SlotsAfterBad.some((s) => s.slot === "lead" && s.session === r32Lead.session));
  assert.ok(r32SlotsAfterBad.some((s) => s.slot === "reviewer" && s.session === r32Rev.session));

  // R32 P1-3: Out-of-order fenced task.leave(slot="reviewer", claim_token="inv-X") arriving
  // BEFORE the thread or slot exists persists a revocation tombstone; delayed task.invite(inv-X)
  // is permanently rejected with claim_revoked (zero orphan), while new invite inv-Y succeeds!
  const earlyLeaveMissing = await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r32_tombstone",
    slot: "reviewer",
    claim_token: "inv_r32_X",
  });
  assert.deepEqual(earlyLeaveMissing, { ok: true, removed: false, kept: false });
  assert.equal(b.store.isClaimRevoked("salix", "cnv_r32_tombstone", "reviewer", "inv_r32_X"), true);

  const tombLead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r32_tombstone",
    slot: "lead",
    claim_token: "inv_r32_tomb_lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const tombThread = b.store.latestThread(tombLead.session)!.thread;

  // Delayed invite for revoked inv_r32_X MUST fail with claim_revoked and create NO reviewer slot
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_r32_tombstone",
        slot: "reviewer",
        join: true,
        claim_token: "inv_r32_X",
        invite_id: "inv_r32_X",
        start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
      }),
    /claim_revoked/,
  );
  assert.equal(
    b.store.taskSlots(tombThread.id).some((s) => s.slot === "reviewer"),
    false,
    "revoked claim must not create an orphan reviewer session",
  );

  // Fresh invite inv_r32_Y on the same slot succeeds cleanly!
  const tombRevY = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r32_tombstone",
    slot: "reviewer",
    join: true,
    claim_token: "inv_r32_Y",
    invite_id: "inv_r32_Y",
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  assert.ok(typeof tombRevY.session === "string");
  assert.equal(
    b.store.taskSlots(tombThread.id).some((s) => s.slot === "reviewer" && s.session === tombRevY.session),
    true,
  );

  // R33 pre-review (P1-3 + P1-4 combo): Slot `reviewer` is occupied by committed `inv_r32_Y`;
  // fenced `task.leave(slot="reviewer", claim_token="inv_r33_Z")` MUST return `kept: true`
  // (protecting `inv_r32_Y`) AND still record revocation tombstone for `inv_r33_Z` so that
  // even after `inv_r32_Y` leaves, a delayed `task.invite(claim_token="inv_r33_Z")` is rejected!
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r32_tombstone",
    confirmed_claims: [{ slot: "reviewer", session: tombRevY.session, claim_token: "inv_r32_Y" }],
    messages: [],
    through: 0,
  });

  const leaveDifferentZ = await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r32_tombstone",
    slot: "reviewer",
    claim_token: "inv_r33_Z",
  });
  assert.deepEqual(leaveDifferentZ, { ok: true, removed: false, kept: true });
  assert.equal(b.store.isClaimRevoked("salix", "cnv_r32_tombstone", "reviewer", "inv_r33_Z"), true);
  // Committed `inv_r32_Y` is still alive and NOT tombstoned
  assert.equal(b.store.isClaimRevoked("salix", "cnv_r32_tombstone", "reviewer", "inv_r32_Y"), false);
  assert.equal(
    b.store.taskSlots(tombThread.id).some((s) => s.slot === "reviewer" && s.session === tombRevY.session),
    true,
  );

  // Even after `inv_r32_Y` leaves (unfenced single-slot leave), delayed `task.invite(inv_r33_Z)` is rejected!
  await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r32_tombstone",
    slot: "reviewer",
  });
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_r32_tombstone",
        slot: "reviewer",
        join: true,
        claim_token: "inv_r33_Z",
        invite_id: "inv_r33_Z",
        start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
      }),
    /claim_revoked/,
  );
  assert.equal(
    b.store.taskSlots(tombThread.id).some((s) => s.slot === "reviewer"),
    false,
  );

  // R33 P1-1: Tombstone write failure rolls back the entire leaveTaskSlotFenced transaction
  // atomically so slot & thread membership remain intact for retry (never skipping hub.stop)!
  const p11Lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r33_p11_atomic",
    slot: "lead",
    claim_token: "inv_r33_p11_lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const p11Rev = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r33_p11_atomic",
    slot: "reviewer",
    join: true,
    claim_token: "inv_r33_p11_rev",
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  const p11Thread = b.store.latestThread(p11Lead.session)!.thread;

  b.store.db.exec(`
    CREATE TRIGGER fail_r33_tombstone BEFORE INSERT ON task_revoked_claims
    WHEN NEW.claim_token = 'inv_r33_p11_rev'
    BEGIN
      SELECT RAISE(ABORT, 'injected_tombstone_write_failure');
    END;
  `);

  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.leave",
        task: "cnv_r33_p11_atomic",
        slot: "reviewer",
        claim_token: "inv_r33_p11_rev",
      }),
    /injected_tombstone_write_failure/,
  );

  // Slot & thread membership MUST still be completely intact after rollback!
  assert.equal(
    b.store.taskSlots(p11Thread.id).some((s) => s.slot === "reviewer" && s.session === p11Rev.session),
    true,
  );
  assert.equal(
    b.store.threadSessions(p11Thread.id).some((m) => m.session === p11Rev.session),
    true,
  );

  b.store.db.exec("DROP TRIGGER fail_r33_tombstone;");
  const p11Retry = await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r33_p11_atomic",
    slot: "reviewer",
    claim_token: "inv_r33_p11_rev",
  });
  assert.deepEqual(p11Retry, { ok: true, removed: true, kept: false });
  assert.equal(b.store.isClaimRevoked("salix", "cnv_r33_p11_atomic", "reviewer", "inv_r33_p11_rev"), true);
  assert.equal(
    b.store.taskSlots(p11Thread.id).some((s) => s.slot === "reviewer"),
    false,
  );

  // R33 P1-2: Whole-thread task.leave MUST NOT clear task_revoked_claims tombstones!
  await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r33_p11_atomic",
  });
  assert.equal(b.store.isClaimRevoked("salix", "cnv_r33_p11_atomic", "reviewer", "inv_r33_p11_rev"), true);

  // Re-create primary after whole-thread leave -> delayed revoked invite is STILL rejected!
  await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r33_p11_atomic",
    slot: "lead",
    claim_token: "inv_r33_p12_new_lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_r33_p11_atomic",
        slot: "reviewer",
        join: true,
        claim_token: "inv_r33_p11_rev",
        invite_id: "inv_r33_p11_rev",
        start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
      }),
    /claim_revoked/,
  );

  // R33 P1-3: Concurrent creates A & B share `reviewer` session S; ONLY A is confirmed via
  // `confirmed_claims`. Rolling-back B calls fenced `task.leave(B)`: returns `kept: true`
  // (protecting A's S) AND writes B's tombstone. After S later leaves, delayed invite B is
  // rejected with `claim_revoked`, while fresh invite C succeeds!
  const p13Lead = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r33_p13_shared",
    slot: "lead",
    claim_token: "inv_r33_p13_lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const p13Thread = b.store.latestThread(p13Lead.session)!.thread;

  const p13RevA = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r33_p13_shared",
    slot: "reviewer",
    join: true,
    claim_token: "inv_r33_p13_A",
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  const p13RevB = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r33_p13_shared",
    slot: "reviewer",
    join: true,
    claim_token: "inv_r33_p13_B",
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  assert.equal(p13RevB.session, p13RevA.session);

  // Confirm ONLY A
  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r33_p13_shared",
    confirmed_claims: [{ slot: "reviewer", session: p13RevA.session, claim_token: "inv_r33_p13_A" }],
    messages: [],
    through: 0,
  });

  // B rolls back: protects A's session (kept: true) AND writes tombstone for B!
  const leaveBShared = await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r33_p13_shared",
    slot: "reviewer",
    claim_token: "inv_r33_p13_B",
  });
  assert.deepEqual(leaveBShared, { ok: true, removed: false, kept: true });
  assert.equal(b.store.isClaimRevoked("salix", "cnv_r33_p13_shared", "reviewer", "inv_r33_p13_B"), true);
  assert.equal(b.store.isClaimRevoked("salix", "cnv_r33_p13_shared", "reviewer", "inv_r33_p13_A"), false);
  assert.equal(
    b.store.taskSlots(p13Thread.id).some((s) => s.slot === "reviewer" && s.session === p13RevA.session),
    true,
  );

  // After S leaves, delayed invite B is rejected with claim_revoked while fresh C succeeds!
  await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r33_p13_shared",
    slot: "reviewer",
  });
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_r33_p13_shared",
        slot: "reviewer",
        join: true,
        claim_token: "inv_r33_p13_B",
        invite_id: "inv_r33_p13_B",
        start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
      }),
    /claim_revoked/,
  );

  const p13RevC = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r33_p13_shared",
    slot: "reviewer",
    join: true,
    claim_token: "inv_r33_p13_C",
    invite_id: "inv_r33_p13_C",
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  assert.ok(typeof p13RevC.session === "string");

  // R34 P0 Order 1: A creates S, B reuses uncommitted S; confirm ONLY B, then leave(A) ->
  // protects B's S (kept: true), deletes A's claim & writes A's tombstone; after S leaves,
  // delayed invite(A) is rejected with claim_revoked!
  const r34Lead1 = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r34_order1",
    slot: "lead",
    claim_token: "inv_r34_o1_lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const r34Thread1 = b.store.latestThread(r34Lead1.session)!.thread;
  const r34A1 = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r34_order1",
    slot: "reviewer",
    join: true,
    claim_token: "inv_r34_o1_A",
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  const r34B1 = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r34_order1",
    slot: "reviewer",
    join: true,
    claim_token: "inv_r34_o1_B",
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  assert.equal(r34B1.session, r34A1.session);

  await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r34_order1",
    confirmed_claims: [{ slot: "reviewer", session: r34B1.session, claim_token: "inv_r34_o1_B" }],
    messages: [],
    through: 0,
  });

  const leaveA1 = await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r34_order1",
    slot: "reviewer",
    claim_token: "inv_r34_o1_A",
  });
  assert.deepEqual(leaveA1, { ok: true, removed: false, kept: true });
  assert.equal(b.store.isClaimRevoked("salix", "cnv_r34_order1", "reviewer", "inv_r34_o1_A"), true);
  assert.equal(b.store.isClaimRevoked("salix", "cnv_r34_order1", "reviewer", "inv_r34_o1_B"), false);
  assert.equal(
    b.store.taskSlots(r34Thread1.id).some((s) => s.slot === "reviewer" && s.session === r34A1.session),
    true,
  );

  // R35 P0 (Station side): While S is still committed for B, a late task.put carrying revoked A's
  // confirmed_claims returns committed_slots=[..., {reviewer, S}] but confirmed_claims=[] (excludes A);
  // carrying B's triple returns confirmed_claims=[{reviewer, S, B}]!
  const putRejectedA = await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r34_order1",
    confirmed_claims: [{ slot: "reviewer", session: r34A1.session, claim_token: "inv_r34_o1_A" }],
    messages: [],
    through: 0,
  });
  assert.ok((putRejectedA.committed_slots as { slot: string }[]).some((s) => s.slot === "reviewer"));
  assert.deepEqual(putRejectedA.confirmed_claims, []);

  const putAcceptedB = await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r34_order1",
    confirmed_claims: [{ slot: "reviewer", session: r34B1.session, claim_token: "inv_r34_o1_B" }],
    messages: [],
    through: 0,
  });
  assert.deepEqual(putAcceptedB.confirmed_claims, [
    { slot: "reviewer", session: r34B1.session, claim_token: "inv_r34_o1_B" },
  ]);

  await tasks.handle("salix", { method: "task.leave", task: "cnv_r34_order1", slot: "reviewer" });
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_r34_order1",
        slot: "reviewer",
        join: true,
        claim_token: "inv_r34_o1_A",
        invite_id: "inv_r34_o1_A",
        start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
      }),
    /claim_revoked/,
  );

  // R34 P0 Order 2: A creates S, B reuses uncommitted S; FIRST leave(A) (protects B, deletes A,
  // writes A tombstone, updates slot.claim_token); THEN late confirmed_claims(A) MUST NOT commit S;
  // THEN leave(B) cleanly removes and stops S ({ removed: true, kept: false })!
  const r34Lead2 = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r34_order2",
    slot: "lead",
    claim_token: "inv_r34_o2_lead",
    start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
  });
  const r34Thread2 = b.store.latestThread(r34Lead2.session)!.thread;
  const r34A2 = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r34_order2",
    slot: "reviewer",
    join: true,
    claim_token: "inv_r34_o2_A",
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  const r34B2 = await tasks.handle("salix", {
    method: "task.invite",
    task: "cnv_r34_order2",
    slot: "reviewer",
    join: true,
    claim_token: "inv_r34_o2_B",
    start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
  });
  assert.equal(r34B2.session, r34A2.session);

  const leaveA2 = await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r34_order2",
    slot: "reviewer",
    claim_token: "inv_r34_o2_A",
  });
  assert.deepEqual(leaveA2, { ok: true, removed: false, kept: true });
  assert.equal(b.store.isClaimRevoked("salix", "cnv_r34_order2", "reviewer", "inv_r34_o2_A"), true);

  const lateConfirmA2 = await tasks.handle("salix", {
    method: "task.put",
    task: "cnv_r34_order2",
    confirmed_claims: [{ slot: "reviewer", session: r34A2.session, claim_token: "inv_r34_o2_A" }],
    messages: [{ seq: 1, text: "late A confirm must not commit", author: { kind: "person", id: "u1" } }],
    through: 1,
  });
  assert.equal(
    (lateConfirmA2.committed_slots as { slot: string }[]).some((s) => s.slot === "reviewer"),
    false,
    "revoked claim A must NEVER commit S",
  );
  const o2Deliv = b.store.db
    .prepare("SELECT COUNT(*) AS c FROM task_slot_deliveries WHERE thread = ? AND slot = 'reviewer'")
    .get(r34Thread2.id) as { c: number };
  assert.equal(o2Deliv.c, 0);

  const leaveB2 = await tasks.handle("salix", {
    method: "task.leave",
    task: "cnv_r34_order2",
    slot: "reviewer",
    claim_token: "inv_r34_o2_B",
  });
  assert.deepEqual(leaveB2, { ok: true, removed: true, kept: false });
  assert.equal(
    b.store.taskSlots(r34Thread2.id).some((s) => s.slot === "reviewer"),
    false,
  );

  // R34 P1-2: Tombstones are retained permanently (never pruned after 7+ days)!
  b.store.db
    .prepare("UPDATE task_revoked_claims SET revoked_at = revoked_at - ? WHERE claim_token = ?")
    .run(8 * 86_400_000, "inv_r34_o1_A");
  b.store.recordRevokedClaim("salix", "cnv_r34_order1", "reviewer", "inv_r34_o1_Y");
  assert.equal(b.store.isClaimRevoked("salix", "cnv_r34_order1", "reviewer", "inv_r34_o1_A"), true);
  await assert.rejects(
    () =>
      tasks.handle("salix", {
        method: "task.invite",
        task: "cnv_r34_order1",
        slot: "reviewer",
        join: true,
        claim_token: "inv_r34_o1_A",
        invite_id: "inv_r34_o1_A",
        start: { requester: "r@test", runtime: "claude", slot: "reviewer", is_primary: false },
      }),
    /claim_revoked/,
  );

  // R35 P1-1 + P1-2 (Station side): task.hello backoff runs strictly on hub.clock (TestClock)
  // via Fibers.after with capped 15s steps and NO 5-attempt cap -> survives 6 consecutive failures,
  // converges on attempt 7, never fires while clock is frozen, and cancels cleanly on disconnect!
  const tc = testClock();
  const rigTc = new Rig({ clock: tc.clock });
  const tasksTc = new Tasks(rigTc.hub, () => null);
  try {
    let helloAttempts = 0;
    tasksTc.attachHost("salix", async (req) => {
      if (req.method === "task.hello") {
        helloAttempts++;
        if (helloAttempts <= 6) throw new Error("transient_db_error");
        return {};
      }
      return {};
    });

    // Attempt 1 fires immediately and fails -> schedules sleep #1 (1000ms)
    await tc.begun(1);
    assert.equal(helloAttempts, 1);
    assert.equal(tasksTc.hasPendingHelloRetry("salix"), true);

    // Frozen clock: advancing 0ms / yielding microtasks fires NO wall-clock retry
    await Promise.resolve();
    assert.equal(helloAttempts, 1);

    const delays = [1_000, 2_000, 4_000, 8_000, 15_000, 15_000];
    for (let i = 0; i < delays.length; i++) {
      await tc.adjust(delays[i]!);
      if (i < delays.length - 1) {
        await tc.begun(i + 2);
      } else {
        // Attempt 7 succeeds -> allow promise microtasks to clear pending retry state
        await Promise.resolve();
        await Promise.resolve();
      }
      assert.equal(helloAttempts, i + 2);
    }
    assert.equal(tasksTc.hasPendingHelloRetry("salix"), false);

    // Disconnect cancels pending hello retry immediately; advancing virtual clock 30s fires 0 retries
    let discAttempts = 0;
    const sleepsBefore = tc.asked();
    tasksTc.attachHost("salix", async (req) => {
      if (req.method === "task.hello") {
        discAttempts++;
        throw new Error("always_fail");
      }
      return {};
    });
    await tc.begun(sleepsBefore + 1);
    assert.equal(discAttempts, 1);
    assert.equal(tasksTc.hasPendingHelloRetry("salix"), true);

    tasksTc.attachHost("salix", null);
    assert.equal(tasksTc.hasPendingHelloRetry("salix"), false);
    await tc.adjust(30_000);
    await Promise.resolve();
    assert.equal(discAttempts, 1);

    // R36 P1-1: Mesh peer returning Unreachable does NOT schedule endless 15s polling;
    // await tasks.end() cleanly cancels and closes Fibers!
    const tcMesh = testClock();
    const rigMesh = new Rig({ clock: tcMesh.clock });
    const tasksMesh = new Tasks(rigMesh.hub, () => null);
    try {
      await tasksMesh.handle("peer-mesh", {
        method: "task.invite",
        task: "cnv_r36_mesh",
        slot: "lead",
        start: { requester: "r@test", runtime: "claude", slot: "lead", is_primary: true },
      });
      tasksMesh.connected();
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      assert.equal(tasksMesh.hasPendingHelloRetry("peer-mesh"), false);
    } finally {
      await tasksMesh.end();
      await rigMesh.close();
    }

    // R36 P1-2: Local SQLite read error during hello() retry shares the exact same
    // .catch backoff chain and recovers on the next TestClock tick!
    const origPrepare = rigTc.store.db.prepare.bind(rigTc.store.db);
    let sqlReadCalls = 0;
    let recoveredAttempts = 0;
    const sleepsBeforeSql = tc.asked();
    (rigTc.store.db as unknown as { prepare: typeof origPrepare }).prepare = ((sql: string) => {
      if (sql.includes("FROM tasks_elsewhere te")) {
        sqlReadCalls++;
        if (sqlReadCalls === 1) throw new Error("SQLITE_BUSY: transient read");
      }
      return origPrepare(sql);
    }) as typeof origPrepare;
    try {
      tasksTc.attachHost("salix", async (req) => {
        if (req.method === "task.hello") {
          recoveredAttempts++;
          return {};
        }
        return {};
      });
      await tc.begun(sleepsBeforeSql + 1);
      assert.equal(sqlReadCalls, 1);
      assert.equal(recoveredAttempts, 0);
      assert.equal(tasksTc.hasPendingHelloRetry("salix"), true);

      await tc.adjust(1_000);
      await Promise.resolve();
      await Promise.resolve();
      assert.equal(sqlReadCalls, 2);
      assert.equal(recoveredAttempts, 1);
      assert.equal(tasksTc.hasPendingHelloRetry("salix"), false);
    } finally {
      (rigTc.store.db as unknown as { prepare: typeof origPrepare }).prepare = origPrepare;
    }
  } finally {
    await tasksTc.end();
    await rigTc.close();
  }
});
