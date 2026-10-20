import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { buildNativeAddon } from "../scripts/native-addon-build";
import { NativeInstallCache, snapshotPaths } from "../scripts/native-build-cache";
import { fetchOpenDropKit } from "../scripts/opendropkit-release";
import { describeMenuBarHost } from "./support/menu-bar-host-checks";

const roots: string[] = [];
function fixture() {
  const root = mkdtempSync(join(tmpdir(), "comma-native-build-"));
  roots.push(root);
  return root;
}
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

it("reinstalls bundles after a resource change, missing output, or failed installation", () => {
  const root = fixture();
  const resource = join(root, "resource");
  const bundle = join(root, "Helper.app");
  mkdirSync(bundle);
  writeFileSync(resource, "first");
  const output = join(bundle, "resource");
  const cache = (identity = "dev") =>
    new NativeInstallCache(
      join(root, "receipt.json"),
      true,
      { source: snapshotPaths([resource]), identity },
      [bundle]
    );
  expect(cache().reuse()).toBe(false);
  writeFileSync(output, "first");
  cache().save();
  expect(cache().reuse()).toBe(true);

  writeFileSync(resource, "second");
  expect(cache().reuse()).toBe(false);
  // An interrupted installer cannot make the old bundle current.
  expect(cache().reuse()).toBe(false);
  writeFileSync(output, "second");
  cache().save();
  expect(cache().reuse()).toBe(true);
  rmSync(output);
  expect(cache().reuse()).toBe(false);
  writeFileSync(output, "second");
  cache().save();
  expect(cache("staging").reuse()).toBe(false);
});

