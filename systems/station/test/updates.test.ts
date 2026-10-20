// The station's and its runtimes' versions and updating them (the Rust station's updates.rs's tests), with fake release
// servers, fake installers and fake npm/vp/curl commands in temporary directories: nothing real is installed or read.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { describe, test } from "node:test";
import { ConfigFile } from "../src/ops/config.ts";
import { type Env, type Found, howToInstall, howToUpdate, findCommand, pinNpmVersion, run, runLines, Unable, kindCommand, kindPackage } from "../src/updates/runtimes.ts";
import { Updates, type UpdatesOptions } from "../src/updates/updates.ts";
import { WINDOWS } from "../src/platform/index.ts";
import { windowsUpdateScript } from "../src/platform/windows.ts";
import {
  channelOf, curlPercent, downloading, feed, INSTALLING, newer, offer, releaseChannel, say, stationDownloadPercent, stationVersion, stepOf, versionIn,
} from "../src/updates/versions.ts";
import { setChannelIn } from "../src/updates/channel.ts";
import { exe, launcher, script as stand_in } from "./accounts-fakes.ts";
import { settle, testClock } from "./hub-fakes.ts";

delete process.env.STILLFAIL_CONFIG;
delete process.env.EMBER_CONFIG;

const temp = () => realpathSync(mkdtempSync(join(tmpdir(), "stillfail-updates-")));
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
/// Looks every 20 ms until `f` holds: what real processes, files and sockets do has no event here. No deadline (it
/// comes, however slow the machine, or the test hangs).
async function until(_what: string, f: () => boolean) {
  while (!f()) await sleep(20);
}
/// An executable script at `path` (a shell one by the launcher the stand-ins share: see accounts-fakes.ts).
const script = (path: string, text: string) => {
  mkdirSync(dirname(path), { recursive: true });
  stand_in(path, text);
};

/// A station installed by the installer (<data>/app, BUILD `build`, from `channel`), in a cloud that answers nothing.
function installed(data: string, build: string, channel: string | null, more: Partial<UpdatesOptions> = {}): Updates {
  const app = join(data, "app");
  mkdirSync(app, { recursive: true });
  writeFileSync(join(app, "BUILD"), build);
  if (channel !== null) writeFileSync(join(app, "CHANNEL"), channel);
  const updates = new Updates({
    app, data, config: new ConfigFile(data), origin: () => "http://127.0.0.1:1", registry: "http://127.0.0.1:1", env: { PATH: "/nowhere" },
    timing: { followLook: 200 }, ...more,
  });
  return updates;
}

const station = (u: Updates) => u.get("zh")[0]!;

/// A PATH of `bin` and the system's commands.
const withSystem = (bin: string) => (WINDOWS ? `${bin};${process.env.SystemRoot ?? "C:\\Windows"}\\System32` : `${bin}:/usr/bin:/bin`);

/// A server answering `routes` (path → status and body, or a function of the request's path and query).
type Said = { status?: number; type?: string; body: string | Buffer } | null;
async function serve(routes: (path: string, search: string) => Said | Promise<Said>): Promise<[string, Server]> {
  const server = createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://x");
    const said = await routes(url.pathname, url.search);
    if (said === null) return void res.writeHead(404).end("no");
    const body = typeof said.body === "string" ? Buffer.from(said.body) : said.body;
    res.writeHead(said.status ?? 200, { "content-type": said.type ?? "application/json", "content-length": body.length }).end(body);
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  return [`http://127.0.0.1:${(server.address() as AddressInfo).port}`, server];
}

/// A still.fail cloud with a release out (`latest` on the stable feed) and an installer that plays the real one's part
/// on a temporary data directory: says its steps, puts the new BUILD in the release, ends 0. Its download goes on until
/// `finish` is called (asking the cloud for /download, which answers then); unless `held`, it goes on at once.
async function cloudWithRelease(latest: string, build: string, held = false): Promise<[string, Server, string[], () => void]> {
  const asked: string[] = [];
  let finish = () => {};
  const finished = held ? new Promise<void>((r) => (finish = r)) : Promise.resolve();
  let origin = "";
  const installer = () => `#!/bin/sh
set -eu
run="$STILLFAIL_DATA/run"
printf 'download\\n' > "$run/update.step"
echo "### 50.0%"
printf '%s %s %s\\n' "$STILLFAIL_CHANNEL" "$EMBER_DATA" "$STILLFAIL_DATA" > "$STILLFAIL_DATA/installer-saw"
curl -fsS "${origin}/download" > /dev/null
printf 'handoff\\n' > "$run/update.step"
printf '${build}\\n' > "$STILLFAIL_DATA/app/BUILD"
`;
  const [base, server] = await serve(async (path, search) => {
    asked.push(path + search);
    if (path === "/releases/station.json") return { body: JSON.stringify({ version: latest }) };
    if (path === "/install.sh") return { type: "text/plain", body: installer() };
    if (path === "/download") return finished.then(() => ({ type: "text/plain", body: "" }));
    return null;
  });
  origin = base;
  return [origin, server, asked, finish];
}

