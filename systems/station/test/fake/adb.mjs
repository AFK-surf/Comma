// A fake `adb` for test/adb.test.ts, never a real device. FAKE_ADB_DIR holds what it knows and did:
//   calls        each invocation's argv, a JSON line
//   state        what `-s <serial> get-state` says (none: "error: device '<serial>' not found", exit 1)
//   on-connect   what `connect` sets `state` to once it reached the phone (default "device")
//   dialed       each line a phone answered over a dialled connection
//   grant-says   what `shell pm grant …` says (default nothing: granted)
// `connect <host:port>` dials it, says "CNXN" and waits for a line back, as a real adb's handshake reaches adbd;
// `pair <host:port> <code>` dials it with "PAIR <code>" and says it paired if a line came back and the code is 123456.
import fs from "node:fs";
import net from "node:net";
import path from "node:path";

const dir = process.env.FAKE_ADB_DIR;
const args = process.argv.slice(2);
const file = (name) => path.join(dir, name);
const read = (name) => (fs.existsSync(file(name)) ? fs.readFileSync(file(name), "utf8").trim() : null);
fs.appendFileSync(file("calls"), JSON.stringify(args) + "\n");

function dial(target, line) {
  const [host, port] = [target.slice(0, target.lastIndexOf(":")), Number(target.slice(target.lastIndexOf(":") + 1))];
  return new Promise((resolve) => {
    const socket = net.connect({ host, port });
    let got = "";
    // No time limit of its own: it answers once the other end did, or closed (the station's limit is its own).
    const done = (answer) => {
      socket.destroy();
      resolve(answer);
    };
    socket.on("connect", () => socket.write(line + "\n"));
    socket.on("data", (b) => {
      got += b;
      if (got.includes("\n")) done(got.slice(0, got.indexOf("\n")));
    });
    socket.on("error", () => done(null));
    socket.on("close", () => done(null));
  });
}

if (args[0] === "-s" && args[2] === "get-state") {
  const state = read("state");
  if (state === null) {
    process.stderr.write(`error: device '${args[1]}' not found\n`);
    process.exit(1);
  }
  process.stdout.write(state + "\n");
} else if (args[0] === "-s" && args[2] === "shell") {
  const says = read("grant-says");
  if (says) process.stdout.write(says + "\n");
} else if (args[0] === "connect") {
  const answer = await dial(args[1], "CNXN");
  if (answer !== null) {
    fs.appendFileSync(file("dialed"), answer + "\n");
    fs.writeFileSync(file("state"), read("on-connect") ?? "device");
  }
  process.stdout.write(`connected to ${args[1]}\n`);
} else if (args[0] === "disconnect") {
  fs.rmSync(file("state"), { force: true });
  process.stdout.write(`disconnected ${args[1]}\n`);
} else if (args[0] === "pair") {
  const answer = await dial(args[1], `PAIR ${args[2]}`);
  if (answer !== null) fs.appendFileSync(file("dialed"), answer + "\n");
  if (answer !== null && args[2] === "123456") process.stdout.write(`Successfully paired to ${args[1]} [guid=adb-fake]\n`);
  else process.stdout.write("Failed: Wrong password or connection was dropped.\n");
} else {
  process.stderr.write(`fake adb: unknown ${args.join(" ")}\n`);
  process.exit(1);
}
