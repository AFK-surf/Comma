// A stand-in for the station's Node side in the launcher's tests: it speaks the control socket's protocol and answers a
// TCP connection on each port it is given with "<pid> mcp|admin". What it does is set by <data>/fake.conf (key=value
// lines, read as it starts): version=…, ready=no (never says ready), ready_after=ms, crash_after=ms (exits 1 that long
// after ready), crash=once (the data directory's first Node exits 1 once ready), start=crash (exits 1 at once),
// take=no|failed (never takes over: says nothing of the agents' door, or that it failed). What
// happens is appended to <data>/fake.log: "<ms> <pid> <what>", among it "ports <mcp> <admin>" once both serve (the
// launcher binds them where it finds them free).
"use strict";
const fs = require("fs");
const net = require("net");
const path = require("path");

const args = process.argv.slice(2);
if (args[0] !== "run") {
  // Another command: says how it was run.
  process.stdout.write(JSON.stringify({ pid: process.pid, args }) + "\n");
  process.exit(7);
}
const flag = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const data = flag("--data");
const conf = {};
try {
  for (const line of fs.readFileSync(path.join(data, "fake.conf"), "utf8").split("\n")) {
    const at = line.indexOf("=");
    if (at > 0) conf[line.slice(0, at).trim()] = line.slice(at + 1).trim();
  }
} catch {}
const log = (what) => fs.appendFileSync(path.join(data, "fake.log"), `${Date.now()} ${process.pid} ${what}\n`);

log(`start ${args.join(" ")}`);
if (conf.start === "crash") {
  log("crash");
  process.exit(1);
}

const [mcp, admin, control] = flag("--launcher-fds").split(",").map(Number);
let serving = 0;
const servers = [
  [mcp, "mcp"],
  [admin, "admin"],
].map(([fd, name]) => {
  const server = net.createServer((socket) => socket.end(`${process.pid} ${name}\n`));
  server.listen({ fd }, () => {
    if (++serving === 2) log(`ports ${servers[0].address().port} ${servers[1].address().port}`);
  });
  return server;
});

const pipe = new net.Socket({ fd: control, readable: true, writable: true });
const say = (message) => pipe.write(JSON.stringify(message) + "\n");
let pending = "";
pipe.on("data", (chunk) => {
  pending += chunk;
  for (let at; (at = pending.indexOf("\n")) >= 0; ) {
    const message = JSON.parse(pending.slice(0, at));
    pending = pending.slice(at + 1);
    log(`got ${message.op}`);
    if (message.op === "handover" || message.op === "stop") quit(0);
    else if (message.op === "drain") say({ drained: "idle" });
  }
});
pipe.on("close", () => {
  log("control closed");
  process.exit(0);
});

// Stops accepting, lets the connections under way end, then exits.
let quitting = false;
function quit(code) {
  if (quitting) return;
  quitting = true;
  let open = servers.length;
  for (const server of servers)
    server.close(() => {
      if (--open === 0) {
        log("exit");
        process.exit(code);
      }
    });
}

if (conf.ready !== "no") {
  const after = Number(conf.ready_after || 0);
  setTimeout(() => {
    // Logged first: the launcher may act on the word before this process runs again.
    log("ready");
    say({ ready: true, version: conf.version || "0.1.0" });
    // Taken over (the station's Node: its loopback port at once, the agents' door once the sessions are taken up):
    // take=no never opens the door, take=failed says it could not.
    const listening = servers.map((server) => (server.listening ? undefined : new Promise((r) => server.once("listening", r))));
    void Promise.all(listening).then(() => {
      say({ serving: "admin", port: servers[1].address().port });
      if (conf.take === "failed") {
        log("take failed");
        say({ failed: "the agents' side did not start: a test's" });
      } else if (conf.take !== "no") say({ serving: "mcp", port: servers[0].address().port });
    });
    const crashed = path.join(data, "crashed");
    if (conf.crash === "once" && !fs.existsSync(crashed)) {
      fs.writeFileSync(crashed, "");
      log("crash");
      process.exit(1);
    }
    if (conf.crash_after)
      setTimeout(() => {
        log("crash");
        process.exit(1);
      }, Number(conf.crash_after));
  }, after);
}
