import { Aes128Gcm, CipherSuite, DhkemP256HkdfSha256, HkdfSha256 } from "@hpke/core";

const domain = "comma.runtime-auth.input.v1";
const encoder = new TextEncoder();
const maximumPlaintext = 64 * 1024;
const runtimeAuthPollIntervalMs = 5_000;
const runtimeAuthMaximumPolls = 60;
const fields = ["actor_id", "tenant_id", "project_id", "target_kind", "workload_id", "device_id", "runtime_id", "provider", "backend", "method", "form", "schema_version", "attempt_id", "runtime_instance_id", "generation", "connection_epoch", "allocation_id", "allocation_generation", "native_generation", "auth_epoch", "sequence", "expires_at"];
const invalid = () => new Error("invalid_format");
const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const only = (value, allowed) => object(value) && Object.keys(value).every((key) => allowed.includes(key));
const token = (value) => typeof value === "string" && value.length > 0 && !/[\s\p{Cc}]/u.test(value);

// One visible panel owns at most one timer. It polls an active attempt for at
// most five minutes. Closing or hiding the panel stops the timer.
export function runtimeAuthPollDelay(attempt, polls) {
  return attempt && ["awaiting_user", "receiving", "applying", "verifying"].includes(attempt.phase) &&
    Number.isInteger(polls) && polls >= 0 && polls < runtimeAuthMaximumPolls
    ? runtimeAuthPollIntervalMs
    : null;
}

const managedStateText = {
  unbound: "此运行环境使用自行配置。",
  installing: "账号已绑定，正在配置运行环境。",
  configured: "组织账号已配置。",
  failed: "账号已绑定，但配置失败。",
  account_disabled: "组织账号已禁用。系统已停止签发凭据，并在移除运行时凭据。",
  revoking: "正在解绑并移除运行时凭据。",
};

const managedIssueText = {
  delivery_failed: "运行环境未确认配置。请重试同一账号，或先解绑。",
  account_disabled: "此账号已禁用。离线副本可能仍可使用，请在 Provider 端吊销密钥。",
  personal_credentials_conflict: "运行环境中有个人凭据。请先人工处理个人配置。",
  runtime_busy: "运行环境正在执行任务。请在任务结束后重试。",
};

export function managedAuthPollDelay(state, polls) {
  return ["installing", "revoking", "account_disabled"].includes(state) &&
    Number.isInteger(polls) && polls >= 0 && polls < 60 ? 5_000 : null;
}