describe.skipIf(process.platform !== "darwin")("native build integration", () => {
  it("builds Computer Use without touching its installed app, then packages existing outputs", () => {
    const root = fixture();
    const bin = join(root, "bin");
    const tools = join(root, "tools");
    const packageDir = join(root, "package");
    const resources = join(packageDir, "Sources/CommaComputerUseDaemon/Resources");
    const app = join(root, "Helper.app");
    for (const path of [bin, tools, resources, app])
      mkdirSync(path, { recursive: true });
    for (const name of [
      "ComputerUseHost_CommaComputerUseDaemon.bundle",
      "ComputerUseHost_CUShared.bundle",
      "ComputerUseHost_CUForeground.bundle",
      "PermissionFlow_PermissionFlow.bundle",
    ]) {
      mkdirSync(join(bin, name));
      writeFileSync(join(bin, name, "resource.txt"), "fixture resource");
    }
    execFileSync(
      "xcrun",
      ["clang", "-x", "c", "-", "-o", join(bin, "CommaComputerUseDaemon")],
      { input: "int main() { return 0; }" }
    );
    writeFileSync(
      join(resources, "panel-logo.png"),
      Buffer.from(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1EAAAAASUVORK5CYII=",
        "base64"
      )
    );
    // Isolate dependency resolution, compilation and icon rendering. Packaging,
    // signing and the packaged executable use macOS tools.
    writeFileSync(join(tools, "git"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    writeFileSync(join(tools, "sips"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    writeFileSync(
      join(tools, "iconutil"),
      `#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = -o ] && : > "$2"; shift; done
`,
      { mode: 0o755 }
    );
    writeFileSync(
      join(tools, "swift"),
      `#!/bin/sh
case "$*" in
  *--show-bin-path*) printf '%s\\n' "$FIXTURE_BIN" ;;
  *) printf '%s\\n' "$*" >> "$FIXTURE_BUILD_LOG" ;;
esac
`,
      { mode: 0o755 }
    );
    const log = join(root, "build.log");
    const marker = join(app, "installed");
    writeFileSync(marker, "existing app");
    const script = resolve(
      import.meta.dirname,
      "../../../../systems/connector/salix-connect/scripts/package-computer-use-helper.sh"
    );
    const run = (mode: string) =>
      execFileSync(
        "bash",
        [
          script,
          "--package-path",
          packageDir,
          "--app-path",
          app,
          "--stop-running",
          mode,
        ],
        {
          env: {
            ...process.env,
            PATH: `${tools}:${process.env.PATH}`,
            FIXTURE_BIN: bin,
            FIXTURE_BUILD_LOG: log,
          },
          stdio: "pipe",
        }
      );
    run("--build-only");
    expect(readFileSync(marker, "utf8")).toBe("existing app");
    const builds = readFileSync(log, "utf8");
    expect(builds).toContain("build");
    run("--package-only");
    expect(readFileSync(log, "utf8")).toBe(builds);
    execFileSync("codesign", ["--verify", "--deep", "--strict", app]);
    execFileSync(join(app, "Contents/MacOS/CommaComputerUseDaemon"));
    expect(
      readFileSync(
        join(
          app,
          "Contents/Resources/PermissionFlow_PermissionFlow.bundle/resource.txt"
        ),
        "utf8"
      )
    ).toBe("fixture resource");
  }, 30_000);

  it("builds incrementally while the toolchain is unchanged, restores deleted outputs, and rebuilds a new configuration", () => {
    const root = fixture();
    const output = join(root, "dist/addon.node");
    // node-gyp's own Make files decide which objects to recompile. Under test
    // is the choice between an incremental build and a clean rebuild, and the
    // installed output. The node-gyp file only identifies the toolchain; an
    // in-process node-gyp writes what the real one would.
    const nodeGypPath = join(root, "node-gyp");
    writeFileSync(nodeGypPath, "node-gyp fixture");
    let log: string[] = [];
    const runNodeGyp = ([command, flag]: string[], cwd: string) => {
      log.push(`${command} ${flag}`);
      const build = join(cwd, "build");
      if (command === "rebuild") rmSync(build, { recursive: true, force: true });
      if (command === "configure" || command === "rebuild") {
        mkdirSync(build, { recursive: true });
        writeFileSync(join(build, "config.gypi"), flag!);
      }
      if (command === "build" || command === "rebuild") {
        const configuration = join(build, flag === "--release" ? "Release" : "Debug");
        mkdirSync(configuration, { recursive: true });
        writeFileSync(
          join(configuration, "fixture.node"),
          readFileSync(join(cwd, "value"))
        );
      }
    };
    writeFileSync(join(root, "value"), "1");
    const options = {
      addonDir: root,
      output,
      targetName: "fixture",
      label: "Fixture addon",
      nodeGypPath,
      configuration: "debug" as const,
      incremental: true,
      runNodeGyp,
    };
    const build = (overrides: { configuration?: "debug" | "release" } = {}) => {
      log = [];
      buildNativeAddon({ ...options, ...overrides });
      return log;
    };
    expect(build()).toEqual(["rebuild --debug"]);
    expect(readFileSync(output, "utf8")).toBe("1");
    const outputTime = statSync(output).mtimeMs;
    expect(build()).toEqual(["configure --debug", "build --debug"]);
    // An unchanged addon keeps its installed file.
    expect(statSync(output).mtimeMs).toBe(outputTime);

    writeFileSync(join(root, "value"), "2");
    expect(build()).toEqual(["configure --debug", "build --debug"]);
    expect(readFileSync(output, "utf8")).toBe("2");
    rmSync(output);
    expect(build()).toEqual(["configure --debug", "build --debug"]);
    expect(readFileSync(output, "utf8")).toBe("2");
    expect(build({ configuration: "release" })).toEqual(["rebuild --release"]);
    expect(readFileSync(output, "utf8")).toBe("2");
  });

  it("reuses a signed release offline, repairs missing outputs, and detects local override changes", async () => {
    const root = fixture();
    const source = join(root, "source");
    mkdirSync(source);
    const binary = join(source, "opendropkit");
    const compile = (code: number) =>
      execFileSync("xcrun", ["clang", "-x", "c", "-", "-o", binary], {
        input: `int main() { return ${code}; }`,
      });
    compile(0);
    writeFileSync(join(source, "OpenDropKit-LICENSE"), "fixture license");
    const archive = join(root, "source.tar.gz");
    execFileSync("tar", ["-czf", archive, "-C", root, "source"]);
    const bytes = readFileSync(archive);
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValue(new Response(new Uint8Array(bytes)));
    const options = {
      appDir: join(root, "app"),
      platform: "darwin",
      arch: process.arch,
      incremental: true,
      fetch,
      release: {
        tag: "fixture",
        archives: {
          [`darwin/${process.arch}`]: {
            archive: "source.tar.gz",
            sha256: createHash("sha256").update(bytes).digest("hex"),
          },
        },
      },
    };
    const installed = join(
      options.appDir,
      "dist/native/darwin",
      process.arch,
      "opendropkit"
    );
    await fetchOpenDropKit(options);
    const installedTime = statSync(installed).mtimeMs;
    fetch.mockRejectedValue(new Error("offline"));
    await fetchOpenDropKit(options);
    expect(statSync(installed).mtimeMs).toBe(installedTime);
    expect(fetch).toHaveBeenCalledTimes(1);
    rmSync(installed);
    await fetchOpenDropKit(options);
    execFileSync(installed);

    await fetchOpenDropKit({ ...options, binaryOverride: binary });
    const overrideTime = statSync(installed).mtimeMs;
    await fetchOpenDropKit({ ...options, binaryOverride: binary });
    expect(statSync(installed).mtimeMs).toBe(overrideTime);
    compile(7);
    await fetchOpenDropKit({ ...options, binaryOverride: binary });
    expect(() => execFileSync(installed)).toThrow();
    // Removing the override restores the pinned release from the archive cache.
    await fetchOpenDropKit(options);
    execFileSync(installed);
  }, 30_000);
});

describeMenuBarHost();
