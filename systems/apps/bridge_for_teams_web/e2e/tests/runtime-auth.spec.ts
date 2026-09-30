import { test, expect } from "@playwright/test";
import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";

// Exercise the actual hook in Chromium, with an intentionally lost submit ACK.
// HTTP authorization/lease checks live in runtime_auth_controller_test.exs;
// native decryption/commit is exercised by the Go private-RPC integration.
const systems = path.resolve(__dirname, "../../../..");
const platform = process.platform === "darwin" ? "darwin" : "linux";
const architecture = process.arch === "arm64" ? "arm64" : "x64";
const bundle = execFileSync(path.join(systems, `_build/esbuild-${platform}-${architecture}`), [
  path.join(systems, "apps/bridge_for_teams_web/assets/js/runtime_auth.mjs"), "--bundle", "--format=iife", "--global-name=RuntimeAuthHarness",
], { encoding: "utf8" });
const fixture = JSON.parse(readFileSync(path.join(systems, "connector/salix-connect/testdata/runtime-auth/hpke-js.json"), "utf8"));

for (const provider of ["codex", "pi", "claude"] as const) {
test(`managed organization account handles a lost ${provider} bind response`, async ({ page }) => {
  const requests: {method: string, body: string | null}[] = [];
  let state = "unbound";
  const account = {id:`account-${provider}`,version:`version-${provider}`,credential_kind:provider === "codex" ? "subscription_oauth" : "provider_api_key",name:`${provider} team account`,connection:provider === "codex" ? undefined : {endpoint:"https://models.example.test",protocol:"anthropic_messages"}};
  await page.route("**/managed-harness", route => route.fulfill({contentType:"text/html",body:`
    <meta name="csrf-token" content="synthetic-csrf"><div id="panel" data-endpoint="/managed-auth">
    <p data-managed-status></p><div data-managed-unbound><select data-managed-source><option value="self_configured">self</option><option value="organization">organization</option></select>
    <label data-managed-account-label hidden><select data-managed-account></select></label><button data-managed-action="bind" hidden>bind</button></div>
    <div data-managed-bound hidden><p data-managed-account-summary></p><button data-managed-action="retry" hidden>retry</button><button data-managed-action="unbind">unbind</button></div>
    <button data-managed-action="refresh">refresh</button><p data-managed-feedback></p></div>`}));
  await page.route("**/managed-auth", async route => {
    const method = route.request().method();
    const body = route.request().postData();
    requests.push({method, body});
    if (method === "PUT") {
      expect(JSON.parse(body!)).toEqual({account_id:account.id,expected_account_version:account.version,expected_binding:null});
      state = "configured";
      return route.abort("failed");
    }
    const binding = state === "unbound" ? null : {id:7,account_id:account.id,enabled:true};
    await route.fulfill({contentType:"application/json",body:JSON.stringify({ok:true,data:{managed_auth:{source:state === "unbound" ? "self_configured" : "organization",state,provider,binding,account:binding ? account : null,accounts:state === "unbound" ? [account] : [],actions:state === "unbound" ? ["bind"] : ["refresh","unbind"],issue:null}}})});
  });
  await page.goto("/managed-harness");
  await page.addScriptTag({content:bundle});
  await page.evaluate(() => {const hook=Object.assign({},(window as any).RuntimeAuthHarness.ManagedRuntimeAuth,{el:document.querySelector("#panel")});(window as any).managedHook=hook;hook.mounted();});
  await expect(page.locator("[data-managed-status]")).toContainText("自行配置");
  await page.locator("[data-managed-source]").selectOption("organization");
  await page.getByRole("button",{name:"绑定账号"}).click();
  await expect(page.locator("[data-managed-status]")).toContainText("组织账号已配置");
  await expect(page.locator("[data-managed-feedback]")).toContainText("结果不确定");
  expect(requests.filter(request => request.method === "PUT")).toHaveLength(1);
  expect(requests.filter(request => request.method === "GET").length).toBeGreaterThanOrEqual(2);
  expect(await page.evaluate(() => localStorage.length)).toBe(0);
  await page.evaluate(() => (window as any).managedHook.destroyed());
});
}