export const ManagedRuntimeAuth = {
  mounted() {
    this.alive = true;
    this.operation = null;
    this.snapshot = null;
    this.polls = 0;
    this.pollTimer = null;
    this.endpoint = this.el.dataset.endpoint;
    this.onAction = (event) => {
      const action = event.target.closest("[data-managed-action]")?.dataset.managedAction;
      if (!action || !this.el.contains(event.target) || this.operation) return;
      event.preventDefault();
      this.run(action);
    };
    this.onSource = () => this.renderSource();
    this.onVisibility = () => {
      clearTimeout(this.pollTimer);
      this.pollTimer = null;
      if (!document.hidden && this.alive && !this.operation) this.run("refresh");
    };
    this.el.addEventListener("click", this.onAction);
    this.el.querySelector("[data-managed-source]")?.addEventListener("change", this.onSource);
    document.addEventListener("visibilitychange", this.onVisibility);
    this.run("refresh");
  },
  destroyed() { this.dispose(); },
  dispose() {
    this.alive = false;
    this.operation?.abort();
    this.operation = null;
    clearTimeout(this.pollTimer);
    this.el.removeEventListener("click", this.onAction);
    this.el.querySelector("[data-managed-source]")?.removeEventListener("change", this.onSource);
    document.removeEventListener("visibilitychange", this.onVisibility);
  },
  show(message) {
    const output = this.el.querySelector("[data-managed-feedback]");
    if (output) output.textContent = message;
  },
  async request(method, body, url = this.endpoint) {
    const operation = this.operation;
    const options = {
      method, credentials: "same-origin", cache: "no-store", redirect: "error",
      headers: { "accept": "application/json", "x-csrf-token": document.querySelector("meta[name='csrf-token']")?.content ?? "" },
      signal: operation.signal,
    };
    if (body) {
      options.headers["content-type"] = "application/json";
      options.body = JSON.stringify(body);
    }
    const response = await fetch(url, options);
    const payload = await response.json();
    if (!this.alive || this.operation !== operation || operation.signal.aborted) throw new Error("target_changed");
    if (!response.ok || !payload.ok) throw new Error(payload.error?.code || "request_failed");
    return payload.data.managed_auth;
  },
  renderSource() {
    const organization = this.el.querySelector("[data-managed-source]")?.value === "organization";
    const label = this.el.querySelector("[data-managed-account-label]");
    const bind = this.el.querySelector('[data-managed-action="bind"]');
    const next = this.el.querySelector('[data-managed-action="accounts-next"]');
    if (label) label.hidden = !organization;
    if (bind) {
      bind.hidden = !organization;
      bind.textContent = this.snapshot?.binding ? "更换账号" : "绑定账号";
    }
    if (next) next.hidden = !organization || !this.snapshot?.accounts_next;
    const selfAuth = this.el.parentElement?.querySelector('[data-managed-self-auth="true"]');
    if (selfAuth) selfAuth.hidden = organization || this.snapshot?.state !== "unbound" || (this.snapshot?.can_self_configure ?? this.snapshot?.can_configure) === false;
  },
  render() {
    const value = this.snapshot;
    clearTimeout(this.pollTimer);
    this.pollTimer = null;
    const status = this.el.querySelector("[data-managed-status]");
    if (status) status.textContent = managedStateText[value.state] || "组织账号状态不可用。";
    const unbound = this.el.querySelector("[data-managed-unbound]");
    const bound = this.el.querySelector("[data-managed-bound]");
    if (unbound) unbound.hidden = !(value.actions || []).includes("bind") || value.can_configure === false;
    if (bound) bound.hidden = value.state === "unbound";
    const source = this.el.querySelector("[data-managed-source]");
    if (source && value.state !== "unbound") source.value = "organization";
    const sourceLabel = this.el.querySelector("[data-managed-source-label]");
    if (sourceLabel) sourceLabel.hidden = value.state !== "unbound";
    const select = this.el.querySelector("[data-managed-account]");
    if (select && (value.actions || []).includes("bind")) {
      select.replaceChildren();
      for (const account of value.accounts || []) {
        const option = document.createElement("option");
        option.value = account.id;
        option.textContent = account.name || account.email || account.id;
        option.dataset.version = account.version;
        select.append(option);
      }
      if (value.binding) select.value = value.binding.account_id;
    }
    const summary = this.el.querySelector("[data-managed-account-summary]");
    if (summary && value.account) {
      const connection = value.account.connection;
      summary.textContent = [value.account.name || value.account.email, connection?.endpoint, connection?.protocol].filter(Boolean).join(" · ");
    }
    const retry = this.el.querySelector('[data-managed-action="retry"]');
    if (retry) retry.hidden = !(value.actions || []).includes("retry");
    const unbind = this.el.querySelector('[data-managed-action="unbind"]');
    if (unbind) unbind.disabled = value.can_configure === false || !(value.actions || []).includes("unbind");
    this.show(managedIssueText[value.issue] || (value.accounts_unavailable ? "组织账号列表暂时不可用。绑定状态已读取；请重新检查以加载账号列表。" : ""));
    this.renderSource();
    const delay = managedAuthPollDelay(value.state, this.polls);
    if (delay !== null && !document.hidden) {
      this.pollTimer = setTimeout(() => {
        if (this.alive && !this.operation) { this.polls += 1; this.run("refresh"); }
      }, delay);
    }
  },
  async run(action) {
    this.operation = new AbortController();
    let mutated = false;
    try {
      if (action === "refresh") {
        this.snapshot = await this.request("GET");
      } else if (action === "bind") {
        const selected = this.el.querySelector("[data-managed-account]")?.selectedOptions[0];
        if (!selected || !selected.value) throw new Error("account_required");
        mutated = true;
        this.snapshot = await this.request("PUT", { account_id: selected.value, expected_account_version: selected.dataset.version, expected_binding: this.snapshot.binding ?? null });
      } else if (action === "retry") {
        mutated = true;
        this.snapshot = await this.request("PUT", { account_id: this.snapshot.binding.account_id, expected_account_version: this.snapshot.account.version, expected_binding: this.snapshot.binding });
      } else if (action === "unbind") {
        if (!window.confirm("解绑可能中断此运行环境的任务。Session 数据会保留。解绑不会在 Provider 端吊销 API key。")) return;
        mutated = true;
        this.snapshot = await this.request("DELETE", { expected_binding: this.snapshot.binding });
      } else if (action === "accounts-next") {
        const cursor = this.snapshot.accounts_next;
        if (!cursor) return;
        const page = await this.request("GET", null, `${this.endpoint}?account_cursor=${encodeURIComponent(cursor)}`);
        this.snapshot = { ...page, accounts: [...(this.snapshot.accounts || []), ...(page.accounts || [])] };
      }
      this.polls = 0;
      this.render();
    } catch (error) {
      if (mutated && this.alive) {
        try {
          this.operation = new AbortController();
          this.snapshot = await this.request("GET");
          this.render();
          this.show("操作结果不确定。已重新读取当前状态。");
          return;
        } catch {}
      }
      this.show(error.message === "forbidden" ? "需要组织管理员和项目写权限。" : "无法确认此运行环境是否已绑定组织账号，暂不能修改自行登录。请重新检查。");
    } finally {
      this.operation = null;
    }
  },
};

