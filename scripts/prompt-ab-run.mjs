#!/usr/bin/env node
/**
 * Portable zero-dependency Node.js L2 multi-turn tool-loop A/B executor.
 * Runs a production-rendered bundle exported by `systems/scripts/prompt_ab_eval.exs --mode export`
 * against any OpenAI-compatible `/chat/completions` endpoint (e.g. L4ES gateway, OpenRouter, etc.).
 *
 * Usage:
 *   node scripts/prompt-ab-run.mjs \
 *     --bundle base/l2_bundle.json --arm base \
 *     --base-url http://10.77.0.1:8180/v1 --model deepseek-flash \
 *     --runs 3 [--concurrency 4] [--max-tokens 4096] [--api-key-env VAR] --out base/l2.jsonl
 */

import fs from "node:fs";
import path from "node:path";

const MAX_ROUNDS = 12;

function parseArgs(argv) {
  const opts = { runs: 1, concurrency: 3, "max-tokens": 4096, "timeout-ms": 120000 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--") && i + 1 < argv.length) {
      const k = a.slice(2);
      const v = argv[++i];
      opts[k] = ["runs", "concurrency", "max-tokens", "timeout-ms"].includes(k) ? Number(v) : v;
    } else {
      throw new Error(`Unexpected arg: ${a}`);
    }
  }
  if (!opts.bundle || !opts["base-url"] || !opts.model) {
    throw new Error("Required: --bundle, --base-url, --model");
  }
  return opts;
}

function extractMessageText(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((b) => (b && typeof b.text === "string" ? b.text : ""))
      .filter(Boolean)
      .join("\n");
  }
  return "";
}

function validTriageDecision(decision) {
  if (!decision || typeof decision !== "object" || Array.isArray(decision)) return false;
  const kind = decision.kind;
  const refs = decision.source_refs;
  if (!Array.isArray(refs) || refs.length === 0) return false;
  if (kind === "reply") {
    return typeof decision.text === "string" && decision.text.trim().length > 0 && !("reason" in decision) && !("reason_code" in decision);
  }
  if (kind === "reaction") {
    return typeof decision.emoji === "string" && decision.emoji.trim().length > 0 && refs.length === 1;
  }
  if (kind === "silence") {
    return (
      ["already_handled", "no_useful_addition", "insufficient_evidence"].includes(decision.reason_code) &&
      typeof decision.reason === "string" &&
      decision.reason.trim().length > 0
    );
  }
  return false;
}

function compileRegex(pat) {
  let flags = "";
  let body = pat;
  const m = body.match(/^\(\?([imsx]+)\)/);
  if (m) {
    for (const ch of m[1]) {
      if ("ims".includes(ch)) flags += ch;
    }
    body = body.slice(m[0].length);
  }
  return new RegExp(body, flags);
}

