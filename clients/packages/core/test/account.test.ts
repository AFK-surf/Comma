import { NodeSql } from "@comma/core-kernel/node-sql";
import { CoreClient, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import { accountDbName } from "../src/account.ts";
import type { StationsHomeValue, StationsValue } from "../src/contract.ts";
import {
  FakeHost,
  FakeStations,
  inProcessOpener,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const WS = "wsp_1";
const me = {
  user: { id: "user-1", email: "user-1@example.test", name: "Ada" },
  workspaces: [{ id: WS, name: "Main", role: "owner" }],
  relay_urls: ["https://relay.example.test/"],
};
const listed = (id: string) => ({
  id,
  name: id,
  version: "1.0.0",
  online: false,
  enrolled_at: 1_700_000_000,
  enrolled_by: "user-1",
});

/** An account's database as the core before the station tables wrote it (version 1). */
function versionOne(): NodeSql {
  const db = NodeSql.memory(true);
  db.exec(`
    CREATE TABLE doc (name TEXT PRIMARY KEY, json TEXT NOT NULL, read_at INTEGER NOT NULL);
    CREATE TABLE meta (key TEXT PRIMARY KEY, json TEXT NOT NULL);
    PRAGMA user_version = 1;
  `);
  const put = (name: string, value: unknown) =>
    db.run("INSERT INTO doc (name, json, read_at) VALUES (?, ?, ?)", [
      name,
      JSON.stringify(value),
      1_000,
    ]);
  put("stations.me", me);
  put(`stations.list.${WS}`, [listed("st_b"), listed("st_a")]);
  put("tasks:grp_1", { kept: true });
  return db;
}

describe("the account's database", () => {
  it("upgrades a version 1 database in place: its documents stay, its station lists become station rows", async () => {
    const host = new FakeHost();
    const time = host.time!;
    host.stationMesh = new FakeStations(() => time.now()).ports;
    for (const method of ["GET", "POST", "PUT", "PATCH", "DELETE"])
      host.api.on(method, "/*", offline());
    const name = accountDbName("https://api.comma.test", "user-1");
    const db = versionOne();
    host.dbs.set(name, db);

    const core = startTestCore(host);
    const client = new CoreClient(inProcessOpener(core, host), {
      schedule: () => undefined,
    });
    const values = new Map<string, unknown>();
    const watch = (topic: Topic) =>
      client.subscribe(
        topic,
        (v) => values.set(topic.topic, v),
        () => undefined
      );
    core.observeSession(signedIn());
    watch({ topic: "stationsHome" });
    watch({ topic: "stations", workspace: WS });
    await time.pass(100);

    // With no network, what the database kept shows: the account, and the stations in their listed order.
    expect(values.get("stationsHome") as StationsHomeValue).toMatchObject({
      state: "ready",
      account: { id: "user-1" },
    });
    expect((values.get("stations") as StationsValue).stations.map((s) => s.id)).toEqual(
      ["st_b", "st_a"]
    );
    const account = core.session.current()!;
    expect(account.doc("tasks:grp_1")?.value).toEqual({ kept: true });
    expect(account.doc(`stations.list.${WS}`)).toBeNull();
    expect(host.dbs.get(name)).toBe(db);
    expect(db.all("PRAGMA user_version")[0]![0]).toBe(3);
  });
});
