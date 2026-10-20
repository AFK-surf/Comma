import { CoreClient, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { MarksValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
  type SeenRequest,
} from "../src/testing/index.ts";

const PATH = "/v1/comma/me/task-panel-dismissals";
const DISMISSED: Topic = { topic: "marks", kind: "chatTaskDismissed" };

type Dismissal = { task_id: string; revision: number };
const dismissalsOf = (request: SeenRequest) =>
  (request.body as { dismissals: Dismissal[] }).dismissals;

/** The account's dismissals as the server keeps them, answered on every device's host. */
class Server {
  /** Task id → the version acknowledged; a version never moves back. */
  readonly kept = new Map<string, number>();
  down = false;
  /** Refuses writes only: reads still answer. */
  writesDown = false;

  serve(host: FakeHost): void {
    const answer = () =>
      this.down
        ? offline()
        : json(200, {
            data: [...this.kept].map(([task_id, revision]) => ({ task_id, revision })),
          });
    host.api.on("GET", PATH, answer);
    host.api.on("POST", PATH, (request) => {
      if (this.writesDown) return offline();
      if (!this.down)
        for (const { task_id, revision } of dismissalsOf(request))
          this.kept.set(
            task_id,
            Math.max(this.kept.get(task_id) ?? revision, revision)
          );
      return answer();
    });
  }
}

/** A device signed in to the account; `host` again is the same device started again. */
function device(server: Server, host = new FakeHost()) {
  server.serve(host);
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  let value: MarksValue | undefined;
  const show = () =>
    client.subscribe(
      DISMISSED,
      (v) => (value = v as MarksValue),
      () => undefined
    );
  core.observeSession(signedIn());
  return {
    host,
    core,
    client,
    time: host.time!,
    show,
    marks: () => value?.marks ?? {},
    dismissed: () => Object.keys(value?.marks ?? {}).toSorted(),
    reads: () => host.api.seen("GET", PATH).length,
    sent: () => host.api.seen("POST", PATH).map(dismissalsOf),
  };
}

describe("the chat task panel's dismissals", () => {
  it("are the account's: a dismissal made on one device hides the row on another, at its Task version", async () => {
    const server = new Server();
    const laptop = device(server);
    laptop.show();
    await laptop.time.pass(100);
    await laptop.client.call("marks.mark", {
      kind: "chatTaskDismissed",
      entries: [["cnv-1", 7]],
    });
    await laptop.time.pass(100);
    expect(laptop.sent()).toEqual([[{ task_id: "cnv-1", revision: 7 }]]);

    const desktop = device(server);
    desktop.show();
    await desktop.time.pass(100);
    expect(desktop.marks()).toEqual({ "cnv-1": 7 });
  });

  it("keep a dismissal made while the server's list is on its way", async () => {
    const server = new Server();
    const t = device(server);
    const release = t.host.api.hold("GET", PATH);
    t.show();
    await t.time.pass(100);
    await t.client.call("marks.mark", {
      kind: "chatTaskDismissed",
      entries: [["cnv-2", 3]],
    });
    await t.time.pass(100);
    release();
    await t.time.pass(100);
    expect(t.marks()).toEqual({ "cnv-2": 3 });
    expect([...server.kept]).toEqual([["cnv-2", 3]]);
  });

  it("send a dismissal again when the server could not take it", async () => {
    const server = new Server();
    const t = device(server);
    t.show();
    await t.time.pass(100);
    server.down = true;
    await t.client.call("marks.mark", {
      kind: "chatTaskDismissed",
      entries: [["cnv-1", 1]],
    });
    await t.time.pass(100);
    expect(t.dismissed()).toEqual(["cnv-1"]);

    server.down = false;
    await t.client.call("marks.mark", {
      kind: "chatTaskDismissed",
      entries: [["cnv-2", 2]],
    });
    await t.time.pass(100);
    expect(t.sent().at(-1)).toEqual([
      { task_id: "cnv-1", revision: 1 },
      { task_id: "cnv-2", revision: 2 },
    ]);
    expect([...server.kept.keys()].toSorted()).toEqual(["cnv-1", "cnv-2"]);
  });

  it("hand the dismissals a device kept before over to the account, once", async () => {
    const server = new Server();
    // An older server: the dismissal stays on this device.
    server.down = true;
    const before = device(server);
    before.show();
    await before.time.pass(100);
    await before.client.call("marks.mark", {
      kind: "chatTaskDismissed",
      entries: [["cnv-old", 4]],
    });
    await before.time.pass(100);
    before.core.close();

    server.down = false;
    server.kept.set("cnv-elsewhere", 1);
    const after = device(server, before.host);
    after.show();
    await after.time.pass(100);
    expect([...server.kept].toSorted()).toEqual([
      ["cnv-elsewhere", 1],
      ["cnv-old", 4],
    ]);
    expect(after.marks()).toEqual({ "cnv-elsewhere": 1, "cnv-old": 4 });
    after.core.close();

    // Handed over once: a dismissal the account no longer has does not come back from this device.
    server.kept.delete("cnv-old");
    const later = device(server, before.host);
    later.show();
    await later.time.pass(100);
    expect(later.dismissed()).toEqual(["cnv-elsewhere"]);
    expect([...server.kept.keys()]).toEqual(["cnv-elsewhere"]);
  });

  it("hand them over again when the handover was cut short", async () => {
    const server = new Server();
    server.down = true;
    const before = device(server);
    before.show();
    await before.time.pass(100);
    await before.client.call("marks.mark", {
      kind: "chatTaskDismissed",
      entries: [["cnv-old", 4]],
    });
    await before.time.pass(100);
    before.core.close();

    // The read answers, the handover's write does not, and the app quits.
    server.down = false;
    server.writesDown = true;
    const cut = device(server, before.host);
    cut.show();
    await cut.time.pass(100);
    expect(cut.dismissed()).toEqual(["cnv-old"]);
    cut.core.close();

    server.writesDown = false;
    const again = device(server, before.host);
    again.show();
    await again.time.pass(100);
    expect([...server.kept]).toEqual([["cnv-old", 4]]);
    expect(again.dismissed()).toEqual(["cnv-old"]);
  });

  it("hand over the ones kept before they recorded a run at no known run, whatever the device's clock said", async () => {
    const server = new Server();
    server.down = true;
    const before = device(server);
    await before.time.pass(100);
    // Kept at the device's time, a clock far ahead of the server's.
    before.core.session.current()!.setMeta("marks:chatTaskDismissed", {
      "cnv-old": before.time.now() + 86_400_000,
    });
    before.core.close();

    server.down = false;
    const after = device(server, before.host);
    after.show();
    await after.time.pass(100);
    expect([...server.kept]).toEqual([["cnv-old", 0]]);
    expect(after.marks()).toEqual({ "cnv-old": 0 });
  });

  it("keep a dismissal the server could not take across a restart, and send it then", async () => {
    const server = new Server();
    const before = device(server);
    before.show();
    await before.time.pass(100);
    server.down = true;
    await before.client.call("marks.mark", {
      kind: "chatTaskDismissed",
      entries: [["cnv-offline", 7]],
    });
    await before.time.pass(100);
    before.core.close();

    server.down = false;
    const after = device(server, before.host);
    after.show();
    await after.time.pass(100);
    expect([...server.kept]).toEqual([["cnv-offline", 7]]);
    expect(after.marks()).toEqual({ "cnv-offline": 7 });
    after.core.close();

    // Taken: a later start sends nothing again.
    const sent = after.sent().length;
    const later = device(server, before.host);
    later.show();
    await later.time.pass(100);
    expect(later.sent()).toHaveLength(sent);
  });

  it("read again when the reader comes back, at most once per 30 seconds", async () => {
    const server = new Server();
    const t = device(server);
    t.show();
    await t.time.pass(100);
    expect(t.reads()).toBe(1);

    server.kept.set("cnv-elsewhere", 9);
    await t.client.call("marks.refresh", { kind: "chatTaskDismissed" });
    await t.time.pass(100);
    expect(t.reads()).toBe(1);

    await t.time.pass(30_000);
    await t.client.call("marks.refresh", { kind: "chatTaskDismissed" });
    await t.time.pass(100);
    expect(t.reads()).toBe(2);
    expect(t.marks()).toEqual({ "cnv-elsewhere": 9 });
  });

  it("end only with the Task's next run: no call lifts one", async () => {
    const t = device(new Server());
    t.show();
    await t.time.pass(100);
    await expect(
      t.client.call("marks.unmark", { kind: "chatTaskDismissed", ids: ["cnv-1"] })
    ).rejects.toMatchObject({ code: "invalid_params" });
  });

  it("never send one account's dismissals for another", async () => {
    const server = new Server();
    const t = device(server);
    t.show();
    await t.time.pass(100);
    server.down = true;
    await t.client.call("marks.mark", {
      kind: "chatTaskDismissed",
      entries: [["cnv-user-1", 1]],
    });
    await t.time.pass(100);

    t.core.observeSession(
      signedIn("user-2", { sessionId: "session-2", generation: 2 })
    );
    await t.time.pass(100);
    server.down = false;
    await t.client.call("marks.mark", {
      kind: "chatTaskDismissed",
      entries: [["cnv-user-2", 1]],
    });
    await t.time.pass(100);
    expect(t.sent().at(-1)).toEqual([{ task_id: "cnv-user-2", revision: 1 }]);
    expect([...server.kept.keys()]).toEqual(["cnv-user-2"]);
  });
});
