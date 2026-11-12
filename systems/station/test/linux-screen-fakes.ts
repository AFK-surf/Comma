// ffmpeg and xdotool as fake programs, for the tests of a Linux desktop (screens/x11-desktop.ts) on any machine:
// node running each, found on the PATH a test's X11Desktop is given. ffmpeg's capture writes pictures as x11grab does
// (raw YUV 4:2:0 or JPEGs, at its frame rate), its encoder answers each raw picture with one FLV video tag (the first
// after an avcC), and xdotool says a display and notes every other command. Each program notes how it was started.
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const FAKE_FFMPEG = `
const fs = require("node:fs");
const a = process.argv.slice(2);
const log = (what) => fs.appendFileSync(process.env.FAKE_X11_LOG, JSON.stringify(what) + "\\n");
if (a.includes("-encoders")) { console.log(" V....D libx264              libx264 H.264 / AVC"); process.exit(0); }
if (a.includes("-devices")) { console.log(" D  x11grab         X11 screen capture, using XCB"); process.exit(0); }
log({ ffmpeg: a });
process.stdout.on("error", () => process.exit(0));
if (a.includes("x11grab")) {
  const [w, h] = /scale=(\\d+):(\\d+)/.exec(a[a.indexOf("-vf") + 1]).slice(1).map(Number);
  const fps = Number(a[a.indexOf("-framerate") + 1]);
  let n = 0;
  const picture = a.includes("rawvideo") ? () => Buffer.alloc(w * h * 3 / 2, n++ & 255) : () => Buffer.from([0xff, 0xd8, n++ & 255, 0xff, 0xd9]);
  const write = () => process.stdout.write(picture());
  write();
  setInterval(write, 1000 / fps);
} else {
  const [w, h] = a[a.indexOf("-video_size") + 1].split("x").map(Number);
  const raw = w * h * 3 / 2;
  const sps = Buffer.from("6742c00ada11ec0440000003004000000f23c489a8", "hex"), pps = Buffer.from("68ce0fc8", "hex");
  const avcC = Buffer.from([1, sps[1], sps[2], sps[3], 0xff, 0xe1, 0, sps.length, ...sps, 1, 0, pps.length, ...pps]);
  const tag = (payload) => {
    const head = Buffer.alloc(11); head[0] = 9; head.writeUIntBE(payload.length, 1, 3);
    const back = Buffer.alloc(4); back.writeUInt32BE(11 + payload.length);
    process.stdout.write(Buffer.concat([head, payload, back]));
  };
  process.stdout.write(Buffer.from([0x46, 0x4c, 0x56, 1, 1, 0, 0, 0, 9, 0, 0, 0, 0]));
  tag(Buffer.concat([Buffer.from([0x17, 0, 0, 0, 0]), avcC]));
  let carry = 0, n = 0;
  process.stdin.on("data", (chunk) => {
    carry += chunk.length;
    while (carry >= raw) {
      carry -= raw;
      const key = n === 0;
      tag(Buffer.from([key ? 0x17 : 0x27, 1, 0, 0, 0, 0, 0, 0, 2, key ? 0x65 : 0x41, n++ & 255]));
    }
  });
  process.stdin.on("end", () => process.exit(0));
}
`;

const FAKE_XDOTOOL = `
const fs = require("node:fs");
const a = process.argv.slice(2);
if (a[0] === "getdisplaygeometry") { console.log(process.env.FAKE_X11_SIZE ?? "1280 800"); process.exit(0); }
if (a[0] === "--version") { console.log("xdotool version fake"); process.exit(0); }
fs.appendFileSync(process.env.FAKE_X11_LOG, JSON.stringify({ xdotool: a }) + "\\n");
`;

/// The fakes in a directory of their own: `env` finds them (and nothing else) on its PATH, with a display.
export function fakeX11Tools() {
  const dir = mkdtempSync(join(tmpdir(), "comma-x11-"));
  const log = join(dir, "log");
  writeFileSync(log, "");
  for (const [name, body] of [["ffmpeg", FAKE_FFMPEG], ["xdotool", FAKE_XDOTOOL]] as const) {
    writeFileSync(join(dir, name), `#!${process.execPath}\n${body}`);
    chmodSync(join(dir, name), 0o755);
  }
  const env: NodeJS.ProcessEnv = { PATH: dir, DISPLAY: ":99", XDG_SESSION_TYPE: "x11", FAKE_X11_LOG: log, HOME: dir };
  const lines = (): Record<string, string[]>[] => readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
  /// What xdotool was told to do, a command a line.
  const posted = () => lines().flatMap((l) => (l.xdotool ? [l.xdotool.join(" ")] : []));
  return { dir, log, env, lines, posted, done: () => rmSync(dir, { recursive: true, force: true }) };
}
