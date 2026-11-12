// What Salix says for the mesh, as a state (src/connector/mesh-turn.ts).
import assert from "node:assert/strict";
import { test } from "node:test";
import { type MeshStep, type MeshTurn, meshConnected, meshEnded, meshHeard, noMeshTurn } from "../src/connector/mesh-turn.ts";

const GRANT = { workspace: "ws", owner: "u" };
const NEWER = { workspace: "ws", owner: "u", revocations: [{ kind: "sub" }] };

/// A run of steps from `state`: the last state, and all that was told, in order.
function run(state: MeshTurn<string>, ...steps: ((s: MeshTurn<string>) => MeshStep<string>)[]) {
  const told: { via: string; facts: unknown }[] = [];
  for (const step of steps) {
    const next = step(state);
    state = next.state;
    told.push(...next.tell);
  }
  return { state, told };
}
const connected = (socket: string) => (s: MeshTurn<string>) => meshConnected(s, socket);
const heard = (socket: string, seq: number, facts: unknown, enabled = true) => (s: MeshTurn<string>) => meshHeard(s, { socket, seq, facts }, enabled);

test("an older number changes nothing, a grant or a deny", () => {
  const start = run(noMeshTurn<string>(), connected("a"), heard("a", 5, GRANT));
  for (const seq of [5, 4, 0]) {
    for (const facts of [NEWER, null]) {
      const after = run(start.state, heard("a", seq, facts));
      assert.deepEqual(after.state, start.state);
      assert.deepEqual(after.told, []);
    }
  }
});

test("a newer number is what stands", () => {
  const { state, told } = run(noMeshTurn<string>(), connected("a"), heard("a", 0, GRANT), heard("a", 1, NEWER));
  assert.equal(state.seq, 1);
  assert.deepEqual(told, [
    { via: "a", facts: GRANT },
    { via: "a", facts: NEWER },
  ]);
});

test("a deny takes back what stands, also what an earlier connection told, and an older grant does not undo it", () => {
  const { state, told } = run(noMeshTurn<string>(), connected("a"), heard("a", 3, GRANT), connected("b"), heard("b", 2, null), heard("b", 1, GRANT));
  assert.equal(state.told, null);
  assert.deepEqual(told, [
    { via: "a", facts: GRANT },
    { via: "a", facts: null },
    { via: "b", facts: null },
  ]);
});

test("a new connection's numbers start over, and what the last one told stands until it speaks", () => {
  const { state, told } = run(noMeshTurn<string>(), connected("a"), heard("a", 9, GRANT), connected("b"));
  assert.equal(state.told, "a");
  assert.deepEqual(told, [{ via: "a", facts: GRANT }]);
  const after = run(state, heard("b", 0, NEWER));
  assert.equal(after.state.told, "b");
  assert.deepEqual(after.told, [{ via: "b", facts: NEWER }]);
});

test("a word from a connection that is no longer the current one changes nothing", () => {
  const start = run(noMeshTurn<string>(), connected("a"), heard("a", 1, GRANT), connected("b"), heard("b", 0, GRANT));
  const after = run(start.state, heard("a", 99, null));
  assert.deepEqual(after.state, start.state);
  assert.deepEqual(after.told, []);
});

test("no word turns it on where the setting has not asked, and turning it off takes back what stands", () => {
  const off = run(noMeshTurn<string>(), connected("a"), heard("a", 0, GRANT, false));
  assert.equal(off.state.told, null);
  assert.deepEqual(off.told, []);
  const on = run(noMeshTurn<string>(), connected("a"), heard("a", 0, GRANT), heard("a", 1, GRANT, false));
  assert.equal(on.state.told, null);
  assert.deepEqual(on.told.at(-1), { via: "a", facts: null });
});

test("ended on purpose, what stands is taken back once", () => {
  const { state, told } = run(noMeshTurn<string>(), connected("a"), heard("a", 0, GRANT), meshEnded, meshEnded);
  assert.equal(state.told, null);
  assert.deepEqual(told, [
    { via: "a", facts: GRANT },
    { via: "a", facts: null },
  ]);
});
