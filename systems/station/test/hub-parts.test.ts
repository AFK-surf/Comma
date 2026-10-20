// The hub's parts that compute (ported with their Rust tests): splitting for Slack, commands, image sizes, local file
// links, the live view, the agent home, the account pool, the decision protocol, references to other chats.
import assert from "node:assert/strict";
import { appendFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { readTimeline, transcriptPaths } from "../src/read/transcript.ts";
import { linkAgentHome, linkTranscripts, writeBuiltinSkills } from "../src/sessions/agent-home.ts";
import { isSlackMethod, isStopCommand, slackWithFiles } from "../src/sessions/args.ts";
import { splitForSlack } from "../src/sessions/chat.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { completionQuestion, parse, request } from "../src/sessions/decision.ts";
import { sizeOf } from "../src/sessions/image-size.ts";
import { nextTsAt } from "../src/sessions/internal.ts";
import { type LiveMessage, LiveHub } from "../src/sessions/live.ts";
import { prepare } from "../src/sessions/local-links.ts";
import { formatSteps, linkedSession } from "../src/sessions/others.ts";
import { availableEfforts, commonEfforts, pickProfile, serves, urgency } from "../src/sessions/pool.ts";
import { spelling } from "../src/sessions/config.ts";
import { settle, testClock } from "./hub-fakes.ts";

const temp = () => mkdtempSync(join(tmpdir(), "hub-parts-"));

test("long text splits on paragraph boundaries", () => {
  const para = "x".repeat(60);
  assert.deepEqual(splitForSlack(Array(5).fill(para).join("\n\n"), 130), [`${para}\n\n${para}`, `${para}\n\n${para}`, para]);
  assert.deepEqual(splitForSlack("", 3500), [""]);
});

test("commands: -stop after mentions, Slack methods by their shape", () => {
  assert.ok(isStopCommand("<@UBOT>  -stop "));
  assert.ok(!isStopCommand("please -stop now"));
  assert.ok(isSlackMethod("conversations.history") && isSlackMethod("assistant.threads.setStatus"));
  assert.ok(!isSlackMethod("Chat.postMessage") && !isSlackMethod("chat") && !isSlackMethod("chat..x"));
});

test("timestamps only go up", () => {
  const a = nextTsAt(1_000);
  const b = nextTsAt(1_000);
  assert.ok(b > a, `${a} ${b}`);
  assert.equal(nextTsAt(4_102_444_800_000), "4102444800.000000");
});

test("sizes are read from each format's header", () => {
  const be32 = (n: number) => [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255];
  const png = [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10, 0, 0, 0, 13, ...Buffer.from("IHDR"), ...be32(640), ...be32(480)];
  assert.deepEqual(sizeOf(Buffer.from(png)), [640, 480]);
  assert.deepEqual(sizeOf(Buffer.from([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 10, 0, 20, 0])), [10, 20]);
  const jpeg = [0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0, 0xff, 0xc0, 0, 17, 8, 1, 44, 0, 200, ...Array(8).fill(0)];
  assert.deepEqual(sizeOf(Buffer.from(jpeg)), [200, 300]);
  assert.equal(sizeOf(Buffer.from("plain text")), null);
});

test("local links and images are delivered once; code and web links are kept", () => {
  const dir = temp();
  const path = join(dir, "a report(1).txt");
  writeFileSync(path, "report");
  const text = `[报告](<${path}>) ![](<file://${path}>) [line](<${path}:12:3>)\n\`[example](/tmp/missing)\`\n\`\`\`md\n[x](/tmp/missing)\n\`\`\`\n[web](https://example.com/a) [chat](/o/ws/st/chat) [cdn](//example.com/a)`;
  const paths: string[] = [];
  const result = prepare(text, paths, dir);
  assert.equal(paths.length, 1);
  assert.ok(result.startsWith("[报告](<a%20report%281%29%2Etxt>) ![](<a%20report%281%29%2Etxt>) [line](<a%20report%281%29%2Etxt>)"), result);
  assert.ok(result.includes("`[example](/tmp/missing)`\n```md\n[x](/tmp/missing)\n```"));
  assert.ok(result.endsWith("[web](https://example.com/a) [chat](/o/ws/st/chat) [cdn](//example.com/a)"));
  assert.equal(prepare(`[![preview](<${path}>)](<${path}>)`, paths, dir), "[![preview](<a%20report%281%29%2Etxt>)](<a%20report%281%29%2Etxt>)");
  rmSync(dir, { recursive: true, force: true });
});

test("explicit files are reused, and missing or colliding files are refused", () => {
  const dir = temp();
  const file = join(dir, "report.txt");
  writeFileSync(file, "one");
  const paths = ["report.txt"];
  prepare(`[report](${file})`, paths, dir);
  assert.equal(paths.length, 1);
  assert.throws(() => prepare("[missing](/tmp/stillfail-no-such-report.txt)", [], dir), /correct the path/);
  mkdirSync(join(dir, "other"));
  const other = join(dir, "other/report.txt");
  writeFileSync(other, "two");
  assert.throws(() => prepare(`[report](${other})`, paths, dir), /same name/);
  // A reference link to a local file is refused: it must be inline.
  assert.throws(() => prepare(`[report][r]\n\n[r]: ${file}`, [], dir), /must use inline Markdown/);
  rmSync(dir, { recursive: true, force: true });
});

test("files an app cannot upload stay in still.fail, and the post links there", () => {
  const file = (name: string) => ({ name, path: `/w/uploads/${name}`, size: 1 });
  const [posted, kept] = slackWithFiles("这周的天气", [file("weather.html"), file("shot.png")], "https://e/o/w/s/k");
  assert.equal(posted, "这周的天气\n\n<https://e/o/w/s/k?file=weather.html|在 still.fail 里查看图表和附件>", "the link opens the figure");
  assert.equal(kept, "这周的天气\n\n[weather.html](weather.html)", "the HTML placed so still.fail draws it");
  assert.deepEqual(slackWithFiles("看图：[天气](weather.html)", [file("weather.html")], "L"), ["看图：[天气](weather.html)\n\n<L?file=weather.html|在 still.fail 里查看图表>", "看图：[天气](weather.html)"]);
  assert.deepEqual(slackWithFiles("", [file("a b.pdf")], "L"), ["<L?file=a%20b.pdf|在 still.fail 里查看附件>", ""]);
});

test("posts show in the history where the agent made them, whole", () => {
  const dir = temp();
  const path = join(dir, "t.jsonl");
  const long = "长".repeat(5000);
  const record = (content: unknown[]) => `${JSON.stringify({ type: "assistant", timestamp: "2026-10-05T00:00:00Z", message: { content } })}\n`;
  const result = (id: string, text: string) => `${JSON.stringify({ type: "user", timestamp: "2026-10-05T00:00:01Z", message: { content: [{ type: "tool_result", tool_use_id: id, content: text }] } })}\n`;
  writeFileSync(
    path,
    record([{ type: "thinking", thinking: "plan" }, { type: "tool_use", id: "p", name: "mcp__stillfail__chat_post", input: { to: "C1/1.1", text: long, kind: "all_done" } }]) +
      result("p", "Posted to C1/1.1.") +
      record([{ type: "text", text: "after" }]),
  );
  const entries = readTimeline("claude", path);
  assert.deepEqual(entries.map((e) => e.kind), ["thinking", "tool_call", "tool_result", "assistant"]);
  assert.equal(JSON.parse(entries[1]!.text).text, long);
  assert.deepEqual([entries[1]!.callId, entries[2]!.callId, entries[2]!.ok], ["p", "p", true]);
  rmSync(dir, { recursive: true });
});

test("references name sessions in every link form", () => {
  assert.deepEqual(linkedSession("http://127.0.0.1:4760/admin/chats/c-e74a0bfa0b"), ["c-e74a0bfa0b", null]);
  assert.deepEqual(linkedSession("[修 bug](https://ember.3720.org/w/ws1/s/st1/chats/cl%3AC1%3A1.2?x=1)"), ["cl:C1:1.2", null]);
  assert.deepEqual(linkedSession("<https://ember.3720.org/o/ws1/st1/c-abc|在 ember 里查看>"), ["c-abc", null]);
  assert.deepEqual(linkedSession("https://ember.3720.org/w/ws/s/st/chats/c-1?history=c-2&entry=41"), ["c-2", 41]);
  assert.deepEqual(linkedSession("<https://app.still.fail/o/ws1/st1/c-abc|在 still.fail 里查看>"), ["c-abc", null]);
  assert.deepEqual(linkedSession("https://app.still.fail/w/ws1/s/st1/chats/c-2"), ["c-2", null]);
  assert.equal(linkedSession("C1/1.000001"), null);
  assert.equal(linkedSession("c-abc"), null);
});

test("steps are numbered and cut", () => {
  const entry = (kind: string, tool: string | undefined, text: string) => ({ at: "2026-09-29T00:00:00.000Z", kind, text, ...(tool ? { tool } : {}) });
  assert.equal(
    formatSteps(7, [entry("assistant", undefined, "好的"), entry("tool_call", "Bash", "ls -la /tmp")], 4),
    "#7 2026-09-29T00:00:00.000Z assistant:\n好的\n\n#8 2026-09-29T00:00:00.000Z tool_call Bash:\nls -… (7 more characters)",
  );
});

const line = (text: string, id: string) => `${JSON.stringify({ type: "assistant", timestamp: "2026-09-26T00:00:00Z", message: { id, content: [{ type: "text", text }], usage: { input_tokens: 10, output_tokens: 2 } } })}\n`;

/// What a LiveHub's watch on a transcript does when the file changes.
const watched = (hub: LiveHub, key: string) => (hub as any).soon(key);

test("a watcher gets what it lacks, the steps in flight, then new entries as the file grows", async () => {
  const dir = temp();
  const path = join(dir, "t.jsonl");
  writeFileSync(path, line("one", "m1") + line("two", "m2"));
  const time = testClock();
  const hub = new LiveHub(() => ({ runtime: "claude", paths: [path] }), time.clock);
  hub.event("s", { kind: "start", id: "x", step: "text" });
  hub.event("s", { kind: "delta", id: "x", field: "text", text: "wri" });
  const got: LiveMessage[] = [];
  const id = hub.subscribe("s", 1, null, (m) => void got.push(m));
  assert.equal(got[0]!.type, "timeline");
  assert.deepEqual((got[0] as any).entries.map((e: any) => e.text), ["two"]);
  assert.equal((got[0] as any).usage.modelCalls, 2);
  assert.equal(got[1]!.type, "steps");
  assert.equal((got[1] as any).steps[0].step, "text", "what a step is, not what it wrote");
  got.length = 0;
  hub.event("s", { kind: "delta", id: "x", field: "text", text: "ting" });
  assert.equal(got.length, 0, "a delta sends nothing");
  hub.event("s", { kind: "end", id: "x" });
  appendFileSync(path, line("writing", "m3"));
  // What its watch does on the file's change (that it comes is side/hub-parts.test.ts's): read once the burst is over.
  watched(hub, "s");
  await settle();
  await time.adjust(40);
  await settle();
  const timeline = got.filter((m): m is Extract<LiveMessage, { type: "timeline" }> => m.type === "timeline").at(-1)!;
  assert.deepEqual([timeline.start, timeline.entries.map((e) => e.text)], [2, ["writing"]]);
  hub.turnEnded("s");
  assert.ok(got.some((m) => m.type === "clear"));
  hub.unsubscribe("s", id);
  hub.close();
  rmSync(dir, { recursive: true, force: true });
});

test("a watcher can take only the latest entries, and ask for those before", () => {
  const dir = temp();
  const path = join(dir, "t.jsonl");
  writeFileSync(path, line("one", "m1") + line("two", "m2") + line("three", "m3"));
  const hub = new LiveHub(() => ({ runtime: "claude", paths: [path] }));
  const texts = (r: [number, { text: string }[]] | null) => r && [r[0], r[1].map((e) => e.text)];
  // Not watched yet: read for the asking.
  assert.deepEqual(texts(hub.before("s", 2, 1)), [1, ["two"]]);
  const got: LiveMessage[] = [];
  hub.subscribe("s", 0, 1, (m) => void got.push(m));
  assert.deepEqual([(got[0] as any).start, (got[0] as any).entries.map((e: any) => e.text)], [2, ["three"]]);
  // Watched: from what is held.
  assert.deepEqual(texts(hub.before("s", 2, 5)), [0, ["one", "two"]]);
  assert.deepEqual(texts(hub.before("s", 0, 5)), [0, []]);
  hub.close();
  rmSync(dir, { recursive: true, force: true });
});

test("a session gone on in a new runtime session: its history reads on from the transcript it left into the new one", async () => {
  const dir = temp();
  const left = join(dir, "a.jsonl");
  const now = join(dir, "b.jsonl");
  writeFileSync(left, line("one", "m1"));
  let paths = [left];
  const time = testClock();
  let current = true;
  const hub = new LiveHub(() => ({ runtime: "claude", paths, current }), time.clock);
  const got: LiveMessage[] = [];
  hub.subscribe("s", 0, null, (m) => void got.push(m));
  // The one left gets its last words, then the session moves on: its new transcript is written only once the
  // conversation begins, after it moved.
  appendFileSync(left, line("two", "m2"));
  current = false;
  hub.moved("s");
  writeFileSync(now, line("three", "m3"));
  paths = [left, now];
  current = true;
  watched(hub, "s");
  await settle();
  await time.adjust(40);
  await settle();
  appendFileSync(now, line("four", "m4"));
  watched(hub, "s");
  await settle();
  await time.adjust(40);
  await settle();
  const told = () => got.flatMap((m) => (m.type === "timeline" ? m.entries.map((e, i) => `${m.start + i}:${e.text}`) : []));
  assert.deepEqual(told(), ["0:one", "1:two", "2:three", "3:four"]);
  const last = got.filter((m): m is Extract<LiveMessage, { type: "timeline" }> => m.type === "timeline").at(-1)!;
  assert.equal(last.usage.modelCalls, 4, "the usage of both");
  assert.deepEqual(hub.before("s", 10, 10)![1].map((e) => e.text), ["one", "two", "three", "four"]);
  hub.close();
  rmSync(dir, { recursive: true, force: true });
});

test("a session's transcripts are found in the home of whichever account wrote them, the current one's once written", () => {
  const dir = temp();
  const [a, b] = [join(dir, "a"), join(dir, "b")];
  mkdirSync(join(a, "projects", "w"), { recursive: true });
  mkdirSync(join(b, "projects", "w"), { recursive: true });
  writeFileSync(join(a, "projects", "w", "one.jsonl"), line("one", "m1"));
  writeFileSync(join(b, "projects", "w", "two.jsonl"), line("two", "m2"));
  assert.deepEqual(transcriptPaths("claude", [b, a], ["one", "two", "three"]), { paths: [join(a, "projects", "w", "one.jsonl"), join(b, "projects", "w", "two.jsonl")], current: false });
  writeFileSync(join(b, "projects", "w", "three.jsonl"), line("three", "m3"));
  assert.equal(transcriptPaths("claude", [b, a], ["one", "two", "three"]).current, true);
  rmSync(dir, { recursive: true, force: true });
});

test("how fast the model writes is told once half a second of it has come", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: 1_000_000 });
  const hub = new LiveHub(() => null);
  const got: LiveMessage[] = [];
  hub.subscribe("s", 0, null, (m) => void got.push(m));
  hub.event("s", { kind: "start", id: "x", step: "text" });
  hub.event("s", { kind: "delta", id: "x", field: "text", text: "x".repeat(400) });
  const rates = () => got.flatMap((m) => (m.type === "rate" ? [m.tokensPerSecond] : []));
  assert.deepEqual(rates(), [], "a first few bytes say nothing of the pace");
  t.mock.timers.tick(600);
  hub.event("s", { kind: "delta", id: "x", field: "text", text: "x".repeat(400) });
  hub.event("s", { kind: "delta", id: "x", field: "text", text: "x".repeat(400) });
  assert.equal(rates().length, 1, "then told, and not again within the second");
  assert.ok(rates()[0]! > 0);
  hub.event("s", { kind: "end", id: "x" });
  assert.equal(rates().at(-1), 0);
  assert.ok(!got.some((m) => m.type === "step" && m.event.kind === "delta"), "no delta is told");
  hub.close();
  await settle(1);
});

