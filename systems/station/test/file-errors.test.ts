// What the agent is told when the station could not use a file (src/ops/files.ts, connector.ts requestReply). An
// error stays as the file system said it. Only an EPERM from a call macOS privacy protection gates, in Desktop,
// Documents or Downloads on a Mac, adds that protection as a possible cause, with where the user may allow access and
// the computer's screen link. A read there that has not finished in FOLDER_PROMPT_WAIT says only that, with its
// possible causes: for the app's station a permission prompt to look for, or slow I/O; for a launchd station slow I/O.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { closeSync, constants, mkdirSync, openSync, writeFileSync, writeSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { Duration, Effect } from "effect";
import { FOLDER_PROMPT_WAIT, type Message, SCOPE_LOCAL_FILE_READ, makeConnector } from "../src/connector/connector.ts";
import { fileErrorMessage, slowFolderReadMessage, withFolderDenialHint } from "../src/ops/files.ts";
import { eventually } from "./connector/support/eventually.ts";
import { tempDir } from "./connector/support/temp.ts";

const MACOS = process.platform === "darwin";
const HOME = "/Users/me";
// As the launcher starts Node. COMMA_APP_PID, which the app sets, picks the app's hint.
const app = {
  argv: ["node", "main.js", "run", "--app", "/Applications/Comma Staging.app/Contents/Resources/native/station", "--data", "/d"],
  env: { COMMA_APP_PID: "4242" },
  deviceId: "dev_1",
  home: HOME,
};
const installed = { argv: ["node", "main.js", "run", "--app", "/Users/me/.comma-station/app", "--data", "/d"], env: {}, deviceId: "dev_1", home: HOME };
const SCREEN = "\ncomma:screen/dev_1/display\n";

function fsError(code: string, path: string, syscall = "scandir"): Error {
  return Object.assign(new Error(`${code}: operation not permitted, ${syscall} '${path}'`), { code, path, syscall });
}

test("on macOS an EPERM listing Documents adds privacy protection as a possible cause, for the app under Files and Folders", { skip: !MACOS }, () => {
  const error = fsError("EPERM", `${HOME}/Documents`);
  const said = fileErrorMessage("en", error, app);
  assert.ok(said.startsWith(`${error.message}. `), said);
  assert.ok(said.includes("possible cause"), said);
  assert.ok(said.includes("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"), said);
  assert.ok(said.includes("under Comma Staging"), said);
  assert.ok(said.endsWith(SCREEN), said);
  // Before Salix said which device this is, there is no screen to link.
  assert.ok(!fileErrorMessage("en", error, { ...app, deviceId: undefined }).includes("comma:screen"));
});

test("on macOS a launchd station's EPERM there names Full Disk Access for its comma-station", { skip: !MACOS }, () => {
  const said = fileErrorMessage("en", fsError("EPERM", `${HOME}/Downloads/a.pdf`, "open"), installed);
  assert.ok(said.includes("Privacy_AllFiles"), said);
  assert.ok(said.includes("/Users/me/.comma-station/app/mesh/target/release/comma-station"), said);
  assert.ok(!said.includes("Files and Folders"), said);
});

test("an EPERM outside those folders, from a call privacy protection does not gate, an EACCES, or one without a path stays as it was", () => {
  for (const error of [
    fsError("EPERM", `${HOME}/Projects/x`),
    fsError("EPERM", `${HOME}/Documents/x`, "chmod"),
    fsError("EACCES", `${HOME}/Documents/x`),
    Object.assign(new Error("EPERM: operation not permitted"), { code: "EPERM" }),
  ])
    assert.equal(fileErrorMessage("en", error, app), error.message);
});

test("a real EPERM, writing an immutable file, is the file system's error and nothing more", { skip: !MACOS && "chflags uchg is macOS's" }, async () => {
  const root = tempDir();
  const locked = join(root, "locked.txt");
  writeFileSync(locked, "kept");
  execFileSync("chflags", ["uchg", locked]);
  const c = makeConnector({ name: "locked", root, env: { HOME: root, PATH: "/usr/bin:/bin" } });
  const replies: Message[] = [];
  const session = c.claimConnection((m) => Effect.sync(() => void replies.push(m)), { onClose: () => {}, deadlineMs: () => 60_000 });
  try {
    assert.ok(session.startRequest({ id: "w", type: "request", method: "write", params: { path: "locked.txt", content: "changed" } }));
    await eventually(() => replies.length === 1, "the write's answer");
    assert.equal(replies[0]!.type, "error");
    assert.match(replies[0]!.error!, /^write: EPERM: operation not permitted, open '.*locked\.txt'$/);
  } finally {
    execFileSync("chflags", ["nouchg", locked]);
    await Effect.runPromise(c.close());
  }
});

