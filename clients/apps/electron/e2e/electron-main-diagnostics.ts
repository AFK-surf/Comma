import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

/** Bounds each external diagnostic tool, so a failed test's teardown stays within its budget. */
const toolBoundMs = 15_000;

/**
 * Native evidence from a Main that may be hung: the stacks of all its threads
 * and, on macOS, the app the desktop has in front. When that app is not this
 * Electron, the report also lists its windows and, for a system alert, the log
 * of who asked for it. Nothing here throws: a missing tool or a denied
 * permission becomes a line in the report.
 *
 * Nothing here sends an Apple event: one to System Events makes macOS ask the
 * runner for consent in an alert, which stays in front for the rest of the
 * job, and every later test that needs its app in front fails.
 */
export async function describeElectronMain(pid: number): Promise<string> {
  const title = `Electron main process ${pid}`;
  if (process.platform !== "darwin")
    return [title, await threadStacks(pid)].join("\n\n");
  const front = await frontApp();
  const stacks = await threadStacks(pid);
  const otherPid = front.pid === pid ? undefined : front.pid;
  const others = await Promise.all(
    otherPid === undefined
      ? []
      : [frontAppWindows(otherPid), ...(front.systemAlert ? [systemAlertLog()] : [])]
  );
  return [title, stacks, front.report, ...others].join("\n\n");
}

// A wait for a window's focus never ends on a desktop that keeps another app
// in front: the report names that app.
async function frontApp() {
  const answer = await tool("sh", [
    "-c",
    'lsappinfo info -only name -only pid "$(lsappinfo front)"',
  ]);
  const pid = /"pid"=(\d+)/.exec(answer)?.[1];
  return {
    report: `Front app:\n${answer}`,
    pid: pid === undefined ? undefined : Number(pid),
    // The agent that shows the alerts of other processes (a consent prompt, a daemon's notice).
    systemAlert: answer.includes('"UserNotificationCenter"'),
  };
}

// The window server lists an app's windows to any process, with no permission:
// the report has their number and place even where their text cannot be read.
async function frontAppWindows(pid: number) {
  const script = `ObjC.import("CoreGraphics"); ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0))).filter((w) => w.kCGWindowOwnerPID === ${pid}).map((w) => "layer " + w.kCGWindowLayer + " " + JSON.stringify(w.kCGWindowBounds) + " title " + JSON.stringify(w.kCGWindowName ?? null)).join("\\n")`;
  return `Front app's windows on screen (pid ${pid}):\n${await tool("osascript", ["-l", "JavaScript", "-e", script])}`;
}

// An alert's window does not say who asked for it. For a consent prompt the
// unified log does: TCC names its service and the process that asked. For any
// alert, the alert agent's own lines give the time it came up.
async function systemAlertLog() {
  const predicate =
    '(process == "tccd" AND eventMessage CONTAINS "AUTHREQ_PROMPTING") OR ((process == "UserNotificationCenter" OR eventMessage CONTAINS[c] "CFUserNotification") AND NOT eventMessage CONTAINS "_react(to:)" AND process != "log")';
  const lines = await tool("/usr/bin/log", [
    "show",
    "--last",
    "30m",
    "--style",
    "compact",
    "--predicate",
    predicate,
  ]);
  // The command and the latest lines: an alert older than the 30 minutes read leaves none.
  const [command, ...found] = lines.trimEnd().split("\n");
  return `System alert log:\n${[command, ...found.slice(-40)].join("\n")}`;
}

async function threadStacks(pid: number) {
  if (process.platform === "darwin")
    // The call graph lists the main thread first; the loaded-image list after it
    // is most of the report and names no frame.
    return (await tool("sample", [String(pid), "3", "-mayDie"])).split(
      "\nBinary Images:"
    )[0]!;
  if (process.platform === "linux") {
    if (await available("eu-stack")) return tool("eu-stack", ["-p", String(pid)]);
    if (await available("gdb"))
      return tool("gdb", ["-p", String(pid), "-batch", "-ex", "thread apply all bt"]);
    return "Thread stacks: neither eu-stack nor gdb is installed.";
  }
  return `Thread stacks: not collected on ${process.platform}.`;
}

async function available(command: string) {
  try {
    await run("sh", ["-c", `command -v ${command}`], { timeout: toolBoundMs });
    return true;
  } catch {
    return false;
  }
}

async function tool(command: string, args: string[]) {
  try {
    const { stdout, stderr } = await run(command, args, {
      encoding: "utf8",
      maxBuffer: 16 * 1024 * 1024,
      timeout: toolBoundMs,
    });
    return `$ ${command} ${args.join(" ")}\n${stdout}${stderr}`;
  } catch (error) {
    const failed = error as {
      code?: number | string | null;
      killed?: boolean;
      signal?: string | null;
      stdout?: string;
      stderr?: string;
    };
    // A tool that printed nothing still says how it ended: no answer within the bound is not a refusal.
    const how =
      typeof failed.code === "string"
        ? failed.code
        : failed.killed
          ? `no answer within ${toolBoundMs}ms`
          : failed.signal
            ? `ended by ${failed.signal}`
            : `exit code ${failed.code}`;
    return `$ ${command} ${args.join(" ")} failed (${how})\n${failed.stdout ?? ""}${failed.stderr ?? ""}`;
  }
}