test("profile homes link to the shared memory and skills under their runtimes' names; a hand-written file is left", () => {
  const root = temp();
  const agent = join(root, "agent");
  const [cc, cx, both] = [join(root, "cc"), join(root, "cx"), join(root, "both")];
  const profiles = [
    { id: "cc", runtimes: ["claude" as const], home: cc },
    { id: "cx", runtimes: ["codex" as const], home: cx },
    { id: "both", runtimes: ["claude" as const, "codex" as const], home: both },
  ];
  linkAgentHome(agent, profiles);
  linkAgentHome(agent, profiles); // idempotent
  assert.equal(readlinkSync(join(cc, "CLAUDE.md")), join(agent, "MEMORY.md"));
  assert.equal(readlinkSync(join(cc, "skills")), join(agent, "skills"));
  assert.equal(readlinkSync(join(cx, "AGENTS.md")), join(agent, "MEMORY.md"));
  assert.equal(readlinkSync(join(both, "CLAUDE.md")), join(agent, "MEMORY.md"));
  assert.equal(readlinkSync(join(both, "AGENTS.md")), join(agent, "MEMORY.md"));
  const own = join(root, "own");
  mkdirSync(own);
  writeFileSync(join(own, "CLAUDE.md"), "mine");
  linkAgentHome(join(root, "agent2"), [{ id: "own", runtimes: ["claude"], home: own }]);
  assert.equal(readFileSync(join(own, "CLAUDE.md"), "utf8"), "mine");
  rmSync(root, { recursive: true, force: true });
});