function evaluateChecks(spec, state) {
  const combinedOutput =
    Array.isArray(spec.triage_allowed_kinds) && typeof state.triageDecision?.text === "string"
      ? state.triageDecision.text
      : state.visibleOutputs.join("\n\n");
  const checks = [];

  for (const tool of spec.required_tools || []) {
    checks.push({ check: `required_tool:${tool}`, pass: state.toolCalls.includes(tool) });
  }
  if (Array.isArray(spec.any_of_tools) && spec.any_of_tools.length > 0) {
    checks.push({
      check: `any_of_tools:${spec.any_of_tools.join("|")}`,
      pass: spec.any_of_tools.some((t) => state.toolCalls.includes(t)),
    });
  }
  for (const tool of spec.forbidden_tools || []) {
    checks.push({ check: `forbidden_tool:${tool}`, pass: !state.toolCalls.includes(tool) });
  }
  for (const rule of spec.required_tool_arg_patterns || []) {
    const re = compileRegex(rule.pattern);
    const ok = state.toolCallDetails.some(
      (d) => d.tool === rule.tool && re.test(JSON.stringify(d.params || {}))
    );
    checks.push({ check: `tool_arg:${rule.tool}:${rule.pattern}`, pass: ok });
  }
  for (const pat of spec.required_output_patterns || []) {
    const re = compileRegex(pat);
    checks.push({ check: `output_match:${pat}`, pass: re.test(combinedOutput) });
  }
  for (const pat of spec.forbidden_output_patterns || []) {
    const re = compileRegex(pat);
    checks.push({ check: `output_forbid:${pat}`, pass: !re.test(combinedOutput) });
  }
  if (Array.isArray(spec.triage_allowed_kinds) && spec.triage_allowed_kinds.length > 0) {
    const kind = state.triageDecision?.kind;
    checks.push({
      check: `triage_kind:${spec.triage_allowed_kinds.join("|")}`,
      pass: spec.triage_allowed_kinds.includes(kind),
    });
  }
  if (Array.isArray(spec.triage_allowed_reason_codes) && spec.triage_allowed_reason_codes.length > 0) {
    const code = state.triageDecision?.reason_code;
    checks.push({
      check: `triage_reason:${spec.triage_allowed_reason_codes.join("|")}`,
      pass: spec.triage_allowed_reason_codes.includes(code),
    });
  }
  if (spec.triage_forbid_follow_up === true) {
    const followUps = (state.triageDecision?.context_candidates || []).filter((c) => c.kind === "follow_up");
    checks.push({ check: "triage_no_follow_up", pass: followUps.length === 0 });
  }
  if (typeof spec.max_tool_calls === "number") {
    checks.push({
      check: `max_tool_calls<=${spec.max_tool_calls}`,
      pass: state.toolCalls.length <= spec.max_tool_calls,
    });
  }

  return checks;
}

function resolveStubResponse(stub, params) {
  if (stub && typeof stub === "object" && Array.isArray(stub.match_rules)) {
    const serialized = JSON.stringify(params || {});
    for (const rule of stub.match_rules) {
      if (rule && typeof rule.pattern === "string" && compileRegex(rule.pattern).test(serialized)) {
        return rule.response;
      }
    }
    if (Object.prototype.hasOwnProperty.call(stub, "default")) {
      return stub.default;
    }
  }
  return stub;
}

function dispatchInner(kase, tool, params, state) {
  state.toolCalls.push(tool);
  state.toolCallDetails.push({ tool, params });

  if (tool === "help") {
    state.helpCalls++;
    const target = String(params?.tool || "");
    if (kase.help_index && kase.help_index[target]) return kase.help_index[target];
    if (kase.namespace_index && kase.namespace_index[target]) return kase.namespace_index[target];
    return { error: `unknown tool: ${target}` };
  }

  if (tool === "im.connects_list") {
    const provider = String(params?.provider || "").trim();
    const all = Array.isArray(kase.im_connects) ? kase.im_connects : [];
    const connects = provider ? all.filter((c) => c.provider === provider) : all;
    return { connects };
  }

  if (tool === "im.provider_apis_list") {
    const provider = String(params?.provider || "internal").trim();
    const apis = kase.provider_apis?.[provider] || [];
    return { provider, apis };
  }

  if (tool === "im_api.internal.send_message") {
    const text = extractMessageText(params?.content);
    if (text) state.visibleOutputs.push(text);
    return { ok: true, message_id: `msg_${state.toolCalls.length}` };
  }

  if (tool === "im_api.internal.triage.complete") {
    const cleaned = { ...(params || {}) };
    delete cleaned.connect_id;
    const keys = Object.keys(cleaned).sort();
    const expectedSnap = kase.tool_stubs?.["im_api.internal.triage.read_source"]?.source_snapshot;
    if (keys.join(",") !== "decision,source_snapshot") {
      return { error: "invalid_triage_completion: expected exact keys source_snapshot and decision" };
    }
    if (expectedSnap && cleaned.source_snapshot !== expectedSnap) {
      return { error: "invalid_triage_source_snapshot" };
    }
    if (!validTriageDecision(cleaned.decision)) {
      return { error: "invalid_triage_completion: decision failed validation" };
    }
    state.triageDecision = cleaned.decision;
    if (cleaned.decision.kind === "reply" && cleaned.decision.text) {
      state.visibleOutputs.push(cleaned.decision.text);
    }
    return { accepted: true, delivery_status: "pending" };
  }

  if (kase.tool_stubs && Object.prototype.hasOwnProperty.call(kase.tool_stubs, tool)) {
    return resolveStubResponse(kase.tool_stubs[tool], params);
  }
  if (tool === "im_api.internal.triage.read_context") return { entries: [] };
  if (tool === "im_api.internal.triage.read_memory") return { exists: false, content: "" };
  if (["im_api.slack.get_channel_history", "im_api.slack.get_thread_replies", "im_api.slack.search", "im_api.slack.message_search"].includes(tool)) {
    return { messages: [], has_more: false };
  }
  if (tool === "im_api.internal.station_task.list") return { tasks: [], has_more: false };
  if (tool === "im_api.slack.get_user_info") {
    const uid = String(params?.user || params?.user_id || "U_UNKNOWN");
    return { user: { id: uid, name: uid.toLowerCase() } };
  }
  return { error: `unstubbed_tool: ${tool}` };
}

