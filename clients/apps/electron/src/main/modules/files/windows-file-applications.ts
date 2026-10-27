import { execFile } from "node:child_process";
import { win32 } from "node:path";
import { promisify } from "node:util";
import type { FileApplicationsPlatform } from "./open-applications";

const runFile = promisify(execFile);

type RunFile = (
  file: string,
  args: string[],
  options: { env: NodeJS.ProcessEnv; timeout: number; windowsHide: boolean }
) => Promise<unknown>;

/** The variable the copied path reaches PowerShell in, so no path is ever parsed as script. */
const copyPathVariable = "COMMA_COPY_FILE_PATH";

/**
 * Windows' part of the file applications: copying a file to the clipboard, so
 * Explorer and other apps paste the file itself. Electron's clipboard writes
 * text and images only; Windows PowerShell's `Set-Clipboard -LiteralPath`
 * (every Windows 10 and 11 has it) puts the file on it as a file drop list
 * (CF_HDROP). Listing and opening with other applications stays macOS'.
 */
export function windowsFileApplications({
  env = process.env,
  run = runFile,
  timeoutMs = 30_000,
}: {
  env?: NodeJS.ProcessEnv;
  run?: RunFile;
  timeoutMs?: number;
} = {}): FileApplicationsPlatform {
  // System32's own PowerShell, not whichever one comes first on PATH.
  const powershell = win32.join(
    env.SystemRoot ?? "C:\\Windows",
    "System32",
    "WindowsPowerShell",
    "v1.0",
    "powershell.exe"
  );
  return {
    listApplicationsForFileName: async () => null,
    listApplicationsForFile: async () => null,
    openFileWithApplication: async () => false,
    copyFileToClipboard: async (path) => {
      try {
        await run(
          powershell,
          [
            "-NoProfile",
            "-NonInteractive",
            // The clipboard needs a single-threaded apartment.
            "-STA",
            "-Command",
            `Set-Clipboard -ErrorAction Stop -LiteralPath $env:${copyPathVariable}`,
          ],
          {
            env: { ...env, [copyPathVariable]: path },
            timeout: timeoutMs,
            windowsHide: true,
          }
        );
        return true;
      } catch {
        return false;
      }
    },
  };
}
