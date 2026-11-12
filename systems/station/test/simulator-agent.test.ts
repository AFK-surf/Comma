// Agents on a computer's iOS Simulators (src/screens/simulator-agent.ts) against fake simulators: what a lease lets an
// agent do, and what it refuses. A real simulator and helper: simulator-agent-live.test.ts.
import assert from "node:assert/strict";
import { test } from "node:test";
import { SimulatorAgents, type AgentSimulator, type AgentSimulators } from "../src/screens/simulator-agent.ts";
import type { DeviceInput, ScreenInput, ScreenView } from "../src/screens/source.ts";

/// A PNG's header for a picture of this size (simulator-agent.ts reads its size from it).
function png(width: number, height: number): Buffer {
  const head = Buffer.alloc(24);
  head.writeUInt32BE(0x89504e47, 0);
  head.writeUInt32BE(0x0d0a1a0a, 4);
  head.writeUInt32BE(13, 8);
  head.write("IHDR", 12, "latin1");
  head.writeUInt32BE(width, 16);
  head.writeUInt32BE(height, 20);
  return head;
}

/// Time a test moves: a short wait (a tap's, a swipe's step) passes at once, moving the clock by its length; a lease's
/// own timer only when told.
function testClock() {
  let now = 1_000_000;
  const after = (ms: number, f: () => void) => {
    if (ms < 10_000)
      queueMicrotask(() => {
        now += ms;
        f();
      });
    return () => {};
  };
  return { now: () => now, after, set: (at: number) => void (now = at) };
}

function fakeSim(udid = "0702F8CC-2E2A-4D0A-8401-C37FA01E1646") {
  const input: ScreenInput[] = [];
  let holds = 0;
  let views = 0;
  let closed = 0;
  const view = { input: async (event: ScreenInput) => void input.push(event), close: () => void closed++ } as unknown as ScreenView;
  const sim: AgentSimulator & { hold(): () => void; input: ScreenInput[]; views(): number; closed(): number } = {
    id: `simulator:${udid}`,
    instance: "boot-1",
    agent: null,
    title: () => "iPhone 17 Pro · iOS 26.2",
    size: () => ({ width: 1206, height: 2622 }),
    held: () => holds > 0,
    hold: () => {
      holds++;
      return () => void holds--;
    },
    current: async () => true,
    agentScreenshot: async () => png(1206, 2622),
    agentView: async () => (views++, view),
    input,
    views: () => views,
    closed: () => closed,
  };
  return sim;
}

function fakeSims(...sims: AgentSimulator[]) {
  let listed = [...sims];
  const listeners = new Set<() => void>();
  const all: AgentSimulators & { remove(id: string): void } = {
    refresh: async () => {},
    list: () => listed,
    sourceOf: (id) => listed.find((s) => s.id === id),
    watch: (heard) => (listeners.add(heard), () => void listeners.delete(heard)),
    remove: (id) => {
      listed = listed.filter((s) => s.id !== id);
      for (const heard of listeners) heard();
    },
  };
  return all;
}

const stored: Buffer[] = [];
const images = async (shot: Buffer) => (stored.push(shot), { ok: true, image_path: `capture-${stored.length}.png`, image_content_type: "image/png", image_size_bytes: shot.length });

async function leased(sim = fakeSim()) {
  const sims = fakeSims(sim);
  const clock = testClock();
  const agents = new SimulatorAgents(sims, clock);
  const started = await agents.call({ action: "start", target: sim.id, consent: true }, images);
  assert.equal(started.ok, true, JSON.stringify(started));
  return { sim, sims, clock, agents, lease: { lease_id: started.lease_id, lease_epoch: started.lease_epoch } };
}

