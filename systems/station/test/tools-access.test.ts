// The admin API's access (src/api/routes/tools.ts): the computer's one value, which the device tools and the device
// connector to Salix both follow. Its owner sets it once the device connection named one; on a station without one
// (a Cloud VM, a still.fail cloud station) the workspace's owners and admins do.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import type { Request } from "../src/api/request.ts";
import { routes } from "../src/api/routes/tools.ts";
import { SCOPE_LOCAL_FILE_READ, makeConnector } from "../src/connector/connector.ts";
import { computerAccess } from "../src/device/access.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { eventually } from "./connector/support/eventually.ts";
import { tempDir } from "./connector/support/temp.ts";

function rig(config: ConfigFile) {
  const table = routes({ config });
  return async (method: string, body: unknown, viewer: { sub: string; role: string }) => {
    const r: Request = {
      method, path: "/tools/access", query: [], headers: {}, lang: "en",
      body: Buffer.from(body === undefined ? "" : JSON.stringify(body)),
      viewer: { ...viewer, email: `${viewer.sub}@x`, name: viewer.sub, workspace: "ws", device: "d" },
    };
    const route = table.find((candidate) => candidate.method === method && candidate.pattern.test(r.path))!;
    const a = await route.handle(r, []);
    return [a.status, JSON.parse(String(a.body))] as const;
  };
}

test("without a device connection the workspace's managers set the computer's access", async () => {
  const config = new ConfigFile(tempDir());
  const ask = rig(config);
  assert.equal((await ask("GET", undefined, { sub: "usr_m", role: "member" }))[1].access, "off");
  assert.equal((await ask("PUT", { access: "full" }, { sub: "usr_m", role: "member" }))[0], 403);
  assert.deepEqual(await ask("PUT", { access: "all" }, { sub: "usr_a", role: "admin" }), [400, { error: "access is one of off, read, full" }]);
  assert.equal((await ask("PUT", { access: "read" }, { sub: "usr_a", role: "admin" }))[0], 200);
  assert.deepEqual(config.raw().tools, { access: "read", computer: true });
});

test("once a device connection named the computer's owner, only that user sets its access, and the connection follows", async () => {
  const config = new ConfigFile(tempDir());
  const access = computerAccess(config);
  const device = makeConnector({ root: tempDir(), deviceMode: true, scope: "", env: { HOME: tempDir() } }, undefined, { access });
  access.owner!("usr_owner");
  const ask = rig(config);
  assert.deepEqual(await ask("PUT", { access: "off" }, { sub: "usr_admin", role: "owner" }), [403, { error: "only this computer's owner sets its access" }]);
  assert.equal(device.currentScope(), "");
  assert.equal((await ask("PUT", { access: "read" }, { sub: "usr_owner", role: "member" }))[0], 200);
  await eventually(() => device.currentScope() === SCOPE_LOCAL_FILE_READ, "the device connection following read");
  assert.equal(device.metadata().capabilities!.access, "read");
  await Effect.runPromise(device.close());
});
