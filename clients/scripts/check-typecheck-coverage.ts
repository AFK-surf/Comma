import { execFileSync } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import getExePath from "@effect/tsgo/lib/getExePath";

const sourceFile = /\.(?:ts|tsx|mts|cts)$/;

// Files that no project checks on purpose. Each entry needs a reason.
const uncheckedByDesign = [
  // Storybook configuration was never type-checked and has known type errors.
  "packages/ui/.storybook/",
];

function configPath(path: string): string {
  return existsSync(path) && statSync(path).isDirectory()
    ? join(path, "tsconfig.json")
    : path;
}

// Lists source files that are not a root file of any project in the build graph.
// Each project checks only its own files, so a file outside every include list
// is not type-checked unless an import happens to reach it.
export function findUncheckedFiles(clients: string): string[] {
  const compiler = getExePath();
  const pending = [configPath(join(clients, "tsconfig.json"))];
  const projects = new Set<string>();
  const checked = new Set<string>();
  while (pending.length > 0) {
    const project = pending.pop()!;
    if (projects.has(project)) continue;
    projects.add(project);
    const config = JSON.parse(
      execFileSync(compiler, ["-p", project, "--showConfig"], {
        encoding: "utf8",
        maxBuffer: 64 * 1024 * 1024,
      })
    ) as { files?: string[]; references?: { path: string }[] };
    for (const reference of config.references ?? []) {
      pending.push(configPath(resolve(dirname(project), reference.path)));
    }
    for (const file of config.files ?? []) {
      checked.add(resolve(dirname(project), file));
    }
  }
  return execFileSync(
    "git",
    ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "."],
    { cwd: clients, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 }
  )
    .split("\0")
    .filter(
      (file) =>
        sourceFile.test(file) &&
        !file.split("/").some((part) => part === "node_modules" || part === "dist") &&
        !uncheckedByDesign.some((prefix) => file.startsWith(prefix)) &&
        existsSync(join(clients, file)) &&
        !checked.has(resolve(clients, file))
    )
    .toSorted();
}

if (import.meta.main) {
  const unchecked = findUncheckedFiles(resolve(import.meta.dirname, ".."));
  if (unchecked.length > 0) {
    console.error(
      "No project referenced from clients/tsconfig.json type-checks these files.\n" +
        "Add each file to the include list of the tsconfig that owns it:"
    );
    for (const file of unchecked) console.error(`  clients/${file}`);
    process.exit(1);
  }
}
