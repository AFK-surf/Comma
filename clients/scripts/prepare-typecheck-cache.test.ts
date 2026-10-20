import { spawnSync } from "node:child_process";
import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import getExePath from "@effect/tsgo/lib/getExePath";
import { expect, it } from "vitest";
import { prepareTypecheckCache } from "./prepare-typecheck-cache";

const compiler = getExePath();

it("checks changed, added, and removed inputs after restoring a referenced build", () => {
  const root = mkdtempSync(join(tmpdir(), "comma-tsbuild-cache-"));
  const workspace = join(root, "checkout");
  const snapshot = join(root, "snapshot");
  const artifacts = [
    "node_modules/.tmp",
    "clients/node_modules/.tmp",
    "clients/packages/shared/dist",
  ];
  const write = (path: string, content: string | object) => {
    const file = join(workspace, path);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(
      file,
      typeof content === "string" ? content : JSON.stringify(content)
    );
  };
  const build = () =>
    spawnSync(compiler, ["-b"], {
      cwd: join(workspace, "clients"),
      encoding: "utf8",
      timeout: 15_000,
    });
  const restore = () => {
    for (const path of artifacts) {
      rmSync(join(workspace, path), { recursive: true, force: true });
      cpSync(join(snapshot, path), join(workspace, path), {
        recursive: true,
        preserveTimestamps: true,
      });
    }
    prepareTypecheckCache(workspace);
  };
  try {
    const options = {
      composite: true,
      strict: true,
      types: [],
      module: "ESNext",
      moduleResolution: "Bundler",
    };
    write("clients/tsconfig.json", {
      files: [],
      references: [{ path: "./apps/web" }],
    });
    write("clients/packages/shared/tsconfig.json", {
      compilerOptions: {
        ...options,
        declaration: true,
        emitDeclarationOnly: true,
        rootDir: "src",
        outDir: "dist",
        tsBuildInfoFile: "../../../node_modules/.tmp/tsconfig.shared.tsbuildinfo",
      },
      include: ["src"],
    });
    write("clients/apps/web/tsconfig.json", {
      compilerOptions: {
        ...options,
        noEmit: true,
        tsBuildInfoFile: "../../node_modules/.tmp/tsconfig.web.tsbuildinfo",
      },
      include: ["src"],
      references: [{ path: "../../packages/shared" }],
    });
    const producer = "clients/packages/shared/src/index.ts";
    const goodProducer = 'export const value: string = "ok";\n';
    write(producer, goodProducer);
    write(
      "clients/apps/web/src/index.ts",
      'import { value } from "../../../packages/shared/src/index";\nconst result: string = value;\n'
    );
    // A cache miss must still allow the first build.
    prepareTypecheckCache(workspace);
    expect(build().status).toBe(0);
    // A peer's outputs can be newer than this job's checkout.
    const future = new Date(Date.now() + 60_000);
    for (const path of [
      "node_modules/.tmp/tsconfig.shared.tsbuildinfo",
      "clients/node_modules/.tmp/tsconfig.web.tsbuildinfo",
    ]) {
      utimesSync(join(workspace, path), future, future);
    }
    for (const path of artifacts) {
      cpSync(join(workspace, path), join(snapshot, path), {
        recursive: true,
        preserveTimestamps: true,
      });
    }
    restore();
    expect(build().status).toBe(0);

    write(producer, "export const value: number = 1;\n");
    restore();
    const changed = build();
    expect(changed.status, changed.stdout + changed.stderr).not.toBe(0);
    expect(changed.stdout).toContain(
      "Type 'number' is not assignable to type 'string'"
    );

    write(producer, goodProducer);
    const added = "clients/packages/shared/src/added.ts";
    write(added, "export const added: string = 1;\n");
    restore();
    const addition = build();
    expect(addition.status, addition.stdout + addition.stderr).not.toBe(0);
    expect(addition.stdout).toMatch(/added.ts.*error TS2322/);

    rmSync(join(workspace, added));
    rmSync(join(workspace, producer));
    restore();
    const removed = build();
    expect(removed.status, removed.stdout + removed.stderr).not.toBe(0);
    expect(removed.stdout).toContain("Cannot find module");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
