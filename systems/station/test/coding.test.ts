// Coding Sessions (src/tasks/coding.ts): a Session invited to a Salix Task with a repository works in a worktree of
// it on its session branch, starts no turn before the checkout is made, pushes after its turns, and answers Salix's
// task.diff, task.save and task.pull_request. "GitHub" is a local bare repository; gh is a script on PATH.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Coding, parseChanges, repoOf } from "../src/tasks/coding.ts";
import { Tasks } from "../src/tasks/tasks.ts";
import { Rig, settle } from "./hub-fakes.ts";

type Json = any;

const git = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, encoding: "utf8", env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" } }).trim();

/// A bare "GitHub" repository acme/api with a main branch holding README.md.
function origin(): { root: string; bare: string } {
  const root = mkdtempSync(join(tmpdir(), "coding-origin-"));
  const bare = join(root, "acme", "api.git");
  mkdirSync(bare, { recursive: true });
  git(bare, "init", "--bare", "-b", "main");
  // As GitHub does: a clone may leave out file contents and fetch them later.
  git(bare, "config", "uploadpack.allowFilter", "true");
  git(bare, "config", "uploadpack.allowAnySHA1InWant", "true");
  const seed = join(root, "seed");
  git(root, "clone", bare, seed);
  writeFileSync(join(seed, "README.md"), "hello\n");
  git(seed, "add", ".");
  git(seed, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "first");
  git(seed, "push", "origin", "HEAD:main");
  return { root, bare };
}

function coding(rig: Rig, root: string): Coding {
  const c = new Coding({
    reposDir: join(rig.dir, "repos"),
    // A file:// URL: git copies a plain path whole, ignoring a filter.
    remote: (owner, name) => "file://" + join(root, owner, `${name}.git`),
    givenToken: join(rig.dir, "token"),
    ghConfigDir: join(rig.dir, "gh"),
  });
  rig.hub.coding = c;
  return c;
}

const start = (branch = "comma/t1") => ({ requester: "ann@example.com", runtime: "claude", repo: { owner: "acme", name: "api", base_ref: "main", branch } });

test("the repository of a Task's start is checked", () => {
  assert.deepEqual(repoOf(start()), { owner: "acme", name: "api", base_ref: "main", branch: "comma/t1" });
  assert.equal(repoOf({ repo: { owner: "acme", name: "api", base_ref: "main", branch: "../x" } }), null);
  assert.equal(repoOf({ repo: { owner: "a b", name: "api", base_ref: "main", branch: "x" } }), null);
  assert.equal(repoOf({}), null);
});

test("a coding Session works in a checkout on its branch, made before its first turn, and pushes after its turns", async () => {
  const { root, bare } = origin();
  const b = new Rig();
  coding(b, root);
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async (r: Json) => (r.method === "task.hello" ? {} : { seq: 2 }));
  const { session } = await tasks.handle("salix", { method: "task.invite", task: "cnv_1", start: start() });
  await tasks.handle("salix", { method: "task.put", task: "cnv_1", messages: [{ seq: 1, author: { kind: "person", id: "ann@example.com" }, text: "fix it", declared: null, at: 0 }], through: 1 });
  await settle();
  // Only once the checkout is made does a turn start, in it.
  const workspace = b.store.getSession(session)!.workspace;
  assert.equal(b.claude.sessions.length, 0, "no turn before the checkout");
  await b.hub.coding!.checkout(session, workspace, repoOf(start())!);
  await settle();
  assert.equal(git(workspace, "rev-parse", "--abbrev-ref", "HEAD"), "comma/t1");
  assert.equal(readFileSync(join(workspace, "README.md"), "utf8"), "hello\n");
  // Blobless, with the whole history: a merge base with the base branch is found.
  assert.equal(git(workspace, "config", "--get", "remote.origin.partialclonefilter"), "blob:none");
  assert.equal(git(workspace, "merge-base", "HEAD", "origin/main"), git(bare, "rev-parse", "main"));
  assert.equal(b.claude.last().options.cwd, workspace);
  // The temporary sandbox defaults to committing and pushing, with explicit user overrides.
  const told = b.claude.last().options.instructions;
  assert.match(told, /github\.com\/acme\/api on the branch comma\/t1/);
  assert.match(told, /By default, commit your changes and push comma\/t1 before you end a turn in which you changed files/);
  assert.match(told, /Follow explicit user instructions when they differ, including requests to leave changes uncommitted, use another branch, or force-push/);

  // Where it stands, as task.status says it.
  writeFileSync(join(workspace, "README.md"), "hello world\n");
  const status = await tasks.handle("salix", { method: "task.status", task: "cnv_1" });
  assert.equal(status.dirty, true);

  // The agent commits; its turn ends; the branch is pushed.
  git(workspace, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-am", "fix the greeting");
  b.claude.last().complete();
  await settle();
  assert.equal(await b.hub.coding!.pushed(workspace), true);
  assert.equal(git(bare, "rev-parse", "comma/t1"), git(workspace, "rev-parse", "HEAD"));
  const after = await tasks.handle("salix", { method: "task.status", task: "cnv_1" });
  assert.equal(after.dirty, false);
  assert.equal(after.unpushed, false);
  await b.close();
});

