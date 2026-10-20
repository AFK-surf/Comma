// Links where Windows refuses them (src/ops/links.ts): what a user without the privilege (Developer Mode off) gets, by
// a maker that refuses as Windows does then, and a junction made for real.
import assert from "node:assert/strict";
import { lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { link, linkSync } from "../src/ops/links.ts";

const skip = process.platform !== "win32" && "Windows only";
const dirs: string[] = [];
after(() => dirs.forEach((d) => rmSync(d, { recursive: true, force: true })));
const tempdir = () => {
  const d = mkdtempSync(join(tmpdir(), "links-"));
  dirs.push(d);
  return d;
};
const eperm = () => Object.assign(new Error("EPERM: operation not permitted, symlink"), { code: "EPERM" });
/// Refuses symbolic links as Windows does without the privilege; junctions it makes.
const refusingSync = (target: string, path: string, type?: string) => {
  if (type !== "junction") throw eperm();
  symlinkSync(target, path, "junction");
};
const refusing = async (target: string, path: string, type?: "dir" | "file" | "junction") => {
  if (type !== "junction") throw eperm();
  await symlink(target, path, "junction");
};

test("refused, a directory is linked as a junction to it and a file is copied, as the caller allows, and said so", { skip }, async () => {
  const d = tempdir();
  mkdirSync(join(d, "skill"));
  writeFileSync(join(d, "skill", "SKILL.md"), "hi");
  writeFileSync(join(d, "stillfail-job"), "#!/bin/sh\n");
  assert.equal(linkSync("skill", join(d, "linked"), { junction: true }, refusingSync), "junction");
  assert.ok(lstatSync(join(d, "linked")).isSymbolicLink(), "a junction reads as a link");
  assert.equal(readlinkSync(join(d, "linked")), join(d, "skill"));
  assert.equal(readFileSync(join(d, "linked", "SKILL.md"), "utf8"), "hi");
  assert.equal(await link("stillfail-job", join(d, "ember-job"), { copy: true }, refusing), "copy");
  assert.equal(readFileSync(join(d, "ember-job"), "utf8"), "#!/bin/sh\n");
  // Nothing there yet to stand in for.
  assert.equal(await link("later", join(d, "dangling"), { junction: true, copy: true }, refusing), "missing");
});

test("a stand-in the caller does not allow is not made: the refusal is said", { skip }, async () => {
  const d = tempdir();
  mkdirSync(join(d, "dir"));
  writeFileSync(join(d, "file"), "x");
  // None allowed (a tree not at its final path yet), a copy where only a junction is, and the other way round.
  assert.equal(await link("dir", join(d, "a"), {}, refusing), "refused");
  assert.equal(await link("file", join(d, "b"), { junction: true }, refusing), "refused");
  assert.equal(linkSync("dir", join(d, "c"), { copy: true }, refusingSync), "refused");
  for (const made of ["a", "b", "c"]) assert.throws(() => lstatSync(join(d, made)), /ENOENT/);
});

test("anything but a refusal is the caller's", { skip }, () => {
  const d = tempdir();
  const busy = () => {
    throw Object.assign(new Error("EEXIST"), { code: "EEXIST" });
  };
  assert.throws(() => linkSync("x", join(d, "y"), { junction: true, copy: true }, busy), /EEXIST/);
});
