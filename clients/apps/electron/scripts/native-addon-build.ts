import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { arch } from "node:process";
import { dirname, resolve } from "node:path";
import {
  NativeInstallCache,
  copyNativeFile,
  snapshotPaths,
} from "./native-build-cache";

function run(command: string, args: string[], cwd: string) {
  execFileSync(command, [...args, "--loglevel=warn"], { cwd, stdio: "inherit" });
}

const addonBuildEnvironment = [
  "PATH",
  "CC",
  "CXX",
  "AR",
  "CFLAGS",
  "CXXFLAGS",
  "CPPFLAGS",
  "LDFLAGS",
  "MAKE",
  "SDKROOT",
  "DEVELOPER_DIR",
  "MACOSX_DEPLOYMENT_TARGET",
  "PYTHON",
  "NODE_GYP_FORCE_PYTHON",
  "npm_config_target",
  "npm_config_arch",
  "npm_config_nodedir",
  "npm_config_disturl",
  "npm_config_devdir",
  "npm_config_python",
  "npm_config_msvs_version",
];
/**
 * The install prefix of the Node running this build, when it carries its own
 * headers (Homebrew and the nodejs.org packages do). Without `--nodedir`,
 * node-gyp downloads the same headers from nodejs.org into its cache.
 */
function localNodeDir() {
  if (process.env.npm_config_nodedir) return undefined;
  const prefix = resolve(dirname(process.execPath), "..");
  return existsSync(resolve(prefix, "include/node/common.gypi")) ? prefix : undefined;
}

const addonToolchains = new Map<string, unknown>();
function nativeAddonToolchain(nodeGypPath: string) {
  if (addonToolchains.has(nodeGypPath)) return addonToolchains.get(nodeGypPath);
  const toolchain = {
    node: snapshotPaths([process.execPath]),
    gyp: snapshotPaths([nodeGypPath]),
    compiler: execFileSync("xcrun", ["clang", "--version"], { encoding: "utf8" }),
    sdk: execFileSync("xcrun", ["--show-sdk-path"], { encoding: "utf8" }),
  };
  addonToolchains.set(nodeGypPath, toolchain);
  return toolchain;
}

export function buildNativeAddon({
  addonDir,
  label,
  output,
  targetName,
  nodeGypPath,
  configuration,
  incremental,
  nodeDir = localNodeDir(),
  runNodeGyp = (args, cwd) => run(nodeGypPath, args, cwd),
}: {
  addonDir: string;
  label: string;
  output: string;
  targetName: string;
  nodeGypPath: string;
  configuration: "release" | "debug";
  incremental: boolean;
  /** Node's headers for node-gyp; undefined lets node-gyp fetch them. */
  nodeDir?: string;
  /** Runs node-gyp at nodeGypPath. Tests substitute an in-process node-gyp. */
  runNodeGyp?: (args: string[], cwd: string) => void;
}) {
  const nodeGypConfiguration = configuration === "release" ? "Release" : "Debug";
  const flag = configuration === "release" ? "--release" : "--debug";
  const headers = nodeDir ? [`--nodedir=${nodeDir}`] : [];
  const cache = new NativeInstallCache(
    resolve(addonDir, "build/comma-configuration.json"),
    incremental,
    {
      configuration,
      arch,
      node: process.version,
      nodeConfig: process.config,
      tools: incremental ? nativeAddonToolchain(nodeGypPath) : null,
      environment: Object.fromEntries(
        addonBuildEnvironment.map((key) => [key, process.env[key]])
      ),
    },
    [resolve(addonDir, "build/config.gypi")]
  );
  const reuse = cache.reuse();
  if (reuse) {
    // GYP reads binding.gyp and included files. Make retains object files and
    // checks source/header dependencies and compiler command changes.
    runNodeGyp(["configure", flag, ...headers], addonDir);
    runNodeGyp(["build", flag], addonDir);
  } else {
    runNodeGyp(["rebuild", flag, ...headers], addonDir);
  }
  cache.save();
  copyNativeFile(
    resolve(addonDir, "build", nodeGypConfiguration, `${targetName}.node`),
    output,
    incremental
  );

  console.log(`${label} built (${configuration}).`);
}