test("Chromium seals input to the production non-root target owner", async ({ page }) => {
  test.setTimeout(120_000);
  const marker = "synthetic-browser-to-native-claude-key";
  const temporary = mkdtempSync(path.join(os.tmpdir(), "comma-runtime-auth-browser-"));
  const ready = path.join(temporary, "ready");
  let output = "";
  const target = spawn("go", ["test", "-run", "^TestRuntimeAuthBrowserTargetHarness$", "-count=1", "-v"], {
    cwd: path.join(systems, "connector/salix-connect"),
    env: { ...process.env, COMMA_RUNTIME_AUTH_BROWSER_HARNESS_READY: ready, COMMA_RUNTIME_AUTH_BROWSER_HARNESS_MARKER: marker },
    stdio: ["ignore", "pipe", "pipe"],
  });
  target.stdout.on("data", chunk => { output += chunk.toString(); });
  target.stderr.on("data", chunk => { output += chunk.toString(); });
  const exited = new Promise<number | null>(resolve => target.once("exit", resolve));
  let url = "";
  try {
    for (let attempt = 0; attempt < 600 && !url; attempt += 1) {
      if (target.exitCode !== null) throw new Error(`target harness exited early: ${output}`);
      try { url = readFileSync(ready, "utf8").trim(); } catch {}
      if (!url) await new Promise(resolve => setTimeout(resolve, 100));
    }
    if (!url) throw new Error("target harness did not become ready");

    const requestBodies: string[] = [];
    page.on("request", request => {
      if (request.url() === `${url}/runtime-auth`) requestBodies.push(request.postData() ?? "");
    });
    await page.goto(url);
    await page.addScriptTag({ content: bundle });
    await page.evaluate(() => {
      const hook = Object.assign({}, (window as any).RuntimeAuthHarness.RuntimeAuth, { el: document.querySelector("#panel") });
      (window as any).authHook = hook;
      hook.mounted();
    });
    await expect(page.locator("[data-auth-secret]")).toBeEnabled();
    await page.locator("[data-auth-secret]").fill(marker);
    await page.getByRole("button", { name: "Save to runtime" }).click();
    await expect(page.locator("[data-auth-status]")).toHaveText("已保存待验证");
    await expect(page.locator("[data-auth-secret]")).toHaveValue("");
    expect(requestBodies.some(body => JSON.parse(body).action === "input_submit")).toBe(true);
    expect(requestBodies.every(body => !body.includes(marker))).toBe(true);
    expect(await page.evaluate(() => localStorage.length)).toBe(0);
  } finally {
    if (url) await page.request.post(`${url}/shutdown`).catch(() => {});
    else target.kill("SIGTERM");
    const exitCode = await exited;
    rmSync(temporary, { recursive: true, force: true });
    expect(output).not.toContain(marker);
    expect(exitCode, output).toBe(0);
  }
});

