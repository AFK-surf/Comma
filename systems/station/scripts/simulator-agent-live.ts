// The live acceptance check of agents on a simulator (docs/simulator-screen.md, "Agents on a simulator"): an agent on a
// real booted iOS Simulator through the station's own code (simulator.ts, simulator-agent.ts) and a real Computer Use
// helper. A screenshot is a PNG of the device, a person's Control holds the agent off, and a tap changes the screen.
// It waits on the real device, so it is not among the tests (test/simulator-agent.test.ts has the fake ones): run it on
// a Mac with simulator-agent-live.sh, which makes a simulator of its own, boots it, starts a helper instance on a socket
// of its own, and deletes them afterwards.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { test } from "node:test";
import { pngSize } from "../src/screens/android-agent.ts";
import { ScreenHelpers } from "../src/screens/helper.ts";
import { SimulatorAgents } from "../src/screens/simulator-agent.ts";
import { SIMCTL, Simulators } from "../src/screens/simulator.ts";
import { makeScreens } from "../src/screens/source.ts";

const UDID = process.env.COMMA_SIM_LIVE_UDID;
const SOCKET = process.env.COMMA_SIM_LIVE_SOCKET;
const TOKEN = process.env.COMMA_SIM_LIVE_TOKEN;
const SHOTS = process.env.COMMA_SIM_LIVE_SHOTS;
const LIVE = { skip: UDID && SOCKET && TOKEN ? false : "needs a simulator and helper of its own (scripts/simulator-agent-live.sh)" };

const shots: Buffer[] = [];
const images = async (png: Buffer) => {
  shots.push(png);
  if (SHOTS) execFileSync("/bin/sh", ["-c", `cat > "${SHOTS}/live-${shots.length}.png"`], { input: png });
  return { ok: true, image_path: `live-${shots.length}.png`, image_content_type: "image/png", image_size_bytes: png.length };
};

/// The share of bytes two screenshots of one size differ in.
const differ = (a: Buffer, b: Buffer) => {
  let changed = 0;
  const length = Math.min(a.length, b.length);
  for (let i = 0; i < length; i++) if (a[i] !== b[i]) changed++;
  return changed / length + Math.abs(a.length - b.length) / Math.max(a.length, b.length);
};

test("an agent on a real simulator: a PNG of it, a tap that changes it, a person's Control first", LIVE, async (t) => {
  const helpers = new ScreenHelpers();
  helpers.attach({ ensure: async () => {}, authToken: () => TOKEN!, socketPath: SOCKET! });
  const screens = makeScreens();
  const simulators = new Simulators({ screens, helper: () => helpers.current(), here: true });
  const agents = new SimulatorAgents(simulators);
  t.after(async () => {
    await agents.close();
    simulators.close();
  });
  const target = `simulator:${UDID}`;

  const status = await agents.call({ action: "status" }, images);
  assert.ok((status.devices as { target: string }[]).some((d) => d.target === target), JSON.stringify(status));
  const started = await agents.call({ action: "start", target, consent: true }, images);
  assert.equal(started.ok, true, JSON.stringify(started));
  const lease = { lease_id: started.lease_id, lease_epoch: started.lease_epoch };

  // Settings, opened by simctl: its list is the screen the tap changes.
  execFileSync(SIMCTL, ["launch", UDID!, "com.apple.Preferences"]);
  await new Promise((resolve) => setTimeout(resolve, 3000));
  const before = await agents.call({ ...lease, action: "observe" }, images);
  assert.equal(before.ok, true, JSON.stringify(before));
  const first = shots.at(-1)!;
  const size = pngSize(first)!;
  assert.deepEqual([before.image_width, before.image_height], [size.width, size.height]);
  assert.ok(size.width >= 1000 && size.height >= 2000, `a phone's pixels, ${size.width}×${size.height}`);

  // A person takes Control: the agent's tap is refused and the screen is as it was.
  const source = simulators.sourceOf(target)!;
  const release = source.hold();
  assert.equal((await agents.call({ ...lease, action: "tap", x: size.width / 2, y: size.height * 0.62 }, images)).error_code, "screen_held_by_person");
  await new Promise((resolve) => setTimeout(resolve, 1500));
  await agents.call({ ...lease, action: "observe" }, images);
  assert.ok(differ(first, shots.at(-1)!) < 0.05, "nothing reached the screen while the person drove it");
  release();

  // Let go: a tap on a row of Settings' list opens that page.
  assert.deepEqual(await agents.call({ ...lease, action: "tap", x: size.width / 2, y: size.height * 0.62 }, images), { ok: true });
  await new Promise((resolve) => setTimeout(resolve, 2000));
  const after = await agents.call({ ...lease, action: "observe" }, images);
  assert.equal(after.ok, true);
  assert.ok(differ(first, shots.at(-1)!) > 0.2, "the tap changed the screen");

  // Home, by the device's button.
  assert.deepEqual(await agents.call({ ...lease, action: "key", key: "home" }, images), { ok: true });
  assert.deepEqual(await agents.call({ ...lease, action: "end" }, images), { ok: true, ended: true });
});
