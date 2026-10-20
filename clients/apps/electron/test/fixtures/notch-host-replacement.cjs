"use strict";

const { createInterface } = require("node:readline");

const hostNumber = process.argv[2];
const hostName = hostNumber === "1" ? "host-a" : "host-b";
const input = createInterface({ input: process.stdin });

input.on("line", (line) => {
  const command = JSON.parse(line);

  if (hostName === "host-a" && command.method === "stop") {
    const acknowledgement = {
      id: command.id,
      payload: {
        method: command.method,
        running: false,
        value: hostName,
      },
      type: "result",
    };
    const partialBuffered = {
      payload: { value: "host-a-partial-buffered" },
      type: "fixture",
    };
    process.stdout.write(
      `${JSON.stringify(acknowledgement)}\n${JSON.stringify(partialBuffered)}\n` +
        '{"type":"action","payload":{"action":"window:minimize","value":"'
    );
    return;
  }

  const result = () =>
    respond({
      id: command.id,
      payload: {
        method: command.method,
        running: command.method !== "stop",
        value: hostName,
      },
      type: "result",
    });
  // Host B holds its start result until the test sends SIGUSR1, once host A
  // has closed, so A's late output, error and exit all land while B starts.
  if (hostName === "host-b" && command.method === "start") {
    process.once("SIGUSR1", result);
    respond({
      payload: { value: "host-b-command-pending" },
      type: "fixture",
    });
    return;
  }
  result();
});

// Stopped, host A stays until the test sends SIGUSR2 once host B is starting,
// then finishes its partial line, writes to stderr and exits.
if (hostName === "host-a") {
  process.on("SIGTERM", () => {});
  process.on("SIGUSR2", () => {
    process.stdout.write('host-a-late-stdout"}}\n', () => {
      process.stderr.write("host-a-late-stderr\n", () => process.exit(23));
    });
  });
}

function respond(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}
