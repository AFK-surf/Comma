// Prepare locally, then deploy the generated isolated config only after scope review.
// Usage: node scripts/control-experiment.mjs prepare <account-id>
//        node scripts/control-experiment.mjs run <temp-directory> <workers.dev-url>
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import https from "node:https";
import http from "node:http";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const [, , mode, arg, url] = process.argv;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

if (mode === "prepare") {
  assert.match(arg ?? "", /^[a-f0-9]{32}$/);
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "salix-vm-control-exp-"));
  const name = `salix-vm-control-exp-${crypto.randomUUID().slice(0, 8)}`;
  const fixture = path.join(root, "test/fixtures/control-experiment");
  const classes = ["Sandbox", "SandboxStandard1", "LegacySandbox"];
  const config = {
    name, account_id: arg, main: path.join(fixture, "worker.ts"),
    compatibility_date: "2026-10-01", compatibility_flags: ["nodejs_compat"], workers_dev: true,
    observability: { enabled: true },
    vars: { SANDBOX_TRANSPORT: "rpc", GATEWAY_BUILD_ID: "isolated-control-experiment", CONNECTOR_IMAGE_VERSION: "fixture-only" },
    containers: classes.map((class_name, i) => ({ class_name, name: `${name}-${class_name.toLowerCase()}`, image: path.join(fixture, "Dockerfile"), image_build_context: fixture, instance_type: ["standard-2", "standard-1", "lite"][i], max_instances: 1 })),
    durable_objects: { bindings: [...classes, "ReplayGuard"].map((class_name) => ({ name: class_name, class_name })) },
    migrations: [{ tag: "v1", new_sqlite_classes: [...classes, "ReplayGuard"] }],
  };
  await fs.writeFile(path.join(directory, "wrangler.json"), JSON.stringify(config, null, 2));
  await fs.writeFile(path.join(directory, "proxy.mjs"), "export default { fetch(request, env) { return env.TEST.fetch(request); } };\n");
  await fs.writeFile(path.join(directory, "proxy.json"), JSON.stringify({ name: `${name}-proxy`, account_id: arg, main: "./proxy.mjs", compatibility_date: "2026-06-30", services: [{ binding: "TEST", service: name, remote: true }] }, null, 2));
  await fs.writeFile(path.join(directory, "secrets.json"), JSON.stringify({ SALIX_VM_GATEWAY_SECRET: crypto.randomBytes(32).toString("hex") }), { mode: 0o600 });
  console.log(JSON.stringify({ directory, name, classes, max_instances: 1, routes: [], SDK: JSON.parse(await fs.readFile(path.join(root, "node_modules/@cloudflare/sandbox/package.json"), "utf8")).version }));
} else if (mode === "run") {
  const config = JSON.parse(await fs.readFile(path.join(arg, "wrangler.json"), "utf8"));
  assert.match(config.name, /^salix-vm-control-exp-[a-f0-9]+$/);
  const base = new URL(url);
  if (base.protocol === "http:" && base.hostname === "127.0.0.1") {
    const proxy = JSON.parse(await fs.readFile(path.join(arg, "proxy.json"), "utf8"));
    assert.deepEqual(proxy.services, [{ binding: "TEST", service: config.name, remote: true }]);
  } else {
    assert.equal(base.protocol, "https:");
    assert.ok(base.hostname.startsWith(config.name + ".") && base.hostname.endsWith(".workers.dev"));
  }
  const { SALIX_VM_GATEWAY_SECRET: secret } = JSON.parse(await fs.readFile(path.join(arg, "secrets.json"), "utf8"));
  const accessFile = process.env.SALIX_CONTROL_EXPERIMENT_ACCESS_TOKEN_FILE;
  const accessToken = accessFile ? (await fs.readFile(accessFile, "utf8")).trim() : undefined;
  const evidence = [];
  const record = (scenario, details) => { const entry = { scenario, ...details }; evidence.push(entry); console.log(JSON.stringify(entry)); };
  function signedHeaders(target, method, raw) {
    const timestamp = String(Math.floor(Date.now() / 1000));
    const nonce = crypto.randomUUID();
    const canonical = [method, target.pathname + target.search, timestamp, nonce, crypto.createHash("sha256").update(raw).digest("hex")].join("\n");
    return { ...accessToken && { "CF-Access-Token": accessToken }, "content-type": "application/json", "x-salix-timestamp": timestamp, "x-salix-nonce": nonce, "x-salix-request-id": nonce, "x-salix-signature": `sha256=${crypto.createHmac("sha256", secret).update(canonical).digest("hex")}` };
  }
  async function request(route, { method = "GET", body, control } = {}) {
    const target = new URL(route, base);
    if (control) target.searchParams.set("salix_control", JSON.stringify(control));
    const raw = body === undefined ? "" : JSON.stringify(body);
    const response = await fetch(target, { method, headers: signedHeaders(target, method, raw), ...raw && { body: raw }, redirect: "manual", signal: AbortSignal.timeout(90_000) });
    const text = await response.text();
    let result;
    try { result = JSON.parse(text); } catch { throw new Error(`non-JSON experiment response (${response.status}); verify isolated Access routing`); }
    return { status: response.status, body: result };
  }
  async function upgrade(route, control) {
    const target = new URL(route, base);
    target.searchParams.set("salix_control", JSON.stringify(control));
    return new Promise((resolve, reject) => {
      const request = (target.protocol === "https:" ? https : http).request(target, { headers: { ...signedHeaders(target, "GET", ""), connection: "Upgrade", upgrade: "websocket", "sec-websocket-version": "13", "sec-websocket-key": crypto.randomBytes(16).toString("base64") } });
      request.setTimeout(20_000, () => request.destroy(new Error("upgrade timeout")));
      request.on("error", reject);
      request.on("upgrade", (response, socket) => { socket.on("error", () => {}); resolve({ status: response.statusCode, socket }); });
      request.on("response", (response) => { response.resume(); resolve({ status: response.statusCode }); });
      request.end();
    });
  }
  async function until(fn, predicate, label, attempts = 45) {
    const deadline = Date.now() + 90_000;
    for (let i = 0; i < attempts && Date.now() < deadline; i++) { const value = await fn(); if (predicate(value)) return value; await sleep(1_000); }
    throw new Error(`bounded observation failed: ${label}`);
  }
  if (process.env.SALIX_CONTROL_EXPERIMENT_CLEANUP_ROUTE) {
    const route = process.env.SALIX_CONTROL_EXPERIMENT_CLEANUP_ROUTE;
    assert.match(route, /^\/experiment\/(standard1|standard2|legacy)\/exp-[a-z0-9-]+\/cleanup$/);
    console.log(JSON.stringify(await request(route, { method: "POST", body: {} })));
    process.exit(0);
  }
  if (process.env.SALIX_CONTROL_EXPERIMENT_OBSERVE_ROUTE) {
    const route = process.env.SALIX_CONTROL_EXPERIMENT_OBSERVE_ROUTE;
    assert.match(route, /^\/internal\/v1\/(profiles\/cf-standard-1\/)?sandboxes\/exp-[a-z0-9-]+\/control$/);
    console.log(JSON.stringify(await request(route)));
    process.exit(0);
  }
  try {
    for (const profile of ["standard1", "standard2"]) {
      const id = `exp-${crypto.randomUUID()}`;
      const prefix = profile === "standard1" ? "/internal/v1/profiles/cf-standard-1" : "/internal/v1";
      const target = `${prefix}/sandboxes/${id}`;
      const experiment = `/experiment/${profile}/${id}`;
      const p = (revision, generation = 1) => ({ owner_id: `fixture-${id}`, operation_id: `operation-${revision}`, generation, revision, claim_id: crypto.randomUUID() });
      const open = async (control) => assert.equal((await request(`${target}/control`, { method: "POST", body: { action: "open", control } })).status, 200);
      const seal = async (control) => { const result = await request(`${target}/control`, { method: "POST", body: { action: "seal", control } }); assert.equal(result.status, 200); return result.body; };
      const observe = () => request(`${target}/control`);
      const ensure = async (control) => {
        const issue = () => request(`${target}/ensure`, { method: "POST", body: { keep_alive: true }, control: { ...control, claim_id: crypto.randomUUID() } });
        const started = await issue();
        if (started.status >= 400) record(`${profile}: native start response`, started);
        return until(async () => {
          const status = await request(`${target}/status`, { control });
          if (status.status === 200 && status.body.status === "ready") return status;
          const observation = (await observe()).body;
          if (observation.control?.pending === null && observation.control.last_terminal?.action === "ensure" &&
              observation.control.last_terminal.status === 503 && observation.control.revision === control.revision) {
            record(`${profile}: exact failed start permits retry`, { passed: true });
            await issue();
          }
          return status;
        }, (r) => r.status === 200 && r.body.status === "ready", "native ready", 90);
      };
      try {
        record(`${profile}: before open`, (await observe()).body);
        const first = p(1); await open(first);
        record(`${profile}: after open`, (await observe()).body);
        const initialReceipt = await request(`${target}/receipt?operation=fixture-import`, { control: first });
        record(`${profile}: initial receipt`, initialReceipt);
        assert.equal(initialReceipt.status, 503);
        assert.equal((await observe()).body.running, false);
        record(`${profile}: stopped receipt is non-starting`, { passed: true });
        const late = request(`${experiment}/delay-ensure`, { method: "POST", body: { control: first, delay_ms: 2_000 } });
        await sleep(250); const second = p(2); await seal(second);
        assert.equal((await late).status, 409);
        assert.equal((await observe()).body.running, false);
        record(`${profile}: delayed old start rejected`, { passed: true });
        const third = p(3); await open(third); await ensure(third);
        const beforeEviction = (await observe()).body.control;
        await request(`${experiment}/evict`, { method: "POST", body: {} });
        const afterEviction = await until(observe, (r) => r.status === 200, "DO restart");
        assert.deepEqual(afterEviction.body.control, beforeEviction);
        record(`${profile}: DO eviction preserves control`, { passed: true });
        const imported = await request(`${experiment}/timeout-import`, { method: "POST", body: { control: { ...third, claim_id: crypto.randomUUID() }, delay_ms: 6_000 } });
        assert.equal(imported.status, 504);
        const fourth = p(4); const during = await seal(fourth);
        assert.equal(during.control.pending.action, "import");
        assert.equal((await request(`${target}/destroy`, { method: "POST", control: fourth })).status, 409);
        if (profile === "standard2") {
          await request(`${experiment}/evict`, { method: "POST", body: {} });
          await until(() => request(`${target}/receipt?operation=fixture-import`, { control: fourth }),
            (r) => r.status === 200 && r.body.phase === "restored", "same import receipt after DO eviction");
        }
        const terminal = await until(observe, (r) => r.body.managed_commands_settled === true, "underlying import settlement");
        assert.equal(terminal.body.control.last_terminal.action, "import");
        assert.equal((await request(`${target}/receipt?operation=fixture-import`, { control: fourth })).body.finishes, 1);
        record(`${profile}: timeout retains pending until ${profile === "standard2" ? "exact receipt after eviction" : "real response"}`, { passed: true });
        const lateDestroy = request(`${experiment}/delay-destroy`, { method: "POST", body: { control: { ...fourth, claim_id: crypto.randomUUID() }, delay_ms: 10_000 } });
        const fifth = p(5, 2); await open(fifth); await ensure(fifth);
        assert.equal((await lateDestroy).status, 409);
        assert.equal((await observe()).body.running, true);
        record(`${profile}: old destroy cannot stop reopened permit on the live Container`, { passed: true });
        const connected = await upgrade(`${target}/connect`, { ...fifth, claim_id: crypto.randomUUID() });
        assert.equal(connected.status, 101);
        const final = p(6, 2); assert.equal((await seal(final)).managed_commands_settled, true);
        assert.equal(connected.socket.destroyed, false);
        assert.equal((await upgrade(`${target}/connect`, { ...final, claim_id: crypto.randomUUID() })).status, 409);
        const repair = await upgrade(`${target}/connect?archive_repair=true`, { ...final, claim_id: crypto.randomUUID() });
        assert.equal(repair.status, 101);
        connected.socket.destroy(); repair.socket.destroy();
        record(`${profile}: WebSocket lifetime does not hold seal`, { passed: true });
        assert.equal((await request(`${target}/destroy`, { method: "POST", control: final })).status, 200);
        assert.equal((await request(`${target}/status`, { control: final })).status, 503);
        assert.equal((await observe()).body.running, false);
        record(`${profile}: stopped status stays non-starting`, { passed: true });
        const restart = p(7, 3); await open(restart);
        try {
          await ensure(restart);
          record(`${profile}: same DO destroy then restart`, { passed: true });
        } catch (error) {
          record(`${profile}: same DO destroy then restart`, { passed: false, error: error.message, observation: (await observe()).body });
        }
      } finally { await request(`${experiment}/cleanup`, { method: "POST", body: {} }); }
    }
    const legacy = `/experiment/legacy/exp-${crypto.randomUUID()}`;
    try {
      const result = await request(`${legacy}/legacy-start`, { method: "POST", body: { delay_ms: 3_000 } });
      assert.equal(result.status, 200, JSON.stringify(result));
      assert.equal(result.body.running_after_destroy, true);
      record("SDK delayed auto-start counterexample", { passed: true, ...result.body });
    } finally { await request(`${legacy}/cleanup`, { method: "POST", body: {} }); }
  } finally { await fs.writeFile(path.join(arg, "evidence.json"), JSON.stringify(evidence, null, 2)); }
} else {
  throw new Error("expected prepare <account-id> or run <temp-directory> <workers.dev-url>");
}
