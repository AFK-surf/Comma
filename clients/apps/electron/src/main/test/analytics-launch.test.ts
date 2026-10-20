import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { observeDesktopLaunch } from "../analytics-launch";

const directories: string[] = [];
afterEach(async () => {
  await Promise.all(directories.splice(0).map((path) => rm(path, { recursive: true })));
});

async function profile() {
  const directory = await mkdtemp(join(tmpdir(), "comma-launch-"));
  directories.push(directory);
  return {
    appVersion: "1.0.0",
    filePath: join(directory, "analytics-launch.json"),
    priorProfilePaths: [
      join(directory, "app-preferences.json"),
      join(directory, "session.json"),
    ],
  };
}

it("counts a fresh profile once across restarts, updates and a reinstall retaining its data", async () => {
  const options = await profile();
  const first = await observeDesktopLaunch(options);
  expect(first?.kind).toBe("new_profile");
  const reopened = await observeDesktopLaunch(options);
  expect(reopened?.kind).toBe("returning");
  expect(reopened?.eventId).not.toBe(first?.eventId);
  expect((await observeDesktopLaunch({ ...options, appVersion: "1.1.0" }))?.kind).toBe(
    "version_changed"
  );
  expect((await observeDesktopLaunch({ ...options, appVersion: "1.1.0" }))?.kind).toBe(
    "returning"
  );
});

it.each([0, 1])(
  "does not count an existing profile as new when prior file %s is present",
  async (index) => {
    const options = await profile();
    await writeFile(options.priorProfilePaths[index]!, "{}");
    expect((await observeDesktopLaunch(options))?.kind).toBe("existing_profile");
    expect((await observeDesktopLaunch(options))?.kind).toBe("returning");
  }
);

it("does not report a new profile when its evidence cannot be read or saved", async () => {
  const options = await profile();
  await writeFile(options.filePath, "truncated{");
  expect(await observeDesktopLaunch(options)).toBeUndefined();
  await rm(options.filePath);
  await mkdir(`${options.filePath}.tmp`);
  expect(await observeDesktopLaunch(options)).toBeUndefined();
});

it("recognizes an unsigned-in legacy profile from its existing data directory", async () => {
  const options = await profile();
  const legacyData = join(directories.at(-1)!, "legacy-core");
  await mkdir(legacyData);
  expect(
    (await observeDesktopLaunch({ ...options, priorProfilePaths: [legacyData] }))?.kind
  ).toBe("existing_profile");
});
