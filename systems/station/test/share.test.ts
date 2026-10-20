// Stations sharing profiles and skills (src/share/index.ts, docs/station-share.md): two stations, a cloud that only
// lists who hosts what (as cloud/src/directory.ts `stationShare` keeps it), and the station transport as a direct call.
import assert from "node:assert/strict";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { checkConfig } from "../src/accounts/check.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { Sharing } from "../src/share/index.ts";

const A = "a".repeat(64);
const B = "b".repeat(64);

/// The workspace's roster as still.fail cloud gives it (the only thing it says here), and each station's view of it.
class FakeCloud {
  peers = [{ id: A, name: "studio" }, { id: B, name: "mini" }];
  listeners = new Set<() => void>();
  cloudFor(station: string) {
    const cloud = this;
    return {
      peersCurrent: true,
      get state() {
        return { station, workspace: "w", peers: cloud.peers } as any;
      },
      removed: () => false,
      listen(f: () => void) {
        cloud.listeners.add(f);
        return () => cloud.listeners.delete(f);
      },
    } as any;
  }
  tell() {
    for (const f of this.listeners) f();
  }
}

type Station = { data: string; config: ConfigFile; sharing: Sharing; lent: string[] };

function station(cloud: FakeCloud, id: string, others: () => Map<string, Station>, profiles: any[] = []): Station {
  const data = mkdtempSync(join(tmpdir(), "share-"));
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles }));
  const config = new ConfigFile(data);
  config.check = checkConfig;
  mkdirSync(join(data, "agent", "skills"), { recursive: true });
  const lent: string[] = [];
  const sharing = new Sharing({
    data, config, cloud: cloud.cloudFor(id),
    ask: async (to, request) => {
      const other = others().get(to);
      if (!other) throw new Error("peer unavailable");
      return other.sharing.handle(id, request);
    },
    agentHome: () => join(data, "agent"),
    env: {},
    claudeToken: async (p) => (lent.push(p.id), { token: `token-of-${p.id}`, expiresAt: Date.now() + 3600_000 }),
    codexRunning: () => false,
    status: (pid) => ({ check: { state: "ok", detail: `checked ${pid}`, models: null, checkedAt: 1 }, quota: null }),
    changed: () => {},
  });
  return { data, config, sharing, lent };
}

const settle = async (...stations: Station[]) => {
  for (let i = 0; i < 4; i++) {
    await new Promise((r) => setImmediate(r));
    await Promise.all(stations.map((s) => s.sharing.reconcile()));
  }
};

const KEY = { id: "deepseek", name: "DeepSeek", credential: "api_key", source: "deepseek", key: "sk-secret", home: "homes/deepseek", env: {} };
const SUB = { id: "max", name: "Claude Max", runtime: "claude", credential: "subscription", source: "claude", home: "homes/max", env: {} };

test("a shared key profile is copied to the other station, key and all; stopping takes it away", async () => {
  const cloud = new FakeCloud();
  const all = new Map<string, Station>();
  const a = station(cloud, A, () => all, [KEY]);
  const b = station(cloud, B, () => all);
  all.set(A, a).set(B, b);
  await a.sharing.shareProfile("deepseek", true, null);
  await settle(a, b);
  const id = a.config.raw().profiles[0].share.id;
  assert.match(id, /^sh-[0-9a-f]{20}$/);
  const copy = b.config.raw().profiles.find((p: any) => p.share?.id === id);
  assert.ok(copy, "copied to the other station");
  assert.equal(copy.id, id);
  assert.equal(copy.key, "sk-secret");
  assert.equal(copy.share.borrowed, true);
  assert.deepEqual(b.sharing.profileView(copy), { id, role: "user", host: A, allow: null, reachable: true });
  // An edit on its host reaches the copy.
  a.config.update((raw) => (raw.profiles[0].key = "sk-new"));
  await settle(a, b);
  assert.equal(b.config.raw().profiles.find((p: any) => p.id === id).key, "sk-new");
  // The host offline: the copy stays.
  all.delete(A);
  await settle(b);
  assert.equal(b.config.raw().profiles.length, 1);
  all.set(A, a);
  // The other away when it changed: told once it can be (the host tries again), over the mesh, not through the cloud.
  all.delete(B);
  a.config.update((raw) => (raw.profiles[0].name = "DeepSeek 2"));
  await settle(a);
  assert.equal(b.config.raw().profiles[0].name, "DeepSeek");
  all.set(B, b);
  await settle(a, b);
  assert.equal(b.config.raw().profiles[0].name, "DeepSeek 2");
  await a.sharing.shareProfile("deepseek", false, null);
  await settle(a, b);
  assert.equal(b.config.raw().profiles.length, 0);
  assert.equal(a.config.raw().profiles[0].share, undefined);
});

test("a station left out of a share's stations does not get it, and refuses to be asked for it", async () => {
  const cloud = new FakeCloud();
  const all = new Map<string, Station>();
  const a = station(cloud, A, () => all, [KEY]);
  const b = station(cloud, B, () => all);
  all.set(A, a).set(B, b);
  await a.sharing.shareProfile("deepseek", true, [A]);
  await settle(a, b);
  assert.equal(b.config.raw().profiles.length, 0);
  const id = a.config.raw().profiles[0].share.id;
  await assert.rejects(a.sharing.handle(B, { method: "share.get", id }), /not for this station/);
});