test("every profile's transcripts are a runtime's one shared place", () => {
  const root = temp();
  const [both, own] = [join(root, "both"), join(root, "own")];
  mkdirSync(join(own, "sessions"), { recursive: true });
  linkTranscripts(root, [
    { id: "both", runtimes: ["claude", "codex"], home: both },
    { id: "own", runtimes: ["codex"], home: own },
  ]);
  assert.equal(readlinkSync(join(both, "projects")), join(root, "transcripts/claude"));
  assert.equal(readlinkSync(join(both, "sessions")), join(root, "transcripts/codex"));
  assert.ok(lstatSync(join(own, "sessions")).isDirectory());
  rmSync(root, { recursive: true, force: true });
});

test("the station's own skills are written and kept as the station has them; the feedback skill on the stable channel only", () => {
  const root = temp();
  const home = join(root, "agent");
  mkdirSync(join(home, "skills", "team-skill"), { recursive: true });
  writeFileSync(join(home, "skills", "team-skill", "SKILL.md"), "ours");
  writeBuiltinSkills(home, false);
  // The same skills as the station wrote them before the rename: replaced; one someone added to is left.
  for (const name of ["ember-jobs", "ember-viz"]) {
    mkdirSync(join(home, "skills", name), { recursive: true });
    writeFileSync(join(home, "skills", name, "SKILL.md"), `---\nname: ${name}\n---\n`);
  }
  writeFileSync(join(home, "skills", "ember-viz", "notes.md"), "mine");
  writeBuiltinSkills(home, false);
  assert.ok(!existsSync(join(home, "skills", "ember-jobs")));
  assert.ok(existsSync(join(home, "skills", "ember-viz", "notes.md")));
  const path = join(home, "skills", "stillfail-jobs", "SKILL.md");
  assert.ok(readFileSync(path, "utf8").startsWith("---\nname: stillfail-jobs\n"));
  assert.equal(readFileSync(path, "utf8"), readFileSync(new URL("../src/skills/stillfail-jobs.md", import.meta.url), "utf8"), "the station's text");
  writeFileSync(path, "edited by hand");
  writeBuiltinSkills(home, false);
  assert.ok(readFileSync(path, "utf8").includes("job_start"), "the station's own, as it has it");
  assert.equal(readFileSync(join(home, "skills", "team-skill", "SKILL.md"), "utf8"), "ours", "the team's stay");
  const feedback = join(home, "skills", "stillfail-feedback", "SKILL.md");
  writeBuiltinSkills(home, true);
  assert.ok(readFileSync(feedback, "utf8").includes("feedback_send"));
  writeBuiltinSkills(home, false);
  assert.ok(!existsSync(join(home, "skills", "stillfail-feedback")));
  writeBuiltinSkills(home, true);
  writeFileSync(join(home, "skills", "stillfail-feedback", "notes.md"), "mine");
  writeBuiltinSkills(home, false);
  assert.ok(existsSync(join(home, "skills", "stillfail-feedback", "notes.md")));
  rmSync(root, { recursive: true, force: true });
});

