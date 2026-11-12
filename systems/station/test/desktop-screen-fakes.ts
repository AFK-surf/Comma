// comma-desktop-screen (native/desktop-screen) as a fake process, for the tests of Windows' desktop (win-screen.test.ts,
// mesh-screens.test.ts): node running FAKE_SCREEN, started by a WindowsDesktop's `start`.
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/// comma-desktop-screen as native/desktop-screen's is, as a process (node running this): `status` says a display;
/// `view` answers its request with its info (or, asked for a 1-pixel view, that it cannot capture), says the pointer,
/// says the pointer again as a mouse op moves it, says a copy as the clipboard is watched, answers each audio ask with a
/// packet (asked `audio`: PCM's 3840 bytes, or 160 bytes as an Opus packet when asked `audioCodec: "opus"`), answers each next with a frame (the first with its config; asked for a 2-pixel view, it ends by itself after the
/// second), and notes the request and each input in its log, a JSON line each.
export const FAKE_SCREEN = `
const fs = require("node:fs");
const [mode, log, stopped] = process.argv.slice(2);
if (mode === "status") { console.log(JSON.stringify({ ok: true, display: { id: 1, width: 2560, height: 1600 }, capture: true })); process.exit(0); }
const out = (kind, payload) => { const head = Buffer.alloc(5); head[0] = kind; head.writeUInt32BE(payload.length, 1); process.stdout.write(Buffer.concat([head, payload])); };
let carry = Buffer.alloc(0), request = null, n = 0, audio = 0;
process.stdin.on("data", (chunk) => {
  carry = Buffer.concat([carry, chunk]);
  if (request === null) {
    const at = carry.indexOf(10); if (at < 0) return;
    request = JSON.parse(carry.subarray(0, at)); carry = carry.subarray(at + 1);
    fs.appendFileSync(log, JSON.stringify(request) + "\\n");
    if (request.maxWidth === 1) { out(1, Buffer.from(JSON.stringify({ error: "no display to capture", code: "display" }))); return process.exit(0); }
    out(1, Buffer.from(JSON.stringify({ width: 1280, height: 800, encoder: "fake", ...(request.codec === "h265" ? { codec: "h265" } : {}), ...(request.audio ? { audio: true } : {}) })));
    if (request.audio) out(8, Buffer.from(JSON.stringify({ codec: request.audioCodec === "opus" ? "opus" : "pcm_s16le", sampleRate: 48000, channels: 2 })));
    out(6, Buffer.from(JSON.stringify({ x: 0.5, y: 0.25, shape: "text" })));
  }
  while (carry.length >= 5) {
    const length = carry.readUInt32BE(1); if (carry.length < 5 + length) return;
    const kind = carry[0], payload = carry.subarray(5, 5 + length); carry = carry.subarray(5 + length);
    if (kind === 1) {
      n++;
      if (n === 1) { const c = Buffer.alloc(8); c.writeUInt32BE(1280, 0); c.writeUInt32BE(800, 4); out(2, Buffer.concat([c, Buffer.from([1, 66, 0, 31])])); }
      const f = Buffer.alloc(9); f[0] = n === 1 ? 1 : 0; f.writeBigUInt64BE(BigInt(n * 1000), 1); out(3, Buffer.concat([f, Buffer.from([0, 0, 0, 1, n])]));
      if (request.maxWidth === 2 && n === 2) { if (stopped) out(4, Buffer.from(JSON.stringify({ stopped }))); process.stdout.end(() => process.exit(3)); }
    } else if (kind === 3) {
      fs.appendFileSync(log, payload.toString() + "\\n");
      // The pointer follows a mouse op, as the real one's does.
      const op = JSON.parse(payload);
      if (op.op === "mouse") out(6, Buffer.from(JSON.stringify({ x: op.x, y: op.y, shape: "default" })));
    }
    else if (kind === 7) fs.appendFileSync(log, JSON.stringify({ rate: payload.readUInt32BE(0) }) + "\\n");
    else if (kind === 4) fs.appendFileSync(log, JSON.stringify({ clip: payload[1], paste: (payload[0] & 1) === 1, text: payload.subarray(2).toString() }) + "\\n");
    else if (kind === 5) {
      fs.appendFileSync(log, JSON.stringify({ watch: payload[0] }) + "\\n");
      // A copy made on the machine once it is watched.
      if (payload[0] === 1) out(5, Buffer.concat([Buffer.from([1]), Buffer.from("复制的")]));
    } else if (kind === 9) {
      audio++;
      const p = Buffer.alloc(8 + (request.audioCodec === "opus" ? 160 : 3840), audio); p.writeBigUInt64BE(BigInt(audio * 20000), 0); out(9, p);
    }
  }
});
process.stdin.on("end", () => process.exit(0));
`;

export function fakeScreen(stopped = "") {
  const dir = mkdtempSync(join(tmpdir(), "comma-winscreen-"));
  const script = join(dir, "fake-screen.cjs");
  const log = join(dir, "log");
  writeFileSync(script, FAKE_SCREEN);
  writeFileSync(log, "");
  const started: string[][] = [];
  const start = (_binary: string, args: string[]) => (started.push(args), spawn(process.execPath, [script, args[0]!, log, stopped], { stdio: ["pipe", "pipe", "inherit"] }));
  const lines = () => readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l));
  return { start, started, lines, done: () => rmSync(dir, { recursive: true, force: true }) };
}
