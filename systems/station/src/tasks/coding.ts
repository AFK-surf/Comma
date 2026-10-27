// Coding sessions: a Session that takes part in a Salix Task run on a coding sandbox (`start.repo`, docs/tasks.md)
// works in a checkout of a GitHub repository. The checkout is a git worktree, at the Session's own workspace, of a
// canonical clone kept in the station's repository cache (`<data>/repos/github.com/<owner>/<name>`), on the session
// branch, made from `base_ref` (or from the branch itself when it was pushed before: a new sandbox of the same Task
// goes on from what the last one pushed). The Session starts no turn until its checkout is made (Hub.prepare).
//
// The station keeps the session branch pushed: after each turn it pushes the commits the agent made. Salix asks it,
// over the Task's requests (tasks.ts), where the worktree stands (`dirty`, `unpushed`, with task.status), for its
// changes against the base (`task.diff`), to save it (`task.save`: commit what is not committed, push) before the
// sandbox is deleted, and to open a pull request (`task.pull_request`, with gh).
//
// The sandbox holds no GitHub token: its L4ES node's proxy does, and uses it for the Task's repository and branch only
// (l4h-sandbox DESIGN.md §31). git and gh present the sandbox's proxy token instead (/run/sbx/secrets/SBX_GITHUB_TOKEN,
// new with each start of the sandbox), which the git credential helper reads on each use and gh from its hosts file,
// never from a process's environment.
//
// A coding Session of a Task with a Mini App (`start.mini_app`) packs what its agent built for a deploy (`app_deploy`,
// tools/apps.ts): the agent builds; the station saves and pushes the worktree as task.save does, then packs from the
// worktree: the manifest `comma-app.json`, `bundle.tar` (dist/ as POSIX ustar, regular files only), `source.tar.gz`
// (git archive of HEAD), and `worker.js` (dist-worker/index.js) when the manifest names a backend.
import { execFile } from "node:child_process";
import { chmodSync, closeSync, copyFileSync, existsSync, lstatSync, mkdirSync, openSync, readdirSync, readFileSync, readSync, rmdirSync, statSync, writeFileSync, writeSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { log } from "../ops/log.ts";

type Json = any;

/// The repository a coding Session works in, as Salix gives it (`start.repo`).
/// `pull_request`: the open pull request whose head `branch` is, where the Task continues one (Salix checked it).
export type Repo = { owner: string; name: string; base_ref: string; branch: string; pull_request?: number };

/// A coding Session's worktree, kept beside its workspace (`<session home>/coding.json`).
export type Checkout = Repo & { worktree: string; clone: string };

/// Where a worktree stands: uncommitted changes, and commits not pushed to the session branch.
export type Standing = { dirty: boolean; unpushed: boolean };

/// One file of a diff.
export type FileChange = { path: string; status: string; additions: number; deletions: number; patch: string | null };

/// One commit of the session branch: its full sha, its subject line, its author's name, and when it was committed.
export type Commit = { sha: string; title: string; author: string; at: string };

/// The pull request of the session branch, as gh sees it: where it stands, whether it merges cleanly, and its checks.
export type PullRequestStatus = {
  url: string;
  number: number;
  title: string;
  state: "open" | "draft" | "merged" | "closed";
  mergeable: "mergeable" | "conflicting" | "unknown";
  checks: { passed: number; failed: number; total: number } | null;
};

/// At most this much patch text in a diff, and this many files: past them, the files are listed without patches.
export const DIFF_MAX_BYTES = 2 * 1024 * 1024;
export const DIFF_MAX_FILES = 1000;
/// At most this many of the branch's commits are listed with its changes, the newest.
export const DIFF_MAX_COMMITS = 100;
const GIT_TIMEOUT_MS = 10 * 60 * 1000;
const QUICK_TIMEOUT_MS = 30 * 1000;

const NAME = /^[A-Za-z0-9_.-]{1,100}$/;
const REF = /^(?!\/)(?!.*\.\.)(?!.*\/\/)[A-Za-z0-9._/-]{1,255}(?<!\/)(?<!\.lock)$/;
/// The conclusions of a check run that GitHub counts as passed.
const CHECK_PASSED = new Set(["SUCCESS", "NEUTRAL", "SKIPPED"]);

/// The repository a Task's `start` names, if it is well formed.
export function repoOf(start: Json): Repo | null {
  const r = start?.repo;
  if (r === null || typeof r !== "object") return null;
  const { owner, name, base_ref, branch, pull_request } = r;
  if (typeof owner !== "string" || !NAME.test(owner) || typeof name !== "string" || !NAME.test(name)) return null;
  if (typeof base_ref !== "string" || !REF.test(base_ref) || typeof branch !== "string" || !REF.test(branch)) return null;
  const carried = typeof pull_request === "number" && Number.isSafeInteger(pull_request) && pull_request > 0;
  return { owner, name, base_ref, branch, ...(carried ? { pull_request } : {}) };
}

export class CodingRefused extends Error {}

type Run = { stdout: string; stderr: string };

export type CodingOptions = {
  /// Where canonical clones are kept (`<data>/repos`).
  reposDir: string;
  /// The remote of `owner/name` (tests point it at local repositories).
  remote?: (owner: string, name: string) => string;
  /// Where L4ES gives the sandbox's proxy token.
  givenToken?: string;
  /// The `gh` configuration directory (`~/.config/gh`).
  ghConfigDir?: string;
};

export class Coding {
  private readonly options: CodingOptions;
  /// Checkouts being made, by Session.
  private readonly making = new Map<string, Promise<Checkout>>();
  /// Pushes, by worktree.
  private readonly pushing = new Map<string, Promise<boolean>>();

  constructor(options: CodingOptions) {
    this.options = options;
  }

  private remote(owner: string, name: string): string {
    return this.options.remote?.(owner, name) ?? `https://github.com/${owner}/${name}.git`;
  }

  // ── the token ────────────────────────────────────────────────────────────────────────────────────────────────────

  private get tokenFile(): string {
    return this.options.givenToken ?? "/run/sbx/secrets/SBX_GITHUB_TOKEN";
  }

  /// Makes gh use the sandbox's proxy token, if L4ES gave one (a sandbox with a GitHub grant). Whether it did.
  begin(): boolean {
    let token: string;
    try {
      token = readFileSync(this.tokenFile, "utf8").trim();
    } catch {
      return false;
    }
    if (token === "") return false;
    // Written at every start: the token is new with each, and a disk kept from an older sandbox may hold another.
    const gh = this.options.ghConfigDir ?? join(homedir(), ".config", "gh");
    mkdirSync(gh, { recursive: true, mode: 0o700 });
    writeFileSync(join(gh, "hosts.yml"), `github.com:\n    oauth_token: ${token}\n    git_protocol: https\n`, { mode: 0o600 });
    chmodSync(join(gh, "hosts.yml"), 0o600);
    return true;
  }

  /// The git identity commits are made with: the Task owner's, else the GitHub account's (COMMA_GIT_USER_NAME, COMMA_GIT_USER_EMAIL, given at
  /// the sandbox's creation).
  async identity(name: string | undefined, email: string | undefined): Promise<void> {
    if (name) await run("git", ["config", "--global", "user.name", name], homedir(), QUICK_TIMEOUT_MS);
    if (email) await run("git", ["config", "--global", "user.email", email], homedir(), QUICK_TIMEOUT_MS);
    // The agent's own git and gh use the token too.
    await run("git", ["config", "--global", "credential.https://github.com.helper", this.helper()], homedir(), QUICK_TIMEOUT_MS);
  }

  /// git's credential helper for github.com: it prints the proxy token. The command, for `credential.helper`.
  helper(): string {
    return `!f() { test "$1" = get || exit 0; echo username=x-access-token; printf 'password='; cat '${this.tokenFile}'; }; f`;
  }

  // ── git ──────────────────────────────────────────────────────────────────────────────────────────────────────────

  private git(cwd: string, args: string[], timeout = GIT_TIMEOUT_MS): Promise<Run> {
    return run("git", ["-c", `credential.https://github.com.helper=${this.helper()}`, ...args], cwd, timeout);
  }

  /// The checkout Session `session` works in, made into its workspace `workspace` the first time. Asked again while it
  /// is being made, the same one.
  checkout(session: string, workspace: string, repo: Repo): Promise<Checkout> {
    const made = this.making.get(session);
    if (made) return made;
    const making = this.make(session, workspace, repo).finally(() => this.making.delete(session));
    this.making.set(session, making);
    return making;
  }

  private async make(session: string, workspace: string, repo: Repo): Promise<Checkout> {
    const kept = this.get(workspace);
    if (kept !== null && existsSync(join(kept.worktree, ".git"))) return kept;
    const clone = join(this.options.reposDir, "github.com", repo.owner, repo.name);
    if (!existsSync(join(clone, ".git"))) {
      mkdirSync(dirname(clone), { recursive: true });
      // Blobless: every commit and tree now, file contents when a checkout, diff or blame needs them. History stays
      // whole, so merge-base, log and push work as in a full clone; a shallow one would break them.
      await this.git(dirname(clone), ["clone", "--filter=blob:none", "--no-checkout", this.remote(repo.owner, repo.name), clone]);
    }
    await this.git(clone, ["fetch", "--prune", "origin"]);
    // A branch pushed before (by an earlier sandbox of the Task) is where it goes on; else from the base.
    const pushed = await this.git(clone, ["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${repo.branch}`]).then(
      () => true,
      () => false,
    );
    const from = pushed ? `origin/${repo.branch}` : await this.baseRef(clone, repo.base_ref);
    // git worktree add takes an empty directory only if it is not there.
    if (existsSync(workspace) && readdirSync(workspace).length === 0) rmdirSync(workspace);
    await this.git(clone, ["worktree", "add", "--force", "-B", repo.branch, workspace, from]);
    if (pushed) await this.git(workspace, ["branch", "--set-upstream-to", `origin/${repo.branch}`]);
    const checkout: Checkout = { ...repo, worktree: workspace, clone };
    writeFileSync(join(dirname(workspace), "coding.json"), JSON.stringify(checkout));
    log.info("coding", "a coding session's checkout is made", { session, repo: `${repo.owner}/${repo.name}`, branch: repo.branch });
    return checkout;
  }

  /// `base_ref` as a revision: a remote branch, else a tag or commit.
  private async baseRef(clone: string, base: string): Promise<string> {
    const branch = await this.git(clone, ["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${base}`]).then(
      () => true,
      () => false,
    );
    if (branch) return `origin/${base}`;
    await this.git(clone, ["rev-parse", "--verify", "--quiet", `${base}^{commit}`]).catch(() => {
      throw new CodingRefused(`there is no branch, tag or commit ${base} in the repository`);
    });
    return base;
  }

  /// The checkout of the Session whose workspace is `workspace`, if it has one.
  get(workspace: string): Checkout | null {
    try {
      return JSON.parse(readFileSync(join(dirname(workspace), "coding.json"), "utf8")) as Checkout;
    } catch {
      return null;
    }
  }

  /// Where the worktree stands. Not a coding Session: null.
  async standing(workspace: string): Promise<Standing | null> {
    const c = this.get(workspace);
    if (c === null) return null;
    const status = await this.git(c.worktree, ["status", "--porcelain"], QUICK_TIMEOUT_MS);
    return { dirty: status.stdout.trim() !== "", unpushed: (await this.ahead(c)) > 0 };
  }

  /// Commits on the session branch that the remote branch does not have (all of them, before its first push).
  private async ahead(c: Checkout): Promise<number> {
    const upstream = await this.git(c.worktree, ["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${c.branch}`]).then(
      () => `origin/${c.branch}`,
      () => null,
    );
    const range = upstream !== null ? `${upstream}..HEAD` : `${await this.mergeBase(c)}..HEAD`;
    const count = await this.git(c.worktree, ["rev-list", "--count", range], QUICK_TIMEOUT_MS);
    return Number.parseInt(count.stdout.trim(), 10) || 0;
  }

  private async mergeBase(c: Checkout): Promise<string> {
    const base = await this.baseRef(c.clone, c.base_ref).catch(() => "HEAD");
    const mb = await this.git(c.worktree, ["merge-base", "HEAD", base], QUICK_TIMEOUT_MS).catch(() => null);
    return mb?.stdout.trim() || "HEAD";
  }

  /// Pushes the session branch if it has commits the remote does not. Whether it pushed. One push at a time per
  /// worktree: asked while one runs, it runs after it.
  push(workspace: string): Promise<boolean> {
    const before = this.pushing.get(workspace) ?? Promise.resolve(false);
    const next = before.catch(() => false).then(() => this.pushNow(workspace));
    this.pushing.set(workspace, next);
    return next;
  }

  /// The push of `workspace` running now, or the last one.
  pushed(workspace: string): Promise<boolean> {
    return this.pushing.get(workspace) ?? Promise.resolve(false);
  }

  private async pushNow(workspace: string): Promise<boolean> {
    const c = this.get(workspace);
    if (c === null || (await this.ahead(c)) === 0) return false;
    await this.git(c.worktree, ["push", "--set-upstream", "origin", `HEAD:refs/heads/${c.branch}`]);
    log.info("coding", "the session branch is pushed", { branch: c.branch });
    return true;
  }

  /// Commits what is not committed (as work in progress, or with `message`) and pushes. Before a sandbox is deleted,
  /// and before a Mini App deploy is packed.
  async save(workspace: string, message = "Work in progress, saved by Comma before the sandbox stopped"): Promise<Standing> {
    const c = this.get(workspace);
    if (c === null) throw new CodingRefused("this Session works in no repository");
    const status = await this.git(c.worktree, ["status", "--porcelain"], QUICK_TIMEOUT_MS);
    if (status.stdout.trim() !== "") {
      await this.git(c.worktree, ["add", "--all"]);
      await this.git(c.worktree, ["commit", "--no-verify", "-m", message]);
    }
    await this.push(workspace);
    return (await this.standing(workspace))!;
  }

  // ── Mini Apps ────────────────────────────────────────────────────────────────────────────────────────────────────

  /// Keeps the Mini App of the Task the Session of `workspace` takes part in (`start.mini_app`), beside its
  /// workspace, so it stays across a restart of the station.
  keepMiniApp(workspace: string, appId: string): void {
    mkdirSync(dirname(workspace), { recursive: true });
    writeFileSync(join(dirname(workspace), "mini_app.json"), JSON.stringify({ app_id: appId }));
  }

  /// The Mini App of the Task the Session of `workspace` takes part in, if it has one.
  miniApp(workspace: string): string | null {
    try {
      const kept = JSON.parse(readFileSync(join(dirname(workspace), "mini_app.json"), "utf8"));
      return typeof kept?.app_id === "string" && kept.app_id !== "" ? kept.app_id : null;
    } catch {
      return null;
    }
  }

  /// Saves and pushes the worktree (as `save`, with `message`), then packs what the agent built into `out` (made
  /// here): the files of a deploy, in order, and the commit they are of. The push finishes before anything is packed.
  /// Refused, with what to do, when the manifest or the build is missing.
  async packApp(workspace: string, out: string, message: string): Promise<{ commit: string; files: PackedFile[] }> {
    const c = this.get(workspace);
    if (c === null) throw new CodingRefused("this Session works in no repository");
    const standing = await this.save(workspace, message);
    if (standing.unpushed) throw new CodingRefused("Nothing was deployed: the session branch was not pushed.");
    const commit = (await this.git(c.worktree, ["rev-parse", "HEAD"], QUICK_TIMEOUT_MS)).stdout.trim();
    const manifestPath = join(c.worktree, "comma-app.json");
    let manifest: Json;
    try {
      manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    } catch (error) {
      const why =
        (error as NodeJS.ErrnoException).code === "ENOENT" ? "there is no comma-app.json at the repository root" : `comma-app.json is not valid JSON (${(error as Error).message})`;
      throw new CodingRefused(`Nothing was deployed: ${why}.`);
    }
    if (manifest === null || typeof manifest !== "object" || Array.isArray(manifest)) throw new CodingRefused("Nothing was deployed: comma-app.json is not a JSON object.");
    const index = join(c.worktree, "dist", "index.html");
    if (!existsSync(index) || !statSync(index).isFile()) {
      throw new CodingRefused("Nothing was deployed: dist/index.html is missing. Build the app first (see the repository's AGENTS.md), then deploy again.");
    }
    const worker = join(c.worktree, "dist-worker", "index.js");
    const backend = manifest.backend !== undefined && manifest.backend !== null;
    if (backend && !(existsSync(worker) && statSync(worker).isFile())) {
      throw new CodingRefused("Nothing was deployed: comma-app.json names a backend, but dist-worker/index.js is missing. Build the backend first, then deploy again.");
    }
    // Copies, so the agent changing its worktree while Salix reads the files does not change the deploy.
    mkdirSync(out, { recursive: true });
    const files: PackedFile[] = [];
    const add = (name: string) => files.push({ name, path: join(out, name), size: statSync(join(out, name)).size });
    copyFileSync(manifestPath, join(out, "comma-app.json"));
    add("comma-app.json");
    writeUstar(join(c.worktree, "dist"), join(out, "bundle.tar"));
    add("bundle.tar");
    await this.git(c.worktree, ["archive", "--format=tar.gz", "-o", join(out, "source.tar.gz"), "HEAD"]);
    add("source.tar.gz");
    if (backend) {
      copyFileSync(worker, join(out, "worker.js"));
      add("worker.js");
    }
    return { commit, files };
  }

  /// The session's changes, and the commits its branch has past its base (newest first, at most DIFF_MAX_COMMITS).
  /// Without a scope, everything against the base: committed and not, and new files. `uncommitted`: what is not
  /// committed yet, new files included. `commit`: what one of the branch's commits changed. The branch's pull request
  /// is Comma's to read from GitHub, sandbox or not.
  async diff(
    workspace: string,
    scope: { commit?: string; uncommitted?: boolean } = {},
  ): Promise<{ base: string; branch: string; files: FileChange[]; truncated: boolean; commits: Commit[]; uncommitted: boolean }> {
    const c = this.get(workspace);
    if (c === null) throw new CodingRefused("this Session works in no repository");
    const base = await this.mergeBase(c);
    const log = await this.git(
      c.worktree,
      ["log", `--max-count=${DIFF_MAX_COMMITS}`, "--format=%H%x1f%s%x1f%an%x1f%cI%x1e", `${base}..HEAD`],
      QUICK_TIMEOUT_MS,
    );
    const commits = parseCommits(log.stdout);
    const status = await this.git(c.worktree, ["status", "--porcelain"], QUICK_TIMEOUT_MS);
    const uncommitted = status.stdout.trim() !== "";
    if (scope.commit !== undefined && !commits.some((k) => k.sha === scope.commit)) {
      throw new CodingRefused("that commit is not one of the session branch's");
    }
    // What the diff compares, and whether new files count: they are not committed, so not in a commit's diff.
    const range = scope.commit !== undefined ? [`${scope.commit}^`, scope.commit] : [scope.uncommitted ? "HEAD" : base];
    const withNew = scope.commit === undefined;
    const numstat = await this.git(c.worktree, ["diff", "--numstat", "-z", "--find-renames", ...range], QUICK_TIMEOUT_MS);
    const names = await this.git(c.worktree, ["diff", "--name-status", "-z", "--find-renames", ...range], QUICK_TIMEOUT_MS);
    const files = parseChanges(names.stdout, numstat.stdout);
    if (withNew) {
      const untracked = await this.git(c.worktree, ["ls-files", "--others", "--exclude-standard", "-z"], QUICK_TIMEOUT_MS);
      for (const path of untracked.stdout.split("\0").filter((p) => p !== "")) {
        files.push({ path, status: "added", additions: 0, deletions: 0, patch: null });
      }
    }
    let bytes = 0;
    let truncated = files.length > DIFF_MAX_FILES;
    const shown = files.slice(0, DIFF_MAX_FILES);
    for (const f of shown) {
      if (bytes >= DIFF_MAX_BYTES) {
        truncated = true;
        break;
      }
      const patch =
        withNew && f.status === "added" && f.additions === 0 && f.deletions === 0
          ? await this.git(c.worktree, ["diff", "--no-index", "--", "/dev/null", f.path], QUICK_TIMEOUT_MS).catch((e: GitFailed) => e.run)
          : await this.git(c.worktree, ["diff", "--find-renames", ...range, "--", f.path], QUICK_TIMEOUT_MS);
      const text = patch.stdout;
      if (f.status === "added" && f.additions === 0) f.additions = text.split("\n").filter((l) => l.startsWith("+") && !l.startsWith("+++")).length;
      if (bytes + text.length > DIFF_MAX_BYTES) {
        truncated = true;
        continue;
      }
      bytes += text.length;
      f.patch = text;
    }
    return { base: c.base_ref, branch: c.branch, files: shown, truncated, commits, uncommitted };
  }

  /// The pull request of the session branch, through gh (`gh pr view`): null where there is none, or gh cannot say.
  /// A pull request asked for while one is open answers that one.
  async pullRequestStatus(c: Checkout): Promise<PullRequestStatus | null> {
    const shown = await run(
      "gh",
      ["pr", "view", c.branch, "--repo", `${c.owner}/${c.name}`, "--json", "url,number,title,state,isDraft,mergeable,statusCheckRollup"],
      c.worktree,
      QUICK_TIMEOUT_MS,
    ).catch(() => null);
    if (shown === null) return null;
    let pr: {
      url?: unknown;
      number?: unknown;
      title?: unknown;
      state?: unknown;
      isDraft?: unknown;
      mergeable?: unknown;
      statusCheckRollup?: unknown;
    };
    try {
      pr = JSON.parse(shown.stdout) as typeof pr;
    } catch {
      return null;
    }
    if (typeof pr.url !== "string" || typeof pr.number !== "number") return null;
    const state = pr.state === "MERGED" ? "merged" : pr.state === "CLOSED" ? "closed" : pr.isDraft === true ? "draft" : "open";
    const mergeable = pr.mergeable === "MERGEABLE" ? "mergeable" : pr.mergeable === "CONFLICTING" ? "conflicting" : "unknown";
    const title = typeof pr.title === "string" ? pr.title : "";
    // Check runs end with a conclusion; commit statuses carry a state. A run GitHub counts as passed (success, neutral,
    // skipped) passed; one that ended any other way failed; the rest are still running.
    const rollup = Array.isArray(pr.statusCheckRollup) ? (pr.statusCheckRollup as { conclusion?: unknown; state?: unknown }[]) : [];
    const passed = rollup.filter(
      (check) => (typeof check.conclusion === "string" && CHECK_PASSED.has(check.conclusion)) || check.state === "SUCCESS",
    );
    const failed = rollup.filter(
      (check) =>
        (typeof check.conclusion === "string" && check.conclusion !== "" && !CHECK_PASSED.has(check.conclusion)) ||
        check.state === "FAILURE" ||
        check.state === "ERROR",
    );
    const checks = rollup.length === 0 ? null : { passed: passed.length, failed: failed.length, total: rollup.length };
    return { url: pr.url, number: pr.number, title, state, mergeable, checks };
  }

  /// Pushes the session branch and opens a pull request into its base, or answers the one open already: the branch's
  /// own, or one of another head at the branch's last commit (a Task that continues a pull request), as Salix reads it.
  async pullRequest(
    workspace: string,
    request: { title?: string; body?: string; draft?: boolean },
  ): Promise<{ url: string; number: number | null; title: string }> {
    const c = this.get(workspace);
    if (c === null) throw new CodingRefused("this Session works in no repository");
    await this.push(workspace);
    const pushed = await this.git(c.worktree, ["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${c.branch}`]).catch(() => null);
    if (pushed === null) throw new CodingRefused("the session branch has no commits to propose");
    const repo = `${c.owner}/${c.name}`;
    const open = await this.pullRequestStatus(c);
    if (open !== null && (open.state === "open" || open.state === "draft")) {
      return { url: open.url, number: open.number, title: open.title };
    }
    const carried = await this.carriedPullRequest(c, pushed.stdout.trim());
    if (carried?.merged === false) return { url: carried.url, number: carried.number, title: carried.title };
    if (carried?.merged === true) throw new CodingRefused(`the branch's work is merged already, in #${carried.number}`);
    const title = request.title || (await this.title(c));
    const args = ["pr", "create", "--repo", repo, "--head", c.branch, "--base", c.base_ref, "--title", title];
    args.push("--body", request.body ?? "Opened from a Comma coding session.");
    if (request.draft) args.push("--draft");
    const made = await run("gh", args, c.worktree, QUICK_TIMEOUT_MS * 2).catch((e: GitFailed) => {
      throw new CodingRefused(`gh pr create failed: ${e.run.stderr.trim().slice(0, 300)}`);
    });
    const url = made.stdout.trim().split("\n").pop() ?? "";
    const number = Number.parseInt(url.split("/").pop() ?? "", 10);
    return { url, number: Number.isSafeInteger(number) ? number : null, title };
  }

  /// A pull request of another head whose head is `sha`, the branch's last commit: an open one, else a merged one.
  /// Null where none is. Where gh cannot say, it refuses: opening one then could put a second beside it.
  private async carriedPullRequest(
    c: Checkout,
    sha: string,
  ): Promise<{ url: string; number: number; title: string; merged: boolean } | null> {
    const unknown = new CodingRefused("GitHub could not say whether another pull request already proposes the branch");
    const listed = await run("gh", ["api", `repos/${c.owner}/${c.name}/commits/${sha}/pulls`], c.worktree, QUICK_TIMEOUT_MS).catch(() => {
      throw unknown;
    });
    let pulls: unknown;
    try {
      pulls = JSON.parse(listed.stdout);
    } catch {
      throw unknown;
    }
    if (!Array.isArray(pulls)) throw unknown;
    type Listed = { html_url?: unknown; number?: unknown; title?: unknown; state?: unknown; merged_at?: unknown; head?: { sha?: unknown; ref?: unknown } };
    const carried = (pulls as Listed[]).filter(
      (pr) => pr.head?.sha === sha && pr.head?.ref !== c.branch && typeof pr.html_url === "string" && typeof pr.number === "number",
    );
    const pr = carried.find((p) => p.state === "open") ?? carried.find((p) => typeof p.merged_at === "string");
    if (pr === undefined) return null;
    return { url: pr.html_url as string, number: pr.number as number, title: typeof pr.title === "string" ? pr.title : "", merged: pr.state !== "open" };
  }

  /// A pull request's title: the session branch's first commit subject.
  private async title(c: Checkout): Promise<string> {
    const base = await this.mergeBase(c);
    const log = await this.git(c.worktree, ["log", "--reverse", "--format=%s", `${base}..HEAD`], QUICK_TIMEOUT_MS).catch(() => null);
    return log?.stdout.split("\n").find((l) => l.trim() !== "")?.trim() || c.branch;
  }
}

/// A file packed for a deploy: its name in the request, where it is, and its size.
export type PackedFile = { name: string; path: string; size: number };

/// Writes the regular files under `root` (symbolic links and the rest left out, in path order) into `out` as a POSIX
/// ustar archive, paths relative to `root`. Streamed a part at a time: no file is held in memory whole.
export function writeUstar(root: string, out: string): void {
  const paths: string[] = [];
  const walk = (rel: string) => {
    for (const name of readdirSync(join(root, rel)).sort()) {
      const path = rel === "" ? name : `${rel}/${name}`;
      const stat = lstatSync(join(root, path));
      if (stat.isDirectory()) walk(path);
      else if (stat.isFile()) paths.push(path);
    }
  };
  walk("");
  const fd = openSync(out, "w");
  const buffer = Buffer.alloc(1024 * 1024);
  try {
    for (const path of paths) {
      const input = openSync(join(root, path), "r");
      try {
        const size = statSync(join(root, path)).size;
        writeSync(fd, ustarHeader(path, size));
        let written = 0;
        for (let read = 1; written < size && read > 0; written += read) {
          read = readSync(input, buffer, 0, Math.min(buffer.length, size - written), written);
          writeSync(fd, buffer, 0, read);
        }
        if (written !== size) throw new Error(`dist/${path} changed while it was packed`);
        if (size % 512 !== 0) writeSync(fd, Buffer.alloc(512 - (size % 512)));
      } finally {
        closeSync(input);
      }
    }
    writeSync(fd, Buffer.alloc(1024));
  } finally {
    closeSync(fd);
  }
}

/// A ustar header of a regular file (mode 0644, owner 0, mtime 0: the same build packs to the same bytes).
function ustarHeader(path: string, size: number): Buffer {
  const header = Buffer.alloc(512);
  const bytes = Buffer.from(path, "utf8");
  let name = bytes;
  let prefix = Buffer.alloc(0);
  if (bytes.length > 100) {
    // Split at a slash: the prefix holds up to 155 bytes, the name up to 100.
    let cut = -1;
    for (let i = Math.min(155, bytes.length - 2); i > 0; i--) {
      if (bytes[i] === 0x2f && bytes.length - i - 1 <= 100) {
        cut = i;
        break;
      }
    }
    if (cut < 0) throw new CodingRefused(`Nothing was deployed: the path dist/${path} is too long for the bundle.`);
    prefix = bytes.subarray(0, cut);
    name = bytes.subarray(cut + 1);
  }
  const octal = (value: number, width: number) => value.toString(8).padStart(width - 1, "0") + "\0";
  name.copy(header, 0);
  header.write(octal(0o644, 8), 100, "ascii");
  header.write(octal(0, 8), 108, "ascii");
  header.write(octal(0, 8), 116, "ascii");
  header.write(octal(size, 12), 124, "ascii");
  header.write(octal(0, 12), 136, "ascii");
  header.write("        ", 148, "ascii");
  header.write("0", 156, "ascii");
  header.write("ustar\0", 257, "ascii");
  header.write("00", 263, "ascii");
  prefix.copy(header, 345);
  let sum = 0;
  for (const byte of header) sum += byte;
  header.write(sum.toString(8).padStart(6, "0") + "\0 ", 148, "ascii");
  return header;
}

class GitFailed extends Error {
  readonly run: Run;
  constructor(command: string, run: Run, code: unknown) {
    super(`${command} failed (${String(code)}): ${run.stderr.trim().slice(0, 500)}`);
    this.run = run;
  }
}

function run(command: string, args: string[], cwd: string, timeout: number): Promise<Run> {
  return new Promise((resolve, reject) => {
    execFile(
      command,
      args,
      { cwd, timeout, maxBuffer: 64 * 1024 * 1024, env: { ...process.env, GIT_TERMINAL_PROMPT: "0", GH_PROMPT_DISABLED: "1" } },
      (error, stdout, stderr) => {
        const result = { stdout: String(stdout), stderr: String(stderr) };
        if (error) reject(new GitFailed(`${command} ${args[args.length > 4 ? 4 : 0] ?? ""}`, result, (error as NodeJS.ErrnoException).code));
        else resolve(result);
      },
    );
  });
}

/// `git log --format=%H%x1f%s%x1f%an%x1f%cI%x1e`, as commits.
export function parseCommits(log: string): Commit[] {
  return log
    .split("\x1e")
    .map((record) => record.trim())
    .filter((record) => record !== "")
    .map((record) => {
      const [sha = "", title = "", author = "", at = ""] = record.split("\x1f");
      return { sha, title, author, at };
    });
}

/// `git diff --name-status -z` and `--numstat -z`, as file changes.
export function parseChanges(nameStatus: string, numstat: string): FileChange[] {
  const statuses: Record<string, string> = { A: "added", M: "modified", D: "deleted", R: "renamed", C: "copied", T: "modified" };
  const files: FileChange[] = [];
  const parts = nameStatus.split("\0");
  for (let i = 0; i < parts.length && parts[i] !== ""; ) {
    const code = parts[i]!;
    const renamed = code.startsWith("R") || code.startsWith("C");
    const path = renamed ? parts[i + 2]! : parts[i + 1]!;
    files.push({ path, status: statuses[code[0]!] ?? "modified", additions: 0, deletions: 0, patch: null });
    i += renamed ? 3 : 2;
  }
  const counts = numstat.split("\0");
  let k = 0;
  for (let i = 0; i < counts.length && counts[i] !== ""; ) {
    const [add, del, path] = counts[i]!.split("\t");
    // A rename is `add\tdel\t` followed by the old and new paths.
    const step = path === "" ? 3 : 1;
    const file = files[k++];
    if (file) {
      file.additions = Number.parseInt(add ?? "0", 10) || 0;
      file.deletions = Number.parseInt(del ?? "0", 10) || 0;
    }
    i += step;
  }
  return files;
}
