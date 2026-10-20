// A fake `claude -p --input-format stream-json --output-format stream-json`: frames as the real CLI writes them
// (system/init, status, stream_event partial messages, assistant/user messages, result), driven by what the prompt says:
//   say:<text>    a reply                       fail:auth|rate|model   a result with is_error
//   slow:<n>      n deltas, 50 ms apart          retry401               two api_retry 401 frames, then waits until interrupted
//   hold:<k>      k deltas, then waits until steered (the steers its deltas) or interrupted
//   gate:<n>:<k>:<name>   k of n deltas; the rest once FAKE_DUMP.<name>.a (a fifo) is written, then FAKE_DUMP.<name>.said
//                 made; the end once FAKE_DUMP.<name>.b is (what the test lets happen when, not a time)
//   tool          a Bash call that waits until background_tasks (or interrupt)
//   again         a reply, then a turn of its own (no prompt of ours)
//   exit          says why on stderr and exits 3 in the middle of the turn
//   …post:<text>  (anywhere in a message the station hands it) calls chat_post through the MCP endpoint of --mcp-config
//                 with its token, to the message's thread, ending the turn all_done; then a reply with what it answered
//                 (`slow:<n> post:<text>`: n deltas, 50 ms apart, before it)
// Input while busy is read into the turn (a delta "steer:<text>"); "queue:<text>" becomes a turn after it.
// FAKE_DUMP: its argv and env are appended there as a JSON line, and every line of stdin to FAKE_DUMP.stdin.
import fs from "node:fs";
import readline from "node:readline";

const dump = process.env.FAKE_DUMP;
if (dump) fs.appendFileSync(dump, JSON.stringify({ argv: process.argv.slice(2), env: process.env, pid: process.pid }) + "\n");
const args = process.argv.slice(2);
const flag = (name) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
const sessionId = flag("--session-id") || flag("--resume") || "none";

const say = (frame) => fs.writeSync(1, JSON.stringify(frame) + "\n");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
/// A wait that a control request (interrupt, background_tasks) or a steer ends; nothing else does.
let wake = () => {};
const pause = () => new Promise((r) => (wake = r));
/// Waits until the fifo at `path` is written (and closed). Windows has no fifos: there the test writes a file at
/// `path`, which its directory's watch tells of.
const gate = async (path) => {
  if (process.platform === "win32") await appears(path);
  return fs.promises.readFile(path);
};
const appears = (path) =>
  new Promise((resolve) => {
    const watcher = fs.watch(path.slice(0, Math.max(path.lastIndexOf("\\"), path.lastIndexOf("/"))), () => look());
    const look = () => fs.existsSync(path) && (watcher.close(), resolve());
    look();
  });

let busy = false;
let interrupted = false;
let backgrounded = false;
let steers = [];
const queued = [];
let n = 0;

function stream(event) {
  say({ type: "stream_event", event, parent_tool_use_id: null, session_id: sessionId, uuid: `u${++n}` });
}

/// A reply of `texts`, `gap` ms apart; `before(i)`, if given, waited for before the i-th (and before its end, at i =
/// texts.length).
async function message(texts, gap, before) {
  const id = `msg_${++n}`;
  stream({ type: "message_start", message: { id, role: "assistant", content: [] } });
  stream({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } });
  let all = "";
  const steered = () => {
    for (const s of steers.splice(0)) {
      stream({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: `steer:${s}` } });
      all += `steer:${s}`;
    }
  };
  for (const [i, t] of texts.entries()) {
    if (before) await before(i);
    if (interrupted) break;
    stream({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: t } });
    all += t;
    steered();
    if (gap) await sleep(gap);
  }
  if (before && !interrupted) {
    await before(texts.length);
    steered();
  }
  stream({ type: "content_block_stop", index: 0 });
  stream({ type: "message_stop" });
  say({ type: "assistant", message: { id, role: "assistant", content: [{ type: "text", text: all }] }, session_id: sessionId });
  return all;
}

function result(fields) {
  say({ type: "result", subtype: "success", is_error: false, duration_ms: 1, num_turns: 1, session_id: sessionId, ...fields });
}