const profile = (id: string, models: string[]) => hubConfig({ profiles: [{ id, runtime: "claude", home: `/h/${id}`, models }] }, "/").profiles[0]!;
const ok = (state: string) => ({ state, detail: "", models: null, checkedAt: 0 });
const quota = (used: number) => ({ state: "ok", windows: [{ label: "5 小时", usedPercent: used, resetsAt: null }], detail: null, checkedAt: 0 });

test("the pool skips broken, spent and unfit profiles, then prefers headroom, then fewer sessions", () => {
  const [a, b, c, d] = [profile("a", ["m1"]), profile("b", ["m1"]), profile("c", ["m1", "m2"]), profile("d", ["m2"])];
  const health: Record<string, any> = { a: { check: ok("failed"), quota: quota(0) }, b: { check: ok("ok"), quota: quota(100) }, c: { check: ok("ok"), quota: quota(60) }, d: { check: ok("ok"), quota: quota(20) } };
  const signals = (load: Record<string, number> = {}, picked: Record<string, number> = {}) => ({ health: (id: string) => health[id], load: (id: string) => load[id] ?? 0, lastPicked: (id: string) => picked[id] ?? 0, now: () => 0 });
  const all = [a, b, c, d];
  assert.equal(pickProfile(all, "m1", signals(), true).id, "c", "a failed, b spent, d lacks m1");
  assert.equal(pickProfile(all, "m2", signals(), true).id, "d", "most headroom");
  assert.equal(pickProfile(all, null, signals(), true).id, "d");
  health.c = { check: ok("ok"), quota: quota(20) };
  assert.equal(pickProfile([c, d], null, signals({ d: 2, c: 1 }), true).id, "c", "fewer sessions");
  assert.equal(pickProfile([c, d], null, signals({}, { c: 5, d: 1 }), true).id, "d", "least recently picked");
  assert.equal(pickProfile([a], "m1", signals(), true).id, "a", "nothing healthy: still one, so the failure shows");
  assert.throws(() => pickProfile([a, b], "m2", signals(), true), /no profile has m2 enabled/);
  assert.equal(pickProfile([a, c], "m9", signals(), false).id, "c", "a connect's binding still runs on its healthy profiles");
});

