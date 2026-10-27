// Where Computer Use's helper app and daemon socket live. The socket is per runtime (namespace or root), under the
// temp directory, and always fits macOS's 104-byte Unix socket path.
import { createHash } from "node:crypto";
import { realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, normalize, resolve } from "node:path";
import { platform } from "../platform/index.ts";

export const COMPUTER_USE_HELLO_MESSAGE = "comma-computer-use-daemon";
export const COMPUTER_USE_SOCKET_DIRECTORY_NAME = "comma-computer-use";
export const COMPUTER_USE_SOCKET_FILE_NAME = "computeruse.sock";
export const COMPUTER_USE_SOCKET_PATH_MAX_BYTES = 104;
const SOCKET_HASH_LENGTH = 16;
const SOCKET_LABEL_LENGTH = 12;

/** Desktop builds name the helper for their release flavor. */
export const COMPUTER_USE_HELPER_APP_NAME = process.env.COMMA_COMPUTER_USE_HELPER_APP_NAME ?? "Comma Computer Use.app";

/** The helper ships beside the station executable, under native/macos (Cua Driver under native/windows). */
export function defaultComputerUseHelperAppPath(executable = process.execPath): string {
  if (platform.hasWindowsComputerUse) return join(dirname(executable), "native", "windows", "cua-driver.exe");
  if (!platform.hasComputerUse) return "";
  return join(dirname(executable), "native", "macos", COMPUTER_USE_HELPER_APP_NAME);
}

export function defaultComputerUseSocketPath(): string {
  return computerUseSocketPathForRuntime("", "");
}

export function computerUseSocketPathForRuntime(runtimeNamespace: string, runtimeRoot: string, tempRoot = normalize(tmpdir())): string {
  if (!platform.hasComputerUse) return "";
  const identity = computerUseSocketIdentity(runtimeNamespace, runtimeRoot);
  const fileName = identity ? `${identity}.sock` : COMPUTER_USE_SOCKET_FILE_NAME;
  const path = join(tempRoot, COMPUTER_USE_SOCKET_DIRECTORY_NAME, fileName);
  if (Buffer.byteLength(path) + 1 <= COMPUTER_USE_SOCKET_PATH_MAX_BYTES) return path;
  // TMPDIR can be long: fall back to a compact per-user directory keyed by it (a path identity, not a security check).
  const tempIdentity = createHash("sha256").update(tempRoot).digest("hex").slice(0, 12);
  return join("/tmp", `comma-cu-${tempIdentity}`, fileName);
}

export function computerUseSocketIdentity(runtimeNamespace: string, runtimeRoot: string): string {
  let root = canonicalRuntimeRoot(runtimeRoot);
  if (!root) {
    const namespace = runtimeNamespace.trim();
    if (!namespace) return "";
    root = `namespace:${namespace}`;
  }
  let label = safeRuntimeNamespace(runtimeNamespace).replace(/^[@\-_.]+|[@\-_.]+$/g, "");
  if (!label) label = "comma";
  label = label.slice(0, SOCKET_LABEL_LENGTH);
  const digest = createHash("sha256").update(root).digest("hex").slice(0, SOCKET_HASH_LENGTH);
  return `${label}-${digest}`;
}

function canonicalRuntimeRoot(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) return "";
  const absolute = resolve(trimmed);
  try {
    return normalize(realpathSync(absolute));
  } catch {
    return absolute;
  }
}

function safeRuntimeNamespace(value: string): string {
  return value
    .trim()
    .replace(/[^a-zA-Z0-9@\-_.]/gu, "_")
    .replace(/^\.+|\.+$/g, "");
}