for (const failure of ["submit_ack", "status_after_commit"]) {
test(`secret material is encrypted once and preserved receipts survive ${failure}`, async ({ page }) => {
  const marker = "synthetic-browser-private-marker";
  const requests: any[] = [];
  let statusReads = 0;
  const target = { kind: "compute_workload", workload_id: "workload-a" };
  const method = { backend: "openrouter", method: "credential_import", form: "api_key", schema_version: 1 };
  await page.route("http://127.0.0.1:4101/auth-harness", (route) => route.fulfill({ contentType: "text/html", body: `
    <meta charset="UTF-8"><meta name="csrf-token" content="synthetic-csrf">
    <div id="panel" data-target='${JSON.stringify(target)}' data-endpoint="/runtime-auth">
      <p data-auth-status></p><select data-auth-method disabled></select>
      <input data-auth-secret type="password" disabled><input data-auth-file type="file" disabled>
      <button data-auth-action="save" disabled>保存到运行环境</button><button data-auth-action="verify" disabled>验证</button>
      <button data-auth-action="refresh">重新检查</button><button data-auth-action="cancel" disabled>取消</button>
      <p data-auth-feedback role="status"></p>
    </div>` }));
  await page.route("**/runtime-auth", async (route) => {
    const wire = route.request().postData()!;
    expect(wire).not.toContain(marker);
    const body = JSON.parse(wire);
    requests.push(body);
    expect(body.target).toEqual(target);
    if (body.action === "input_submit") {
      const envelope = JSON.parse(body.envelope);
      expect(Object.keys(envelope).sort()).toEqual(["ciphertext", "enc"]);
      await new Promise((resolve) => setTimeout(resolve, 100));
      if (failure === "submit_ack") return route.abort("failed");
      return route.fulfill({ contentType: "application/json", body: JSON.stringify({ok: true, data: {runtime_auth: {save_result: "committed", issue: ""}}}) });
    }
    if (body.action === "status" && ++statusReads === 2 && failure === "status_after_commit") return route.abort("failed");
    const result = body.action === "status" ? { provider: "pi", auth: { status: "configured" }, native_ready: true, dispatch_ready: false, methods: [method], attempt: null } : {
      public_key: fixture.Public, context: { ...fixture.Context, form: "api_key", expires_at: Date.now() + 60000 },
    };
    await route.fulfill({ contentType: "application/json", body: JSON.stringify({ ok: true, data: { runtime_auth: result } }) });
  });
  await page.goto("/auth-harness");
  await page.addScriptTag({ content: bundle });
  await page.evaluate(() => {
    const hook = Object.assign({}, (window as any).RuntimeAuthHarness.RuntimeAuth, { el: document.querySelector("#panel") });
    (window as any).authHook = hook;
    hook.mounted();
  });
  await expect(page.locator("[data-auth-secret]")).toBeEnabled();
  await page.locator("[data-auth-secret]").fill(marker);
  await page.getByRole("button", { name: "保存到运行环境" }).dblclick();
  await expect(page.getByRole("status")).toContainText(failure === "submit_ack" ? "保存结果未知" : "配置已保存，当前验证或状态读取未完成");
  await expect(page.locator("[data-auth-secret]")).toHaveValue("");
  expect(requests.filter((request) => request.action === "input_submit")).toHaveLength(1);
  await page.getByRole("button", { name: "重新检查" }).click();
  await expect(page.locator("[data-auth-status]")).toHaveText("已保存待验证");
  expect(requests.filter((request) => request.action === "input_submit")).toHaveLength(1);
  await page.locator("[data-auth-secret]").fill(marker);
  await page.evaluate(() => (window as any).authHook.destroyed());
  await expect(page.locator("[data-auth-secret]")).toHaveValue("");
  expect(await page.evaluate(() => localStorage.length)).toBe(0);
});

}

for (const end of ["close", "expiry"] as const) {
test(`native device code is cleared on ${end}`, async ({ page }) => {
  await page.clock.install();
  await page.route("**/auth-harness", route => route.fulfill({contentType:"text/html",body:`<div id="panel" data-target='{"kind":"connected_runtime","device_id":"device","runtime_id":"runtime"}' data-endpoint="/runtime-auth"><p data-auth-status></p><select data-auth-method></select><input data-auth-secret><input data-auth-file type="file"><div data-auth-ceremony hidden><a data-auth-login-url>登录页</a><code data-auth-user-code></code></div><button data-auth-action="save">保存</button><button data-auth-action="verify">验证</button><button data-auth-action="cancel">取消</button><p data-auth-feedback></p></div>`}));
  await page.route("**/runtime-auth", route => route.fulfill({contentType:"application/json",body:JSON.stringify({ok:true,data:{runtime_auth:{provider:"codex",auth:{status:"pending"},native_ready:true,dispatch_ready:false,methods:[],attempt:{owned:true,attempt_id:"attempt",expires_at:Date.now()+60000,ceremony:{verification_url:"https://auth.openai.com/codex/device",user_code:"SYNTHETIC-CODE"}}}}})}));
  await page.goto("/auth-harness");
  await page.addScriptTag({content:bundle});
  await page.evaluate(() => {const hook = Object.assign({}, (window as any).RuntimeAuthHarness.RuntimeAuth, {el:document.querySelector("#panel")}); (window as any).authHook=hook;hook.mounted();});
  await expect(page.locator("[data-auth-user-code]")).toHaveText("SYNTHETIC-CODE");
  await expect(page.locator("[data-auth-login-url]")).toHaveAttribute("href","https://auth.openai.com/codex/device");
  if (end === "close") await page.evaluate(() => (window as any).authHook.destroyed());
  else await page.clock.runFor(61000);
  await expect(page.locator("[data-auth-user-code]")).toHaveText("");
  await expect(page.locator("[data-auth-login-url]")).not.toHaveAttribute("href");
});

}

