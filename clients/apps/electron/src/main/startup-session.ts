import { existsSync, readFileSync } from "node:fs";
import type { SecureSessionInput } from "./secure-store";

const startupSessionExpiresAtEpochSeconds = 4_102_444_800;

interface ElectronStartupSessionEnv {
  COMMA_ELECTRON_STARTUP_SESSION_EMAIL?: string | undefined;
  COMMA_ELECTRON_STARTUP_SESSION_FILE?: string | undefined;
  COMMA_ELECTRON_STARTUP_SESSION_TOKEN?: string | undefined;
}

interface ElectronStartupSessionFile {
  apiBaseUrl: string;
  email: string;
  sessionToken: string;
  version: 1;
}

/**
 * Resolves one explicit unpackaged startup Session seed. Local development
 * keeps its seed in a gitignored file so Electron Forge can relaunch Main
 * without losing the login. E2E can still provide the same seed through its
 * isolated process environment. Test-only behavior belongs in separate E2E
 * hooks. Environment bearers are consumed so native child processes cannot
 * inherit them after SecureSessionStore owns the credential.
 */
export function resolveElectronStartupSession({
  apiBaseUrl,
  defaultFilePath,
  env = process.env,
  isPackaged,
  fileExists = existsSync,
  readFile = readFileSync,
}: {
  apiBaseUrl: string;
  defaultFilePath?: string | undefined;
  env?: ElectronStartupSessionEnv;
  isPackaged: boolean;
  fileExists?: (path: string) => boolean;
  readFile?: (path: string, encoding: "utf8") => string;
}): SecureSessionInput | undefined {
  const explicitFilePath = env.COMMA_ELECTRON_STARTUP_SESSION_FILE?.trim();
  const filePath = explicitFilePath || defaultFilePath;
  const token = env.COMMA_ELECTRON_STARTUP_SESSION_TOKEN?.trim();
  delete env.COMMA_ELECTRON_STARTUP_SESSION_TOKEN;

  if (isPackaged) return undefined;

  if (filePath && (explicitFilePath || fileExists(filePath))) {
    const config = parseStartupSessionFile(filePath, readFile(filePath, "utf8"));
    if (canonicalAudience(config.apiBaseUrl) !== canonicalAudience(apiBaseUrl)) {
      throw new Error(
        `Comma development Session file ${filePath} targets ${config.apiBaseUrl}, ` +
          `but this client targets ${apiBaseUrl}.`
      );
    }
    return startupSessionInput(apiBaseUrl, config.email, config.sessionToken);
  }

  if (!token) return undefined;

  const email =
    env.COMMA_ELECTRON_STARTUP_SESSION_EMAIL?.trim().toLowerCase() ||
    "comma-local@example.com";
  return startupSessionInput(apiBaseUrl, email, token);
}

function parseStartupSessionFile(
  filePath: string,
  source: string
): ElectronStartupSessionFile {
  let value: unknown;
  try {
    value = JSON.parse(source);
  } catch (error) {
    throw new Error(`Comma development Session file ${filePath} is not valid JSON.`, {
      cause: error,
    });
  }

  if (
    !value ||
    typeof value !== "object" ||
    (value as Partial<ElectronStartupSessionFile>).version !== 1 ||
    typeof (value as Partial<ElectronStartupSessionFile>).apiBaseUrl !== "string" ||
    !(value as Partial<ElectronStartupSessionFile>).apiBaseUrl?.trim() ||
    typeof (value as Partial<ElectronStartupSessionFile>).email !== "string" ||
    !(value as Partial<ElectronStartupSessionFile>).email?.trim() ||
    typeof (value as Partial<ElectronStartupSessionFile>).sessionToken !== "string" ||
    !(value as Partial<ElectronStartupSessionFile>).sessionToken?.trim()
  ) {
    throw new Error(
      `Comma development Session file ${filePath} must contain version, apiBaseUrl, email, and sessionToken.`
    );
  }

  const config = value as ElectronStartupSessionFile;
  return {
    apiBaseUrl: config.apiBaseUrl.trim(),
    email: config.email.trim().toLowerCase(),
    sessionToken: config.sessionToken.trim(),
    version: 1,
  };
}

function canonicalAudience(value: string): string {
  return value.replace(/\/+$/, "");
}

function startupSessionInput(
  apiBaseUrl: string,
  email: string,
  token: string
): SecureSessionInput {
  return {
    audience: apiBaseUrl,
    email,
    expiresAtEpochSeconds: startupSessionExpiresAtEpochSeconds,
    sessionId: `startup-session:${email}`,
    token,
    userId: `startup-user:${email}`,
  };
}