test("a Task that continues a pull request works on its head branch, is told so, and pushes to it", async () => {
  const { root, bare } = origin();
  // The pull request's head branch, one commit past main.
  const seed = join(root, "seed");
  git(seed, "checkout", "-b", "feature/x");
  writeFileSync(join(seed, "README.md"), "hello pr\n");
  git(seed, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-am", "pr work");
  git(seed, "push", "origin", "HEAD:feature/x");
  const prStart = { ...start("feature/x"), repo: { ...start("feature/x").repo, pull_request: 7 } };
  assert.equal(repoOf(prStart)!.pull_request, 7);

  const b = new Rig();
  coding(b, root);
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async (r: Json) => (r.method === "task.hello" ? {} : { seq: 2 }));
  const { session } = await tasks.handle("salix", { method: "task.invite", task: "cnv_pr", start: prStart });
  await tasks.handle("salix", { method: "task.put", task: "cnv_pr", messages: [{ seq: 1, author: { kind: "person", id: "ann@example.com" }, text: "fix the review", declared: null, at: 0 }], through: 1 });
  await settle();
  const workspace = b.store.getSession(session)!.workspace;
  await b.hub.coding!.checkout(session, workspace, repoOf(prStart)!);
  await settle();
  assert.equal(readFileSync(join(workspace, "README.md"), "utf8"), "hello pr\n", "goes on from the pull request's branch");
  assert.match(b.claude.last().options.instructions, /feature\/x is the head branch of pull request #7: what you push to it updates that pull request/);

  writeFileSync(join(workspace, "README.md"), "hello review\n");
  git(workspace, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-am", "address review");
  b.claude.last().complete();
  await settle();
  assert.equal(await b.hub.coding!.pushed(workspace), true);
  assert.equal(git(bare, "rev-parse", "feature/x"), git(workspace, "rev-parse", "HEAD"));
  await b.close();
});

test("task.diff, task.save and task.pull_request answer about the Session's worktree", async () => {
  const { root, bare } = origin();
  const b = new Rig();
  const c = coding(b, root);
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async (r: Json) => (r.method === "task.hello" ? {} : { seq: 2 }));
  const { session } = await tasks.handle("salix", { method: "task.invite", task: "cnv_2", start: start("comma/t2") });
  const workspace = b.store.getSession(session)!.workspace;
  await c.checkout(session, workspace, repoOf(start("comma/t2"))!);

  writeFileSync(join(workspace, "README.md"), "hello\nmore\n");
  writeFileSync(join(workspace, "new.txt"), "a\nb\n");
  const diff = await tasks.handle("salix", { method: "task.diff", task: "cnv_2" });
  assert.equal(diff.base, "main");
  assert.equal(diff.branch, "comma/t2");
  const files = Object.fromEntries(diff.files.map((f: Json) => [f.path, f]));
  assert.equal(files["README.md"].status, "modified");
  assert.equal(files["README.md"].additions, 1);
  assert.match(files["README.md"].patch, /\+more/);
  assert.equal(files["new.txt"].status, "added");
  assert.equal(files["new.txt"].additions, 2);

  // Saved: committed as work in progress and pushed.
  const saved = await tasks.handle("salix", { method: "task.save", task: "cnv_2" });
  assert.deepEqual(saved, { dirty: false, unpushed: false });
  assert.match(git(bare, "log", "-1", "--format=%s", "comma/t2"), /Work in progress/);

  // A pull request, through gh.
  const bin = mkdtempSync(join(tmpdir(), "gh-"));
  writeFileSync(join(bin, "gh"), `#!/bin/sh\nif [ "$2" = view ]; then exit 1; fi\nif [ "$1" = api ]; then echo '[]'; exit 0; fi\necho "$@" > ${join(bin, "args")}\necho https://github.com/acme/api/pull/7\n`);
  chmodSync(join(bin, "gh"), 0o755);
  const path = process.env.PATH;
  process.env.PATH = `${bin}:${path}`;
  try {
    const pr = await tasks.handle("salix", { method: "task.pull_request", task: "cnv_2", title: "Fix it", draft: true });
    assert.deepEqual(pr, { url: "https://github.com/acme/api/pull/7", number: 7, title: "Fix it" });
    const args = readFileSync(join(bin, "args"), "utf8");
    assert.match(args, /pr create --repo acme\/api --head comma\/t2 --base main --title Fix it/);
    assert.match(args, /--draft/);
  } finally {
    process.env.PATH = path;
  }
  // With a pull request open on the branch, asking for one answers it: gh opens no second.
  const seen = mkdtempSync(join(tmpdir(), "gh-"));
  writeFileSync(
    join(seen, "gh"),
    `#!/bin/sh\nif [ "$2" = view ]; then echo '{"url":"https://github.com/acme/api/pull/7","number":7,"title":"Fix it","state":"OPEN","isDraft":true,"mergeable":"CONFLICTING","statusCheckRollup":[]}'; exit 0; fi\necho created > ${join(seen, "created")}\nexit 1\n`,
  );
  chmodSync(join(seen, "gh"), 0o755);
  process.env.PATH = `${seen}:${path}`;
  try {
    const again = await tasks.handle("salix", { method: "task.pull_request", task: "cnv_2", title: "Fix it again" });
    assert.deepEqual(again, { url: "https://github.com/acme/api/pull/7", number: 7, title: "Fix it" });
    assert.equal(existsSync(join(seen, "created")), false);
  } finally {
    process.env.PATH = path;
  }
  // The branch's last commit is another pull request's head (the Task continues #51): that one is answered, open, and a
  // merged one is not proposed again.
  const head = git(bare, "rev-parse", "comma/t2");
  const carried = (state: string) =>
    JSON.stringify([
      { html_url: "https://github.com/acme/api/pull/50", number: 50, title: "Moved past", state: "open", head: { sha: "0".repeat(40), ref: "claude/old" } },
      {
        html_url: "https://github.com/acme/api/pull/51",
        number: 51,
        title: "Cards",
        state,
        merged_at: state === "closed" ? "2026-10-23T10:00:00Z" : null,
        head: { sha: head, ref: "claude/cards" },
      },
    ]);
  const other = mkdtempSync(join(tmpdir(), "gh-"));
  process.env.PATH = `${other}:${path}`;
  try {
    for (const state of ["open", "closed"]) {
      writeFileSync(
        join(other, "gh"),
        `#!/bin/sh\nif [ "$2" = view ]; then exit 1; fi\nif [ "$1" = api ] && [ "$2" = repos/acme/api/commits/${head}/pulls ]; then echo '${carried(state)}'; exit 0; fi\necho created > ${join(other, "created")}\nexit 1\n`,
      );
      chmodSync(join(other, "gh"), 0o755);
      const asked = tasks.handle("salix", { method: "task.pull_request", task: "cnv_2", title: "Cards again" });
      if (state === "open") assert.deepEqual(await asked, { url: "https://github.com/acme/api/pull/51", number: 51, title: "Cards" });
      else await assert.rejects(asked, /merged already, in #51/);
    }
    // Where GitHub cannot say, none is opened: it could be a second beside #51.
    writeFileSync(join(other, "gh"), `#!/bin/sh\nif [ "$2" = view ]; then exit 1; fi\nif [ "$1" = api ]; then exit 1; fi\necho created > ${join(other, "created")}\nexit 1\n`);
    await assert.rejects(tasks.handle("salix", { method: "task.pull_request", task: "cnv_2" }), /could not say/);
    assert.equal(existsSync(join(other, "created")), false);
  } finally {
    process.env.PATH = path;
  }
  await assert.rejects(tasks.handle("salix", { method: "task.diff", task: "cnv_9" }), /no coding session/);
  await b.close();
});

test("task.diff lists the branch's commits and reads one commit, or what is not committed, alone", async () => {
  const { root } = origin();
  const b = new Rig();
  const c = coding(b, root);
  const tasks = new Tasks(b.hub, () => null);
  b.hub.setTasks(tasks);
  tasks.attachHost("salix", async (r: Json) => (r.method === "task.hello" ? {} : { seq: 2 }));
  const { session } = await tasks.handle("salix", { method: "task.invite", task: "cnv_3", start: start("comma/t3") });
  const workspace = b.store.getSession(session)!.workspace;
  await c.checkout(session, workspace, repoOf(start("comma/t3"))!);

  writeFileSync(join(workspace, "README.md"), "hello\ncommitted\n");
  git(workspace, "commit", "-am", "Say more in the README");
  writeFileSync(join(workspace, "draft.txt"), "x\n");

  const all = await tasks.handle("salix", { method: "task.diff", task: "cnv_3" });
  assert.deepEqual(all.commits.map((k: Json) => [k.title, k.author]), [["Say more in the README", "t"]]);
  assert.equal(all.uncommitted, true);
  assert.deepEqual(all.files.map((f: Json) => f.path).sort(), ["README.md", "draft.txt"]);

  const sha = all.commits[0].sha;
  const one = await tasks.handle("salix", { method: "task.diff", task: "cnv_3", commit: sha });
  assert.deepEqual(one.files.map((f: Json) => f.path), ["README.md"]);
  assert.match(one.files[0].patch, /\+committed/);

  const open = await tasks.handle("salix", { method: "task.diff", task: "cnv_3", uncommitted: true });
  assert.deepEqual(open.files.map((f: Json) => f.path), ["draft.txt"]);

  // Only the branch's own commits are read, named in full.
  const first = git(workspace, "rev-list", "--max-parents=0", "HEAD");
  await assert.rejects(tasks.handle("salix", { method: "task.diff", task: "cnv_3", commit: first }), /not one of the session branch's/);
  await assert.rejects(tasks.handle("salix", { method: "task.diff", task: "cnv_3", commit: sha.slice(0, 7) }), /full sha/);
  await b.close();
});

test("a new sandbox of the Task goes on from the branch the last one pushed", async () => {
  const { root, bare } = origin();
  const first = new Rig();
  const c1 = coding(first, root);
  const w1 = join(first.dir, "sessions", "a", "workspace");
  mkdirSync(w1, { recursive: true });
  await c1.checkout("s1", w1, repoOf(start("comma/t3"))!);
  writeFileSync(join(w1, "x.txt"), "x\n");
  await c1.save(w1);

  const second = new Rig();
  const c2 = coding(second, root);
  const w2 = join(second.dir, "sessions", "b", "workspace");
  mkdirSync(w2, { recursive: true });
  await c2.checkout("s2", w2, repoOf(start("comma/t3"))!);
  assert.equal(readFileSync(join(w2, "x.txt"), "utf8"), "x\n");
  assert.equal(git(w2, "rev-parse", "HEAD"), git(bare, "rev-parse", "comma/t3"));
  assert.deepEqual(await c2.standing(w2), { dirty: false, unpushed: false });
  await first.close();
  await second.close();
});

test("git and gh present the sandbox's proxy token, which replaces a token an older sandbox left", async () => {
  const dir = mkdtempSync(join(tmpdir(), "coding-token-"));
  writeFileSync(join(dir, "given"), "sbxgh_given\n");
  mkdirSync(join(dir, "gh"));
  writeFileSync(join(dir, "gh", "hosts.yml"), "github.com:\n    oauth_token: ghu_old\n");
  const c = new Coding({ reposDir: dir, givenToken: join(dir, "given"), ghConfigDir: join(dir, "gh") });
  assert.equal(c.begin(), true);
  const hosts = readFileSync(join(dir, "gh", "hosts.yml"), "utf8");
  assert.match(hosts, /oauth_token: sbxgh_given/);
  assert.doesNotMatch(hosts, /ghu_old/);
  assert.equal(statSync(join(dir, "gh", "hosts.yml")).mode & 0o777, 0o600);
  // git's credential helper reads the file on each use.
  const out = execFileSync("sh", ["-c", `git -c credential.helper= -c 'credential.https://github.com.helper=${c.helper()}' credential fill`], {
    input: "protocol=https\nhost=github.com\n\n",
    env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
    encoding: "utf8",
  });
  assert.match(out, /password=sbxgh_given/);
  // No token given: not a coding sandbox.
  assert.equal(new Coding({ reposDir: dir, givenToken: join(dir, "none") }).begin(), false);
});

test("name-status and numstat become file changes, renames included", () => {
  const names = ["M", "a.txt", "R100", "old.txt", "new.txt", "D", "gone.txt", ""].join("\0");
  const counts = ["3\t1\ta.txt", "0\t0\t", "old.txt", "new.txt", "0\t5\tgone.txt", ""].join("\0");
  assert.deepEqual(parseChanges(names, counts), [
    { path: "a.txt", status: "modified", additions: 3, deletions: 1, patch: null },
    { path: "new.txt", status: "renamed", additions: 0, deletions: 0, patch: null },
    { path: "gone.txt", status: "deleted", additions: 0, deletions: 5, patch: null },
  ]);
});