async function chatComplete(opts, messages, tools) {
  const url = `${opts["base-url"].replace(/\/+$/, "")}/chat/completions`;
  const headers = { "content-type": "application/json" };
  if (opts["api-key-env"] && process.env[opts["api-key-env"]]) {
    headers.authorization = `Bearer ${process.env[opts["api-key-env"]]}`;
  }

  const body = {
    model: opts.model,
    messages,
    tools,
    max_tokens: opts["max-tokens"],
    temperature: 0,
  };

  for (let attempt = 0; attempt < 3; attempt++) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), opts["timeout-ms"]);
    try {
      const res = await fetch(url, {
        method: "POST",
        headers,
        body: JSON.stringify(body),
        signal: controller.signal,
      });
      clearTimeout(timer);
      const text = await res.text();
      if (res.status >= 200 && res.status < 300) {
        return JSON.parse(text);
      }
      if ((res.status === 429 || res.status >= 500) && attempt < 2) {
        await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
        continue;
      }
      throw new Error(`HTTP ${res.status}: ${text.slice(0, 300)}`);
    } catch (err) {
      clearTimeout(timer);
      if (attempt < 2) {
        await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
        continue;
      }
      throw err;
    }
  }
}

async function runCase(opts, kase, runIdx, arm) {
  const started = Date.now();
  const messages = [
    { role: "system", content: kase.prompt },
    ...(kase.history_messages || []),
    ...(kase.user_messages || []).map((t) => ({ role: "user", content: t })),
  ];

  const state = {
    toolCalls: [],
    toolCallDetails: [],
    helpCalls: 0,
    visibleOutputs: [],
    assistantTexts: [],
    triageDecision: null,
    plainNudges: 0,
    rounds: 0,
    usage: { prompt_tokens: 0, cached_tokens: 0, completion_tokens: 0 },
    error: null,
  };

  function hasDeliveredOutput() {
    return (
      state.visibleOutputs.length > 0 ||
      Boolean(state.triageDecision) ||
      state.toolCalls.includes("im_api.internal.task.create")
    );
  }

  try {
    for (let round = 1; round <= MAX_ROUNDS; round++) {
      state.rounds = round;
      const resp = await chatComplete(opts, messages, kase.tools);
      const u = resp.usage || {};
      state.usage.prompt_tokens += u.prompt_tokens || u.input_tokens || 0;
      state.usage.cached_tokens += u.prompt_tokens_details?.cached_tokens || u.cache_read_input_tokens || 0;
      state.usage.completion_tokens += u.completion_tokens || u.output_tokens || 0;

      const msg = resp.choices?.[0]?.message || {};
      const toolCalls = Array.isArray(msg.tool_calls) ? msg.tool_calls : [];
      if (toolCalls.length === 0) {
        const text = typeof msg.content === "string" ? msg.content.trim() : "";
        if (text) state.assistantTexts.push(text);
        if (!hasDeliveredOutput() && state.plainNudges < 1 && round < MAX_ROUNDS) {
          state.plainNudges++;
          messages.push({ role: "assistant", content: msg.content || "" });
          messages.push({
            role: "user",
            content:
              "Runtime notice: plain assistant text is not visible to the user. Send your reply with im_api.internal.send_message (or end_turn with reply), or call end_turn with no_reply=true if silence is deliberate.",
          });
          continue;
        }
        break;
      }

      messages.push({ role: "assistant", content: msg.content || "", tool_calls: toolCalls });
      let ended = false;
      for (const tc of toolCalls) {
        const fnName = tc.function?.name || "";
        let args = {};
        try {
          args = typeof tc.function?.arguments === "string" ? JSON.parse(tc.function.arguments) : tc.function?.arguments || {};
        } catch {
          args = {};
        }

        let result;
        if (fnName === "end_turn") {
          if (args.reply && typeof args.reply.tool === "string" && args.reply.params && typeof args.reply.params === "object") {
            dispatchInner(kase, args.reply.tool, args.reply.params, state);
          }
          if (args.outcome === "done" && args.no_reply !== true && !hasDeliveredOutput()) {
            result = {
              error:
                "done_without_reply: send the answer via im_api.internal.send_message or end_turn.reply, create a Task, or set no_reply=true",
            };
          } else {
            result = { ok: true, ended: true, outcome: args.outcome };
            ended = true;
          }
        } else if (fnName === "wait_for") {
          result = { ok: true, waiting: true, reason: args.reason };
          ended = true;
        } else if (fnName === "call") {
          result = dispatchInner(kase, String(args.tool || ""), args.params || {}, state);
        } else {
          result = { error: `unsupported_outer_tool: ${fnName}` };
        }

        messages.push({
          role: "tool",
          tool_call_id: tc.id || `tc_${round}`,
          content: JSON.stringify(result),
        });
      }
      if (ended) break;
      if (round === MAX_ROUNDS) state.error = "max_rounds_exceeded";
    }
  } catch (err) {
    state.error = err.message;
  }

  const checks = evaluateChecks(kase.checks || {}, state);
  const pass = !state.error && checks.every((c) => c.pass);

  return {
    layer: "l2",
    arm,
    model: opts.model,
    case: kase.name,
    category: kase.category,
    hard_guardrail: Boolean(kase.hard_guardrail),
    run: runIdx,
    pass,
    error: state.error,
    prompt_chars: kase.prompt_chars,
    prompt_sha256: kase.prompt_sha256,
    rounds: state.rounds,
    help_calls: state.helpCalls,
    tool_calls: state.toolCalls,
    tool_call_details: state.toolCallDetails,
    visible_outputs: state.visibleOutputs,
    triage_decision: state.triageDecision,
    usage: state.usage,
    latency_ms: Date.now() - started,
    checks,
  };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const bundle = JSON.parse(fs.readFileSync(opts.bundle, "utf8"));
  const arm = opts.arm || bundle.arm || "cand";
  let cases = bundle.cases || [];
  if (opts.cases) {
    const wanted = new Set(opts.cases.split(",").map((s) => s.trim()).filter(Boolean));
    cases = cases.filter((c) => wanted.has(c.name));
  }

  const jobs = [];
  for (const kase of cases) {
    for (let r = 1; r <= opts.runs; r++) {
      jobs.push({ kase, r });
    }
  }

  const results = new Array(jobs.length);
  let cursor = 0;
  async function worker() {
    while (true) {
      const idx = cursor++;
      if (idx >= jobs.length) break;
      const { kase, r } = jobs[idx];
      const row = await runCase(opts, kase, r, arm);
      results[idx] = row;
      const tag = row.pass ? "PASS" : "FAIL";
      process.stderr.write(`[${arm}] ${tag} ${kase.name}#${r} (rounds=${row.rounds} tools=${row.tool_calls.length} tok=${row.usage.prompt_tokens})\n`);
    }
  }

  await Promise.all(Array.from({ length: Math.min(opts.concurrency, jobs.length) }, () => worker()));

  const body = results.map((r) => JSON.stringify(r)).join("\n") + "\n";
  if (opts.out) {
    fs.mkdirSync(path.dirname(opts.out), { recursive: true });
    fs.writeFileSync(opts.out, body, "utf8");
  } else {
    process.stdout.write(body);
  }
  const passed = results.filter((r) => r.pass).length;
  process.stderr.write(`Summary [${arm} / ${opts.model}]: ${passed}/${results.length} passed\n`);
}

main().catch((err) => {
  process.stderr.write(`${err.stack || err.message}\n`);
  process.exit(1);
});