async function turn(text) {
  busy = true;
  interrupted = false;
  backgrounded = false;
  say({ type: "system", subtype: "init", session_id: sessionId, model: flag("--model") || "default", tools: [], mcp_servers: [] });
  say({ type: "system", subtype: "status", status: "requesting", session_id: sessionId });
  if (text === "fail:auth") result({ is_error: true, result: "API Error: 401 invalid x-api-key" });
  else if (text === "fail:rate") result({ is_error: true, result: "You've hit your weekly limit · resets Oct 8" });
  else if (text === "fail:model") result({ is_error: true, result: "prompt is too long" });
  else if (text === "retry401") {
    for (const attempt of [1, 2]) say({ type: "system", subtype: "api_retry", attempt, retry_delay_ms: 100, error_status: 401, error: "invalid token", session_id: sessionId });
    while (!interrupted) await pause();
    result({ subtype: "error_during_execution", is_error: true, result: "" });
  } else if (text.startsWith("hold:")) {
    const k = Number(text.slice(5));
    const all = await message(Array.from({ length: k }, (_, i) => `d${i} `), 0, async (i) => {
      while (i === k && !interrupted && steers.length === 0) await pause();
    });
    if (interrupted) result({ subtype: "error_during_execution", is_error: true, result: "" });
    else result({ result: all });
  } else if (text.startsWith("gate:")) {
    const [count, held, name] = text.slice(5).split(":");
    const at = `${dump}.${name}`;
    const all = await message(Array.from({ length: Number(count) }, (_, i) => `d${i} `), 0, async (i) => {
      if (i === Number(held)) await gate(`${at}.a`);
      if (i === Number(count)) {
        fs.writeFileSync(`${at}.said`, "");
        await gate(`${at}.b`);
      }
    });
    result({ result: all });
  } else if (text.includes("post:")) {
    const server = JSON.parse(flag("--mcp-config")).mcpServers.stillfail;
    const to = /thread="([^"]+)"/.exec(text)?.[1] ?? "";
    const said = text.slice(text.indexOf("post:") + 5).split("\n")[0];
    // `slow:<n>` before it: n deltas, 50 ms apart, first (a turn long enough to hand over in the middle of).
    const slow = /slow:(\d+)/.exec(text.slice(0, text.indexOf("post:")));
    if (slow) await message(Array.from({ length: Number(slow[1]) }, (_, i) => `d${i} `), 50);
    const call = (id, method, params) =>
      fetch(server.url, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${process.env.STILLFAIL_MCP_TOKEN}` }, body: JSON.stringify({ jsonrpc: "2.0", id, method, params }) }).then((r) => r.json());
    await call(1, "initialize", { protocolVersion: "2025-06-18" });
    const answer = await call(2, "tools/call", { name: "chat_post", arguments: { to, text: said, kind: "all_done", done: "answered the question that was asked" } });
    result({ result: await message([answer.result.content[0].text], 0) });
  } else if (text === "exit") {
    await message(["partial"], 0);
    fs.writeSync(2, "noise\n\nerror: An unknown error occurred (Unexpected)\n");
    process.exit(3);
  } else if (text === "tool") {
    const id = `msg_${++n}`;
    stream({ type: "message_start", message: { id } });
    stream({ type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "call_1", name: "Bash", input: {} } });
    stream({ type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"command":' } });
    stream({ type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '"sleep 60"}' } });
    stream({ type: "content_block_stop", index: 0 });
    stream({ type: "message_stop" });
    while (!backgrounded && !interrupted) await pause();
    say({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "call_1", content: backgrounded ? "moved to background" : "interrupted" }] } });
    if (interrupted) result({ subtype: "error_during_execution", is_error: true, result: "" });
    else result({ result: await message(["done"], 0) });
  } else if (text.startsWith("slow:")) {
    const count = Number(text.slice(5));
    const all = await message(Array.from({ length: count }, (_, i) => `d${i} `), 50);
    if (interrupted) result({ subtype: "error_during_execution", is_error: true, result: "" });
    else result({ result: all });
  } else {
    result({ result: await message([text.startsWith("say:") ? text.slice(4) : text], 0) });
    if (text === "again") queued.push("auto");
  }
  busy = false;
  const next = queued.shift();
  if (next !== undefined) setTimeout(() => turn(next), 50);
}

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (dump) fs.appendFileSync(dump + ".stdin", line + "\n");
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  if (msg.type === "control_request") {
    const subtype = msg.request && msg.request.subtype;
    if (subtype === "interrupt") interrupted = true;
    if (subtype === "background_tasks") backgrounded = true;
    wake();
    say({ type: "control_response", response: { subtype: "success", request_id: msg.request_id } });
    return;
  }
  if (msg.type !== "user") return;
  const text = msg.message.content.map((c) => c.text).join("");
  if (!busy) turn(text);
  else if (text.startsWith("queue:")) queued.push(text.slice(6));
  else {
    steers.push(text);
    wake();
  }
});
rl.on("close", () => process.exit(0));
