import { setDefaultTimeout, test } from "bun:test";
import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Builds and subprocesses here take longer than the five-second default.
setDefaultTimeout(30 * 60_000);

const REPO_ROOT = new URL("../../..", import.meta.url).pathname;
const INSTALLER =
  `${REPO_ROOT}/systems/connector/mac-mini-provisioner-install.sh`;

test("BFT runner install writes launchd HOME and PATH", async () => {
  const root = await mkdtemp(join(tmpdir(), "bft-runner-install-e2e-"));

  try {
    const paths = await writeArtifacts(root);
    const home = `${root}/home`;
    const prefix = `${root}/install`;
    await mkdir(home, { recursive: true });

    const result = await run("sh", [INSTALLER], {
      cwd: REPO_ROOT,
      env: installEnv({
        HOME: home,
        PATH: `${paths.toolDir}:${process.env.PATH ?? ""}`,
        BFT_INSTALL_PREFIX: prefix,
        BFT_SALIX_CONNECTOR_URL: paths.salixConnector.path,
        BFT_SALIX_CONNECTOR_SHA256: paths.salixConnector.sha256,
        BFT_SALIX_CONNECTOR_SIZE: String(paths.salixConnector.size),
        BFT_RUNNER_URL: paths.runner.path,
        BFT_RUNNER_SHA256: paths.runner.sha256,
        BFT_RUNNER_SIZE: String(paths.runner.size),
        BFT_AGENT_VMM_HOST_URL: paths.agentVMMHost.path,
        BFT_AGENT_VMM_HOST_SHA256: paths.agentVMMHost.sha256,
        BFT_AGENT_VMM_HOST_SIZE: String(paths.agentVMMHost.size),
        BFT_API_BASE_URL: "https://bridge.example.test",
        BFT_ORG_ID: "org_test",
        BFT_RUNNER_TOKEN: "bft_secret_token_should_not_be_logged",
      }),
    });

    if (result.code !== 0) {
      throw new Error(result.combined);
    }

    const plist = await readPlist(
      `${prefix}/com.bridgeforteams.runner.plist`,
    );
    assertHasKey(plist, "EnvironmentVariables");
    assertEquals(plist.EnvironmentVariables.HOME, home);
    const launchdPath = String(plist.EnvironmentVariables.PATH).split(":");

    assertIncludes(launchdPath, `${home}/.local/bin`);
    assertIncludes(launchdPath, `${home}/.npm-global/bin`);
    assertIncludes(launchdPath, `${home}/.asdf/shims`);
    assertIncludes(launchdPath, "/opt/homebrew/bin");
    assertIncludes(launchdPath, "/usr/local/bin");
    assertIncludes(launchdPath, "/usr/bin");
    assertArrayEquals(plist.ProgramArguments, [`${prefix}/bin/bft-runner`]);
  } finally {
    await rm(root, { recursive: true }).catch(() => {});
  }
});

test("BFT runner install accepts an explicit launchd PATH", async () => {
  const root = await mkdtemp(join(tmpdir(), "bft-runner-install-e2e-"));

  try {
    const paths = await writeArtifacts(root);
    const home = `${root}/home`;
    const prefix = `${root}/install`;
    const launchdPath = "/custom/bin:/usr/bin:/bin";
    await mkdir(home, { recursive: true });

    const result = await run("sh", [INSTALLER], {
      cwd: REPO_ROOT,
      env: installEnv({
        HOME: home,
        PATH: `${paths.toolDir}:${process.env.PATH ?? ""}`,
        BFT_INSTALL_PREFIX: prefix,
        BFT_SALIX_CONNECTOR_URL: paths.salixConnector.path,
        BFT_SALIX_CONNECTOR_SHA256: paths.salixConnector.sha256,
        BFT_SALIX_CONNECTOR_SIZE: String(paths.salixConnector.size),
        BFT_RUNNER_URL: paths.runner.path,
        BFT_RUNNER_SHA256: paths.runner.sha256,
        BFT_RUNNER_SIZE: String(paths.runner.size),
        BFT_AGENT_VMM_HOST_URL: paths.agentVMMHost.path,
        BFT_AGENT_VMM_HOST_SHA256: paths.agentVMMHost.sha256,
        BFT_AGENT_VMM_HOST_SIZE: String(paths.agentVMMHost.size),
        BFT_API_BASE_URL: "https://bridge.example.test",
        BFT_ORG_ID: "org_test",
        BFT_RUNNER_TOKEN: "bft_secret_token_should_not_be_logged",
        BFT_LAUNCHD_PATH: launchdPath,
      }),
    });

    if (result.code !== 0) {
      throw new Error(result.combined);
    }

    const plist = await readPlist(
      `${prefix}/com.bridgeforteams.runner.plist`,
    );
    assertHasKey(plist, "EnvironmentVariables");
    assertEquals(plist.EnvironmentVariables.PATH, launchdPath);
  } finally {
    await rm(root, { recursive: true }).catch(() => {});
  }
});

type Artifact = {
  path: string;
  sha256: string;
  size: number;
};

type RunOptions = {
  cwd?: string;
  env?: Record<string, string | undefined>;
};

function installEnv(
  values: Record<string, string>,
): Record<string, string | undefined> {
  const env = { ...process.env };
  delete env.BFT_LAUNCHD_PATH;
  return { ...env, ...values };
}

