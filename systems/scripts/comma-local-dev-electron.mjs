import { spawn } from "node:child_process";
import { chmod, mkdir, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { seedLocalDev } from "./comma-local-dev-seed.mjs";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
export const localDevSessionFilePath = path.join(
  repositoryRoot,
  ".local/comma-dev-session.json",
);

export function localDevElectronEnvironment(
  seed,
  source = process.env,
  sessionFilePath = localDevSessionFilePath,
) {
  const environment = Object.fromEntries(
    Object.entries(source).filter(
      ([name]) =>
        !name.startsWith("COMMA_ELECTRON_E2E_") &&
        !name.startsWith("COMMA_ELECTRON_STARTUP_SESSION_"),
    ),
  );
  return {
    ...environment,
    COMMA_API_BASE_URL: seed.apiBaseUrl,
    COMMA_ELECTRON_STARTUP_SESSION_FILE: sessionFilePath,
    // Local auto-login is deliberately independent from the E2E fixture mode,
    // whose static Connector status file disables real supervision.
    NODE_ENV: "development",
  };
}

export async function writeLocalDevSessionFile(
  seed,
  filePath = localDevSessionFilePath,
) {
  const contents = JSON.stringify(
    {
      apiBaseUrl: seed.apiBaseUrl,
      email: seed.email,
      sessionToken: seed.sessionToken,
      version: 1,
    },
    null,
    2,
  );
  const temporaryPath = `${filePath}.${process.pid}.tmp`;

  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(temporaryPath, `${contents}\n`, { mode: 0o600 });
  await rename(temporaryPath, filePath);
  await chmod(filePath, 0o600);
  return filePath;
}

export async function runLocalDevElectron({
  seed = seedLocalDev,
  spawnProcess = spawn,
} = {}) {
  const seeded = await seed();
  const sessionFilePath = await writeLocalDevSessionFile(seeded);
  process.stdout.write(
    `Starting Comma Dev as ${seeded.email} against ${seeded.apiBaseUrl} ` +
      `with the real Connector runtime. Login seed: ${path.relative(
        repositoryRoot,
        sessionFilePath,
      )}.\n`,
  );

  const child = spawnProcess("pnpm", ["--dir", "clients", "dev:electron"], {
    cwd: repositoryRoot,
    env: localDevElectronEnvironment(seeded, process.env, sessionFilePath),
    stdio: "inherit",
  });

  return new Promise((resolve, reject) => {
    const forward = (signal) => child.kill(signal);
    const onSigint = () => forward("SIGINT");
    const onSigterm = () => forward("SIGTERM");
    process.once("SIGINT", onSigint);
    process.once("SIGTERM", onSigterm);

    const cleanup = () => {
      process.removeListener("SIGINT", onSigint);
      process.removeListener("SIGTERM", onSigterm);
    };
    child.once("error", (error) => {
      cleanup();
      reject(error);
    });
    child.once("exit", (code, signal) => {
      cleanup();
      resolve(code ?? (signal ? 1 : 0));
    });
  });
}

function isMainModule() {
  return Boolean(
    process.argv[1] &&
    fileURLToPath(import.meta.url) === path.resolve(process.argv[1]),
  );
}

if (isMainModule()) {
  runLocalDevElectron()
    .then((code) => {
      process.exitCode = code;
    })
    .catch((error) => {
      console.error(error instanceof Error ? error.message : String(error));
      process.exitCode = 1;
    });
}