test("a shared subscription: the other borrows tokens from its host, with no login of its own; not while the host is away", async () => {
  const cloud = new FakeCloud();
  const all = new Map<string, Station>();
  const a = station(cloud, A, () => all, [SUB]);
  const b = station(cloud, B, () => all);
  all.set(A, a).set(B, b);
  await a.sharing.shareProfile("max", true, null);
  await settle(a, b);
  const copy = b.config.raw().profiles[0];
  assert.equal(copy.credential, "subscription");
  assert.equal(copy.key, undefined);
  assert.equal(b.sharing.borrowedSubscription(copy), true);
  assert.equal(existsSync(join(b.data, "homes", copy.id, ".credentials.json")), false);
  const token = await b.sharing.lendClaude(copy);
  assert.equal(token.token, "token-of-max");
  assert.deepEqual(a.lent, ["max"]);
  assert.equal((await b.sharing.status(copy)).check.detail, "checked max");
  all.delete(A);
  await assert.rejects(b.sharing.lendClaude(copy), /did not lend/);
  assert.equal(b.sharing.profileView(copy)!.reachable, false);
});

test("a borrowed Codex subscription's login is written in its home, the profile as the runtime has it (its home resolved)", async () => {
  const cloud = new FakeCloud();
  const all = new Map<string, Station>();
  const CODEX = { id: "plus", name: "ChatGPT Plus", runtime: "codex", credential: "subscription", home: "homes/plus", env: {} };
  const a = station(cloud, A, () => all, [CODEX]);
  const b = station(cloud, B, () => all);
  all.set(A, a).set(B, b);
  const jwt = (claims: object) => ["{}", JSON.stringify(claims), "s"].map((p) => Buffer.from(p).toString("base64url")).join(".");
  mkdirSync(join(a.data, "homes", "plus"), { recursive: true });
  // Expires in 2100.
  writeFileSync(join(a.data, "homes", "plus", "auth.json"), JSON.stringify({ tokens: { id_token: "id", access_token: jwt({ exp: 4_102_444_800 }), account_id: "acct", refresh_token: "r" } }));
  await a.sharing.shareProfile("plus", true, null);
  await settle(a, b);
  const copy = b.config.raw().profiles[0];
  // As sessions/config.ts gives it to the runtime: its home absolute (C:\… on Windows; a doubled one was made there).
  const home = join(b.data, copy.home);
  await b.sharing.lendCodex({ ...copy, home });
  const auth = JSON.parse(readFileSync(join(home, "auth.json"), "utf8"));
  assert.equal(auth.tokens.account_id, "acct");
  assert.equal(auth.tokens.refresh_token, "lent-by-another-station");
});

test("a shared subscription moves to another station: login handed over, the old host keeps a copy", async () => {
  const cloud = new FakeCloud();
  const all = new Map<string, Station>();
  const a = station(cloud, A, () => all, [SUB]);
  const b = station(cloud, B, () => all);
  all.set(A, a).set(B, b);
  mkdirSync(join(a.data, "homes", "max"), { recursive: true });
  writeFileSync(join(a.data, "homes", "max", ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "x", refreshToken: "r" } }));
  await a.sharing.shareProfile("max", true, null);
  await settle(a, b);
  const id = a.config.raw().profiles[0].share.id;
  await a.sharing.moveProfile("max", B);
  await settle(a, b);
  const taken = b.config.raw().profiles.find((p: any) => p.share?.id === id);
  assert.equal(taken.share.borrowed, undefined);
  assert.equal(b.sharing.profileView(taken)!.role, "host");
  assert.deepEqual(b.sharing.profileView(taken)!.users, [A], "it knows who borrows it");
  assert.equal(JSON.parse(readFileSync(join(b.data, "homes", taken.id, ".credentials.json"), "utf8")).claudeAiOauth.refreshToken, "r");
  // The old host forgot the login and borrows now (under the same profile id: its chats go on).
  const left = a.config.raw().profiles.find((p: any) => p.id === "max");
  assert.equal(left.share.borrowed, true);
  assert.equal(left.share.host, B, "it knows whom it borrows from");
  assert.equal(existsSync(join(a.data, "homes", "max", ".credentials.json")), false);
  assert.equal((await a.sharing.lendClaude(left)).token, `token-of-${taken.id}`);
  // Only the station that has it can hand it over.
  await assert.rejects(a.sharing.moveProfile("max", A), /only a profile this station shares/);
});