async function writeArtifacts(root: string) {
  const dir = `${root}/artifacts`;
  const toolDir = `${root}/tools`;
  await mkdir(dir, { recursive: true });
  await mkdir(toolDir, { recursive: true });

  const salixConnector = await writeExecutable(
    `${dir}/salix-connector`,
    "#!/bin/sh\nprintf 'fake salix connector\\n'\n",
  );
  const runner = await writeExecutable(
    `${dir}/mac-mini-provisioner`,
    "#!/bin/sh\nprintf 'fake bft runner\\n'\n",
  );
  const agentVMMHost = await writeAgentVMMHostArchive(root, dir);
  await writeExecutable(`${toolDir}/codesign`, "#!/bin/sh\nexit 0\n");
  await writeExecutable(
    `${toolDir}/ditto`,
    [
      "#!/usr/bin/env python3",
      "import os, pathlib, shutil, sys, zipfile",
      "args = sys.argv[1:]",
      "if args[:2] == ['-x', '-k']:",
      "    with zipfile.ZipFile(args[2]) as archive:",
      "        archive.extractall(args[3])",
      "        for entry in archive.infolist():",
      "            mode = (entry.external_attr >> 16) & 0o777",
      "            if mode:",
      "                os.chmod(pathlib.Path(args[3], entry.filename), mode)",
      "else:",
      "    shutil.copytree(args[0], args[1])",
      "",
    ].join("\n"),
  );

  return {
    salixConnector,
    runner,
    agentVMMHost,
    toolDir,
  };
}

async function writeExecutable(path: string, body: string): Promise<Artifact> {
  await writeFile(path, body);
  await chmod(path, 0o755);

  return artifactAt(path);
}

async function artifactAt(path: string): Promise<Artifact> {
  return {
    path,
    sha256: await sha256Hex(await readFile(path)),
    size: (await stat(path)).size,
  };
}

async function writeAgentVMMHostArchive(
  root: string,
  artifactDir: string,
): Promise<Artifact> {
  const app = `${root}/bundle/Agent VMM Host.app`;
  const executable = `${app}/Contents/MacOS/agent-vmm-host`;
  const helper = `${app}/Contents/Helpers/agent-vmm-lifecycle`;
  await mkdir(`${app}/Contents/MacOS`, { recursive: true });
  await mkdir(`${app}/Contents/Helpers`, { recursive: true });
  await writeExecutable(executable, "#!/bin/sh\nexit 0\n");
  await writeExecutable(
    helper,
    [
      "#!/bin/sh",
      'if [ "$1" = "version" ]; then',
      '  printf \'%s\\n\' \'{"version":"release-test","release_id":"release-test"}\'',
      "  exit 0",
      "fi",
      'if [ "$1" = "status" ]; then',
      '  printf \'%s\\n\' \'{"hostInstalled":true,"hostLoaded":true,"hostReadable":true,"hostHealthy":true}\'',
      "fi",
      "exit 0",
      "",
    ].join("\n"),
  );
  await writeExecutable(
    `${app}/Contents/Helpers/agent-vmm`,
    "#!/bin/sh\nexit 0\n",
  );
  await writeExecutable(
    `${app}/Contents/Helpers/agent-vmm-service-executor`,
    "#!/bin/sh\nexit 0\n",
  );
  const archive = `${artifactDir}/agent-vmm-host.zip`;
  const result = await run("python3", [
    "-c",
    [
      "import pathlib, sys, zipfile",
      "app = pathlib.Path(sys.argv[1])",
      "with zipfile.ZipFile(sys.argv[2], 'w', zipfile.ZIP_DEFLATED) as output:",
      "    for path in sorted(app.rglob('*')):",
      "        output.write(path, path.relative_to(app.parent))",
    ].join("\n"),
    app,
    archive,
  ]);
  if (result.code !== 0) throw new Error(result.combined);
  return artifactAt(archive);
}

async function sha256Hex(data: Uint8Array): Promise<string> {
  const copy = new Uint8Array(data.byteLength);
  copy.set(data);
  const digest = await crypto.subtle.digest("SHA-256", copy.buffer);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function readPlist(path: string): Promise<Record<string, any>> {
  const result = await run("python3", [
    "-c",
    "import json, plistlib, sys; print(json.dumps(plistlib.load(open(sys.argv[1], 'rb'))))",
    path,
  ]);

  if (result.code !== 0) {
    throw new Error(result.combined);
  }

  return JSON.parse(result.stdout);
}

async function run(command: string, args: string[], opts: RunOptions = {}) {
  const child = Bun.spawn([command, ...args], {
    cwd: opts.cwd,
    env: opts.env,
    stdout: "pipe",
    stderr: "pipe",
  });

  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);

  return {
    code,
    success: code === 0,
    stdout,
    stderr,
    combined: stdout + stderr,
  };
}

function assertIncludes<T>(values: T[], expected: T) {
  if (!values.includes(expected)) {
    throw new Error(
      `expected ${JSON.stringify(values)} to include ${
        JSON.stringify(
          expected,
        )
      }`,
    );
  }
}

function assertArrayEquals(actual: unknown, expected: unknown[]) {
  assertEquals(JSON.stringify(actual), JSON.stringify(expected));
}

function assertHasKey(value: Record<string, any>, key: string) {
  if (!(key in value)) {
    throw new Error(`expected object to include key ${JSON.stringify(key)}`);
  }
}

function assertEquals(actual: unknown, expected: unknown) {
  if (actual !== expected) {
    throw new Error(
      `expected ${JSON.stringify(actual)} to equal ${JSON.stringify(expected)}`,
    );
  }
}