test("a simulator is leased only on the word of its owner's card; status lists the booted ones", async () => {
  const sim = fakeSim();
  const agents = new SimulatorAgents(fakeSims(sim), testClock());
  assert.deepEqual((await agents.call({ action: "status" }, images)).devices, [
    { target: sim.id, title: "iPhone 17 Pro · iOS 26.2", kind: "simulator", instance: "boot-1", width: 1206, height: 2622, leased: false, held_by_person: false },
  ]);
  // No card answered: no lease, and what the card would name.
  assert.deepEqual(await agents.call({ action: "start", target: sim.id }, images), {
    ok: false,
    error_code: "screen_consent_required",
    error: "the computer's owner allows this chat first",
    title: "iPhone 17 Pro · iOS 26.2",
    target: sim.id,
    instance: "boot-1",
  });
  assert.equal(sim.agent, null);
  assert.equal((await agents.call({ action: "start", target: "simulator:NOPE", consent: true }, images)).error_code, "screen_target_unknown");
  const started = await agents.call({ action: "start", target: sim.id, consent: true }, images);
  assert.equal(started.ok, true);
  assert.equal(sim.agent, "agent");
  // One lease a device.
  assert.equal((await agents.call({ action: "start", target: sim.id, consent: true }, images)).error_code, "screen_leased");
  await agents.close();
});

test("observe gives a kept PNG; a tap and a swipe go to the screen at that picture's point, as a finger", async () => {
  const { sim, agents, lease } = await leased();
  const seen = await agents.call({ ...lease, action: "observe" }, images);
  assert.equal(seen.ok, true);
  assert.equal(seen.image_width, 1206);
  assert.equal(seen.image_height, 2622);
  assert.equal(seen.image_path, `capture-${stored.length}.png`);
  assert.equal(seen.observation_id, 1);

  assert.deepEqual(await agents.call({ ...lease, action: "tap", x: 603, y: 1311 }, images), { ok: true });
  assert.deepEqual(sim.input, [
    { t: "pointer", kind: "down", x: 0.5, y: 0.5, buttons: 1 },
    { t: "pointer", kind: "up", x: 0.5, y: 0.5, buttons: 0 },
  ]);
  sim.input.length = 0;
  assert.deepEqual(await agents.call({ ...lease, action: "swipe", from: [603, 2000], to: [603, 1000], duration_ms: 64 }, images), { ok: true });
  const moves = sim.input as DeviceInput[];
  assert.deepEqual(moves[0], { t: "pointer", kind: "down", x: 0.5, y: 2000 / 2622, buttons: 1 });
  assert.deepEqual(moves.at(-1), { t: "pointer", kind: "up", x: 0.5, y: 1000 / 2622, buttons: 0 });
  assert.ok(moves.slice(1, -1).every((m) => m.t === "pointer" && m.kind === "move"));
  // Typed text and the device's buttons, by Simulator.app's shortcuts.
  sim.input.length = 0;
  await agents.call({ ...lease, action: "type", text: "hi" }, images);
  await agents.call({ ...lease, action: "key", key: "home" }, images);
  assert.deepEqual(sim.input, [
    { t: "text", text: "hi" },
    { t: "key", kind: "down", key: "home", code: "KeyH", mods: 12 },
    { t: "key", kind: "up", key: "home", code: "KeyH", mods: 12 },
  ]);
  // One view carries a lease's input, and closes as it ends.
  assert.equal(sim.views(), 1);
  assert.deepEqual(await agents.call({ ...lease, action: "end" }, images), { ok: true, ended: true });
  assert.equal(sim.closed(), 1);
  assert.equal(sim.agent, null);
  assert.equal((await agents.call({ ...lease, action: "tap", x: 1, y: 1 }, images)).error_code, "screen_lease_unknown");
});

test("a person driving the simulator in Control holds every agent's input off it, and a look is still given", async () => {
  const { sim, agents, lease } = await leased();
  const release = sim.hold();
  assert.equal((await agents.call({ ...lease, action: "tap", x: 10, y: 10 }, images)).error_code, "screen_held_by_person");
  assert.equal((await agents.call({ ...lease, action: "type", text: "x" }, images)).error_code, "screen_held_by_person");
  const seen = await agents.call({ ...lease, action: "observe" }, images);
  assert.equal(seen.held_by_person, true);
  assert.deepEqual(sim.input, []);
  release();
  assert.deepEqual(await agents.call({ ...lease, action: "tap", x: 10, y: 10 }, images), { ok: true });
  await agents.close();
});

