import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile, rename, rm, readdir, stat } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { savePiApiKey, verifyPiApiKey } from "./pi.mjs";

const sdkEntry = process.env.COMMA_PI_TEST_SDK;
if (!sdkEntry) throw new Error("COMMA_PI_TEST_SDK must name the packaged Pi SDK entry");

for (const outcome of ["committed", "not_committed", "unknown", "unknown_after_rename", "committed_sync_failed"]) {
  test(`Pi native state ${outcome}`, async () => {
    const directory = await mkdtemp(join(tmpdir(), "comma-pi-auth-"));
    const authPath = join(directory, "auth.json");
    const previous = JSON.stringify({ openrouter: { type: "api_key", key: "old-synthetic-key" }, other: { type: "oauth", access: "untouched-test-access", refresh: "untouched-test-refresh", expires: 1 } });
    await writeFile(authPath, previous, { mode: 0o600 });
    let commits = 0;
    try {
      const result = await savePiApiKey({ sdkEntry, authPath, entry: { type: "api_key", key: "new-synthetic-key" }, signal: AbortSignal.timeout(10000), commit: async ({ temporaryPath, destinationPath }) => {
        commits++;
        assert.equal((await stat(temporaryPath)).mode & 0o777, 0o600);
        assert.equal(destinationPath, authPath);
        if (["committed", "unknown_after_rename", "committed_sync_failed"].includes(outcome)) await rename(temporaryPath, destinationPath);
        if (outcome.startsWith("unknown")) throw new Error("simulated lost commit response");
        return outcome === "committed_sync_failed" ? { save_result: "committed", issue: "storage_sync_failed" } : { save_result: outcome };
      } });
      assert.equal(commits, 1);
      assert.equal(result.save_result, outcome.startsWith("unknown") ? "unknown" : outcome.startsWith("committed") ? "committed" : outcome);
      if (outcome === "committed_sync_failed") assert.equal(result.issue,"storage_sync_failed");
      const current = await readFile(authPath, "utf8");
      if (["committed", "unknown_after_rename", "committed_sync_failed"].includes(outcome)) {
        assert.equal(JSON.parse(current).openrouter.key, "new-synthetic-key");
        assert.deepEqual(JSON.parse(current).other, JSON.parse(previous).other);
      } else assert.equal(current, previous);
      assert.deepEqual((await readdir(directory)).sort(), ["auth.json"]);
    } finally { await rm(directory, { recursive: true, force: true }); }
  });
}

test("Pi rejects executable and indirect credentials without touching storage", async () => {
  for (const key of ["!touch /tmp/not-executed", "$OPENROUTER_API_KEY", "${TOKEN}", "has whitespace"]) {
    let called = false;
    const result = await savePiApiKey({ sdkEntry, authPath: "/unused", entry: { type: "api_key", key }, commit: async () => { called = true; } });
    assert.deepEqual(result, { save_result: "not_committed", issue: "invalid_format" });
    assert.equal(called, false);
  }
});

test("Pi rejects an occupied native storage lock", async () => {
  const { createRequire } = await import("node:module");
  const lockfile = createRequire(sdkEntry)("proper-lockfile");
  const directory = await mkdtemp(join(tmpdir(), "comma-pi-auth-busy-"));
  const authPath = join(directory, "auth.json");
  const previous = "{}";
  await writeFile(authPath, previous, { mode: 0o600 });
  const release = await lockfile.lock(authPath, { realpath: false });
  try {
    const result = await savePiApiKey({ sdkEntry, authPath, entry: { type: "api_key", key: "synthetic-key" }, commit: async () => { assert.fail("busy native storage reached commit"); } });
    assert.deepEqual(result, { save_result: "not_committed", issue: "runtime_busy" });
    assert.equal(await readFile(authPath,"utf8"), previous);
  } finally { await release(); await rm(directory,{recursive:true,force:true}); }
});

