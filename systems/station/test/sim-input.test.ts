// A person's input as an iOS Simulator takes it (screens/sim-input.ts).
import assert from "node:assert/strict";
import { test } from "node:test";
import { SimInput, TYPED, USAGES } from "../src/screens/sim-input.ts";
import type { DeviceInput } from "../src/screens/source.ts";

test("input as an iOS Simulator takes it: the left button a finger (from an edge, a system gesture), a wheel, keys by their HID usage, its buttons by Simulator.app's shortcuts", () => {
  const sim = new SimInput();
  const pointer = (kind: "down" | "up" | "move", x: number, y: number, buttons: number): DeviceInput => ({ t: "pointer", kind, x, y, buttons });
  // A pointer moving with nothing held, or another button: no finger.
  assert.deepEqual(sim.ops(pointer("move", 0.5, 0.5, 0)), []);
  assert.deepEqual(sim.ops(pointer("down", 0.5, 0.5, 2)), []);
  assert.deepEqual(sim.ops(pointer("down", 0.25, 0.5, 1)), [{ op: "touch", type: "begin", x: 0.25, y: 0.5 }]);
  assert.deepEqual(sim.ops(pointer("move", 0.3, 0.6, 1)), [{ op: "touch", type: "move", x: 0.3, y: 0.6 }]);
  assert.deepEqual(sim.ops(pointer("up", 0.3, 0.6, 0)), [{ op: "touch", type: "end", x: 0.3, y: 0.6 }]);
  // From the bottom edge: the home indicator's swipe, the whole gesture; out of the screen, held within it.
  assert.deepEqual(sim.ops(pointer("down", 0.5, 0.99, 1)), [{ op: "touch", type: "begin", x: 0.5, y: 0.99, edge: 3 }]);
  assert.deepEqual(sim.ops(pointer("move", 0.5, -0.2, 1)), [{ op: "touch", type: "move", x: 0.5, y: 0, edge: 3 }]);
  // The button let go where the page saw no up (the pointer left the view): the finger lifts at the next move.
  assert.deepEqual(sim.ops(pointer("move", 0.5, 0.4, 0)), [{ op: "touch", type: "end", x: 0.5, y: 0.4, edge: 3 }]);
  assert.deepEqual(sim.ops(pointer("down", 0.5, 0.01, 1))[0], { op: "touch", type: "begin", x: 0.5, y: 0.01, edge: 2 });
  sim.ops(pointer("up", 0.5, 0.3, 0));
  assert.deepEqual(sim.ops({ t: "wheel", x: 0.5, y: 0.5, dx: 0, dy: 120 }), [{ op: "scroll", x: 0.5, y: 0.5, dx: 0, dy: 120 }]);
  assert.deepEqual(sim.ops({ t: "wheel", x: 0.5, y: 0.5, dx: 0, dy: 0 }), []);
  const key = (kind: "down" | "up", code: string, mods = 0): DeviceInput => ({ t: "key", kind, key: "", code, mods });
  assert.deepEqual(sim.ops(key("down", "KeyA")), [{ op: "key", type: "down", usage: 0x04 }]);
  assert.deepEqual(sim.ops(key("up", "Enter")), [{ op: "key", type: "up", usage: 0x28 }]);
  assert.equal(USAGES.Digit0, 0x27);
  assert.equal(USAGES.F12, 0x45);
  assert.deepEqual(sim.ops(key("down", "Unidentified")), []);
  // A modifier held from its own key is not pressed again round the next; one only named in `mods` (a phone's keys row) is.
  assert.deepEqual(sim.ops(key("down", "ShiftLeft", 8)), [{ op: "key", type: "down", usage: 0xe1 }]);
  assert.deepEqual(sim.ops(key("down", "KeyA", 8)), [{ op: "key", type: "down", usage: 0x04 }]);
  sim.ops(key("up", "ShiftLeft"));
  assert.deepEqual(sim.ops(key("down", "KeyA", 2)), [{ op: "key", type: "down", usage: 0xe0 }, { op: "key", type: "down", usage: 0x04 }]);
  assert.deepEqual(sim.ops(key("up", "KeyA", 2)), [{ op: "key", type: "up", usage: 0x04 }, { op: "key", type: "up", usage: 0xe0 }]);
  // Simulator.app's shortcuts: the device's buttons, once (as the key goes down).
  assert.deepEqual(sim.ops(key("down", "KeyH", 12)), [{ op: "button", name: "home" }]);
  assert.deepEqual(sim.ops(key("up", "KeyH", 12)), []);
  assert.deepEqual(sim.ops(key("down", "KeyL", 4)), [{ op: "button", name: "lock" }]);
  assert.deepEqual(sim.ops(key("down", "KeyK", 4)), [{ op: "button", name: "keyboard" }]);
  assert.deepEqual(sim.ops(key("down", "KeyH", 14)), [{ op: "button", name: "app_switcher" }]);
  // ⌃⌘ with another key is that key, ⌃⌘ round it.
  assert.deepEqual(sim.ops(key("down", "KeyL", 6))[0], { op: "key", type: "down", usage: 0xe0 });
  // The client's buttons beside the device.
  assert.deepEqual(sim.ops({ t: "device", name: "rotate" }), [{ op: "rotate" }]);
  assert.deepEqual(sim.ops({ t: "device", name: "volume_up" }), [{ op: "button", name: "volume_up" }]);
  assert.deepEqual(sim.ops({ t: "pose", name: "closed" }), [{ op: "pose", name: "closed" }]);
  assert.deepEqual(sim.ops({ t: "pose", name: "open" }), [{ op: "pose", name: "open" }]);
  assert.deepEqual(sim.ops({ t: "pose", name: "book" }), []);
});

test("text as an iOS Simulator takes it: a US keyboard's keys where each character has one, else pasted", () => {
  const sim = new SimInput();
  const KEY_A = 0x04, SHIFT = 0xe1;
  assert.deepEqual(sim.ops({ t: "text", text: "aA!" }), [
    { op: "key", type: "down", usage: KEY_A },
    { op: "key", type: "up", usage: KEY_A },
    { op: "key", type: "down", usage: SHIFT },
    { op: "key", type: "down", usage: KEY_A },
    { op: "key", type: "up", usage: KEY_A },
    { op: "key", type: "up", usage: SHIFT },
    { op: "key", type: "down", usage: SHIFT },
    { op: "key", type: "down", usage: 0x1e },
    { op: "key", type: "up", usage: 0x1e },
    { op: "key", type: "up", usage: SHIFT },
  ]);
  assert.deepEqual(TYPED["\n"], [0x28, false]);
  // An IME's Chinese, or a paste with any character no key types: the whole of it pasted, in one.
  assert.deepEqual(sim.ops({ t: "text", text: "你好 world" }), [{ op: "paste", text: "你好 world" }]);
  assert.deepEqual(sim.ops({ t: "text", text: "" }), []);
  // Shift already held from its own key is not pressed again.
  sim.ops({ t: "key", kind: "down", key: "", code: "ShiftLeft", mods: 8 });
  assert.deepEqual(sim.ops({ t: "text", text: "A" }), [{ op: "key", type: "down", usage: KEY_A }, { op: "key", type: "up", usage: KEY_A }]);
});