test("off macOS an EPERM in Documents stays as the file system said it", { skip: MACOS }, () => {
  const eperm = fsError("EPERM", `${HOME}/Documents`);
  assert.equal(fileErrorMessage("en", eperm, app), eperm.message);
});

test("a slow read says it has not finished: the app's station may have a prompt to look for, else slow I/O", () => {
  const said = slowFolderReadMessage("en", `${HOME}/Documents`, 5, app);
  assert.ok(said.includes("has not finished in 5 seconds"), said);
  assert.ok(said.includes("if a prompt for Comma Staging is showing"), said);
  assert.ok(said.includes("if not, offer to wait or try again"), said);
  assert.ok(said.endsWith(SCREEN), said);
});

test("a launchd station's slow read is slow I/O: no prompt to wait for, Full Disk Access only as a possible cause", () => {
  const said = slowFolderReadMessage("en", `${HOME}/Documents`, 5, installed);
  assert.ok(said.includes("has not finished in 5 seconds"), said);
  assert.ok(said.includes("no macOS permission prompt"), said);
  assert.ok(!said.includes("is showing") && !said.includes("allow it"), said);
  assert.ok(said.includes("possible cause") && said.includes("Full Disk Access"), said);
  assert.ok(!said.includes("comma:screen"), said);
});

/** A read the connector serves in `home`'s Documents, held as macOS holds one while its prompt is unanswered (a FIFO). */
function heldRead(home: string) {
  mkdirSync(join(home, "Documents"));
  const path = join(home, "Documents", "held");
  execFileSync("mkfifo", ["-m", "600", path]);
  const c = makeConnector({ name: "held", root: home, env: { HOME: home, PATH: "/usr/bin:/bin" }, testClock: true });
  const replies: Message[] = [];
  const session = c.claimConnection((m) => Effect.sync(() => void replies.push(m)), { onClose: () => {}, deadlineMs: () => 600_000 });
  c.setIdentity(session, { runId: "run-1", deviceId: "dev_1" });
  assert.ok(session.startRequest({ id: "held-read", type: "request", method: "read", params: { path: "Documents/held" } }));
  const release = () => {
    const fd = openSync(path, constants.O_WRONLY);
    writeSync(fd, "allowed");
    closeSync(fd);
  };
  return { c, path, replies, release };
}

test("on macOS a read in Documents that has not finished is answered with that, its possible causes and the screen", { skip: !MACOS }, async () => {
  const home = tempDir();
  const { c, path, replies, release } = heldRead(home);
  try {
    await Effect.runPromise(c.advanceClockForTest(FOLDER_PROMPT_WAIT));
    await eventually(() => replies.length === 1, "the held read's answer");
    assert.equal(replies[0]!.type, "error");
    // The test's own process has no --app: the hint is the app's.
    assert.equal(replies[0]!.error, `read: ${slowFolderReadMessage("zh", path, 5, { deviceId: "dev_1", home })}`);
    assert.ok(replies[0]!.error!.endsWith(SCREEN));
  } finally {
    release();
    await Effect.runPromise(c.close());
  }
});

test("off macOS such a read waits as any other", { skip: MACOS || process.platform === "win32" }, async () => {
  const { c, replies, release } = heldRead(tempDir());
  try {
    await Effect.runPromise(c.advanceClockForTest(FOLDER_PROMPT_WAIT));
    assert.equal(replies.length, 0);
    release();
    await eventually(() => replies.length === 1, "the released read's answer");
    assert.equal(replies[0]!.type, "response");
  } finally {
    await Effect.runPromise(c.close());
  }
});

const failed = (stderr: string, stdout = "", exit_code = 1) => ({ exit_code, stdout, stderr });