test("Claude authorization code is HPKE sealed before native login completion", async ({ page }) => {
  const marker = "synthetic-claude-authorization-code";
  const requests: any[] = [];
  const target = {kind: "compute_workload", workload_id: "claude-workload"};
  const url = "https://claude.com/cai/oauth/authorize?code=true&client_id=client&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=challenge&code_challenge_method=S256&state=state";
  const context = {...fixture.Context, provider:"claude", backend:"anthropic", method:"native_login", form:"authorization_code", target_kind:"compute_workload", workload_id:"claude-workload", expires_at:Date.now()+60000};
  const offer = {context, public_key:fixture.Public, phase:"awaiting_user", save_result:"not_committed"};
  let started = false;
  let authenticated = false;
  await page.route("**/auth-harness", route => route.fulfill({contentType:"text/html",body:`
    <meta charset="UTF-8"><meta name="csrf-token" content="synthetic-csrf">
    <div id="panel" data-target='${JSON.stringify(target)}' data-endpoint="/runtime-auth"><p data-auth-status></p><select data-auth-method></select>
      <input data-auth-secret><input data-auth-file type="file"><div data-auth-ceremony hidden><a data-auth-login-url>登录页</a>
      <p data-auth-device-code><code data-auth-user-code></code></p><label data-auth-callback-label hidden><input data-auth-callback-code type="password"></label>
      <button data-auth-action="complete-login" hidden>提交授权码</button><p data-auth-login-help></p></div>
      <button data-auth-action="login">原生登录</button><button data-auth-action="save">保存</button><button data-auth-action="verify">验证</button>
      <button data-auth-action="refresh">重新检查</button><button data-auth-action="cancel">取消</button><p data-auth-feedback></p></div>`}));
  await page.route("**/runtime-auth", async route => {
    const wire = route.request().postData()!;
    expect(wire).not.toContain(marker);
    const body = JSON.parse(wire);
    requests.push(body);
    let result;
    if (body.action === "login_start") { started = true; result = {...offer, verification_url:url}; }
    else if (body.action === "input_submit") { authenticated = true; result = {save_result:"committed", issue:""}; }
    else result = authenticated ? {provider:"claude",auth:{status:"authenticated"},native_ready:true,dispatch_ready:false,methods:[],attempt:null} : started ?
      {provider:"claude",auth:{status:"pending"},native_ready:true,dispatch_ready:false,methods:[],attempt:{owned:true,attempt_id:context.attempt_id,expires_at:context.expires_at,phase:"awaiting_user",save_result:"not_committed",issue:"",ceremony:{verification_url:url,user_code:"",input:offer}}} :
      {provider:"claude",auth:{status:"unauthenticated"},native_ready:true,dispatch_ready:false,methods:[{backend:"anthropic",method:"native_login",form:"authorization_code",schema_version:1}],attempt:null};
    await route.fulfill({contentType:"application/json",body:JSON.stringify({ok:true,data:{runtime_auth:result}})});
  });
  await page.goto("/auth-harness");
  await page.addScriptTag({content:bundle});
  await page.evaluate(() => {const hook=Object.assign({},(window as any).RuntimeAuthHarness.RuntimeAuth,{el:document.querySelector("#panel")});(window as any).authHook=hook;hook.mounted();});
  await page.getByRole("button", {name:"原生登录"}).click();
  await expect(page.locator("[data-auth-callback-code]")).toBeVisible();
  await page.locator("[data-auth-callback-code]").fill(marker);
  await page.getByRole("button", {name:"提交授权码"}).click();
  await expect(page.locator("[data-auth-status]")).toHaveText("已鉴权，运行环境尚未就绪");
  await expect(page.locator("[data-auth-callback-code]")).toHaveValue("");
  expect(requests.filter(request => request.action === "input_submit")).toHaveLength(1);
});

