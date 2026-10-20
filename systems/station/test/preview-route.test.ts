// A preview through the admin API: any method to the service on this machine, the query as asked, its answer back.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { Admin } from "../src/api/admin.ts";

test("a preview's request reaches its service and the answer comes back", async () => {
  const service = createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => res.writeHead(201, { "set-cookie": ["a=1", "b=2"], "x-seen": `${req.method} ${req.url} ${body}` }).end("hello"));
  }).listen(0, "127.0.0.1");
  await new Promise((r) => service.once("listening", r));
  const port = (service.address() as AddressInfo).port;
  const admin = new Admin({ names: new Map(), read: async () => "{}" } as any);
  const viewer = { sub: "u", email: "a@x", name: "", role: "member", workspace: "w", device: "d" };
  const answer = await admin.handle({ method: "POST", path: `/preview/${port}/api/x`, query: [["q", "1"]], search: "?q=1", headers: {}, body: Buffer.from("hi"), viewer, lang: "en" });
  assert.equal(answer.status, 201);
  assert.equal(answer.headers["x-seen"], "POST /api/x?q=1 hi");
  assert.equal(answer.headers["set-cookie"], "a=1, b=2");
  const chunks: Buffer[] = [];
  for await (const c of answer.body as AsyncIterable<Buffer>) chunks.push(Buffer.from(c));
  assert.equal(Buffer.concat(chunks).toString(), "hello");
  service.close();
});