// Byte-for-byte counterpart of runtimeAuthInputContext.aad; shared Go fixture
// covers UTF-8 and decimal numeric fields. No JSON canonicalization is involved.
export function runtimeAuthAAD(context) {
  const chunks = [domain, ...fields.map((field) => {
    const value = context[field];
    if (typeof value !== "string" && !Number.isSafeInteger(value)) throw invalid();
    return String(value);
  })].map((value) => encoder.encode(value));
  const size = chunks.reduce((total, value) => total + 4 + value.length, 0);
  if (size > 8192) throw invalid();
  const result = new Uint8Array(size);
  const view = new DataView(result.buffer);
  let offset = 0;
  for (const chunk of chunks) {
    view.setUint32(offset, chunk.length);
    result.set(chunk, offset + 4);
    offset += chunk.length + 4;
  }
  return result;
}

const decode = (value) => Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
const encode = (value) => {
  let text = "";
  for (const byte of new Uint8Array(value)) text += String.fromCharCode(byte);
  return btoa(text);
};

export async function sealRuntimeAuth(offer, plaintext) {
  if (!(plaintext instanceof Uint8Array) || plaintext.length === 0 || plaintext.length > maximumPlaintext ||
      offer.context.schema_version !== 1 || offer.context.sequence !== 1 || offer.context.expires_at <= Date.now()) throw invalid();
  const suite = new CipherSuite({ kem: new DhkemP256HkdfSha256(), kdf: new HkdfSha256(), aead: new Aes128Gcm() });
  const recipientPublicKey = await suite.kem.deserializePublicKey(decode(offer.public_key));
  const sender = await suite.createSenderContext({ recipientPublicKey, info: encoder.encode(domain) });
  const ciphertext = await sender.seal(plaintext, runtimeAuthAAD(offer.context));
  return JSON.stringify({ enc: encode(sender.enc), ciphertext: encode(ciphertext) });
}

