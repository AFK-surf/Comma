// Writes asked with an idempotency key happen once (once.rs): asked again, or twice at once, the first answer.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Admin } from "../src/api/admin.ts";
import { Store } from "../src/store/store.ts";

const viewer = { sub: "u", email: "a@x", name: "A", role: "member", workspace: "w", device: "d" };

test("a keyed write is done once; others get its answer; a different key or viewer is another write", async () => {
  const store = Store.open(":memory:", null);
  store.insertSession({ key: "s1", connect: "ds", runtime: "claude", profile: "cc", workspace: "/w/s1", token: "t", createdAt: 1, lastActiveAt: 1 });
  let writes = 0;
  const stop = store.subscribe((c) => c.type === "pins" && writes++);
  const admin = new Admin({ names: new Map(), read: async () => "{}" } as any, { store });
  const ask = (key: string | null, who = viewer) =>
    admin.handle({ method: "PUT", path: "/sessions/s1/pin", query: [], headers: key ? { "Idempotency-Key": key } : {}, body: Buffer.alloc(0), viewer: who, lang: "en" });
  const [a, b] = await Promise.all([ask("k1"), ask("k1")]);
  await ask("k1");
  assert.equal(writes, 1);
  assert.equal(String(a.body), String(b.body));
  assert.equal(a.headers["stillfail-idempotent"], "1");
  await ask("k2");
  await ask("k1", { ...viewer, email: "b@x" });
  await ask(null);
  assert.equal(writes, 4);
  // A refusal (4xx) is kept as well.
  const no = () => admin.handle({ method: "PUT", path: "/sessions/nope/pin", query: [], headers: { "idempotency-key": "k3" }, body: Buffer.alloc(0), viewer, lang: "en" });
  assert.equal((await no()).status, 404);
  assert.equal((await no()).status, 404);
  stop();
});