/// A registry with Codex 0.47.0 out, its build for this machine downloadable; and a bin with a fake npm that records
/// what it is asked and, asked to install, puts a `codex` saying `version` beside itself (none: it installs nothing).
async function codexWorld(version: string | null): Promise<[string, Server, string, string]> {
  const tarball = Buffer.alloc(300_000, 1);
  let base = "";
  const [registry, server] = await serve((path) => {
    if (path === "/@openai/codex/latest") return { body: JSON.stringify({ version: "0.47.0" }) };
    if (path.startsWith("/@openai/codex/0.47.0-")) return { body: JSON.stringify({ dist: { tarball: `${base}/codex.tgz` } }) };
    if (path === "/codex.tgz") return { type: "application/octet-stream", body: tarball };
    if (path === "/@anthropic-ai/claude-code/latest") return { body: JSON.stringify({ version: "2.1.300" }) };
    return null;
  });
  base = registry;
  const bin = join(temp(), "bin");
  const said = join(dirname(bin), "npm-asked");
  // On Windows what is installed is a .cmd (as npm's shims are), written by Git's sh: its paths with /.
  const [b, s] = [bin, said].map((p) => p.replaceAll("\\", "/"));
  const codex = WINDOWS ? `printf '@echo codex-cli ${version}\\r\\n' > "${b}/codex.cmd"` : `printf '#!/bin/sh\\necho "codex-cli ${version}"\\n' > "${b}/codex.sh"; /bin/ln "${launcher()}" "${b}/codex"`;
  script(join(bin, "npm"), `#!/bin/sh
echo "$*" >> "${s}"
if [ "$1" = install ]; then
  echo "==> Downloading codex"
  ${version === null ? ":" : codex}
  echo "added 1 package"
fi
exit 0
`);
  return [registry, server, bin, said];
}

const found = (real: string): Found => ({ onPath: "/nowhere/bin/x", real });

