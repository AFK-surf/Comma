import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ensureCompiled, viteIsServer } from "../../scripts/compiled-catalogs.mjs";

/** A checkout with one catalog, and a compiler that writes what it was asked for. */
function checkout() {
  const root = mkdtempSync(join(tmpdir(), "comma-i18n-"));
  const directory = join(root, "clients/packages/i18n");
  mkdirSync(join(directory, "messages"), { recursive: true });
  mkdirSync(join(directory, "project.inlang"), { recursive: true });
  writeFileSync(join(root, "pnpm-lock.yaml"), "lockfileVersion: 1");
  writeFileSync(join(directory, "messages/en.json"), '{"greeting":"Hello"}');
  writeFileSync(join(directory, "project.inlang/settings.json"), "{}");
  const output = join(directory, "src/paraglide");
  const compilations: string[] = [];
  const compile = async (job: { outdir: string; isServer?: string }) => {
    const catalog = readFileSync(join(directory, "messages/en.json"), "utf8");
    compilations.push(catalog);
    rmSync(job.outdir, { recursive: true, force: true });
    mkdirSync(join(job.outdir, "messages"), { recursive: true });
    writeFileSync(join(job.outdir, "messages/en.js"), catalog);
    writeFileSync(join(job.outdir, "runtime.js"), `isServer = ${job.isServer}`);
  };
  return {
    root,
    directory,
    output,
    compilations,
    ensure: (given: { isServer?: string; cache?: string } = {}) =>
      ensureCompiled({ directory, compile, ...given }),
  };
}