test("saved-unverified completion wakes one Router request without resubmitting auth", async ({ page }) => {
  const completions: any[] = [];
  const target = { kind: "compute_workload", workload_id: "workload-router" };
  await page.route("**/auth-harness", route => route.fulfill({contentType:"text/html",body:`
    <meta charset="UTF-8"><meta name="csrf-token" content="synthetic-csrf">
    <div id="panel" data-target='${JSON.stringify(target)}' data-endpoint="/runtime-auth" data-request-id="request-router">
      <p data-auth-status></p><select data-auth-method></select><input data-auth-secret><input data-auth-file type="file">
      <button data-auth-action="save">保存</button><button data-auth-action="verify">验证</button>
      <button data-auth-action="refresh">重新检查</button><button data-auth-action="cancel">取消</button>
      <button data-auth-action="finish-saved" hidden>结束处理（已保存未验证）</button><p data-auth-feedback></p>
    </div>`}));
  await page.route("**/runtime-auth/requests/request-router/complete", async route => {
    completions.push(JSON.parse(route.request().postData()!));
    await new Promise(resolve => setTimeout(resolve, 100));
    await route.fulfill({contentType:"application/json",body:JSON.stringify({ok:true,data:{runtime_auth_request:{status:"completed"}}})});
  });
  await page.route("**/runtime-auth", route => route.fulfill({contentType:"application/json",body:JSON.stringify({ok:true,data:{runtime_auth:{provider:"claude",auth:{status:"configured"},native_ready:true,dispatch_ready:false,methods:[],attempt:null}}})}));
  await page.goto("/auth-harness");
  await page.addScriptTag({content:bundle});
  await page.evaluate(() => {const hook = Object.assign({}, (window as any).RuntimeAuthHarness.RuntimeAuth, {el:document.querySelector("#panel")}); (window as any).authHook=hook;hook.mounted();});
  const finish = page.getByRole("button", {name:"结束处理（已保存未验证）"});
  await expect(finish).toBeVisible();
  await finish.dblclick();
  await expect(page.locator("[data-auth-feedback]")).toContainText("已通知请求方");
  expect(completions).toEqual([{outcome:"saved_unverified"}]);
});