test("the pool spends first what would be lost: a week refilling within a day, then the fastest to spend", () => {
  const now = 1_791_270_331_000;
  const hours = (h: number) => now + h * 3_600_000;
  const windows = (five: [number, number], week: [number, number]) => ({
    state: "ok",
    windows: [
      { label: "5 小时", usedPercent: five[0], resetsAt: hours(five[1]), minutes: 300 },
      { label: "每周", usedPercent: week[0], resetsAt: hours(week[1]), minutes: 7 * 24 * 60 },
    ],
    detail: null,
    checkedAt: 0,
  });
  // As the station's accounts were on 2026-10-06: cuesurf3 and cuesurf4 tied on their tightest window (2%), so they
  // took turns, though cuesurf4's week, nearly all left, refilled within a day.
  const health: Record<string, any> = {
    machine: { check: ok("ok"), quota: windows([48, 1.1], [38, 100.9]) },
    s2: { check: ok("ok"), quota: windows([17, 1.1], [41, 127.9]) },
    s3: { check: ok("ok"), quota: windows([2, 1.7], [0, 39.6]) },
    s4: { check: ok("ok"), quota: windows([2, 2.4], [1, 22.9]) },
  };
  const all = ["machine", "s2", "s3", "s4"].map((id) => profile(id, ["m"]));
  const signals = (load: Record<string, number> = {}, picked: Record<string, number> = {}) => ({ health: (id: string) => health[id], load: (id: string) => load[id] ?? 0, lastPicked: (id: string) => picked[id] ?? 0, now: () => now });
  const order = (s = signals()) => {
    const left = [...all];
    const out: string[] = [];
    while (left.length > 0) {
      const p = pickProfile(left, "m", s, true);
      out.push(p.id);
      left.splice(left.indexOf(p), 1);
    }
    return out;
  };
  assert.deepEqual(order(), ["s4", "s3", "machine", "s2"], "s4's week refills within a day; then left × length ÷ time to refill");
  assert.equal(pickProfile(all, "m", signals({ s4: 3 }, { s4: now }), true).id, "s4", "more sessions or picked last does not take it off");
  const s4 = urgency(health.s4.quota, now);
  assert.deepEqual([s4.crowded, s4.soon], [false, true]);
  assert.ok(Math.abs(s4.pace - (0.99 * 168) / 22.9) < 1e-9, "left × length ÷ time to refill");
  // The soon one is preferred even over a faster pace: what is left of it is lost tomorrow.
  health.s3 = { check: ok("ok"), quota: windows([2, 1.7], [0, 25]) };
  health.s4 = { check: ok("ok"), quota: windows([2, 2.4], [90, 20]) };
  assert.ok(urgency(health.s3.quota, now).pace > urgency(health.s4.quota, now).pace);
  assert.equal(pickProfile(all, "m", signals(), true).id, "s4");
  // Nearly full five hours: last, whatever its week.
  health.s4 = { check: ok("ok"), quota: windows([85, 2.4], [1, 22.9]) };
  assert.deepEqual(order(), ["s3", "machine", "s2", "s4"]);
  // Used up this week, refilling soon: nothing left to lose, so not soon.
  health.s4 = { check: ok("ok"), quota: windows([2, 2.4], [100, 22.9]) };
  assert.equal(urgency(health.s4.quota, now).soon, false);
  // Equal allowances: fewer sessions, then the one picked least recently.
  for (const id of ["s3", "s4"]) health[id] = { check: ok("ok"), quota: windows([2, 2], [0, 30]) };
  assert.equal(pickProfile([all[2]!, all[3]!], "m", signals({ s3: 1 }), true).id, "s4");
  assert.equal(pickProfile([all[2]!, all[3]!], "m", signals({}, { s3: 1, s4: 2 }), true).id, "s3");
});