describe("compiled message catalogs", () => {
  it("compiles once for the same catalogs and again when one changes", async () => {
    const { directory, output, compilations, ensure } = checkout();

    expect(await ensure()).toBe("compiled");
    expect(await ensure()).toBe("current");
    expect(compilations).toHaveLength(1);

    writeFileSync(join(directory, "messages/en.json"), '{"greeting":"Hi"}');
    expect(await ensure()).toBe("compiled");
    expect(readFileSync(join(output, "messages/en.js"), "utf8")).toBe(
      '{"greeting":"Hi"}'
    );

    writeFileSync(join(directory, "messages/zh-CN.json"), '{"greeting":"你好"}');
    expect(await ensure()).toBe("compiled");
    expect(compilations).toHaveLength(3);
  });

  it("compiles again when the lockfile or the runtime's server expression changes", async () => {
    const { root, output, ensure } = checkout();

    expect(await ensure()).toBe("compiled");
    expect(await ensure({ isServer: viteIsServer })).toBe("compiled");
    expect(readFileSync(join(output, "runtime.js"), "utf8")).toBe(
      `isServer = ${viteIsServer}`
    );
    expect(await ensure({ isServer: viteIsServer })).toBe("current");

    writeFileSync(join(root, "pnpm-lock.yaml"), "lockfileVersion: 2");
    expect(await ensure({ isServer: viteIsServer })).toBe("compiled");
  });

  it("compiles again when the output is not the one it compiled", async () => {
    const { output, compilations, ensure } = checkout();
    await ensure();

    // Another compiler wrote the directory.
    writeFileSync(join(output, "runtime.js"), "isServer = somethingElse");
    expect(await ensure()).toBe("compiled");

    rmSync(join(output, "messages/en.js"));
    expect(await ensure()).toBe("compiled");
    expect(compilations).toHaveLength(3);
  });

  it("does not take a failed compilation for an output", async () => {
    const { directory, compilations, ensure } = checkout();
    await ensure();
    writeFileSync(join(directory, "messages/en.json"), '{"greeting":"Hi"}');

    const failing = ensureCompiled({
      directory,
      compile: async () => {
        throw new Error("invalid catalog");
      },
    });
    await expect(failing).rejects.toThrow("invalid catalog");
    expect(readdirSync(directory).toSorted()).toEqual([
      "messages",
      "project.inlang",
      "src",
    ]);

    expect(await ensure()).toBe("compiled");
    expect(compilations).toHaveLength(2);
  });

  it("leaves the output whole for its readers while it compiles or restores another", async () => {
    const cache = join(mkdtempSync(join(tmpdir(), "comma-i18n-cache-")), "comma-i18n");
    const first = checkout();
    await first.ensure({ cache, isServer: viteIsServer });

    const second = checkout();
    await second.ensure({ cache });
    const seen: string[] = [];
    // Another process of the job reads the output while this one compiles.
    const reading = ensureCompiled({
      directory: second.directory,
      cache,
      isServer: "typeof document === 'undefined'",
      compile: async (job: { outdir: string; isServer?: string }) => {
        // Paraglide empties the directory it compiles into.
        rmSync(job.outdir, { recursive: true, force: true });
        seen.push(readFileSync(join(second.output, "messages/en.js"), "utf8"));
        mkdirSync(join(job.outdir, "messages"), { recursive: true });
        writeFileSync(join(job.outdir, "messages/en.js"), "compiled");
        writeFileSync(join(job.outdir, "runtime.js"), `isServer = ${job.isServer}`);
      },
    });
    expect(await reading).toBe("compiled");
    expect(seen).toEqual(['{"greeting":"Hello"}']);
    expect(readFileSync(join(second.output, "messages/en.js"), "utf8")).toBe(
      "compiled"
    );

    expect(await second.ensure({ cache, isServer: viteIsServer })).toBe("restored");
    expect(readFileSync(join(second.output, "runtime.js"), "utf8")).toBe(
      `isServer = ${viteIsServer}`
    );
    // Nothing is left beside the output.
    expect(readdirSync(second.directory).toSorted()).toEqual([
      "messages",
      "project.inlang",
      "src",
    ]);
  });

  it("gives a host's next checkout the output from the cache, each variant its own", async () => {
    const cache = join(mkdtempSync(join(tmpdir(), "comma-i18n-cache-")), "comma-i18n");
    const first = checkout();
    expect(await first.ensure({ cache })).toBe("compiled");
    expect(await first.ensure({ cache, isServer: viteIsServer })).toBe("compiled");

    const second = checkout();
    expect(await second.ensure({ cache })).toBe("restored");
    expect(readFileSync(join(second.output, "runtime.js"), "utf8")).toBe(
      "isServer = undefined"
    );
    expect(await second.ensure({ cache, isServer: viteIsServer })).toBe("restored");
    expect(readFileSync(join(second.output, "runtime.js"), "utf8")).toBe(
      `isServer = ${viteIsServer}`
    );
    expect(await second.ensure({ cache, isServer: viteIsServer })).toBe("current");
    expect(second.compilations).toHaveLength(0);
  });

  it("restores into the output directory a build reads, file by file", async () => {
    const cache = join(mkdtempSync(join(tmpdir(), "comma-i18n-cache-")), "comma-i18n");
    const first = checkout();
    await first.ensure({ cache, isServer: viteIsServer });

    // Forge runs its Vite builds at once: one restores the variant they all
    // read while another already reads it. The directory stays, with every
    // file; what an earlier output left goes.
    const second = checkout();
    await second.ensure({ cache });
    writeFileSync(join(second.output, "stale.js"), "");
    const directory = statSync(second.output).ino;
    expect(await second.ensure({ cache, isServer: viteIsServer })).toBe("restored");
    expect(statSync(second.output).ino).toBe(directory);
    expect(readFileSync(join(second.output, "runtime.js"), "utf8")).toBe(
      `isServer = ${viteIsServer}`
    );
    expect(existsSync(join(second.output, "stale.js"))).toBe(false);
    expect(
      readdirSync(second.output).filter((name) => name.startsWith(".partial"))
    ).toEqual([]);
    expect(await second.ensure({ cache, isServer: viteIsServer })).toBe("current");
  });

  it("compiles over a cache entry that is not whole and replaces it", async () => {
    const cache = mkdtempSync(join(tmpdir(), "comma-i18n-cache-"));
    const first = checkout();
    await first.ensure({ cache });
    const [entry] = readdirSync(cache);
    rmSync(join(cache, entry!, "messages/en.js"));

    const second = checkout();
    expect(await second.ensure({ cache })).toBe("compiled");
    expect(existsSync(join(cache, entry!, "messages/en.js"))).toBe(true);

    const third = checkout();
    expect(await third.ensure({ cache })).toBe("restored");
  });
});
