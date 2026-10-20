// Ported from systems/connector/salix-connect/main_test.go: workspace archives (same test names), plus the build info
// test from the same file.
// An archive keeps executable links that stay inside the root, native files, git metadata and user data, skips
// regenerable caches, and refuses an external or dangling link instead of omitting it.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, lstatSync, mkdirSync, readFileSync, readlinkSync, rmSync, symlinkSync, truncateSync, unlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { Effect, Exit } from "effect";
import { restoreTarGz, writeTarGz } from "../../src/connector/archive.ts";
import { currentBuildInfo, makeConnector } from "../../src/connector/connector.ts";
import { tarGzNames } from "./support/tar.ts";
import { tempDir } from "./support/temp.ts";

const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect);
const put = (path: string, content: string, mode = 0o600) => {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  writeFileSync(path, content, { mode });
};
const archiveOf = (root: string) => run(writeTarGz(root));
const archiveFails = async (root: string) => Exit.isFailure(await Effect.runPromiseExit(writeTarGz(root)));

test("TestCurrentBuildInfoPublishesDiagnosticReleaseWithoutTargetRevision", () => {
  const info = JSON.parse(JSON.stringify(currentBuildInfo({ releaseId: "server-bound-test" })));
  assert.equal(info.release_id, "server-bound-test");
  assert.ok(!("target_revision" in info), "binary metadata kept target_revision");
});

test("TestManagedArchivePreservesExecutableLinksAndNativeFiles", { skip: process.platform === "win32" && "a Cloud VM's archive (Linux): executable scripts and links" }, async () => {
  const root = tempDir();
  put(join(root, "home/packages/cli/run"), "#!/bin/sh\nprintf restored", 0o700);
  symlinkSync("cli/run", join(root, "home/packages/cli-command"));
  put(join(root, "home/native-history.json"), '{"session":"retained"}');
  const restored = tempDir();
  await run(restoreTarGz(await archiveOf(root), restored));
  assert.equal(execFileSync(join(restored, "home/packages/cli-command")).toString(), "restored", "the restored CLI link does not run");
  assert.equal(readFileSync(join(restored, "home/native-history.json"), "utf8"), '{"session":"retained"}');
  const outside = tempDir();
  symlinkSync(outside, join(root, "external"));
  assert.ok(await archiveFails(root), "the archive omitted an external link instead of failing");
  unlinkSync(join(root, "external"));
  symlinkSync(join(outside, "absent"), join(root, "external"));
  assert.ok(await archiveFails(root), "the archive accepted an absent external link target");
});

test("a restore takes the paths a started station seeded: a different link or a file, and a link where a file goes", async () => {
  const root = tempDir();
  put(join(root, "bin/new-name"), "#!/bin/sh\n", 0o700);
  symlinkSync("new-name", join(root, "bin/linked"));
  put(join(root, "bin/old-name"), "an older station's script");
  put(join(root, "conf/settings.json"), "{\"theirs\":true}");
  const restored = tempDir();
  // What the target's start made there: a link elsewhere, a file where the archive has a link, a link where it has a
  // file (the old name became a link), and its own settings.
  put(join(restored, "bin/new-name"), "the start's script");
  put(join(restored, "bin/other"), "x");
  symlinkSync("other", join(restored, "bin/old-name"));
  put(join(restored, "bin/linked"), "a file");
  put(join(restored, "conf/settings.json"), "{}");
  await run(restoreTarGz(await archiveOf(root), restored));
  assert.equal(readlinkSync(join(restored, "bin/linked")), "new-name");
  assert.ok(!lstatSync(join(restored, "bin/old-name")).isSymbolicLink(), "a file was written through a link");
  assert.equal(readFileSync(join(restored, "bin/old-name"), "utf8"), "an older station's script");
  assert.equal(readFileSync(join(restored, "bin/other"), "utf8"), "x");
  assert.equal(readFileSync(join(restored, "conf/settings.json"), "utf8"), '{"theirs":true}');

  // A directory in the way of a file is not removed: the restore fails.
  const blocked = tempDir();
  mkdirSync(join(blocked, "bin/linked"), { recursive: true });
  put(join(blocked, "bin/linked/kept"), "kept");
  assert.ok(Exit.isFailure(await Effect.runPromiseExit(restoreTarGz(await archiveOf(root), blocked))));
  assert.equal(readFileSync(join(blocked, "bin/linked/kept"), "utf8"), "kept");
});