test("a model is served however a profile spells it", () => {
  const [direct, router] = [profile("direct", ["gpt-6-astra"]), profile("router", ["openai/gpt-6-astra"])];
  const health: Record<string, any> = { direct: { check: ok("ok"), quota: quota(100) }, router: { check: ok("ok"), quota: quota(10) } };
  const picked = pickProfile([direct, router], "gpt-6-astra", { health: (id) => health[id], load: () => 0, lastPicked: () => 0, now: () => 0 }, true);
  assert.equal(picked.id, "router", "the direct account is spent; the router's spelling is the same model");
  assert.equal(spelling(picked, "gpt-6-astra"), "openai/gpt-6-astra", "and it runs as the router spells it");
  assert.equal(spelling(direct, "openai/gpt-6-astra"), "gpt-6-astra");
  assert.ok(!serves(direct, "gpt-6"));
});

test("reported levels, aliases, empty and legacy", () => {
  const catalog = { codex: { "gpt-6-astra": ["low", "medium", "high", "xhigh", "max", "ultra"], "gpt-6-luna": ["low", "medium", "high", "xhigh", "max"], "no-reasoning": [] } };
  const astra = availableEfforts("codex", "openai/gpt-6-astra", catalog);
  assert.ok(astra.includes("max") && astra.includes("ultra") && !astra.includes("minimal"));
  assert.deepEqual(availableEfforts("codex", "no-reasoning", catalog), []);
  assert.deepEqual(availableEfforts("codex", "unknown", catalog), ["minimal", "low", "medium", "high", "xhigh"]);
  assert.deepEqual(availableEfforts("claude", "gpt-6-astra", catalog), ["low", "medium", "high", "xhigh", "max"]);
  assert.ok(!commonEfforts([astra, availableEfforts("codex", "gpt-6-luna", catalog)], "codex").includes("ultra"));
});

