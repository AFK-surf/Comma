import { describe, expect, it } from "vitest";
import { createScriptedCore } from "../scripted-core";

const item = (id: string, title: string) => ({ id, title, status: "running" });

describe("a scripted core", () => {
  it("sends a change to one item of a keyed list as that item's change, as the core does", async () => {
    const core = createScriptedCore();
    const seen: { items: { id: string }[] }[] = [];
    core.client.subscribe(
      { topic: "tasks", workspace: "" },
      (v) => seen.push(v as never),
      () => undefined
    );
    core.emit("tasks", {
      items: [item("a", "A"), item("b", "B")],
      source: "live-sync",
    });
    await new Promise((r) => setTimeout(r, 0));
    core.emit("tasks", {
      items: [item("a", "A2"), item("b", "B")],
      source: "live-sync",
    });
    await new Promise((r) => setTimeout(r, 0));
    const [before, after] = seen.slice(-2);
    expect(after!.items[0]).toMatchObject({ title: "A2" });
    expect(after!.items[1]).toBe(before!.items[1]);
  });
});
