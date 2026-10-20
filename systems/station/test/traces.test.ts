// The mesh's spans (station telemetry.rs's tests).
import assert from "node:assert/strict";
import { test } from "node:test";
import { Traces, parseParent, route } from "../src/mesh/traces.ts";

test("a traceparent is read as W3C says", () => {
  const parent = parseParent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")!;
  assert.ok(parent.sampled);
  assert.equal(parent.span, "00f067aa0ba902b7");
  assert.equal(parseParent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00")!.sampled, false);
  for (const bad of ["", "00-zz-00f067aa0ba902b7-01", "00-00000000000000000000000000000000-00f067aa0ba902b7-01", "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"]) {
    assert.equal(parseParent(bad), null, bad);
  }
});

test("spans only when on and sampled", async () => {
  const parent = parseParent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
  assert.equal(new Traces(false).start(parent), null);
  const on = new Traces(true);
  assert.equal(on.start(null), null);
  assert.equal(on.start(parseParent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00")), null);
  const span = on.start(parent)!;
  const traceparent = Traces.traceparent(span);
  assert.ok(traceparent.startsWith("00-4bf92f3577b34da6a3ce929d0e0e4736-") && traceparent.endsWith("-01"));
  on.end(span, "GET /admin/api/threads", [["http.response.status_code", 200]], false);
  const [recorded] = on.spans as any[];
  assert.equal(recorded.parentSpanId, "00f067aa0ba902b7");
  assert.equal(recorded.attributes[0].value.intValue, "200");
  assert.equal(traceparent.slice(36, 52), recorded.spanId);
  on.spans.length = 0;
  await on.close();
});

test("routes hide ids", () => {
  assert.equal(route("/admin/api/threads/42/messages?limit=50"), "/admin/api/threads/:id/messages");
  assert.equal(route("/admin/api/sessions/slack:T1:C1/files?name=a.pdf"), "/admin/api/sessions/:id/files");
});