const config = (provider: "jev" | "chat_logprobs") => ({ provider, endpoint: "http://127.0.0.1:1", model: "test", apiKey: "", sessionHeader: false, threshold: 0.85 });

test("native choices are strict, and uncertainty is not completion", () => {
  const c = config("jev");
  const q = completionQuestion();
  const raw: any = { answers: { decision: { type: "choice", probabilities: { complete: 0.9, agent_work: 0.04, human_needed: 0.04, uncertain: 0.02 } } } };
  const accepts = () => {
    const r = parse(c, q, raw);
    return r.selected === "complete" && r.probabilities.complete! >= c.threshold;
  };
  assert.ok(accepts());
  raw.answers.decision.probabilities.complete = 0.6;
  raw.answers.decision.probabilities.uncertain = 0.32;
  assert.ok(!accepts());
  raw.answers.decision.probabilities.complete = -0.1;
  assert.throws(() => parse(c, q, raw));
});

test("incomplete top logprobs never become a confident answer", () => {
  const c = config("chat_logprobs");
  const q = completionQuestion();
  const tokens: any[] = [["A", 0.02], ["B", 0.9], ["C", 0.04], ["D", 0.03]].map(([token, p]) => ({ token, logprob: Math.log(p as number) }));
  const raw = (ts: any[]) => ({ choices: [{ logprobs: { content: [{ top_logprobs: ts }] } }] });
  // Criteria in their names' order (a BTreeMap's): agent_work A, complete B, human_needed C, uncertain D.
  const r = parse(c, q, raw(tokens));
  assert.equal(r.selected, "complete");
  // A choice too unlikely to be among the top tokens counts as none, while the rest hold nearly all of it.
  tokens.pop();
  assert.equal(parse(c, q, raw(tokens)).probabilities.uncertain, 0);
  tokens.shift();
  tokens.shift();
  assert.throws(() => parse(c, q, raw(tokens)), /mass/);
  tokens.unshift({ token: "A", logprob: Math.log(0.02) });
  tokens.push({ token: "D", logprob: -2.0 });
  assert.throws(() => parse(c, q, raw(tokens)));
});

test("requests disable reasoning and keep evidence out of the system prompt", () => {
  const r = request(config("chat_logprobs"), completionQuestion(), { text: "untrusted sample" });
  assert.equal(r.reasoning_effort, "none");
  assert.equal(r.max_completion_tokens, 1);
  assert.ok(!r.messages[0].content.includes("untrusted sample"));
  assert.ok(r.messages[1].content.includes("untrusted sample"));
});
