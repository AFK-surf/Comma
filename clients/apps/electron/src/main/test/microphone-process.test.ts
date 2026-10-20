import { spawn, type ChildProcess } from "node:child_process";
import { once } from "node:events";
import { expect, it } from "vitest";
import {
  HelperMicrophoneCapture,
  type MicrophoneHostProcess,
} from "../modules/audio-capture/microphone";

it("reaps a real helper that ignores EOF and SIGTERM", async () => {
  let child: ChildProcess | undefined;
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
    // Stop settles only once it observes the exit, which the SIGKILL brings.
    await session.stop();
    expect(child?.signalCode).toBe("SIGKILL");
  } finally {
    if (child && child.exitCode === null && child.signalCode === null) {
      const exited = once(child, "exit");
      child.kill("SIGKILL");
      await exited;
    }
  }
});
