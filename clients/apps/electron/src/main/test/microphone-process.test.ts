import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { expect, it } from "vitest";
import {
  HelperMicrophoneCapture,
  type MicrophoneHostProcess,
} from "../modules/audio-capture/microphone";

it("reaps a real helper that ignores EOF and SIGTERM", async () => {
  let child: ChildProcess | undefined;
  let timeout: ReturnType<typeof setTimeout> | undefined;
  const capture = new HelperMicrophoneCapture({
    executablePath: process.execPath,
    spawn: () => {
      child = spawn(
        process.execPath,
        [
          "-e",
          [
            "process.on('SIGTERM', () => {});",
            "process.stdin.resume();",
            "process.stderr.write(JSON.stringify({event: 'ready'}) + '\\n');",
            "setInterval(() => {}, 100);",
          ].join("\n"),
        ],
        { stdio: ["pipe", "pipe", "pipe"] }
      );
      return child as unknown as MicrophoneHostProcess;
    },
  });
  try {
    const session = await capture.start({
      sampleRate: 48000,
      onError: () => {},
      onFrames: () => {},
    });
    const stopped = await Promise.race([
      session.stop().then(() => true),
      // Allow scheduler slack beyond the 1.5s grace without asserting exact time.
      new Promise<boolean>((resolve) => {
        timeout = setTimeout(() => resolve(false), 5000);
      }),
    ]);
    expect(stopped, "Stop must observe exit after forced termination").toBe(true);
    expect(child?.signalCode).toBe("SIGKILL");
  } finally {
    clearTimeout(timeout);
    if (child && child.exitCode === null && child.signalCode === null) {
      const exited = once(child, "exit");
      child.kill("SIGKILL");
      await exited;
    }
  }
}, 15000);
