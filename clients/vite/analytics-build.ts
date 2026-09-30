import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

/** Build attribution only; no credentials or runtime configuration discovery. */
export function analyticsBuildDefines(packageDir: string) {
  let sha = process.env.GITHUB_SHA ?? "";
  if (!sha) {
    try {
      sha = execFileSync("git", ["rev-parse", "HEAD"], {
        cwd: packageDir,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      }).trim();
    } catch {
      // Source archives may not have git metadata.
    }
  }
  const { version } = JSON.parse(
    readFileSync(resolve(packageDir, "package.json"), "utf8")
  );
  return {
    COMMA_DEFINED_APP_VERSION: JSON.stringify(version),
    COMMA_DEFINED_BUILD_SHA: JSON.stringify(
      /^[a-f0-9]{40}$/i.test(sha) ? sha : "unknown"
    ),
  };
}
