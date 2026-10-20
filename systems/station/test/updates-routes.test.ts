// POST /updates…, as admin/mod.rs answers them (admin/tests.rs), and `stillfail-station channel` asking a running
// station (the Rust station's main.rs's tests). Temporary data directories, a cloud that answers nothing.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { Request } from "../src/api/request.ts";
import { routes } from "../src/api/routes/updates.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { channelCommand, setChannel } from "../src/updates/channel.ts";
import { CHANNEL_ANSWER, CHANNEL_ASK, Updates, answerChannelAsk } from "../src/updates/updates.ts";
import type { Channel } from "../src/updates/versions.ts";

delete process.env.STILLFAIL_CONFIG;
delete process.env.EMBER_CONFIG;

const temp = () => realpathSync(mkdtempSync(join(tmpdir(), "stillfail-updates-")));

function installed(data: string, channel: string | null): Updates {
  const app = join(data, "app");
  mkdirSync(app, { recursive: true });
  writeFileSync(join(app, "BUILD"), "1300");
  if (channel !== null) writeFileSync(join(app, "CHANNEL"), channel);
  return new Updates({ app, data, config: new ConfigFile(data), origin: () => "http://127.0.0.1:1", registry: "http://127.0.0.1:1", env: { PATH: "/nowhere" } });
}

function rig(updates: Updates | null) {
  const table = routes({ updates });
  return async (method: string, path: string, body?: unknown, role = "owner") => {
    const r: Request = {
      method, path, query: [], headers: {}, lang: "zh",
      body: Buffer.from(body === undefined ? "" : typeof body === "string" ? body : JSON.stringify(body)),
      viewer: { sub: "s", email: "m@x.com", name: "M", role, workspace: "ws", device: "d" },
    };
    for (const route of table) {
      const found = route.method === method ? route.pattern.exec(path) : null;
      if (found) {
        const a = await route.handle(r, found.slice(1));
        return [a.status, JSON.parse(String(a.body))] as const;
      }
    }
    return [404, { error: `no route ${method} ${path}` }] as const;
  };
}

const stationOf = (lines: any) => (lines as any[]).find((v) => v.id === "station");

test("the update channel is said with the versions and set by an admin", async (t) => {
  const dir = temp();
  const updates = installed(dir, "beta");
  t.after(() => updates.close());
  const ask = rig(updates);
  const [status, lines] = await ask("POST", "/updates/check");
  assert.equal(status, 200);
  assert.equal(stationOf(lines).channel, "beta", "installed from the beta, on it");
  assert.deepEqual(lines.map((l: any) => l.id), ["station", "claude", "codex"]);
  assert.equal(stationOf(lines).idleOnly, true);
  assert.equal(typeof stationOf(lines).checkedAt, "number");

  // A member may not; nor a channel that is not one.
  assert.deepEqual(await ask("POST", "/updates/channel", { channel: "stable" }, "member"), [403, { error: "只有 workspace 的 owner 或管理员能更新 station 和它的运行时" }]);
  assert.deepEqual(await ask("POST", "/updates/channel", { channel: "nightly" }, "admin"), [400, { error: "channel 必须是 stable 或 beta" }]);
  assert.deepEqual(await ask("POST", "/updates/channel", "{", "admin"), [400, { error: "invalid JSON" }]);

  const [ok, after] = await ask("POST", "/updates/channel", { channel: "stable" }, "admin");
  assert.equal(ok, 200);
  assert.equal(stationOf(after).channel, "stable");
  assert.equal(new ConfigFile(dir).raw().updateChannel, "stable");
  assert.equal(stationOf(updates.get()).channel, "stable");
});

test("updating by itself is said with the versions, on by default, and turned off or on by an admin", async (t) => {
  const dir = temp();
  const updates = installed(dir, null);
  t.after(() => updates.close());
  const ask = rig(updates);
  await ask("POST", "/updates/check");
  assert.equal(stationOf(updates.get()).auto, true, "on unless turned off");
  assert.equal((await ask("POST", "/updates/auto", { on: false }, "member"))[0], 403);
  assert.deepEqual(await ask("POST", "/updates/auto", { on: "yes" }, "admin"), [400, { error: "on 必须是 true 或 false" }]);
  const [, off] = await ask("POST", "/updates/auto", { on: false }, "admin");
  assert.equal(stationOf(off).auto, false);
  assert.equal(new ConfigFile(dir).raw().autoUpdate, false);
  assert.equal(stationOf(updates.get()).auto, false);
  const [status, lines] = await ask("POST", "/updates/auto", { on: true }, "admin");
  assert.equal(status, 200);
  assert.equal(stationOf(lines).auto, true);
  assert.equal(new ConfigFile(dir).raw().autoUpdate, true);
});