describe("updates", { concurrency: true }, () => {
  test("an install says where it is as it goes", async () => {
    const env: Env = { PATH: "/usr/bin:/bin" };
    const steps: string[] = [];
    const program = "console.log('==> Downloading https://x'); console.log('==> Pouring codex'); console.error('Warning: x'); process.exitCode = 3";
    const [ok, said] = await runLines(process.execPath, ["-e", program], env, 10_000, (line) => {
      const s = stepOf(line);
      if (s) steps.push(say(s, "zh"));
    });
    assert.equal(ok, false);
    assert.deepEqual(steps, ["正在下载…", say(INSTALLING, "zh")]);
    // Both streams kept (their order between them is not known).
    assert.ok(said.includes("==> Pouring codex") && said.includes("Warning: x"));
    assert.deepEqual(stepOf("Setting up Claude Code..."), INSTALLING);
    assert.equal(stepOf("added 2 packages in 4s"), null);
    const [a, p] = downloading("0.159.3", 60_000_000, 133_847_481);
    assert.deepEqual([say(a, "zh"), p], ["正在下载 0.159.3（134 MB）", 44]);
    const [b, q] = downloading("0.159.3", 60_000_000, null);
    assert.deepEqual([say(b, "zh"), q], ["正在下载 0.159.3：已下 60 MB", null]);
  });

  test("versions compare number by number", () => {
    assert.ok(newer("2.1.9", "2.1.10"));
    assert.ok(!newer("2.1.10", "2.1.9"));
    assert.ok(!newer("0.1.1200", "0.1.1200"));
    assert.ok(newer("0.46.0", "0.47.0-alpha.1"));
  });

  test("a version is read from what the command says", () => {
    assert.equal(versionIn("2.1.284 (Claude Code)"), "2.1.284");
    assert.equal(versionIn("codex-cli 0.46.0\n"), "0.46.0");
    assert.equal(versionIn("nothing here"), null);
  });

  test("a release says its version and a clone none", () => {
    const dir = temp();
    assert.equal(stationVersion(dir), undefined);
    writeFileSync(join(dir, "BUILD"), "1234\n");
    assert.equal(stationVersion(dir), "0.1.1234");
  });

  test("the latest comes from the channel's feed and a station is on the channel it was installed from", () => {
    assert.equal(feed("stable", "https://app.still.fail"), "https://app.still.fail/releases/station.json");
    assert.equal(feed("beta", "https://app.still.fail"), "https://app.still.fail/releases/station-beta.json");
    const dir = temp();
    // An install from before channels, and a config that says none: stable.
    assert.equal(releaseChannel(dir), null);
    assert.equal(channelOf({}, dir), "stable");
    assert.equal(channelOf({ updateChannel: "nonsense" }, dir), "stable");
    // Installed from the beta: on it, until the config says otherwise.
    writeFileSync(join(dir, "CHANNEL"), "beta\n");
    assert.equal(channelOf({}, dir), "beta");
    assert.equal(channelOf({ updateChannel: "stable" }, dir), "stable");
    assert.equal(channelOf({ updateChannel: "beta" }, dir), "beta");
  });

  test("an older version is offered only back from the beta", () => {
    // Newer is newer on either channel.
    assert.deepEqual(offer("0.1.10", "0.1.12", "stable", "stable"), [true, false]);
    assert.deepEqual(offer("0.1.10", "0.1.12", "beta", "stable"), [true, false]);
    // A stable station never goes back by itself, nor a beta one to an older beta.
    assert.deepEqual(offer("0.1.12", "0.1.10", "stable", "stable"), [false, false]);
    assert.deepEqual(offer("0.1.12", "0.1.10", "beta", "beta"), [false, false]);
    // Switched back from the beta: the older stable release is offered, as going back.
    assert.deepEqual(offer("0.1.12", "0.1.10", "stable", "beta"), [false, true]);
    // The same build (a beta promoted): nothing.
    assert.deepEqual(offer("0.1.12", "0.1.12", "stable", "beta"), [false, false]);
    assert.deepEqual(offer(null, "0.1.10", "stable", "beta"), [false, false]);
    assert.deepEqual(offer("0.1.12", null, "stable", "beta"), [false, false]);
  });

  test("an update started before a handover is followed to its end", async (t) => {
    const dir = temp();
    const runDir = join(dir, "run");
    mkdirSync(runDir, { recursive: true });
    // Started by the release this one took over from, which was 0.1.1299; the installer is handing over.
    writeFileSync(join(runDir, "update.started"), JSON.stringify({ at: Date.now(), from: "0.1.1299" }));
    writeFileSync(join(runDir, "update.step"), "handoff\n");
    const updates = installed(dir, "1300", null);
    t.after(() => updates.close());
    updates.countRunning(() => 2);
    updates.followStarted();
    assert.deepEqual([station(updates).state, station(updates).progress], ["updating", "正在交接给新版本（agent 不中断）…"]);
    // Had it had to restart: what the drain waits on.
    writeFileSync(join(runDir, "update.step"), "drain\n");
    await until("draining", () => station(updates).progress === "等 2 个 agent 跑完这一轮再重启（新消息先排队）…");
    writeFileSync(join(runDir, "update.step"), "handoff\n");
    writeFileSync(join(runDir, "update.exit"), "0\n");
    await until("done", () => station(updates).state === "idle");
    const line = station(updates);
    assert.deepEqual([line.state, line.progress, line.done], ["idle", undefined, "已更新到 0.1.1300，agent 没有中断"]);
    assert.ok(!existsSync(join(runDir, "update.started")) && !existsSync(join(runDir, "update.step")));
    // Read again (the next check), it still says so; and in English to an English page.
    await updates.check();
    assert.equal(station(updates).done, "已更新到 0.1.1300，agent 没有中断");
    assert.equal(updates.get("en")[0]!.done?.includes("0.1.1300"), true);
  });

  test("an update started too long ago is not followed", async (t) => {
    const dir = temp();
    const runDir = join(dir, "run");
    mkdirSync(runDir, { recursive: true });
    writeFileSync(join(runDir, "update.started"), JSON.stringify({ at: Date.now() - 21 * 60_000, from: "0.1.1299" }));
    writeFileSync(join(runDir, "update.step"), "drain\n");
    const updates = installed(dir, "1300", null);
    t.after(() => updates.close());
    updates.followStarted();
    assert.equal(station(updates).state, "idle");
    assert.ok(!existsSync(join(runDir, "update.started")) && !existsSync(join(runDir, "update.step")));
  });

  test("the installer's download percent reads complete curl bars", () => {
    assert.equal(curlPercent("下载 still.fail station…\n\r                 0.0%"), 0);
    assert.equal(curlPercent("\r###   12.4%\r########   44.9%\r#########  45."), 44);
    assert.equal(curlPercent("\r######## 100.0%\n"), 100);
    for (const log of ["", "\r#=#=#", "error 44.0%", "### NaN%", "### 101.0%", "### -1.0%"]) assert.equal(curlPercent(log), null, log);
    const dir = temp();
    const log = join(dir, "update.log");
    assert.equal(stationDownloadPercent(log), null);
    writeFileSync(log, `${"old output\n".repeat(1000)}\r### 37.2%`);
    assert.equal(stationDownloadPercent(log), 37);
  });

  test("the station's download percent changes are told and cleared", async (t) => {
    const dir = temp();
    const runDir = join(dir, "run");
    mkdirSync(runDir, { recursive: true });
    const updates = installed(dir, "1300", null);
    t.after(() => updates.close());
    let told = 0;
    updates.changes(() => told++);
    writeFileSync(join(runDir, "update.step"), "download\n");
    writeFileSync(join(runDir, "update.log"), "\r### 12.4%");
    updates.follow({ at: Date.now(), from: "0.1.1300" });
    assert.equal(station(updates).percent, 12);
    writeFileSync(join(runDir, "update.log"), "\r### 12.4%\r######## 44.9%");
    await until("44%", () => station(updates).percent === 44);
    assert.ok(told >= 2);
    writeFileSync(join(runDir, "update.step"), "handoff\n");
    await until("handoff", () => station(updates).percent === undefined);
    assert.equal(station(updates).progress, "正在交接给新版本（agent 不中断）…");
    writeFileSync(join(runDir, "update.exit"), "0\n");
    await until("ended", () => station(updates).state === "idle");
    assert.equal(station(updates).percent, undefined);
    // The same version as it started from: it says so.
    assert.equal(station(updates).done, "已经是最新版");
  });

  test("a failed installer says what it said last", async (t) => {
    const dir = temp();
    const runDir = join(dir, "run");
    mkdirSync(runDir, { recursive: true });
    const updates = installed(dir, "1300", null);
    t.after(() => updates.close());
    writeFileSync(join(runDir, "update.log"), "one\ntwo\nthree\nfour\nfive\n");
    updates.follow({ at: Date.now(), from: "0.1.1300" });
    writeFileSync(join(runDir, "update.exit"), "1\n");
    await until("failed", () => station(updates).state === "failed");
    assert.equal(station(updates).message, "two\nthree\nfour\nfive");
  });

  test("switched back from the beta the stable release is offered and kept in the config", async (t) => {
    const dir = temp();
    const updates = installed(dir, "1300", "beta");
    t.after(() => updates.close());
    assert.equal(updates.channel(), "beta");
    let line = updates.stationWith("0.1.1310");
    assert.deepEqual([line.channel, line.newer, line.downgrade], ["beta", true, false]);

    await updates.setChannel("stable");
    assert.equal(updates.channel(), "stable");
    assert.equal(JSON.parse(readFileSync(join(dir, "config.json"), "utf8")).updateChannel, "stable");
    // What was read from the beta's feed is not the stable one's.
    line = station(updates);
    assert.deepEqual([line.latest, line.newer, line.downgrade], [undefined, false, false]);
    line = updates.stationWith("0.1.1200");
    assert.deepEqual([line.channel, line.newer, line.downgrade], ["stable", false, true]);

    // A station that never was on the beta is not offered an older one.
    const other = temp();
    const stable = installed(other, "1300", null);
    t.after(() => stable.close());
    line = stable.stationWith("0.1.1200");
    assert.deepEqual([line.channel, line.newer, line.downgrade], ["stable", false, false]);
    // Read again in a new process from a config that says beta: the feed it reads is the beta's.
    setChannelIn(other, "beta");
    const again = installed(other, "1300", null);
    t.after(() => again.close());
    assert.equal(again.channel(), "beta");
  });

  test("unless turned off, the station updates itself to each newer release once", async (t) => {
    const dir = temp();
    const updates = installed(dir, "1300", null);
    t.after(() => updates.close());
    // On when the config says nothing; off when the user turned it off, and on again when turned on.
    assert.equal(updates.stationWith("0.1.1310").auto, true);
    new ConfigFile(dir).update((raw) => (raw.autoUpdate = false));
    assert.equal(updates.stationWith("0.1.1310").auto, false);
    updates.backdateUse(5 * 60_000);
    assert.equal(updates.toUpdateTo(), null, "not when turned off");
    new ConfigFile(dir).update((raw) => (raw.autoUpdate = true));
    updates.used();
    assert.equal(updates.stationWith("0.1.1310").auto, true);
    assert.equal(updates.toUpdateTo(), null, "wait for five minutes of quiet");
    updates.backdateUse(5 * 60_000);
    assert.equal(updates.toUpdateTo(), "0.1.1310");
    // Already the latest, or the latest is older: nothing.
    updates.stationWith("0.1.1300");
    assert.equal(updates.toUpdateTo(), null);
    updates.stationWith("0.1.1290");
    assert.equal(updates.toUpdateTo(), null);
    // A version it went for (and failed to get) is not tried again; the next one is.
    updates.tried = "0.1.1310";
    updates.stationWith("0.1.1310");
    assert.equal(updates.toUpdateTo(), null);
    updates.stationWith("0.1.1320");
    assert.equal(updates.toUpdateTo(), "0.1.1320");
    // While a runtime installs: not yet, nor by hand (a handover or restart would leave it unfollowed).
    updates.poke("codex", (i) => (i.updating = Date.now()));
    assert.equal(updates.toUpdateTo(), null);
    await assert.rejects(updates.update("station", "zh"), (e: Error) => e.message.includes("Codex 正在安装"));
    updates.poke("codex", (i) => (i.updating = null));
    assert.equal(updates.toUpdateTo(), "0.1.1320");
    // While an update goes on: nothing more, nor a runtime installed meanwhile.
    updates.poke("station", (i) => (i.updating = Date.now()));
    assert.equal(updates.toUpdateTo(), null);
    await assert.rejects(updates.update("codex", "zh"), (e: Error) => e.message.includes("station 正在更新"));

    // Switched back from the beta, the older stable release is offered, but not gone to by itself.
    const other = temp();
    const beta = installed(other, "1300", "beta");
    t.after(() => beta.close());
    new ConfigFile(other).update((raw) => {
      raw.updateChannel = "stable";
    });
    assert.ok(beta.stationWith("0.1.1200").downgrade);
    assert.equal(beta.toUpdateTo(), null);
  });

  test("automatic updates wait for clients and turns, then a quiet period", async (t) => {
    const dir = temp();
    const updates = installed(dir, "1300", null);
    t.after(() => updates.close());
    new ConfigFile(dir).update((raw) => (raw.autoUpdate = true));
    updates.stationWith("0.1.1310");
    let clients = true;
    let running = false;
    updates.whileInUse(() => clients);
    updates.countRunning(() => (running ? 1 : 0));
    updates.backdateUse(5 * 60_000);
    assert.equal(updates.toUpdateTo(), null, "a client is still using it");
    clients = false;
    assert.equal(updates.toUpdateTo(), null, "closing the client does not update immediately");
    updates.backdateUse(5 * 60_000);
    running = true;
    assert.equal(updates.toUpdateTo(), null, "a Slack turn also postpones the update");
    running = false;
    assert.equal(updates.toUpdateTo(), null);
    updates.backdateUse(5 * 60_000);
    assert.equal(updates.toUpdateTo(), "0.1.1310");
    updates.used();
    assert.equal(updates.toUpdateTo(), null, "a request resets the quiet period");
  });

  // The installer here is install.sh, piped to sh; Windows' (install.ps1, by a scheduled task) is the next test's.
  const shInstaller = { skip: WINDOWS && "install.sh is macOS's and Linux's" };

  test("on Windows the update's script runs install.ps1, its words in UTF-8 and its exit kept", { skip: !WINDOWS && "Windows'" }, async (t) => {
    const dir = temp();
    const run = join(dir, "run 'x'");
    mkdirSync(run);
    const installer = [
      "Write-Host ('下载 still.fail station… ' + $env:STILLFAIL_CHANNEL + ' ' + $env:STILLFAIL_DATA)",
      "[Console]::Error.WriteLine('没能更新')",
      "exit 3",
    ].join("\r\n");
    const asked: string[] = [];
    const [origin, server] = await serve((path, search) => {
      asked.push(path + search);
      return path === "/install.ps1" ? { type: "text/plain; charset=utf-8", body: installer } : null;
    });
    t.after(() => server.close());
    const env = { STILLFAIL_DATA: dir, STILLFAIL_CHANNEL: "beta", PATH: "C:\\nowhere" };
    const ps1 = join(run, "update.ps1");
    const text = windowsUpdateScript(origin, run, env, "still.fail station (test, not registered) update", "zh");
    // Only the station's own variables: the task has the user's PATH.
    assert.ok(!text.includes("nowhere"));
    writeFileSync(ps1, text);
    // Run here as the task runs it (no task: its removal at the end finds none). Not spawnSync: the cloud is this process.
    await new Promise<void>((resolve, reject) =>
      execFile("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ps1], (e, _out, err) => (e ? reject(new Error(`${e.message} ${err}`)) : resolve())),
    );
    assert.deepEqual(asked, ["/install.ps1?lang=zh"]);
    assert.equal(readFileSync(join(run, "update.exit"), "utf8").trim(), "3");
    const log = readFileSync(join(run, "update.log"), "utf8");
    assert.ok(log.includes(`下载 still.fail station… beta ${dir}`), log);
    assert.ok(log.includes("没能更新"), log);
  });

  test("the station is updated by its cloud's installer, followed to its end", shInstaller, async (t) => {
    const dir = temp();
    const [origin, server, asked, finish] = await cloudWithRelease("0.1.1310", "1310", true);
    t.after(() => server.close());
    const updates = installed(dir, "1300", null, { origin: () => origin, env: { PATH: "/usr/bin:/bin" } });
    t.after(() => updates.close());
    await updates.check();
    assert.deepEqual([station(updates).latest, station(updates).newer, station(updates).updatable], ["0.1.1310", true, true]);
    await updates.update("station", "zh");
    assert.equal(station(updates).state, "updating");
    assert.ok(existsSync(join(dir, "run", "update.started")));
    // Asked again meanwhile: refused.
    await assert.rejects(updates.update("station", "zh"), (e: Error) => e.message === "Station 正在更新");
    finish();
    await until("ended", () => station(updates).state === "idle");
    assert.equal(station(updates).done, "已更新到 0.1.1310，agent 没有中断");
    assert.ok(asked.includes("/install.sh?lang=zh"), asked.join());
    assert.equal(readFileSync(join(dir, "installer-saw"), "utf8").trim(), `stable ${dir} ${dir}`);
    assert.ok(!existsSync(join(dir, "run", "update.started")));
    assert.equal(readFileSync(join(dir, "run", "update.exit"), "utf8").trim(), "0");
  });

  test("by default, a quiet station updates itself by the installer, once", shInstaller, async (t) => {
    const dir = temp();
    const [origin, server, asked] = await cloudWithRelease("0.1.1310", "1310");
    t.after(() => server.close());
    const time = testClock();
    const updates = installed(dir, "1300", null, { origin: () => origin, env: { PATH: "/usr/bin:/bin" }, timing: { followLook: 200, idlePoll: 50, idleFor: 100 }, clock: time.clock });
    t.after(() => updates.close());
    /// Moves its time on by `ms` until `f` holds (what it waits for meanwhile may be a real process).
    const steps = async (ms: number, f: () => boolean) => {
      while (!f()) {
        await time.adjust(ms);
        await sleep(10);
      }
    };
    // A reading of what is out ended once the feed was asked a second time (it decides as it ends).
    const feeds = () => asked.filter((a) => a.startsWith("/releases/station.json")).length;
    let readAgain = false;
    updates.changes(() => void (feeds() >= 2 && (readAgain = true)));
    updates.start();
    // It reads what is out at once; quiet for 100 ms of its time, it updates itself by the installer.
    await until("read", () => station(updates).latest === "0.1.1310");
    await steps(50, () => station(updates).state === "updating");
    await until("the installer ended", () => existsSync(join(dir, "run", "update.exit")));
    await steps(200, () => station(updates).done === "已更新到 0.1.1310，agent 没有中断");
    // Then reads what is out again: the feed still says 0.1.1310 and the release is 0.1.1310, so nothing more (its
    // decision taken as the reading ends), nor on its rounds after.
    await until("read again", () => readAgain);
    for (let i = 0; i < 5; i++) {
      await time.adjust(50);
      await settle();
    }
    assert.equal(station(updates).state, "idle");
    assert.equal(asked.filter((a) => a.startsWith("/install.sh")).length, 1);
  });

  test("a station not installed by the installer, or not in a workspace, is not updated here", async (t) => {
    const dir = temp();
    const app = join(dir, "elsewhere");
    mkdirSync(app);
    writeFileSync(join(app, "BUILD"), "1300");
    const updates = new Updates({ app, data: dir, config: new ConfigFile(dir), origin: () => "http://127.0.0.1:1", registry: "http://127.0.0.1:1", env: { PATH: "/nowhere" } });
    t.after(() => updates.close());
    await updates.check();
    let line = station(updates);
    assert.deepEqual([line.note, line.updatable, line.channel, line.auto], ["不是用安装脚本装的，没法在这里更新", false, undefined, undefined]);
    await assert.rejects(updates.update("station", "en"), /Station: /);
    await assert.rejects(updates.setAuto(true, "zh"), (e: Error) => e.message === "Station：不是用安装脚本装的，没法在这里更新");
    const unjoined = installed(temp(), "1300", null, { origin: () => null });
    t.after(() => unjoined.close());
    await unjoined.check();
    line = station(unjoined);
    assert.equal(line.note, "还没加入 workspace，无从更新");
    await assert.rejects(unjoined.update("nope", "zh"), (e: Error) => e.message === "没有 nope 这一项");
  });

  describe("Codex installed by npm (one build file in the temp directory: one at a time)", () => {
    test("a runtime the machine has not is installed with npm, its download measured, its version pinned", async (t) => {
      const [registry, server, bin, said] = await codexWorld("0.47.0");
      t.after(() => server.close());
      const dir = temp();
      let changed = 0;
      const updates = installed(dir, "1300", null, { registry, env: { PATH: withSystem(bin), HOME: dir }, runtimeChanged: () => changed++ });
      t.after(() => updates.close());
      await updates.check();
      let codex = updates.get("zh")[2]!;
      assert.deepEqual([codex.installed, codex.updatable, codex.latest, codex.state], [false, true, "0.47.0", "idle"]);
      const percents: number[] = [];
      updates.changes(() => {
        const p = updates.get("zh")[2]!.percent;
        if (p !== undefined) percents.push(p);
      });
      await updates.update("codex", "zh");
      assert.equal(updates.get("zh")[2]!.state, "updating");
      await until("installed", () => updates.get("zh")[2]!.state !== "updating");
      codex = updates.get("zh")[2]!;
      assert.deepEqual([codex.installed, codex.version, codex.newer, codex.state, codex.message], [true, "0.47.0", false, "idle", undefined]);
      assert.equal(changed, 1);
      assert.equal(percents.at(-1), 100);
      const asked = readFileSync(said, "utf8").trim().split("\n");
      assert.ok(asked[0]!.startsWith("cache add "), asked.join("|"));
      assert.equal(asked[1], "install -g @openai/codex@0.47.0 --prefer-online");
    });

    test("an install that leaves nothing on the station's PATH says so", async (t) => {
      const [registry, server, bin] = await codexWorld(null);
      t.after(() => server.close());
      const dir = temp();
      const updates = installed(dir, "1300", null, { registry, env: { PATH: withSystem(bin), HOME: dir } });
      t.after(() => updates.close());
      await updates.check();
      await updates.update("codex", "zh");
      await until("failed", () => updates.get("zh")[2]!.state === "failed");
      assert.equal(updates.get("zh")[2]!.message, `${exe(join(bin, "npm"))} 跑完了，但 station 的 PATH 上还是找不到 codex：可能装到了别处`);
    });
  });

  test("on Windows a command beside vp.exe is Vite+'s, updated with it; one in npm's prefix with that npm", { skip: !WINDOWS && "Windows'" }, () => {
    const dir = temp();
    writeFileSync(join(dir, "vp.exe"), "");
    writeFileSync(join(dir, "codex.cmd"), "@echo codex-cli 0.1.0\r\n");
    const env: Env = { PATH: dir };
    assert.deepEqual(howToUpdate("codex", findCommand("codex", env)!, env), { program: join(dir, "vp.exe"), args: ["install", "-g", "@openai/codex@latest"] });
    const prefix = temp();
    mkdirSync(join(prefix, "node_modules", "@anthropic-ai", "claude-code"), { recursive: true });
    writeFileSync(join(prefix, "claude.cmd"), "@echo 2.1.0\r\n");
    writeFileSync(join(prefix, "npm.cmd"), "");
    const there: Env = { PATH: prefix };
    assert.deepEqual(howToUpdate("claude", findCommand("claude", there)!, there), {
      program: join(prefix, "npm.cmd"), args: ["install", "-g", "@anthropic-ai/claude-code@latest", "--prefix", prefix],
    });
  });

  test("vite shims update the package with their own vp", { skip: WINDOWS && "Windows' Vite+ commands are shims of their own (the test before)" }, async () => {
    const dir = temp();
    script(join(dir, "vp"), "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
    for (const kind of ["claude", "codex"] as const) {
      symlinkSync("vp", join(dir, kindCommand(kind)));
      const env: Env = { PATH: dir };
      const f = findCommand(kindCommand(kind), env)!;
      const how = howToUpdate(kind, f, env);
      assert.ok(!(how instanceof Unable));
      const [ok, said] = await run(how.program, how.args, env, 10_000);
      assert.ok(ok);
      assert.equal(said, `install\n-g\n${kindPackage(kind)}@latest\n`);
    }
  });

  test("a standalone update keeps the actual home and path, with shell characters", shInstaller, async () => {
    const dir = temp();
    const home = join(dir, "custom codex ' $home");
    const real = join(home, "packages/standalone/releases/0.155.1-aarch64-apple-darwin/bin/codex");
    const bin = join(dir, "visible bin ' $bin");
    script(real, "#!/bin/sh\necho 'codex-cli 0.155.1'\n");
    mkdirSync(bin, { recursive: true });
    symlinkSync(real, join(bin, "codex"));
    // A harmless installer instead of downloading or changing any real installation.
    script(join(bin, "curl"), `#!/bin/sh
cat <<'INSTALLER'
test "$CODEX_NON_INTERACTIVE" = 1 || exit 1
test "$1" = --release && test "$2" = latest || exit 2
printf '%s\\n' "$CODEX_HOME" "$CODEX_INSTALL_DIR"
INSTALLER
`);
    const env: Env = { PATH: `${bin}:/usr/bin:/bin`, CODEX_HOME: "/wrong/home" };
    const f = findCommand("codex", env)!;
    const how = howToUpdate("codex", f, env);
    assert.ok(!(how instanceof Unable));
    const [ok, said] = await run(how.program, how.args, env, 10_000);
    assert.ok(ok, said);
    assert.equal(said, `${realpathSync(home)}\n${bin}\n`);
    assert.ok(howToUpdate("codex", { onPath: real, real }, env) instanceof Unable);
  });

  test("each runtime is updated the way it was installed", () => {
    const dir = temp();
    for (const name of ["brew", "npm"]) script(join(dir, name), "#!/bin/sh\n");
    const env: Env = { PATH: dir };
    const [brew, npm] = [exe(join(dir, "brew")), exe(join(dir, "npm"))];
    assert.deepEqual(howToUpdate("claude", found("/Users/a/.local/share/claude/versions/2.1.284"), env), { program: "/nowhere/bin/x", args: ["update"] });
    assert.deepEqual(howToUpdate("claude", found("/opt/homebrew/Caskroom/claude-code/2.1.284/claude"), env), { program: brew, args: ["upgrade", "--cask", "claude-code"] });
    assert.deepEqual(howToUpdate("codex", found("/opt/homebrew/Cellar/codex/0.46.0/bin/codex"), env), { program: brew, args: ["upgrade", "codex"] });
    assert.deepEqual(howToUpdate("codex", found("/Users/a/.nvm/versions/node/v24/lib/node_modules/@openai/codex/bin/codex.js"), env), {
      program: npm, args: ["install", "-g", "@openai/codex@latest", "--prefix", "/Users/a/.nvm/versions/node/v24"],
    });
    assert.deepEqual(howToUpdate("claude", found("/Users/a/node/lib/node_modules/@anthropic-ai/claude-code/cli.js"), env), {
      program: npm, args: ["install", "-g", "@anthropic-ai/claude-code@latest", "--prefix", "/Users/a/node"],
    });
    // Linked from a directory beside another Node's npm: its own Node's npm, not that one.
    const node = join(dir, "node/v24.3.0");
    mkdirSync(join(node, "bin"), { recursive: true });
    writeFileSync(join(node, "bin/npm"), "");
    const linked: Found = { onPath: join(dir, "codex"), real: join(node, "lib/node_modules/@openai/codex/bin/codex.js") };
    const how = howToUpdate("codex", linked, env);
    assert.deepEqual(how, { program: join(node, "bin/npm"), args: ["install", "-g", "@openai/codex@latest", "--prefix", node] });
    assert.deepEqual(pinNpmVersion(how as any, "@openai/codex", "0.159.3").args, ["install", "-g", "@openai/codex@0.159.3", "--prefix", node, "--prefer-online"]);
    const say_ = (h: unknown) => (h as Unable).say("zh");
    assert.ok(say_(howToUpdate("codex", found("/project/node_modules/@openai/codex/bin/codex.js"), env)).includes("全局安装目录"));
    assert.ok(say_(howToUpdate("codex", found("/usr/local/bin/codex"), env)).includes("自己更新"));
    // Codex's standalone installer is a shell script: on Windows not run.
    if (WINDOWS) assert.ok(say_(howToUpdate("codex", found("C:/Users/a/.codex/packages/standalone/releases/0.1.0-x86_64-pc-windows-msvc/bin/codex.exe"), env)).includes("自己更新"));
    assert.deepEqual(howToInstall("codex", env), { program: npm, args: ["install", "-g", "@openai/codex@latest"] });
    const bare: Env = { PATH: "/nowhere" };
    assert.ok(say_(howToInstall("codex", bare)).includes("Node"));
    assert.equal((howToInstall("claude", bare) as any).program, WINDOWS ? "powershell" : "/bin/sh");
  });
});