test("TestArchiveSkipsALiveRunnersSocketAndPipes", { skip: process.platform === "win32" && "needs a FIFO" }, async () => {
  // A Cloud VM's station keeps its runners' sockets under the workspace; its archive was refused for one.
  const root = tempDir();
  // A socket's path is short (104 bytes on macOS): the runners' directory sits at the root here.
  put(join(root, "station.json"), "{}");
  mkdirSync(join(root, "r"));
  const socket = join(root, "r/c.sock");
  const server = createServer();
  await new Promise<void>((resolve) => server.listen(socket, resolve));
  execFileSync("mkfifo", [join(root, "pipe")]);
  try {
    const restored = tempDir();
    await run(restoreTarGz(await archiveOf(root), restored));
    assert.equal(readFileSync(join(restored, "station.json"), "utf8"), "{}");
    assert.ok(existsSync(join(restored, "r")), "the runners' directory was dropped");
    assert.ok(!existsSync(join(restored, "r/c.sock")), "a socket was restored");
    assert.ok(!existsSync(join(restored, "pipe")), "a pipe was restored");
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("TestArchiveCarriesFilesARunningProcessRemovesOrTruncatesMeanwhile", async () => {
  // A parked station's agents can still write logs: a file listed but removed before it is read is left out, and a
  // file truncated while it is read keeps its listed size, padded with zeros, instead of failing the whole archive.
  const root = tempDir();
  put(join(root, "a.log"), "first");
  put(join(root, "b.sqlite-wal"), "x".repeat(300_000));
  put(join(root, "c.tmp"), "rotated away");
  put(join(root, "d/e.tmp"), "gone with its directory");
  const exclude = (path: string) => {
    if (path === join(root, "a.log")) {
      unlinkSync(join(root, "c.tmp"));
      rmSync(join(root, "d"), { recursive: true });
      mkdirSync(join(root, "d"));
    }
    if (path === join(root, "d")) rmSync(join(root, "d"), { recursive: true });
    if (path === join(root, "b.sqlite-wal")) truncateSync(path, 1000);
    return false;
  };
  const restored = tempDir();
  await run(restoreTarGz(await run(writeTarGz(root, { exclude })), restored));
  assert.equal(readFileSync(join(restored, "a.log"), "utf8"), "first");
  const wal = readFileSync(join(restored, "b.sqlite-wal"));
  assert.equal(wal.length, 300_000);
  assert.equal(wal.subarray(0, 1000).toString(), "x".repeat(1000));
  assert.ok(wal.subarray(1000).every((byte) => byte === 0), "the truncated tail is not zeros");
  assert.ok(!existsSync(join(restored, "c.tmp")));
  assert.ok(!existsSync(join(restored, "d/e.tmp")));
});

test("TestArchiveKeepsGitMetadataAndUserFilesWhileSkippingGeneratedCaches", async () => {
  const root = tempDir();
  const connectorHome = ".salix/sprite-home/.local/share/salix/connector-home";
  const workspace = join(root, connectorHome, ".comma/workspaces/session/repo");
  const files: Record<string, string> = {
    ".git/refs/heads/local": "unpushed commit",
    ".gitignore": "private.conf\n",
    "private.conf": "user configuration",
    "node_modules/pkg/index.js": "locally patched dependency",
    "node_modules/notes.txt": "user data",
    ".venv/pyvenv.cfg": "home = /usr/bin",
    ".venv/notes.txt": "user data",
    ".venv/lib/python3.12/site-packages/pkg/source.py": "patched installation",
    ".venv/lib/python3.12/site-packages/pkg-1.dist-info/METADATA": "installation marker",
    ".tox/env/user-notes.txt": "user data",
    ".nox/env/user-notes.txt": "user data",
    ".pixi/envs/default/user-notes.txt": "user data",
    "__pypackages__/3.12/lib/user-notes.txt": "user data",
    "package.json": '{"dependencies":{"pkg":"1.0.0"}}',
    "package-lock.json": '{"lockfileVersion":3}',
    "dist/output.js": "generated build",
    ".dart_tool/package_config.json": "generated package data",
    ".cxx/object.o": "generated native build",
    "xcuserdata/preferences": "user settings",
    ".swiftpm/configuration/mirrors.json": "user configuration",
    ".terraform/terraform.tfstate": "backend metadata",
    ".tools/local-tool": "user tool",
  };
  for (const [name, content] of Object.entries(files)) put(join(workspace, name), content);
  put(join(root, ".salix/sprite-home/.cache/go-build/object"), "generated");
  put(join(root, connectorHome, ".local/share/pnpm/store/v10/object"), "generated");
  put(join(root, "project/.comma/workspaces/session/repo/build/asset.txt"), "user-owned path");
  const generatedHome = [
    ".npm/_cacache/object", ".cargo/registry/src/crate/lib.rs", ".gradle/caches/module.jar", ".android/cache/build.bin",
    ".m2/repository/library.jar", ".hex/cache.ets", "Library/Developer/Xcode/DerivedData/App/Build/object.o", "go/pkg/mod/example/module.go",
  ];
  const retainedHome = [
    ".npmrc", ".cargo/config.toml", ".cargo/git/db/refs/heads/local", ".gradle/gradle.properties", ".android/adbkey", ".m2/settings.xml",
    "Library/Developer/Xcode/Archives/App.xcarchive/Info.plist", "go/bin/tool",
  ];
  for (const name of generatedHome) put(join(root, connectorHome, name), "generated");
  for (const name of retainedHome) put(join(root, connectorHome, name), "retain");
  const installation = ".salix/sprite-home/.local/share/sprite-agents/local-patch.js";
  put(join(root, installation), "user-patched tool");
  const restored = tempDir();
  await run(restoreTarGz(await archiveOf(root), restored));
  assert.equal(readFileSync(join(restored, installation), "utf8"), "user-patched tool", "an installed tool patch changed");
  const repo = join(restored, connectorHome, ".comma/workspaces/session/repo");
  for (const [name, content] of Object.entries(files)) {
    if (name.startsWith(".dart_tool/") || name.startsWith(".cxx/")) continue;
    assert.equal(readFileSync(join(repo, name), "utf8"), content, `user file ${name} changed`);
  }
  for (const name of [".dart_tool", ".cxx"]) assert.ok(!existsSync(join(repo, name)), `generated directory ${name} was restored`);
  assert.ok(!existsSync(join(restored, ".salix/sprite-home/.cache")), "a runtime cache was restored");
  assert.ok(!existsSync(join(restored, connectorHome, ".local/share/pnpm/store")), "a dependency store was restored");
  assert.ok(existsSync(join(restored, "project/.comma/workspaces/session/repo/build/asset.txt")), "unrelated project data is missing");
  for (const name of generatedHome) assert.ok(!existsSync(join(restored, connectorHome, name)), `generated home cache ${name} was restored`);
  for (const name of retainedHome) assert.ok(existsSync(join(restored, connectorHome, name)), `home configuration ${name} is missing`);
});

test("TestArchiveExportsMoreThanOneHundredThousandEntries", { skip: process.platform === "win32" && "a Cloud VM's archive (Linux), read back by GNU tar" }, async () => {
  const root = tempDir();
  for (let i = 0; i <= 100_000; i++) mkdirSync(join(root, `entry-${String(i).padStart(6, "0")}`), { mode: 0o700 });
  const archive = await archiveOf(root);
  assert.equal(tarGzNames(archive).filter((name) => name.startsWith("entry-")).length, 100_001);
  const restored = tempDir();
  await run(restoreTarGz(archive, restored));
  assert.ok(existsSync(join(restored, "entry-100000")), "the last archive entry is missing after restore");
});
