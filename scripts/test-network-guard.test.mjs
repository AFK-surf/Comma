// Run with `node --import ./scripts/test-network-guard.mjs --test`.
import assert from "node:assert/strict";
import { createServer, request } from "node:http";
import { connect } from "node:net";
import { test } from "node:test";
import { isLocal, takeBlocked } from "./test-network-guard.mjs";

test("this machine is local and other hosts are not", () => {
  for (const host of [
    "localhost",
    "app-shell.localhost",
    "127.0.0.2",
    "::1",
    "[::1]",
    "::ffff:127.0.0.1",
  ])
    assert.ok(isLocal(host), host);
  for (const host of [
    "registry.npmjs.org",
    "8.8.8.8",
    "2606:4700::1111",
    "::ffff:1.1.1.1",
  ])
    assert.ok(!isLocal(host), host);
});

test("fetch reaches a server on this machine", async () => {
  const server = createServer((_request, response) => response.end("ok"));
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const response = await fetch(`http://localhost:${server.address().port}/`);
    assert.equal(await response.text(), "ok");
  } finally {
    server.close();
  }
});

test("a connection to another host is refused, naming the host", async () => {
  await assert.rejects(fetch("https://registry.npmjs.org/"), (error) => {
    assert.match(
      String(error.cause?.message ?? error.message),
      /real network: .*registry\.npmjs\.org:443/
    );
    return true;
  });
  assert.throws(() => connect(443, "192.0.2.1"), /connected to 192\.0\.2\.1:443/);
  assert.equal(takeBlocked().length, 2);
  // Both were refused on purpose: the run itself has not failed.
  process.exitCode = 0;
});

// A caller's own resolver that answers `address` for any name.
const pinned = (address) => (_hostname, options, callback) =>
  options.all ? callback(null, [{ address, family: 4 }]) : callback(null, address, 4);

test("a name the caller resolves itself goes where its lookup answers", async () => {
  const server = createServer((_request, response) => response.end("ok"));
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const get = (address) =>
    new Promise((resolve, reject) =>
      request(
        `http://media.example:${server.address().port}/`,
        { agent: false, lookup: pinned(address) },
        (response) =>
          response.on("data", () => {}).on("end", () => resolve(response.statusCode))
      )
        .on("error", reject)
        .end()
    );
  try {
    assert.equal(await get("127.0.0.1"), 200);
    await assert.rejects(
      get("192.0.2.1"),
      /connected to media\.example \(192\.0\.2\.1\)/
    );
    assert.equal(takeBlocked().length, 1);
    process.exitCode = 0;
  } finally {
    server.close();
  }
});

test("subprocesses inherit an offline environment", () => {
  assert.equal(process.env.npm_config_offline, "true");
  assert.equal(process.env.GOPROXY, "off");
  assert.equal(process.env.HTTPS_PROXY, "http://127.0.0.1:9");
});
