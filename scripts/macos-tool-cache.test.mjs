import { test } from "node:test";
import assert from "node:assert/strict";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  realpathSync,
  readdirSync,
  utimesSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync, spawn } from "node:child_process";

const selector = fileURLToPath(
  new URL(
    "../.github/actions/setup-macos-cache/select-cache.sh",
    import.meta.url,
  ),
);

test("runner-native Go paths and Playwright downloads survive guest replacement", () => {
  const root = mkdtempSync(join(tmpdir(), "comma tools-"));
  try {
    const shared = join(root, "My Shared Files", "cache");
    mkdirSync(shared, { recursive: true });
    const select = (
      guest,
      slot = "tokyo / 1",
      os = "macOS",
      mount = shared,
      extra = {},
    ) => {
      const tools = join(root, guest, "_tool");
      // Each guest is a fresh VM with its own home.
      const home = join(root, guest, "home");
      mkdirSync(home, { recursive: true });
      const env = join(root, `${guest}.env`);
      writeFileSync(env, "");
      execFileSync("bash", [selector, mount], {
        env: {
          ...process.env,
          HOME: home,
          RUNNER_OS: os,
          RUNNER_NAME: slot,
          RUNNER_TOOL_CACHE: tools,
          GITHUB_ENV: env,
          GITHUB_OUTPUT: join(root, `${guest}.output`),
          ...extra,
        },
      });
      const values = Object.fromEntries(
        readFileSync(env, "utf8")
          .trim()
          .split("\n")
          .filter(Boolean)
          .map((line) => {
            const index = line.indexOf("=");
            return [line.slice(0, index), line.slice(index + 1)];
          }),
      );
      return {
        tools,
        browsers: values.PLAYWRIGHT_BROWSERS_PATH,
        // The store path is the same on every runner; where it leads is the slot's.
        pnpmStore:
          values.npm_config_store_dir &&
          realpathSync(values.npm_config_store_dir),
      };
    };
    // Image tools must survive migration; unrelated tool families remain local.
    const original = join(root, "guest1", "_tool");
    mkdirSync(join(original, "go", "1.26.6", "arm64"), { recursive: true });
    writeFileSync(join(original, "go", "1.26.6", "arm64.complete"), "");
    writeFileSync(
      join(original, "go", "1.26.6", "arm64", "installed"),
      "image Go",
    );
    mkdirSync(join(original, "node"));
    writeFileSync(join(original, "node", "installed"), "image Node");
    const first = select("guest1");
    assert.equal(
      readFileSync(join(first.tools, "node", "installed"), "utf8"),
      "image Node",
    );
    assert.ok(
      realpathSync(join(first.tools, "go")).startsWith(realpathSync(shared)),
      "setup-go must reach shared storage through the runner-provided root",
    );
    const backup = readdirSync(first.tools).find((name) =>
      name.startsWith("comma-go-backup."),
    );
    assert.equal(
      readFileSync(
        join(first.tools, backup, "go", "1.26.6", "arm64", "installed"),
        "utf8",
      ),
      "image Go",
    );
    writeFileSync(join(first.browsers, "chromium-fixture"), "browser download");
    // setup-go's actual tool-cache root is supplied by the runner, not an output.
    mkdirSync(join(first.tools, "go", "1.27.0", "arm64"), { recursive: true });
    writeFileSync(join(first.tools, "go", "1.27.0", "arm64.complete"), "");
    const second = select("guest2");
    assert.ok(existsSync(join(second.tools, "go", "1.27.0", "arm64.complete")));
    assert.equal(
      readFileSync(
        join(second.tools, "go", "1.26.6", "arm64", "installed"),
        "utf8",
      ),
      "image Go",
    );
    assert.equal(
      readFileSync(join(second.browsers, "chromium-fixture"), "utf8"),
      "browser download",
    );
    assert.equal(
      realpathSync(join(second.tools, "go")),
      realpathSync(join(first.tools, "go")),
    );
    assert.ok(existsSync(first.pnpmStore));
    assert.equal(second.pnpmStore, first.pnpmStore);
    assert.deepEqual(select("guest2"), second); // repeated setup is safe
    const other = select("guest3", "tokyo / 2");
    assert.equal(
      existsSync(join(other.tools, "go", "1.27.0", "arm64.complete")),
      false,
    );
    assert.equal(existsSync(join(other.browsers, "chromium-fixture")), false);
    assert.notEqual(other.pnpmStore, first.pnpmStore);
    const linux = select("linux", "tokyo", "Linux");
    assert.equal(existsSync(linux.tools), false);
    assert.equal(linux.browsers, undefined);
    assert.equal(linux.pnpmStore, undefined);
    // ARC pods on one node share the slot their runner image names, whatever
    // their single-use runner names.
    const pod = (guest, name) =>
      select(guest, name, "Linux", shared, { SYNCH_CACHE_SLOT: "ci-linux09" });
    const pod1 = pod("pod1", "pvg-linux-arm64-a");
    writeFileSync(join(pod1.browsers, "chromium-linux"), "browser download");
    const pod2 = pod("pod2", "pvg-linux-arm64-b");
    assert.equal(pod2.pnpmStore, pod1.pnpmStore);
    assert.equal(
      readFileSync(join(pod2.browsers, "chromium-linux"), "utf8"),
      "browser download",
    );
    assert.notEqual(pod1.pnpmStore, first.pnpmStore);
    const absent = select(
      "absent",
      "tokyo",
      "macOS",
      join(root, "absent-mount"),
    );
    assert.equal(existsSync(absent.tools), false);
    assert.equal(absent.browsers, undefined);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a fresh guest copies only the image Go versions shared storage lacks", () => {
  const root = mkdtempSync(join(tmpdir(), "comma go-"));
  try {
    const shared = join(root, "cache");
    mkdirSync(shared, { recursive: true });
    const guest = (name, versions) => {
      const tools = join(root, name, "_tool");
      for (const [version, content, complete] of versions) {
        mkdirSync(join(tools, "go", version, "arm64"), { recursive: true });
        writeFileSync(
          join(tools, "go", version, "arm64", "installed"),
          content,
        );
        if (complete) {
          writeFileSync(join(tools, "go", version, "arm64.complete"), "");
        }
      }
      const env = join(root, `${name}.env`);
      writeFileSync(env, "");
      execFileSync("bash", [selector, shared], {
        env: {
          ...process.env,
          RUNNER_OS: "macOS",
          RUNNER_NAME: "pvg 1",
          RUNNER_TOOL_CACHE: tools,
          GITHUB_ENV: env,
        },
      });
      return (version) =>
        readFileSync(join(tools, "go", version, "arm64", "installed"), "utf8");
    };
    guest("guest1", [
      ["1.26.6", "first image", true],
      ["1.25.3", "unfinished", false],
    ]);
    // The next guest's image carries the same versions. One shared storage
    // already holds whole is left alone; one without its completion marker
    // there is copied again.
    const second = guest("guest2", [
      ["1.26.6", "second image", true],
      ["1.25.3", "second image", true],
    ]);
    assert.equal(second("1.26.6"), "first image");
    assert.equal(second("1.25.3"), "second image");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("runners on one LAN share tool caches through the Synchronicity gateway", async () => {
  const { createServer } = await import("node:http");
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const run = promisify(execFile);
  // The gateway serves one unified read view; each host writes its own view.
  const objects = new Map();
  const puts = [];
  const server = createServer((req, res) => {
    const url = new URL(req.url, "http://gateway");
    const [, bucket, ...rest] = url.pathname.split("/");
    const key = rest.join("/");
    if (req.method === "GET" && !key) {
      const prefix = url.searchParams.get("prefix");
      const listed = [...objects]
        .filter(([name]) => name.startsWith(prefix))
        .map(
          ([name, value]) =>
            `<Contents><Key>${name}</Key><LastModified>${value.at}</LastModified></Contents>`,
        );
      res.end(`<ListBucketResult>${listed.join("")}</ListBucketResult>`);
    } else if (req.method === "PUT") {
      const chunks = [];
      req.on("data", (chunk) => chunks.push(chunk));
      req.on("end", () => {
        puts.push(`${bucket}/${key}`);
        objects.set(key, {
          body: Buffer.concat(chunks),
          at: new Date(Date.now() + puts.length).toISOString(),
        });
        res.end();
      });
    } else if (req.method === "DELETE") {
      objects.delete(key);
      res.statusCode = 204;
      res.end();
    } else if (!objects.has(key)) {
      res.statusCode = 404;
      res.end();
    } else {
      res.end(req.method === "HEAD" ? undefined : objects.get(key).body);
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const root = mkdtempSync(join(tmpdir(), "comma synch-"));
  try {
    const action = fileURLToPath(
      new URL("../.github/actions/setup-macos-cache/", import.meta.url),
    );
    // Where station-rust-cache.sh reads native.ts's TOOLCHAIN.
    const repository = fileURLToPath(new URL("..", import.meta.url));
    const workspace = join(root, "workspace");
    mkdirSync(join(workspace, "go"), { recursive: true });
    writeFileSync(join(workspace, "go", "go.mod"), "module x\n\ngo 1.25.3\n");
    const hosts = ["host a", "host b", "host c"].map((name) => {
      const shared = join(root, name, "cache");
      mkdirSync(join(shared, "synch"), { recursive: true });
      writeFileSync(
        join(shared, "synch", "s3.env"),
        [
          `SYNCH_S3_ENDPOINT=http://127.0.0.1:${server.address().port}`,
          "SYNCH_S3_ACCESS_KEY=ci-vm",
          "SYNCH_S3_SECRET_KEY=secret",
          "SYNCH_S3_READ_BUCKET=cinet",
          `SYNCH_S3_WRITE_BUCKET=${name.replace(" ", "-")}`,
        ].join("\n"),
      );
      return { name, shared };
    });
    const job = async (
      host,
      step,
      families = "go",
      jobWorkspace = workspace,
    ) => {
      const temp = join(root, host.name, "temp");
      mkdirSync(temp, { recursive: true });
      writeFileSync(join(temp, "env"), "");
      const env = {
        ...process.env,
        RUNNER_OS: "macOS",
        RUNNER_NAME: `${host.name} 1`,
        RUNNER_TEMP: temp,
        RUNNER_TOOL_CACHE: join(root, host.name, "_tool"),
        GITHUB_ENV: join(temp, "env"),
        GITHUB_WORKSPACE: jobWorkspace,
        SYNCH_CACHE_SHARED_DIRECTORY: host.shared,
        INPUT_FAMILIES: families,
        "INPUT_GO-VERSION-FILE": "go/go.mod",
      };
      const { stdout } = await run("node", [join(action, `${step}.mjs`)], {
        env,
      });
      return stdout;
    };
    const goCache = (host) =>
      join(
        host.shared,
        "comma-toolchains",
        Buffer.from(`${host.name} 1`).toString("hex"),
        "tools",
        "go",
      );

    // The first host misses everywhere, installs, and publishes its toolchain.
    assert.match(await job(hosts[0], "main"), /no peer snapshot for 1\.25\.3/);
    // A real install comes seconds after the stamp; Linux file times are
    // coarse enough that a directory made at once can share its timestamp.
    const past = new Date(Date.now() - 5000);
    const stamp = join(root, hosts[0].name, "temp", "synch-cache.stamp");
    utimesSync(stamp, past, past);
    mkdirSync(join(goCache(hosts[0]), "1.25.3", "arm64"), { recursive: true });
    writeFileSync(join(goCache(hosts[0]), "1.25.3", "arm64.complete"), "");
    assert.match(await job(hosts[0], "post"), /published 1\.25\.3/);
    assert.equal(puts.length, 1);

    // A peer restores that snapshot instead of downloading Go again.
    assert.match(await job(hosts[1], "main"), /restored 1\.25\.3 from peers/);
    assert.ok(existsSync(join(goCache(hosts[1]), "1.25.3", "arm64.complete")));
    assert.doesNotMatch(await job(hosts[1], "post"), /published/);

    // Once satisfied, later jobs neither download nor publish this key.
    assert.doesNotMatch(await job(hosts[1], "main"), /Synch cache/);
    assert.doesNotMatch(await job(hosts[0], "main"), /Synch cache/);
    assert.doesNotMatch(await job(hosts[0], "post"), /Synch cache/);
    assert.equal(puts.length, 1);

    // The pnpm store is content-addressed: a peer snapshot fills an empty
    // store, and a store that already holds packages is left to pnpm.
    const store = (host) =>
      join(
        host.shared,
        "comma-toolchains",
        Buffer.from(`${host.name} 1`).toString("hex"),
        "pnpm-store",
      );
    mkdirSync(store(hosts[0]), { recursive: true });
    writeFileSync(join(store(hosts[0]), "package-a"), "a");
    assert.match(
      await job(hosts[0], "main", "pnpm-store"),
      /pnpm-store: local store already populated/,
    );
    const pnpmStamp = join(root, hosts[0].name, "temp", "synch-cache.stamp");
    utimesSync(pnpmStamp, past, past);
    writeFileSync(join(store(hosts[0]), "package-b"), "b");
    assert.match(
      await job(hosts[0], "post", "pnpm-store"),
      /pnpm-store: published/,
    );
    mkdirSync(store(hosts[1]), { recursive: true });
    writeFileSync(join(store(hosts[1]), "package-a"), "a");
    assert.match(
      await job(hosts[1], "main", "pnpm-store"),
      /pnpm-store: local store already populated/,
    );
    assert.equal(existsSync(join(store(hosts[1]), "package-b")), false);
    assert.match(
      await job(hosts[2], "main", "pnpm-store"),
      /pnpm-store: restored .* from peers/,
    );
    assert.equal(readFileSync(join(store(hosts[2]), "package-b"), "utf8"), "b");

    // TLC gets the same directory through GITHUB_ENV and the peer transport.
    await job(hosts[0], "main", "tla");
    const tlaCache = (host) => {
      const output = readFileSync(join(root, host.name, "temp", "env"), "utf8");
      return output.match(/^TLA_CACHE_DIR=(.+)$/m)[1];
    };
    const firstTlaCache = tlaCache(hosts[0]);
    const jar = "tla2tools-1.7.4.jar";
    utimesSync(stamp, past, past);
    writeFileSync(join(firstTlaCache, jar), "TLC download fixture");
    assert.match(await job(hosts[0], "post", "tla"), /tla: published/);
    assert.match(
      await job(hosts[1], "main", "tla"),
      /tla: restored .* from peers/,
    );
    assert.equal(
      readFileSync(join(tlaCache(hosts[1]), jar), "utf8"),
      "TLC download fixture",
    );
    assert.notEqual(firstTlaCache, tlaCache(hosts[1]));
    assert.doesNotMatch(await job(hosts[1], "main", "tla"), /tla: restored/);
    assert.equal(
      readFileSync(join(tlaCache(hosts[1]), jar), "utf8"),
      "TLC download fixture",
    );

    // setup-java discovers Temurin by its tool-cache directory and completion
    // marker. Restore both on another host, then after guest replacement.
    const javaCache = (host) =>
      join(root, host.name, "_tool", "Java_Temurin-Hotspot_jdk");
    await job(hosts[0], "main", "java");
    utimesSync(stamp, past, past);
    const javaHome = "21.0.8-9/arm64/Contents/Home";
    mkdirSync(join(javaCache(hosts[0]), javaHome, "bin"), { recursive: true });
    writeFileSync(
      join(javaCache(hosts[0]), javaHome, "bin", "java"),
      '#!/bin/sh\nprintf "Temurin fixture\\n"\n',
      { mode: 0o755 },
    );
    writeFileSync(join(javaCache(hosts[0]), "21.0.8-9", "arm64.complete"), "");
    assert.match(await job(hosts[0], "post", "java"), /java: published 21/);
    for (let guest = 0; guest < 2; guest++) {
      assert.match(
        await job(hosts[1], "main", "java"),
        /java: restored 21 from peers/,
      );
      assert.ok(
        existsSync(join(javaCache(hosts[1]), "21.0.8-9", "arm64.complete")),
      );
      assert.equal(
        execFileSync(join(javaCache(hosts[1]), javaHome, "bin", "java"), {
          encoding: "utf8",
        }),
        "Temurin fixture\n",
      );
      rmSync(javaCache(hosts[1]), { recursive: true });
    }

    const leanWorkspace = (host) => {
      const directory = join(root, host.name, "workspace");
      const kernel = join(directory, "systems/native/verified_kernel");
      mkdirSync(kernel, { recursive: true });
      writeFileSync(
        join(kernel, "lean-toolchain"),
        "leanprover/lean4:v4.24.0\n",
      );
      execFileSync("git", ["init", "-q", directory]);
      execFileSync("git", ["-C", directory, "add", "."]);
      execFileSync("git", [
        "-C",
        directory,
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.com",
        "commit",
        "-qm",
        "fixture",
      ]);
      return directory;
    };
    const leanA = leanWorkspace(hosts[0]);
    const leanB = leanWorkspace(hosts[1]);
    const leanFamilies = "lean-toolchain lean-build";
    const build = (workspace) =>
      join(workspace, "systems/native/verified_kernel/.lake/build");
    await job(hosts[0], "main", leanFamilies, leanA);
    const elanA = readFileSync(
      join(root, hosts[0].name, "temp", "env"),
      "utf8",
    ).match(/^ELAN_HOME=(.+)$/m)[1];
    utimesSync(stamp, past, past);
    mkdirSync(elanA, { recursive: true });
    writeFileSync(join(elanA, "toolchain-fixture"), "pinned compiler");
    mkdirSync(build(leanA), { recursive: true });
    writeFileSync(join(build(leanA), "proof.olean"), "compiled proof fixture");
    assert.match(
      await job(hosts[0], "post", leanFamilies, leanA),
      /lean-build: published/,
    );
    assert.match(
      await job(hosts[1], "main", leanFamilies, leanB),
      /lean-build: restored .* from peers/,
    );
    const elanB = readFileSync(
      join(root, hosts[1].name, "temp", "env"),
      "utf8",
    ).match(/^ELAN_HOME=(.+)$/m)[1];
    assert.equal(
      readFileSync(join(elanB, "toolchain-fixture"), "utf8"),
      "pinned compiler",
    );
    assert.equal(
      readFileSync(join(build(leanB), "proof.olean"), "utf8"),
      "compiled proof fixture",
    );
    assert.ok(!elanA.startsWith(hosts[0].shared));
    assert.ok(!elanB.startsWith(hosts[1].shared));
    // The peer marker survives VM replacement; guest files do not.
    rmSync(elanB, { recursive: true });
    rmSync(build(leanB), { recursive: true });
    assert.match(
      await job(hosts[1], "main", leanFamilies, leanB),
      /lean-build: restored .* from peers/,
    );
    assert.equal(
      readFileSync(join(elanB, "toolchain-fixture"), "utf8"),
      "pinned compiler",
    );
    assert.equal(
      readFileSync(join(build(leanB), "proof.olean"), "utf8"),
      "compiled proof fixture",
    );

    // Compiler snapshots must replace older state under the same compatibility
    // key, including after a guest moves to another host.
    const compiler = join(action, "typecheck-cache.mjs");
    const typecheck = async (host, mode, key = "compatible") => {
      const repo = join(root, host.name, "compiler");
      mkdirSync(repo, { recursive: true });
      const { stdout } = await run("node", [compiler, mode], {
        env: {
          ...process.env,
          RUNNER_OS: "macOS",
          GITHUB_WORKSPACE: repo,
          SYNCH_CACHE_SHARED_DIRECTORY: host.shared,
          TYPECHECK_CACHE_KEY: key,
        },
      });
      return { repo, stdout };
    };
    const { repo: compilerA } = await typecheck(hosts[0], "restore");
    mkdirSync(join(compilerA, "clients/node_modules/.tmp"), {
      recursive: true,
    });
    mkdirSync(join(compilerA, "clients/packages/core/dist"), {
      recursive: true,
    });
    const buildInfo = "clients/node_modules/.tmp/core.tsbuildinfo";
    writeFileSync(join(compilerA, buildInfo), "first signatures");
    writeFileSync(
      join(compilerA, "clients/packages/core/dist/index.d.ts"),
      "types",
    );
    await typecheck(hosts[0], "save");
    const { repo: compilerB, stdout } = await typecheck(hosts[1], "restore");
    assert.match(stdout, /restored compatible from peers/);
    assert.equal(
      readFileSync(join(compilerB, buildInfo), "utf8"),
      "first signatures",
    );
    assert.equal(
      readFileSync(
        join(compilerB, "clients/packages/core/dist/index.d.ts"),
        "utf8",
      ),
      "types",
    );
    writeFileSync(join(compilerB, buildInfo), "updated signatures");
    await typecheck(hosts[1], "save");
    await typecheck(hosts[0], "restore");
    assert.equal(
      readFileSync(join(compilerA, buildInfo), "utf8"),
      "updated signatures",
    );
    const { repo: compilerC } = await typecheck(
      hosts[2],
      "restore",
      "different-config",
    );
    assert.equal(existsSync(join(compilerC, buildInfo)), false);

    // Rust builds retain dependency downloads, compiled crates, and keyed
    // native binaries when the next job lands on another host.
    const rust = async (host, mode, key = "rust-toolchain-and-lockfiles") => {
      const temp = join(root, host.name, "rust-job");
      mkdirSync(temp, { recursive: true });
      const output = join(temp, "env");
      writeFileSync(output, "");
      const { stdout } = await run(
        "bash",
        [join(action, "station-rust-cache.sh"), mode],
        {
          env: {
            ...process.env,
            RUNNER_OS: "macOS",
            RUNNER_TEMP: temp,
            GITHUB_ENV: output,
            SYNCH_CACHE_SHARED_DIRECTORY: host.shared,
            GITHUB_WORKSPACE: repository,
            RUST_CACHE_KEY: key,
          },
        },
      );
      const values = Object.fromEntries(
        readFileSync(output, "utf8")
          .trim()
          .split("\n")
          .filter(Boolean)
          .map((line) => {
            const at = line.indexOf("=");
            return [line.slice(0, at), line.slice(at + 1)];
          }),
      );
      return { values, stdout };
    };
    const { values: rustA } = await rust(hosts[0], "restore");
    const rustEntries = [
      ["CARGO_HOME", "registry/crate", "download"],
      ["CARGO_HOME", "git/checkout", "git dependency"],
      ["CARGO_TARGET_DIR", "native/mesh/dependency.rlib", "compiled crate"],
      ["STILLFAIL_NATIVE_CACHE", "mesh/source-key/mesh.node", "native binary"],
    ];
    for (const [variable, path, content] of rustEntries) {
      const file = join(rustA[variable], path);
      mkdirSync(join(file, ".."), { recursive: true });
      writeFileSync(file, content);
    }
    writeFileSync(
      join(rustA.CARGO_HOME, "credentials.toml"),
      "private fixture",
    );
    const rustc = join(rustA.RUSTUP_HOME, "toolchains/pinned/bin/rustc");
    mkdirSync(join(rustc, ".."), { recursive: true });
    writeFileSync(rustc, "toolchain");
    await rust(hosts[0], "save");
    const { values: rustB, stdout: rustRestore } = await rust(
      hosts[1],
      "restore",
    );
    assert.match(rustRestore, /station-rust: restored/);
    for (const [variable, path, content] of rustEntries) {
      assert.equal(readFileSync(join(rustB[variable], path), "utf8"), content);
    }
    assert.equal(existsSync(join(rustB.CARGO_HOME, "credentials.toml")), false);
    // A key nothing was published under (a changed lockfile) starts from the
    // newest snapshot of any key: Cargo rebuilds only what changed.
    const { values: rustC, stdout: rustFallback } = await rust(
      hosts[2],
      "restore",
      "new-toolchain",
    );
    assert.match(rustFallback, /station-rust: restored rust-toolchain-and-lockfiles/);
    for (const [variable, path, content] of rustEntries) {
      assert.equal(readFileSync(join(rustC[variable], path), "utf8"), content);
    }
    assert.equal(existsSync(join(rustC.CARGO_HOME, "credentials.toml")), false);
    // The toolchain a job installed reaches another host's guest once, in a
    // snapshot of its own (one per version, not one per Rust key).
    assert.match(rustRestore, /rust-toolchain: restored rust-/);
    assert.equal(
      readFileSync(join(rustB.RUSTUP_HOME, "toolchains/pinned/bin/rustc"), "utf8"),
      "toolchain",
    );

    // A complete dependency archive transfers once and retains relative links.
    // A second producer cannot overwrite the immutable install for that key.
    const snapshot = async (host, mode, archive) =>
      run(
        "bash",
        [
          join(action, "synch-snapshot.sh"),
          mode,
          "node-modules",
          "fixture",
          archive,
        ],
        {
          env: {
            ...process.env,
            RUNNER_OS: "macOS",
            SYNCH_CACHE_SHARED_DIRECTORY: host.shared,
          },
        },
      );
    const source = join(root, "dependency-source");
    mkdirSync(join(source, "node_modules/dep"), { recursive: true });
    writeFileSync(join(source, "node_modules/dep/index.js"), "dependency");
    execFileSync("ln", ["-s", "dep", join(source, "node_modules/alias")]);
    const archiveA = join(root, "install-a.tar");
    const archiveB = join(root, "install-b.tar");
    execFileSync("tar", ["-cf", archiveA, "-C", source, "."]);
    await snapshot(hosts[0], "save", archiveA);
    await snapshot(hosts[1], "restore", archiveB);
    const restored = join(root, "dependency-restored");
    mkdirSync(restored);
    execFileSync("tar", ["-xf", archiveB, "-C", restored]);
    assert.equal(
      readFileSync(join(restored, "node_modules/alias/index.js"), "utf8"),
      "dependency",
    );
    const uploaded = puts.length;
    await snapshot(hosts[1], "save", archiveB);
    assert.equal(puts.length, uploaded);
    rmSync(archiveB);
    const object = [...objects.keys()].find((key) =>
      key.endsWith("/node-modules/fixture.tar"),
    );
    objects.set(object, {
      body: Buffer.from("truncated archive"),
      at: new Date().toISOString(),
    });
    await snapshot(hosts[1], "restore", archiveB);
    assert.equal(existsSync(archiveB), false);
    // Missing gateway configuration leaves a cold install to the caller.
    await snapshot({ shared: join(root, "no-gateway") }, "restore", archiveB);
    assert.equal(existsSync(archiveB), false);
  } finally {
    server.close();
    rmSync(root, { recursive: true, force: true });
  }
});

const installer = fileURLToPath(
  new URL(
    "../.github/actions/setup-macos-cache/install-node-modules.sh",
    import.meta.url,
  ),
);

test("a guest restores main's install and installs only what its lockfile changes", () => {
  const root = mkdtempSync(join(tmpdir(), "comma modules-"));
  try {
    const cache = join(root, "shared", "comma-node-modules");
    // pnpm stand-in: an install records "installed", or "updated" over a tree
    // restored from another lockfile; a restored tree of the same lockfile
    // only runs prepare, which records whether the dependencies were there.
    const bin = join(root, "bin");
    mkdirSync(bin);
    writeFileSync(
      join(bin, "pnpm"),
      [
        "#!/usr/bin/env bash",
        'if [[ "$1" == run ]]; then',
        '  if [[ -f node_modules/dep/index.js ]]; then echo reused >> "$INSTALL_LOG"; else echo missing >> "$INSTALL_LOG"; fi',
        "  exit 0",
        "fi",
        'if [[ -f node_modules/dep/index.js ]]; then echo updated >> "$INSTALL_LOG"; else echo installed >> "$INSTALL_LOG"; fi',
        "mkdir -p node_modules/dep packages/app/node_modules",
        "echo dependency > node_modules/dep/index.js",
        "ln -sfn ../../../node_modules/dep packages/app/node_modules/dep",
        "",
      ].join("\n"),
      { mode: 0o755 },
    );
    const install = (guest, lockfile, extraEnv = {}) => {
      const repo = join(root, guest);
      mkdirSync(join(repo, "clients"), { recursive: true });
      writeFileSync(join(repo, "pnpm-lock.yaml"), lockfile);
      execFileSync("git", ["init", "-q", repo]);
      const log = join(root, `${guest}.log`);
      execFileSync("bash", [installer], {
        cwd: repo,
        env: {
          ...process.env,
          PATH: `${bin}:${process.env.PATH}`,
          COMMA_NODE_MODULES_CACHE: cache,
          RUNNER_OS: "macOS",
          SYNCH_CACHE_SHARED_DIRECTORY: join(root, "isolated shared"),
          INSTALL_LOG: log,
          ...extraEnv,
        },
      });
      return { repo, result: readFileSync(log, "utf8").trim() };
    };
    const main = { GITHUB_EVENT_NAME: "push", GITHUB_REF: "refs/heads/main" };
    const branch = {
      GITHUB_EVENT_NAME: "pull_request",
      GITHUB_REF: "refs/pull/1/merge",
    };
    const snapshots = () =>
      readdirSync(join(cache, "main")).filter((name) => name.endsWith(".tar"));
    // Only main keeps its install.
    assert.equal(install("guest1", "lock: 1", main).result, "installed");
    assert.equal(snapshots().length, 1);
    const second = install("guest2", "lock: 1", branch);
    assert.equal(second.result, "reused");
    assert.equal(
      readFileSync(
        join(second.repo, "packages", "app", "node_modules", "dep", "index.js"),
        "utf8",
      ).trim(),
      "dependency",
    );
    // A branch on another lockfile starts from main's install and keeps none.
    assert.equal(install("guest3", "lock: 2", branch).result, "updated");
    assert.equal(snapshots().length, 1);
    // Main keeps its two newest installs.
    const [lock1] = snapshots();
    assert.equal(install("guest4", "lock: 2", main).result, "updated");
    assert.equal(snapshots().length, 2);
    const hourAgo = new Date(Date.now() - 3_600_000);
    utimesSync(join(cache, "main", lock1), hourAgo, hourAgo);
    assert.equal(install("guest5", "lock: 3", main).result, "updated");
    assert.deepEqual(snapshots().includes(lock1), false);
    assert.equal(snapshots().length, 2);
    // Archives of the earlier layout stay while a branch on the earlier
    // script still touches them, and go after three unused days.
    const fresh = join(cache, "fresh.tar");
    const stale = join(cache, "stale.tar");
    writeFileSync(fresh, "");
    writeFileSync(stale, "");
    const longAgo = new Date("2020-01-01T00:00:00Z");
    utimesSync(stale, longAgo, longAgo);
    install("guest6", "lock: 3", branch);
    assert.equal(existsSync(fresh), true);
    assert.equal(existsSync(stale), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a guest takes the npm mirror its LAN names, or its synch gateway's host, when it answers", async () => {
  const root = mkdtempSync(join(tmpdir(), "comma mirror-"));
  // The mirror runs in its own process: the selector below blocks this one.
  const server = spawn(
    process.execPath,
    [
      "-e",
      'const s = require("http").createServer((q, r) => r.end(q.url === "/-/ping" ? "{}" : "")); s.listen(0, "127.0.0.1", () => console.log(s.address().port));',
    ],
    { stdio: ["ignore", "pipe", "inherit"] },
  );
  try {
    const port = await new Promise((resolve) =>
      server.stdout.once("data", (data) => resolve(String(data).trim())),
    );
    const registry = (setup) => {
      const shared = join(root, setup, "cache");
      mkdirSync(shared, { recursive: true });
      const home = join(root, setup, "home");
      mkdirSync(home, { recursive: true });
      const env = join(root, `${setup}.env`);
      writeFileSync(env, "");
      return {
        shared,
        home,
        env,
        read: () =>
          readFileSync(env, "utf8").match(/^npm_config_registry=(.*)$/m)?.[1],
      };
    };
    const run = ({ shared, home, env }) =>
      execFileSync("bash", [selector, shared], {
        env: {
          ...process.env,
          HOME: home,
          RUNNER_OS: "macOS",
          RUNNER_NAME: "tokyo 1",
          RUNNER_TOOL_CACHE: join(home, "_tool"),
          GITHUB_ENV: env,
          GITHUB_OUTPUT: `${env}.output`,
        },
        stdio: "pipe",
      });
    // A host outside the synch cluster names its mirror beside its caches.
    const named = registry("named");
    writeFileSync(
      join(named.shared, "npm-mirror"),
      `http://127.0.0.1:${port}/\n`,
    );
    run(named);
    assert.equal(named.read(), `http://127.0.0.1:${port}/`);
    // Otherwise the mirror is on the host of the synch gateway; it does not answer here.
    const gateway = registry("gateway");
    mkdirSync(join(gateway.shared, "synch"));
    writeFileSync(
      join(gateway.shared, "synch", "s3.env"),
      "SYNCH_S3_ENDPOINT=http://127.0.0.2:9000\n",
    );
    run(gateway);
    assert.equal(gateway.read(), undefined);
  } finally {
    server.kill();
    rmSync(root, { recursive: true, force: true });
  }
});