test("on macOS a command's Operation not permitted on a protected folder says what is missing and where to allow it", { skip: !MACOS }, () => {
  const line = `ls: ${HOME}/Downloads: Operation not permitted\n`;
  const said = withFolderDenialHint("en", failed(line), HOME, app);
  assert.equal(said.exit_code, 1);
  assert.ok(said.stderr.startsWith(line), said.stderr);
  assert.ok(said.stderr.includes(`${HOME}/Downloads is in a folder macOS protects`), said.stderr);
  // The words prove no cause (a command can print them): privacy protection is only a possible one.
  assert.ok(said.stderr.includes("possible cause"), said.stderr);
  assert.ok(said.stderr.includes("Privacy_FilesAndFolders"), said.stderr);
  assert.ok(said.stderr.includes("under Comma Staging"), said.stderr);
  assert.ok(said.stderr.endsWith(SCREEN), said.stderr);
});

test("on macOS the tools' other ways of naming the path are read, relative to the command's directory", { skip: !MACOS }, () => {
  for (const [line, cwd] of [
    ["ls: Documents: Operation not permitted", HOME],
    ["ls: .: Operation not permitted", `${HOME}/Desktop/a`],
    [`sh: line 1: cd: ${HOME}/Documents/x y: Operation not permitted`, "/"],
    [`zsh:1: operation not permitted: ${HOME}/Desktop/x`, "/"],
    [`PermissionError: [Errno 1] Operation not permitted: '${HOME}/Documents'`, "/"],
    [`Error: EPERM: operation not permitted, scandir '${HOME}/Downloads'`, "/"],
    [`mv: rename a to ${HOME}/Documents/b: Operation not permitted`, "/"],
    ["rg: ~/Documents: Operation not permitted (os error 1)", "/"],
  ] as const)
    assert.ok(withFolderDenialHint("en", failed(line), cwd, app).stderr.includes("folder macOS protects"), line);
});

test("a command's output says so only with a clear sign: stdout only when it failed, never a mere non-zero exit", { skip: !MACOS }, () => {
  const denied = `ls: ${HOME}/Downloads: Operation not permitted`;
  // 2>&1 puts it on stdout; the command failed.
  assert.ok(withFolderDenialHint("en", failed("", denied), HOME, app).stderr.includes("folder macOS protects"));
  // A pipeline's exit is the last command's, and only stderr is the command's own say.
  assert.ok(withFolderDenialHint("en", failed(denied, "", 0), HOME, app).stderr.includes("folder macOS protects"));
  // A file that merely contains the words, and failures that do not say them.
  for (const result of [
    failed("", denied, 0),
    failed(`ls: ${HOME}/Downloads: No such file or directory`),
    failed("make: *** [all] Error 2"),
    failed(`chflags: ${HOME}/Projects/x: Operation not permitted`),
  ])
    assert.deepEqual(withFolderDenialHint("en", result, HOME, app), result);
});

test("off macOS a command's output is its own", { skip: MACOS }, () => {
  const result = failed(`ls: ${HOME}/Downloads: Operation not permitted`);
  assert.deepEqual(withFolderDenialHint("en", result, HOME, app), result);
});

function connectorIn(home: string, scope = "") {
  const c = makeConnector({ name: "shell", root: home, scope, env: { HOME: home, PATH: "/usr/bin:/bin" }, testClock: true });
  const replies: Message[] = [];
  const session = c.claimConnection((m) => Effect.sync(() => void replies.push(m)), { onClose: () => {}, deadlineMs: () => 600_000 });
  c.setIdentity(session, { runId: "run-1", deviceId: "dev_1" });
  return { c, replies, session };
}

test("on macOS an agent's shell command denied a protected folder comes back with the guidance and the screen link", { skip: !MACOS }, async () => {
  const home = tempDir();
  const { c, replies, session } = connectorIn(home);
  try {
    assert.ok(session.startRequest({ id: "e", type: "request", method: "exec", params: { command: `echo "ls: ${home}/Downloads: Operation not permitted" >&2; exit 1` } }));
    await eventually(() => replies.length === 1, "the command's answer");
    const result = replies[0]!.result as { exit_code: number; stderr: string };
    assert.equal(result.exit_code, 1);
    assert.ok(result.stderr.startsWith(`ls: ${home}/Downloads: Operation not permitted\n`), result.stderr);
    assert.ok(result.stderr.includes("Privacy_FilesAndFolders"), result.stderr);
    assert.ok(result.stderr.endsWith(SCREEN), result.stderr);
  } finally {
    await Effect.runPromise(c.close());
  }
});

