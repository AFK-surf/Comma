import { execFileSync } from "node:child_process";
import { existsSync, lstatSync, readFileSync } from "node:fs";
import { dirname, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";

// Check the working tree, including new files, so this works before git add.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const paths = [
  ...new Set(
    execFileSync(
      "git",
      [
        "ls-files",
        "--cached",
        "--others",
        "--exclude-standard",
        "-z",
        "--",
        "docs/",
      ],
      { cwd: root, encoding: "utf8" },
    )
      .split("\0")
      .filter(Boolean),
  ),
].filter(
  (path) =>
    !path.startsWith("docs/architecture/") &&
    !path.startsWith("docs/user_manual/") &&
    existsSync(resolve(root, path)),
);
const failures = [];
if (paths.length > 20)
  failures.push(`general docs has ${paths.length} files (maximum 20)`);
for (const path of paths) {
  const absolute = resolve(root, path);
  if (!lstatSync(absolute).isFile()) {
    failures.push(`${path}: expected a regular file`);
    continue;
  }
  const body = readFileSync(absolute);
  if (body.length > 20_000)
    failures.push(`${path}: ${body.length} bytes (maximum 20000)`);
  if (!path.endsWith(".md")) continue;
  // Inline local Markdown links. Fenced examples are not navigation links.
  const text = body
    .toString("utf8")
    .replace(/^```[^\n]*\n[\s\S]*?^```\s*$/gm, "");
  for (const match of text.matchAll(/\]\(([^\s)]+)\)/g)) {
    const target = match[1];
    if (/^[a-z][a-z\d+.-]*:/i.test(target)) continue;
    const [name, fragment] = target.split("#");
    const destination = name
      ? resolve(dirname(absolute), decodeURIComponent(name))
      : absolute;
    if (!existsSync(destination)) {
      failures.push(`${path}: missing link ${target}`);
      continue;
    }
    if (fragment && destination.endsWith(".md")) {
      const headings = readFileSync(destination, "utf8").matchAll(
        /^#{1,6}\s+(.+)$/gm,
      );
      const anchors = new Set(
        [...headings].map((heading) =>
          heading[1]
            .toLowerCase()
            .replace(/[^\p{L}\p{N}_\-\s]/gu, "")
            .replace(/ /g, "-"),
        ),
      );
      if (!anchors.has(decodeURIComponent(fragment)))
        failures.push(`${path}: missing heading ${target}`);
    }
  }
}
if (failures.length) {
  console.error(failures.join("\n"));
  process.exitCode = 1;
} else {
  const largest = paths
    .map((path) => [
      readFileSync(resolve(root, path)).length,
      relative(root, resolve(root, path)),
    ])
    .sort((a, b) => b[0] - a[0])[0];
  console.log(
    `general docs (excluding architecture/ and user_manual/): ${paths.length}/20 files; largest ${largest?.[0] ?? 0}/20000 bytes (${largest?.[1] ?? "none"}); local links valid`,
  );
}
