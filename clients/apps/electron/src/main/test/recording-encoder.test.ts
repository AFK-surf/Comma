import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { HelperRecordingEncoder } from "../modules/audio-capture/encoder";

const directories: string[] = [];
afterEach(async () => {
  await Promise.all(
    directories.splice(0).map((path) => rm(path, { recursive: true, force: true }))
  );
});

it.each(["exit", "timeout"])(
  "removes partial output after a real helper %s and retains the source",
  async (failure) => {
    const directory = await mkdtemp(join(tmpdir(), "comma-encoder-fault-"));
    directories.push(directory);
    const source = join(directory, "recording.wav");
    await writeFile(source, "completed WAV");
    const helper = join(directory, "helper");
    await writeFile(
      helper,
      `#!${process.execPath}\nrequire('node:fs').writeFileSync(process.argv[4], 'partial M4A');\n${failure === "exit" ? "process.exit(2);" : "setInterval(() => {}, 100);"}\n`,
      { mode: 0o755 }
    );
    const encoder = new HelperRecordingEncoder(helper, 300);
    await expect(encoder.encode(source)).rejects.toThrow();
    expect(await readdir(directory)).toEqual(["helper", "recording.wav"]);
    expect(await readFile(source, "utf8")).toBe("completed WAV");
  }
);
