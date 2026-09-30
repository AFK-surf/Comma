import { mkdir, mkdtemp, rm, symlink } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { describe, expect, test } from "bun:test";

import {
  assertNoSymbolicLinks,
  createGitSourceSnapshot,
  publishDatasetBuild,
  runChecked,
} from "./dataset-build-support";

describe("TeamBench dataset build boundaries", () => {
  test("materializes a revision without worktree-only files", async () => {
    const repository = await mkdtemp(
      path.join(os.tmpdir(), "evalens-teambench-repository-")
    );
    try {
      await runChecked(["git", "init", repository]);
      await runChecked(["git", "-C", repository, "config", "user.name", "Evalens"]);
      await runChecked([
        "git",
        "-C",
        repository,
        "config",
        "user.email",
        "evalens@example.test",
      ]);
      await mkdir(path.join(repository, "tasks", "FIXTURE"), { recursive: true });
      await Bun.write(
        path.join(repository, "tasks", "FIXTURE", "tracked.txt"),
        "tracked"
      );
      await runChecked(["git", "-C", repository, "add", "."]);
      await runChecked(["git", "-C", repository, "commit", "-m", "fixture"]);
      const revision = (
        await runChecked(["git", "-C", repository, "rev-parse", "HEAD"])
      ).trim();
      await Bun.write(
        path.join(repository, "tasks", "FIXTURE", "tracked.txt"),
        "tampered worktree"
      );
      await Bun.write(
        path.join(repository, "tasks", "FIXTURE", "untracked-secret.txt"),
        "must not escape"
      );

      await using snapshot = await createGitSourceSnapshot(repository, revision);

      expect(
        await Bun.file(
          path.join(snapshot.root, "tasks", "FIXTURE", "tracked.txt")
        ).text()
      ).toBe("tracked");
      expect(
        await Bun.file(
          path.join(snapshot.root, "tasks", "FIXTURE", "untracked-secret.txt")
        ).exists()
      ).toBe(false);
    } finally {
      await rm(repository, { recursive: true, force: true });
    }
  });

  test("rejects symbolic links before materialization or archiving", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "evalens-teambench-link-"));
    try {
      await Bun.write(path.join(root, "target.txt"), "target");
      await symlink("target.txt", path.join(root, "linked.txt"));

      await expect(assertNoSymbolicLinks(root)).rejects.toThrow("symbolic link");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("replaces all item archives while preserving packed dataset versions", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "evalens-teambench-publish-"));
    const output = path.join(root, "dataset");
    const staged = path.join(root, "staged");
    try {
      await mkdir(path.join(output, "items"), { recursive: true });
      await mkdir(path.join(output, "sha256"), { recursive: true });
      await mkdir(path.join(staged, "items"), { recursive: true });
      await Bun.write(path.join(output, "items", "stale.tar"), "stale");
      await Bun.write(path.join(output, "dataset.json"), "old");
      await Bun.write(path.join(output, "sha256", "published.tar"), "published");
      await Bun.write(path.join(staged, "items", "current.tar"), "current");
      await Bun.write(path.join(staged, "dataset.json"), "new");

      await publishDatasetBuild(staged, output);

      expect(await Bun.file(path.join(output, "items", "stale.tar")).exists()).toBe(
        false
      );
      expect(await Bun.file(path.join(output, "items", "current.tar")).text()).toBe(
        "current"
      );
      expect(await Bun.file(path.join(output, "dataset.json")).text()).toBe("new");
      expect(await Bun.file(path.join(output, "sha256", "published.tar")).text()).toBe(
        "published"
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
