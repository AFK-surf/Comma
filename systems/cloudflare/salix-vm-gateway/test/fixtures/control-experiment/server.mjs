import http from "node:http";
import crypto from "node:crypto";
const boot = crypto.randomUUID();
const receipts = new Map();
let finishes = 0;
const serve = async (request, response) => {
  const path = new URL(request.url, "http://fixture").pathname;
  let result = { ok: true, boot, finishes };
  if (path === "/archive" && request.method === "POST") {
    let raw = "";
    for await (const chunk of request) raw += chunk;
    const body = JSON.parse(raw);
    if (body.action === "status") result = receipts.get(body.operation) ?? { operation: body.operation, phase: "pending" };
    else {
      receipts.set(body.operation, { operation: body.operation, phase: "restoring" });
      await new Promise((resolve) => setTimeout(resolve, Math.min(15_000, body.delay_ms ?? 0)));
      finishes++;
      result = { operation: body.operation, phase: "restored", next_offset: 1, sessions: 0, finishes, boot };
      receipts.set(body.operation, result);
    }
  }
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify(result));
};
for (const port of [8080, 3000]) {
  const server = http.createServer((request, response) => serve(request, response).catch(() => { response.writeHead(500); response.end(); }));
  server.on("upgrade", (request, socket) => {
    const accept = crypto.createHash("sha1").update(request.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.on("error", () => {});
  });
  server.listen(port, "0.0.0.0");
}