test("an update asked for is refused with what is wrong", async (t) => {
  const updates = installed(temp(), null);
  t.after(() => updates.close());
  const ask = rig(updates);
  await ask("POST", "/updates/check");
  assert.deepEqual(await ask("POST", "/updates", { id: "nope" }), [400, { error: "没有 nope 这一项" }]);
  assert.deepEqual(await ask("POST", "/updates", {}), [400, { error: "没有  这一项" }]);
  // Codex is not there and there is neither npm nor Homebrew to install it with.
  assert.deepEqual(await ask("POST", "/updates", { id: "codex" }), [400, { error: "Codex：这台机器上没有 npm 也没有 Homebrew：先装 Node（带 npm），再回来安装 Codex" }]);
});

test("a station with nothing to update has no channel to set", async () => {
  const ask = rig(null);
  assert.deepEqual(await ask("POST", "/updates/channel", { channel: "beta" }), [404, { error: "这台 station 不能在这里更新" }]);
  // Managers only, before that.
  assert.equal((await ask("POST", "/updates/check", undefined, "member"))[0], 403);
});

test("with no station running the channel is written in the config", async () => {
  const dir = temp();
  await setChannel(dir, "beta", 1000, () => assert.fail("no station to ask"));
  assert.equal(new ConfigFile(dir).raw().updateChannel, "beta");
  // Beside a station from before it took the ask: written too (the update that follows restarts it).
  mkdirSync(join(dir, "run"), { recursive: true });
  writeFileSync(join(dir, "run", "station.json"), JSON.stringify({ pid: process.pid, drain: 1 }));
  await setChannel(dir, "stable", 1000, () => true);
  assert.equal(new ConfigFile(dir).raw().updateChannel, "stable");
  // A broken config is not written over.
  writeFileSync(join(dir, "config.json"), "{ broken");
  await assert.rejects(setChannel(dir, "beta", 1000, () => true));
  assert.equal(readFileSync(join(dir, "config.json"), "utf8"), "{ broken");
});

// No SIGHUP on Windows: the config is written there (the test before), which a running station reads afresh.
test("a running station is asked for the channel and keeps it itself", { skip: process.platform === "win32" && "no signals on Windows" }, async () => {
  const dir = temp();
  const runDir = join(dir, "run");
  mkdirSync(runDir, { recursive: true });
  // This process plays the station: its file saying it takes the ask, SIGHUP taken (the launcher's `hup`).
  writeFileSync(join(runDir, "station.json"), JSON.stringify({ pid: process.pid, drain: 1, channel: 1 }));
  const asked: Channel[] = [];
  const hup = () =>
    answerChannelAsk(runDir, (channel) => {
      asked.push(channel);
      if (channel === "stable") throw new Error("不行");
    });
  process.on("SIGHUP", hup);
  try {
    await setChannel(dir, "beta", 5000, () => true);
    assert.deepEqual(asked, ["beta"]);
    assert.ok(!existsSync(join(dir, "config.json")), "the running station keeps it, not this");
    assert.ok(!existsSync(join(runDir, CHANNEL_ASK)) && !existsSync(join(runDir, CHANNEL_ANSWER)));
    // What the station says when it cannot.
    await assert.rejects(setChannel(dir, "stable", 5000, () => true), (e: Error) => e.message === "不行");
  } finally {
    process.off("SIGHUP", hup);
  }
});

test("the running station takes the ask: kept in its config and read on that channel", async (t) => {
  const dir = temp();
  const updates = installed(dir, null);
  t.after(() => updates.close());
  const runDir = join(dir, "run");
  mkdirSync(runDir, { recursive: true });
  writeFileSync(join(runDir, CHANNEL_ASK), "beta");
  updates.answerChannelAsk();
  assert.equal(readFileSync(join(runDir, CHANNEL_ANSWER), "utf8"), "ok beta\n");
  assert.equal(updates.channel(), "beta");
  writeFileSync(join(runDir, CHANNEL_ASK), "nightly");
  updates.answerChannelAsk();
  assert.equal(readFileSync(join(runDir, CHANNEL_ANSWER), "utf8"), "error 不认识的渠道 nightly\n");
});

test("the channel command says the channel, set first when named", async () => {
  const dir = temp();
  const app = join(dir, "app");
  mkdirSync(app, { recursive: true });
  writeFileSync(join(app, "CHANNEL"), "beta\n");
  const said: string[] = [];
  const log = console.log;
  const error = console.error;
  console.log = (s: string) => void said.push(String(s));
  console.error = (s: string) => void said.push(`! ${s}`);
  try {
    assert.equal(await channelCommand(["channel", "--app", app, "--data", dir], dir), 0);
    assert.equal(await channelCommand(["channel", "stable", "--app", app, "--data", dir], dir), 0);
    assert.equal(await channelCommand(["channel", "nightly", "--app", app, "--data", dir], dir), 1);
    assert.equal(await channelCommand(["channel", "a", "b", "--data", dir], dir), 2);
  } finally {
    console.log = log;
    console.error = error;
  }
  assert.deepEqual(said, ["beta", "stable", "! Error: channel 必须是 stable 或 beta，不是 nightly"]);
  assert.equal(new ConfigFile(dir).raw().updateChannel, "stable");
});