test("an existing Pi runtime reads the replaced native credential", async () => {
  const { pathToFileURL } = await import("node:url");
  const { ModelRuntime } = await import(pathToFileURL(sdkEntry).href);
  const directory = await mkdtemp(join(tmpdir(), "comma-pi-auth-refresh-"));
  const authPath = join(directory, "auth.json");
  await writeFile(authPath, JSON.stringify({ openrouter: { type: "api_key", key: "old-synthetic-key" } }), { mode: 0o600 });
  try {
    const runtime = await ModelRuntime.create({ authPath, modelsPath: null, allowModelNetwork: false, refreshOnCreate: false });
    const before = await runtime.getAuth("openrouter", { env: {} });
    assert.equal(before.auth.apiKey, "old-synthetic-key");
    const result = await savePiApiKey({ sdkEntry, authPath, entry: { type: "api_key", key: "new-synthetic-key" }, signal: AbortSignal.timeout(10000), commit: async ({ temporaryPath, destinationPath }) => {
      await rename(temporaryPath, destinationPath);
      return { save_result: "committed" };
    } });
    assert.equal(result.save_result, "committed");
    const after = await runtime.getAuth("openrouter", { env: {} });
    assert.equal(after.auth.apiKey, "new-synthetic-key");
  } finally { await rm(directory, { recursive: true, force: true }); }
});

for (const status of [200, 401, 402, 403, 429, 503]) {
 test(`Pi explicit verification classifies HTTP ${status}`, async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "comma-pi-auth-verify-"));
  const authPath = join(directory,"auth.json");
  await writeFile(authPath,JSON.stringify({openrouter:{type:"api_key",key:"synthetic-verification-key"}}),{mode:0o600});
  let requests=0;
  t.mock.method(globalThis,"fetch",async (input,init) => {
   requests++;
   assert.equal(String(input),"https://openrouter.ai/api/v1/chat/completions");
   const headers = new Headers(init.headers);
   assert.equal(headers.get("authorization"),"Bearer synthetic-verification-key");
   const body=JSON.parse(init.body);
   assert.equal(body.model,"openai/gpt-4.1-nano");
   assert.equal(body.max_tokens ?? body.max_completion_tokens,64);
   assert.equal(body.tools,undefined);
   if(status!==200) return new Response(JSON.stringify({error:{message:"synthetic private error must not escape"}}),{status,headers:{"content-type":"application/json"}});
   return new Response('data: {"id":"synthetic","choices":[{"index":0,"delta":{"content":"OK"},"finish_reason":null}]}\n\ndata: {"id":"synthetic","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',{headers:{"content-type":"text/event-stream"}});
  });
  try {
   const result=await verifyPiApiKey({sdkEntry,authPath,modelId:"openai/gpt-4.1-nano"});
   assert.equal(requests,1);
   assert.deepEqual(result, status===200?{status:"authenticated"}:status===401?{status:"unauthenticated",issue:"credentials_rejected"}:{status:"error",issue:({402:"quota_exhausted",403:"permission_denied",429:"rate_limited",503:"provider_unavailable"})[status]});
  } finally { await rm(directory,{recursive:true,force:true}); }
 });
}

test("Pi first save creates its private native directory", async () => {
 const directory=await mkdtemp(join(tmpdir(),"comma-pi-auth-new-"));
 const authPath=join(directory,"agent","auth.json");
 try {
  const result=await savePiApiKey({sdkEntry,authPath,entry:{type:"api_key",key:"synthetic-first-key"},commit:async({temporaryPath,destinationPath})=>{await rename(temporaryPath,destinationPath);return {save_result:"committed"};}});
  assert.equal(result.save_result,"committed");
  assert.equal((await stat(join(directory,"agent"))).mode & 0o777,0o700);
  assert.equal(JSON.parse(await readFile(authPath,"utf8")).openrouter.key,"synthetic-first-key");
 } finally {await rm(directory,{recursive:true,force:true});}
});