// Browser checks provide actionable format feedback. The native owner still
// performs authoritative schema validation and rejects duplicate JSON members.
export function runtimeAuthMaterial(form, backend, text) {
  if (typeof text !== "string" || encoder.encode(text).length > maximumPlaintext) throw invalid();
  if (form === "api_key") {
    if (!token(text) || text.startsWith("!") || text.startsWith("$")) throw invalid();
    const bytes = encoder.encode(JSON.stringify({ key: text }));
    if (bytes.length > maximumPlaintext) throw invalid();
    return bytes;
  }
  if (form === "authorization_code") {
    if (!token(text) || text.length > 4096) throw invalid();
    return encoder.encode(text);
  }
  let value;
  try { value = JSON.parse(text); } catch { throw invalid(); }
  const depth = (node, level = 1) => {
    if (level > 16) throw invalid();
    if (node && typeof node === "object") for (const child of Object.values(node)) depth(child, level + 1);
  };
  depth(value);
  if (!object(value)) throw invalid();
  if (form === "pi_auth_entry" && backend === "openrouter") {
    if (!Object.hasOwn(value, "type")) value = value[backend];
    if (!only(value, ["type", "key"]) || value.type !== "api_key" || !token(value.key) || /^[!$]/.test(value.key)) throw invalid();
    return encoder.encode(JSON.stringify(value));
  }
  if (form === "codex_auth_file") {
    if (!only(value, ["auth_mode", "OPENAI_API_KEY", "tokens", "last_refresh"])) throw invalid();
    if (backend === "openai") {
      if (!only(value, ["auth_mode", "OPENAI_API_KEY"]) || value.auth_mode !== "apikey" || !token(value.OPENAI_API_KEY)) throw invalid();
    } else if (backend === "chatgpt") {
      if (![undefined, "chatgpt"].includes(value.auth_mode) || ![undefined, null].includes(value.OPENAI_API_KEY) ||
          !only(value.tokens, ["id_token", "access_token", "refresh_token", "account_id"]) ||
          !["id_token", "access_token", "refresh_token", "account_id"].every((key) => token(value.tokens[key])) ||
          typeof value.last_refresh !== "string" || !Number.isFinite(Date.parse(value.last_refresh))) throw invalid();
    } else throw invalid();
    return encoder.encode(text);
  }
  if (form === "claude_backend_config") {
    if (!only(value, ["env"]) || !object(value.env)) throw invalid();
    if (backend === "anthropic") {
      if (!(only(value.env, ["ANTHROPIC_API_KEY"]) && token(value.env.ANTHROPIC_API_KEY)) &&
          !(only(value.env, ["CLAUDE_CODE_OAUTH_TOKEN"]) && token(value.env.CLAUDE_CODE_OAUTH_TOKEN))) throw invalid();
    } else if (backend === "openrouter") {
      if (!only(value.env, ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"]) ||
          value.env.ANTHROPIC_BASE_URL !== "https://openrouter.ai/api" || !token(value.env.ANTHROPIC_AUTH_TOKEN) || value.env.ANTHROPIC_API_KEY !== "") throw invalid();
    } else throw invalid();
    return encoder.encode(text);
  }
  if (form === "claude_credentials_file" && backend === "anthropic") {
    if (!only(value, ["claudeAiOauth"]) || !object(value.claudeAiOauth)) throw invalid();
    const auth = value.claudeAiOauth;
    if (!only(auth, ["accessToken", "refreshToken", "expiresAt", "refreshTokenExpiresAt", "scopes", "clientId", "subscriptionType", "rateLimitTier"]) ||
        !token(auth.accessToken) || !token(auth.refreshToken) || !Number.isSafeInteger(auth.expiresAt) || auth.expiresAt <= 0 ||
        (auth.refreshTokenExpiresAt !== undefined && (!Number.isSafeInteger(auth.refreshTokenExpiresAt) || auth.refreshTokenExpiresAt <= 0)) ||
        !Array.isArray(auth.scopes) || auth.scopes.length === 0 || auth.scopes.length > 16) throw invalid();
    const scopes = new Set();
    let inference = false;
    for (const scope of auth.scopes) {
      if (!token(scope) || scope.length > 128 || !scope.startsWith("user:") || scopes.has(scope)) throw invalid();
      scopes.add(scope);
      inference ||= scope === "user:inference" || scope === "user:ccr_inference";
    }
    if (!inference || (auth.clientId !== undefined && !token(auth.clientId)) ||
        (auth.subscriptionType !== undefined && auth.subscriptionType !== null && !["max", "pro", "team", "enterprise"].includes(auth.subscriptionType)) ||
        (auth.rateLimitTier !== undefined && auth.rateLimitTier !== null && (typeof auth.rateLimitTier !== "string" || !/^[a-z][a-z0-9_]{0,63}$/.test(auth.rateLimitTier)))) throw invalid();
    return encoder.encode(text);
  }
  throw invalid();
}

const messages = {
  invalid_format: "材料格式不受支持，请检查后重新选择。",
  runtime_busy: "目标正在执行任务，当前操作不会中断任务。请稍后重新检查。",
  target_changed: "目标已变化，请关闭并重新查看。",
  runtime_auth_target_changed: "目标已变化，请关闭并重新查看。",
  canceled: "操作已取消。",
  credentials_rejected: "鉴权未通过，请替换凭证。",
  credentials_missing: "目标尚未保存凭证。",
  permission_denied: "当前凭证没有访问权限。",
  quota_exhausted: "Provider 额度不足。",
  rate_limited: "Provider 暂时限流。",
  verification_model_unavailable: "验证模型不可用。",
  verification_timeout: "验证超时，凭证未删除。",
  provider_unavailable: "Provider 暂时不可达，凭证未删除。",
  completion_unknown: "配置结果已确定，但通知请求方的结果未知。请不要重复提交鉴权操作。",
};

// One visible panel owns one in-memory ceremony. Fetch carries only identity,
// bounded ciphertext, or finite actions; secret controls are never serialized
// by LiveView. No automatic mutation retries or persistent browser storage.
export const RuntimeAuth = {
  mounted() {
    this.alive = true;
    this.operation = null;
    this.offer = null;
    this.status = null;
    this.target = JSON.parse(this.el.dataset.target);
    this.targetText = this.el.dataset.target;
    this.endpoint = this.el.dataset.endpoint;
    this.requestId = this.el.dataset.requestId || null;
    this.completionSent = false;
    this.polls = 0;
    this.pollAttemptId = null;
    this.pollTimer = null;
    this.onAction = (event) => {
      const action = event.target.closest("[data-auth-action]")?.dataset.authAction;
      if (!action || !this.el.contains(event.target)) return;
      event.preventDefault();
      if (this.operation && action === "cancel") { this.operation.abort(); this.operation = null; }
      if (!this.operation) this.run(action);
    };
    this.onSelection = () => { this.clearMaterial(); this.renderMethod(); };
    this.onPageHide = () => this.dispose();
    this.el.addEventListener("click", this.onAction);
    this.el.querySelector("[data-auth-method]")?.addEventListener("change", this.onSelection);
    window.addEventListener("pagehide", this.onPageHide);
    this.run("refresh");
  },
  updated() {
    if (this.targetText !== this.el.dataset.target) {
      this.dispose();
      this.show("目标已变化，请关闭并重新查看。");
    }
  },
  destroyed() { this.dispose(); },
  dispose() {
    this.alive = false;
    this.operation?.abort();
    this.operation = null;
    clearTimeout(this.expiry);
    clearTimeout(this.pollTimer);
    this.offer = null;
    this.clearMaterial();
    const code = this.el.querySelector("[data-auth-user-code]");
    if (code) code.textContent = "";
    this.el.querySelector("[data-auth-login-url]")?.removeAttribute("href");
    this.el.removeEventListener("click", this.onAction);
    this.el.querySelector("[data-auth-method]")?.removeEventListener("change", this.onSelection);
    window.removeEventListener("pagehide", this.onPageHide);
  },
  clearMaterial() {
    for (const input of this.el.querySelectorAll("[data-auth-secret],[data-auth-file],[data-auth-callback-code]")) input.value = "";
  },
  show(message) {
    const output = this.el.querySelector("[data-auth-feedback]");
    if (output) output.textContent = message;
  },
  async request(action, input = {}) {
    const operation = this.operation;
    if (!this.alive || !operation || operation.signal.aborted) throw new Error("target_changed");
    const response = await fetch(this.endpoint, {
      method: "POST", credentials: "same-origin", cache: "no-store", redirect: "error",
      headers: { "content-type": "application/json", "accept": "application/json", "x-csrf-token": document.querySelector("meta[name='csrf-token']")?.content ?? "" },
      body: JSON.stringify({ action, target: this.target, ...input }), signal: operation.signal,
    });
    const body = await response.json();
    if (!this.alive || this.operation !== operation || operation.signal.aborted) throw new Error("target_changed");
    if (!response.ok || !body.ok) throw new Error(messages[body.error?.code] ? body.error.code : "request_failed");
    return body.data.runtime_auth;
  },
  async reportCompletion(outcome) {
    if (!this.requestId || this.completionSent) return;
    this.completionSent = true;
    const requestId = this.requestId;
    this.requestId = null;
    const response = await fetch(`${this.endpoint}/requests/${encodeURIComponent(requestId)}/complete`, {
      method: "POST", credentials: "same-origin", cache: "no-store", redirect: "error",
      headers: { "content-type": "application/json", "accept": "application/json", "x-csrf-token": document.querySelector("meta[name='csrf-token']")?.content ?? "" },
      body: JSON.stringify({ outcome }),
    });
    if (!response.ok) throw new Error("completion_unknown");
  },
  renderStatus() {
    const status = this.status;
    clearTimeout(this.pollTimer);
    this.pollTimer = null;
    const activeAttempt = status.attempt && ["awaiting_user", "receiving", "applying", "verifying"].includes(status.attempt.phase);
    if (activeAttempt && this.pollAttemptId !== status.attempt.attempt_id) {
      this.pollAttemptId = status.attempt.attempt_id;
      this.polls = 0;
    } else if (!activeAttempt) {
      this.pollAttemptId = null;
      this.polls = 0;
    }
    const pollDelay = runtimeAuthPollDelay(status.attempt, this.polls);
    if (pollDelay !== null) {
      this.pollTimer = setTimeout(() => {
        if (this.alive && !this.operation) {
          this.polls += 1;
          this.run("refresh");
        }
      }, pollDelay);
    }
    const output = this.el.querySelector("[data-auth-status]");
    if (output) output.textContent = status.dispatch_ready ? "已验证可用" : ({ configured: "已保存待验证", pending: "等待完成登录", unauthenticated: "未登录", authenticated: "已鉴权，运行环境尚未就绪" })[status.auth.status] ?? "当前未知";
    const login = this.el.querySelector('[data-auth-action="login"]');
    if (login) login.disabled = !status.methods.some((method) => method.method === "native_login");
    const ceremony = status.attempt?.owned ? status.attempt.ceremony : null;
    const section = this.el.querySelector("[data-auth-ceremony]");
    if (section) {
      let claude = false;
      try { const url = new URL(ceremony?.verification_url); claude = url.protocol === "https:" && url.host === "claude.com" && url.pathname === "/cai/oauth/authorize"; } catch {}
      const valid = (ceremony?.verification_url === "https://auth.openai.com/codex/device" && typeof ceremony.user_code === "string") || (claude && ceremony?.user_code === "" && object(ceremony.input));
      section.hidden = !valid;
      section.querySelector("[data-auth-user-code]").textContent = valid ? ceremony.user_code : "";
      const deviceCode = section.querySelector("[data-auth-device-code]");
      const callbackLabel = section.querySelector("[data-auth-callback-label]");
      const completeLogin = section.querySelector('[data-auth-action="complete-login"]');
      const loginHelp = section.querySelector("[data-auth-login-help]");
      if (deviceCode) deviceCode.hidden = !valid || claude;
      if (callbackLabel) callbackLabel.hidden = !valid || !claude;
      if (completeLogin) completeLogin.hidden = !valid || !claude;
      if (loginHelp) loginHelp.hidden = valid && claude;
      if (valid && claude) this.offer = ceremony.input;
      const link = section.querySelector("[data-auth-login-url]");
      if (valid) link.href = ceremony.verification_url; else link.removeAttribute("href");
      clearTimeout(this.expiry);
      if (valid) this.expiry = setTimeout(() => {
        section.hidden = true;
        section.querySelector("[data-auth-user-code]").textContent = "";
        const callback = section.querySelector("[data-auth-callback-code]");
        if (callback) callback.value = "";
        link.removeAttribute("href");
        this.show("登录已到期，请重新检查。");
      }, Math.max(0, status.attempt.expires_at - Date.now()));
    }
    const select = this.el.querySelector("[data-auth-method]");
    const previous = select.value;
    select.replaceChildren();
    for (const method of status.methods.filter((method) => method.method === "credential_import")) {
      const option = document.createElement("option");
      option.value = JSON.stringify(method);
      option.textContent = `${method.backend} · ${method.form === "api_key" ? "填写 API key" : "导入鉴权文件"}`;
      select.append(option);
    }
    if ([...select.options].some((option) => option.value === previous)) select.value = previous;
    select.disabled = select.options.length === 0;
    this.el.querySelector('[data-auth-action="save"]').disabled = select.disabled;
    for (const field of this.el.querySelectorAll("[data-auth-secret],[data-auth-file]")) field.disabled = select.disabled;
    this.el.querySelector('[data-auth-action="verify"]').disabled = !status.methods.some((method) => method.method === "verify");
    this.el.querySelector('[data-auth-action="cancel"]').disabled =
      !status.attempt || !["awaiting_user", "receiving", "applying", "verifying"].includes(status.attempt.phase);
    const finishSaved = this.el.querySelector('[data-auth-action="finish-saved"]');
    if (finishSaved) finishSaved.hidden = !(this.requestId && status.auth.status === "configured");
    this.renderMethod();
    if (status.attempt && !status.attempt.owned) this.show("另一位管理员正在处理。可以刷新状态，或取消后重新开始。");
  },
  renderMethod() {
    const selection = this.el.querySelector("[data-auth-method]").value;
    const method = selection ? JSON.parse(selection) : null;
    for (const [selector, visible] of [["[data-auth-secret]", method?.form === "api_key"], ["[data-auth-file]", method && method.form !== "api_key"]]) {
      const field = this.el.querySelector(selector);
      if (field?.closest("label")) field.closest("label").hidden = !visible;
    }
    const checkbox = this.el.querySelector("[data-auth-save-verify]");
    if (checkbox) {
      const supported = method && this.status.methods.some((item) => item.method === "verify" && item.backend === method.backend);
      checkbox.disabled = !supported;
      if (!supported) checkbox.checked = false;
    }
  },
  async material(method) {
    if (method.form === "api_key") return runtimeAuthMaterial(method.form, method.backend, this.el.querySelector("[data-auth-secret]").value);
    const file = this.el.querySelector("[data-auth-file]").files[0];
    if (!file || file.size > maximumPlaintext) throw invalid();
    let text;
    try { text = new TextDecoder("utf-8", { fatal: true }).decode(await file.arrayBuffer()); } catch { throw invalid(); }
    return runtimeAuthMaterial(method.form, method.backend, text);
  },
  async run(action) {
    const operation = new AbortController();
    this.operation = operation;
    this.el.querySelector('[data-auth-action="cancel"]').disabled = false;
    let plaintext;
    let submitted = false;
    let saveReceipt = null;
    this.show( action === "save" ? "正在保存到运行环境…" : "正在读取运行环境…");
    try {
      if (action === "refresh") {
        this.status = await this.request("status");
        this.show("");
        if (this.status.auth.status === "authenticated") await this.reportCompletion("authenticated");
      } else if (action === "login") {
        const method = this.status.methods.find((item) => item.method === "native_login");
        if (!method) throw invalid();
        const started = await this.request("login_start", {backend: method.backend, flow: method.form});
        if (started.context) this.offer = started;
        this.status = await this.request("status");
        if (this.status.auth.status === "authenticated") await this.reportCompletion("authenticated");
        this.show(method.form === "authorization_code" ? "请打开 Provider 登录页，完成后粘贴返回的授权码。" : "请在 Provider 页面输入设备码。完成后重新检查状态。");
      } else if (action === "complete-login") {
        if (!this.offer?.context || this.offer.context.method !== "native_login") throw invalid();
        plaintext = runtimeAuthMaterial("authorization_code", "anthropic", this.el.querySelector("[data-auth-callback-code]").value);
        const envelope = await sealRuntimeAuth(this.offer, plaintext);
        plaintext.fill(0);
        plaintext = null;
        this.clearMaterial();
        submitted = true;
        const result = await this.request("input_submit", { attempt_id: this.offer.context.attempt_id, envelope });
        saveReceipt = result;
        this.offer = null;
        this.show(result.save_result === "committed" ? (result.issue ? "登录凭据已保存，尚未生效。" : "原生登录已保存，正在检查。") : messages[result.issue] ?? "原生登录未完成。");
        this.status = await this.request("status");
        if (this.status.auth.status === "authenticated") await this.reportCompletion("authenticated");
      } else if (action === "save") {
        const method = JSON.parse(this.el.querySelector("[data-auth-method]").value);
        plaintext = await this.material(method);
        this.offer = await this.request("input_begin", { backend: method.backend, form: method.form });
        const context = this.offer.context;
        if (context.backend !== method.backend || context.form !== method.form || context.target_kind !== this.target.kind ||
            (this.target.kind === "compute_workload" && context.workload_id !== this.target.workload_id) ||
            (this.target.kind === "connected_runtime" && (context.device_id !== this.target.device_id || context.runtime_id !== this.target.runtime_id))) throw new Error("target_changed");
        clearTimeout(this.expiry);
        this.expiry = setTimeout(() => { this.clearMaterial(); this.offer = null; }, Math.max(0, context.expires_at - Date.now()));
        const envelope = await sealRuntimeAuth(this.offer, plaintext);
        plaintext.fill(0);
        plaintext = null;
        this.clearMaterial();
        if (!this.alive || operation.signal.aborted) return;
        submitted = true;
        const result = await this.request("input_submit", { attempt_id: context.attempt_id, envelope });
        saveReceipt = result;
        this.offer = null;
        clearTimeout(this.expiry);
        this.show(result.save_result === "committed" ? (result.issue ? "配置已保存，尚未生效。" : "已保存，尚未验证。") : result.save_result === "unknown" ? "保存结果未知，目标可能已保存。请查询状态；重新提交前须重新选择材料。" : messages[result.issue] ?? "未保存，请重新检查运行环境。");
        if (result.save_result === "committed" && !result.issue && this.el.querySelector("[data-auth-save-verify]")?.checked) {
          const verification = await this.request("verify", { backend: method.backend });
          this.show(verification.status === "authenticated" ? "已保存并验证可用。" : `已保存。${messages[verification.issue] ?? "验证未完成，凭证未删除。"}`);
        }
        this.status = await this.request("status");
        if (this.status.auth.status === "authenticated") await this.reportCompletion("authenticated");
      } else if (action === "verify") {
        const method = this.status.methods.find((method) => method.method === "verify");
        if (!method) throw invalid();
        this.show("正在验证，最多等待 30 秒…");
        const result = await this.request("verify", { backend: method.backend });
        this.show(result.status === "authenticated" ? "已验证可用。" : messages[result.issue] ?? "验证未完成，凭证未删除。");
        this.status = await this.request("status");
        if (this.status.auth.status === "authenticated") await this.reportCompletion("authenticated");
      } else if (action === "cancel") {
        this.status = await this.request("status");
        const attempt = this.status.attempt;
        if (!attempt) return;
        const result = await this.request("input_cancel", { attempt_id: attempt.attempt_id });
        this.clearMaterial();
        this.offer = null;
        this.show(result.save_result === "committed" ? "配置已经保存，取消不能撤回。" : "操作已取消。");
        this.status = await this.request("status");
        if (result.save_result !== "committed") await this.reportCompletion("canceled");
      } else if (action === "finish-saved") {
        await this.reportCompletion("saved_unverified");
        this.show("已通知请求方：配置已保存但尚未验证。");
      }
      if (this.alive && this.operation === operation) this.renderStatus();
    } catch (error) {
      this.clearMaterial();
      this.offer = null;
      if (this.alive && this.operation === operation) this.show(saveReceipt?.save_result === "committed" ? "配置已保存，当前验证或状态读取未完成。请重新检查。" : submitted ? "保存结果未知，目标可能已保存。请查询状态；重新提交前须重新选择材料。" : messages[error.message] ?? "无法完成操作，请检查权限和运行环境后重新查询。");
    } finally {
      plaintext?.fill(0);
      if (this.operation === operation) this.operation = null;
    }
  },
};