test("device runtime changes organization account with one action and preserves the expected binding", async ({ page }) => {
  const accounts = [{id:"first",version:"v1",name:"First team"},{id:"second",version:"v2",name:"Second team"}];
  let account = accounts[0];
  let binding = {id:41,account_id:account.id,enabled:true};
  const writes: {method:string,body:any}[] = [];
  await page.route("**/device-binding-harness", route => route.fulfill({contentType:"text/html",body:`
    <meta name="csrf-token" content="synthetic-csrf"><div><div id="panel" data-endpoint="/devices/mac/runtimes/codex/managed-auth">
    <p data-managed-status></p><div data-managed-unbound hidden><select data-managed-source><option value="self_configured">self</option><option value="organization">organization</option></select>
    <label data-managed-account-label hidden><select data-managed-account></select></label><button data-managed-action="bind" hidden>bind</button></div>
    <div data-managed-bound hidden><p data-managed-account-summary></p><button data-managed-action="retry" hidden>retry</button><button data-managed-action="unbind">unbind</button></div>
    <button data-managed-action="refresh">refresh</button><p data-managed-feedback></p></div><div data-managed-self-auth="true" hidden>native credentials</div></div>`}));
  await page.route("**/devices/mac/runtimes/codex/managed-auth", async route => {
    if (route.request().method() !== "GET") {
      const body = route.request().postDataJSON();
      writes.push({method:route.request().method(),body});
      expect(body).toEqual({account_id:"second",expected_account_version:"v2",expected_binding:binding});
      account = accounts[1]; binding = {id:42,account_id:account.id,enabled:true};
    }
    await route.fulfill({contentType:"application/json",body:JSON.stringify({ok:true,data:{managed_auth:{source:"organization",state:"configured",provider:"codex",binding,account,accounts,actions:["bind","retry","unbind"],can_configure:true,can_self_configure:true}}})});
  });
  await page.goto("/device-binding-harness");
  await page.addScriptTag({content:bundle});
  await page.evaluate(() => {const hook=Object.assign({},(window as any).RuntimeAuthHarness.ManagedRuntimeAuth,{el:document.querySelector("#panel")});(window as any).managedHook=hook;hook.mounted();});
  await expect(page.locator("[data-managed-account-summary]")).toHaveText("First team");
  await page.locator("[data-managed-account]").selectOption("second");
  await page.getByRole("button",{name:"更换账号"}).click();
  await expect(page.locator("[data-managed-account-summary]")).toHaveText("Second team");
  expect(writes.map(write => write.method)).toEqual(["PUT"]);
  await expect(page.locator("[data-managed-self-auth]")).toBeHidden();
  await page.evaluate(() => (window as any).managedHook.destroyed());
});

test("device self login survives account-list failure and explains unavailable binding state", async ({ page }) => {
  let unavailable = false;
  await page.route("**/managed-harness", route => route.fulfill({contentType:"text/html",body:`
    <meta name="csrf-token" content="synthetic-csrf"><main><div id="panel" data-endpoint="/managed-auth">
    <p data-managed-status></p><div data-managed-unbound><select data-managed-source><option value="self_configured">self</option><option value="organization">organization</option></select>
    <label data-managed-account-label hidden><select data-managed-account></select></label><button data-managed-action="bind" hidden>bind</button></div>
    <div data-managed-bound hidden></div><button data-managed-action="refresh">refresh</button><p data-managed-feedback></p></div>
    <div data-managed-self-auth="true" hidden><button>Native login</button></div></main>`}));
  await page.route("**/managed-auth", route => route.fulfill({status:unavailable ? 503 : 200,contentType:"application/json",body:JSON.stringify(unavailable ? {ok:false,error:{code:"runtime_auth_unavailable"}} : {ok:true,data:{managed_auth:{source:"self_configured",state:"unbound",provider:"codex",can_self_configure:true,can_configure:true,accounts:[],accounts_unavailable:true,actions:["bind"]}}})}));
  await page.goto("/managed-harness");
  await page.addScriptTag({content:bundle});
  const mount = () => page.evaluate(() => {const hook=Object.assign({},(window as any).RuntimeAuthHarness.ManagedRuntimeAuth,{el:document.querySelector("#panel")});(window as any).managedHook=hook;hook.mounted();});
  await mount();
  await expect(page.getByRole("button",{name:"Native login"})).toBeVisible();
  await expect(page.locator("[data-managed-feedback]")).toContainText("账号列表暂时不可用");
  await page.evaluate(() => (window as any).managedHook.destroyed());
  unavailable = true;
  await page.reload();
  await page.addScriptTag({content:bundle});
  await mount();
  await expect(page.locator("[data-managed-feedback]")).toContainText("暂不能修改自行登录");
  await expect(page.getByRole("button",{name:"Native login"})).toBeHidden();
  await page.evaluate(() => (window as any).managedHook.destroyed());
});