test("a lease ends with its time, and with its device: nothing more reaches it", async () => {
  const { sim, sims, clock, agents, lease } = await leased();
  clock.set(clock.now() + 3_600_000);
  assert.equal((await agents.call({ ...lease, action: "tap", x: 10, y: 10 }, images)).error_code, "screen_lease_expired");
  const again = await agents.call({ action: "start", target: sim.id, consent: true }, images);
  // (the device leaving ends the lease in its turn, which the next action waits for)
  sims.remove(sim.id);
  assert.equal((await agents.call({ lease_id: again.lease_id, action: "observe" }, images)).error_code, "screen_lease_unknown");
  assert.deepEqual(sim.input, []);
  await agents.close();
});

test("a swipe that runs past its lease's time stops there: its finger is lifted where it was, and nothing more goes", async () => {
  const { sim, clock, agents, lease } = await leased();
  await agents.call({ ...lease, action: "observe" }, images);
  // 1 s of the lease left; a 5 s swipe of 30 moves, one each 1/6 s.
  clock.set(clock.now() + 600_000 - 1_000);
  const swiped = await agents.call({ ...lease, action: "swipe", from: [603, 2600], to: [603, 0], duration_ms: 5000 }, images);
  assert.equal(swiped.error_code, "screen_lease_expired");
  const moves = sim.input as DeviceInput[];
  const ups = moves.filter((m) => m.t === "pointer" && m.kind === "up");
  assert.equal(ups.length, 1);
  assert.deepEqual(moves.at(-1), ups[0]);
  // Lifted where the finger was, not at the swipe's end; no move after the lease's end.
  const last = moves.at(-2) as { y: number };
  assert.equal((ups[0] as { y: number }).y, last.y);
  assert.ok(last.y > 0.5);
  assert.ok(moves.length - 2 <= 6, `${moves.length - 2} moves in the second left`);
  // The lease is over: its view closed, nothing more goes.
  assert.equal(sim.closed(), 1);
  assert.equal((await agents.call({ ...lease, action: "tap", x: 1, y: 1 }, images)).error_code, "screen_lease_unknown");
});

test("the station stopping during a swipe: its finger is lifted and the swipe refused", async () => {
  const { sim, agents, lease } = await leased();
  await agents.call({ ...lease, action: "observe" }, images);
  const swiping = agents.call({ ...lease, action: "swipe", from: [603, 2600], to: [603, 0], duration_ms: 5000 }, images);
  // (once the finger is down and has moved)
  while (sim.input.length < 3) await Promise.resolve();
  const closing = agents.close();
  assert.equal((await swiping).error_code, "screen_environment_unavailable");
  await closing;
  const moves = sim.input as DeviceInput[];
  assert.equal(moves.filter((m) => m.t === "pointer" && m.kind === "up").length, 1);
  assert.equal((moves.at(-1) as { kind: string }).kind, "up");
});

test("what an agent asks is checked: a point within the picture, a known key, text within bounds", async () => {
  const { agents, lease } = await leased();
  assert.equal((await agents.call({ ...lease, action: "tap", x: 5000, y: 1 }, images)).error_code, "screen_bad_args");
  assert.equal((await agents.call({ ...lease, action: "key", key: "power" }, images)).error_code, "screen_bad_args");
  assert.equal((await agents.call({ ...lease, action: "type", text: "x".repeat(1001) }, images)).error_code, "screen_bad_args");
  assert.equal((await agents.call({ ...lease, action: "install" }, images)).error_code, "screen_action_unsupported");
  assert.equal((await agents.call({ ...lease, action: "observe" }, null)).error_code, "screen_environment_unavailable");
  await agents.close();
});
