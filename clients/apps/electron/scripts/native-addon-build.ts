import { execFileSync } from "node:child_process";
import { arch } from "node:process";
import { resolve } from "node:path";
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
  runNodeGyp = (args, cwd) => run(nodeGypPath, args, cwd),
}: {
  addonDir: string;
  label: string;
  output: string;
  targetName: string;
  nodeGypPath: string;
  configuration: "release" | "debug";
  incremental: boolean;
  /** Runs node-gyp at nodeGypPath. Tests substitute an in-process node-gyp. */
  runNodeGyp?: (args: string[], cwd: string) => void;
}) {
  const nodeGypConfiguration = configuration === "release" ? "Release" : "Debug";
  const flag = configuration === "release" ? "--release" : "--debug";
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
    runNodeGyp(["configure", flag], addonDir);
    runNodeGyp(["build", flag], addonDir);
  } else {
    runNodeGyp(["rebuild", flag], addonDir);
  }
  cache.save();
  copyNativeFile(
    resolve(addonDir, "build", nodeGypConfiguration, `${targetName}.node`),
    output,
    incremental
  );

  console.log(`${label} built (${configuration}).`);
}