test("a shared skill: copied and linked under its name, edits go back to the host, one made on an older copy is kept beside it", async () => {
  const cloud = new FakeCloud();
  const all = new Map<string, Station>();
  const a = station(cloud, A, () => all);
  const b = station(cloud, B, () => all);
  all.set(A, a).set(B, b);
  const dir = join(a.data, "agent", "skills", "ember");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "SKILL.md"), "---\nname: ember\ndescription: 项目记忆：ember\n---\nfirst\n");
  await a.sharing.shareSkill("ember", true, null);
  await settle(a, b);
  const link = join(b.data, "agent", "skills", "ember");
  assert.ok(lstatSync(link).isSymbolicLink());
  assert.match(readFileSync(join(link, "SKILL.md"), "utf8"), /first/);
  const id = a.config.raw().sharedSkills.ember.id;
  assert.equal(b.sharing.skillView("ember")!.role, "user");
  // An edit on the copy, sent to the host on the version it was made on.
  writeFileSync(join(readlinkSync(link), "SKILL.md"), "---\nname: ember\ndescription: 项目记忆：ember\n---\nfrom mini\n");
  const state = JSON.parse(readFileSync(join(b.data, "share", "state.json"), "utf8"));
  const base = state.borrowed[id].version;
  const answer = await a.sharing.handle(B, { method: "share.put", id, base, files: { "SKILL.md": Buffer.from("from mini\n").toString("base64") } });
  assert.deepEqual(answer, { version: base + 1, conflict: false });
  assert.equal(readFileSync(join(dir, "SKILL.md"), "utf8"), "from mini\n");
  // One made on the version before: kept beside, the host's stays.
  const late = await a.sharing.handle(B, { method: "share.put", id, base, files: { "SKILL.md": Buffer.from("late\n").toString("base64") } });
  assert.equal(late.conflict, true);
  assert.equal(readFileSync(join(dir, "SKILL.md"), "utf8"), "from mini\n");
  assert.equal(readFileSync(join(dir, `SKILL.conflict-${B.slice(0, 12)}.md`), "utf8"), "late\n");
  // One of the station's own by that name wins over a shared one.
  await a.sharing.shareSkill("ember", false, null);
  await settle(a, b);
  assert.equal(existsSync(link), false);
});

test("a station gone from the workspace: what it shared is taken away, what it used forgotten", async () => {
  const cloud = new FakeCloud();
  const all = new Map<string, Station>();
  const a = station(cloud, A, () => all, [KEY]);
  const b = station(cloud, B, () => all);
  all.set(A, a).set(B, b);
  await a.sharing.shareProfile("deepseek", true, null);
  await settle(a, b);
  const id = a.config.raw().profiles[0].share.id;
  assert.deepEqual(a.sharing.profileView(a.config.raw().profiles[0])!.users, [B]);
  cloud.peers = cloud.peers.filter((p) => p.id !== A);
  cloud.tell();
  await settle(b);
  assert.equal(b.config.raw().profiles.length, 0, "its copy taken away");
  cloud.peers = [{ id: A, name: "studio" }];
  cloud.tell();
  await settle(a);
  assert.deepEqual(a.sharing.profileView(a.config.raw().profiles[0])!.users, [], "no one borrows it now");
  assert.equal(a.config.raw().profiles[0].share.id, id);
});

test("a host outside the workspace (Salix): its profiles are placed whole, lent through its own channel, and kept apart from the roster", async () => {
  const cloud = new FakeCloud();
  const all = new Map<string, Station>();
  const b = station(cloud, B, () => all);
  all.set(B, b);
  const salixId = "sh-0123456789abcdefghij";
  const keyId = "sh-abcdefghij0123456789";
  b.sharing.hostProfiles("salix", [
    { id: salixId, version: 1, name: "Claude Max", profile: { name: "Claude Max", runtime: "claude", credential: "subscription", source: "claude" }, email: "pat@example.com" },
    { id: keyId, version: 1, name: "Anthropic", profile: { name: "Anthropic", credential: "api_key", source: "anthropic", key: "sk-salix" } },
  ]);
  const sub = b.config.raw().profiles.find((p: any) => p.share?.id === salixId);
  assert.deepEqual(sub.share, { id: salixId, borrowed: true, host: "salix", email: "pat@example.com" });
  assert.equal(b.sharing.borrowedSubscription(sub), true);
  assert.equal(b.config.raw().profiles.find((p: any) => p.share?.id === keyId).key, "sk-salix");
  // Not connected: nothing is lent.
  await assert.rejects(b.sharing.lendClaude(sub), /salix is not connected/);
  const asked: any[] = [];
  b.sharing.attachHost("salix", async (request) => (asked.push(request), { token: "salix-token", expiresAt: 42 }));
  assert.deepEqual(await b.sharing.lendClaude(sub), { token: "salix-token", expiresAt: 42 });
  assert.deepEqual(asked, [{ method: "share.lend", id: salixId }]);
  // Salix is no station of the roster: reconciling keeps its profiles.
  await settle(b);
  assert.equal(b.config.raw().profiles.length, 2);
  // What it no longer lends goes.
  b.sharing.hostProfiles("salix", [{ id: keyId, version: 1, name: "Anthropic", profile: { name: "Anthropic", credential: "api_key", source: "anthropic", key: "sk-salix" } }]);
  assert.deepEqual(b.config.raw().profiles.map((p: any) => p.share.id), [keyId]);
  assert.throws(() => b.sharing.hostProfiles("salix", [{ id: "not-a-share" }]), /bad share id/);
});
