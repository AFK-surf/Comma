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

  if (hostName === "host-b") {
    respond({
      payload: { value: "host-b-command-pending" },
      type: "fixture",
    });
  }

  const delay = hostName === "host-b" && command.method === "start" ? 400 : 0;
  setTimeout(() => {
    respond({
      id: command.id,
      payload: {
        method: command.method,
        running: command.method !== "stop",
        value: hostName,
      },
      type: "result",
    });
  }, delay);
});

if (hostName === "host-a") {
  process.on("SIGTERM", () => {
    setTimeout(() => {
      process.stdout.write('host-a-late-stdout"}}\n');
      process.stderr.write("host-a-late-stderr\n");
    }, 180);
    setTimeout(() => {
      process.exit(23);
    }, 240);
  });
}

function respond(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}