test("on macOS a search from the home that macOS holds at a protected folder says so after the same wait", { skip: !MACOS }, async () => {
  const home = tempDir();
  const { c, replies, session } = connectorIn(home);
  c.setHooksForTest({ openFolder: (folder) => (folder === join(home, "Documents") ? new Promise(() => undefined) : Promise.resolve()) });
  try {
    assert.ok(session.startRequest({ id: "g", type: "request", method: "glob", params: { path: home, pattern: "*.txt" } }));
    await Effect.runPromise(c.advanceClockForTest(FOLDER_PROMPT_WAIT));
    await eventually(() => replies.length === 1, "the held search's answer");
    assert.equal(replies[0]!.type, "error");
    assert.equal(replies[0]!.error, `glob: ${slowFolderReadMessage("zh", join(home, "Documents"), 5, { deviceId: "dev_1", home })}`);
    assert.ok(replies[0]!.error!.endsWith(SCREEN));
  } finally {
    await Effect.runPromise(c.close());
  }
});

test("on macOS the protected folders share one wait: a slow first folder leaves the next the rest of it", { skip: !MACOS }, async () => {
  const home = tempDir();
  const { c, replies, session } = connectorIn(home);
  const opened: string[] = [];
  let desktopOpened = () => {};
  c.setHooksForTest({
    openFolder: (folder) => {
      opened.push(folder);
      if (folder === join(home, "Desktop")) return new Promise<void>((done) => (desktopOpened = done));
      return new Promise(() => undefined);
    },
  });
  try {
    assert.ok(session.startRequest({ id: "g", type: "request", method: "grep", params: { path: home, pattern: "x" } }));
    await eventually(() => opened.length === 1, "Desktop's open");
    await Effect.runPromise(c.advanceClockForTest(Duration.seconds(4)));
    assert.equal(replies.length, 0);
    desktopOpened();
    await eventually(() => opened.length === 2, "Documents' open");
    await Effect.runPromise(c.advanceClockForTest(Duration.seconds(1)));
    await eventually(() => replies.length === 1, "the held search's answer");
    assert.equal(replies[0]!.error, `grep: ${slowFolderReadMessage("zh", join(home, "Documents"), 5, { deviceId: "dev_1", home })}`);
    assert.deepEqual(opened, [join(home, "Desktop"), join(home, "Documents")]);
  } finally {
    await Effect.runPromise(c.close());
  }
});

test("a search the station refuses opens no folder", { skip: !MACOS }, async () => {
  const home = tempDir();
  const { c, replies, session } = connectorIn(home, SCOPE_LOCAL_FILE_READ);
  const opened: string[] = [];
  c.setHooksForTest({ openFolder: async (folder) => void opened.push(folder) });
  try {
    assert.ok(session.startRequest({ id: "g", type: "request", method: "glob", params: { path: home, pattern: "*" } }));
    await eventually(() => replies.length === 1, "the refusal");
    assert.match(replies[0]!.error!, /not permitted/);
    assert.deepEqual(opened, []);
  } finally {
    await Effect.runPromise(c.close());
  }
});

test("a search from the home that nothing holds gives its matches; off macOS the folders are not looked at", async () => {
  const home = tempDir();
  writeFileSync(join(home, "a.txt"), "x");
  const { c, replies, session } = connectorIn(home);
  const opened: string[] = [];
  c.setHooksForTest({ openFolder: async (folder) => void opened.push(folder) });
  try {
    assert.ok(session.startRequest({ id: "g", type: "request", method: "glob", params: { path: home, pattern: "a.txt" } }));
    await eventually(() => replies.length === 1, "the search's answer");
    assert.deepEqual((replies[0]!.result as { matches: string[] }).matches, ["/a.txt"]);
    assert.equal(opened.length, MACOS ? 3 : 0);
  } finally {
    await Effect.runPromise(c.close());
  }
});

test("a search that starts below the home does not open its protected folders", { skip: !MACOS }, async () => {
  const home = tempDir();
  mkdirSync(join(home, "Projects"));
  const { c, replies, session } = connectorIn(home);
  const opened: string[] = [];
  c.setHooksForTest({ openFolder: async (folder) => void opened.push(folder) });
  try {
    assert.ok(session.startRequest({ id: "g", type: "request", method: "glob", params: { path: join(home, "Projects"), pattern: "*" } }));
    await eventually(() => replies.length === 1, "the search's answer");
    assert.equal(replies[0]!.type, "response");
    assert.deepEqual(opened, []);
  } finally {
    await Effect.runPromise(c.close());
  }
});
