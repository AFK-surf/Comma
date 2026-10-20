// The loopback port's answers, as the Rust station's local.rs's tests have them.
import assert from "node:assert/strict";
import { test } from "node:test";
import { type Place, answer, langOfBrowser } from "../src/ops/loopback.ts";

const place: Place = { origin: "https://app.still.fail/", workspace: "W1", workspace_name: "Dev", station: "abc" };
const at = (path: string, query: string | null = null, p: Place | null = place) => answer(path, query, true, p, "zh").headers.location;

test("old links to the page go to the same page in the cloud", () => {
  const [w, s] = ["https://app.still.fail/w/W1", "https://app.still.fail/w/W1/s/abc"];
  assert.equal(at("/admin/chats/ember%3Ac-1", "history=k&entry=3"), `${s}/chats/ember%3Ac-1?history=k&entry=3`);
  assert.equal(at("/admin/chats/ember%3Ac-1"), `${s}/chats/ember%3Ac-1`);
  assert.equal(at("/admin/services/j1"), `${s}/services/j1`);
  assert.equal(at("/admin/connects/c1"), `${s}/connects/c1`);
  assert.equal(at("/admin/bots/c1"), `${s}/connects/c1`);
  assert.equal(at("/admin/settings/accounts"), `${s}/settings/accounts`);
  assert.equal(at("/admin/settings/accounts/p1"), `${s}/settings/accounts/p1`);
  for (const page of ["connects", "memory", "appearance", "shortcuts"]) assert.equal(at(`/admin/settings/${page}`), `${w}/settings/${page}`);
  assert.equal(at("/admin/settings/device"), `${w}/settings/stations`);
  assert.equal(at("/admin/new"), `${w}/new`);
  assert.equal(at("/admin/archive"), `${w}/archive`);
  for (const path of ["/admin/", "/admin", "/", "/admin/chats", "/admin/whatever/else"]) assert.equal(at(path), `${w}/`, path);
  assert.equal(answer("/admin/new", null, true, place, "zh").status, 302);
});

test("the loopback port serves no admin API nor page", () => {
  for (const path of ["/admin/api/overview", "/admin/api/events", "/admin/api/preview/5180/", "/admin/api"]) {
    const r = answer(path, null, true, place, "zh");
    assert.equal(r.status, 404, path);
    assert.equal(r.headers.location, undefined);
  }
  assert.equal(answer("/assets/index.js", null, true, place, "zh").status, 404);
  assert.equal(answer("/healthz", null, true, null, "zh").status, 200);
  assert.equal(answer("/healthz", null, false, null, "zh").status, 503);
});

test("in no workspace it says so and how to join one", () => {
  const never = answer("/admin/chats/k", null, true, null, "zh");
  assert.equal(never.status, 404);
  assert.ok(never.body.includes("还没有加入 workspace") && never.body.includes("stillfail station enroll"), never.body);
  const removed = answer("/admin/chats/k", null, true, { ...place, removed_at: 1_790_000_000 }, "zh");
  assert.equal(removed.headers.location, undefined);
  assert.ok(removed.body.includes("已被移出 workspace「Dev」") && removed.body.includes("2026-09-21T"), removed.body);
});

test("a browser's language: its stillfail-lang, else the first it accepts", () => {
  assert.equal(langOfBrowser({ "accept-language": "en-US,zh;q=0.8" }), "en");
  assert.equal(langOfBrowser({ "accept-language": "zh-CN,en;q=0.8" }), "zh");
  assert.equal(langOfBrowser({ "stillfail-lang": "en", "accept-language": "zh" }), "en");
  assert.equal(langOfBrowser({}), "zh");
});
